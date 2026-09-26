//
//  ShareIntake.swift
//  „An PodcastAI senden“ (iOS und macOS)
//
//  Nimmt aus einer Freigabe einen Link oder eine Audiodatei und legt sie in
//  den Eingang der App Group. Mehr tut die Erweiterung nicht: Sie legt keine
//  Quelle an, lädt nichts aus dem Netz und spielt nichts ab. Die App liest
//  den Eingang beim Start und zeigt die Vorschau mit „Abonnieren“ oder „Nur
//  diese Folge“.
//
//  Danach versucht die Erweiterung, die App zu öffnen. iOS erlaubt das
//  einer Share Extension nicht; dann sagt ein kurzer Satz, dass der Link in
//  PodcastAI wartet.
//

import Foundation
import Observation
import UniformTypeIdentifiers
import PodcastAIShareInbox

@MainActor
@Observable
final class ShareIntake {

    enum Phase: Equatable {
        case working
        /// Im Eingang, aber die App ließ sich nicht öffnen.
        case handedOver(summary: String)
        case failed(String)
    }

    private(set) var phase: Phase = .working

    @ObservationIgnored private let items: [NSExtensionItem]
    @ObservationIgnored private let openApp: @MainActor (URL) async -> Bool
    @ObservationIgnored private let complete: @MainActor () -> Void
    @ObservationIgnored private let cancel: @MainActor () -> Void
    @ObservationIgnored private var started = false

    init(items: [NSExtensionItem],
         openApp: @escaping @MainActor (URL) async -> Bool,
         complete: @escaping @MainActor () -> Void,
         cancel: @escaping @MainActor () -> Void) {
        self.items = items
        self.openApp = openApp
        self.complete = complete
        self.cancel = cancel
    }

    func start() async {
        guard !started else { return }
        started = true
        guard let inbox = ShareInbox.appGroup() else {
            phase = .failed(ShareInboxError.unavailable.localizedDescription)
            return
        }
        do {
            let item = try await ShareAttachments.deposit(from: items, into: inbox)
            if await openApp(ShareInbox.openAppURL) {
                complete()
            } else {
                phase = .handedOver(summary: Self.summary(of: item))
            }
        } catch let error as ShareInboxError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(ShareInboxError.unreadableEntry.localizedDescription)
        }
    }

    func done() { complete() }

    func dismiss() { cancel() }

    /// Was übergeben wurde, in einer Zeile.
    static func summary(of item: ShareInboxItem) -> String {
        switch item.kind {
        case .audioFile:
            let name = item.displayName ?? ""
            let size = ByteCountFormatter.string(fromByteCount: item.byteCount ?? 0, countStyle: .file)
            return String(localized: "„\(name)“ · \(size)")
        case .link:
            guard let text = item.link, let url = URL(string: text) else { return "" }
            return label(for: SharedLinks.classify(url))
        }
    }

    static func label(for kind: SharedLinkKind) -> String {
        switch kind {
        case .applePodcastEpisode: String(localized: "Folge aus Apple Podcasts")
        case .applePodcast: String(localized: "Podcast aus Apple Podcasts")
        case .spotify: String(localized: "Link von Spotify")
        case .youTubeVideo: String(localized: "YouTube-Video")
        case .youTubeChannel: String(localized: "YouTube-Kanal")
        case .youTubePlaylist: String(localized: "YouTube-Playlist")
        case .socialPost(let platform): String(localized: "Beitrag von \(platform.displayName)")
        case .socialProfile(let platform): String(localized: "Profil bei \(platform.displayName)")
        case .audioFile: String(localized: "Audiodatei im Netz")
        case .podcastFeed: String(localized: "Podcast-Feed")
        case .webPage: String(localized: "Webseite")
        }
    }
}

/// Liest die Anhänge einer Freigabe. Eine Audiodatei geht vor einem Link,
/// ein Link vor Text, in dem ein Link steckt. Genommen wird nur das Erste.
enum ShareAttachments {

    @MainActor
    static func deposit(from items: [NSExtensionItem], into inbox: ShareInbox) async throws -> ShareInboxItem {
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) }) {
            return try await depositAudio(from: provider, into: inbox)
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = try? await loadURL(from: provider) {
            if url.isFileURL { return try await depositLocalFile(url, into: inbox) }
            if let item = try depositIfLink(url.absoluteString, into: inbox) { return item }
        }
        // Manche Apps teilen nur Text, etwa „Titel https://…“.
        var texts: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await loadText(from: provider) { texts.append(text) }
        }
        texts += items.compactMap { $0.attributedContentText?.string }
        for text in texts {
            if let item = try depositIfLink(text, into: inbox) { return item }
        }
        throw ShareInboxError.noLink
    }

    /// `nil`, wenn im Text kein lesbarer Link steht. Andere Fehler, etwa ein
    /// voller Eingang, gehen weiter, damit die Meldung stimmt.
    private static func depositIfLink(_ text: String, into inbox: ShareInbox) throws -> ShareInboxItem? {
        do {
            return try inbox.deposit(link: text)
        } catch ShareInboxError.noLink {
            return nil
        }
    }

    /// Die Datei liegt nur, solange der Block läuft. Deshalb wird sie darin
    /// in den Eingang kopiert.
    @MainActor
    private static func depositAudio(from provider: NSItemProvider, into inbox: ShareInbox) async throws -> ShareInboxItem {
        let suggested = provider.suggestedName
        // Geladen wird der angebotene Typ selbst, etwa MP3, nicht der Oberbegriff.
        let type = provider.registeredContentTypes(conformingTo: .audio).first ?? .audio
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareInboxError.fileMissing)
                    return
                }
                continuation.resume(with: Result {
                    try inbox.deposit(audioFileAt: url, originalName: fileName(suggested: suggested, file: url))
                })
            }
        }
    }

    /// Eine Datei aus dem Finder kommt als Adresse. Angenommen wird sie nur,
    /// wenn ihr Typ Ton ist.
    private static func depositLocalFile(_ url: URL, into inbox: ShareInbox) async throws -> ShareInboxItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .audio) == true else { throw ShareInboxError.notAudio }
        return try inbox.deposit(audioFileAt: url, originalName: url.lastPathComponent)
    }

    @MainActor
    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error ?? ShareInboxError.noLink)
                }
            }
        }
    }

    @MainActor
    private static func loadText(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text { continuation.resume(returning: text) } else {
                    continuation.resume(throwing: error ?? ShareInboxError.noLink)
                }
            }
        }
    }

    /// Der vorgeschlagene Name trägt oft keine Endung, die Kopie des Systems schon.
    private static func fileName(suggested: String?, file: URL) -> String {
        guard let suggested, !suggested.isEmpty else { return file.lastPathComponent }
        let hasExtension = !(suggested as NSString).pathExtension.isEmpty
        return hasExtension || file.pathExtension.isEmpty ? suggested : "\(suggested).\(file.pathExtension)"
    }
}

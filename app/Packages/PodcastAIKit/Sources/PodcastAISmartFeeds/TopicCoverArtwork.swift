//
//  TopicCoverArtwork.swift
//  PodcastAISmartFeeds
//
//  Das Bildcover eines Themen-Updates, erzeugt mit Image Playground.
//
//  Ein Bild je Update, nicht je Ausgabe: das Update ist die Sendung, die
//  Ausgaben sind ihre Folgen. Das Bild entsteht aus den Themen des Updates,
//  abstrakt und ohne Schrift, immer im selben Stil. Abgelegt wird es als
//  Datei unter Application Support, benannt nach Update und einem
//  Fingerabdruck der Themen. Ändern sich die Themen, passt der Name nicht
//  mehr, und das Cover gilt als veraltet. Mehr Zustand braucht es nicht,
//  in der Datenbank ändert sich nichts.
//
//  `ImageCreator` ist seit Version 27 als veraltet markiert, Apple verweist
//  auf den Systemdialog. Er bleibt hier der Weg für das automatische Cover,
//  solange das System ihn anbietet. Meldet er sich als nicht verfügbar,
//  bleibt der Dialog (`TopicCoverGenerator.isDialogAvailable`), und ohne
//  beides das Layoutcover. Alles, was `ImageCreator` betrifft, steht in
//  `TopicCoverGenerator`, damit ein Wechsel nur diese eine Stelle trifft.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PodcastAICore
#if canImport(ImagePlayground)
import ImagePlayground
#endif

// MARK: - Rezept

/// Woraus das Bild eines Updates entsteht.
///
/// Die Begriffe sind Themen, keine Sätze. Themen sind Nutzereingaben und
/// gehen als einzelne Begriffe an Image Playground, nie als Anweisung.
public struct TopicCoverRecipe: Sendable, Hashable {

    public let feedID: SmartFeedID
    /// Die Themen, bereinigt und gekürzt.
    public let concepts: [String]
    /// Fingerabdruck der Themen, unabhängig von ihrer Reihenfolge.
    public let digest: String
    /// Der Zusatz für ein abstraktes Bild, in der Sprache des Geräts.
    public let abstractConcept: String

    /// Mehr Begriffe machen das Bild nicht besser, nur beliebiger.
    public static let maximumConcepts = 4
    /// Ein Thema ist ein Begriff. Was länger ist, wird abgeschnitten.
    public static let maximumConceptLength = 60
    /// Der Zusatz für den zweiten Versuch. Englisch versteht Image
    /// Playground überall, auch wenn die Themen in einer Sprache sind, die
    /// es nicht unterstützt.
    public static let neutralConcept = "abstract shapes and soft color fields"

    public init(feed: SmartPodcastFeed, topics: [String], languageCode: String? = nil) {
        feedID = feed.id
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in topics {
            let label = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumConceptLength))
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard !label.isEmpty, seen.insert(key).inserted else { continue }
            cleaned.append(label)
        }
        // Ein Update ohne benannte Themen bekommt sein Bild aus dem Titel.
        if cleaned.isEmpty {
            let title = String(feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumConceptLength))
            if !title.isEmpty { cleaned = [title] }
        }
        concepts = Array(cleaned.prefix(Self.maximumConcepts))
        let normalized = concepts
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            .sorted()
            .joined(separator: "\n")
        digest = String(StableDigest.hex(of: normalized).prefix(12))
        let language = languageCode ?? Locale.current.language.languageCode?.identifier
        abstractConcept = language == "de" ? "abstrakte Formen und weiche Farbflächen" : Self.neutralConcept
    }

    /// Die Versuche der Reihe nach: erst die Themen mit dem Zusatz für ein
    /// abstraktes Bild, dann nur der neutrale Zusatz. Der zweite Versuch
    /// greift, wenn Image Playground mit den Themen nichts anfangen kann,
    /// etwa bei einem Namen oder einer nicht unterstützten Sprache.
    public var attempts: [[String]] {
        [concepts + [abstractConcept], [Self.neutralConcept]]
    }
}

// MARK: - Ablage

/// Ein abgelegtes Bildcover.
public struct StoredTopicCover: Sendable, Hashable {
    public let feedID: SmartFeedID
    public let digest: String
    public let url: URL
    public let createdAt: Date

    public init(feedID: SmartFeedID, digest: String, url: URL, createdAt: Date) {
        self.feedID = feedID; self.digest = digest; self.url = url; self.createdAt = createdAt
    }

    /// Passt das Bild noch zu den Themen?
    public func matches(_ recipe: TopicCoverRecipe) -> Bool {
        feedID == recipe.feedID && digest == recipe.digest
    }
}

/// Die Bildcover als Dateien, eins je Update.
public struct TopicCoverStore: Sendable {

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `Application Support/PodcastAI/Covers`.
    public static var standard: TopicCoverStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return TopicCoverStore(directory: base.appendingPathComponent("PodcastAI/Covers", isDirectory: true))
    }

    public enum StoreError: Error, LocalizedError {
        case unreadable
        case encodingFailed

        public var errorDescription: String? {
            String(localized: "Das Bild konnte nicht übernommen werden.", bundle: .module)
        }
    }

    /// Das abgelegte Cover eines Updates, auch ein veraltetes.
    public func stored(for feedID: SmartFeedID) -> StoredTopicCover? {
        let prefix = Self.prefix(for: feedID)
        return files(for: feedID).compactMap { url -> StoredTopicCover? in
            let name = url.deletingPathExtension().lastPathComponent
            let digest = String(name.dropFirst(prefix.count))
            guard !digest.isEmpty, !digest.contains("-") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return StoredTopicCover(feedID: feedID, digest: digest, url: url, createdAt: date)
        }
        .max { $0.createdAt < $1.createdAt }
    }

    /// Legt ein Bild ab, quadratisch zugeschnitten, und entfernt ältere
    /// Bilder desselben Updates.
    @discardableResult
    public func write(_ image: CGImage, for recipe: TopicCoverRecipe) throws -> StoredTopicCover {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let square = Self.squared(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { throw StoreError.encodingFailed }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.encodingFailed }

        let url = directory.appendingPathComponent(
            Self.prefix(for: recipe.feedID) + recipe.digest + ".png")
        try (data as Data).write(to: url, options: .atomic)
        for other in files(for: recipe.feedID) where other.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
        return StoredTopicCover(feedID: recipe.feedID, digest: recipe.digest, url: url, createdAt: Date())
    }

    /// Übernimmt das Ergebnis des Systemdialogs. Die Datei dort ist
    /// kurzlebig und wird deshalb sofort gelesen.
    @discardableResult
    public func adopt(fileAt url: URL, for recipe: TopicCoverRecipe) throws -> TopicCover {
        guard let image = Self.loadImage(at: url) else { throw StoreError.unreadable }
        let stored = try write(image, for: recipe)
        return TopicCover(stored: stored, image: Self.squared(image))
    }

    /// Entfernt alle Bilder eines Updates.
    public func remove(_ feedID: SmartFeedID) {
        for url in files(for: feedID) { try? FileManager.default.removeItem(at: url) }
    }

    /// Entfernt die Bilder aller Updates außer den genannten. Ein Update,
    /// das auf einem anderen Gerät gelöscht wurde, fehlt hier nur in der
    /// Liste, und ohne diesen Abgleich bliebe sein Bild für immer liegen.
    public func removeAll(except kept: Set<SmartFeedID>) {
        let prefixes = kept.map(Self.prefix(for:))
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in all where url.pathExtension == "png" && url.lastPathComponent.hasPrefix("cover-") {
            let name = url.lastPathComponent
            guard !prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Erzeugt ein Bild mit Image Playground und legt es ab.
    public func generate(for recipe: TopicCoverRecipe) async throws -> TopicCover {
        let image = try await TopicCoverGenerator.makeImage(for: recipe)
        let stored = try write(image, for: recipe)
        return TopicCover(stored: stored, image: Self.squared(image))
    }

    /// Liest ein Bild und dekodiert es gleich, damit das nicht erst beim
    /// Zeichnen auf dem Hauptthread passiert.
    public static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Schneidet die Mitte quadratisch aus. Ein Cover ist quadratisch,
    /// auch am Sperrbildschirm.
    static func squared(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        guard image.width != image.height, side > 0 else { return image }
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                          width: side, height: side)
        return image.cropping(to: rect) ?? image
    }

    static func prefix(for feedID: SmartFeedID) -> String {
        let safe = feedID.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? StableDigest.hex(of: feedID.rawValue)
        return "cover-\(safe)-"
    }

    private func files(for feedID: SmartFeedID) -> [URL] {
        let prefix = Self.prefix(for: feedID)
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "png" }
    }
}

/// Ein Bildcover mit seinem dekodierten Bild.
public struct TopicCover: Sendable {
    public let stored: StoredTopicCover
    public let image: CGImage

    public init(stored: StoredTopicCover, image: CGImage) {
        self.stored = stored; self.image = image
    }
}

// MARK: - Erzeugung

/// Die einzige Stelle, die `ImageCreator` kennt.
public enum TopicCoverGenerator {

    /// Wie ein Bild entstehen kann.
    public enum Availability: Sendable, Equatable {
        /// Noch nicht geprüft.
        case unknown
        /// Die App erzeugt Bilder selbst.
        case available
        /// Nur über den Systemdialog von Image Playground.
        case dialogOnly
        /// Gar nicht: Gerät, Region oder Apple Intelligence aus.
        case unavailable
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Image Playground steht nicht bereit.
        case unavailable
        /// Die App war nicht im Vordergrund. Später erneut versuchen.
        case notInForeground
        /// Abgebrochen, etwa vom System.
        case cancelled
        /// Kein Bild entstanden, auch nicht im zweiten Versuch.
        case failed
    }

    /// Kann der Systemdialog von Image Playground erscheinen?
    @MainActor public static var isDialogAvailable: Bool {
        #if canImport(ImagePlayground)
        ImagePlaygroundViewController.isAvailable
        #else
        false
        #endif
    }

    /// Erzeugt ein Bild. Wirft `Failure`, nie einen fremden Fehler.
    public static func makeImage(for recipe: TopicCoverRecipe) async throws -> CGImage {
        #if canImport(ImagePlayground)
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            throw failure(from: error)
        }
        guard let style = preferredStyle(in: creator.availableStyles) else { throw Failure.unavailable }
        for concepts in recipe.attempts {
            do {
                if let image = try await firstImage(from: creator, concepts: concepts, style: style) {
                    return image
                }
            } catch {
                let failure = failure(from: error)
                // Nur ein inhaltliches Scheitern lohnt den zweiten Versuch.
                guard failure == .failed else { throw failure }
            }
        }
        throw Failure.failed
        #else
        throw Failure.unavailable
        #endif
    }

    #if canImport(ImagePlayground)
    /// Ein Stil für alle Updates, damit die Liste wie aus einem Guss
    /// aussieht. Nie `externalProvider`: nur Apple Intelligence.
    static func preferredStyle(in available: [ImagePlaygroundStyle]) -> ImagePlaygroundStyle? {
        [ImagePlaygroundStyle.illustration, .animation, .sketch].first { available.contains($0) }
    }

    private static func firstImage(
        from creator: ImageCreator, concepts: [String], style: ImagePlaygroundStyle
    ) async throws -> CGImage? {
        let concepts = concepts.map { ImagePlaygroundConcept.text($0) }
        if #available(iOS 26.4, macOS 26.4, *) {
            var options = ImagePlaygroundOptions()
            // Keine Gesichter aus der Fotomediathek: ein Themencover braucht sie nicht.
            options.personalization = .disabled
            for try await created in creator.images(for: concepts, style: style, options: options, limit: 1) {
                return created.cgImage
            }
        } else {
            for try await created in creator.images(for: concepts, style: style, limit: 1) {
                return created.cgImage
            }
        }
        return nil
    }

    private static func failure(from error: any Error) -> Failure {
        if error is CancellationError { return .cancelled }
        guard let error = error as? ImageCreator.Error else { return .failed }
        switch error {
        case .notSupported, .unavailable: return .unavailable
        case .backgroundCreationForbidden: return .notInForeground
        case .creationCancelled: return .cancelled
        default: return .failed
        }
    }
    #endif
}

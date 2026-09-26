//
//  AppModel+ShareInbox.swift
//  PodcastAI
//
//  Was „An PodcastAI senden“ übergibt, landet auf denselben Wegen wie ein
//  eingefügter Link oder eine Folgenseite ohne Feed. Hier stehen nur die
//  zwei Stücke, die es dafür zusätzlich braucht: die Vorschau eines
//  Podcasts zu einem geteilten Feed, damit auch dort erst „Abonnieren“ oder
//  „Nur diese Folge“ kommt, und das Übernehmen einer geteilten Audiodatei.
//
//  Beides legt nichts an, solange niemand tippt. Abgespielt wird nichts.
//

import Foundation
import PodcastAIKit

extension AppModel {

    /// Die Vorschau zu einem geteilten Link auf einen Podcast: Feed, Seite
    /// eines Podcasts oder ein Podcast bei Apple. Ein eingefügter Link
    /// abonniert so etwas gleich; ein geteilter zeigt erst die Vorschau, denn
    /// geteilt heißt nicht abonniert. `nil`, wenn der Link keinen Podcast
    /// meint, etwa eine einzelne Audiodatei.
    func sharedPodcastPreview(for text: String) async throws -> PodcastLinkPreview? {
        guard let url = SharedLinks.link(in: text) else { return nil }
        let feedURL: URL
        switch SharedLinks.classify(url) {
        case .applePodcast:
            guard let feed = try await PodcastDirectory.feedURL(forAppleLink: url) else {
                throw FeedRefreshError.appleLinkWithoutFeed
            }
            feedURL = feed
        case .spotify:
            throw FeedRefreshError.spotifyLink
        case .podcastFeed, .webPage:
            feedURL = url
        case .applePodcastEpisode, .youTubeVideo, .youTubeChannel, .youTubePlaylist,
             .socialPost, .socialProfile, .audioFile:
            return nil
        }
        activity = String(localized: "Podcast wird geladen …")
        defer { activity = nil }
        let preview = try await PodcastCatalog.shared.preview(of: feedURL, model: self)
        let resolved = preview.feedURL ?? feedURL
        return PodcastLinkPreview(
            title: preview.feed.title.isEmpty ? (resolved.host() ?? resolved.absoluteString) : preview.feed.title,
            author: preview.feed.author, artworkURL: preview.feed.artworkURL,
            preview: preview, episode: nil, episodeMissing: false)
    }

    /// Nimmt eine geteilte Audiodatei als Folge unter „Einzelne Folgen“ auf,
    /// auf demselben Weg wie eine Folgenseite ohne Feed (`addAudioEpisode`).
    ///
    /// Die Datei zieht aus dem Eingang in den Audioordner, unter die Fassung
    /// einer Adresse, die nur diese Folge kennzeichnet. Aus dem Netz lässt
    /// sie sich nicht wieder holen; deshalb zählt sie wie „Laden (offline)“
    /// und bleibt, bis jemand „Audio entfernen“ wählt. Auf anderen Geräten
    /// steht die Folge nach dem Abgleich mit Transkript, aber ohne Ton.
    @discardableResult
    func addSharedAudioFile(_ file: URL, title: String) async throws -> AddedSource {
        // Nur Formate, die Wiedergabe und Transkript ohne Dateiendung erkennen.
        guard PlayableAsset.sniffMIMEType(at: file) != nil else { throw ShareInboxError.notAudio }
        let address = Self.sharedAudioAddress(title: title)
        let target = LocalMediaLocator.mediaDirectory
            .appendingPathComponent(MediaVersionID(stable: address.absoluteString).rawValue)
        try Self.moveOrCopy(file, to: target)
        mediaStorageChanged += 1

        // Vorab vermerkt, damit auch ein sehr schnell scheiterndes Transkript
        // die Datei nicht wegräumt. Die Kennung bildet `addSingleEpisode`
        // genauso; maßgeblich ist danach die Folge, die wirklich entstand.
        let expected = EpisodeID(stable: "\(SourceID(stable: "single-episodes").rawValue)|\(address.absoluteString)")
        keptOffline.insert(expected)
        do {
            let added = try await addAudioEpisode(address, title: title)
            if let episode = episodes.values.joined().first(where: { $0.audioURL == address }),
               episode.id != expected {
                keptOffline.insert(episode.id)
                keptOffline.remove(expected)
            }
            mediaStorageChanged += 1
            return added
        } catch {
            keptOffline.remove(expected)
            // Zurück in den Eingang, damit ein zweiter Tipp dieselbe Datei
            // findet. Ohne sie meldete er „keine Audiodatei“. „Verwerfen“
            // räumt sie dort weg wie sonst auch.
            do {
                try Self.moveOrCopy(target, to: file)
            } catch {
                try? FileManager.default.removeItem(at: target)
            }
            mediaStorageChanged += 1
            throw error
        }
    }

    /// Eine Adresse, die nur die Folge kennzeichnet. Einen Ort im Netz gibt
    /// es für eine geteilte Datei nicht; die Datei liegt unter der Fassung
    /// dieser Adresse im Audioordner.
    static func sharedAudioAddress(title: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = String(title.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
            .split(separator: "-").joined(separator: "-")
        let name = slug.isEmpty ? "audio" : String(slug.prefix(60))
        return URL(fileURLWithPath: "/PodcastAI/Geteilt/\(UUID().uuidString)/\(name)")
    }

    /// App Group und App liegen auf demselben Laufwerk, dann ist Verschieben
    /// nur ein Umbenennen. Sonst wird kopiert und das Original entfernt.
    private static func moveOrCopy(_ source: URL, to target: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            try FileManager.default.copyItem(at: source, to: target)
            try? FileManager.default.removeItem(at: source)
        }
    }
}

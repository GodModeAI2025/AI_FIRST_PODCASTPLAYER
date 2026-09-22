//
//  Services.swift
//  PodcastAI
//
//  Die Dienste, die Netz, Dateisystem und Modellzustand an die Oberfläche
//  anbinden. Bewusst klein gehalten: die Regeln stehen in PodcastAIKit,
//  hier wird nur zusammengesteckt.
//

import Foundation
import PodcastAIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Feeds holen und einlesen

public struct AddedSource: Sendable {
    public let title: String
    public let episodeCount: Int
}

public struct RefreshResult: Sendable {
    public let newEpisodes: Int
    public let failedSources: [String]
}

public actor FeedRefresher {

    private let store: LibraryStore
    private let resolver = SourceResolver()
    private let parser = FeedParser()
    private let session: URLSession

    public init(store: LibraryStore) {
        self.store = store
        // `SafeHTTP` bringt Adressprüfung, Weiterleitungsprüfung und das
        // Abschalten von Cookies und gespeicherten Zugangsdaten mit. Vorher
        // hatte diese Session gar keinen Delegaten — Weiterleitungen eines
        // fremden Feeds liefen ungeprüft durch.
        self.session = SafeHTTP.makeSession { configuration in
            configuration.requestCachePolicy = .reloadRevalidatingCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = true
        }
    }

    public func addSource(from input: String) async throws -> AddedSource {
        let link = try resolver.resolve(input)

        let feedURL: URL
        let kind: SourceKind
        var capabilities: SourceCapabilities

        switch link {
        case .podcastFeed(let url):
            feedURL = url; kind = .podcastRSS; capabilities = .fullPodcast
        case .youTubeChannel(_, let url):
            // Metadaten ja, Audiozugang nein — und das wird auch so angezeigt.
            feedURL = url; kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .youTubePlaylist:
            // Regelhaft, ohne Anfrage.
            guard let url = FeedDiscovery.directFeedURL(for: link) else {
                throw FeedRefreshError.needsDiscovery
            }
            feedURL = url; kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .youTubeVideo:
            feedURL = try await discoverYouTubeChannelFeed(for: link)
            kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .webPageNeedingDiscovery:
            feedURL = try await discoverFeedOnPage(for: link)
            kind = .podcastRSS; capabilities = .fullPodcast
        case .localFile(let url):
            feedURL = url; kind = .localFile
            capabilities = SourceCapabilities(metadata: true, audioDownload: true)
        }

        let data = try await fetch(feedURL)
        let parsed = try parser.parse(data)

        // Stabile Kennung aus der Feed-Adresse: dieselbe Quelle zweimal
        // hinzuzufügen erzeugt keine zweite Quelle.
        let sourceID = SourceID(stable: feedURL.absoluteString)
        if parsed.items.contains(where: { $0.transcripts.contains(where: \.isTimed) }) {
            capabilities.publisherTranscript = true
        }
        if parsed.nextPageURL != nil { capabilities.historicalCatalog = true }

        let source = Source(
            id: sourceID, kind: kind,
            title: parsed.title.isEmpty ? feedURL.host ?? "Unbenannte Quelle" : parsed.title,
            author: parsed.author, feedURL: feedURL,
            websiteURL: parsed.websiteURL, artworkURL: parsed.artworkURL,
            capabilities: capabilities
        )
        try await store.upsert(source: source)

        let episodes = parsed.items.map { makeEpisode($0, sourceID: sourceID) }
        _ = try await store.upsert(episodes: episodes, forSource: sourceID)

        return AddedSource(title: source.title, episodeCount: episodes.count)
    }

    public func refreshAll() async throws -> RefreshResult {
        var newEpisodes = 0
        var failed: [String] = []

        for source in try await store.sources() where source.isSubscribed {
            guard let feedURL = source.feedURL else { continue }
            do {
                let parsed = try parser.parse(try await fetch(feedURL))
                let episodes = parsed.items.map { makeEpisode($0, sourceID: source.id) }
                newEpisodes += try await store.upsert(episodes: episodes, forSource: source.id)
            } catch {
                // Eine kaputte Quelle darf den Lauf nicht abbrechen.
                failed.append(source.title)
            }
        }
        return RefreshResult(newEpisodes: newEpisodes, failedSources: failed)
    }

    private func makeEpisode(_ item: ParsedItem, sourceID: SourceID) -> Episode {
        // Kennung aus der Feed-GUID. Der Titel taugt nicht: er ändert sich,
        // und zwei Folgen können gleich heißen.
        let key = item.guid ?? item.audioURL?.absoluteString ?? item.title
        return Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(key)"),
            sourceID: sourceID,
            title: item.title,
            summary: item.summary,
            publishedAt: item.publishedAt,
            declaredDuration: item.duration.map { MediaDuration(seconds: Double($0)) },
            artworkURL: item.artworkURL,
            webPageURL: item.webPageURL,
            audioURL: item.audioURL,
            // Nur getaktete Transkripte: ungetakteter Text liefert Wissen,
            // aber keine Timecodes.
            timedTranscriptURL: item.transcripts.first(where: \.isTimed)?.url
        )
    }

    /// Sucht den Feed auf einer gewöhnlichen Webseite.
    ///
    /// Gelesen wird nur der Kopf der Seite — genau das eine Element, das
    /// laut Konvention den Feed benennt. Findet sich keines, ist das ein
    /// eigener Fehler und keine allgemeine Ausrede: der Nutzer erfährt,
    /// dass die Seite keinen Feed anbietet, nicht dass „etwas nicht
    /// eingebaut“ sei.
    private func discoverFeedOnPage(for link: ResolvedLink) async throws -> URL {
        guard let page = FeedDiscovery.pageToInspect(for: link) else {
            throw FeedRefreshError.needsDiscovery
        }
        let data = try await SafeHTTP.load(page, using: session, limit: Self.pageLimit)
        let html = String(decoding: data, as: UTF8.self)

        guard let feedURL = FeedDiscovery.feedLinks(inHTML: html, base: page).first else {
            throw FeedRefreshError.noFeedOnPage(page.host ?? page.absoluteString)
        }
        return feedURL
    }

    /// Macht aus einem YouTube-Video den Feed seines Kanals.
    ///
    /// Ein einzelnes Video ist kein Feed. Abonniert wird deshalb der Kanal —
    /// und das steht auch in der Oberfläche, statt so zu tun, als sei das
    /// Video die Quelle.
    private func discoverYouTubeChannelFeed(for link: ResolvedLink) async throws -> URL {
        guard let page = FeedDiscovery.pageToInspect(for: link) else {
            throw FeedRefreshError.needsDiscovery
        }
        let data = try await SafeHTTP.load(page, using: session, limit: Self.pageLimit)
        let html = String(decoding: data, as: UTF8.self)

        guard let channelID = FeedDiscovery.youTubeChannelID(inHTML: html),
              let feedURL = FeedDiscovery.youTubeFeedURL(forChannel: channelID) else {
            throw FeedRefreshError.noChannelForVideo
        }
        return feedURL
    }

    /// Eine HTML-Seite ist grösser als ein Feed, aber nicht beliebig gross.
    /// YouTube-Seiten liegen bei wenigen Megabyte.
    private static let pageLimit: Int64 = 12 * 1024 * 1024

    /// Holt einen Feed — mit Adressprüfung vor der Anfrage und einer
    /// Obergrenze, die *während* des Lesens greift.
    ///
    /// Vorher stand hier `session.data(for:)`: ein Server, der endlos
    /// sendet, hätte den Speicher gefüllt, bis das System die App beendet.
    private func fetch(_ url: URL) async throws -> Data {
        try await SafeHTTP.load(url, using: session, limit: SafeHTTP.textLimit)
    }
}

public enum FeedRefreshError: Error, LocalizedError {
    case needsDiscovery
    case noFeedOnPage(String)
    case noChannelForVideo

    public var errorDescription: String? {
        switch self {
        case .needsDiscovery:
            "Zu diesem Link lässt sich keine Feed-Adresse ermitteln. "
            + "Füge die Feed-Adresse direkt ein."
        case .noFeedOnPage(let host):
            "\(host) bietet keinen Feed an. Manche Seiten verlinken ihn nur auf "
            + "einer Unterseite — dann hilft die Adresse des Feeds selbst."
        case .noChannelForVideo:
            "Zu diesem Video liess sich kein Kanal ermitteln. PodcastAI abonniert "
            + "Kanäle, keine einzelnen Videos."
        }
    }
}

// MARK: - Medien finden

public struct LocalMediaLocator: MediaLocating {

    public init() {}

    public func playbackURL(for mediaVersionID: MediaVersionID) -> URL? {
        let base = Self.mediaDirectory
        let candidate = base.appendingPathComponent(mediaVersionID.rawValue)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var directory = base.appendingPathComponent("PodcastAI/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // **Nicht ins Backup.** Ohne diese Zeile wandert jede
        // heruntergeladene Folge ins iCloud-Backup des Nutzers — bei bis zu
        // 2 GB je Datei. Apples Data Storage Guidelines verlangen
        // ausdrücklich, dass nachladbare Inhalte ausgenommen werden; es ist
        // ein bekannter Ablehnungsgrund im App Review.
        //
        // Gesetzt wird das Merkmal am **Ordner**: es vererbt sich auf alles
        // darin, auch auf Dateien, die es noch nicht gibt. Es je Datei zu
        // setzen hiesse, es irgendwann bei einer zu vergessen.
        if (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return directory
    }
}

// MARK: - Modellzustand

public enum ModelStatusProbe {

    /// Fragt den tatsächlichen Zustand ab.
    ///
    /// PCC wird hier bewusst als nicht verfügbar gemeldet, solange kein
    /// Entitlement für dieses Entwicklerkonto vorliegt. Das ist ein offener
    /// Nachweis aus dem Plan (GATE-PCC) und keine Stelle, an der man
    /// optimistisch raten sollte.
    public static func current() async -> ModelStatus {
        #if canImport(FoundationModels)
        let onDevice: ModelAvailability = await checkOnDevice()
        #else
        let onDevice: ModelAvailability = .unavailable(.deviceNotEligible)
        #endif
        return ModelStatus(
            onDevice: onDevice,
            privateCloudCompute: .unavailable(.entitlementMissing)
        )
    }

    #if canImport(FoundationModels)
    private static func checkOnDevice() async -> ModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return switch reason {
            case .deviceNotEligible: .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: .unavailable(.appleIntelligenceDisabled)
            case .modelNotReady: .unavailable(.modelNotReady)
            @unknown default: .unavailable(.unknown("unbekannter Grund"))
            }
        @unknown default:
            return .unavailable(.unknown("unbekannter Zustand"))
        }
    }
    #endif
}

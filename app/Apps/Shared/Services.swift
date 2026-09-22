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

        // Eine einzelne Audiodatei ist kein Feed. Sie landet als Folge in
        // der Quelle „Einzelne Folgen“ und kann direkt erschlossen werden.
        if case .audioFile(let audioURL) = link {
            return try await addSingleEpisode(audioURL)
        }

        let linkFeedURL: URL
        let kind: SourceKind
        var capabilities: SourceCapabilities

        switch link {
        case .podcastFeed(let url):
            linkFeedURL = url; kind = .podcastRSS; capabilities = .fullPodcast
        case .youTubeChannel(_, let url):
            // Metadaten ja, Audiozugang nein — und das wird auch so angezeigt.
            linkFeedURL = url; kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .youTubePlaylist:
            // Regelhaft, ohne Anfrage.
            guard let url = FeedDiscovery.directFeedURL(for: link) else {
                throw FeedRefreshError.needsDiscovery
            }
            linkFeedURL = url; kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .youTubeVideo:
            linkFeedURL = try await discoverYouTubeChannelFeed(for: link)
            kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .webPageNeedingDiscovery:
            linkFeedURL = try await discoverFeedOnPage(for: link)
            kind = .podcastRSS; capabilities = .fullPodcast
        case .localFile(let url):
            linkFeedURL = url; kind = .localFile
            capabilities = SourceCapabilities(metadata: true, audioDownload: true)
        case .audioFile:
            // Oben bereits behandelt.
            throw FeedRefreshError.needsDiscovery
        }

        let (resolvedFeedURL, parsed) = try await fetchFeed(linkFeedURL, allowDiscovery: kind == .podcastRSS)
        let feedURL = resolvedFeedURL

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
            capabilities: capabilities, language: parsed.language
        )
        try await store.upsert(source: source)

        let episodes = parsed.items.map { makeEpisode($0, sourceID: sourceID) }
        _ = try await store.upsert(episodes: episodes, forSource: sourceID)

        return AddedSource(title: source.title, episodeCount: episodes.count)
    }

    /// Holt und liest einen Feed. Liefert die Adresse statt eines Feeds eine
    /// Webseite oder einen Fehler, sucht die Methode auf dieser Seite und auf
    /// der Startseite des Hosts nach dem verlinkten Feed. Podigee etwa
    /// antwortet auf `/rssfeed` mit einer 404-Seite, verlinkt den echten Feed
    /// `/feed/mp3` aber im Kopf der Startseite.
    private func fetchFeed(_ url: URL, allowDiscovery: Bool) async throws -> (URL, ParsedFeed) {
        var firstError: Error?
        do {
            let parsed = try parser.parse(try await fetch(url))
            return (url, parsed)
        } catch {
            firstError = error
        }
        guard allowDiscovery else { throw firstError! }

        var pages = [url]
        if let host = url.host, let root = URL(string: "\(url.scheme ?? "https")://\(host)/"), root != url {
            pages.append(root)
        }
        for page in pages {
            guard let data = try? await SafeHTTP.load(page, using: session, limit: Self.pageLimit) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            for candidate in FeedDiscovery.feedLinks(inHTML: html, base: page) where candidate != url {
                if let parsed = try? parser.parse(try await fetch(candidate)) {
                    return (candidate, parsed)
                }
            }
        }
        throw FeedRefreshError.notAFeed(url.host ?? url.absoluteString)
    }

    /// Legt eine einzelne Audiodatei als Folge an.
    private func addSingleEpisode(_ audioURL: URL) async throws -> AddedSource {
        let sourceID = SourceID(stable: "single-episodes")
        let existing = try await store.sources().first { $0.id == sourceID }
        if existing == nil {
            try await store.upsert(source: Source(
                id: sourceID, kind: .singleEpisodeLink, title: "Einzelne Folgen",
                capabilities: SourceCapabilities(metadata: true, audioDownload: true)
            ))
        }
        let name = audioURL.deletingPathExtension().lastPathComponent
        let title = "\(audioURL.host ?? "Audio") · \(name.count > 24 ? String(name.prefix(24)) + "…" : name)"
        let episode = Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(audioURL.absoluteString)"),
            sourceID: sourceID, title: title, publishedAt: Date(), audioURL: audioURL
        )
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        return AddedSource(title: "Einzelne Folgen", episodeCount: 1)
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
            timedTranscriptURL: item.transcripts.first(where: \.isTimed)?.url,
            publisherChapters: item.chapters,
            chaptersURL: item.chaptersURL,
            shownotesHTML: item.shownotesHTML
        )
    }

    /// Lädt Kapitel aus einer Podcasting-2.0-Kapiteldatei.
    public func loadChapters(from url: URL) async -> [Chapter]? {
        guard let data = try? await SafeHTTP.load(url, using: session, limit: 2 * 1024 * 1024) else { return nil }
        return try? ChapterFile.parse(data)
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
        // Viele Feed-Adressen sehen nicht nach Feed aus, etwa
        // `feeds.transistor.fm/ai-to-the-dna`. Ist der Inhalt selbst ein
        // Feed, ist die Suche hier schon zu Ende.
        if (try? parser.parse(data)) != nil { return page }
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
    case notAFeed(String)

    public var errorDescription: String? {
        switch self {
        case .needsDiscovery:
            "Zu diesem Link lässt sich keine Feed-Adresse ermitteln. "
            + "Füge die Feed-Adresse direkt ein."
        case .noFeedOnPage(let host):
            "\(host) bietet keinen Feed an. Manche Seiten verlinken ihn nur auf "
            + "einer Unterseite — dann hilft die Adresse des Feeds selbst."
        case .notAFeed(let host):
            "Unter dieser Adresse liegt kein Feed, und \(host) verlinkt auch keinen. "
            + "Prüfe die Adresse oder füge den Link der Podcast-Seite ein."
        case .noChannelForVideo:
            "Zu diesem Video liess sich kein Kanal ermitteln. PodcastAI abonniert "
            + "Kanäle, keine einzelnen Videos."
        }
    }
}

// MARK: - Audio-Podcast zu einem YouTube-Kanal

/// Ein Podcast aus dem Apple-Podcast-Verzeichnis, der zu einem YouTube-Kanal
/// passt. Viele Kanäle veröffentlichen dieselben Inhalte zusätzlich als
/// Audio-Podcast. Dessen Feed liefert echtes Audio, das PodcastAI
/// transkribieren darf. Das Audio der YouTube-Videos selbst lädt die App
/// nicht, das untersagen die Nutzungsbedingungen von YouTube.
public struct PodcastCounterpart: Sendable, Hashable, Identifiable {
    public let title: String
    public let author: String
    public let feedURL: URL
    public var id: URL { feedURL }
}

public enum PodcastDirectory {

    /// Sucht Podcasts, deren Autor oder Titel den Kanalnamen enthält.
    public static func counterparts(forChannel name: String) async -> [PodcastCounterpart] {
        let term = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 3,
              var components = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "DE"),
            URLQueryItem(name: "term", value: term),
        ]
        guard let url = components.url else { return [] }
        let session = SafeHTTP.makeSession { $0.timeoutIntervalForRequest = 15 }
        defer { session.finishTasksAndInvalidate() }
        guard let data = try? await SafeHTTP.load(url, using: session, limit: 2 * 1024 * 1024),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }

        let needle = term.lowercased()
        return response.results.compactMap { result in
            guard let feed = result.feedUrl.flatMap(URL.init(string:)) else { return nil }
            let author = result.artistName ?? ""
            let title = result.collectionName ?? ""
            let matches = author.lowercased().contains(needle) || title.lowercased().contains(needle)
            return matches ? PodcastCounterpart(title: title, author: author, feedURL: feed) : nil
        }
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let collectionName: String?
            let artistName: String?
            let feedUrl: String?
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
        let directory = base.appendingPathComponent("PodcastAI/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

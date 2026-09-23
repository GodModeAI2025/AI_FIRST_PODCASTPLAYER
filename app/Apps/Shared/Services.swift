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

    /// Die erste Web-Adresse in einem geteilten Text.
    static func firstLink(in text: String) -> URL? {
        text.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .flatMap { URL(string: String($0)) }
    }

    public func addSource(from input: String) async throws -> AddedSource {
        // Geteilte Links kommen oft mit Titel davor. Apple Podcasts und
        // Spotify verlinken keinen Feed auf ihren Seiten.
        if let shared = Self.firstLink(in: input), let host = shared.host()?.lowercased() {
            if host.hasSuffix("podcasts.apple.com") || host == "itunes.apple.com" {
                guard let feed = try await PodcastDirectory.feedURL(forAppleLink: shared) else {
                    throw FeedRefreshError.appleLinkWithoutFeed
                }
                return try await addSource(from: feed.absoluteString)
            }
            if host.hasSuffix("spotify.com") || host == "spotify.link" {
                throw FeedRefreshError.spotifyLink
            }
        }
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
        case .youTubeVideo, .youTubeChannelPage:
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

        let resolvedFeedURL: URL
        let parsed: ParsedFeed
        do {
            (resolvedFeedURL, parsed) = try await fetchFeed(linkFeedURL, allowDiscovery: kind == .podcastRSS)
        } catch where kind == .youTubeChannel {
            // Der Feed-Dienst von YouTube fällt immer wieder aus und antwortet
            // dann mit 404. Der Kanal wird trotzdem angelegt, mit Name und
            // Bild von der Kanalseite. Der passende Audio-Podcast lässt sich
            // so weiter finden, die Videoliste kommt beim nächsten Abgleich.
            return try await addYouTubeChannelWithoutFeed(feedURL: linkFeedURL, capabilities: capabilities)
        }
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

    private func addYouTubeChannelWithoutFeed(
        feedURL: URL, capabilities: SourceCapabilities
    ) async throws -> AddedSource {
        guard let channelID = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "channel_id" })?.value,
              let pageURL = URL(string: "https://www.youtube.com/channel/\(channelID)") else {
            throw FeedRefreshError.youTubeFeedUnavailable
        }
        // Ohne diese Angabe leitet YouTube in der EU auf eine Einwilligungsseite um.
        let html: String
        do {
            let data = try await SafeHTTP.load(pageURL, using: session, limit: Self.pageLimit,
                                               headers: ["Cookie": "SOCS=CAI", "Accept-Language": "de"])
            html = String(decoding: data, as: UTF8.self)
        } catch {
            throw FeedRefreshError.youTubeFeedUnavailable
        }
        guard let title = Self.metaContent("og:title", in: html), !title.isEmpty else {
            throw FeedRefreshError.youTubeFeedUnavailable
        }
        var limited = capabilities
        limited.limitationReason = "YouTube liefert die Videoliste gerade nicht. Der Kanal ist angelegt, "
            + "die Videos erscheinen beim nächsten Abgleich. Den passenden Audio-Podcast kannst du schon abonnieren."
        let source = Source(
            id: SourceID(stable: feedURL.absoluteString), kind: .youTubeChannel,
            title: title, author: title, feedURL: feedURL, websiteURL: pageURL,
            artworkURL: Self.metaContent("og:image", in: html).flatMap(URL.init(string:)),
            capabilities: limited
        )
        try await store.upsert(source: source)
        return AddedSource(title: title, episodeCount: 0)
    }

    /// Liest `<meta property="…" content="…">` aus einer Seite.
    static func metaContent(_ property: String, in html: String) -> String? {
        guard let range = html.range(of: "<meta property=\"\(property)\" content=\"") else { return nil }
        let rest = html[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
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

    /// Macht aus einem YouTube-Video oder einem Kanalnamen (`/@name`) den
    /// Feed des Kanals.
    ///
    /// Ein einzelnes Video ist kein Feed. Abonniert wird deshalb der Kanal —
    /// und das steht auch in der Oberfläche, statt so zu tun, als sei das
    /// Video die Quelle.
    private func discoverYouTubeChannelFeed(for link: ResolvedLink) async throws -> URL {
        guard let page = FeedDiscovery.pageToInspect(for: link) else {
            throw FeedRefreshError.needsDiscovery
        }
        var handle: String?
        if case .youTubeChannelPage(let name, _) = link { handle = name }
        // Ohne das Cookie leitet YouTube in der EU auf eine Einwilligungsseite
        // um, und dort steht keine Kanalkennung.
        let data: Data
        do {
            data = try await SafeHTTP.load(page, using: session, limit: Self.pageLimit,
                                           headers: ["Cookie": "SOCS=CAI", "Accept-Language": "de"])
        } catch HTTPTransferError.httpStatus(404) where handle != nil {
            throw FeedRefreshError.noChannelForHandle(handle ?? "")
        }
        let html = String(decoding: data, as: UTF8.self)

        guard let channelID = FeedDiscovery.youTubeChannelID(inHTML: html),
              let feedURL = FeedDiscovery.youTubeFeedURL(forChannel: channelID) else {
            if let handle { throw FeedRefreshError.noChannelForHandle(handle) }
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
    case noChannelForHandle(String)
    case notAFeed(String)
    case youTubeFeedUnavailable
    case appleLinkWithoutFeed
    case spotifyLink

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
        case .youTubeFeedUnavailable:
            "YouTube liefert für diesen Kanal gerade keine Daten. Das kommt bei YouTube immer wieder vor. "
            + "Später noch einmal versuchen oder direkt den Audio-Podcast des Kanals hinzufügen."
        case .appleLinkWithoutFeed:
            "Apple Podcasts nennt zu diesem Link keinen offenen Feed. Such den Podcast oben nach seinem Namen."
        case .spotifyLink:
            "Spotify gibt keine Feed-Adressen heraus. Such den Podcast oben nach seinem Namen, "
            + "fast alle Sendungen gibt es auch als offenen Feed."
        case .noChannelForVideo:
            "Zu diesem Video liess sich kein Kanal ermitteln. PodcastAI abonniert "
            + "Kanäle, keine einzelnen Videos."
        case .noChannelForHandle(let handle):
            "Zu „\(handle)“ liess sich kein YouTube-Kanal finden. Prüf die Schreibweise "
            + "oder füge den Link zu einem Video des Kanals ein."
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
    public var artworkURL: URL?
    public var genre: String?
    public var id: URL { feedURL }
}

public enum PodcastDirectoryError: Error, LocalizedError {
    case unreachable
    case unreadableAnswer

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            "Keine Verbindung zum Podcast-Verzeichnis. Prüf die Internetverbindung und versuch es noch einmal."
        case .unreadableAnswer:
            "Das Podcast-Verzeichnis hat gerade keine lesbare Antwort geschickt. Versuch es gleich noch einmal."
        }
    }
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

    /// Sucht im Apple-Podcast-Verzeichnis nach Name, Anbieter oder Thema.
    ///
    /// Wirft, wenn das Verzeichnis nicht erreichbar ist. Eine leere Liste
    /// heißt nur: nichts gefunden. Vorher sah beides gleich aus, und wer
    /// offline suchte, las „Keine Ergebnisse“.
    public static func search(_ term: String) async throws -> [PodcastCounterpart] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        let results = try await query("search", [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "DE"),
            URLQueryItem(name: "term", value: term),
        ])
        var seen = Set<URL>()
        return results.compactMap(\.counterpart).filter { seen.insert($0.feedURL).inserted }
    }

    /// Die Feed-Adresse zu einem Link aus Apple Podcasts. Apple nennt sie
    /// im Verzeichnis, die Seite selbst verlinkt keinen Feed. `nil` heißt:
    /// das Verzeichnis kennt keinen Feed dazu. Ist es nicht erreichbar,
    /// wirft die Methode.
    public static func feedURL(forAppleLink url: URL) async throws -> URL? {
        guard let id = applePodcastID(in: url) else { return nil }
        let results = try await query("lookup", [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: "podcast"),
        ])
        return results.compactMap(\.counterpart).first?.feedURL
    }

    /// `…/podcast/name/id1234567890?i=…` → `1234567890`.
    static func applePodcastID(in url: URL) -> String? {
        for part in url.pathComponents.reversed() where part.hasPrefix("id") {
            let digits = part.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    private static func query(_ endpoint: String, _ items: [URLQueryItem]) async throws -> [SearchResponse.Result] {
        guard var components = URLComponents(string: "https://itunes.apple.com/\(endpoint)") else { return [] }
        components.queryItems = items
        guard let url = components.url else { return [] }
        let session = SafeHTTP.makeSession { $0.timeoutIntervalForRequest = 15 }
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        do {
            data = try await SafeHTTP.load(url, using: session, limit: 2 * 1024 * 1024)
        } catch {
            // Eine abgebrochene Suche (weitergetippt) ist kein Verbindungsfehler.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw PodcastDirectoryError.unreachable
        }
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw PodcastDirectoryError.unreadableAnswer
        }
        return response.results
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let collectionName: String?
            let artistName: String?
            let feedUrl: String?
            let artworkUrl100: String?
            let primaryGenreName: String?

            var counterpart: PodcastCounterpart? {
                guard let feed = feedUrl.flatMap(URL.init(string:)) else { return nil }
                return PodcastCounterpart(title: collectionName ?? feed.host() ?? "Podcast",
                                          author: artistName ?? "", feedURL: feed,
                                          artworkURL: artworkUrl100.flatMap(URL.init(string:)),
                                          genre: primaryGenreName)
            }
        }
    }
}

// MARK: - Medien finden

public struct LocalMediaLocator: MediaLocating {

    public init() {}

    /// Die geladene Datei, sonst die Adresse beim Anbieter. So lassen sich
    /// Stellen auch nach „Audio entfernen“ weiter anhören, dann gestreamt.
    public func playbackURL(for mediaVersionID: MediaVersionID) -> URL? {
        localFile(for: mediaVersionID) ?? RemoteMediaRegistry.shared.url(for: mediaVersionID)
    }

    public func localFile(for mediaVersionID: MediaVersionID) -> URL? {
        let candidate = Self.mediaDirectory.appendingPathComponent(mediaVersionID.rawValue)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Belegter Speicher aller geladenen Audiodateien in Byte.
    public static func storedBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        return files.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return total }
            return total + Int64(values?.fileSize ?? 0)
        }
    }

    /// Löscht die Audiodateien der genannten Fassungen.
    public static func removeFiles(for ids: [MediaVersionID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent(id.rawValue))
        }
    }

    /// Löscht alle geladenen Audiodateien und gibt ihre Fassungen zurück.
    public static func removeAllFiles() -> [MediaVersionID] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        var removed: [MediaVersionID] = []
        for url in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            try? FileManager.default.removeItem(at: url)
            removed.append(MediaVersionID(rawValue: url.lastPathComponent))
        }
        return removed
    }

    public static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("PodcastAI/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Merkt sich, unter welcher Adresse eine Fassung beim Anbieter liegt.
/// Die Fassungskennung ist ein Hash der Adresse und lässt sich nicht
/// zurückrechnen; deshalb trägt die App beim Laden der Folgen hier ein.
public final class RemoteMediaRegistry: @unchecked Sendable {
    public static let shared = RemoteMediaRegistry()
    private let lock = NSLock()
    private var urls: [MediaVersionID: URL] = [:]

    public func register(_ episodes: [Episode]) {
        lock.lock(); defer { lock.unlock() }
        for episode in episodes {
            guard let audio = episode.audioURL else { continue }
            urls[MediaVersionID(stable: audio.absoluteString)] = audio
            if let current = episode.currentMediaVersionID { urls[current] = audio }
        }
    }

    public func url(for id: MediaVersionID) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return urls[id]
    }
}

// MARK: - Modellzustand

public enum ModelStatusProbe {

    /// Der tatsächliche Zustand von Gerätemodell und Private Cloud Compute.
    public static func current(allowPrivateCloud: Bool) -> ModelStatus {
        KnowledgeExtractor.currentStatus(allowPrivateCloud: allowPrivateCloud)
    }
}

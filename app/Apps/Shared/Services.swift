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

/// Was man vor dem Abonnieren von einem Podcast sieht: Beschreibung, Zahl
/// der Folgen und die neuesten Titel.
public struct PodcastPreview: Sendable {
    public struct Item: Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let publishedAt: Date?
    }
    public let summary: String?
    public let episodeCount: Int
    public let latestDate: Date?
    public let latest: [Item]

    init(_ feed: ParsedFeed) {
        summary = feed.summary
        episodeCount = feed.items.count
        latestDate = feed.items.compactMap(\.publishedAt).max()
        latest = feed.items.enumerated()
            .sorted { ($0.element.publishedAt ?? .distantPast) > ($1.element.publishedAt ?? .distantPast) }
            .prefix(3)
            .map { Item(id: $0.offset, title: $0.element.title, publishedAt: $0.element.publishedAt) }
    }
}

public actor FeedRefresher {

    private let store: LibraryStore
    private let resolver = SourceResolver()
    private let parser = FeedParser()
    private let session: URLSession
    /// Die zuletzt angesehene Vorschau. Wer gleich danach abonniert, lädt
    /// einen großen Feed nicht ein zweites Mal.
    private var previewed: (url: URL, feedURL: URL, feed: ParsedFeed, at: Date)?

    public init(store: LibraryStore) {
        self.store = store
        // `SafeHTTP` bringt Adressprüfung, Weiterleitungsprüfung und das
        // Abschalten von Cookies und gespeicherten Zugangsdaten mit. Vorher
        // hatte diese Session gar keinen Delegaten — Weiterleitungen eines
        // fremden Feeds liefen ungeprüft durch.
        self.session = SafeHTTP.makeSession { configuration in
            configuration.requestCachePolicy = .reloadRevalidatingCacheData
            // Kommt 20 Sekunden lang nichts, gilt der Server als nicht
            // erreichbar. Ein großer Feed, der stetig lädt, darf länger
            // brauchen, aber nicht ewig.
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 180
            // Nicht auf Netz warten. Mit Warten galt auch eine Adresse, die
            // es nicht mehr gibt, als „noch kein Netz“: Abonnieren drehte
            // dann ohne Ende, und ein toter Feed hielt das Aktualisieren
            // aller anderen auf. Ohne Netz scheitern Abruf und Aktualisieren
            // jetzt gleich, das Aktualisieren übergeht die Quelle wie jeden
            // anderen Fehler.
            configuration.waitsForConnectivity = false
        }
    }

    /// Die erste Web-Adresse in einem geteilten Text.
    static func firstLink(in text: String) -> URL? {
        text.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .flatMap { URL(string: String($0)) }
    }

    /// Legt die Quelle an. Netzfehler kommen als Sätze zurück, die zum
    /// Abonnieren passen, nicht als Meldung des Systems.
    public func addSource(from input: String) async throws -> AddedSource {
        do {
            return try await subscribe(from: input)
        } catch {
            throw FeedRefreshError.forSubscription(error, input: input)
        }
    }

    private func subscribe(from input: String) async throws -> AddedSource {
        // Geteilte Links kommen oft mit Titel davor. Apple Podcasts und
        // Spotify verlinken keinen Feed auf ihren Seiten.
        if let shared = Self.firstLink(in: input), let host = shared.host()?.lowercased() {
            if host.hasSuffix("podcasts.apple.com") || host == "itunes.apple.com" {
                guard let feed = try await PodcastDirectory.feedURL(forAppleLink: shared) else {
                    throw FeedRefreshError.appleLinkWithoutFeed
                }
                return try await subscribe(from: feed.absoluteString)
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
        // Stellt sich die Seite selbst als Feed heraus, ist er schon gelesen.
        var prefetched: ParsedFeed?

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
        case .webPageNeedingDiscovery(let page) where previewed?.url == page:
            // Gerade in der Vorschau gelesen, `fetchFeed` nimmt ihn von dort.
            linkFeedURL = page; kind = .podcastRSS; capabilities = .fullPodcast
        case .webPageNeedingDiscovery:
            let found = try await discoverFeedOnPage(for: link)
            linkFeedURL = found.url; prefetched = found.feed
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
            if let prefetched {
                (resolvedFeedURL, parsed) = (linkFeedURL, prefetched)
            } else {
                (resolvedFeedURL, parsed) = try await fetchFeed(linkFeedURL, allowDiscovery: kind == .podcastRSS)
            }
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
            title: parsed.title.isEmpty ? feedURL.host ?? String(localized: "Unbenannter Podcast") : parsed.title,
            author: parsed.author, feedURL: feedURL,
            websiteURL: parsed.websiteURL, artworkURL: parsed.artworkURL,
            capabilities: capabilities, language: parsed.language
        )
        try await store.upsert(source: source)

        let episodes = parsed.items.map { makeEpisode($0, sourceID: sourceID) }
        _ = try await store.upsert(episodes: episodes, forSource: sourceID)

        return AddedSource(title: source.title, episodeCount: episodes.count)
    }

    /// Liest einen Podcast für die Vorschau, ohne ihn anzulegen. Abonniert
    /// jemand gleich danach, nimmt `addSource` den schon gelesenen Feed.
    public func preview(of url: URL) async throws -> PodcastPreview {
        do {
            let link = try resolver.resolve(url.absoluteString)
            let feedURL: URL
            let feed: ParsedFeed
            switch link {
            case .podcastFeed(let address):
                (feedURL, feed) = try await fetchFeed(address, allowDiscovery: true)
                previewed = (address, feedURL, feed, Date())
            case .webPageNeedingDiscovery(let address):
                let found = try await discoverFeedOnPage(for: link)
                if let parsed = found.feed {
                    (feedURL, feed) = (found.url, parsed)
                } else {
                    (feedURL, feed) = try await fetchFeed(found.url, allowDiscovery: true)
                }
                previewed = (address, feedURL, feed, Date())
            default:
                throw FeedRefreshError.needsDiscovery
            }
            return PodcastPreview(feed)
        } catch {
            throw FeedRefreshError.forSubscription(error, input: url.absoluteString)
        }
    }

    /// Gibt den Feed der letzten Vorschau frei, etwa wenn das Blatt zugeht.
    /// Ein großer Feed belegt sonst Speicher, den niemand mehr braucht.
    public func discardPreview() {
        previewed = nil
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
        limited.limitationReason = String(localized: """
            YouTube liefert die Videoliste gerade nicht. Der Kanal ist angelegt, die Videos erscheinen \
            beim nächsten Abgleich. Den passenden Audio-Podcast kannst du schon abonnieren.
            """)
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
        if let kept = previewed {
            // Nur einmal und nur kurz: danach zählt wieder, was der Server sagt.
            if Date().timeIntervalSince(kept.at) > 600 {
                previewed = nil
            } else if kept.url == url {
                previewed = nil
                return (kept.feedURL, kept.feed)
            }
        }
        var firstError: Error?
        do {
            let parsed = try parser.parse(try await fetch(url))
            return (url, parsed)
        } catch {
            firstError = error
        }
        // Ist der Server gar nicht erreichbar, kosten weitere Anfragen an
        // denselben Host nur Wartezeit, und am Ende stünde „kein Feed“
        // statt des eigentlichen Grunds.
        guard allowDiscovery, Self.worthDiscovering(after: firstError) else { throw firstError! }

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
        let sourceTitle = String(localized: "Einzelne Folgen")
        let existing = try await store.sources().first { $0.id == sourceID }
        if existing == nil {
            try await store.upsert(source: Source(
                id: sourceID, kind: .singleEpisodeLink, title: sourceTitle,
                capabilities: SourceCapabilities(metadata: true, audioDownload: true)
            ))
        }
        let name = audioURL.deletingPathExtension().lastPathComponent
        let title = "\(audioURL.host ?? String(localized: "Audio")) · \(name.count > 24 ? String(name.prefix(24)) + "…" : name)"
        let episode = Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(audioURL.absoluteString)"),
            sourceID: sourceID, title: title, publishedAt: Date(), audioURL: audioURL
        )
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        return AddedSource(title: sourceTitle, episodeCount: 1)
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

    /// Nur wenn der Server geantwortet, aber keinen Feed geliefert hat,
    /// lohnt die Suche auf seinen Seiten.
    private static func worthDiscovering(after error: Error?) -> Bool {
        if error is URLError || error is CancellationError { return false }
        if let http = error as? HTTPTransferError {
            switch http {
            case .httpStatus, .emptyResponse: return true
            default: return false
            }
        }
        return true
    }

    /// Sucht den Feed auf einer gewöhnlichen Webseite.
    ///
    /// Gelesen wird nur der Kopf der Seite — genau das eine Element, das
    /// laut Konvention den Feed benennt. Findet sich keines, ist das ein
    /// eigener Fehler und keine allgemeine Ausrede: der Nutzer erfährt,
    /// dass die Seite keinen Feed anbietet, nicht dass „etwas nicht
    /// eingebaut“ sei.
    ///
    /// Ist die Seite selbst der Feed, kommt er gelesen zurück.
    private func discoverFeedOnPage(for link: ResolvedLink) async throws -> (url: URL, feed: ParsedFeed?) {
        guard let page = FeedDiscovery.pageToInspect(for: link) else {
            throw FeedRefreshError.needsDiscovery
        }
        // Mit der Grenze für Feeds, nicht der für Seiten: viele Feed-Adressen
        // sehen nicht nach Feed aus, etwa `feeds.transistor.fm/ai-to-the-dna`
        // oder `feeds.megaphone.fm/ESHO5419936864`. Ein Feed mit 2000 Folgen
        // hat über 20 MB und scheiterte hier an der Seitengrenze.
        let data = try await fetch(page)
        if let feed = try? parser.parse(data) { return (page, feed) }
        let html = String(decoding: data, as: UTF8.self)

        guard let feedURL = FeedDiscovery.feedLinks(inHTML: html, base: page).first else {
            throw FeedRefreshError.noFeedOnPage(page.host ?? page.absoluteString)
        }
        return (feedURL, nil)
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

    /// Eine HTML-Seite ist größer als ein Feed, aber nicht beliebig groß.
    /// YouTube-Seiten liegen bei wenigen Megabyte.
    private static let pageLimit: Int64 = 12 * 1024 * 1024

    /// Holt einen Feed — mit Adressprüfung vor der Anfrage und einer
    /// Obergrenze, die *während* des Lesens greift.
    ///
    /// Vorher stand hier `session.data(for:)`: ein Server, der endlos
    /// sendet, hätte den Speicher gefüllt, bis das System die App beendet.
    /// Ein Feed über der Grenze wird abgeschnitten, nicht abgelehnt: die
    /// neuesten Folgen stehen vorn, und der Parser behält, was bis zum
    /// Schnitt vollständig war.
    private func fetch(_ url: URL) async throws -> Data {
        try await SafeHTTP.load(url, using: session, limit: SafeHTTP.feedLimit, truncating: true)
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
    case hostNotFound
    case notResponding
    case offline
    case insecureServer
    case pageTooLarge
    case gone
    case unreachable

    /// Übersetzt Netzfehler beim Abonnieren in eigene Fälle mit klaren
    /// Sätzen. Die Meldungen des Systems sprachen von „App Transport
    /// Security“, und ein zu großer Feed klang wie ein Problem mit
    /// Transkripten. Alles andere bleibt, wie es ist.
    static func forSubscription(_ error: Error, input: String) -> Error {
        switch error as? HTTPTransferError {
        case .tooLarge?: return FeedRefreshError.pageTooLarge
        case .httpStatus(404)?, .httpStatus(410)?: return FeedRefreshError.gone
        default: break
        }
        guard let urlError = error as? URLError else { return error }
        let wasHTTP = FeedRefresher.firstLink(in: input)?.scheme?.lowercased() == "http"
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .cannotFindHost, .dnsLookupFailed:
            return FeedRefreshError.hostNotFound
        case .cannotConnectToHost where wasHTTP:
            // Die App fragt über https an. Antwortet der Server dort nicht,
            // kann er nur unverschlüsselt.
            return FeedRefreshError.insecureServer
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return FeedRefreshError.notResponding
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return FeedRefreshError.offline
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return FeedRefreshError.insecureServer
        default:
            return FeedRefreshError.unreachable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .hostNotFound:
            String(localized: """
                Diesen Podcast gibt es unter seiner Adresse nicht mehr. Vermutlich wurde er \
                eingestellt oder ist umgezogen.
                """)
        case .notResponding:
            String(localized: "Dieser Podcast antwortet gerade nicht. Später noch einmal versuchen.")
        case .offline:
            String(localized: "Keine Internetverbindung. Sobald wieder Netz da ist, noch einmal versuchen.")
        case .insecureServer:
            String(localized: """
                Der Server dieses Podcasts bietet keine sichere Verbindung an. Die App lädt nur über \
                sichere Verbindungen, deshalb lässt er sich nicht abonnieren.
                """)
        case .pageTooLarge:
            String(localized: """
                Die Seite hinter diesem Link ist größer, als die App liest. Such den Podcast oben nach \
                seinem Namen.
                """)
        case .gone:
            String(localized: """
                Unter dieser Adresse gibt es den Podcast nicht mehr. Vermutlich ist er umgezogen oder \
                wurde eingestellt.
                """)
        case .unreachable:
            String(localized: "Der Podcast ließ sich gerade nicht laden. Später noch einmal versuchen.")
        case .needsDiscovery:
            String(localized: "Zu diesem Link lässt sich keine Feed-Adresse ermitteln. Füge die Feed-Adresse direkt ein.")
        case .noFeedOnPage(let host):
            String(localized: """
                \(host) bietet keinen Feed an. Manche Seiten verlinken ihn nur auf einer Unterseite. \
                Dann hilft die Adresse des Feeds selbst.
                """)
        case .notAFeed(let host):
            String(localized: """
                Unter dieser Adresse liegt kein Feed, und \(host) verlinkt auch keinen. Prüfe die \
                Adresse oder füge den Link der Podcast-Seite ein.
                """)
        case .youTubeFeedUnavailable:
            String(localized: """
                YouTube liefert für diesen Kanal gerade keine Daten. Das kommt bei YouTube immer wieder \
                vor. Später noch einmal versuchen oder direkt den Audio-Podcast des Kanals hinzufügen.
                """)
        case .appleLinkWithoutFeed:
            String(localized: """
                Apple Podcasts nennt zu diesem Link keinen offenen Feed. Such den Podcast oben nach \
                seinem Namen.
                """)
        case .spotifyLink:
            String(localized: """
                Spotify gibt keine Feed-Adressen heraus. Such den Podcast oben nach seinem Namen, fast \
                alle Sendungen gibt es auch als offenen Feed.
                """)
        case .noChannelForVideo:
            String(localized: """
                Zu diesem Video ließ sich kein Kanal ermitteln. PodcastAI abonniert Kanäle, keine \
                einzelnen Videos.
                """)
        case .noChannelForHandle(let handle):
            String(localized: """
                Zu „\(handle)“ ließ sich kein YouTube-Kanal finden. Prüf die Schreibweise oder füge \
                den Link zu einem Video des Kanals ein.
                """)
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
    /// Zahl der Folgen und Datum der neuesten laut Verzeichnis, für die
    /// Vorschau vor dem Abonnieren.
    public var episodeCount: Int?
    public var latestRelease: Date?
    public var id: URL { feedURL }
}

public enum PodcastDirectoryError: Error, LocalizedError {
    case unreachable
    case unreadableAnswer

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: """
                Keine Verbindung zum Podcast-Verzeichnis. Prüf die Internetverbindung und versuch es \
                noch einmal.
                """)
        case .unreadableAnswer:
            String(localized: """
                Das Podcast-Verzeichnis hat gerade keine lesbare Antwort geschickt. Versuch es gleich \
                noch einmal.
                """)
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
            // Hat das Verzeichnis geantwortet, etwa mit 403 oder 503, weil zu
            // schnell hintereinander gesucht wurde, liegt es nicht an der
            // Verbindung. „Prüf die Internetverbindung“ schickte dann auf die
            // falsche Suche.
            if error is HTTPTransferError { throw PodcastDirectoryError.unreadableAnswer }
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
            let trackCount: Int?
            let releaseDate: String?

            var counterpart: PodcastCounterpart? {
                guard let feed = feedUrl.flatMap(URL.init(string:)) else { return nil }
                return PodcastCounterpart(title: collectionName ?? feed.host() ?? String(localized: "Podcast"),
                                          author: artistName ?? "", feedURL: feed,
                                          artworkURL: artworkUrl100.flatMap(URL.init(string:)),
                                          genre: primaryGenreName,
                                          episodeCount: trackCount,
                                          latestRelease: releaseDate.flatMap { try? Date($0, strategy: .iso8601) })
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

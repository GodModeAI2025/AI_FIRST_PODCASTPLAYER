//
//  PodcastIndexClient.swift
//  PodcastAISources
//
//  Der Podcast-Katalog der App: Suche, Trends je Sprache und Rubrik,
//  Einzelheiten und neueste Folgen eines Podcasts, alles von Podcast Index
//  (podcastindex.org).
//
//  Jede Anfrage trägt vier Kopfzeilen: `User-Agent`, `X-Auth-Key`,
//  `X-Auth-Date` (Unixzeit in ganzen Sekunden) und `Authorization`, den
//  SHA-1 über Schlüssel, Geheimnis und Zeit in kleinen Hexziffern. Der
//  Server nimmt nur Zeiten an, die höchstens drei Minuten abweichen. Geht
//  die Uhr des Geräts falsch, rechnet der Client einmal mit der Zeit aus
//  der Antwort nach.
//
//  Zugangsdaten stehen nie im Quelltext. Die App liest sie aus einer Datei,
//  die nicht im Repository liegt; fehlt sie, ist der Katalog aus.
//

import Foundation
import PodcastAICore
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Zugang

/// Schlüssel und Geheimnis für Podcast Index. Ein Schlüssel mit
/// Leserechten reicht für alles, was der Katalog braucht.
public struct PodcastIndexCredentials: Sendable, Equatable, Decodable {
    public let apiKey: String
    public let apiSecret: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "APIKey"
        case apiSecret = "APISecret"
    }

    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(apiKey: (try? container.decode(String.self, forKey: .apiKey)) ?? "",
                  apiSecret: (try? container.decode(String.self, forKey: .apiSecret)) ?? "")
    }

    /// Liest eine Property-Liste mit `APIKey` und `APISecret`. `nil`, wenn
    /// die Datei keine solche Liste ist.
    public init?(propertyList data: Data) {
        guard let decoded = try? PropertyListDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }

    /// Ohne beides beantwortet der Katalog keine Anfrage.
    public var isComplete: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }
}

public enum PodcastIndexSignature {

    /// `sha1(key + secret + timestamp)` über UTF-8, in kleinen Hexziffern.
    public static func authorization(key: String, secret: String, timestamp: Int) -> String {
        #if canImport(CryptoKit)
        Insecure.SHA1.hash(data: Data((key + secret + String(timestamp)).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #else
        ""
        #endif
    }

    /// Die vier Kopfzeilen für eine Anfrage zum Zeitpunkt `date`. Die Zeit
    /// wird abgerundet: der Server erwartet ganze Sekunden ohne Punkt.
    public static func headers(for credentials: PodcastIndexCredentials, at date: Date,
                               userAgent: String) -> [String: String] {
        let timestamp = Int(date.timeIntervalSince1970.rounded(.down))
        return [
            "User-Agent": userAgent,
            "X-Auth-Key": credentials.apiKey,
            "X-Auth-Date": String(timestamp),
            "Authorization": authorization(key: credentials.apiKey, secret: credentials.apiSecret,
                                           timestamp: timestamp),
        ]
    }
}

// MARK: - Fehler

public enum PodcastIndexError: Error, LocalizedError, Equatable, Sendable {
    case missingCredentials
    case unauthorized
    case rateLimited
    case notFound
    case serverStatus(Int)
    case unreachable
    case unreadableAnswer

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            String(localized: """
                Dieser Fassung der App fehlt der Zugang zum Podcast-Katalog. Gesucht wird im \
                Apple-Podcast-Verzeichnis.
                """, bundle: .module)
        case .unauthorized:
            String(localized: """
                Der Podcast-Katalog hat die Anfrage abgelehnt. Stimmt die Uhrzeit des Geräts? \
                Sonst später noch einmal versuchen.
                """, bundle: .module)
        case .rateLimited:
            String(localized: """
                Der Podcast-Katalog bekommt gerade zu viele Anfragen. In einer Minute noch einmal versuchen.
                """, bundle: .module)
        case .notFound:
            String(localized: "Diesen Podcast führt der Katalog nicht mehr.", bundle: .module)
        case .serverStatus(let code):
            String(localized: """
                Der Podcast-Katalog antwortet gerade nicht (Status \(String(code))). Später noch einmal versuchen.
                """, bundle: .module)
        case .unreachable:
            String(localized: """
                Keine Verbindung zum Podcast-Katalog. Prüf die Internetverbindung und versuch es noch einmal.
                """, bundle: .module)
        case .unreadableAnswer:
            String(localized: """
                Der Podcast-Katalog hat keine lesbare Antwort geschickt. Versuch es gleich noch einmal.
                """, bundle: .module)
        }
    }
}

// MARK: - Übertragung

/// Eine Antwort, wie der Client sie braucht: Status, Inhalt und die Zeit
/// des Servers aus der Kopfzeile `Date`.
public struct CatalogHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let serverDate: Date?

    public init(status: Int, body: Data, serverDate: Date? = nil) {
        self.status = status
        self.body = body
        self.serverDate = serverDate
    }
}

/// Holt eine Adresse mit Kopfzeilen. Im Betrieb über `SafeHTTP`, in Tests
/// und UI-Tests aus festen Antworten.
public typealias CatalogTransport = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> CatalogHTTPResponse

// MARK: - Client

public actor PodcastIndexClient {

    public static let baseURL = URL(string: "https://api.podcastindex.org/api/1.0/")!
    /// Obergrenze je Antwort. 100 Trends mit Beschreibung sind etwa 150 KB.
    public static let responseLimit: Int64 = 4 * 1024 * 1024
    /// Arten von Feeds, die im Katalog als Podcast erscheinen. Musik,
    /// Filme, Blogs und Listen anderer Feeds bleiben draußen.
    static let podcastMedia: Set<String> = ["podcast", "audiobook", "video"]

    private let credentials: PodcastIndexCredentials
    private let userAgent: String
    private let transport: CatalogTransport
    private let clock: @Sendable () -> Date
    /// Abstand zwischen Server- und Geräteuhr, sobald eine Antwort ihn
    /// verraten hat.
    private var clockOffset: TimeInterval = 0

    public init(credentials: PodcastIndexCredentials, userAgent: String,
                transport: @escaping CatalogTransport = PodcastIndexClient.liveTransport(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.userAgent = userAgent
        self.transport = transport
        self.clock = clock
    }

    /// Über `SafeHTTP`: Adressprüfung, keine Cookies, Weiterleitungen nur
    /// ohne die Kopfzeilen mit Zugangsdaten.
    public static func liveTransport() -> CatalogTransport {
        let session = SafeHTTP.makeSession { configuration in
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        return { url, headers in
            let (data, response) = try await SafeHTTP.loadResponse(url, using: session, limit: responseLimit,
                                                                     headers: headers)
            return CatalogHTTPResponse(status: response.statusCode, body: data,
                                       serverDate: httpDate(response.value(forHTTPHeaderField: "Date")))
        }
    }

    // MARK: Anfragen

    /// Sucht in Titel, Autor und Eigentümer. Die API kennt dabei keinen
    /// Sprachfilter.
    public func search(_ term: String, max: Int = 30) async throws -> [CatalogPodcast] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        let envelope: FeedsEnvelope = try await get("search/byterm", [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "max", value: String(max)),
        ])
        // Derselbe Feed kann zweimal im Index stehen, etwa nach einem Umzug.
        return CatalogMerge.merged(envelope.feeds.compactMap(Self.podcast(from:)), [])
    }

    /// Was gerade viel gehört wird, auf Wunsch nur in einer Sprache und
    /// einer Rubrik. Blättern kennt die API nicht; mehr gibt es über ein
    /// größeres `max`.
    public func trending(language: AppLanguage?, category: CatalogCategory? = nil,
                         max: Int = 40) async throws -> [CatalogPodcast] {
        var items = [URLQueryItem(name: "max", value: String(min(Swift.max(max, 1), 1000)))]
        if let language {
            items.append(URLQueryItem(name: "lang", value: CatalogLanguage.codes(for: language).joined(separator: ",")))
        }
        if let category {
            items.append(URLQueryItem(name: "cat", value: category.podcastIndexIDs.map(String.init).joined(separator: ",")))
        }
        let envelope: FeedsEnvelope = try await get("podcasts/trending", items)
        var podcasts = CatalogMerge.merged(envelope.feeds.compactMap(Self.podcast(from:)), [])
        // Die Antwort ist schon gefiltert. Hier noch einmal, weil „lang“ die
        // Schreibweise des Feeds trifft und nicht die Sprache.
        podcasts = CatalogLanguage.filter(podcasts, language: language)
        if let category {
            // Nach derselben Regel wie die Rubriken auf der Seite eines
            // Podcasts: Oberbegriffe zuerst. „Musik > Kommentar“ trägt die
            // 54 der Nachrichten, bleibt aber Musik.
            podcasts = podcasts.filter { CatalogCategory.categories(for: $0.categoryIDs).contains(category) }
        }
        return podcasts
    }

    /// Alles, was der Katalog über einen Podcast weiß.
    public func podcast(id: Int) async throws -> CatalogPodcast {
        let envelope: FeedEnvelope = try await get("podcasts/byfeedid", [URLQueryItem(name: "id", value: String(id))])
        guard let feed = envelope.feed, let podcast = Self.podcast(from: feed) else {
            throw PodcastIndexError.notFound
        }
        return podcast
    }

    /// Die neuesten Folgen, neueste zuerst.
    public func episodes(feedID: Int, max: Int = 10) async throws -> [CatalogEpisode] {
        let envelope: ItemsEnvelope = try await get("episodes/byfeedid", [
            URLQueryItem(name: "id", value: String(feedID)),
            URLQueryItem(name: "max", value: String(max)),
        ])
        return envelope.items
            .compactMap(Self.episode(from:))
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    // MARK: Übertragung und Fehler

    static func url(_ path: String, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items
        // `URLComponents` lässt „+“ stehen, der Server liest es als Leerzeichen.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func get<Envelope: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> Envelope {
        guard let url = Self.url(path, items) else { throw PodcastIndexError.unreadableAnswer }
        let body = try await send(url, retryWithServerTime: true)
        do {
            return try JSONDecoder().decode(Envelope.self, from: body)
        } catch {
            throw PodcastIndexError.unreadableAnswer
        }
    }

    private func send(_ url: URL, retryWithServerTime: Bool) async throws -> Data {
        guard credentials.isComplete else { throw PodcastIndexError.missingCredentials }
        // Während diese Anfrage läuft, kann eine andere den Abstand schon
        // berichtigt haben. Verglichen wird mit dem, womit hier signiert wurde.
        let usedOffset = clockOffset
        let headers = PodcastIndexSignature.headers(for: credentials, at: clock().addingTimeInterval(usedOffset),
                                                    userAgent: userAgent)
        let response: CatalogHTTPResponse
        do {
            response = try await transport(url, headers)
        } catch let error as PodcastIndexError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch HTTPTransferError.tooLarge {
            throw PodcastIndexError.unreadableAnswer
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw PodcastIndexError.unreachable
        }
        switch response.status {
        case 200..<300:
            return response.body
        case 401, 403:
            // Der Text des Fehlers kommt als Klartext. Häufigster Grund bei
            // gültigem Schlüssel: die Uhr des Geräts. Einmal mit der Zeit des
            // Servers nachrechnen, und nur, wenn sie deutlich abweicht.
            if retryWithServerTime, let serverDate = response.serverDate {
                let offset = serverDate.timeIntervalSince(clock())
                if abs(offset - usedOffset) > 60 {
                    clockOffset = offset
                    return try await send(url, retryWithServerTime: false)
                }
            }
            throw PodcastIndexError.unauthorized
        case 404:
            throw PodcastIndexError.notFound
        case 429:
            throw PodcastIndexError.rateLimited
        default:
            throw PodcastIndexError.serverStatus(response.status)
        }
    }

    /// `Tue, 23 Sep 2026 12:58:57 GMT`
    static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: Umwandeln

    /// `nil` für aufgegebene Feeds, für Feeds ohne gültige Adresse und für
    /// alles, was kein Podcast ist.
    static func podcast(from feed: PodcastIndexFeed) -> CatalogPodcast? {
        guard feed.dead != true,
              let feedURL = CatalogText.feedURL(feed.url),
              let title = CatalogText.line(feed.title) else { return nil }
        if let medium = feed.medium?.lowercased(), !medium.isEmpty, !podcastMedia.contains(medium) {
            return nil
        }
        let newest = feed.newestItemPubdate ?? feed.newestItemPublishTime
        return CatalogPodcast(
            origin: .podcastIndex,
            podcastIndexID: feed.id,
            itunesID: feed.itunesId.flatMap { $0 > 0 ? $0 : nil },
            podcastGUID: feed.podcastGuid.flatMap { $0.isEmpty ? nil : $0 },
            title: title,
            author: CatalogText.line(feed.author) ?? CatalogText.line(feed.ownerName) ?? "",
            feedURL: feedURL,
            originalFeedURL: CatalogText.feedURL(feed.originalUrl).flatMap { $0 == feedURL ? nil : $0 },
            websiteURL: CatalogText.safeURL(feed.link),
            artworkURL: CatalogText.safeURL(feed.artwork) ?? CatalogText.safeURL(feed.image),
            summary: CatalogText.plain(feed.description),
            language: feed.language.flatMap { $0.isEmpty ? nil : $0 },
            categoryIDs: feed.categoryIDs,
            isExplicit: feed.explicit ?? false,
            episodeCount: feed.episodeCount,
            newestEpisodeDate: newest.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        )
    }

    static func episode(from item: PodcastIndexEpisode) -> CatalogEpisode? {
        guard let id = item.id, let title = CatalogText.line(item.title) else { return nil }
        return CatalogEpisode(
            id: id, title: title,
            publishedAt: item.datePublished.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            duration: item.duration.flatMap { $0 > 0 ? $0 : nil },
            isExplicit: item.explicit ?? false,
            season: item.season.flatMap { $0 > 0 ? $0 : nil },
            episodeNumber: item.episode.flatMap { $0 > 0 ? $0 : nil },
            episodeType: item.episodeType
        )
    }
}

// MARK: - Antworten der API

/// Die API ist in PHP geschrieben und nicht immer gleich: Zahlen kommen
/// auch als Text, Wahrheitswerte als 0 und 1, eine leere Liste von
/// Kategorien als `[]` statt `{}`. Gelesen wird deshalb nachsichtig, und ein
/// kaputter Eintrag kostet nur sich selbst.
struct FeedsEnvelope: Decodable {
    let feeds: [PodcastIndexFeed]
    enum CodingKeys: String, CodingKey { case feeds }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = (try? container.decode(Lossy<PodcastIndexFeed>.self, forKey: .feeds))?.elements ?? []
    }
}

struct FeedEnvelope: Decodable {
    let feed: PodcastIndexFeed?
    enum CodingKeys: String, CodingKey { case feed }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unbekannte Kennung: `"feed": []`.
        feed = try? container.decode(PodcastIndexFeed.self, forKey: .feed)
    }
}

struct ItemsEnvelope: Decodable {
    let items: [PodcastIndexEpisode]
    enum CodingKeys: String, CodingKey { case items }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode(Lossy<PodcastIndexEpisode>.self, forKey: .items))?.elements ?? []
    }
}

struct PodcastIndexFeed: Decodable {
    var id: Int?
    var podcastGuid: String?
    var title: String?
    var url: String?
    var originalUrl: String?
    var link: String?
    var description: String?
    var author: String?
    var ownerName: String?
    var image: String?
    var artwork: String?
    var language: String?
    var categoryIDs: [Int] = []
    var explicit: Bool?
    var episodeCount: Int?
    var newestItemPubdate: Int?
    var newestItemPublishTime: Int?
    var itunesId: Int?
    var dead: Bool?
    var medium: String?
    var trendScore: Int?

    enum CodingKeys: String, CodingKey {
        case id, podcastGuid, title, url, originalUrl, link, description, author, ownerName, image, artwork
        case language, categories, explicit, episodeCount, newestItemPubdate, newestItemPublishTime
        case itunesId, dead, medium, trendScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        podcastGuid = c.lenientString(.podcastGuid)
        title = c.lenientString(.title)
        url = c.lenientString(.url)
        originalUrl = c.lenientString(.originalUrl)
        link = c.lenientString(.link)
        description = c.lenientString(.description)
        author = c.lenientString(.author)
        ownerName = c.lenientString(.ownerName)
        image = c.lenientString(.image)
        artwork = c.lenientString(.artwork)
        language = c.lenientString(.language)
        explicit = c.lenientBool(.explicit)
        episodeCount = c.lenientInt(.episodeCount)
        newestItemPubdate = c.lenientInt(.newestItemPubdate)
        newestItemPublishTime = c.lenientInt(.newestItemPublishTime)
        itunesId = c.lenientInt(.itunesId)
        dead = c.lenientBool(.dead)
        medium = c.lenientString(.medium)
        trendScore = c.lenientInt(.trendScore)
        // `{"104": "Tv", "105": "Film"}`: die Schlüssel sind Text.
        if let categories = try? c.decode([String: String?].self, forKey: .categories) {
            categoryIDs = categories.keys.compactMap { Int($0) }.sorted()
        }
    }
}

struct PodcastIndexEpisode: Decodable {
    var id: Int?
    var title: String?
    var datePublished: Int?
    var duration: Int?
    var explicit: Bool?
    var episode: Int?
    var season: Int?
    var episodeType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, datePublished, duration, explicit, episode, season, episodeType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id)
        title = c.lenientString(.title)
        datePublished = c.lenientInt(.datePublished)
        duration = c.lenientInt(.duration)
        explicit = c.lenientBool(.explicit)
        episode = c.lenientInt(.episode)
        season = c.lenientInt(.season)
        episodeType = c.lenientString(.episodeType)
    }
}

/// Eine Liste, in der ein unlesbarer Eintrag übersprungen wird, statt die
/// ganze Antwort zu verwerfen.
struct Lossy<Element: Decodable>: Decodable {
    let elements: [Element]

    /// Nimmt jeden Wert an und liest nichts daraus, damit es weitergeht.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skip.self)) == nil, (try? container.decodeNil()) != true {
                break
            }
        }
        self.elements = elements
    }
}

extension KeyedDecodingContainer {
    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           abs(value) < 9e15 { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespaces))
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        }
        return nil
    }

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

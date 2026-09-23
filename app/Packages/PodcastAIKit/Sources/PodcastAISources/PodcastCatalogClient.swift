//
//  PodcastCatalogClient.swift
//  PodcastAISources
//
//  Der Podcast-Katalog der App, ganz ohne Schlüssel und ohne Konto:
//  Charts und Rubriken aus Apple Podcasts, gesucht wird bei Apple und bei
//  Podcast Index zugleich.
//
//  Die Quellen:
//
//  - Charts eines Landes:
//    `rss.marketingtools.apple.com/api/v2/{land}/podcasts/top/{n}/podcasts.json`,
//    höchstens 100 Einträge (bei 200 antwortet der Server mit 500).
//  - Charts einer Rubrik:
//    `itunes.apple.com/{land}/rss/toppodcasts/limit={n}/genre={id}/json`,
//    höchstens 200 Einträge.
//  - Einzelheiten zu bis zu 100 Kennungen auf einmal:
//    `itunes.apple.com/lookup?id=…&entity=podcast&country={land}`.
//  - Suche: `itunes.apple.com/search` und `api.podcastindex.org/search`.
//    Podcast Index antwortet dort in derselben Form wie Apple, ohne
//    Schlüssel, verlangt aber einen User-Agent, der die App nennt.
//
//  Die Charts nennen nur Kennung, Name, Anbieter und ein kleines Bild.
//  Feed-Adresse, großes Cover, Zahl der Folgen und Datum der neuesten holt
//  eine Abfrage je Seite. Charts und Einzelheiten hält der Client eine
//  Viertelstunde.
//
//  Das Land kommt aus der Region des Geräts, nicht aus der Sprache der App.
//  Führt Apple das Land nicht, fragt der Client in den USA nach.
//

import Foundation
import PodcastAICore

// MARK: - Fehler

public enum CatalogError: Error, LocalizedError, Equatable, Sendable {
    case rateLimited
    case serverStatus(Int)
    case unreachable
    case unreadableAnswer

    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            String(localized: """
                Der Podcast-Katalog bekommt gerade zu viele Anfragen. In einer Minute noch einmal versuchen.
                """, bundle: .module)
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

/// Status und Inhalt einer Antwort.
public struct CatalogHTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Holt eine Adresse mit Kopfzeilen. Im Betrieb über `SafeHTTP`, in Tests
/// und UI-Tests aus festen Antworten.
public typealias CatalogTransport = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> CatalogHTTPResponse

// MARK: - Land

/// Das Land, dessen Charts und Verzeichnis der Katalog zeigt.
public enum CatalogStorefront {

    /// Wenn das Gerät keine Region nennt oder Apple sie nicht führt.
    public static let fallback = "us"

    /// Zwei Buchstaben in Kleinschrift, etwa „de“ für „DE“. Regionen wie
    /// „001“ (Welt) oder „150“ (Europa) haben keine Charts.
    public static func country(forRegion identifier: String?) -> String {
        guard let identifier, identifier.count == 2,
              identifier.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else {
            return fallback
        }
        return identifier.lowercased()
    }

    /// Aus der Region des Geräts. Die Sprache der App spielt keine Rolle:
    /// wer Englisch eingestellt hat und in Deutschland wohnt, sieht die
    /// deutschen Charts.
    public static var current: String { country(forRegion: Locale.current.region?.identifier) }
}

// MARK: - Charts

/// Welche Charts: die eines Landes oder die einer Rubrik darin.
public enum CatalogChart: Hashable, Sendable {
    case top
    case genre(CatalogCategory)

    /// So viele Einträge liefert Apple höchstens.
    public var limit: Int {
        switch self {
        case .top: 100
        case .genre: 200
        }
    }
}

/// Ein Platz in den Charts, wie Apple ihn nennt. Ohne Feed-Adresse, die
/// kommt erst mit den Einzelheiten.
public struct CatalogChartEntry: Sendable, Hashable {
    public let itunesID: Int
    public let title: String
    public let author: String
    public let artworkURL: URL?
    public let genreIDs: [Int]
    public let genres: [String]
    public let summary: String?
}

/// Eine Seite aus den Charts.
public struct CatalogPage: Sendable {
    /// In der Reihenfolge der Charts. Wer keine Feed-Adresse hat, fehlt:
    /// abonnieren ließe er sich nicht.
    public let podcasts: [CatalogPodcast]
    /// Wo die nächste Seite beginnt. `nil` am Ende der Charts.
    public let nextOffset: Int?
    /// Wie viele Plätze die Charts haben.
    public let total: Int
    /// Das Land, aus dem die Charts kamen. Weicht vom Gerät ab, wenn Apple
    /// dessen Land nicht führt.
    public let country: String
}

// MARK: - Client

public actor PodcastCatalogClient {

    public static let cacheLifetime: TimeInterval = 15 * 60
    /// Charts aus den USA statt aus dem Land des Geräts hält der Client nur
    /// kurz. War der Grund ein vorübergehender Fehler, kommen bald wieder
    /// die richtigen.
    public static let fallbackCacheLifetime: TimeInterval = 60
    /// So viele Kennungen nimmt `lookup` auf einmal.
    public static let lookupBatchSize = 100
    /// Treffer je Suchdienst.
    public static let searchLimit = 30
    /// Obergrenze je Antwort. 200 Plätze einer Rubrik mit Beschreibung sind
    /// etwa 400 KB, 100 Einzelheiten etwa 170 KB.
    public static let responseLimit: Int64 = 4 * 1024 * 1024
    /// So antwortet Apple, wenn es ein Land nicht führt: 400 bei Suche und
    /// Einzelheiten, 500 bei den Charts eines Landes.
    static let storefrontMissingStatuses: Set<Int> = [400, 404, 500]
    /// Bei der Suche heißt 500 nur, dass Apple gerade klemmt.
    static let searchStorefrontMissingStatuses: Set<Int> = [400, 404]

    public nonisolated let country: String
    private let userAgent: String
    private let transport: CatalogTransport
    private let clock: @Sendable () -> Date

    private var charts: [CatalogChart: (at: Date, country: String, entries: [CatalogChartEntry])] = [:]
    /// Einzelheiten je Land und Kennung. `nil` heißt: Apple kennt zu der
    /// Kennung keinen Feed.
    private var details: [String: (at: Date, podcast: CatalogPodcast?)] = [:]

    public init(country: String = CatalogStorefront.current, userAgent: String,
                transport: @escaping CatalogTransport = PodcastCatalogClient.liveTransport(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.country = CatalogStorefront.country(forRegion: country)
        self.userAgent = userAgent
        self.transport = transport
        self.clock = clock
    }

    /// Über `SafeHTTP`: Adressprüfung, keine Cookies, Obergrenze beim Laden.
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
            return CatalogHTTPResponse(status: response.statusCode, body: data)
        }
    }

    // MARK: Charts

    /// `count` Plätze der Charts ab `offset`, mit Feed-Adresse und großem
    /// Cover. Die Charts selbst holt der Client einmal, die Einzelheiten
    /// mit einer Abfrage je Seite.
    public func page(of chart: CatalogChart, offset: Int, count: Int) async throws -> CatalogPage {
        let (country, entries) = try await chartEntries(chart)
        let start = min(max(offset, 0), entries.count)
        let end = min(start + max(count, 0), entries.count)
        let slice = entries[start..<end]
        let found = try await lookup(slice.map(\.itunesID), country: country)
        // Zwei Plätze können auf denselben Feed zeigen. Die Seite zählt
        // Podcasts, der höhere Platz bleibt.
        var feeds = Set<String>()
        let podcasts = slice
            .compactMap { entry in found[entry.itunesID].map { Self.combined($0, with: entry) } }
            .filter { feeds.insert(CatalogMerge.feedKey($0.feedURL)).inserted }
        return CatalogPage(podcasts: podcasts, nextOffset: end < entries.count ? end : nil,
                           total: entries.count, country: country)
    }

    func chartEntries(_ chart: CatalogChart) async throws -> (country: String, entries: [CatalogChartEntry]) {
        if let cached = charts[chart] {
            let lifetime = cached.country == self.country ? Self.cacheLifetime : Self.fallbackCacheLifetime
            if clock().timeIntervalSince(cached.at) < lifetime { return (cached.country, cached.entries) }
        }
        var (country, body) = try await fetchInStorefront { Self.chartURL(chart, country: $0) }
        var entries = try Self.decodeChart(chart, body)
        // Manche Länder haben Charts, aber keine der Rubriken: Apple
        // antwortet dann mit 200 und ohne Einträge.
        if entries.isEmpty, country != CatalogStorefront.fallback,
           let url = Self.chartURL(chart, country: CatalogStorefront.fallback) {
            country = CatalogStorefront.fallback
            body = try await fetch(url)
            entries = try Self.decodeChart(chart, body)
        }
        charts[chart] = (clock(), country, entries)
        return (country, entries)
    }

    /// Einzelheiten zu Kennungen aus den Charts, in Stapeln zu höchstens
    /// 100. Schon bekannte fragt der Client nicht noch einmal.
    func lookup(_ ids: [Int], country: String) async throws -> [Int: CatalogPodcast] {
        var result: [Int: CatalogPodcast] = [:]
        var missing: [Int] = []
        var seen = Set<Int>()
        let now = clock()
        for id in ids where seen.insert(id).inserted {
            if let cached = details["\(country)|\(id)"], now.timeIntervalSince(cached.at) < Self.cacheLifetime {
                if let podcast = cached.podcast { result[id] = podcast }
            } else {
                missing.append(id)
            }
        }
        for batch in Self.batches(missing, size: Self.lookupBatchSize) {
            guard let url = Self.lookupURL(batch, country: country) else { throw CatalogError.unreadableAnswer }
            // Apple ordnet die Antwort nicht nach der Anfrage und lässt
            // Unbekanntes einfach weg. Zugeordnet wird über die Kennung.
            var byID: [Int: CatalogPodcast] = [:]
            for podcast in try Self.decodeResults(try await fetch(url), origin: .appleDirectory) {
                if let id = podcast.itunesID, byID[id] == nil { byID[id] = podcast }
            }
            let at = clock()
            for id in batch {
                details["\(country)|\(id)"] = (at, byID[id])
                if let podcast = byID[id] { result[id] = podcast }
            }
        }
        return result
    }

    /// Teilt Kennungen in Stapel für `lookup`.
    static func batches(_ ids: [Int], size: Int) -> [[Int]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// Die Einzelheiten zuerst, was dort fehlt, aus den Charts.
    static func combined(_ detail: CatalogPodcast, with entry: CatalogChartEntry) -> CatalogPodcast {
        var podcast = detail
        if podcast.artworkURL == nil { podcast.artworkURL = entry.artworkURL }
        if podcast.summary == nil { podcast.summary = entry.summary }
        if podcast.genres.isEmpty { podcast.genres = entry.genres }
        if podcast.genreIDs.isEmpty { podcast.genreIDs = entry.genreIDs }
        if podcast.author.isEmpty { podcast.author = entry.author }
        return podcast
    }

    // MARK: Suche

    /// Sucht bei Apple und bei Podcast Index zugleich und führt die Treffer
    /// zusammen. Antwortet nur einer von beiden, zählt dessen Liste.
    public func search(_ term: String) async throws -> [CatalogPodcast] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return [] }
        async let apple = Self.outcome { try await self.searchApple(term) }
        async let index = Self.outcome { try await self.searchPodcastIndex(term) }
        let (fromApple, fromIndex) = await (apple, index)
        try Task.checkCancellation()
        switch (fromApple, fromIndex) {
        case (.success(let listed), .success(let found)):
            return CatalogMerge.merged(listed, found)
        case (.success(let listed), .failure):
            return listed
        case (.failure, .success(let found)):
            return found
        case (.failure(let error), .failure):
            throw error
        }
    }

    func searchApple(_ term: String) async throws -> [CatalogPodcast] {
        let (_, body) = try await fetchInStorefront(missing: Self.searchStorefrontMissingStatuses) {
            Self.appleSearchURL(term, country: $0)
        }
        // Derselbe Feed kann zweimal im Verzeichnis stehen.
        return CatalogMerge.merged(try Self.decodeResults(body, origin: .appleDirectory), [])
    }

    func searchPodcastIndex(_ term: String) async throws -> [CatalogPodcast] {
        guard let url = Self.podcastIndexSearchURL(term) else { throw CatalogError.unreadableAnswer }
        let found = try Self.decodeResults(try await fetch(url), origin: .podcastIndex)
        return Array(CatalogMerge.merged(found, []).prefix(Self.searchLimit))
    }

    private nonisolated static func outcome<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: Adressen

    static func chartURL(_ chart: CatalogChart, country: String) -> URL? {
        switch chart {
        case .top:
            URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(chart.limit)/podcasts.json")
        case .genre(let category):
            URL(string: "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(chart.limit)/genre=\(category.genreID)/json")
        }
    }

    static func lookupURL(_ ids: [Int], country: String) -> URL? {
        url("https://itunes.apple.com/lookup", [
            URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "country", value: country),
        ])
    }

    static func appleSearchURL(_ term: String, country: String) -> URL? {
        url("https://itunes.apple.com/search", [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(searchLimit)),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "term", value: term),
        ])
    }

    static func podcastIndexSearchURL(_ term: String) -> URL? {
        url("https://api.podcastindex.org/search", [URLQueryItem(name: "term", value: term)])
    }

    static func url(_ base: String, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        // `URLComponents` lässt „+“ stehen, die Server lesen es als Leerzeichen.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: Übertragung und Fehler

    /// Erst im Land des Geräts. Führt Apple es nicht, noch einmal in den USA.
    private func fetchInStorefront(missing: Set<Int> = storefrontMissingStatuses,
                                   _ url: (String) -> URL?) async throws -> (country: String, body: Data) {
        guard let first = url(country) else { throw CatalogError.unreadableAnswer }
        do {
            return (country, try await fetch(first))
        } catch CatalogError.serverStatus(let status)
                    where missing.contains(status) && country != CatalogStorefront.fallback {
            guard let second = url(CatalogStorefront.fallback) else { throw CatalogError.serverStatus(status) }
            return (CatalogStorefront.fallback, try await fetch(second))
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let response: CatalogHTTPResponse
        do {
            response = try await transport(url, ["User-Agent": userAgent])
        } catch let error as CatalogError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch HTTPTransferError.tooLarge {
            throw CatalogError.unreadableAnswer
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw CatalogError.unreachable
        }
        switch response.status {
        case 200..<300:
            return response.body
        case 403, 429:
            // Apple drosselt zu schnelle Suchen mit 403.
            throw CatalogError.rateLimited
        default:
            throw CatalogError.serverStatus(response.status)
        }
    }

    // MARK: Antworten lesen

    static func decodeChart(_ chart: CatalogChart, _ data: Data) throws -> [CatalogChartEntry] {
        let entries: [CatalogChartEntry]
        do {
            switch chart {
            case .top:
                entries = try JSONDecoder().decode(TopChartResponse.self, from: data).results.compactMap(\.entry)
            case .genre:
                entries = try JSONDecoder().decode(GenreChartResponse.self, from: data).entries.compactMap(\.entry)
            }
        } catch {
            throw CatalogError.unreadableAnswer
        }
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.itunesID).inserted }
    }

    /// Suche bei Apple, Suche bei Podcast Index und Einzelheiten haben
    /// dieselbe Form.
    static func decodeResults(_ data: Data, origin: CatalogPodcast.Origin) throws -> [CatalogPodcast] {
        do {
            return try JSONDecoder().decode(DirectoryResponse.self, from: data).results
                .compactMap { podcast(from: $0, origin: origin) }
        } catch {
            throw CatalogError.unreadableAnswer
        }
    }

    /// `nil` ohne gültige Feed-Adresse oder ohne Titel, und für alles, was
    /// kein Podcast ist.
    static func podcast(from result: DirectoryResult, origin: CatalogPodcast.Origin) -> CatalogPodcast? {
        guard let feedURL = CatalogText.feedURL(result.feedUrl),
              let title = CatalogText.line(result.collectionName) else { return nil }
        if let kind = result.kind, !kind.isEmpty, kind != "podcast" { return nil }
        // Namen und Kennungen der Rubriken stehen paarweise, „Podcasts“
        // (26) gehört zu jedem Podcast und fällt weg.
        var genreIDs: [Int] = []
        var genres: [String] = []
        if result.genreIds.count == result.genres.count {
            for (id, name) in zip(result.genreIds, result.genres) where id != CatalogCategory.podcastsGenreID {
                genreIDs.append(id)
                if let name = CatalogText.line(name) { genres.append(name) }
            }
        } else {
            genreIDs = result.genreIds.filter { $0 != CatalogCategory.podcastsGenreID }
            genres = result.genres.compactMap(CatalogText.line).filter { $0 != "Podcasts" }
        }
        // Bei Podcast Index zählt die Kennung nur, wenn sie auf Apple
        // Podcasts zeigt. Sonst könnte sie eine eigene sein und zwei
        // verschiedene Podcasts zusammenlegen.
        var itunesID = result.collectionId.flatMap { $0 > 0 ? $0 : nil }
        if origin == .podcastIndex, !Self.pointsToApple(result.collectionViewUrl) { itunesID = nil }
        return CatalogPodcast(
            origin: origin, itunesID: itunesID, title: title,
            author: CatalogText.line(result.artistName) ?? "",
            feedURL: feedURL,
            artworkURL: CatalogText.safeURL(result.artworkUrl600) ?? CatalogText.safeURL(result.artworkUrl100),
            genre: CatalogText.line(result.primaryGenreName),
            genres: genres, genreIDs: genreIDs,
            isExplicit: result.collectionExplicitness == "explicit" || result.contentAdvisoryRating == "Explicit",
            episodeCount: result.trackCount.flatMap { $0 > 0 ? $0 : nil },
            // Podcast Index schreibt bei der Suche die Zeit der Anfrage in
            // `releaseDate`, nicht die der neuesten Folge.
            newestEpisodeDate: origin == .podcastIndex
                ? nil : result.releaseDate.flatMap { try? Date($0, strategy: .iso8601) })
    }

    private static func pointsToApple(_ link: String?) -> Bool {
        guard let host = link.flatMap(URL.init(string:))?.host()?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }
}

// MARK: - Antworten der Dienste

/// Charts eines Landes: `feed.results[]`.
struct TopChartResponse: Decodable {
    let results: [Result]

    private enum CodingKeys: String, CodingKey { case feed }
    private enum FeedKeys: String, CodingKey { case results }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let feed = try container.nestedContainer(keyedBy: FeedKeys.self, forKey: .feed)
        results = (try? feed.decode(Lossy<Result>.self, forKey: .results))?.elements ?? []
    }

    struct Result: Decodable {
        var id: Int?
        var name: String?
        var artistName: String?
        var artworkUrl100: String?
        var genres: [Genre] = []

        struct Genre: Decodable {
            var genreId: Int?
            var name: String?
            enum CodingKeys: String, CodingKey { case genreId, name }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                genreId = c.lenientInt(.genreId)
                name = c.lenientString(.name)
            }
        }

        enum CodingKeys: String, CodingKey { case id, name, artistName, artworkUrl100, genres }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenientInt(.id)
            name = c.lenientString(.name)
            artistName = c.lenientString(.artistName)
            artworkUrl100 = c.lenientString(.artworkUrl100)
            genres = (try? c.decode(Lossy<Genre>.self, forKey: .genres))?.elements ?? []
        }

        var entry: CatalogChartEntry? {
            guard let id, id > 0, let title = CatalogText.line(name) else { return nil }
            let named = genres.filter { $0.genreId != CatalogCategory.podcastsGenreID }
            return CatalogChartEntry(itunesID: id, title: title, author: CatalogText.line(artistName) ?? "",
                                     artworkURL: CatalogText.safeURL(artworkUrl100),
                                     genreIDs: named.compactMap(\.genreId),
                                     genres: named.compactMap { CatalogText.line($0.name) },
                                     summary: nil)
        }
    }
}

/// Charts einer Rubrik im alten RSS-Format: `feed.entry[]`. Bei einem
/// einzigen Platz ist `entry` ein Objekt statt einer Liste, bei keinem
/// fehlt es.
struct GenreChartResponse: Decodable {
    let entries: [Entry]

    private enum CodingKeys: String, CodingKey { case feed }
    private enum FeedKeys: String, CodingKey { case entry }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let feed = try container.nestedContainer(keyedBy: FeedKeys.self, forKey: .feed)
        if let list = try? feed.decode(Lossy<Entry>.self, forKey: .entry) {
            entries = list.elements
        } else if let single = try? feed.decode(Entry.self, forKey: .entry) {
            entries = [single]
        } else {
            entries = []
        }
    }

    /// `{"label": "…", "attributes": {…}}`, die Form jedes Felds hier.
    struct Labeled: Decodable {
        var label: String?
        var attributes: [String: String] = [:]
        enum CodingKeys: String, CodingKey { case label, attributes }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = c.lenientString(.label)
            attributes = (try? c.decode([String: String].self, forKey: .attributes)) ?? [:]
        }
    }

    struct Entry: Decodable {
        var name: Labeled?
        var images: [Labeled] = []
        var id: Labeled?
        var artist: Labeled?
        var category: Labeled?
        var summary: Labeled?

        enum CodingKeys: String, CodingKey {
            case name = "im:name", images = "im:image", id, artist = "im:artist", category, summary
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decode(Labeled.self, forKey: .name)
            images = (try? c.decode(Lossy<Labeled>.self, forKey: .images))?.elements ?? []
            id = try? c.decode(Labeled.self, forKey: .id)
            artist = try? c.decode(Labeled.self, forKey: .artist)
            category = try? c.decode(Labeled.self, forKey: .category)
            summary = try? c.decode(Labeled.self, forKey: .summary)
        }

        var entry: CatalogChartEntry? {
            guard let itunesID = id?.attributes["im:id"].flatMap({ Int($0) }), itunesID > 0,
                  let title = CatalogText.line(name?.label) else { return nil }
            // Das größte Bild. Apple nennt die Höhe als Text.
            let largest = images.max { (Int($0.attributes["height"] ?? "") ?? 0) < (Int($1.attributes["height"] ?? "") ?? 0) }
            let genreID = category?.attributes["im:id"].flatMap { Int($0) }
            let genreName = CatalogText.line(category?.attributes["label"])
            return CatalogChartEntry(itunesID: itunesID, title: title, author: CatalogText.line(artist?.label) ?? "",
                                     artworkURL: CatalogText.safeURL(largest?.label),
                                     genreIDs: genreID.map { [$0] } ?? [],
                                     genres: genreName.map { [$0] } ?? [],
                                     summary: CatalogText.plain(summary?.label))
        }
    }
}

/// Suche bei Apple, Suche bei Podcast Index und Einzelheiten: `results[]`.
struct DirectoryResponse: Decodable {
    let results: [DirectoryResult]
    enum CodingKeys: String, CodingKey { case results }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? container.decode(Lossy<DirectoryResult>.self, forKey: .results))?.elements ?? []
    }
}

struct DirectoryResult: Decodable {
    var kind: String?
    var collectionId: Int?
    var collectionName: String?
    var artistName: String?
    var feedUrl: String?
    var artworkUrl100: String?
    var artworkUrl600: String?
    var primaryGenreName: String?
    /// Apple schreibt die Kennungen als Text, Podcast Index als Zahlen.
    var genreIds: [Int] = []
    var genres: [String] = []
    var trackCount: Int?
    var releaseDate: String?
    var collectionExplicitness: String?
    var contentAdvisoryRating: String?
    var collectionViewUrl: String?

    enum CodingKeys: String, CodingKey {
        case kind, collectionId, collectionName, artistName, feedUrl, artworkUrl100, artworkUrl600
        case primaryGenreName, genreIds, genres, trackCount, releaseDate, collectionExplicitness
        case contentAdvisoryRating, collectionViewUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenientString(.kind)
        collectionId = c.lenientInt(.collectionId)
        collectionName = c.lenientString(.collectionName)
        artistName = c.lenientString(.artistName)
        feedUrl = c.lenientString(.feedUrl)
        artworkUrl100 = c.lenientString(.artworkUrl100)
        artworkUrl600 = c.lenientString(.artworkUrl600)
        primaryGenreName = c.lenientString(.primaryGenreName)
        genreIds = (try? c.decode(Lossy<LenientInt>.self, forKey: .genreIds))?.elements.map(\.value) ?? []
        genres = (try? c.decode(Lossy<String>.self, forKey: .genres))?.elements ?? []
        trackCount = c.lenientInt(.trackCount)
        releaseDate = c.lenientString(.releaseDate)
        collectionExplicitness = c.lenientString(.collectionExplicitness)
        contentAdvisoryRating = c.lenientString(.contentAdvisoryRating)
        collectionViewUrl = c.lenientString(.collectionViewUrl)
    }
}

// MARK: - Nachsichtig lesen

/// Eine Zahl, auch wenn sie als Text kommt.
struct LenientInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self),
                  let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "keine Zahl")
        }
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
        return nil
    }

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

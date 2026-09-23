//
//  CatalogTests.swift
//  PodcastAIKitTests
//
//  Der Podcast-Katalog ohne Schlüssel: Charts und Rubriken aus Apple
//  Podcasts, Einzelheiten in Stapeln, Suche bei Apple und Podcast Index,
//  Zwischenspeicher, Land und Zusammenführen der Treffer.
//  Kein Test geht ins Netz; die Antworten kommen aus festen Texten.
//

import Foundation
import Synchronization
import Testing
import PodcastAIKit
@testable import PodcastAISources
#if canImport(AppKit)
import AppKit
#endif

/// Merkt sich jede Anfrage, die der Client stellt.
private actor Recorder {
    private(set) var calls: [(url: URL, headers: [String: String])] = []
    func record(_ url: URL, _ headers: [String: String]) { calls.append((url, headers)) }
    var urls: [URL] { calls.map(\.url) }
}

/// Hält Anfragen an, bis `count` von ihnen da sind, und lässt dann alle
/// zugleich weiter.
private actor Gate {
    private let count: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(count: Int) { self.count = count }

    func arrive() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == count {
                waiting.forEach { $0.resume() }
                waiting.removeAll()
            }
        }
    }
}

/// Eine Uhr, die der Test vorstellt.
private final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_790_140_000))
    var now: Date { time.withLock { $0 } }
    func advance(by seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private func client(
    country: String = "de",
    _ transport: @escaping CatalogTransport = CatalogFixtures.transport,
    clock: TestClock = TestClock()
) -> PodcastCatalogClient {
    PodcastCatalogClient(country: country, userAgent: "PodcastAI/0.7.2", transport: transport,
                         clock: { clock.now })
}

/// Der Transport der Fixtures, der jede Anfrage aufschreibt.
private func recording(_ recorder: Recorder,
                       _ transport: @escaping CatalogTransport = CatalogFixtures.transport) -> CatalogTransport {
    { url, headers in
        await recorder.record(url, headers)
        return try await transport(url, headers)
    }
}

private func query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

private func json(_ text: String) -> Data { Data(text.utf8) }

// MARK: - Antworten lesen

@Suite("Katalog: Antworten lesen")
struct CatalogDecodingTests {

    @Test("Charts eines Landes: Kennung als Text, Rubrik, kaputte Einträge übersprungen")
    func topChart() throws {
        let body = json(#"""
        {"feed": {"title": "Top-Podcasts", "country": "de", "results": [
          {"artistName": "Paul Ronzheimer", "id": "1700432142", "name": "RONZHEIMER.", "kind": "podcasts",
           "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Podcasts116/v4/16/ab/81/x.jpg/100x100bb.png",
           "genres": [{"genreId": "1489", "name": "Nachrichten", "url": "https://itunes.apple.com/de/genre/id1489"}],
           "url": "https://podcasts.apple.com/de/podcast/ronzheimer/id1700432142"},
          {"artistName": "Ohne Kennung", "name": "Kaputt"},
          17,
          {"artistName": "Beispiel", "id": 1413425371, "name": "Mord &amp; Lust",
           "artworkUrl100": "http://example.com/a.png", "genres": [{"genreId": "26", "name": "Podcasts"}]}
        ]}}
        """#)
        let entries = try PodcastCatalogClient.decodeChart(.top, body)
        #expect(entries.map(\.itunesID) == [1_700_432_142, 1_413_425_371])
        let first = try #require(entries.first)
        #expect(first.title == "RONZHEIMER.")
        #expect(first.author == "Paul Ronzheimer")
        #expect(first.genreIDs == [1489])
        #expect(first.genres == ["Nachrichten"])
        #expect(first.artworkURL?.host() == "is1-ssl.mzstatic.com")
        // „Podcasts“ fällt weg, http wird https, Entitäten werden Text.
        #expect(entries[1].genreIDs.isEmpty)
        #expect(entries[1].title == "Mord & Lust")
        #expect(entries[1].artworkURL?.absoluteString == "https://example.com/a.png")
    }

    @Test("Charts einer Rubrik: Liste, einzelnes Objekt oder gar kein Eintrag")
    func genreChart() throws {
        let entry = #"""
        {"im:name": {"label": "Mordlust"},
         "im:image": [{"label": "https://example.com/55x55bb.png", "attributes": {"height": "55"}},
                      {"label": "https://example.com/170x170bb.png", "attributes": {"height": "170"}},
                      {"label": "https://example.com/60x60bb.png", "attributes": {"height": "60"}}],
         "summary": {"label": "Wahre Fälle &amp; Hintergründe.\n\nJede Woche neu."},
         "id": {"label": "https://podcasts.apple.com/de/podcast/mordlust/id1413425371?uo=2",
                "attributes": {"im:id": "1413425371"}},
         "im:artist": {"label": "Paulina Krasa & Laura Wohlers"},
         "category": {"attributes": {"im:id": "1488", "term": "True Crime", "label": "Wahre Kriminalfälle"}},
         "im:releaseDate": {"label": "2026-09-22T20:00:00-07:00"}}
        """#
        let list = try PodcastCatalogClient.decodeChart(.genre(.trueCrime),
                                                        json(#"{"feed": {"entry": [\#(entry), {"im:name": {"label": "Ohne Kennung"}}]}}"#))
        #expect(list.count == 1)
        let first = try #require(list.first)
        #expect(first.itunesID == 1_413_425_371)
        #expect(first.author == "Paulina Krasa & Laura Wohlers")
        #expect(first.artworkURL?.absoluteString == "https://example.com/170x170bb.png")
        #expect(first.genreIDs == [1488])
        #expect(first.genres == ["Wahre Kriminalfälle"])
        #expect(first.summary == "Wahre Fälle & Hintergründe.\n\nJede Woche neu.")

        let single = try PodcastCatalogClient.decodeChart(.genre(.trueCrime), json(#"{"feed": {"entry": \#(entry)}}"#))
        #expect(single.map(\.title) == ["Mordlust"])
        let none = try PodcastCatalogClient.decodeChart(.genre(.politics), json(#"{"feed": {"title": {"label": "leer"}}}"#))
        #expect(none.isEmpty)
    }

    @Test("Einzelheiten und Apples Suche: Feed, großes Cover, Rubriken ohne „Podcasts“")
    func lookup() throws {
        let body = json(#"""
        {"resultCount": 4, "results": [
          {"wrapperType": "track", "kind": "podcast", "collectionId": 1700432142, "trackId": 1700432142,
           "artistName": "Paul Ronzheimer", "collectionName": "RONZHEIMER.",
           "collectionViewUrl": "https://podcasts.apple.com/de/podcast/ronzheimer/id1700432142?uo=4",
           "feedUrl": "https://ronzheimer.podigee.io/feed/mp3",
           "artworkUrl100": "https://example.com/100x100bb.jpg", "artworkUrl600": "https://example.com/600x600bb.jpg",
           "releaseDate": "2026-09-22T02:00:00Z", "collectionExplicitness": "notExplicit", "trackCount": 834,
           "primaryGenreName": "Politik", "contentAdvisoryRating": "Clean",
           "genreIds": ["1527", "26", "1489", "1526"],
           "genres": ["Politik", "Podcasts", "Nachrichten", "Nachrichten des Tages"]},
          {"wrapperType": "track", "kind": "podcast", "collectionId": 1, "collectionName": "Ohne Feed"},
          {"wrapperType": "track", "kind": "podcast-episode", "collectionId": 2, "collectionName": "Eine Folge",
           "feedUrl": "https://example.com/folge.xml"},
          {"kind": "podcast", "collectionId": 3, "collectionName": "Lokal", "feedUrl": "http://127.0.0.1/feed.xml"}
        ]}
        """#)
        let podcasts = try PodcastCatalogClient.decodeResults(body, origin: .appleDirectory)
        #expect(podcasts.count == 1)
        let podcast = try #require(podcasts.first)
        #expect(podcast.itunesID == 1_700_432_142)
        #expect(podcast.feedURL.absoluteString == "https://ronzheimer.podigee.io/feed/mp3")
        #expect(podcast.artworkURL?.absoluteString == "https://example.com/600x600bb.jpg")
        #expect(podcast.genre == "Politik")
        #expect(podcast.genres == ["Politik", "Nachrichten", "Nachrichten des Tages"])
        #expect(podcast.genreIDs == [1527, 1489, 1526])
        #expect(podcast.categories == [.news])
        #expect(podcast.episodeCount == 834)
        #expect(podcast.newestEpisodeDate == Date(timeIntervalSince1970: 1_790_042_400))
        #expect(!podcast.isExplicit)
        #expect(podcast.origin == .appleDirectory)
    }

    @Test("Suche bei Podcast Index: Kennungen als Zahlen, Zeitzone ohne Doppelpunkt")
    func podcastIndexSearch() throws {
        let body = json(#"""
        {"resultCount": 2, "results": [
          {"wrapperType": "track", "kind": "podcast", "collectionId": 1594623221,
           "artistName": "Trail Talk", "collectionName": "Wanderwach &amp; Kaffee",
           "collectionViewUrl": "https://podcasts.apple.com/us/podcast/*/id1594623221?uo=4",
           "feedUrl": "https://rss.buzzsprout.com/1885272.rss",
           "artworkUrl600": "https://storage.buzzsprout.com/abc?.jpg",
           "releaseDate": "2026-09-23T15:51:20-0500", "collectionExplicitness": "explicit", "trackCount": 163,
           "primaryGenreName": "Sports", "genreIds": [1545, 1324, 1502, 26],
           "genres": ["Sports", "Society & Culture", "Leisure", "Podcasts"]},
          {"kind": "podcast", "collectionId": 7004512, "collectionName": "Nur im Index",
           "collectionViewUrl": "https://podcastindex.org/podcast/7004512",
           "feedUrl": "https://example.org/index.xml", "genreIds": [], "genres": []}
        ]}
        """#)
        let podcasts = try PodcastCatalogClient.decodeResults(body, origin: .podcastIndex)
        #expect(podcasts.map(\.title) == ["Wanderwach & Kaffee", "Nur im Index"])
        let first = podcasts[0]
        #expect(first.genreIDs == [1545, 1324, 1502])
        #expect(first.categories == [.sports, .society, .leisure])
        #expect(first.newestEpisodeDate == Date(timeIntervalSince1970: 1_790_196_680))
        #expect(first.isExplicit)
        #expect(first.itunesID == 1_594_623_221)
        // Die Kennung zeigt nicht auf Apple Podcasts und gilt nicht als Apple-Kennung.
        #expect(podcasts[1].itunesID == nil)
    }

    @Test("Unlesbares wird zu einem eigenen Fehler")
    func unreadable() {
        #expect(throws: CatalogError.unreadableAnswer) { try PodcastCatalogClient.decodeChart(.top, json("<html>")) }
        #expect(throws: CatalogError.unreadableAnswer) { try PodcastCatalogClient.decodeChart(.top, json(#"{"results": []}"#)) }
        #expect(throws: CatalogError.unreadableAnswer) {
            try PodcastCatalogClient.decodeResults(json("nicht json"), origin: .appleDirectory)
        }
        #expect((try? PodcastCatalogClient.decodeResults(json(#"{"resultCount": 0}"#), origin: .appleDirectory))?.isEmpty == true)
    }

    @Test("HTML wird zu Text, Adressen werden geprüft")
    func plainText() {
        #expect(CatalogText.plain("Erste Zeile<br>zweite &amp;lt;b&amp;gt; &#228; &#x2014; ok<script>alert(1)</script>")
                == "Erste Zeile\nzweite &lt;b&gt; ä — ok")
        #expect(CatalogText.plain("<ul><li>eins</li><li>zwei</li></ul>") == "• eins\n• zwei")
        #expect(CatalogText.plain("   <p> </p> ") == nil)
        #expect(CatalogText.plain("&Ouml;sterreich &Uuml;ber &Auml;rger &auml;h") == "Österreich Über Ärger äh")
        #expect(CatalogText.plain("Fisch &AMP; Chips &LT;3") == "Fisch & Chips <3")
        #expect(CatalogText.plain("<style type=\"text/css\">\n.x{color:red}\n</style>Text<SCRIPT>\nlet a = 1\n</SCRIPT> bleibt")
                == "Text bleibt")
        #expect(CatalogText.line("  Titel\n mit   <i>Umbruch</i> ") == "Titel mit Umbruch")
        #expect(CatalogText.safeURL("http://example.com/a.jpg")?.absoluteString == "https://example.com/a.jpg")
        #expect(CatalogText.safeURL("file:///etc/passwd") == nil)
        #expect(CatalogText.safeURL("http://192.168.0.1/a.jpg") == nil)
    }
}

// MARK: - Charts und Seiten

@Suite("Katalog: Charts und Seiten")
struct CatalogChartTests {

    @Test("Eine Seite: Charts einmal, Einzelheiten in einem Abruf, Reihenfolge der Charts")
    func firstPage() async throws {
        let recorder = Recorder()
        let catalog = client(recording(recorder))
        let page = try await catalog.page(of: .top, offset: 0, count: 4)
        #expect(page.podcasts.map(\.title) == ["Morgenlage", "Lachen verboten", "Kalte Spuren", "Code und Kaffee"])
        #expect(page.nextOffset == 4)
        #expect(page.total == 11)
        #expect(page.country == "de")

        let urls = await recorder.urls
        #expect(urls.count == 2)
        #expect(urls[0].absoluteString == "https://rss.marketingtools.apple.com/api/v2/de/podcasts/top/100/podcasts.json")
        #expect(urls[1].host() == "itunes.apple.com" && urls[1].path() == "/lookup")
        #expect(query(urls[1], "id") == "1000000001,1000000002,1000000003,1000000004")
        #expect(query(urls[1], "country") == "de")
        #expect(query(urls[1], "entity") == "podcast")

        // Aus den Einzelheiten: Feed, großes Cover, Folgen, Unterrubrik.
        let first = try #require(page.podcasts.first)
        #expect(first.feedURL.absoluteString == "https://example.com/feeds/morgenlage.xml")
        #expect(first.artworkURL?.absoluteString == "https://example.com/art/1000000001/600x600bb.jpg")
        #expect(first.episodeCount == 812)
        #expect(first.genres == ["Nachrichten", "Nachrichten des Tages"])
        #expect(page.podcasts[1].isExplicit)
    }

    @Test("Ohne Feed fällt ein Platz aus der Seite, am Ende gibt es keine nächste")
    func lastPage() async throws {
        let page = try await client().page(of: .top, offset: 8, count: 25)
        #expect(page.podcasts.map(\.title) == ["Kurs und Kapital", "Story Time Tales"])
        #expect(page.nextOffset == nil)
        let beyond = try await client().page(of: .top, offset: 40, count: 25)
        #expect(beyond.podcasts.isEmpty && beyond.nextOffset == nil)
    }

    @Test("Mehr als 100 Kennungen gehen in Stapeln zu 100")
    func lookupBatches() async throws {
        #expect(PodcastCatalogClient.batches(Array(1...250), size: 100).map(\.count) == [100, 100, 50])
        #expect(PodcastCatalogClient.batches([], size: 100).isEmpty)
        #expect(PodcastCatalogClient.batches([7], size: 100) == [[7]])

        // Charts mit 150 Plätzen, jede Kennung hat einen Feed.
        let chart: [String: Any] = ["feed": ["results": (1...150).map { index in
            ["id": String(5_000 + index), "name": "Podcast \(index)", "artistName": "Beispiel"]
        }]]
        let chartBody = try JSONSerialization.data(withJSONObject: chart)
        let recorder = Recorder()
        let catalog = client { url, headers in
            await recorder.record(url, headers)
            if url.path() == "/lookup" {
                let ids = (query(url, "id") ?? "").split(separator: ",").compactMap { Int($0) }
                let results = ids.map { id in
                    ["kind": "podcast", "collectionId": id, "collectionName": "Podcast \(id - 5_000)",
                     "feedUrl": "https://example.com/\(id).xml"] as [String: Any]
                }
                return CatalogHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: ["results": results]))
            }
            return CatalogHTTPResponse(status: 200, body: chartBody)
        }
        let page = try await catalog.page(of: .top, offset: 0, count: 150)
        #expect(page.podcasts.count == 150)
        #expect(page.podcasts.first?.title == "Podcast 1" && page.podcasts.last?.title == "Podcast 150")
        let lookups = await recorder.urls.filter { $0.path() == "/lookup" }
        #expect(lookups.map { (query($0, "id") ?? "").split(separator: ",").count } == [100, 50])
        #expect(query(lookups[1], "id")?.hasPrefix("5101,") == true)
    }

    @Test("Rubriken: Charts der Rubrik, auch mit nur einem oder gar keinem Platz")
    func genreCharts() async throws {
        let recorder = Recorder()
        let catalog = client(recording(recorder))
        let news = try await catalog.page(of: .genre(.news), offset: 0, count: 25)
        #expect(news.podcasts.map(\.title) == ["Morgenlage", "Morning Signal"])
        #expect(await recorder.urls.first?.absoluteString
                == "https://itunes.apple.com/de/rss/toppodcasts/limit=200/genre=1489/json")
        // Die Beschreibung bringen die Charts einer Rubrik mit.
        #expect(news.podcasts.first?.summary == "Die Nachrichten des Tages in zehn Minuten.\n\nJeden Morgen um sechs.")

        let crime = try await catalog.page(of: .genre(.trueCrime), offset: 0, count: 25)
        #expect(crime.podcasts.map(\.title) == ["Kalte Spuren"])

        let before = await recorder.calls.count
        let government = try await catalog.page(of: .genre(.politics), offset: 0, count: 25)
        #expect(government.podcasts.isEmpty && government.total == 0 && government.nextOffset == nil)
        // Nur die Charts, kein leerer Abruf der Einzelheiten.
        #expect(await recorder.calls.count == before + 1)
    }

    @Test("Eine Viertelstunde aus dem Zwischenspeicher, danach neu")
    func caching() async throws {
        let recorder = Recorder()
        let clock = TestClock()
        let catalog = client(recording(recorder), clock: clock)
        _ = try await catalog.page(of: .top, offset: 0, count: 5)
        #expect(await recorder.calls.count == 2)

        _ = try await catalog.page(of: .top, offset: 0, count: 5)
        #expect(await recorder.calls.count == 2)

        // Die zweite Seite braucht nur ihre Einzelheiten.
        _ = try await catalog.page(of: .top, offset: 5, count: 5)
        #expect(await recorder.calls.count == 3)

        clock.advance(by: 14 * 60)
        _ = try await catalog.page(of: .top, offset: 0, count: 5)
        #expect(await recorder.calls.count == 3)

        clock.advance(by: 2 * 60)
        _ = try await catalog.page(of: .top, offset: 0, count: 5)
        #expect(await recorder.calls.count == 5)
    }

    @Test("Führt Apple das Land nicht, kommen Charts und Einzelheiten aus den USA")
    func storefrontFallback() async throws {
        let recorder = Recorder()
        let catalog = client(country: "kp") { url, headers in
            await recorder.record(url, headers)
            if url.path().contains("/kp/") || query(url, "country") == "kp" {
                return CatalogHTTPResponse(status: url.host() == "itunes.apple.com" ? 400 : 500, body: Data())
            }
            return try await CatalogFixtures.transport(url, headers)
        }
        let page = try await catalog.page(of: .top, offset: 0, count: 3)
        #expect(page.country == "us")
        #expect(page.podcasts.count == 3)
        let urls = await recorder.urls
        #expect(urls.map(\.absoluteString).prefix(2) == [
            "https://rss.marketingtools.apple.com/api/v2/kp/podcasts/top/100/podcasts.json",
            "https://rss.marketingtools.apple.com/api/v2/us/podcasts/top/100/podcasts.json",
        ])
        #expect(query(urls.last, "country") == "us")

        let found = try await catalog.search("kaffee")
        #expect(found.contains { $0.title == "Kaffeeklatsch" })
        let searches = await recorder.urls.filter { $0.path() == "/search" && $0.host() == "itunes.apple.com" }
        #expect(searches.map { query($0, "country") } == ["kp", "us"])
    }

    @Test("Fehler des Katalogs kommen als eigene Fehler")
    func errors() async {
        let limited = client { _, _ in CatalogHTTPResponse(status: 429, body: Data()) }
        await #expect(throws: CatalogError.rateLimited) { try await limited.page(of: .top, offset: 0, count: 5) }
        let throttled = client { _, _ in CatalogHTTPResponse(status: 403, body: Data()) }
        await #expect(throws: CatalogError.rateLimited) { try await throttled.page(of: .top, offset: 0, count: 5) }
        let broken = client { _, _ in CatalogHTTPResponse(status: 503, body: Data()) }
        await #expect(throws: CatalogError.serverStatus(503)) { try await broken.page(of: .top, offset: 0, count: 5) }
        // In den USA gibt es kein Land, auf das noch auszuweichen wäre.
        let american = client(country: "US") { _, _ in CatalogHTTPResponse(status: 500, body: Data()) }
        await #expect(throws: CatalogError.serverStatus(500)) { try await american.page(of: .top, offset: 0, count: 5) }
        let offline = client { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: CatalogError.unreachable) { try await offline.page(of: .top, offset: 0, count: 5) }
        let tooLarge = client { _, _ in throw HTTPTransferError.tooLarge(limit: 10) }
        await #expect(throws: CatalogError.unreadableAnswer) { try await tooLarge.page(of: .top, offset: 0, count: 5) }
    }

    @Test("Fehlermeldungen in der Sprache der App")
    func errorMessages() {
        #expect(CatalogError.rateLimited.errorDescription == TestLanguage.pick(
            de: "Der Podcast-Katalog bekommt gerade zu viele Anfragen. In einer Minute noch einmal versuchen.",
            en: "The podcast catalog is getting too many requests right now. Try again in a minute."))
        #expect(CatalogError.serverStatus(503).errorDescription == TestLanguage.pick(
            de: "Der Podcast-Katalog antwortet gerade nicht (Status 503). Später noch einmal versuchen.",
            en: "The podcast catalog isn't responding right now (status 503). Try again later."))
    }
}

// MARK: - Suche

@Suite("Katalog: Suche bei Apple und Podcast Index")
struct CatalogSearchTests {

    @Test("Beide Dienste, zusammengeführt und ohne Doppelte")
    func mergedSearch() async throws {
        let recorder = Recorder()
        let found = try await client(recording(recorder)).search("kaffee")
        #expect(found.map(\.title) == ["Code und Kaffee", "Kaffeeklatsch", "Bohnenfunk"])
        #expect(found.map(\.origin) == [.appleDirectory, .appleDirectory, .podcastIndex])
        // „Code und Kaffee“ stand bei beiden, bei Podcast Index mit „www.“,
        // http und Schrägstrich. „Kaffeeklatsch“ ohne Apple-Kennung, aber
        // mit derselben Adresse. „Kaffee ohne Feed“ fehlt ganz.
        #expect(found[0].itunesID == 1_000_000_004)
        #expect(found[1].itunesID == 1_000_000_012)
        #expect(found[2].feedURL.absoluteString == "https://example.org/bohnenfunk/rss")

        let urls = await recorder.urls
        let apple = try #require(urls.first { $0.host() == "itunes.apple.com" })
        #expect(apple.path() == "/search")
        #expect(query(apple, "term") == "kaffee")
        #expect(query(apple, "country") == "de")
        #expect(query(apple, "media") == "podcast")
        let index = try #require(urls.first { $0.host() == "api.podcastindex.org" })
        #expect(index.absoluteString == "https://api.podcastindex.org/search?term=kaffee")
        // Podcast Index lehnt Anfragen ohne Namen der App ab.
        #expect(await recorder.calls.allSatisfy { $0.headers["User-Agent"] == "PodcastAI/0.7.2" })
    }

    @Test("Beide Anfragen laufen zugleich", .timeLimit(.minutes(1)))
    func parallel() async throws {
        let gate = Gate(count: 2)
        let catalog = client { url, headers in
            await gate.arrive()
            return try await CatalogFixtures.transport(url, headers)
        }
        #expect(try await catalog.search("kaffee").count == 3)
    }

    @Test("Antwortet nur einer, zählt dessen Liste; antwortet keiner, kommt Apples Fehler")
    func partialFailure() async throws {
        let indexDown = client { url, headers in
            if url.host() == "api.podcastindex.org" { return CatalogHTTPResponse(status: 503, body: Data()) }
            return try await CatalogFixtures.transport(url, headers)
        }
        #expect(try await indexDown.search("kaffee").map(\.title) == ["Code und Kaffee", "Kaffeeklatsch"])

        let appleDown = client { url, headers in
            if url.host() == "itunes.apple.com" { throw URLError(.timedOut) }
            return try await CatalogFixtures.transport(url, headers)
        }
        #expect(try await appleDown.search("kaffee").map(\.title) == ["Code und Kaffee", "Bohnenfunk", "Kaffeeklatsch"])

        let bothDown = client { url, _ in
            if url.host() == "itunes.apple.com" { throw URLError(.notConnectedToInternet) }
            return CatalogHTTPResponse(status: 429, body: Data())
        }
        await #expect(throws: CatalogError.unreachable) { try await bothDown.search("kaffee") }
    }

    @Test("Zu kurze Begriffe fragen niemanden")
    func shortTerm() async throws {
        let recorder = Recorder()
        #expect(try await client(recording(recorder)).search(" k ").isEmpty)
        #expect(await recorder.calls.isEmpty)
    }

    @Test("Suchbegriffe mit Plus und Und-Zeichen kommen unverfälscht an")
    func queryEncoding() throws {
        let index = try #require(PodcastCatalogClient.podcastIndexSearchURL("c++ & co"))
        #expect(index.absoluteString == "https://api.podcastindex.org/search?term=c%2B%2B%20%26%20co")
        let apple = try #require(PodcastCatalogClient.appleSearchURL("c++", country: "de"))
        #expect(apple.absoluteString.hasSuffix("&term=c%2B%2B"))
    }
}

// MARK: - Land

@Suite("Katalog: Land")
struct CatalogStorefrontTests {

    @Test("Region des Geräts in Kleinschrift, sonst die USA")
    func country() {
        #expect(CatalogStorefront.country(forRegion: "DE") == "de")
        #expect(CatalogStorefront.country(forRegion: "at") == "at")
        #expect(CatalogStorefront.country(forRegion: nil) == "us")
        #expect(CatalogStorefront.country(forRegion: "") == "us")
        #expect(CatalogStorefront.country(forRegion: "001") == "us")
        #expect(CatalogStorefront.country(forRegion: "150") == "us")
        #expect(CatalogStorefront.country(forRegion: "DEU") == "us")
        #expect(CatalogStorefront.country(forRegion: "Ö1") == "us")
        #expect(CatalogStorefront.country(forRegion: "d/") == "us")
    }

    @Test("Der Client nimmt nur ein gültiges Land in seine Adressen")
    func clientCountry() {
        #expect(client(country: "CH").country == "ch")
        #expect(client(country: "../x").country == "us")
        #expect(PodcastCatalogClient.chartURL(.top, country: "ch")?.absoluteString
                == "https://rss.marketingtools.apple.com/api/v2/ch/podcasts/top/100/podcasts.json")
        #expect(PodcastCatalogClient.chartURL(.genre(.science), country: "ch")?.absoluteString
                == "https://itunes.apple.com/ch/rss/toppodcasts/limit=200/genre=1533/json")
    }
}

// MARK: - Rubriken

@Suite("Katalog: Rubriken")
struct CatalogCategoryTests {

    @Test("Die 19 Rubriken von Apple Podcasts, jede Kennung einmal")
    func genres() {
        let topLevel: Set<Int> = [1301, 1321, 1303, 1304, 1483, 1511, 1512, 1487, 1305, 1502,
                                  1310, 1489, 1314, 1533, 1324, 1545, 1309, 1318, 1488]
        #expect(CatalogCategory.allCases.count == 19)
        #expect(Set(CatalogCategory.allCases.map(\.genreID)) == topLevel)
        let subgenres = CatalogCategory.allCases.flatMap(\.subgenreIDs)
        #expect(subgenres.count == 91)
        #expect(Set(subgenres).count == subgenres.count)
        #expect(Set(subgenres).isDisjoint(with: topLevel))
        for category in CatalogCategory.allCases {
            #expect(CatalogCategory(genreID: category.genreID) == category)
            #expect(category.subgenreIDs.allSatisfy { CatalogCategory(genreID: $0) == category })
        }
    }

    @Test("Unterrubriken gehören zu ihrer Rubrik, „Podcasts“ zu keiner")
    func mapping() {
        #expect(CatalogCategory(genreID: 1527) == .news)
        #expect(CatalogCategory(genreID: 1546) == .sports)
        #expect(CatalogCategory(genreID: 1438) == .religion)
        #expect(CatalogCategory(genreID: CatalogCategory.podcastsGenreID) == nil)
        #expect(CatalogCategory(genreID: 9_999) == nil)
        #expect(CatalogCategory.categories(for: [1527, 26, 1489, 1526]) == [.news])
        #expect(CatalogCategory.categories(for: [1538, 1533, 1304]) == [.science, .education])
        #expect(CatalogCategory.categories(for: []).isEmpty)
    }

    @Test("Jedes Symbol gibt es, keines doppelt")
    func symbols() {
        let symbols = CatalogCategory.allCases.map(\.symbol)
        #expect(Set(symbols).count == 19)
        #if canImport(AppKit)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
        #endif
    }

    @Test("Apples Namen in der Sprache der App")
    func titles() {
        #expect(Set(CatalogCategory.allCases.map(\.title)).count == 19)
        #expect(CatalogCategory.news.title == TestLanguage.pick(de: "Nachrichten", en: "News"))
        #expect(CatalogCategory.trueCrime.title == TestLanguage.pick(de: "Wahre Kriminalfälle", en: "True Crime"))
        #expect(CatalogCategory.politics.title == TestLanguage.pick(de: "Regierung", en: "Government"))
        #expect(CatalogCategory.kidsFamily.title == TestLanguage.pick(de: "Kinder und Familie", en: "Kids & Family"))
        #expect(CatalogCategory.technology.title == TestLanguage.pick(de: "Technologie", en: "Technology"))
    }
}

// MARK: - Zusammenführen

@Suite("Katalog: Treffer zusammenführen")
struct CatalogMergeTests {

    private func podcast(_ title: String, _ feed: String, origin: CatalogPodcast.Origin = .appleDirectory,
                         itunes: Int? = nil, artwork: String? = nil, genres: [String] = []) -> CatalogPodcast {
        CatalogPodcast(origin: origin, itunesID: itunes, title: title, author: "", feedURL: URL(string: feed)!,
                       artworkURL: artwork.flatMap(URL.init(string:)), genres: genres)
    }

    @Test("Gleicher Feed in anderer Schreibweise oder gleiche Apple-Kennung: nur einmal")
    func deduplicates() {
        let apple = [
            podcast("A", "https://example.com/a.xml", itunes: 1),
            podcast("B", "https://example.com/b.xml"),
            podcast("E", "https://example.com/e.xml"),
        ]
        let index = [
            podcast("A (Index)", "http://www.Example.com/a.xml/", origin: .podcastIndex,
                    artwork: "https://example.com/a.jpg", genres: ["Nachrichten"]),
            podcast("A (andere Adresse)", "https://feeds.example.org/a", origin: .podcastIndex, itunes: 1),
            podcast("D", "https://example.com/d.xml", origin: .podcastIndex, itunes: 4),
        ]
        let merged = CatalogMerge.merged(apple, index)
        #expect(merged.map(\.title) == ["A", "B", "E", "D"])
        // Was dem ersten Eintrag fehlt, kommt vom zweiten.
        #expect(merged[0].artworkURL?.absoluteString == "https://example.com/a.jpg")
        #expect(merged[0].genres == ["Nachrichten"])
        #expect(merged[0].itunesID == 1)
        #expect(merged[3].origin == .podcastIndex)
        // Die andere Adresse zählt beim Abo-Abgleich mit.
        #expect(merged[0].knownFeedURLs.contains(URL(string: "https://feeds.example.org/a")!))
        #expect(merged[0].feedURL.absoluteString == "https://example.com/a.xml")
    }

    @Test("Ohne Treffer der zweiten Liste bleibt die erste, wie sie ist")
    func firstOnly() {
        let apple = [podcast("X", "https://example.com/x.xml"), podcast("Y", "https://example.com/y.xml")]
        #expect(CatalogMerge.merged(apple, []).map(\.title) == ["X", "Y"])
        #expect(CatalogMerge.feedKey(URL(string: "https://WWW.example.com:443/feed/")!)
                == CatalogMerge.feedKey(URL(string: "http://example.com/feed")!))
        #expect(CatalogMerge.feedKey(URL(string: "https://example.com/feed?id=1")!)
                != CatalogMerge.feedKey(URL(string: "https://example.com/feed?id=2")!))
    }
}

// MARK: - Feeds der Fixtures

@Suite("Katalog: Feeds der Fixtures")
struct CatalogFixtureFeedTests {

    @Test("Jeder ausgedachte Podcast hat einen lesbaren Feed ohne Audio")
    func feeds() throws {
        let data = try #require(CatalogFixtures.feed(for: URL(string: "http://www.example.com/feeds/morgenlage.xml")!))
        let feed = try FeedParser().parse(data)
        #expect(feed.title == "Morgenlage")
        #expect(feed.items.count == 5)
        #expect(feed.items.first?.title == "Folge 40: Beispiel & Einordnung")
        #expect(feed.items.allSatisfy { $0.audioURL == nil })
        #expect(CatalogFixtures.feed(for: URL(string: "https://example.com/unbekannt.xml")!) == nil)
    }
}

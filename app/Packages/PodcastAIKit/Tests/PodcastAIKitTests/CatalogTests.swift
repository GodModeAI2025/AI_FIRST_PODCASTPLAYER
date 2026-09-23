//
//  CatalogTests.swift
//  PodcastAIKitTests
//
//  Der Podcast-Katalog über Podcast Index: Anmeldung, Lesen der Antworten,
//  Rubriken, Sprache und das Zusammenführen mit dem Apple-Verzeichnis.
//  Kein Test geht ins Netz; die Antworten kommen aus festen Texten.
//

import Foundation
import Testing
import PodcastAIKit
@testable import PodcastAISources

/// Merkt sich jede Anfrage, die der Client stellt.
private actor Recorder {
    private(set) var calls: [(url: URL, headers: [String: String])] = []
    func record(_ url: URL, _ headers: [String: String]) { calls.append((url, headers)) }
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

private func client(
    _ transport: @escaping CatalogTransport = PodcastIndexFixtures.transport,
    credentials: PodcastIndexCredentials = PodcastIndexFixtures.credentials,
    clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_140_000) }
) -> PodcastIndexClient {
    PodcastIndexClient(credentials: credentials, userAgent: "PodcastAI/0.7.2", transport: transport, clock: clock)
}

@Suite("Podcast Index: Anmeldung")
struct PodcastIndexSigningTests {

    @Test("Hash nach dem Rechenbeispiel der Dokumentation")
    func knownVector() {
        let hash = PodcastIndexSignature.authorization(
            key: "UXKCGDSYGUUEVQJSYDZH", secret: "yzJe2eE7XV-3eY576dyRZ6wXyAbndh6LUrCZ8KN|", timestamp: 1613713388)
        #expect(hash == "73a1fffed61c1d30d858beb1fc48f355386449d2")
    }

    @Test("Vier Kopfzeilen, Zeit in ganzen Sekunden abgerundet")
    func headers() {
        let credentials = PodcastIndexCredentials(apiKey: "UXKCGDSYGUUEVQJSYDZH",
                                                  apiSecret: "yzJe2eE7XV-3eY576dyRZ6wXyAbndh6LUrCZ8KN|")
        let headers = PodcastIndexSignature.headers(for: credentials, at: Date(timeIntervalSince1970: 1613713388.97),
                                                    userAgent: "PodcastAI/0.7.2")
        #expect(headers["X-Auth-Date"] == "1613713388")
        #expect(headers["X-Auth-Key"] == "UXKCGDSYGUUEVQJSYDZH")
        #expect(headers["Authorization"] == "73a1fffed61c1d30d858beb1fc48f355386449d2")
        #expect(headers["User-Agent"] == "PodcastAI/0.7.2")
    }

    @Test("Zugangsdaten aus der Property-Liste, leeres Geheimnis heißt: aus")
    func credentialsFromPropertyList() throws {
        let complete = try PropertyListSerialization.data(
            fromPropertyList: ["APIKey": " KEY ", "APISecret": "se$cr|et//x"], format: .xml, options: 0)
        let parsed = try #require(PodcastIndexCredentials(propertyList: complete))
        #expect(parsed.apiKey == "KEY")
        #expect(parsed.apiSecret == "se$cr|et//x")
        #expect(parsed.isComplete)

        let withoutSecret = try PropertyListSerialization.data(
            fromPropertyList: ["APIKey": "KEY", "APISecret": ""], format: .xml, options: 0)
        #expect(PodcastIndexCredentials(propertyList: withoutSecret)?.isComplete == false)
        let keyOnly = try PropertyListSerialization.data(fromPropertyList: ["APIKey": "KEY"], format: .xml, options: 0)
        #expect(PodcastIndexCredentials(propertyList: keyOnly)?.isComplete == false)
        #expect(PodcastIndexCredentials(propertyList: Data("kein plist".utf8)) == nil)
    }

    @Test("Der Client schickt Schlüssel, Zeit, Hash und Produktnamen mit")
    func clientSignsRequests() async throws {
        let recorder = Recorder()
        let catalog = client { url, headers in
            await recorder.record(url, headers)
            return try await PodcastIndexFixtures.transport(url, headers)
        }
        _ = try await catalog.trending(language: .german)
        let call = try #require(await recorder.calls.first)
        #expect(call.headers["X-Auth-Key"] == "FIXTUREKEY")
        #expect(call.headers["X-Auth-Date"] == "1790140000")
        #expect(call.headers["User-Agent"] == "PodcastAI/0.7.2")
        let hash = try #require(call.headers["Authorization"])
        #expect(hash.count == 40 && hash == hash.lowercased())
        #expect(hash == PodcastIndexSignature.authorization(key: "FIXTUREKEY", secret: "fixture-secret",
                                                            timestamp: 1_790_140_000))
    }

    @Test("Ohne Geheimnis keine Anfrage")
    func missingSecretSendsNothing() async {
        let recorder = Recorder()
        let catalog = client({ url, headers in
            await recorder.record(url, headers)
            return CatalogHTTPResponse(status: 200, body: Data())
        }, credentials: PodcastIndexCredentials(apiKey: "KEY", apiSecret: ""))
        await #expect(throws: PodcastIndexError.missingCredentials) { try await catalog.search("lage") }
        #expect(await recorder.calls.isEmpty)
    }

    @Test("Falsche Geräteuhr: einmal mit der Zeit des Servers nachrechnen")
    func clockSkewRetriesOnce() async throws {
        let recorder = Recorder()
        let serverNow = Date(timeIntervalSince1970: 1_790_140_000 + 900)
        let catalog = client { url, headers in
            await recorder.record(url, headers)
            let sent = Int(headers["X-Auth-Date"] ?? "") ?? 0
            guard abs(TimeInterval(sent) - serverNow.timeIntervalSince1970) < 180 else {
                return CatalogHTTPResponse(status: 401, body: Data("The hash in the Authorization header doesn't match up.".utf8),
                                           serverDate: serverNow)
            }
            return try await PodcastIndexFixtures.transport(url, headers)
        }
        let found = try await catalog.search("kaffee")
        #expect(found.count == 2)
        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls.last?.headers["X-Auth-Date"] == "1790140900")
    }

    @Test("Falsche Geräteuhr: zwei Anfragen zugleich, beide rechnen nach")
    func clockSkewWithConcurrentRequests() async throws {
        let gate = Gate(count: 2)
        let serverNow = Date(timeIntervalSince1970: 1_790_140_000 + 900)
        let catalog = client { url, headers in
            let sent = Int(headers["X-Auth-Date"] ?? "") ?? 0
            guard abs(TimeInterval(sent) - serverNow.timeIntervalSince1970) < 180 else {
                // Beide falsch signierten Anfragen sind unterwegs, bevor die
                // erste ihre Ablehnung sieht.
                await gate.arrive()
                return CatalogHTTPResponse(status: 401, body: Data(), serverDate: serverNow)
            }
            return try await PodcastIndexFixtures.transport(url, headers)
        }
        async let found = catalog.search("kaffee")
        async let trending = catalog.trending(language: nil)
        let (fromSearch, fromTrending) = try await (found, trending)
        #expect(fromSearch.count == 2)
        #expect(fromTrending.count == 10)
    }

    @Test("Fehler des Katalogs kommen als eigene Fehler, nicht als Serverfehler eines Podcasts")
    func errors() async {
        let unauthorized = client { _, _ in CatalogHTTPResponse(status: 401, body: Data("nope".utf8)) }
        await #expect(throws: PodcastIndexError.unauthorized) { try await unauthorized.search("lage") }
        let limited = client { _, _ in CatalogHTTPResponse(status: 429, body: Data()) }
        await #expect(throws: PodcastIndexError.rateLimited) { try await limited.trending(language: nil) }
        let broken = client { _, _ in CatalogHTTPResponse(status: 503, body: Data()) }
        await #expect(throws: PodcastIndexError.serverStatus(503)) { try await broken.trending(language: nil) }
        let offline = client { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: PodcastIndexError.unreachable) { try await offline.search("lage") }
        let tooLarge = client { _, _ in throw HTTPTransferError.tooLarge(limit: 10) }
        await #expect(throws: PodcastIndexError.unreadableAnswer) { try await tooLarge.search("lage") }
        let garbage = client { _, _ in CatalogHTTPResponse(status: 200, body: Data("<html>".utf8)) }
        await #expect(throws: PodcastIndexError.unreadableAnswer) { try await garbage.search("lage") }
        await #expect(throws: PodcastIndexError.notFound) { try await client().podcast(id: 1) }
    }

    @Test("Fehlermeldungen in der Sprache der App")
    func errorMessages() {
        #expect(PodcastIndexError.rateLimited.errorDescription == TestLanguage.pick(
            de: "Der Podcast-Katalog bekommt gerade zu viele Anfragen. In einer Minute noch einmal versuchen.",
            en: "The podcast catalog is getting too many requests right now. Try again in a minute."))
        #expect(PodcastIndexError.serverStatus(503).errorDescription == TestLanguage.pick(
            de: "Der Podcast-Katalog antwortet gerade nicht (Status 503). Später noch einmal versuchen.",
            en: "The podcast catalog isn't responding right now (status 503). Try again later."))
    }

    @Test("Zeit aus der Kopfzeile Date")
    func httpDate() {
        #expect(PodcastIndexClient.httpDate("Wed, 23 Sep 2026 12:58:57 GMT")
                == Date(timeIntervalSince1970: 1_790_168_337))
        #expect(PodcastIndexClient.httpDate("gestern") == nil)
    }

    @Test("Suchbegriffe mit Plus und Und-Zeichen kommen unverfälscht an")
    func queryEncoding() throws {
        let url = try #require(PodcastIndexClient.url("search/byterm", [URLQueryItem(name: "q", value: "c++ & co")]))
        #expect(url.absoluteString == "https://api.podcastindex.org/api/1.0/search/byterm?q=c%2B%2B%20%26%20co")
    }
}

@Suite("Podcast Index: Antworten lesen")
struct PodcastIndexDecodingTests {

    @Test("Trends: Felder, Bild über https, Beschreibung ohne HTML")
    func trending() async throws {
        let all = try await client().trending(language: nil)
        #expect(all.count == 10)
        let first = try #require(all.first)
        #expect(first.title == "Morgenlage")
        #expect(first.podcastIndexID == 9001)
        #expect(first.itunesID == 1000000001)
        #expect(first.feedURL.absoluteString == "https://example.com/feeds/morgenlage.xml")
        #expect(first.summary == "Die Nachrichten des Tages in zehn Minuten.\n\nJeden Morgen um sechs.")
        #expect(first.categoryIDs == [55, 56])
        #expect(first.categories.first == .news)
        #expect(first.newestEpisodeDate == Date(timeIntervalSince1970: 1_790_141_400))
        #expect(first.origin == .podcastIndex)

        let comedy = try #require(all.first { $0.podcastIndexID == 9002 })
        // `artwork` leer, `image` mit http: das Bild kommt über https.
        #expect(comedy.artworkURL?.absoluteString == "https://example.com/art/lachen.png")
        #expect(comedy.itunesID == nil)
        #expect(comedy.summary == "Zwei Freunde, ein Mikrofon & keine Regeln.")
    }

    @Test("Suche: aufgegebene Feeds, Musik und Feeds ohne Adresse fallen weg")
    func search() async throws {
        let found = try await client().search("kaffee")
        #expect(found.map(\.title) == ["Code und Kaffee", "Kaffeeklatsch"])
        let code = found[0]
        #expect(code.originalFeedURL?.absoluteString == "http://old.example.com/code.xml")
        #expect(code.websiteURL?.absoluteString == "https://example.com/code")
        #expect(code.episodeCount == 212)
        #expect(code.podcastGUID == "5f3c2a10-0000-4000-8000-000000009004")
        #expect(code.isExplicit == false)
        #expect(code.newestEpisodeDate == Date(timeIntervalSince1970: 1_789_819_200))
        let klatsch = found[1]
        // Kein Autor, aber ein Eigentümer. Kategorien als leere Liste `[]`.
        #expect(klatsch.author == "Beispiel Familie")
        #expect(klatsch.categoryIDs.isEmpty)
        #expect(klatsch.isExplicit)
        #expect(try await client().search("k").isEmpty)
    }

    @Test("Einzelheiten und neueste Folgen")
    func detailAndEpisodes() async throws {
        let catalog = client()
        let podcast = try await catalog.podcast(id: 9003)
        #expect(podcast.title == "Kalte Spuren")
        #expect(podcast.episodeCount == 123)
        #expect(podcast.websiteURL?.absoluteString == "https://example.com/podcasts/9003")
        let episodes = try await catalog.episodes(feedID: 9003)
        #expect(episodes.count == 5)
        #expect(episodes.first?.title == "Folge 40: Beispiel & Einordnung")
        #expect(episodes.first?.duration == 1_800)
        #expect(episodes.first?.season == 2)
        #expect(episodes.map(\.publishedAt) == episodes.map(\.publishedAt).sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) })
    }

    @Test("Zahlen als Text, Wahrheitswerte als 0 und 1, kaputte Einträge übersprungen")
    func lenientDecoding() throws {
        let json = #"""
        {"status": "true", "feeds": [
          42, null,
          {"id": "77", "title": "Als &quot;Text&quot;", "url": "https://example.com/t.xml", "explicit": 1,
           "dead": "0", "episodeCount": "12", "newestItemPubdate": 1790000000.0, "categories": {"103": null}},
          {"id": 78, "title": "Aufgegeben", "url": "https://example.com/d.xml", "dead": true},
          {"id": 79, "title": "Lokal", "url": "http://127.0.0.1/feed.xml"}
        ]}
        """#
        let envelope = try JSONDecoder().decode(FeedsEnvelope.self, from: Data(json.utf8))
        #expect(envelope.feeds.count == 3)
        let podcasts = envelope.feeds.compactMap(PodcastIndexClient.podcast(from:))
        #expect(podcasts.count == 1)
        let podcast = try #require(podcasts.first)
        #expect(podcast.podcastIndexID == 77)
        #expect(podcast.title == "Als \"Text\"")
        #expect(podcast.isExplicit)
        #expect(podcast.episodeCount == 12)
        #expect(podcast.categories == [.trueCrime])

        let unknown = try JSONDecoder().decode(FeedEnvelope.self, from: Data(#"{"status":"true","feed":[]}"#.utf8))
        #expect(unknown.feed == nil)
    }

    @Test("HTML wird zu Text")
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

@Suite("Katalog: Rubriken")
struct CatalogCategoryTests {

    @Test("Jede der 112 Kategorien gehört zu genau einer Rubrik")
    func everyIDMapsOnce() {
        let ids = CatalogCategory.allCases.flatMap(\.podcastIndexIDs)
        #expect(Set(ids) == Set(1...112))
        #expect(ids.count == 112)
        #expect(CatalogCategory.allCases.count == 19)
        #expect(Set(CatalogCategory.allCases.map(\.symbol)).count == 19)
        #expect(Set(CatalogCategory.allCases.map(\.title)).count == 19)
    }

    @Test("Oberbegriffe entscheiden, Unterbegriffe nur als Rückfall")
    func mapping() {
        // „TV & Film > TV Reviews“
        #expect(CatalogCategory.primary(for: [104, 105, 107]) == .tvFilm)
        // „News > Politics“: beide Rubriken, Nachrichten zuerst.
        #expect(CatalogCategory.categories(for: [55, 59]) == [.news, .politics])
        // Nur „Interviews“ oder nur „Commentary“.
        #expect(CatalogCategory.primary(for: [17]) == .comedy)
        #expect(CatalogCategory.primary(for: [54]) == .news)
        // „Comedy Fiction“: das Genauere zuerst.
        #expect(CatalogCategory.primary(for: [16, 26]) == .comedy)
        #expect(CatalogCategory.primary(for: [77, 103]) == .trueCrime)
        // „Sports > Fantasy Sports“ ist Sport, nicht Freizeit.
        #expect(CatalogCategory.primary(for: [86, 90]) == .sports)
        #expect(CatalogCategory.primary(for: [112]) == .business)
        #expect(CatalogCategory.primary(for: []) == nil)
        #expect(CatalogCategory.primary(for: [999]) == nil)
    }

    @Test("Namen in der Sprache der App")
    func titles() {
        #expect(CatalogCategory.news.title == TestLanguage.pick(de: "Nachrichten", en: "News"))
        #expect(CatalogCategory.kidsFamily.title == TestLanguage.pick(de: "Kinder & Familie", en: "Kids & Family"))
        #expect(CatalogCategory.technology.title == TestLanguage.pick(de: "Technik", en: "Technology"))
        #expect(CatalogCategory.trueCrime.title == "True Crime")
    }

    @Test("Trends einer Rubrik fragen alle ihre Kennungen ab")
    func categoryRequest() async throws {
        let recorder = Recorder()
        let catalog = client { url, headers in
            await recorder.record(url, headers)
            return try await PodcastIndexFixtures.transport(url, headers)
        }
        let news = try await catalog.trending(language: nil, category: .news, max: 25)
        #expect(news.map(\.title) == ["Morgenlage", "Morning Signal"])
        let url = try #require(await recorder.calls.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "cat" }?.value == "55,54,56,57")
        #expect(items.first { $0.name == "max" }?.value == "25")
        #expect(items.contains { $0.name == "lang" } == false)
    }

    @Test("In einer Rubrik nur, was nach Oberbegriffen dorthin gehört")
    func categoryListUsesPrimaryRule() async throws {
        let json = #"""
        {"status": "true", "feeds": [
          {"id": 1, "title": "Musikkommentar", "url": "https://example.com/1.xml", "categories": {"53": "Music", "54": "Commentary"}},
          {"id": 2, "title": "Musikgespräche", "url": "https://example.com/2.xml", "categories": {"53": "Music", "17": "Interviews"}},
          {"id": 3, "title": "Tageslage", "url": "https://example.com/3.xml", "categories": {"55": "News", "56": "Daily"}},
          {"id": 4, "title": "Nur Kommentar", "url": "https://example.com/4.xml", "categories": {"54": "Commentary"}}
        ]}
        """#
        let catalog = client { _, _ in CatalogHTTPResponse(status: 200, body: Data(json.utf8)) }
        #expect(try await catalog.trending(language: nil, category: .news).map(\.title) == ["Tageslage", "Nur Kommentar"])
        #expect(try await catalog.trending(language: nil, category: .comedy).isEmpty)
        #expect(try await catalog.trending(language: nil, category: .music).map(\.title)
                == ["Musikkommentar", "Musikgespräche"])
    }
}

@Suite("Katalog: Sprache")
struct CatalogLanguageTests {

    @Test("Schreibweisen der Sprache im Feed")
    func matches() {
        #expect(CatalogLanguage.matches("de", .german))
        #expect(CatalogLanguage.matches("de-DE", .german))
        #expect(CatalogLanguage.matches("de_at", .german))
        #expect(CatalogLanguage.matches("DE", .german))
        #expect(!CatalogLanguage.matches("en-us", .german))
        #expect(!CatalogLanguage.matches(nil, .german))
        #expect(!CatalogLanguage.matches("", .english))
        #expect(CatalogLanguage.matches("en-GB", .english))
    }

    @Test("Trends in der Sprache der App oder in allen")
    func trendingByLanguage() async throws {
        let recorder = Recorder()
        let catalog = client { url, headers in
            await recorder.record(url, headers)
            return try await PodcastIndexFixtures.transport(url, headers)
        }
        let german = try await catalog.trending(language: .german)
        #expect(german.map(\.podcastIndexID) == [9001, 9002, 9003, 9004, 9007, 9008, 9009])
        let english = try await catalog.trending(language: .english)
        #expect(english.map(\.title) == ["Morning Signal", "Deep Field Notes", "Story Time Tales"])
        #expect(try await catalog.trending(language: nil).count == 10)
        let url = try #require(await recorder.calls.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "lang" }?.value == "de,de-de,de-at,de-ch")
    }
}

@Suite("Katalog: Treffer zusammenführen")
struct CatalogMergeTests {

    private func podcast(_ title: String, _ feed: String, origin: CatalogPodcast.Origin = .podcastIndex,
                         itunes: Int? = nil, original: String? = nil, artwork: String? = nil) -> CatalogPodcast {
        CatalogPodcast(origin: origin, itunesID: itunes, title: title, author: "", feedURL: URL(string: feed)!,
                       originalFeedURL: original.flatMap(URL.init(string:)),
                       artworkURL: artwork.flatMap(URL.init(string:)))
    }

    @Test("Gleicher Feed, alte Adresse oder gleiche Apple-Kennung: nur einmal")
    func deduplicates() {
        let index = [
            podcast("A", "https://example.com/a.xml", itunes: 1),
            podcast("B", "https://example.com/b.xml", original: "http://old.example.com/b.xml"),
            podcast("E", "https://example.com/e.xml"),
        ]
        let apple = [
            podcast("A (Apple)", "http://www.Example.com/a.xml/", origin: .appleDirectory,
                    artwork: "https://example.com/a.jpg"),
            podcast("B (Apple)", "http://old.example.com/b.xml", origin: .appleDirectory),
            podcast("A (andere Adresse)", "https://feeds.example.org/a", origin: .appleDirectory, itunes: 1),
            podcast("D", "https://example.com/d.xml", origin: .appleDirectory, itunes: 4),
        ]
        let merged = CatalogMerge.merged(index, apple)
        #expect(merged.map(\.title) == ["A", "B", "E", "D"])
        // Was dem ersten Eintrag fehlt, kommt vom zweiten.
        #expect(merged[0].artworkURL?.absoluteString == "https://example.com/a.jpg")
        #expect(merged[0].itunesID == 1)
        #expect(merged[3].origin == .appleDirectory)
        // Die Adresse aus dem Apple-Verzeichnis zählt beim Abo-Abgleich mit.
        let keysOfA = Set(merged[0].knownFeedURLs.map(CatalogMerge.feedKey))
        #expect(keysOfA.contains(CatalogMerge.feedKey(URL(string: "https://feeds.example.org/a")!)))
        #expect(merged[0].knownFeedURLs.contains(URL(string: "https://feeds.example.org/a")!))
        #expect(merged[0].feedURL.absoluteString == "https://example.com/a.xml")
    }

    @Test("Ohne Treffer bei Podcast Index bleibt die Apple-Liste, wie sie ist")
    func appleOnly() {
        let apple = [podcast("X", "https://example.com/x.xml", origin: .appleDirectory),
                     podcast("Y", "https://example.com/y.xml", origin: .appleDirectory)]
        #expect(CatalogMerge.merged([], apple).map(\.title) == ["X", "Y"])
        #expect(CatalogMerge.feedKey(URL(string: "https://WWW.example.com:443/feed/")!)
                == CatalogMerge.feedKey(URL(string: "http://example.com/feed")!))
        #expect(CatalogMerge.feedKey(URL(string: "https://example.com/feed?id=1")!)
                != CatalogMerge.feedKey(URL(string: "https://example.com/feed?id=2")!))
    }
}

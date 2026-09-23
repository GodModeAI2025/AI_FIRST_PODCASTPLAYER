//
//  CatalogFixtures.swift
//  PodcastAISources
//
//  Feste Antworten in den Formen von Apple Podcasts und Podcast Index,
//  für Tests im Paket und für UI-Tests mit `-catalog-fixtures`. Damit
//  laufen beide ohne Netz und sehen jedes Mal dasselbe.
//
//  Die Podcasts sind ausgedacht, die Adressen zeigen auf example.com und
//  example.org. Die Charts sind die eines deutschen Geräts.
//  Nur in Debug-Builds enthalten.
//

#if DEBUG
import Foundation

public enum CatalogFixtures {

    /// Ein ausgedachter Podcast mit allem, was die vier Dienste über ihn sagen.
    struct Show {
        let id: Int
        let title: String
        let author: String
        /// `nil`: Apple kennt keinen Feed dazu. So ein Platz fällt aus den Charts.
        let feed: String?
        /// Rubrik, danach Unterrubrik, wie Apple sie in `genreIds` nennt.
        let genres: [(id: Int, name: String)]
        let summary: String
        let explicit: Bool
        let episodes: Int
        let newest: String
    }

    static let shows: [Show] = [
        Show(id: 1_000_000_001, title: "Morgenlage", author: "Beispielradio",
             feed: "https://example.com/feeds/morgenlage.xml",
             genres: [(1489, "Nachrichten"), (1526, "Nachrichten des Tages")],
             summary: "<p>Die Nachrichten des Tages in <b>zehn Minuten</b>.</p><p>Jeden Morgen um sechs.</p>",
             explicit: false, episodes: 812, newest: "2026-09-23T04:00:00Z"),
        Show(id: 1_000_000_002, title: "Lachen verboten", author: "Studio Beispiel",
             feed: "https://example.com/feeds/lachen-verboten.xml",
             genres: [(1303, "Comedy"), (1495, "Comedy-Interviews")],
             summary: "Zwei Freunde, ein Mikrofon &amp; keine Regeln.",
             explicit: true, episodes: 140, newest: "2026-09-22T16:00:00Z"),
        Show(id: 1_000_000_003, title: "Kalte Spuren", author: "Redaktion Beispiel",
             feed: "https://example.com/feeds/kalte-spuren.xml",
             genres: [(1488, "Wahre Kriminalfälle")],
             summary: "Ungelöste Fälle, sorgfältig recherchiert.",
             explicit: false, episodes: 64, newest: "2026-09-21T07:00:00Z"),
        Show(id: 1_000_000_004, title: "Code und Kaffee", author: "Beispiel Tech",
             feed: "https://example.com/feeds/code-und-kaffee.xml",
             genres: [(1318, "Technologie")],
             summary: "Softwareentwicklung ohne Buzzwords.",
             explicit: false, episodes: 212, newest: "2026-09-19T12:00:00Z"),
        Show(id: 1_000_000_005, title: "Morning Signal", author: "Example Public Radio",
             feed: "https://example.com/feeds/morning-signal.xml",
             genres: [(1489, "Nachrichten")],
             summary: "The day's news in fifteen minutes.",
             explicit: false, episodes: 1_204, newest: "2026-09-23T05:00:00Z"),
        Show(id: 1_000_000_006, title: "Deep Field Notes", author: "Example Observatory",
             feed: "https://example.com/feeds/deep-field.xml",
             genres: [(1538, "Astronomie"), (1533, "Wissenschaft")],
             summary: "Astronomy for curious people.",
             explicit: false, episodes: 88, newest: "2026-09-20T09:00:00Z"),
        Show(id: 1_000_000_007, title: "Wissen kompakt", author: "Beispiel Wissen",
             feed: "https://example.com/feeds/wissen-kompakt.xml",
             genres: [(1533, "Wissenschaft"), (1304, "Bildung")],
             summary: "Forschung verständlich erklärt.",
             explicit: false, episodes: 301, newest: "2026-09-18T06:00:00Z"),
        Show(id: 1_000_000_008, title: "Anpfiff", author: "Beispiel Sport",
             feed: "https://example.com/feeds/anpfiff.xml",
             genres: [(1546, "Fußball"), (1545, "Sport")],
             summary: "Fußball nach dem Schlusspfiff.",
             explicit: false, episodes: 97, newest: "2026-09-22T21:00:00Z"),
        Show(id: 1_000_000_009, title: "Kurs und Kapital", author: "Beispiel Finanz",
             feed: "https://example.com/feeds/kurse.xml",
             genres: [(1412, "Investitionen"), (1321, "Wirtschaft")],
             summary: "Geld, Märkte und was sie bewegt.",
             explicit: false, episodes: 156, newest: "2026-09-17T05:00:00Z"),
        Show(id: 1_000_000_010, title: "Story Time Tales", author: "Example Family Audio",
             feed: "https://example.com/feeds/story-time.xml",
             genres: [(1305, "Kinder und Familie"), (1521, "Geschichten für Kinder")],
             summary: "Bedtime stories for kids.",
             explicit: false, episodes: 45, newest: "2026-09-16T18:00:00Z"),
        Show(id: 1_000_000_011, title: "Ohne Feed", author: "Beispiel",
             feed: nil,
             genres: [(1489, "Nachrichten")],
             summary: "Steht in den Charts, hat aber keinen Feed.",
             explicit: false, episodes: 3, newest: "2026-09-10T05:00:00Z"),
    ]

    /// Steht nur in Apples Suche.
    static let klatsch = Show(id: 1_000_000_012, title: "Kaffeeklatsch", author: "Beispiel Familie",
                              feed: "https://example.com/feeds/kaffeeklatsch.xml",
                              genres: [(1324, "Gesellschaft und Kultur")],
                              summary: "Gespräche am Küchentisch.",
                              explicit: true, episodes: 48, newest: "2026-09-12T08:00:00Z")

    /// Steht nur in der Suche von Podcast Index.
    static let bohnenfunk = Show(id: 1_000_000_013, title: "Bohnenfunk", author: "Unabhängige Röster",
                                 feed: "https://example.org/bohnenfunk/rss",
                                 genres: [(1502, "Freizeit")],
                                 summary: "Ein kleiner Podcast über Kaffee.",
                                 explicit: false, episodes: 21, newest: "2026-09-15T10:00:00-0500")

    // MARK: Transport

    /// Beantwortet Anfragen an die Charts, an `lookup` und an beide Suchen.
    /// Die Charts einer Rubrik enthalten nur die Podcasts dieser Rubrik, wie
    /// Apple es täte.
    public static let transport: CatalogTransport = { url, _ in
        let host = url.host() ?? ""
        let path = url.path()
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if host == "rss.marketingtools.apple.com", path.contains("/podcasts/top/") {
            return CatalogHTTPResponse(status: 200, body: data(topChart))
        }
        if host == "itunes.apple.com", path.contains("/rss/toppodcasts/") {
            let genre = path.components(separatedBy: "genre=").last.flatMap { Int($0.prefix { $0.isNumber }) }
            return CatalogHTTPResponse(status: 200, body: data(genreChart(genreID: genre ?? 0)))
        }
        if host == "itunes.apple.com", path == "/lookup" {
            let ids = (query["id"] ?? "").split(separator: ",").compactMap { Int($0) }
            return CatalogHTTPResponse(status: 200, body: data(lookup(ids)))
        }
        if host == "itunes.apple.com", path == "/search" {
            return CatalogHTTPResponse(status: 200, body: data(appleSearch))
        }
        if host == "api.podcastindex.org", path == "/search" {
            return CatalogHTTPResponse(status: 200, body: data(podcastIndexSearch))
        }
        return CatalogHTTPResponse(status: 404, body: Data())
    }

    // MARK: Antworten

    /// Charts eines Landes im Format von `rss.marketingtools.apple.com`.
    static var topChart: [String: Any] {
        ["feed": [
            "title": "Top-Podcasts",
            "country": "de",
            "author": ["name": "Apple", "url": "https://www.apple.com/"],
            "results": shows.map { show in
                [
                    "artistName": show.author,
                    "id": String(show.id),
                    "name": show.title,
                    "kind": "podcasts",
                    "artworkUrl100": "https://example.com/art/\(show.id)/100x100bb.png",
                    // Hier nur die Rubrik, ohne Unterrubrik.
                    "genres": show.genres.filter { CatalogCategory(genreID: $0.id)?.genreID == $0.id }.prefix(1).map { genre in
                        ["genreId": String(genre.id), "name": genre.name,
                         "url": "https://itunes.apple.com/de/genre/id\(genre.id)"]
                    },
                    "url": "https://podcasts.apple.com/de/podcast/id\(show.id)",
                ] as [String: Any]
            },
        ] as [String: Any]]
    }

    /// Charts einer Rubrik im alten RSS-Format. Bei genau einem Platz steht
    /// `entry` als Objekt da, bei keinem fehlt es, wie bei Apple.
    static func genreChart(genreID: Int) -> [String: Any] {
        let matching = shows.filter { show in
            show.genres.contains { CatalogCategory(genreID: $0.id)?.genreID == genreID }
        }
        let entries: [[String: Any]] = matching.map { show in
            let genre = show.genres.first { $0.id == genreID } ?? show.genres[0]
            return [
                "im:name": ["label": show.title],
                "im:image": [55, 60, 170].map { size in
                    ["label": "https://example.com/art/\(show.id)/\(size)x\(size)bb.png",
                     "attributes": ["height": String(size)]] as [String: Any]
                },
                "summary": ["label": show.summary],
                "title": ["label": "\(show.title) - \(show.author)"],
                "id": ["label": "https://podcasts.apple.com/de/podcast/id\(show.id)?uo=2",
                       "attributes": ["im:id": String(show.id)]] as [String: Any],
                "im:artist": ["label": show.author],
                "category": ["attributes": ["im:id": String(genreID), "term": "Genre", "label": genre.name]],
                "im:releaseDate": ["label": show.newest],
            ]
        }
        var feed: [String: Any] = ["title": ["label": "iTunes Store: Top-Podcasts"]]
        if entries.count == 1 {
            feed["entry"] = entries[0]
        } else if !entries.isEmpty {
            feed["entry"] = entries
        }
        return ["feed": feed]
    }

    /// Einzelheiten zu den erfragten Kennungen, in umgekehrter Reihenfolge
    /// und ohne Unbekanntes, wie Apple antwortet.
    static func lookup(_ ids: [Int]) -> [String: Any] {
        let wanted = Set(ids)
        let results = (shows + [klatsch, bohnenfunk]).filter { wanted.contains($0.id) }.reversed()
            .map { directoryResult($0, genreIDsAsText: true, store: "de") }
        return ["resultCount": results.count, "results": results]
    }

    /// Apples Suche nach „kaffee“.
    static var appleSearch: [String: Any] {
        let results = [shows[3], klatsch].map { directoryResult($0, genreIDsAsText: true, store: "de") }
        return ["resultCount": results.count, "results": results]
    }

    /// Die Suche bei Podcast Index nach „kaffee“: derselbe Feed wie bei
    /// Apple in anderer Schreibweise, einer, den nur Podcast Index kennt,
    /// einer mit derselben Adresse wie bei Apple, aber ohne Apple-Kennung,
    /// und einer ohne Feed.
    static var podcastIndexSearch: [String: Any] {
        var code = directoryResult(shows[3], genreIDsAsText: false, store: "us")
        code["feedUrl"] = "http://www.example.com/feeds/code-und-kaffee.xml/"
        var klatschCopy = directoryResult(klatsch, genreIDsAsText: false, store: "us")
        klatschCopy["collectionId"] = 7_004_512
        klatschCopy["collectionViewUrl"] = "https://podcastindex.org/podcast/7004512"
        klatschCopy["feedUrl"] = "https://example.com/feeds/kaffeeklatsch.xml/"
        var withoutFeed = directoryResult(shows[10], genreIDsAsText: false, store: "us")
        withoutFeed["collectionName"] = "Kaffee ohne Feed"
        let results: [[String: Any]] = [
            code, directoryResult(bohnenfunk, genreIDsAsText: false, store: "us"), klatschCopy, withoutFeed,
        ]
        return ["resultCount": results.count, "results": results]
    }

    /// Ein Eintrag wie bei `lookup` und in beiden Suchen.
    static func directoryResult(_ show: Show, genreIDsAsText: Bool, store: String) -> [String: Any] {
        let genreIDs = show.genres.map(\.id) + [CatalogCategory.podcastsGenreID]
        var result: [String: Any] = [
            "wrapperType": "track",
            "kind": "podcast",
            "collectionId": show.id,
            "trackId": show.id,
            "artistName": show.author,
            "collectionName": show.title,
            "trackName": show.title,
            "collectionViewUrl": "https://podcasts.apple.com/\(store)/podcast/id\(show.id)?uo=4",
            "artworkUrl100": "https://example.com/art/\(show.id)/100x100bb.jpg",
            "artworkUrl600": "https://example.com/art/\(show.id)/600x600bb.jpg",
            "releaseDate": show.newest,
            "collectionExplicitness": show.explicit ? "explicit" : "notExplicit",
            "contentAdvisoryRating": show.explicit ? "Explicit" : "Clean",
            "trackCount": show.episodes,
            "primaryGenreName": show.genres[0].name,
            "genreIds": genreIDsAsText ? genreIDs.map { String($0) as Any } : genreIDs.map { $0 as Any },
            "genres": show.genres.map(\.name) + ["Podcasts"],
        ]
        if let feed = show.feed { result["feedUrl"] = feed }
        return result
    }

    private static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    // MARK: Feeds

    /// Ein kleiner RSS-Feed zu jedem ausgedachten Podcast, für die Seite
    /// eines Podcasts: Beschreibung, Website und fünf Folgen im Abstand
    /// einer Woche. Die Folgen haben nur einen Link auf eine Webseite, kein
    /// Audio. `nil` für andere Adressen.
    public static func feed(for url: URL) -> Data? {
        let key = CatalogMerge.feedKey(url)
        guard let show = (shows + [klatsch, bohnenfunk]).first(where: { show in
            show.feed.flatMap(URL.init(string:)).map(CatalogMerge.feedKey) == key
        }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let newest = (try? Date(show.newest, strategy: .iso8601)) ?? Date(timeIntervalSince1970: 1_790_141_400)
        let items = (0..<5).map { index in
            """
                <item>
                  <guid>\(show.id)-\(index)</guid>
                  <title>Folge \(40 - index): Beispiel &amp; Einordnung</title>
                  <link>https://example.com/podcasts/\(show.id)/folge-\(40 - index)</link>
                  <pubDate>\(formatter.string(from: newest.addingTimeInterval(-Double(index) * 7 * 86_400)))</pubDate>
                  <itunes:duration>\(1_800 + index * 420)</itunes:duration>
                </item>
            """
        }
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
              <channel>
                <title>\(show.title)</title>
                <link>https://example.com/podcasts/\(show.id)</link>
                <language>de</language>
                <description><![CDATA[\(show.summary)]]></description>
                <itunes:author>\(show.author)</itunes:author>
            \(items.joined(separator: "\n"))
              </channel>
            </rss>
            """
        return Data(xml.utf8)
    }
}
#endif

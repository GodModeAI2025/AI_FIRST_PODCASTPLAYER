//
//  PodcastIndexFixtures.swift
//  PodcastAISources
//
//  Feste Antworten im Format von Podcast Index, für Tests im Paket und für
//  UI-Tests mit `-catalog-fixtures`. Damit laufen beide ohne Netz und ohne
//  Zugangsdaten und sehen jedes Mal dasselbe.
//
//  Die Podcasts sind ausgedacht. Die Adressen zeigen auf example.com.
//  Nur in Debug-Builds enthalten.
//

#if DEBUG
import Foundation

public enum PodcastIndexFixtures {

    /// Zugangsdaten, die nur der feste Transport annimmt.
    public static let credentials = PodcastIndexCredentials(apiKey: "FIXTUREKEY", apiSecret: "fixture-secret")

    /// Beantwortet Anfragen an die vier Endpunkte des Katalogs aus den
    /// Antworten unten. Trends werden nach `cat` gefiltert, wie der Server
    /// es täte.
    public static let transport: CatalogTransport = { url, _ in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        let path = url.path
        if path.hasSuffix("/search/byterm") {
            return CatalogHTTPResponse(status: 200, body: Data(search.utf8))
        }
        if path.hasSuffix("/podcasts/trending") {
            return CatalogHTTPResponse(status: 200, body: trendingBody(categories: query["cat"]))
        }
        if path.hasSuffix("/podcasts/byfeedid") {
            return CatalogHTTPResponse(status: 200, body: feedBody(id: Int(query["id"] ?? "")))
        }
        if path.hasSuffix("/episodes/byfeedid") {
            return CatalogHTTPResponse(status: 200, body: episodesBody(feedID: Int(query["id"] ?? "") ?? 0))
        }
        return CatalogHTTPResponse(status: 404, body: Data())
    }

    // MARK: Antworten

    /// Zehn Podcasts in fünf Schreibweisen von Deutsch und Englisch.
    public static let trending = #"""
    {
      "status": "true",
      "feeds": [
        {"id": 9001, "url": "https://example.com/feeds/morgenlage.xml", "title": "Morgenlage",
         "description": "<p>Die Nachrichten des Tages in <b>zehn Minuten</b>.</p><p>Jeden Morgen um sechs.</p>",
         "author": "Beispielradio", "image": "https://example.com/art/morgenlage.jpg",
         "artwork": "https://example.com/art/morgenlage.jpg", "newestItemPublishTime": 1790141400,
         "itunesId": 1000000001, "trendScore": 9, "language": "de",
         "categories": {"55": "News", "56": "Daily"}},
        {"id": 9002, "url": "https://example.com/feeds/lachen-verboten.xml", "title": "Lachen verboten",
         "description": "Zwei Freunde, ein Mikrofon &amp; keine Regeln.", "author": "Studio Beispiel",
         "image": "http://example.com/art/lachen.png", "artwork": "", "newestItemPublishTime": 1790096400,
         "itunesId": null, "trendScore": 8, "language": "de-DE",
         "categories": {"16": "Comedy", "17": "Interviews"}},
        {"id": 9003, "url": "https://example.com/feeds/kalte-spuren.xml", "title": "Kalte Spuren",
         "description": "Ungelöste Fälle, sorgfältig recherchiert.", "author": "Redaktion Beispiel",
         "image": "https://example.com/art/kalte-spuren.jpg", "artwork": "https://example.com/art/kalte-spuren.jpg",
         "newestItemPublishTime": 1789977600, "itunesId": 1000000003, "trendScore": 8, "language": "de",
         "categories": {"103": "True Crime"}},
        {"id": 9004, "url": "https://example.com/feeds/code-und-kaffee.xml", "title": "Code und Kaffee",
         "description": "Softwareentwicklung ohne Buzzwords.", "author": "Beispiel Tech",
         "image": "https://example.com/art/code.jpg", "artwork": "https://example.com/art/code.jpg",
         "newestItemPublishTime": 1789819200, "itunesId": 1000000004, "trendScore": 7, "language": "de",
         "categories": {"102": "Technology"}},
        {"id": 9005, "url": "https://example.com/feeds/morning-signal.xml", "title": "Morning Signal",
         "description": "The day's news in fifteen minutes.", "author": "Example Public Radio",
         "image": "https://example.com/art/signal.jpg", "artwork": "https://example.com/art/signal.jpg",
         "newestItemPublishTime": 1790136000, "itunesId": 1000000005, "trendScore": 9, "language": "en-us",
         "categories": {"55": "News", "56": "Daily"}},
        {"id": 9006, "url": "https://example.com/feeds/deep-field.xml", "title": "Deep Field Notes",
         "description": "Astronomy for curious people.", "author": "Example Observatory",
         "image": "https://example.com/art/deep-field.jpg", "artwork": "https://example.com/art/deep-field.jpg",
         "newestItemPublishTime": 1789894800, "itunesId": 1000000006, "trendScore": 6, "language": "en",
         "categories": {"67": "Science", "68": "Astronomy"}},
        {"id": 9007, "url": "https://example.com/feeds/wissen-kompakt.xml", "title": "Wissen kompakt",
         "description": "Forschung verständlich erklärt.", "author": "Beispiel Wissen",
         "image": "https://example.com/art/wissen.jpg", "artwork": "https://example.com/art/wissen.jpg",
         "newestItemPublishTime": 1789743600, "itunesId": 1000000007, "trendScore": 6, "language": "de-AT",
         "categories": {"67": "Science", "20": "Education"}},
        {"id": 9008, "url": "https://example.com/feeds/anpfiff.xml", "title": "Anpfiff",
         "description": "Fußball nach dem Schlusspfiff.", "author": "Beispiel Sport",
         "image": "https://example.com/art/anpfiff.jpg", "artwork": "https://example.com/art/anpfiff.jpg",
         "newestItemPublishTime": 1790056800, "itunesId": 1000000008, "trendScore": 5, "language": "de-ch",
         "categories": {"86": "Sports", "96": "Soccer"}},
        {"id": 9009, "url": "https://example.com/feeds/kurse.xml", "title": "Kurs und Kapital",
         "description": "Geld, Märkte und was sie bewegt.", "author": "Beispiel Finanz",
         "image": "https://example.com/art/kurse.jpg", "artwork": "https://example.com/art/kurse.jpg",
         "newestItemPublishTime": 1789639200, "itunesId": 1000000009, "trendScore": 5, "language": "de",
         "categories": {"9": "Business", "12": "Investing"}},
        {"id": 9010, "url": "https://example.com/feeds/story-time.xml", "title": "Story Time Tales",
         "description": "Bedtime stories for kids.", "author": "Example Family Audio",
         "image": "https://example.com/art/story.jpg", "artwork": "https://example.com/art/story.jpg",
         "newestItemPublishTime": 1789542000, "itunesId": 1000000010, "trendScore": 4, "language": "en-GB",
         "categories": {"36": "Kids", "37": "Family", "41": "Stories"}}
      ],
      "count": 10,
      "max": 40,
      "since": 1790050000,
      "description": "Found matching feeds"
    }
    """#

    /// Suche mit einem aufgegebenen Feed, einem Musik-Feed und einem Feed
    /// ohne Adresse. Übrig bleiben zwei.
    public static let search = #"""
    {
      "status": "true",
      "feeds": [
        {"id": 9004, "podcastGuid": "5f3c2a10-0000-4000-8000-000000009004", "title": "Code und Kaffee",
         "url": "https://example.com/feeds/code-und-kaffee.xml",
         "originalUrl": "http://old.example.com/code.xml", "link": "https://example.com/code",
         "description": "Softwareentwicklung ohne Buzzwords.", "author": "Beispiel Tech",
         "ownerName": "Beispiel Tech GmbH", "image": "https://example.com/art/code.jpg",
         "artwork": "https://example.com/art/code.jpg", "lastUpdateTime": 1789819200,
         "itunesId": 1000000004, "language": "de", "explicit": false, "type": 0, "medium": "podcast",
         "dead": 0, "episodeCount": 212, "categories": {"102": "Technology"}, "locked": 0,
         "imageUrlHash": 123456, "newestItemPubdate": 1789819200},
        {"id": 9011, "title": "Kaffeeklatsch", "url": "https://example.com/feeds/kaffeeklatsch.xml",
         "description": "Gespräche am Küchentisch.", "author": "", "ownerName": "Beispiel Familie",
         "image": "https://example.com/art/klatsch.jpg", "artwork": "https://example.com/art/klatsch.jpg",
         "itunesId": null, "language": "de", "explicit": true, "medium": "podcast", "dead": 0,
         "episodeCount": 48, "categories": [], "newestItemPubdate": 1789400000},
        {"id": 9012, "title": "Alter Funkturm", "url": "https://example.com/feeds/funkturm.xml",
         "description": "Eingestellt.", "author": "Niemand", "language": "de", "explicit": false,
         "medium": "podcast", "dead": 1, "episodeCount": 3, "categories": null},
        {"id": 9013, "title": "Beat Kaffee", "url": "https://example.com/feeds/beats.xml",
         "description": "Nur Musik.", "author": "DJ Beispiel", "language": "de", "explicit": false,
         "medium": "music", "dead": 0, "episodeCount": 90, "categories": {"53": "Music"}},
        {"id": 9014, "title": "Ohne Adresse", "url": "", "author": "Beispiel", "dead": 0}
      ],
      "count": 5,
      "query": "kaffee",
      "description": "Found matching feeds"
    }
    """#

    // MARK: Aus den Antworten gebaut

    private static func trendingBody(categories: String?) -> Data {
        guard let categories, !categories.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: Data(trending.utf8)) as? [String: Any],
              let feeds = object["feeds"] as? [[String: Any]] else { return Data(trending.utf8) }
        let wanted = Set(categories.split(separator: ",").map(String.init))
        let matching = feeds.filter { feed in
            let keys = (feed["categories"] as? [String: Any]).map { Set($0.keys) } ?? []
            return !keys.isDisjoint(with: wanted)
        }
        object["feeds"] = matching
        object["count"] = matching.count
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(trending.utf8)
    }

    /// Die Einzelheiten zu einem Podcast aus den Trends, ergänzt um die
    /// Felder, die nur `podcasts/byfeedid` liefert.
    private static func feedBody(id: Int?) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: Data(trending.utf8)) as? [String: Any],
              let feeds = object["feeds"] as? [[String: Any]],
              var feed = feeds.first(where: { ($0["id"] as? Int) == id }) else {
            return Data(#"{"status":"true","feed":[],"description":"No feeds match this id."}"#.utf8)
        }
        let feedID = feed["id"] as? Int ?? 0
        feed["podcastGuid"] = "5f3c2a10-0000-4000-8000-00000000\(feedID)"
        feed["link"] = "https://example.com/podcasts/\(feedID)"
        feed["episodeCount"] = 120 + feedID % 100
        feed["explicit"] = feedID == 9002
        feed["dead"] = 0
        feed["medium"] = "podcast"
        feed["newestItemPubdate"] = feed["newestItemPublishTime"]
        let body: [String: Any] = ["status": "true", "feed": feed, "description": "Found matching feed"]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Fünf Folgen im Abstand von einer Woche, die neueste zuerst.
    private static func episodesBody(feedID: Int) -> Data {
        let newest = 1790141400
        let items: [[String: Any]] = (0..<5).map { index in
            [
                "id": feedID * 100 + index,
                "title": "Folge \(40 - index): Beispiel &amp; Einordnung",
                "datePublished": newest - index * 7 * 86_400,
                "duration": 1_800 + index * 420,
                "explicit": 0,
                "episode": 40 - index,
                "season": 2,
                "episodeType": "full",
                "feedId": feedID,
                "enclosureUrl": "https://example.com/audio/\(feedID)-\(index).mp3",
            ]
        }
        let body: [String: Any] = ["status": "true", "items": items, "liveItems": [], "count": items.count,
                                   "query": String(feedID), "description": "Found matching items"]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}
#endif

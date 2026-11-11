//
//  FeedDateTests.swift
//  PodcastAIKitTests
//
//  Das Datum einer Folge. Feeds schreiben Jahre zweistellig, hängen der Zone
//  einen Kommentar an oder nennen sie „CEST“, und Atom kennt zwei Daten je
//  Eintrag. Ein falsches Datum ist schlimmer als keines: es sortiert eine
//  alte Folge nach oben.
//

import Foundation
import Testing
import PodcastAIKit

@Suite("Datum einer Folge")
struct FeedDateTests {

    private func utc(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    @Test("Zwei- und dreistellige Jahre nach RFC 2822, nie ein Jahr unter 100")
    func shortYears() {
        #expect(FeedDateParser.date(from: "Wed, 01 Jan 25 10:00:00 GMT") == utc("2025-01-01T10:00:00Z"))
        #expect(FeedDateParser.date(from: "Sat, 01 Jan 00 10:00:00 GMT") == utc("2000-01-01T10:00:00Z"))
        #expect(FeedDateParser.date(from: "31 Dec 49 23:30 -0500") == utc("2050-01-01T04:30:00Z"))
        #expect(FeedDateParser.date(from: "Sun, 01 Jan 50 10:00:00 GMT") == utc("1950-01-01T10:00:00Z"))
        #expect(FeedDateParser.date(from: "Fri, 31 Dec 99 10:00:00 GMT") == utc("1999-12-31T10:00:00Z"))
        #expect(FeedDateParser.date(from: "Wed, 01 Jan 125 10:00:00 GMT") == utc("2025-01-01T10:00:00Z"))
        // Ausgeschriebene Jahre bleiben, auch alte aus einem Archiv.
        #expect(FeedDateParser.date(from: "Thu, 01 Jan 1925 10:00:00 GMT") == utc("1925-01-01T10:00:00Z"))
        // Ein Jahr unter 100 in anderer Schreibweise ist kein Datum.
        for text in ["0025-01-01T10:00:00Z", "0025-01-01", "25-01-01 10:00:00", "Wed, 01 Jan 0025 10:00:00 GMT"] {
            #expect(FeedDateParser.date(from: text) == nil, "\(text)")
        }
    }

    @Test("Kommentar hinter der Zone und Zonenkürzel aus Europa")
    func commentsAndEuropeanZones() {
        #expect(FeedDateParser.date(from: "Wed, 15 Jan 2025 10:00:00 +0100 (CET)") == utc("2025-01-15T09:00:00Z"))
        #expect(FeedDateParser.date(from: "Wed, 15 Jan 2025 10:00:00 GMT (UTC)") == utc("2025-01-15T10:00:00Z"))
        // Steht die Zone nur im Kommentar, wird nicht geraten.
        #expect(FeedDateParser.date(from: "Wed, 15 Jan 2025 10:00:00 (CET)") == nil)
        // Feste Offsets: CEST ist +0200, auch an einem Tag im Januar.
        let hours = ["CET": 1, "MEZ": 1, "CEST": 2, "MESZ": 2, "BST": 1, "WET": 0, "WEST": 1, "EET": 2, "EEST": 3]
        let noon = utc("2025-01-15T12:00:00Z")
        for (zone, offset) in hours {
            #expect(FeedDateParser.date(from: "Wed, 15 Jan 2025 12:00:00 \(zone)")
                    == noon?.addingTimeInterval(TimeInterval(-offset * 3600)), "\(zone)")
        }
        // Die Kürzel aus RFC 822 gingen schon vorher und bleiben.
        #expect(FeedDateParser.date(from: "Tue, 15 Jul 2025 10:00:00 EST") == utc("2025-07-15T15:00:00Z"))
        #expect(FeedDateParser.date(from: "Tue, 15 Jul 2025 10:00:00 GMT") == utc("2025-07-15T10:00:00Z"))
    }

    @Test("In Atom zählt published, updated ist nur der Ersatz")
    func atomPublishedWins() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Blog</title>
          <entry>
            <id>a</id><title>Erst updated, wie bei WordPress</title>
            <link rel="alternate" href="https://example.com/a"/>
            <updated>2026-09-20T08:00:00Z</updated>
            <published>2019-03-01T08:00:00Z</published>
          </entry>
          <entry>
            <id>b</id><title>Erst published</title>
            <link rel="alternate" href="https://example.com/b"/>
            <published>2019-04-01T08:00:00Z</published>
            <updated>2026-09-21T08:00:00Z</updated>
          </entry>
          <entry>
            <id>c</id><title>Nur updated</title>
            <link rel="alternate" href="https://example.com/c"/>
            <updated>2026-09-22T08:00:00Z</updated>
          </entry>
        </feed>
        """
        let items = try FeedParser().parse(Data(xml.utf8)).items
        #expect(items.map(\.publishedAt) == [
            utc("2019-03-01T08:00:00Z"), utc("2019-04-01T08:00:00Z"), utc("2026-09-22T08:00:00Z"),
        ])
    }
}

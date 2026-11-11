//
//  FeedLimitTests.swift
//  PodcastAIKitTests
//
//  Große Feeds und alte http-Adressen. Ein Podcast mit 2000 Folgen scheiterte
//  an der Größe, einer mit http-Adresse an App Transport Security.
//

import Foundation
import Testing
import PodcastAIKit

@Suite("Große Feeds und http-Adressen")
struct FeedLimitTests {

    @Test("Feeds dürfen größer sein als andere Texte, der Parser zieht mit")
    func feedLimitCoversLargeFeeds() {
        #expect(SafeHTTP.feedLimit >= 64 * 1024 * 1024)
        #expect(Int64(FeedParser.maximumBytes) == SafeHTTP.feedLimit)
    }

    @Test("Ein abgeschnittener Feed behält die Folgen bis zum Schnitt")
    func truncatedFeedKeepsCompleteItems() throws {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Groß</title>
        """
        for number in (1...40).reversed() {
            xml += """
            <item><guid>folge-\(number)</guid><title>Folge \(number)</title>\
            <enclosure url="https://example.com/\(number).mp3" length="1000" type="audio/mpeg"/></item>
            """
        }
        xml += "</channel></rss>"
        let data = Data(xml.utf8)
        // Mitten in einem späteren Eintrag abgeschnitten, wie beim Laden an der Grenze.
        let cut = data.prefix(data.count * 2 / 3)

        let feed = try FeedParser().parse(Data(cut))

        #expect(feed.items.count > 10)
        #expect(feed.items.first?.title == "Folge 40")
    }

    /// Die Grenze je Textknoten zählt Bytes. Nach Zeichen gezählt lief der
    /// Parser bei jedem Stück durch den ganzen bisherigen Text, und dieser
    /// Feed brauchte Sekunden.
    @Test("Ein Textknoten endet nach einem Megabyte, auch wenn er aus Umlauten besteht")
    func textNodeLimitCountsBytes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Lang</title>
        <item><guid>lang</guid><title>Folge</title>\
        <description>\(String(repeating: "ä", count: 600_000))</description>\
        <enclosure url="https://example.com/lang.mp3" length="1000" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let feed = try FeedParser().parse(Data(xml.utf8))
        let bytes = try #require(feed.items.first?.summary).utf8.count
        #expect(bytes >= 1_000_000)
        #expect(bytes < 1_100_000)
    }

    @Test("http wird zu https, alles andere bleibt")
    func upgradesHTTP() {
        let http = URL(string: "http://feeds.feedburner.com/marketingovercoffee?x=1")!
        #expect(SafeHTTP.secureVariant(of: http).absoluteString == "https://feeds.feedburner.com/marketingovercoffee?x=1")
        let port = URL(string: "http://example.com:80/feed")!
        #expect(SafeHTTP.secureVariant(of: port).absoluteString == "https://example.com/feed")
        let https = URL(string: "https://example.com/feed")!
        #expect(SafeHTTP.secureVariant(of: https) == https)
    }
}

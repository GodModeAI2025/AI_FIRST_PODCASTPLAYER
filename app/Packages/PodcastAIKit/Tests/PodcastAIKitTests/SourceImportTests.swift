//
//  SourceImportTests.swift
//  PodcastAIKitTests
//
//  Abos mitbringen: OPML-Dateien aus anderen Apps und YouTube-Links mit
//  Kanalnamen (`youtube.com/@name`). Beides endete bisher in Handarbeit
//  oder in einer Fehlermeldung.
//

import Foundation
import Testing
import PodcastAIKit
@testable import PodcastAISources

@Suite("OPML lesen und schreiben")
struct OPMLTests {

    @Test("Verschachtelte Gruppen, Schreibweisen und Entitäten")
    func readsTypicalExport() throws {
        let opml = """
        <?xml version="1.0" encoding="utf-8"?>
        <opml version="1.0">
          <head><title>Overcast Podcast Subscriptions</title></head>
          <body>
            <outline text="feeds">
              <outline type="rss" text="Lage &amp; Ausblick" title="Lage" xmlUrl="https://example.com/feed.xml?a=1&amp;b=2" htmlUrl="https://example.com/"/>
              <outline type="rss" text="  Zweiter   Podcast " xmlURL="feed://feeds.example.org/zwei">
                <outline type="podcast-episode" text="Folge 1" url="https://example.org/1.mp3"/>
              </outline>
            </outline>
            <outline text="Ohne Typ" xmlUrl="http://example.net/rss"/>
            <outline text="Doppelt" xmlUrl="https://example.com/feed.xml?a=1&amp;b=2"/>
            <outline text="Kein Feed" htmlUrl="https://example.com/"/>
            <outline text="Datei" xmlUrl="file:///etc/passwd"/>
          </body>
        </opml>
        """
        let feeds = try OPML.feeds(in: Data(opml.utf8))
        #expect(feeds.map(\.feedURL.absoluteString) == [
            "https://example.com/feed.xml?a=1&b=2",
            "https://feeds.example.org/zwei",
            "http://example.net/rss",
        ])
        #expect(feeds[0].title == "Lage & Ausblick")
        #expect(feeds[0].websiteURL?.absoluteString == "https://example.com/")
        #expect(feeds[1].title == "Zweiter Podcast")
    }

    @Test("Ein Feed oder beliebiges XML ist keine Abo-Liste")
    func rejectsOtherFiles() {
        let rss = #"<?xml version="1.0"?><rss version="2.0"><channel><title>x</title></channel></rss>"#
        #expect(throws: OPMLError.notOPML) { try OPML.feeds(in: Data(rss.utf8)) }
        #expect(throws: OPMLError.notOPML) { try OPML.feeds(in: Data("kein xml".utf8)) }
        let empty = #"<opml version="2.0"><head/><body><outline text="leer"/></body></opml>"#
        #expect(throws: OPMLError.noFeeds) { try OPML.feeds(in: Data(empty.utf8)) }
    }

    @Test("Export lässt sich wieder einlesen, Sonderzeichen inklusive")
    func roundTrip() throws {
        let feeds = [
            OPMLFeed(title: "Fragen & \"Antworten\" <live>",
                     feedURL: URL(string: "https://example.com/feed?x=1&y=2")!,
                     websiteURL: URL(string: "https://example.com/")),
            OPMLFeed(title: "Kanal\nmit Umbruch",
                     feedURL: URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ")!),
        ]
        let text = OPML.document(title: "PodcastAI Abos", feeds: feeds)
        #expect(text.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
        let read = try OPML.feeds(in: Data(text.utf8))
        #expect(read.map(\.feedURL) == feeds.map(\.feedURL))
        #expect(read[0].title == "Fragen & \"Antworten\" <live>")
        #expect(read[0].websiteURL == feeds[0].websiteURL)
        #expect(read[1].title == "Kanal mit Umbruch")
    }
}

@Suite("YouTube-Kanalnamen")
struct YouTubeHandleTests {

    @Test("@-Link wird zur Kanalseite, ohne ?si= und ohne Reiter")
    func handleLinkBecomesChannelPage() throws {
        let link = try SourceResolver().resolve("https://youtube.com/@mkbhd?si=AbC123xyz")
        #expect(link == .youTubeChannelPage(handle: "@mkbhd",
                                            pageURL: URL(string: "https://www.youtube.com/@mkbhd")!))
        #expect(link.requiresNetworkDiscovery)
        #expect(FeedDiscovery.pageToInspect(for: link)?.absoluteString == "https://www.youtube.com/@mkbhd")
        #expect(FeedDiscovery.directFeedURL(for: link) == nil)

        let tab = try SourceResolver().resolve("m.youtube.com/@Kanal.Name_1/videos?feature=shared")
        #expect(FeedDiscovery.pageToInspect(for: tab)?.absoluteString == "https://www.youtube.com/@Kanal.Name_1")
    }

    @Test("Alte Formen /c/ und /user/")
    func legacyChannelNames() throws {
        let c = try SourceResolver().resolve("https://www.youtube.com/c/Beispiel?si=x")
        #expect(c == .youTubeChannelPage(handle: "Beispiel",
                                         pageURL: URL(string: "https://www.youtube.com/c/Beispiel")!))
        let user = try SourceResolver().resolve("https://www.youtube.com/user/beispiel/featured")
        #expect(FeedDiscovery.pageToInspect(for: user)?.absoluteString == "https://www.youtube.com/user/beispiel")
    }

    @Test("Auf der Kanalseite zählt der Kanal selbst, nicht ein empfohlener")
    func channelPageIgnoresRecommendedChannels() {
        // Aufbau wie auf youtube.com/@mkbhd: im Seitenskript steht zuerst
        // die Kennung eines empfohlenen Kanals.
        let html = """
        <html><head>
        <link rel="canonical" href="https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ">
        <meta property="og:url" content="https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ">
        </head><body>
        <meta itemprop="identifier" content="UCBJycsmduvYEL83R_U4JriQ">
        <script>var ytInitialData = {"channelId":"UCG7J20LhUeLl6y_Emi7OJrA","externalId":"UCBJycsmduvYEL83R_U4JriQ"};</script>
        </body></html>
        """
        #expect(FeedDiscovery.youTubeChannelID(inHTML: html) == "UCBJycsmduvYEL83R_U4JriQ")

        let scriptOnly = #"<script>{"channelId":"UCG7J20LhUeLl6y_Emi7OJrA","externalId":"UCBJycsmduvYEL83R_U4JriQ"}</script>"#
        #expect(FeedDiscovery.youTubeChannelID(inHTML: scriptOnly) == "UCBJycsmduvYEL83R_U4JriQ")
    }

    @Test("Auf der Videoseite bleibt es beim Kanal des Videos")
    func watchPageStillFindsOwner() {
        let html = """
        <html><head>
        <link rel="canonical" href="https://www.youtube.com/watch?v=eWKY0OnPByg">
        <meta property="og:url" content="https://www.youtube.com/watch?v=eWKY0OnPByg">
        </head><body>
        <meta itemprop="identifier" content="eWKY0OnPByg">
        <script>{"videoDetails":{"videoId":"eWKY0OnPByg","channelId":"UCBJycsmduvYEL83R_U4JriQ"}}</script>
        <a href="/channel/UCMiJRAwDNSNzuYeN2uWa0pA">anderer Kanal</a>
        </body></html>
        """
        #expect(FeedDiscovery.youTubeChannelID(inHTML: html) == "UCBJycsmduvYEL83R_U4JriQ")
    }
}

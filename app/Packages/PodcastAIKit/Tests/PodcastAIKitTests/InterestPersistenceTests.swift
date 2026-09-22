import Testing
import Foundation
@testable import PodcastAIKit

@Suite("Interessen speichern")
struct InterestPersistenceTests {

    @Test("Ein angelegtes Thema erscheint wieder im Profil")
    func topicRoundTrip() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(interest: Interest(label: "Neue KI Modelle", kind: .topic, origin: .confirmedByUser))
        let profile = try await store.interestProfile(learningEnabled: false)
        #expect(profile.topics.map(\.label) == ["Neue KI Modelle"])
    }
}

@Suite("Beta-Feedback 0.1")
struct BetaFeedbackTests {

    @Test("Ein MP3-Link mit Zähler in der Abfrage ist eine Folge, kein Feed und keine Webseite")
    func mp3LinkIsAudio() throws {
        let link = try SourceResolver().resolve(
            "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=webplayer-download")
        guard case .audioFile = link else { Issue.record("aufgelöst als \(link)"); return }
    }

    @Test("Eine Podigee-Seite verweist im Kopf auf ihren Feed")
    func podigeeFeedLink() {
        let html = #"<head><link rel="alternate" type="application/rss+xml" title="Think AI" href="https://think-ai.podigee.io/feed/mp3"></head>"#
        let links = FeedDiscovery.feedLinks(inHTML: html, base: URL(string: "https://think-ai.podigee.io/")!)
        #expect(links.first?.absoluteString == "https://think-ai.podigee.io/feed/mp3")
    }
}

@Suite("Beta-Feedback 0.2")
struct BetaFeedback02Tests {
    @Test("Ein Feed im Aufbau von Transistor wird als Feed erkannt")
    func transistorStyleFeed() throws {
        // Nachgebaut: Stylesheet-Anweisung vor dem rss-Element, Atom-Selbstlink,
        // Podcasting-2.0-Kapitel. Transistor liefert Feeds so aus, und die App
        // hielt die Adresse deshalb für eine Webseite.
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <?xml-stylesheet href="/stylesheet.xsl" type="text/xsl"?>
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <atom:link rel="self" type="application/rss+xml" href="https://feeds.example.com/show"/>
            <title>Beispiel</title>
            <language>de</language>
            <item>
              <title>Folge 1</title>
              <guid isPermaLink="false">abc</guid>
              <enclosure url="https://media.example.com/1.mp3" length="1000" type="audio/mpeg"/>
              <podcast:chapters url="https://share.example.com/1/chapters.json" type="application/json+chapters"/>
            </item>
            <item>
              <title>Folge 2</title>
              <enclosure url="https://media.example.com/2.mp3" length="1000" type="audio/mpeg"/>
            </item>
          </channel>
        </rss>
        """#
        let feed = try FeedParser().parse(Data(xml.utf8))
        #expect(feed.items.count == 2)
        #expect(feed.items.first?.chaptersURL?.absoluteString == "https://share.example.com/1/chapters.json")
    }
}

@Suite("Kapitel und Shownotes")
struct ChapterTests {
    @Test("Podlove-Kapitel und content:encoded werden gelesen")
    func podloveChapters() throws {
        let xml = #"""
        <rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>T</title>
        <item><title>Folge</title><enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
        <psc:chapters version="1.2"><psc:chapter start="00:00:00" title="Intro"/><psc:chapter start="00:02:47.500" title="Anthropic"/></psc:chapters>
        <content:encoded><![CDATA[<p>Shownotes <a href="https://example.com">Link</a></p>]]></content:encoded>
        </item></channel></rss>
        """#
        let item = try #require(FeedParser().parse(Data(xml.utf8)).items.first)
        #expect(item.chapters.map(\.title) == ["Intro", "Anthropic"])
        #expect(item.chapters.last?.start == MediaTime(milliseconds: 167_500))
        #expect(item.shownotesHTML?.contains("Shownotes") == true)
    }

    @Test("JSON-Kapitel aus Podcasting 2.0")
    func jsonChapters() throws {
        let json = #"{"version":"1.2.0","chapters":[{"startTime":34.5,"title":"B"},{"startTime":0,"title":"A"},{"startTime":60,"title":"C","toc":false}]}"#
        let chapters = try ChapterFile.parse(Data(json.utf8))
        #expect(chapters.map(\.title) == ["A", "B"])
    }
}

@Suite("Beta-Feedback 0.3")
struct BetaFeedback03Tests {
    @Test("Das Format einer geladenen Datei ohne Endung wird erkannt")
    func sniffsFormats() {
        #expect(PlayableAsset.mimeType(forHeader: Data("ID3\u{04}\u{00}".utf8)) == "audio/mpeg")
        #expect(PlayableAsset.mimeType(forHeader: Data([0xFF, 0xFB, 0x90, 0x64])) == "audio/mpeg")
        #expect(PlayableAsset.mimeType(forHeader: Data([0xFF, 0xF1, 0x50, 0x80])) == "audio/aac")
        #expect(PlayableAsset.mimeType(forHeader: Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)) == "audio/mp4")
        #expect(PlayableAsset.mimeType(forHeader: Data("OggS\u{00}".utf8)) == "audio/ogg")
        #expect(PlayableAsset.mimeType(forHeader: Data("<html>".utf8)) == nil)
    }

    @Test("Eine MP3 ohne Endung bekommt den MIME-Typ mitgegeben")
    func extensionlessFileGetsMIMEType() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("ID3\u{04}\u{00}\u{00}\u{00}\u{00}\u{00}\u{00}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PlayableAsset.sniffMIMEType(at: url) == "audio/mpeg")
    }
}

//
//  FeedMetadataTests.swift
//  PodcastAIKitTests
//
//  Metadaten aus dem Feed, Kapitel aus Zeitmarken und Kapiteldateien und
//  Transkripte des Anbieters in VTT, SRT und JSON.
//

import Foundation
import Testing
import PodcastAIKit

@Suite("Metadaten, Kapitel und Anbietertranskripte")
struct FeedMetadataTests {

    static let podcastFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
         xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:podcast="https://podcastindex.org/namespace/1.0"
         xmlns:content="http://purl.org/rss/1.0/modules/content/"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
      <title>Technik am Morgen</title>
      <link>https://example.com/show</link>
      <language>de-DE</language>
      <description>Jeden Morgen zehn Minuten Technik.</description>
      <itunes:author>Beispiel Verlag</itunes:author>
      <itunes:explicit>false</itunes:explicit>
      <itunes:image href="https://example.com/cover.jpg"/>
      <itunes:category text="Technology"/>
      <itunes:category text="News">
        <itunes:category text="Tech News"/>
      </itunes:category>
      <category>Technology</category>
      <item>
        <guid>folge-14</guid>
        <title>Folge 14: Datenschutz</title>
        <link>https://example.com/show/14</link>
        <pubDate>Tue, 22 Sep 2026 06:00:00 +0200</pubDate>
        <itunes:duration>00:42:10</itunes:duration>
        <itunes:episode>14</itunes:episode>
        <itunes:season>2</itunes:season>
        <itunes:episodeType>full</itunes:episodeType>
        <itunes:author>Anna Beispiel</itunes:author>
        <itunes:keywords>Datenschutz, USA, Datenschutz</itunes:keywords>
        <category>Recht</category>
        <enclosure url="https://example.com/14.mp3" length="1000" type="audio/mpeg"/>
        <podcast:transcript url="https://example.com/14.json" type="application/json"/>
        <podcast:transcript url="https://example.com/14.vtt" type="text/vtt" language="de"/>
        <content:encoded><![CDATA[
          <p>Heute geht es um Datenschutz.</p>
          <p>00:00 Intro<br/>(03:15) Was die USA planen<br/>12:40 - Fragen der Hörer<br/>1:02:03 – Zu lang</p>
          <p>Treffen um 12:30 Uhr im Studio.</p>
        ]]></content:encoded>
      </item>
      <item>
        <guid>trailer</guid>
        <title>Trailer</title>
        <dc:creator>Redaktion</dc:creator>
        <itunes:episodeType>trailer</itunes:episodeType>
        <itunes:episode>0</itunes:episode>
        <enclosure url="https://example.com/trailer.mp3" length="1000" type="audio/mpeg"/>
        <description>Kurz vorgestellt.</description>
      </item>
    </channel>
    </rss>
    """

    // MARK: Feed

    @Test("Rubriken samt Unterrubriken, Autor, Sprache, explizit und Cover")
    func sourceMetadata() throws {
        let feed = try FeedParser().parse(Data(Self.podcastFeed.utf8))
        #expect(feed.categories == ["Technology", "News", "Tech News"])
        #expect(feed.author == "Beispiel Verlag")
        #expect(feed.language == "de-DE")
        #expect(feed.isExplicit == false)
        #expect(feed.summary == "Jeden Morgen zehn Minuten Technik.")
        #expect(feed.websiteURL?.absoluteString == "https://example.com/show")
        #expect(feed.artworkURL?.absoluteString == "https://example.com/cover.jpg")
    }

    @Test("Staffel, Folge, Art, Autor und Stichworte je Folge")
    func episodeMetadata() throws {
        let feed = try FeedParser().parse(Data(Self.podcastFeed.utf8))
        let first = try #require(feed.items.first)
        #expect(first.episodeNumber == 14)
        #expect(first.season == 2)
        #expect(first.episodeType == "full")
        #expect(first.author == "Anna Beispiel")
        #expect(first.keywords == ["Datenschutz", "USA", "Recht"])
        #expect(first.duration == 42 * 60 + 10)
        #expect(first.publishedAt != nil)
        #expect(first.webPageURL?.absoluteString == "https://example.com/show/14")
        // VTT vor JSON, auch wenn JSON zuerst im Feed steht.
        #expect(first.preferredTimedTranscript?.url.absoluteString == "https://example.com/14.vtt")

        let trailer = try #require(feed.items.last)
        #expect(trailer.episodeType == "trailer")
        #expect(trailer.author == "Redaktion")
        // Folge 0 ist keine Nummer.
        #expect(trailer.episodeNumber == nil)
    }

    @Test("Ein YouTube-Feed liefert Autor und Beschreibung je Video")
    func youTubeEntryMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015"
              xmlns:media="http://search.yahoo.com/mrss/">
          <title>Kanal</title>
          <author><name>Kanal</name></author>
          <entry>
            <id>yt:video:abc</id>
            <yt:videoId>abc</yt:videoId>
            <title>Video</title>
            <link rel="alternate" href="https://www.youtube.com/watch?v=abc"/>
            <author><name>Kanal</name></author>
            <media:group>
              <media:description>Kapitel:
        00:00 Intro
        01:30 Hauptteil
        10:05 Fazit</media:description>
            </media:group>
          </entry>
        </feed>
        """
        let feed = try FeedParser().parse(Data(xml.utf8))
        let entry = try #require(feed.items.first)
        #expect(entry.author == "Kanal")
        let chapters = TimestampChapters.parse(entry.summary)
        #expect(chapters.map(\.title) == ["Intro", "Hauptteil", "Fazit"])
        #expect(chapters.map(\.start.milliseconds) == [0, 90_000, 605_000])
        #expect(chapters.allSatisfy { $0.provenance == .original })
    }

    // MARK: Zeitmarken

    @Test("Zeitmarken in Shownotes werden Kapitel, Uhrzeiten und Zeiten nach dem Ende nicht")
    func timestampChaptersInShownotes() throws {
        let feed = try FeedParser().parse(Data(Self.podcastFeed.utf8))
        let item = try #require(feed.items.first)
        let chapters = TimestampChapters.parse(
            item.shownotesHTML, duration: MediaDuration(seconds: Double(item.duration ?? 0)))
        #expect(chapters.map(\.title) == ["Intro", "Was die USA planen", "Fragen der Hörer"])
        #expect(chapters.map(\.start.milliseconds) == [0, 195_000, 760_000])
    }

    @Test("Stunden, Klammern und Trenner")
    func timestampFormats() {
        let text = """
        [00:00] Begrüßung
        • 05:30 | Nachrichten
        1:02:03 - Titel mit Stunde
        """
        let chapters = TimestampChapters.parse(text)
        #expect(chapters.map(\.title) == ["Begrüßung", "Nachrichten", "Titel mit Stunde"])
        #expect(chapters.last?.start.milliseconds == 3_723_000)
    }

    @Test("Eine einzelne Zeitmarke oder ein später Beginn ergibt keine Kapitel")
    func timestampRequiresChapterList() {
        #expect(TimestampChapters.parse("Ab 00:00 Intro geht es los").isEmpty)
        #expect(TimestampChapters.parse("00:00 Intro").isEmpty)
        #expect(TimestampChapters.parse("05:00 Mitte\n12:00 Ende").isEmpty)
        #expect(TimestampChapters.parse("00:00 Intro\n99:99 Kaputt").isEmpty)
    }

    // MARK: Kapiteldatei

    @Test("Kapiteldatei mit Bild und Link, unsichere Adressen fallen weg")
    func chapterFileImageAndLink() throws {
        let json = """
        {"version": "1.2.0", "chapters": [
          {"startTime": 65.5, "title": "Zweites", "img": "javascript:alert(1)", "url": "https://example.com/b"},
          {"startTime": 0, "title": "Erstes", "img": "https://example.com/a.jpg"},
          {"startTime": 30, "title": "Versteckt", "toc": false}
        ]}
        """
        let chapters = try ChapterFile.parse(Data(json.utf8))
        #expect(chapters.map(\.title) == ["Erstes", "Zweites"])
        #expect(chapters[0].imageURL?.absoluteString == "https://example.com/a.jpg")
        #expect(chapters[1].imageURL == nil)
        #expect(chapters[1].linkURL?.absoluteString == "https://example.com/b")
        #expect(chapters[1].start.milliseconds == 65_500)
    }

    @Test("Gespeicherte Kapitel von vor 0.9 lassen sich weiter lesen")
    func oldChapterDataDecodes() throws {
        let current = try JSONEncoder().encode([Chapter(start: .zero, title: "Intro", provenance: .original)])
        // Das Format ohne Bild und Link ist, was ältere Versionen geschrieben haben.
        #expect(String(decoding: current, as: UTF8.self).contains("imageURL") == false)
        let decoded = try JSONDecoder().decode([Chapter].self, from: current)
        #expect(decoded.first?.title == "Intro")
        #expect(decoded.first?.imageURL == nil)
    }

    // MARK: Anbietertranskripte

    @Test("WebVTT mit Stimmen, Hinweisblock und kurzen Stücken")
    func parsesWebVTT() throws {
        let vtt = """
        WEBVTT

        NOTE Erzeugt vom Hoster

        1
        00:00:00.000 --> 00:00:02.500
        <v Anna>Willkommen zur

        2
        00:00:02.500 --> 00:00:04.000
        <v Anna>Sendung.

        00:04.200 --> 00:00:07.000 align:start
        <v Ben>Danke, <i>Anna</i>!
        """
        let cues = try PublisherTranscript.parse(Data(vtt.utf8))
        #expect(cues.count == 2)
        #expect(cues[0].text == "Willkommen zur Sendung.")
        #expect(cues[0].speaker == "Anna")
        #expect(cues[0].range.start.milliseconds == 0)
        #expect(cues[0].range.end.milliseconds == 4_000)
        #expect(cues[1].text == "Danke, Anna!")
        #expect(cues[1].speaker == "Ben")
        #expect(cues[1].range.start.milliseconds == 4_200)
    }

    @Test("SRT mit Komma in den Millisekunden")
    func parsesSRT() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,250\r\nErster Satz.\r\n\r\n2\r\n00:01:02,000 --> 00:01:05,000\r\nZweiter\r\nSatz.\r\n"
        let cues = try PublisherTranscript.parse(Data(srt.utf8))
        #expect(PublisherTranscript.format(of: srt) == .srt)
        #expect(cues.map(\.text) == ["Erster Satz.", "Zweiter Satz."])
        #expect(cues[0].range.end.milliseconds == 3_250)
        #expect(cues[1].range.start.milliseconds == 62_000)
    }

    @Test("JSON nach Podcasting 2.0, ungültige Zeiten fallen weg")
    func parsesJSONTranscript() throws {
        let json = """
        {"version": "1.0.0", "segments": [
          {"speaker": "Anna", "startTime": 0.5, "endTime": 2.0, "body": "Hallo."},
          {"speaker": "Ben", "startTime": 2.0, "endTime": 1.0, "body": "Rückwärts"},
          {"speaker": "Ben", "startTime": 2.5, "endTime": 4.0, "body": "Hallo Anna."}
        ]}
        """
        let cues = try PublisherTranscript.parse(Data(json.utf8))
        #expect(cues.map(\.text) == ["Hallo.", "Hallo Anna."])
        #expect(cues.map(\.speaker) == ["Anna", "Ben"])
        #expect(cues[0].range.start.milliseconds == 500)
    }

    @Test("Unbekanntes Format ist ein Fehler, keine leere Liste")
    func rejectsUnknownFormat() {
        #expect(throws: PublisherTranscript.ParseError.unknownFormat) {
            try PublisherTranscript.parse(Data("Nur Text ohne Zeitmarken".utf8))
        }
    }

    // MARK: Speichern

    @Test("Metadaten und geladene Kapitel überstehen das nächste Einlesen")
    func metadataAndChaptersPersist() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let sourceID = SourceID(stable: "meta-feed")
        try await store.upsert(source: Source(
            id: sourceID, kind: .podcastRSS, title: "Technik am Morgen",
            summary: "Beschreibung", categories: ["Technology", "Tech News"], isExplicit: false))
        let chapterFile = URL(string: "https://example.com/14.json")!
        let episode = Episode(
            id: EpisodeID(stable: "meta-14"), sourceID: sourceID, title: "Folge 14",
            chaptersURL: chapterFile, author: "Anna", episodeNumber: 14, season: 2,
            episodeType: "full", keywords: ["Datenschutz"])
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)

        let loaded = [Chapter(start: .zero, title: "Intro", provenance: .original,
                              imageURL: URL(string: "https://example.com/a.jpg"))]
        try await store.save(chapters: loaded, forEpisode: episode.id)
        // Das nächste Einlesen liefert wieder nur den Verweis auf die Datei.
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)

        let source = try #require(try await store.sources().first { $0.id == sourceID })
        #expect(source.summary == "Beschreibung")
        #expect(source.categories == ["Technology", "Tech News"])
        #expect(source.isExplicit == false)

        let stored = try #require(try await store.episodes(forSource: sourceID).first)
        #expect(stored.publisherChapters == loaded)
        #expect(stored.author == "Anna")
        #expect(stored.episodeNumber == 14)
        #expect(stored.season == 2)
        #expect(stored.episodeType == "full")
        #expect(stored.keywords == ["Datenschutz"])

        // Verweist der Feed auf eine andere Datei, gelten die alten Kapitel nicht mehr.
        var moved = episode
        moved.chaptersURL = URL(string: "https://example.com/14-neu.json")
        _ = try await store.upsert(episodes: [moved], forSource: sourceID)
        let after = try #require(try await store.episodes(forSource: sourceID).first)
        #expect(after.publisherChapters.isEmpty)
    }
}

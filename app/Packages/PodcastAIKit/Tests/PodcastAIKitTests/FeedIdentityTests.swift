//
//  FeedIdentityTests.swift
//  PodcastAIKitTests
//
//  Woran eine Folge wiedererkannt wird. Die Kennung entsteht aus der GUID
//  des Feeds. Ändert sie sich, liegt die Folge auf allen Geräten doppelt und
//  ihr Hörzustand ist weg. Leere oder mehrfach vergebene GUIDs dürfen
//  trotzdem nicht aus verschiedenen Folgen eine machen.
//

import Foundation
import Testing
import PodcastAIKit
import PodcastAIPlayerKit

@Suite("Kennung einer Folge aus dem Feed")
struct FeedIdentityTests {

    private func rss(_ items: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Podcast</title>
        \(items)
        </channel></rss>
        """.utf8)
    }

    private let source = SourceID(stable: "quelle")

    /// Die Kennungen, wie Uhr und Fernseher sie bilden. Die App rechnet gleich.
    private func episodeIDs(_ feed: ParsedFeed) -> [EpisodeID] {
        FeedImport.episodes(from: feed, sourceID: source).map(\.id)
    }

    /// Die Kennung einer Folge mit diesem Schlüssel: GUID oder Audioadresse.
    private func episodeID(_ key: String) -> EpisodeID {
        EpisodeID(stable: "\(source.rawValue)|\(key)")
    }

    @Test("Leere GUIDs machen aus verschiedenen Folgen nicht eine")
    func emptyGUIDs() throws {
        let feed = try FeedParser().parse(rss("""
        <item><guid isPermaLink="false"></guid><title>Eins</title>
          <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
        <item><guid>   </guid><title>Zwei</title>
          <enclosure url="https://example.com/2.mp3" type="audio/mpeg"/></item>
        <item><guid/><title>Drei</title>
          <enclosure url="https://example.com/3.mp3" type="audio/mpeg"/></item>
        """))
        // Wie ganz ohne GUID: die Audioadresse.
        #expect(feed.items.map(\.guid) == [
            "https://example.com/1.mp3", "https://example.com/2.mp3", "https://example.com/3.mp3",
        ])
        #expect(Set(episodeIDs(feed)).count == 3)
    }

    @Test("Dieselbe GUID an verschiedenen Audiodateien zählt nicht als Kennung")
    func reusedGUID() throws {
        let feed = try FeedParser().parse(rss("""
        <item><guid>https://example.com/</guid><title>Neu</title>
          <enclosure url="https://example.com/3.mp3" type="audio/mpeg"/></item>
        <item><guid>https://example.com/</guid><title>Mitte</title>
          <enclosure url="https://example.com/2.mp3" type="audio/mpeg"/></item>
        <item><guid>https://example.com/</guid><title>Alt</title>
          <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
        <item><guid>eigene</guid><title>Mit eigener GUID</title>
          <enclosure url="https://example.com/0.mp3" type="audio/mpeg"/></item>
        """))
        #expect(feed.items.map(\.guid) == [nil, nil, nil, "eigene"])
        let ids = episodeIDs(feed)
        #expect(Set(ids).count == 4)
        // Dieselbe Kennung wie bei einer Folge ganz ohne GUID.
        #expect(ids.first == episodeID("https://example.com/3.mp3"))
        #expect(ids.last == episodeID("eigene"))
    }

    @Test("Echte Doppelte behalten ihre GUID: gleiche GUID, gleiche Datei")
    func trueDuplicatesKeepGUID() throws {
        let feed = try FeedParser().parse(rss("""
        <item><guid>folge-7</guid><title>Folge 7</title>
          <enclosure url="https://example.com/7.mp3" type="audio/mpeg"/></item>
        <item><guid>folge-7</guid><title>Folge 7, noch einmal</title>
          <enclosure url="https://example.com/7.mp3" type="audio/mpeg"/></item>
        <item><guid>folge-6</guid><title>Folge 6</title>
          <enclosure url="https://example.com/6.mp3" type="audio/mpeg"/></item>
        """))
        #expect(feed.items.map(\.guid) == ["folge-7", "folge-7", "folge-6"])
        #expect(Set(episodeIDs(feed)).count == 2)
    }

    /// Was heute funktioniert, behält seine Kennung Zeichen für Zeichen.
    @Test("Eindeutige GUIDs kommen unverändert heraus")
    func uniqueGUIDsAreUntouched() throws {
        let feed = try FeedParser().parse(rss("""
        <item><guid isPermaLink="false">d996026e-5911-457a-b63a-da9fac3ab5c1</guid><title>UUID</title>
          <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        <item><title>GUID nach dem Anhang</title>
          <enclosure url="https://example.com/b.mp3" type="audio/mpeg"/>
          <guid isPermaLink="true">https://Example.com/Folge?id=7&amp;x=%20y#Teil</guid></item>
        <item><guid><![CDATA[ tag:example.com,2026:Folge mit Leerzeichen ]]></guid><title>CDATA</title>
          <enclosure url="https://example.com/c.mp3" type="audio/mpeg"/></item>
        <item><guid>
            Größe/ÄÖÜ-42
          </guid><title>Umbruch und Umlaute</title>
          <enclosure url="https://example.com/d.mp3" type="audio/mpeg"/></item>
        <item><title>Ohne GUID</title>
          <enclosure url="https://example.com/e.mp3?x=1" type="audio/mpeg"/></item>
        <item><title>Ohne GUID und ohne Audio</title><link>https://example.com/seite</link></item>
        <item><atom:id>urn:x:1</atom:id><guid>zweite-zaehlt-nicht</guid><title>Die erste Angabe gewinnt</title>
          <enclosure url="https://example.com/f.mp3" type="audio/mpeg"/></item>
        """))
        #expect(feed.items.map(\.guid) == [
            "d996026e-5911-457a-b63a-da9fac3ab5c1",
            "https://Example.com/Folge?id=7&x=%20y#Teil",
            "tag:example.com,2026:Folge mit Leerzeichen",
            "Größe/ÄÖÜ-42",
            "https://example.com/e.mp3?x=1",
            "https://example.com/seite",
            "urn:x:1",
        ])

        let youTube = try FeedParser().parse(Data("""
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015">
          <title>Kanal</title>
          <entry><id>yt:video:abc</id><yt:videoId>abc</yt:videoId><title>Video</title>
            <link rel="alternate" href="https://www.youtube.com/watch?v=abc"/></entry>
        </feed>
        """.utf8))
        #expect(youTube.items.map(\.guid) == ["yt:video:abc"])
    }

    // MARK: Audiodatei

    @Test("Ein Anhang ohne Audiotyp zählt über die Dateiendung, Video weiter nicht")
    func enclosureWithoutAudioType() throws {
        let feed = try FeedParser().parse(rss("""
        <item><guid>a</guid><title>Ohne Typ</title><link>https://example.com/a</link>
          <enclosure url="https://example.com/a.mp3?x=1" length="10"/></item>
        <item><guid>b</guid><title>Octet-Stream</title><link>https://example.com/b</link>
          <enclosure url="https://example.com/b.M4A" type="application/octet-stream"/></item>
        <item><guid>c</guid><title>Video</title><link>https://example.com/c</link>
          <enclosure url="https://example.com/c.mp4" type="video/mp4"/></item>
        <item><guid>d</guid><title>Video ohne Typ</title><link>https://example.com/d</link>
          <enclosure url="https://example.com/d.mp4"/></item>
        <item><guid>e</guid><title>Bild</title><link>https://example.com/e</link>
          <enclosure url="https://example.com/e.jpg"/></item>
        <item><guid>f</guid><title>Bild mit Audio-Endung</title><link>https://example.com/f</link>
          <enclosure url="https://example.com/f.mp3" type="image/jpeg"/></item>
        """))
        #expect(feed.items.map { $0.audioURL?.absoluteString } == [
            "https://example.com/a.mp3?x=1", "https://example.com/b.M4A", nil, nil, nil, nil,
        ])
        #expect(feed.items.map(\.guid) == ["a", "b", "c", "d", "e", "f"])
    }

    /// Eine Folge ohne GUID gab es bisher ohne Audio, mit ihrer Seite als
    /// Kennung. Bekommt sie jetzt ihre Audiodatei, bleibt die Kennung, und
    /// eine Datei, die schon galt, wird nicht ersetzt.
    @Test("Die neu erkannte Audiodatei ändert keine Kennung und ersetzt keine Datei")
    func lateAudioKeepsIdentity() throws {
        let feed = try FeedParser().parse(rss("""
        <item><title>Ohne GUID, mit Seite</title><link>https://example.com/seite-1</link>
          <enclosure url="https://example.com/1.mp3"/></item>
        <item><title>Ohne GUID, ohne Seite</title>
          <enclosure url="https://example.com/2.mp3"/></item>
        <item><title>Erst mit Typ, dann ohne</title>
          <enclosure url="https://example.com/3.mp3" type="audio/mpeg"/>
          <enclosure url="https://example.com/3-roh.mp3"/></item>
        <item><title>Erst ohne Typ, dann mit</title>
          <enclosure url="https://example.com/4-roh.mp3"/>
          <enclosure url="https://example.com/4.mp3" type="audio/mpeg"/></item>
        """))
        #expect(feed.items.map { $0.audioURL?.absoluteString } == [
            "https://example.com/1.mp3", "https://example.com/2.mp3",
            "https://example.com/3.mp3", "https://example.com/4.mp3",
        ])
        #expect(feed.items.map(\.guid) == [
            "https://example.com/seite-1", "https://example.com/2.mp3",
            "https://example.com/3.mp3", "https://example.com/4.mp3",
        ])
    }

    // MARK: Relative Adressen

    @Test("Relative Adressen gelten gegen die Adresse des Feeds, ohne sie weiter nicht")
    func relativeURLs() throws {
        let atom = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Blog</title>
          <link rel="alternate" href="/"/>
          <link rel="next" href="?seite=2"/>
          <entry><id>ep1</id><title>Folge 1</title>
            <link rel="alternate" href="./folgen/1"/>
            <link rel="enclosure" href="/media/ep1.mp3"/></entry>
          <entry><id>ep2</id><title>Folge 2</title>
            <link rel="enclosure" type="audio/mpeg" href="//cdn.example.org/ep2.mp3"/>
            <link rel="alternate" href="javascript:alert(1)"/></entry>
        </feed>
        """.utf8)
        let feed = try FeedParser().parse(atom, baseURL: URL(string: "https://example.com/podcast/feed.xml"))
        #expect(feed.websiteURL?.absoluteString == "https://example.com/")
        #expect(feed.nextPageURL?.absoluteString == "https://example.com/podcast/feed.xml?seite=2")
        #expect(feed.items.map { $0.audioURL?.absoluteString } == [
            "https://example.com/media/ep1.mp3", "https://cdn.example.org/ep2.mp3",
        ])
        // Nur http und https, auch nach dem Auflösen.
        #expect(feed.items.map { $0.webPageURL?.absoluteString } == ["https://example.com/podcast/folgen/1", nil])
        // Eine aufgelöste Adresse ist eine gewöhnliche, gleich der ausgeschriebenen.
        #expect(feed.items.first?.audioURL == URL(string: "https://example.com/media/ep1.mp3"))

        // Ohne Adresse des Feeds, oder mit einer Datei als Herkunft, zählt davon nichts.
        #expect(try FeedParser().parse(atom).items.isEmpty)
        #expect(try FeedParser().parse(atom, baseURL: URL(fileURLWithPath: "/tmp/feed.xml")).items.isEmpty)
    }

    /// Feeds schreiben „siriusxm.com“ in `<link>` und meinen die Seite, nicht
    /// einen Pfad neben dem Feed. Aufgelöst zeigte die Adresse ins Leere.
    /// Relativ ist deshalb nur, was mit `/`, `.` oder `?` beginnt.
    @Test("Eine Adresse ohne Schema wird kein Pfad unter der Adresse des Feeds")
    func schemelessHostIsNotRelative() throws {
        let feed = try FeedParser().parse(rss("""
        <link>siriusxm.com</link>
        <item><guid>a</guid><title>Seite ohne Schema</title><link>siriusxm.com</link>
          <enclosure url="https://cdn.example.com/a.mp3" type="audio/mpeg"/></item>
        <item><guid>b</guid><title>Audio ohne Schema</title><link>https://example.com/b</link>
          <enclosure url="www.example.com/b.mp3" type="audio/mpeg"/></item>
        <item><guid>c</guid><title>Platzhalter statt Seite</title><link>n/a</link>
          <enclosure url="https://cdn.example.com/c.mp3" type="audio/mpeg"/></item>
        """), baseURL: URL(string: "https://feeds.example.com/podcast/feed.xml"))
        #expect(feed.websiteURL == nil)
        #expect(feed.items.map { $0.webPageURL?.absoluteString } == [nil, "https://example.com/b", nil])
        #expect(feed.items.map { $0.audioURL?.absoluteString } == [
            "https://cdn.example.com/a.mp3", nil, "https://cdn.example.com/c.mp3",
        ])
    }

    @Test("Auch eine relativ angegebene Audiodatei ändert keine Kennung und ersetzt keine Datei")
    func relativeAudioKeepsIdentity() throws {
        let data = rss("""
        <item><title>Ohne GUID, mit Seite</title><link>https://example.com/seite-1</link>
          <enclosure url="/media/1.mp3" type="audio/mpeg"/></item>
        <item><title>Vollständig und relativ gemischt</title>
          <enclosure url="https://cdn.example.com/2.mp3" type="audio/mpeg"/>
          <enclosure url="/media/2.mp3" type="audio/mpeg"/>
          <link>https://example.com/seite-2</link>
          <link>/seite-2-relativ</link></item>
        <item><title>Beides relativ</title><link>/seite-3</link>
          <enclosure url="/media/3.mp3" type="audio/mpeg"/></item>
        """)
        let with = try FeedParser().parse(data, baseURL: URL(string: "https://example.com/feed.xml")).items
        let without = try FeedParser().parse(data).items
        #expect(with.map { $0.audioURL?.absoluteString } == [
            "https://example.com/media/1.mp3", "https://cdn.example.com/2.mp3", "https://example.com/media/3.mp3",
        ])
        #expect(with.map { $0.webPageURL?.absoluteString } == [
            "https://example.com/seite-1", "https://example.com/seite-2", "https://example.com/seite-3",
        ])
        // Die dritte Folge gab es ohne die Adresse des Feeds nicht. Sie ist
        // neu und bekommt die Kennung wie jede Folge ohne GUID: Audio vor Seite.
        #expect(with.map(\.guid) == [
            "https://example.com/seite-1", "https://cdn.example.com/2.mp3", "https://example.com/media/3.mp3",
        ])
        #expect(without.map(\.guid) == ["https://example.com/seite-1", "https://cdn.example.com/2.mp3"])
    }
}

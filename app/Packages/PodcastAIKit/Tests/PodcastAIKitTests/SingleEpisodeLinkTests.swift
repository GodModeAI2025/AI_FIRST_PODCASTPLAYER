//
//  SingleEpisodeLinkTests.swift
//  PodcastAIKitTests
//
//  Einzelne Folgen und YouTube-Links: jede Linkform, Folgen aus Apple
//  Podcasts über `?i=`, Folgenseiten von Hostern, Playlists als eigene
//  Quelle und Podcasts, aus denen nur einzelne Folgen geholt wurden.
//
//  Die Seiten sind gekürzte Fassungen echter Seiten von Podigee,
//  Transistor, Apple Podcasts und YouTube (abgerufen am 24. September 2026).
//

import Foundation
import Testing
@testable import PodcastAIKit
@testable import PodcastAISources
@testable import PodcastAIPersistence

// MARK: - YouTube-Links

@Suite("YouTube: jede Linkform")
struct YouTubeLinkFormTests {

    private func resolve(_ text: String) throws -> ResolvedLink { try SourceResolver().resolve(text) }

    @Test("Videos: watch, youtu.be, shorts, live, embed, YouTube Music, ohne Cookies")
    func videos() throws {
        let forms = [
            "https://www.youtube.com/watch?v=pOX1l1edBME&si=abc",
            "https://youtu.be/pOX1l1edBME?t=42",
            "https://www.youtube.com/shorts/pOX1l1edBME",
            "https://www.youtube.com/live/pOX1l1edBME?feature=share",
            "https://m.youtube.com/watch?v=pOX1l1edBME",
            "https://music.youtube.com/watch?v=pOX1l1edBME&list=RDAMVM",
            "https://www.youtube-nocookie.com/embed/pOX1l1edBME",
            "youtube.com/watch?v=pOX1l1edBME",
        ]
        for form in forms {
            guard case .youTubeVideo(let id, let watch, _) = try resolve(form) else {
                Issue.record("Kein Video: \(form)"); continue
            }
            #expect(id == "pOX1l1edBME", "\(form)")
            #expect(watch.absoluteString == "https://www.youtube.com/watch?v=pOX1l1edBME")
        }
    }

    @Test("Kanäle: /channel, /browse bei YouTube Music, @Name, /c, /user")
    func channels() throws {
        let id = "UCBJycsmduvYEL83R_U4JriQ"
        for form in ["https://www.youtube.com/channel/\(id)/videos",
                     "https://music.youtube.com/browse/\(id)",
                     "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"] {
            guard case .youTubeChannel(let channel, let feed) = try resolve(form) else {
                Issue.record("Kein Kanal: \(form)"); continue
            }
            #expect(channel == id)
            #expect(feed.absoluteString == "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")
        }
        for (form, handle) in [("https://www.youtube.com/@mkbhd/featured", "@mkbhd"),
                               ("https://www.youtube.com/c/Beispiel", "Beispiel"),
                               ("https://www.youtube.com/user/beispiel", "beispiel")] {
            guard case .youTubeChannelPage(let name, _) = try resolve(form) else {
                Issue.record("Keine Kanalseite: \(form)"); continue
            }
            #expect(name == handle)
        }
    }

    @Test("Playlists sind eine eigene Quelle mit eigenem Feed, auch als Feed-Link")
    func playlists() throws {
        for form in ["https://www.youtube.com/playlist?list=PL6566A39B68523E18",
                     "https://music.youtube.com/playlist?list=PL6566A39B68523E18",
                     "https://www.youtube.com/feeds/videos.xml?playlist_id=PL6566A39B68523E18"] {
            let link = try resolve(form)
            guard case .youTubePlaylist(let id, _) = link else {
                Issue.record("Keine Playlist: \(form)"); continue
            }
            #expect(id == "PL6566A39B68523E18")
            #expect(FeedDiscovery.directFeedURL(for: link)?.absoluteString
                    == "https://www.youtube.com/feeds/videos.xml?playlist_id=PL6566A39B68523E18")
        }
    }

    @Test("Der Feed einer Playlist nennt Titel, Kanal und Videos mit der Kennung des Kanalfeeds")
    func playlistFeed() throws {
        let data = Data(YouTubeFixtures.playlistFeed.utf8)
        let feed = try FeedParser().parse(data)
        #expect(feed.title == "Explained!")
        #expect(feed.author == "Marques Brownlee")
        #expect(feed.items.first?.guid == "yt:video:pzGsUp3yM8w")
        #expect(feed.items.first?.youTubeVideoID == "pzGsUp3yM8w")
        #expect(YouTubePageInfo.channelID(inFeed: data) == "UCBJycsmduvYEL83R_U4JriQ")
        // Im Kanalfeed steht die Kennung auf Feedebene ohne „UC“.
        let channelFeed = Data(YouTubeFixtures.channelFeedHead.utf8)
        #expect(YouTubePageInfo.channelID(inFeed: channelFeed) == "UCBJycsmduvYEL83R_U4JriQ")
    }

    @Test("Kanal- und Videoseite: Name, Bild, Beschreibung, Kanal und Datum")
    func pages() {
        let channel = YouTubePageInfo.parse(html: YouTubeFixtures.channelPage)
        #expect(channel.title == "Marques Brownlee")
        #expect(channel.summary?.hasPrefix("MKBHD: Quality Tech Videos") == true)
        #expect(channel.imageURL?.host() == "yt3.googleusercontent.com")
        #expect(channel.channelID == "UCBJycsmduvYEL83R_U4JriQ")

        let video = YouTubePageInfo.parse(html: YouTubeFixtures.videoPage)
        #expect(video.title == "The Apple Watch Has a Problem")
        #expect(video.summary?.contains("\"Audio Intelligence\"") == true)
        #expect(video.channelID == "UCBJycsmduvYEL83R_U4JriQ")
        #expect(video.publishedAt == ISO8601DateFormatter().date(from: "2026-09-22T17:49:42Z"))
    }
}

// MARK: - Apple Podcasts

@Suite("Apple Podcasts: Folge über ?i=")
struct AppleEpisodeLinkTests {

    @Test("Podcast und Folge aus dem Link, ohne ?i= nur der Podcast")
    func reference() throws {
        let link = try #require(URL(string:
            "https://podcasts.apple.com/de/podcast/trump-banned/id1200361736?i=1000791084583&uo=4"))
        #expect(EpisodeLinks.appleEpisode(in: link)
                == AppleEpisodeReference(podcastID: "1200361736", episodeID: "1000791084583"))
        let show = try #require(URL(string: "https://podcasts.apple.com/de/podcast/the-daily/id1200361736"))
        #expect(EpisodeLinks.appleEpisode(in: show) == nil)
        #expect(EpisodeLinks.applePodcastID(in: show) == "1200361736")
        let other = try #require(URL(string: "https://example.com/podcast/id1200361736?i=1000791084583"))
        #expect(EpisodeLinks.appleEpisode(in: other) == nil)
        let lookup = try #require(EpisodeLinks.appleEpisodeLookupURL(
            for: AppleEpisodeReference(podcastID: "1200361736", episodeID: "1"), country: "de"))
        #expect(lookup.absoluteString.contains("entity=podcastEpisode"))
        #expect(lookup.absoluteString.contains("limit=200"))
    }

    @Test("Die Antwort von Apple nennt Feed, GUID und Audioadresse der Folge")
    func lookup() throws {
        let result = try AppleEpisodeLookup.parse(Data(AppleFixtures.lookup.utf8), episodeID: "1000791084583")
        #expect(result.feedURL?.absoluteString == "https://feeds.simplecast.com/Sl5CSM3S")
        #expect(result.podcastTitle == "The Daily")
        #expect(result.episode?.guids == ["e8457907-7885-4f02-bcb4-f2a213d743cf"])
        #expect(result.episode?.title == "Trump Banned the Media. This Time, the Media Struck Back.")
        let missing = try AppleEpisodeLookup.parse(Data(AppleFixtures.lookup.utf8), episodeID: "42")
        #expect(missing.episode == nil)
        #expect(missing.feedURL != nil)
    }

    @Test("Die Folge im Feed: über die GUID, sonst über die Audioadresse hinter einem Zähler")
    func matchInFeed() throws {
        let feed = try FeedParser().parse(Data(AppleFixtures.feed.utf8))
        let byGuid = EpisodeLocator(guids: ["e8457907-7885-4f02-bcb4-f2a213d743cf"])
        #expect(EpisodeMatcher.index(of: byGuid, in: feed.items) == 1)

        // Apple nennt die Adresse mit Podtrac davor, der Feed ohne.
        let tracked = try #require(URL(string:
            "https://dts.podtrac.com/redirect.mp3/nyt.simplecastaudio.com/03d8b493/episodes/96b1cb24/audio/128/default.mp3?aid=rss_feed"))
        #expect(EpisodeMatcher.index(of: EpisodeLocator(audioURLs: [tracked]), in: feed.items) == 1)

        // Ältere Folge, nur Titel und GUID von der Seite bei Apple.
        let page = EpisodePageHints.parse(html: AppleFixtures.episodePage,
                                          pageURL: try #require(URL(string: "https://podcasts.apple.com/us/podcast/x/id1200361736?i=1000791084583")))
        #expect(page.locator.guids.contains("e8457907-7885-4f02-bcb4-f2a213d743cf"))
        #expect(EpisodeMatcher.index(of: EpisodeLocator(guids: page.locator.guids, title: page.locator.title),
                                     in: feed.items) == 1)

        #expect(EpisodeMatcher.index(of: EpisodeLocator(guids: ["unbekannt"]), in: feed.items) == nil)
    }
}

// MARK: - Folgenseiten

@Suite("Folgenseiten von Hostern, Overcast und Pocket Casts")
struct HosterEpisodePageTests {

    @Test("Podigee: Feed im Kopf, die Seite ist der <link> der Folge")
    func podigee() throws {
        let page = try #require(URL(string: "https://think-ai.podigee.io/58-doomsday"))
        let hints = EpisodePageHints.parse(html: HosterFixtures.podigeePage, pageURL: page)
        #expect(hints.feedURLs.map(\.absoluteString) == ["https://think-ai.podigee.io/feed/mp3"])
        #expect(hints.locator.title == "Doomsday")
        #expect(hints.artworkURL?.host() == "images.podigee-cdn.net")

        let feed = try FeedParser().parse(Data(HosterFixtures.podigeeFeed.utf8))
        #expect(EpisodeMatcher.index(of: hints.locator, in: feed.items, feedWebsite: feed.websiteURL) == 1)
    }

    @Test("Die Startseite eines Podcasts ist keine Folge, auch wenn Folgen sie als <link> nennen")
    func homePageIsNoEpisode() throws {
        let home = try #require(URL(string: "https://think-ai.podigee.io/"))
        let hints = EpisodePageHints.parse(html: HosterFixtures.podigeeHome, pageURL: home)
        let feed = try FeedParser().parse(Data(HosterFixtures.podigeeFeed.utf8))
        #expect(!hints.feedURLs.isEmpty)
        #expect(EpisodeMatcher.index(of: hints.locator, in: feed.items, feedWebsite: feed.websiteURL) == nil)
    }

    @Test("Transistor: der Titel der Seite trägt den Namen des Podcasts davor")
    func transistor() throws {
        let page = try #require(URL(string: "https://attd.fm/episodes/federated-learning?utm_source=share"))
        let hints = EpisodePageHints.parse(html: HosterFixtures.transistorPage, pageURL: page)
        #expect(hints.feedURLs.map(\.absoluteString) == ["https://feeds.transistor.fm/ai-to-the-dna"])
        let feed = try FeedParser().parse(Data(HosterFixtures.transistorFeed.utf8))
        #expect(EpisodeMatcher.index(of: hints.locator, in: feed.items, feedWebsite: feed.websiteURL) == 0)
        // Auch nur über den Titel, ohne Adresse.
        #expect(EpisodeMatcher.index(of: EpisodeLocator(title: hints.locator.title), in: feed.items) == 0)
    }

    @Test("Overcast-artige Seite: Ton im Player, Podcast über die Apple-Kennung")
    func appPage() throws {
        let page = try #require(URL(string: "https://overcast.fm/+AbCdEfGh"))
        let hints = EpisodePageHints.parse(html: HosterFixtures.overcastStylePage, pageURL: page)
        #expect(hints.feedURLs.isEmpty)
        #expect(hints.applePodcastID == "1200361736")
        #expect(hints.locator.audioURLs.map(\.absoluteString)
                == ["https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=feed"])
        let feed = try FeedParser().parse(Data(HosterFixtures.podigeeFeed.utf8))
        #expect(EpisodeMatcher.index(of: hints.locator, in: feed.items) == 1)
    }

    @Test("og:audio und podcast:guid auf der Seite")
    func openGraphAudio() throws {
        let page = try #require(URL(string: "https://pca.st/episode/0a1b2c3d"))
        let hints = EpisodePageHints.parse(html: HosterFixtures.openGraphAudioPage, pageURL: page)
        #expect(hints.locator.guids == ["54a2c4368f8f141f1e02759bc312c150"])
        #expect(hints.locator.audioURLs.first?.host() == "cdn.example.org")
        let feed = try FeedParser().parse(Data(HosterFixtures.podigeeFeed.utf8))
        #expect(EpisodeMatcher.index(of: hints.locator, in: feed.items) == 0)
    }

    @Test("Nennt die Seite auch andere Folgen, zählt die erste Angabe, nicht die neueste im Feed")
    func pageListsOtherEpisodes() throws {
        let newest = try #require(URL(string: "https://cdn.example.org/neu-folge-mit-langem-namen.mp3"))
        let older = try #require(URL(string: "https://cdn.example.org/alt-folge-mit-langem-namen.mp3"))
        let items = [
            ParsedItem(guid: "neu", title: "Neu", audioURL: newest),
            ParsedItem(guid: "alt", title: "Alt", audioURL: older),
        ]
        #expect(EpisodeMatcher.index(of: EpisodeLocator(guids: ["alt", "neu"]), in: items) == 1)
        #expect(EpisodeMatcher.index(of: EpisodeLocator(audioURLs: [older, newest]), in: items) == 1)
    }

    @Test("Zwei Folgen mit gleichem Titel: keine wird geraten")
    func ambiguousTitle() {
        let items = [ParsedItem(guid: "a", title: "Update"), ParsedItem(guid: "b", title: "Update")]
        #expect(EpisodeMatcher.index(of: EpisodeLocator(title: "Update"), in: items) == nil)
    }
}

// MARK: - Nicht abonniert

@Suite("Podcasts mit einzeln geholten Folgen")
struct NotSubscribedSourceTests {

    private func emptyStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    private let feedURL = URL(string: "https://feeds.example.org/podcast")!

    private func source(subscribed: Bool) -> Source {
        Source(id: SourceID(stable: feedURL.absoluteString), kind: .podcastRSS, title: "Beispiel",
               feedURL: feedURL, isSubscribed: subscribed)
    }

    private func episode(_ key: String, in source: Source) -> Episode {
        Episode(id: EpisodeID(stable: "\(source.id.rawValue)|\(key)"), sourceID: source.id, title: key,
                publishedAt: Date(), audioURL: URL(string: "https://cdn.example.org/\(key).mp3"))
    }

    @Test("Kein Aktualisieren, kein Export, alle Folgen werden vorbereitet")
    func policy() {
        let single = source(subscribed: false)
        #expect(!single.refreshesAutomatically)
        #expect(!single.isExportableSubscription)
        #expect(single.holdsChosenEpisodes)
        let subscribed = source(subscribed: true)
        #expect(subscribed.refreshesAutomatically)
        #expect(subscribed.isExportableSubscription)
        #expect(!subscribed.holdsChosenEpisodes)

        let list = ["a", "b", "c"].map { episode($0, in: single) }
        #expect(PreparationCandidates.newest(in: list, of: single, perSource: 1).count == 3)
        #expect(PreparationCandidates.newest(in: list, of: subscribed, perSource: 1).count == 1)
    }

    @Test("Eine einzelne Folge nimmt kein Abo zurück")
    func singleKeepsSubscription() {
        let fresh = source(subscribed: true)
        #expect(fresh.forSingleEpisode(existing: nil).isSubscribed == false)
        #expect(fresh.forSingleEpisode(existing: source(subscribed: true)).isSubscribed == true)
        #expect(fresh.forSingleEpisode(existing: source(subscribed: false)).isSubscribed == false)
    }

    @Test("Später abonnieren behält die geholte Folge und legt sie nicht doppelt an")
    func subscribeLaterKeepsEpisodes() async throws {
        let store = try emptyStore()
        let single = source(subscribed: false)
        try await store.upsert(source: single)
        _ = try await store.upsert(episodes: [episode("b", in: single)], forSource: single.id)
        #expect(try await store.sources().first?.isSubscribed == false)

        let subscribed = source(subscribed: true)
        try await store.upsert(source: subscribed)
        let inserted = try await store.upsert(
            episodes: ["a", "b", "c"].map { episode($0, in: subscribed) }, forSource: subscribed.id)
        #expect(inserted == 2)
        #expect(try await store.sources().first?.isSubscribed == true)
        #expect(try await store.episodes(forSource: subscribed.id).count == 3)
    }

    @Test("Doppelte Quellzeilen aus dem Abgleich: das Abo gewinnt")
    func duplicateRowsKeepSubscription() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source(subscribed: false))
        try await store.insertSourceCopyForTesting(source(subscribed: true), addedAt: .distantFuture)
        try await store.removeDuplicates()
        let sources = try await store.sources()
        #expect(sources.count == 1)
        #expect(sources.first?.isSubscribed == true)
    }

    @Test("Videos bleiben, auch wenn der Feed sie nicht mehr nennt")
    func videosAccumulate() async throws {
        let store = try emptyStore()
        let channelFeed = try #require(URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ"))
        let channel = Source(id: SourceID(stable: channelFeed.absoluteString), kind: .youTubeChannel,
                             title: "Kanal", feedURL: channelFeed, capabilities: .youTubeMetadataOnly)
        try await store.upsert(source: channel)
        func video(_ id: String) -> Episode {
            Episode(id: EpisodeID(stable: "\(channel.id.rawValue)|yt:video:\(id)"), sourceID: channel.id,
                    title: id, webPageURL: URL(string: "https://www.youtube.com/watch?v=\(id)"))
        }
        _ = try await store.upsert(episodes: (0..<15).map { video("old\($0)") }, forSource: channel.id)
        _ = try await store.upsert(episodes: (0..<15).map { video("new\($0)") }, forSource: channel.id)
        #expect(try await store.episodes(forSource: channel.id).count == 30)
    }
}

// MARK: - Seiten und Feeds

enum YouTubeFixtures {
    static let channelPage = """
    <!DOCTYPE html><html><head>
    <link rel="canonical" href="https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ">
    <meta property="og:title" content="Marques Brownlee">
    <meta property="og:url" content="https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ">
    <meta property="og:image" content="https://yt3.googleusercontent.com/qu4TmIaYUlS41-dJ9gZ7DUR3nilvmB5=s900">
    <meta property="og:description" content="MKBHD: Quality Tech Videos | YouTuber | Geek | Consumer Electronics | Tech Head">
    <meta property="og:type" content="profile">
    </head><body><script>var x = {"channelId":"UCxxxxxxxxxxxxxxxxxxxxxx"};</script></body></html>
    """

    static let videoPage = """
    <!DOCTYPE html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=pOX1l1edBME">
    <meta property="og:title" content="The Apple Watch Has a Problem">
    <meta property="og:image" content="https://i.ytimg.com/vi/pOX1l1edBME/maxresdefault.jpg">
    <meta property="og:description" content="Apple Watch series 12 has a new &quot;Audio Intelligence&quot; feature, let&#39;s talk about it">
    <meta itemprop="datePublished" content="2026-09-22T10:49:42-07:00">
    <meta itemprop="uploadDate" content="2026-09-22T10:49:42-07:00">
    </head><body><script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"pOX1l1edBME","channelId":"UCBJycsmduvYEL83R_U4JriQ"}};</script></body></html>
    """

    static let playlistFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <link rel="self" href="http://www.youtube.com/feeds/videos.xml?playlist_id=PL6566A39B68523E18"/>
     <id>yt:playlist:PL6566A39B68523E18</id>
     <yt:playlistId>PL6566A39B68523E18</yt:playlistId>
     <yt:channelId>UCBJycsmduvYEL83R_U4JriQ</yt:channelId>
     <title>Explained!</title>
     <author><name>Marques Brownlee</name><uri>https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ</uri></author>
     <published>2012-04-06T00:16:14+00:00</published>
     <entry>
      <id>yt:video:pzGsUp3yM8w</id>
      <yt:videoId>pzGsUp3yM8w</yt:videoId>
      <yt:channelId>UCBJycsmduvYEL83R_U4JriQ</yt:channelId>
      <title>Pixel Density: Explained!</title>
      <link rel="alternate" href="https://www.youtube.com/watch?v=pzGsUp3yM8w"/>
      <author><name>Marques Brownlee</name></author>
      <published>2012-04-06T00:16:14+00:00</published>
      <media:group>
       <media:thumbnail url="https://i1.ytimg.com/vi/pzGsUp3yM8w/hqdefault.jpg" width="480" height="360"/>
       <media:description>Pixel density explained.</media:description>
      </media:group>
     </entry>
    </feed>
    """

    static let channelFeedHead = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
     <id>yt:channel:BJycsmduvYEL83R_U4JriQ</id>
     <yt:channelId>BJycsmduvYEL83R_U4JriQ</yt:channelId>
     <title>Marques Brownlee</title>
    </feed>
    """
}

enum AppleFixtures {
    static let lookup = """
    {"resultCount":3,"results":[
     {"wrapperType":"track","kind":"podcast","collectionId":1200361736,"trackId":1200361736,
      "artistName":"The New York Times","collectionName":"The Daily",
      "feedUrl":"https://feeds.simplecast.com/Sl5CSM3S",
      "artworkUrl600":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/ab/600x600bb.jpg"},
     {"wrapperType":"podcastEpisode","kind":"podcast-episode","trackId":1000791261066,
      "trackName":"Health Trackers Are Everywhere. Do Babies Need Them, Too?",
      "episodeGuid":"d996026e-5911-457a-b63a-da9fac3ab5c1","collectionName":"The Daily",
      "feedUrl":"https://feeds.simplecast.com/Sl5CSM3S",
      "episodeUrl":"https://dts.podtrac.com/redirect.mp3/nyt.simplecastaudio.com/03d8b493/episodes/16a4ec6f/audio/128/default.mp3?aid=rss_feed"},
     {"wrapperType":"podcastEpisode","kind":"podcast-episode","trackId":1000791084583,
      "trackName":"Trump Banned the Media. This Time, the Media Struck Back.",
      "episodeGuid":"e8457907-7885-4f02-bcb4-f2a213d743cf","collectionName":"The Daily",
      "feedUrl":"https://feeds.simplecast.com/Sl5CSM3S",
      "episodeUrl":"https://dts.podtrac.com/redirect.mp3/nyt.simplecastaudio.com/03d8b493/episodes/96b1cb24/audio/128/default.mp3?aid=rss_feed"}
    ]}
    """

    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
     <title>The Daily</title><link>https://www.nytimes.com/the-daily</link>
     <item><title>Health Trackers Are Everywhere. Do Babies Need Them, Too?</title>
      <guid isPermaLink="false">d996026e-5911-457a-b63a-da9fac3ab5c1</guid>
      <enclosure url="https://nyt.simplecastaudio.com/03d8b493/episodes/16a4ec6f/audio/128/default.mp3?aid=rss_feed&amp;feed=Sl5CSM3S" type="audio/mpeg" length="1"/></item>
     <item><title>Trump Banned the Media. This Time, the Media Struck Back.</title>
      <guid isPermaLink="false">e8457907-7885-4f02-bcb4-f2a213d743cf</guid>
      <enclosure url="https://nyt.simplecastaudio.com/03d8b493/episodes/96b1cb24/audio/128/default.mp3?aid=rss_feed&amp;feed=Sl5CSM3S" type="audio/mpeg" length="1"/></item>
    </channel></rss>
    """

    static let episodePage = """
    <!DOCTYPE html><html><head>
    <meta property="og:title" content="Trump Banned the Media. This Time, the Media Struck Back.">
    <meta property="og:description" content="Podcast Episode · The Daily · September 22 · 28m">
    <meta property="og:site_name" content="Apple Podcasts">
    </head><body><script type="application/json" id="serialized-server-data">[{"data":{"guid":"e8457907-7885-4f02-bcb4-f2a213d743cf","title":"Trump Banned the Media."}}]</script></body></html>
    """
}

enum HosterFixtures {
    static let podigeePage = """
    <!DOCTYPE html><html lang="de"><head>
    <title>Doomsday - Think Different. Think AI.</title>
    <meta property="og:title" content="Doomsday" />
    <meta property="og:type" content="website" />
    <meta property="og:url" content="https://think-ai.podigee.io/58-doomsday" />
    <meta property="og:image" content="https://images.podigee-cdn.net/0x,sRd6=/https://main.podigee-cdn.net/uploads/u73317/6415b4e5.png" />
    <meta name="twitter:player" content="https://think-ai.podigee.io/58-doomsday/embed?context=social" />
    <link rel="alternate" type="application/rss+xml" title="Doomsday - Think Different. Think AI. - Podcast" href="https://think-ai.podigee.io/feed/mp3">
    <link rel="canonical" href="https://think-ai.podigee.io/58-doomsday">
    </head><body></body></html>
    """

    static let podigeeHome = """
    <!DOCTYPE html><html lang="de"><head>
    <meta property="og:title" content="Think Different. Think AI." />
    <meta property="og:url" content="https://think-ai.podigee.io/" />
    <link rel="alternate" type="application/rss+xml" title="Think Different. Think AI. - Podcast" href="https://think-ai.podigee.io/feed/mp3">
    </head><body></body></html>
    """

    static let podigeeFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
     <title>Think Different. Think AI.</title><link>https://think-ai.podigee.io/</link>
     <item><title>Neues aus der KI</title><link>https://think-ai.podigee.io/</link>
      <guid isPermaLink="false">54a2c4368f8f141f1e02759bc312c150</guid>
      <enclosure url="https://audio.podigee-cdn.net/2600000-m-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.mp3?source=feed" type="audio/mpeg" length="1"/></item>
     <item><title>Doomsday</title><link>https://think-ai.podigee.io/58-doomsday</link>
      <guid isPermaLink="false">2f917b7ec67d1420bf8d6ac59309f2be</guid>
      <enclosure url="https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=feed" type="audio/mpeg" length="1"/></item>
    </channel></rss>
    """

    static let transistorPage = """
    <!DOCTYPE html><html><head>
    <meta name="twitter:title" content="AI to the DNA | Federated Learning: Wie Krankenhäuser gemeinsam ein KI-Modell trainieren">
    <meta property="og:url" content="https://attd.fm/episodes/federated-learning">
    <meta property="og:site_name" content="AI to the DNA">
    <meta property="og:title" content="AI to the DNA | Federated Learning: Wie Krankenhäuser gemeinsam ein KI-Modell trainieren">
    <link rel="alternate" type="application/rss+xml" title="AI to the DNA" href="https://feeds.transistor.fm/ai-to-the-dna" />
    </head><body></body></html>
    """

    static let transistorFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>AI to the DNA</title><link>https://attd.fm</link>
     <item><title>Federated Learning: Wie Krankenhäuser gemeinsam ein KI-Modell trainieren</title>
      <link>https://attd.fm/episodes/federated-learning</link>
      <guid isPermaLink="false">0a8fab72-6813-4a52-bdff-9eb6b8dadfdf</guid>
      <enclosure url="https://media.transistor.fm/abc/def.mp3" type="audio/mpeg" length="1"/></item>
     <item><title>Agenten im Mittelstand</title>
      <link>https://attd.fm/episodes/agenten</link>
      <guid isPermaLink="false">1b8fab72-6813-4a52-bdff-9eb6b8dadfdf</guid>
      <enclosure url="https://media.transistor.fm/abc/ghi.mp3" type="audio/mpeg" length="1"/></item>
    </channel></rss>
    """

    /// Aufgebaut wie die öffentliche Folgenseite von Overcast: der Ton im
    /// Player mit Sprungmarke, der Podcast über seine Apple-Kennung.
    static let overcastStylePage = """
    <!DOCTYPE html><html><head><title>Doomsday — Think Different. Think AI. — Overcast</title>
    <meta name="og:title" content="Doomsday — Think Different. Think AI.">
    </head><body>
    <a href="/itunes1200361736/think-different-think-ai" class="ttabletitle">Think Different. Think AI.</a>
    <audio id="audioplayer" preload="none" controls><source src="https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3?source=feed#t=0" type="audio/mpeg"/></audio>
    </body></html>
    """

    static let openGraphAudioPage = """
    <!DOCTYPE html><html><head>
    <meta property="og:title" content="Neues aus der KI">
    <meta property="og:audio" content="https://cdn.example.org/files/neu.mp3">
    <meta name="podcast:guid" content="54a2c4368f8f141f1e02759bc312c150">
    </head><body></body></html>
    """
}

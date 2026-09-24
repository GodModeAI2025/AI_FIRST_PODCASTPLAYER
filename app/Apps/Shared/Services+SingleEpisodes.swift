//
//  Services+SingleEpisodes.swift
//  PodcastAI
//
//  Einzelne Folgen und YouTube-Links. Ein eingefügter Link führt zu einer
//  Vorschau, wenn es etwas zu wählen gibt: eine Folge aus Apple Podcasts,
//  eine Folgenseite eines Hosters oder ein YouTube-Link. Feeds und
//  Audiodateien werden wie bisher gleich angelegt.
//
//  Eine einzeln geholte Folge liegt unter ihrem echten Podcast, der dann
//  als „nicht abonniert“ in der Bibliothek steht. Ihre Kennung ist dieselbe,
//  die ein Abo später vergäbe, damit die Folge dabei nicht doppelt entsteht.
//
//  Was Seiten und Verzeichnisse sagen, ist fremder Text. Es dient nur dazu,
//  eine Folge im Feed zu finden, und wird angezeigt, nie ausgeführt.
//

import Foundation
import PodcastAIKit

/// Was hinter einem eingefügten Link steckt.
public enum LinkTarget: Sendable {
    /// Feed, Webseite mit Feed, Audiodatei: gleich anlegen wie bisher.
    case direct
    /// Eine Folgenseite ohne Feed, aber mit Ton.
    case audioFile(URL, title: String?)
    /// Ein Podcast, meist mit der Folge, die der Link meint.
    case podcast(PodcastLinkPreview)
    /// Ein YouTube-Kanal, ein Video oder eine Playlist.
    case youTube(YouTubeLinkPreview)
}

/// Ein Podcast aus einem Folgenlink, vor dem Abonnieren.
public struct PodcastLinkPreview: Sendable, Identifiable {
    public let id = UUID()
    public let title: String
    public let author: String?
    public let artworkURL: URL?
    public let preview: PodcastPreview
    /// Die Folge, die der Link meint.
    public let episode: PodcastPreview.Item?
    /// Der Link meint eine Folge, die der Feed nicht mehr führt.
    public let episodeMissing: Bool
    public var feedURL: URL? { preview.feedURL }
}

/// Ein YouTube-Link vor dem Abonnieren: Kanal mit Bild, Name und
/// Beschreibung, die neuesten Videos und, falls vorhanden, das Video oder
/// die Playlist aus dem Link.
public struct YouTubeLinkPreview: Sendable, Identifiable {
    public struct Video: Sendable {
        public let id: String
        public let title: String
        public let summary: String?
        public let watchURL: URL
        public let thumbnailURL: URL?
        public let publishedAt: Date?
    }
    public struct Playlist: Sendable {
        public let title: String
        public let feedURL: URL
    }

    public let id = UUID()
    public let channelID: String?
    public let channelName: String
    public let channelFeedURL: URL?
    public let channelPageURL: URL?
    public let summary: String?
    public let artworkURL: URL?
    public let video: Video?
    public let playlist: Playlist?
    /// Die neuesten Videos, aus dem Feed der Playlist oder des Kanals.
    public let latest: [PodcastPreview.Item]
    /// Der Feed des Kanals, falls er gelesen werden konnte.
    let channelFeed: ParsedFeed?
    /// Passende Audio-Podcasts aus dem Verzeichnis. Nur mit ihnen gibt es
    /// Ton, also Transkript und Fakten.
    public var counterparts: [PodcastCounterpart] = []
}

extension FeedRefresher {

    // MARK: Link prüfen

    /// Sieht nach, was ein Link anbietet, ohne etwas anzulegen.
    public func inspect(_ input: String) async throws -> LinkTarget {
        do {
            return try await inspectLink(input)
        } catch {
            throw FeedRefreshError.forSubscription(error, input: input)
        }
    }

    private func inspectLink(_ input: String) async throws -> LinkTarget {
        let text = Self.firstLink(in: input)?.absoluteString ?? input
        if let url = Self.firstLink(in: input) {
            if let reference = EpisodeLinks.appleEpisode(in: url) {
                return try await inspectAppleEpisode(reference, link: url)
            }
            // Ohne Folge wie bisher über das Verzeichnis. Spotify gibt keinen
            // Feed heraus, das sagt das Abonnieren selbst.
            let host = url.host()?.lowercased() ?? ""
            if EpisodeLinks.isApplePodcasts(url) || host.hasSuffix("spotify.com") || host == "spotify.link" {
                return .direct
            }
        }
        let link = try resolver.resolve(text)
        switch link {
        case .youTubeChannel, .youTubeChannelPage, .youTubeVideo, .youTubePlaylist:
            return .youTube(try await youTubePreview(for: link))
        case .webPageNeedingDiscovery(let page):
            return try await inspectPage(page)
        case .podcastFeed, .localFile, .audioFile:
            return .direct
        }
    }

    /// Eine Folge aus Apple Podcasts. Apple nennt Feed, GUID und Audioadresse
    /// der 200 neuesten Folgen. Ist die Folge älter, stehen Titel und GUID
    /// noch auf ihrer Seite bei Apple.
    private func inspectAppleEpisode(_ reference: AppleEpisodeReference, link: URL) async throws -> LinkTarget {
        guard let lookupURL = EpisodeLinks.appleEpisodeLookupURL(for: reference, country: CatalogStorefront.current)
        else { throw FeedRefreshError.appleLinkWithoutFeed }
        let lookupSession = SafeHTTP.makeSession { $0.timeoutIntervalForRequest = 15 }
        defer { lookupSession.finishTasksAndInvalidate() }
        let data = try await SafeHTTP.load(lookupURL, using: lookupSession, limit: 4 * 1024 * 1024)
        guard let lookup = try? AppleEpisodeLookup.parse(data, episodeID: reference.episodeID) else {
            throw PodcastDirectoryError.unreadableAnswer
        }
        guard let feedAddress = lookup.feedURL else { throw FeedRefreshError.appleLinkWithoutFeed }

        var locator = lookup.episode ?? EpisodeLocator()
        if lookup.episode == nil, let data = try? await SafeHTTP.load(link, using: session, limit: Self.pageLimit) {
            locator = EpisodePageHints.parse(html: String(decoding: data, as: UTF8.self), pageURL: link).locator
            // Die Seite bei Apple ist keine Folgenseite des Podcasts.
            locator.pageURLs = []
        }
        let (feedURL, feed) = try await fetchFeed(feedAddress, allowDiscovery: true)
        previewed = (feedURL, feedURL, feed, Date())
        let index = locator.isEmpty ? nil : EpisodeMatcher.index(of: locator, in: feed.items, feedWebsite: feed.websiteURL)
        return .podcast(Self.linkPreview(feed, feedURL: feedURL, index: index, missing: index == nil,
                                         fallbackTitle: lookup.podcastTitle, fallbackArtwork: lookup.artworkURL))
    }

    /// Eine Webseite: selbst ein Feed, die Seite eines Podcasts oder die
    /// Seite einer Folge. Nur wenn der Feed die Folge der Seite führt, gibt
    /// es eine Vorschau mit „Nur diese Folge“; sonst wird wie bisher abonniert.
    private func inspectPage(_ page: URL) async throws -> LinkTarget {
        let data = try await fetch(page)
        if let feed = try? parser.parse(data) {
            previewed = (page, page, feed, Date())
            return .direct
        }
        let hints = EpisodePageHints.parse(html: String(decoding: data, as: UTF8.self), pageURL: page)
        var feedAddress = hints.feedURLs.first
        if feedAddress == nil, let appleID = hints.applePodcastID,
           let appleLink = URL(string: "https://podcasts.apple.com/podcast/id\(appleID)") {
            // Overcast und andere Apps verlinken den Podcast über Apple.
            feedAddress = try? await PodcastDirectory.feedURL(forAppleLink: appleLink)
        }
        guard let feedAddress else {
            if let audio = hints.locator.audioURLs.first {
                return .audioFile(audio, title: hints.locator.title)
            }
            throw FeedRefreshError.noFeedOnPage(page.host() ?? page.absoluteString)
        }
        let (feedURL, feed) = try await fetchFeed(feedAddress, allowDiscovery: true)
        guard let index = EpisodeMatcher.index(of: hints.locator, in: feed.items, feedWebsite: feed.websiteURL) else {
            // Die Seite des Podcasts selbst. Abonniert wird mit dem schon
            // gelesenen Feed.
            previewed = (page, feedURL, feed, Date())
            return .direct
        }
        previewed = (feedURL, feedURL, feed, Date())
        return .podcast(Self.linkPreview(feed, feedURL: feedURL, index: index, missing: false,
                                         fallbackTitle: nil, fallbackArtwork: hints.artworkURL))
    }

    private static func linkPreview(
        _ feed: ParsedFeed, feedURL: URL, index: Int?, missing: Bool,
        fallbackTitle: String?, fallbackArtwork: URL?
    ) -> PodcastLinkPreview {
        let title = feed.title.isEmpty ? (fallbackTitle ?? feedURL.host() ?? "") : feed.title
        return PodcastLinkPreview(
            title: title, author: feed.author,
            artworkURL: feed.artworkURL ?? fallbackArtwork,
            preview: PodcastPreview(feed, feedURL: feedURL),
            episode: index.map { PodcastPreview.item(feed.items[$0], at: $0) },
            episodeMissing: missing)
    }

    // MARK: YouTube

    /// Kanal, Video oder Playlist mit allem, was die Vorschau zeigt. Die
    /// Kanalseite liefert Name, Bild und Beschreibung, der Feed die Videos.
    private func youTubePreview(for link: ResolvedLink) async throws -> YouTubeLinkPreview {
        var channelID: String?
        var video: YouTubeLinkPreview.Video?
        var playlist: YouTubeLinkPreview.Playlist?
        var playlistFeed: ParsedFeed?
        var pageInfo: YouTubePageInfo?

        switch link {
        case .youTubeChannel(let id, _):
            channelID = id
        case .youTubeChannelPage(let handle, let pageURL):
            let data: Data
            do {
                data = try await loadYouTubePage(pageURL)
            } catch HTTPTransferError.httpStatus(404) {
                throw FeedRefreshError.noChannelForHandle(handle)
            }
            let info = YouTubePageInfo.parse(html: String(decoding: data, as: UTF8.self))
            guard let id = info.channelID else { throw FeedRefreshError.noChannelForHandle(handle) }
            channelID = id
            pageInfo = info
        case .youTubeVideo(let videoID, let watchURL, _):
            let data = try await loadYouTubePage(watchURL)
            let info = YouTubePageInfo.parse(html: String(decoding: data, as: UTF8.self))
            guard let id = info.channelID else { throw FeedRefreshError.noChannelForVideo }
            channelID = id
            video = YouTubeLinkPreview.Video(
                id: videoID, title: info.title ?? watchURL.absoluteString, summary: info.summary,
                watchURL: watchURL,
                thumbnailURL: info.imageURL, publishedAt: info.publishedAt)
        case .youTubePlaylist:
            guard let feedURL = FeedDiscovery.directFeedURL(for: link) else { throw FeedRefreshError.needsDiscovery }
            let data: Data
            do {
                data = try await fetch(feedURL)
            } catch {
                throw FeedRefreshError.youTubeFeedUnavailable
            }
            let feed = try parser.parse(data)
            playlistFeed = feed
            playlist = YouTubeLinkPreview.Playlist(
                title: feed.title.isEmpty ? String(localized: "Playlist") : feed.title, feedURL: feedURL)
            channelID = YouTubePageInfo.channelID(inFeed: data)
        default:
            throw FeedRefreshError.needsDiscovery
        }

        // Die Kanalseite: Name, Bild und Beschreibung. Fehlt sie, reicht der Feed.
        if pageInfo == nil, let channelID, let page = YouTubePageInfo.channelPageURL(channelID: channelID) {
            pageInfo = (try? await loadYouTubePage(page)).map {
                YouTubePageInfo.parse(html: String(decoding: $0, as: UTF8.self))
            }
        }
        let channelFeedURL = channelID.flatMap(FeedDiscovery.youTubeFeedURL(forChannel:))
        var channelFeed: ParsedFeed?
        if let channelFeedURL {
            // YouTube liefert den Feed nicht immer. Die Vorschau zeigt dann
            // Kanal und Möglichkeiten ohne Videoliste.
            channelFeed = try? parser.parse(try await fetch(channelFeedURL))
        }
        let name = pageInfo?.title ?? channelFeed?.author ?? channelFeed?.title
            ?? playlistFeed?.author ?? String(localized: "YouTube-Kanal")
        let listed = playlistFeed ?? channelFeed
        let latest = (listed?.items ?? []).enumerated()
            .sorted { ($0.element.publishedAt ?? .distantPast) > ($1.element.publishedAt ?? .distantPast) }
            .prefix(10)
            .map { PodcastPreview.item($0.element, at: $0.offset) }
        return YouTubeLinkPreview(
            channelID: channelID, channelName: name, channelFeedURL: channelFeedURL,
            channelPageURL: channelID.flatMap(YouTubePageInfo.channelPageURL(channelID:)),
            summary: pageInfo?.summary, artworkURL: pageInfo?.imageURL,
            video: video, playlist: playlist, latest: latest, channelFeed: channelFeed)
    }

    /// Ohne das Cookie leitet YouTube in der EU auf eine Einwilligungsseite
    /// um, und dort steht weder Kanal noch Video.
    private func loadYouTubePage(_ url: URL) async throws -> Data {
        try await SafeHTTP.load(url, using: session, limit: Self.pageLimit,
                                headers: ["Cookie": "SOCS=CAI", "Accept-Language": "de"])
    }

    // MARK: Einzeln holen

    /// Legt eine Folge aus einer Vorschau an, ohne den Podcast zu abonnieren.
    /// Ist er schon abonniert, bleibt er es.
    public func addSingleEpisode(key: String, from preview: PodcastPreview) async throws -> AddedSource {
        guard let feedURL = preview.feedURL,
              let item = preview.feed.items.first(where: { Self.episodeKey($0) == key }) else {
            throw FeedRefreshError.episodeNotInFeed
        }
        let feed = preview.feed
        let sourceID = SourceID(stable: feedURL.absoluteString)
        let existing = try await store.sources().first { $0.id == sourceID }
        var capabilities = existing?.capabilities ?? .fullPodcast
        if item.transcripts.contains(where: \.isTimed) { capabilities.publisherTranscript = true }
        let source = Source(
            id: sourceID, kind: existing?.kind ?? .podcastRSS,
            title: feed.title.isEmpty ? (existing?.title ?? feedURL.host() ?? String(localized: "Unbenannter Podcast")) : feed.title,
            author: feed.author ?? existing?.author, feedURL: feedURL,
            websiteURL: feed.websiteURL ?? existing?.websiteURL,
            artworkURL: feed.artworkURL ?? existing?.artworkURL,
            capabilities: capabilities, language: feed.language ?? existing?.language
        ).forSingleEpisode(existing: existing)
        try await store.upsert(source: source)
        _ = try await store.upsert(episodes: [makeEpisode(item, sourceID: sourceID)], forSource: sourceID)
        return AddedSource(title: source.title, episodeCount: 1)
    }

    /// Legt das Video aus einem YouTube-Link unter seinem Kanal an, ohne den
    /// Kanal zu abonnieren. Steht es im Feed, kommt es von dort, sonst von
    /// seiner Seite; die Kennung ist in beiden Fällen dieselbe.
    public func addSingleVideo(from preview: YouTubeLinkPreview) async throws -> AddedSource {
        guard let video = preview.video, let feedURL = preview.channelFeedURL else {
            throw FeedRefreshError.noChannelForVideo
        }
        let sourceID = SourceID(stable: feedURL.absoluteString)
        let existing = try await store.sources().first { $0.id == sourceID }
        let source = Source(
            id: sourceID, kind: .youTubeChannel,
            title: existing?.title ?? preview.channelName,
            author: existing?.author ?? preview.channelName,
            feedURL: feedURL, websiteURL: preview.channelPageURL ?? existing?.websiteURL,
            artworkURL: preview.artworkURL ?? existing?.artworkURL,
            capabilities: existing?.capabilities ?? .youTubeMetadataOnly
        ).forSingleEpisode(existing: existing)
        try await store.upsert(source: source)

        let episode: Episode
        if let item = preview.channelFeed?.items.first(where: { $0.youTubeVideoID == video.id }) {
            episode = makeEpisode(item, sourceID: sourceID)
        } else {
            // Dieselbe Kennung, die der Feed vergäbe: `<id>yt:video:…</id>`.
            episode = Episode(
                id: EpisodeID(stable: "\(sourceID.rawValue)|yt:video:\(video.id)"),
                sourceID: sourceID, title: video.title, summary: video.summary,
                publishedAt: video.publishedAt, artworkURL: video.thumbnailURL,
                webPageURL: video.watchURL)
        }
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        return AddedSource(title: source.title, episodeCount: 1)
    }
}

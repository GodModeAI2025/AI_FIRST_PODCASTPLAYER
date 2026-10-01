//
//  FeedImport.swift
//  PodcastAIPlayerKit
//
//  Macht aus einem gelesenen Feed Folgen. Dieselbe Regel für die Kennung wie
//  in der iOS-App (`Services.makeEpisode`): Podcast und Feed-GUID, nicht der
//  Titel. Dieselbe Folge bekommt so auf jedem Gerät dieselbe Kennung, und der
//  Hörzustand passt zusammen.
//

import Foundation
import PodcastAICore
import PodcastAISources

public enum FeedImport {

    /// Kennung aus der Feed-GUID, sonst der Audioadresse, sonst dem Titel.
    static func episodeKey(_ item: ParsedItem) -> String {
        item.guid ?? item.audioURL?.absoluteString ?? item.title
    }

    public static func episodes(from feed: ParsedFeed, sourceID: SourceID) -> [Episode] {
        feed.items.filter(\.isUsable).map { episode(from: $0, sourceID: sourceID) }
    }

    static func episode(from item: ParsedItem, sourceID: SourceID) -> Episode {
        let duration = item.duration.map { MediaDuration(seconds: Double($0)) }
        // Kapitel: Podlove im Feed, sonst die Kapiteldatei (wird bei Bedarf
        // geladen), sonst die Zeitmarken in Shownotes oder Beschreibung.
        var chapters = item.chapters
        if chapters.isEmpty, item.chaptersURL == nil {
            chapters = TimestampChapters.parse(item.shownotesHTML, duration: duration)
            if chapters.isEmpty { chapters = TimestampChapters.parse(item.summary, duration: duration) }
        }
        return Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(episodeKey(item))"),
            sourceID: sourceID,
            title: item.title,
            summary: item.summary,
            publishedAt: item.publishedAt,
            declaredDuration: duration,
            artworkURL: item.artworkURL,
            webPageURL: item.webPageURL,
            audioURL: item.audioURL,
            publisherChapters: chapters,
            chaptersURL: item.chaptersURL,
            shownotesHTML: item.shownotesHTML,
            author: item.author, episodeNumber: item.episodeNumber, season: item.season,
            episodeType: item.episodeType
        )
    }

    /// Lädt einen Feed und liest ihn. Nur über `SafeHTTP`: Adresse geprüft,
    /// Größe begrenzt.
    public static func fetch(_ feedURL: URL, using session: URLSession) async throws -> ParsedFeed {
        let data = try await SafeHTTP.load(feedURL, using: session, limit: SafeHTTP.feedLimit, truncating: true)
        return try FeedParser().parse(data)
    }
}

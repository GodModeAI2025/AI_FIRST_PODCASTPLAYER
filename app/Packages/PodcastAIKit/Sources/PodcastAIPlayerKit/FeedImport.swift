//
//  FeedImport.swift
//  PodcastAIPlayerKit
//
//  Macht aus einem gelesenen Feed Folgen. Die Kennung kommt aus
//  `ParsedItem.episodeID(in:)` in `PodcastAISources`, derselben Regel wie in
//  der iOS-App: Podcast und Feed-GUID, nicht der Titel. Dieselbe Folge
//  bekommt so auf jedem Gerät dieselbe Kennung, und der Hörzustand passt
//  zusammen.
//

import Foundation
import PodcastAICore
import PodcastAISources

public enum FeedImport {

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
            id: item.episodeID(in: sourceID),
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
    public static func fetch(
        _ feedURL: URL, using session: URLSession, limit: Int64 = SafeHTTP.feedLimit
    ) async throws -> ParsedFeed {
        let data = try await SafeHTTP.load(feedURL, using: session, limit: limit, truncating: true)
        return try FeedParser().parse(data, baseURL: feedURL)
    }
}

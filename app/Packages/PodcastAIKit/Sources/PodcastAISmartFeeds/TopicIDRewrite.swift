//
//  TopicIDRewrite.swift
//  PodcastAISmartFeeds
//
//  Legt der Store zwei Tags zusammen, zeigen Themenfeeds und Ausgaben
//  danach auf die Kennung, die bleibt. Sonst liefe ein Feed mit einem
//  verschwundenen Thema leer.
//
//  Eine Ausgabe bleibt dabei dieselbe: Kennung, Abschnitte, Zeiten und
//  Prüfsumme des Manifests ändern sich nicht, nur die Themenverweise.
//

import Foundation
import PodcastAICore

extension Array where Element == InterestID {
    /// Ersetzt Kennungen laut `map` und nimmt jede nur einmal, in der
    /// bisherigen Reihenfolge.
    public func replacingInterestIDs(_ map: [InterestID: InterestID]) -> [InterestID] {
        var seen: Set<InterestID> = []
        return self.map { map[$0] ?? $0 }.filter { seen.insert($0).inserted }
    }
}

extension SmartPodcastFeed {
    public func replacingTopicIDs(_ map: [InterestID: InterestID]) -> SmartPodcastFeed {
        var copy = self
        copy.topicIDs = topicIDs.replacingInterestIDs(map)
        return copy
    }
}

extension PersonalEpisodeSegment {
    public func replacingTopicIDs(_ map: [InterestID: InterestID]) -> PersonalEpisodeSegment {
        replacing(virtualRange: virtualRange, topicIDs: topicIDs.replacingInterestIDs(map))
    }
}

extension PersonalEpisode {
    /// Berührt die Umschreibung diese Ausgabe?
    public func refersToTopics(in map: [InterestID: InterestID]) -> Bool {
        segments.contains { $0.topicIDs.contains { map[$0] != nil } }
            || overviewEntries.contains { $0.tagIDs.contains { map[$0] != nil } }
    }

    /// Dieselbe Ausgabe mit umgeschriebenen Themen. Die Prüfsumme des
    /// Manifests hängt nur an Fassung und Zeiten und bleibt deshalb gleich.
    public func replacingTopicIDs(_ map: [InterestID: InterestID]) -> PersonalEpisode {
        PersonalEpisode(
            id: id, feedID: feedID, revision: revision, policyRevision: policyRevision,
            batchKey: batchKey, title: title, subtitle: subtitle, publishedAt: publishedAt,
            publicationState: publicationState, consumptionState: consumptionState,
            segments: segments.map { $0.replacingTopicIDs(map) }, shownotes: shownotes,
            coverAssetID: coverAssetID, coverage: coverage, part: part, runKey: runKey,
            overviewEntries: overviewEntries.map {
                $0.replacing(segmentIDs: $0.segmentIDs, virtualStart: $0.virtualStart,
                             tagIDs: $0.tagIDs.replacingInterestIDs(map))
            })
    }
}

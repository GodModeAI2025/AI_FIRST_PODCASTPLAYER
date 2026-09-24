//
//  EditionStatistics.swift
//  PodcastAISmartFeeds
//
//  Die Zahlen für den Kopf des Tabs „Themen-Updates“: wie viele neue
//  Aussagen es je Tag gibt, seit jemand das Update zuletzt gehört hat.
//  Reine Zählung über Kapitel, Fakten und Hörzustand, ohne Modell.
//

import Foundation
import PodcastAICore

/// Neue Aussagen zu einem Tag.
public struct TagStatementCount: Sendable, Hashable, Identifiable {
    public let tagID: InterestID
    public let label: String
    public let count: Int

    public init(tagID: InterestID, label: String, count: Int) {
        self.tagID = tagID; self.label = label; self.count = count
    }

    public var id: InterestID { tagID }
}

/// Die Zahlen eines Themen-Updates.
public struct SmartFeedStatistics: Sendable, Hashable {
    public let feedID: SmartFeedID
    /// Gezählt wird ab hier. `nil`: das Update wurde noch nie gehört, dann
    /// zählt alles Ungehörte.
    public let since: Date?
    /// Je Tag des Updates, in dessen Reihenfolge.
    public let tags: [TagStatementCount]
    /// Alle neuen Aussagen, jede einmal, auch wenn ihr Kapitel zwei Tags trägt.
    public let total: Int

    public init(feedID: SmartFeedID, since: Date?, tags: [TagStatementCount], total: Int) {
        self.feedID = feedID; self.since = since; self.tags = tags; self.total = total
    }

    /// Wann das Update zuletzt gehört wurde: die jüngste Ausgabe, von der
    /// mindestens `heardThreshold` gehört ist. Das Hörprotokoll selbst
    /// merkt sich keinen Zeitpunkt für Ausgaben, deshalb zählt das Datum
    /// der gehörten Ausgabe.
    public static func lastListened(
        to editions: [PersonalEpisode], ledger: ListeningLedger, heardThreshold: Double = 0.8
    ) -> Date? {
        editions
            .filter { $0.heardFraction(in: ledger) >= heardThreshold }
            .map(\.publishedAt)
            .max()
    }

    /// Zählt neue Aussagen je Tag.
    ///
    /// Eine Aussage zählt, wenn ihr Kapitel zum Update passt (Tags, Modus,
    /// Quellen), die Folge nach `since` erschienen ist und die Stelle der
    /// Aussage noch nicht gehört ist.
    public static func compute(
        feed: SmartPodcastFeed,
        chapters: [EditionChapter],
        editions: [PersonalEpisode],
        ledger: ListeningLedger,
        followedTagIDs: Set<InterestID> = [],
        tagLabels: [InterestID: String] = [:],
        heardThreshold: Double = 0.8
    ) -> SmartFeedStatistics {
        let order = feed.topicIDs.isEmpty
            ? followedTagIDs.sorted { (tagLabels[$0] ?? $0.rawValue) < (tagLabels[$1] ?? $1.rawValue) }
            : feed.topicIDs
        let tags = Set(order)
        let since = lastListened(to: editions, ledger: ledger, heardThreshold: heardThreshold)
        let scope = Set(feed.restrictedToSourceIDs)

        var perTag: [InterestID: Int] = [:]
        var seen: Set<String> = []
        for chapter in PersonalEpisodePublisher.unique(chapters)
        where (scope.isEmpty || scope.contains(chapter.sourceID)) && chapter.matches(tags, mode: feed.effectiveMatchMode) {
            if let since {
                guard let published = chapter.originalPublishedAt, published > since else { continue }
            }
            let fresh = chapter.statements.filter { !ledger.state(for: chapter.mediaVersionID).hasHeard($0) }
            guard !fresh.isEmpty else { continue }
            for tag in chapter.tagIDs.intersection(tags) { perTag[tag, default: 0] += fresh.count }
            for statement in fresh {
                seen.insert("\(chapter.mediaVersionID.rawValue)|\(statement.start.milliseconds)|\(statement.end.milliseconds)")
            }
        }
        return SmartFeedStatistics(
            feedID: feed.id, since: since,
            tags: order.map { TagStatementCount(tagID: $0, label: tagLabels[$0] ?? "", count: perTag[$0] ?? 0) },
            total: seen.count)
    }

    /// Für den Kopf des Tabs: je Tag über alle Updates. Trägt ein Tag in
    /// zwei Updates, gilt die größere Zahl, denn es sind dieselben Aussagen.
    public static func header(_ statistics: [SmartFeedStatistics]) -> [TagStatementCount] {
        var best: [InterestID: TagStatementCount] = [:]
        var order: [InterestID] = []
        for entry in statistics.flatMap(\.tags) {
            if let known = best[entry.tagID] {
                if entry.count > known.count { best[entry.tagID] = entry }
            } else {
                best[entry.tagID] = entry
                order.append(entry.tagID)
            }
        }
        return order.compactMap { best[$0] }.filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

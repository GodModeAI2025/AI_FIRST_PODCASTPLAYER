//
//  TagTrends.swift
//  PodcastAIKnowledge
//
//  „Angesagt“ und „Neu“ seit 0.12. Reine Zählung über Kapitel-Tags, Fakten
//  und Hörzustand, ohne Modell und ohne Store, damit prüfbar.
//
//  Angesagt ist ein Tag, wenn es in den letzten sieben Tagen nach
//  Erscheinungsdatum mindestens dreimal so viele Kapitel trägt wie im
//  Wochenschnitt der vier Wochen davor, aus mindestens drei verschiedenen
//  Quellen und mit mindestens fünf Kapiteln. Gefolgte und neutrale Tags
//  zählen gleich. Die Werte stehen in ``TrendThresholds``.
//
//  Neu sind für ein Tag die Aussagen (Fakten) in Kapiteln mit diesem Tag,
//  deren Folge erschienen ist, seit jemand die Seite des Tags zuletzt offen
//  hatte, und die noch nicht gehört sind.
//

import Foundation
import PodcastAICore

// MARK: - Angesagt

/// Die Schwellen für „Angesagt“.
public struct TrendThresholds: Sendable, Hashable {
    /// Das Fenster, das auf einen Trend geprüft wird, in Tagen.
    public var windowDays: Int
    /// So viele Wochen vor dem Fenster bilden den Vergleich.
    public var baselineWeeks: Int
    /// Mindestens so oft wie im Wochenschnitt davor.
    public var minimumRatio: Double
    /// Aus so vielen verschiedenen Quellen muss das Tag im Fenster kommen.
    public var minimumSources: Int
    /// So viele Kapitel muss das Tag im Fenster mindestens tragen.
    public var minimumChapters: Int
    /// So weit muss die Bibliothek vor dem Fenster zurückreichen, in Tagen.
    /// Ohne Vorgeschichte wäre jedes Tag neu und damit angesagt.
    public var minimumHistoryDays: Int

    public init(
        windowDays: Int = 7, baselineWeeks: Int = 4, minimumRatio: Double = 3,
        minimumSources: Int = 3, minimumChapters: Int = 5, minimumHistoryDays: Int = 7
    ) {
        self.windowDays = max(windowDays, 1)
        self.baselineWeeks = max(baselineWeeks, 1)
        self.minimumRatio = max(minimumRatio, 0)
        self.minimumSources = max(minimumSources, 1)
        self.minimumChapters = max(minimumChapters, 1)
        self.minimumHistoryDays = max(minimumHistoryDays, 0)
    }

    /// Die Werte aus dem Plan (Abschnitt 6, offene Entscheidung 5).
    public static let standard = TrendThresholds()
}

/// Ein Tag, das gerade angesagt ist, mit den Zahlen dahinter.
public struct TagTrend: Sendable, Hashable, Identifiable {
    public let normalizedKey: String
    /// Kapitel im Fenster.
    public let recentChapters: Int
    /// Verschiedene Quellen im Fenster.
    public let sourceCount: Int
    /// Kapitel in den Wochen davor.
    public let baselineChapters: Int
    /// Kapitel je Woche davor, über die Wochen, die die Bibliothek abdeckt.
    public let weeklyAverage: Double

    public init(
        normalizedKey: String, recentChapters: Int, sourceCount: Int,
        baselineChapters: Int, weeklyAverage: Double
    ) {
        self.normalizedKey = normalizedKey; self.recentChapters = recentChapters
        self.sourceCount = sourceCount; self.baselineChapters = baselineChapters
        self.weeklyAverage = weeklyAverage
    }

    public var id: String { normalizedKey }

    /// Wie viel öfter als im Wochenschnitt. `nil`: vorher kam das Tag gar
    /// nicht vor.
    public var ratio: Double? {
        weeklyAverage > 0 ? Double(recentChapters) / weeklyAverage : nil
    }
}

/// Ein angesagtes Tag mit dem Tag selbst, so wie die Oberfläche es zeigt.
public struct TrendingTag: Sendable, Hashable, Identifiable {
    public let tag: Tag
    public let trend: TagTrend

    public init(tag: Tag, trend: TagTrend) {
        self.tag = tag; self.trend = trend
    }

    public var id: InterestID { tag.id }
}

public enum TrendDetector {

    private static let day: TimeInterval = 86_400

    /// Die beiden Zeiträume, halb offen wie
    /// `LibraryStore.chapterTagCounts(publishedFrom:to:)`.
    ///
    /// Das Fenster reicht einen Tag über `now` hinaus: Feeds mit falscher
    /// Zeitzone datieren eine Folge manchmal ein paar Stunden in die Zukunft,
    /// und sie gehört trotzdem zu dieser Woche. Gerechnet wird in festen
    /// Tagen zu 24 Stunden, eine Zeitumstellung verschiebt nichts Wichtiges.
    public static func windows(
        now: Date, thresholds: TrendThresholds = .standard
    ) -> (recent: Range<Date>, baseline: Range<Date>) {
        let recentStart = now.addingTimeInterval(-Double(thresholds.windowDays) * day)
        let baselineStart = recentStart.addingTimeInterval(-Double(thresholds.baselineWeeks * 7) * day)
        return (recentStart..<now.addingTimeInterval(day), baselineStart..<recentStart)
    }

    /// Die angesagten Tags, die meisten Kapitel zuerst.
    ///
    /// - Parameters:
    ///   - recent: Kapitel je Tag und Quelle im Fenster.
    ///   - baseline: Kapitel je Tag und Quelle in den Wochen davor.
    ///   - historyStart: das früheste Erscheinungsdatum aller Kapitel-Tags
    ///     der Bibliothek. Reicht die Bibliothek erst zwei Wochen zurück,
    ///     gilt der Schnitt dieser zwei Wochen, nicht der von vier. Fehlt
    ///     die Vorgeschichte oder ist sie kürzer als
    ///     ``TrendThresholds/minimumHistoryDays``, ist nichts angesagt.
    public static func detect(
        recent: [ChapterTagCount],
        baseline: [ChapterTagCount],
        historyStart: Date?,
        now: Date,
        thresholds: TrendThresholds = .standard
    ) -> [TagTrend] {
        guard let historyStart else { return [] }
        let recentStart = windows(now: now, thresholds: thresholds).recent.lowerBound
        let baselineDays = Double(thresholds.baselineWeeks * 7)
        let historyDays = min(max(recentStart.timeIntervalSince(historyStart) / day, 0), baselineDays)
        guard historyDays > 0, historyDays >= Double(thresholds.minimumHistoryDays) else { return [] }
        let observedWeeks = historyDays / 7

        var chapters: [String: Int] = [:]
        var sources: [String: Set<SourceID>] = [:]
        for count in recent where !count.normalizedKey.isEmpty {
            chapters[count.normalizedKey, default: 0] += count.chapterCount
            if !count.sourceID.rawValue.isEmpty {
                sources[count.normalizedKey, default: []].insert(count.sourceID)
            }
        }
        var before: [String: Int] = [:]
        for count in baseline where !count.normalizedKey.isEmpty {
            before[count.normalizedKey, default: 0] += count.chapterCount
        }

        return chapters.compactMap { key, recentChapters -> TagTrend? in
            let sourceCount = sources[key]?.count ?? 0
            guard recentChapters >= thresholds.minimumChapters,
                  sourceCount >= thresholds.minimumSources else { return nil }
            let baselineChapters = before[key] ?? 0
            let average = Double(baselineChapters) / observedWeeks
            guard Double(recentChapters) >= thresholds.minimumRatio * average else { return nil }
            return TagTrend(normalizedKey: key, recentChapters: recentChapters, sourceCount: sourceCount,
                            baselineChapters: baselineChapters, weeklyAverage: average)
        }
        .sorted {
            if $0.recentChapters != $1.recentChapters { return $0.recentChapters > $1.recentChapters }
            if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
            return $0.normalizedKey < $1.normalizedKey
        }
    }

    /// Die angesagten Tags zu den bekannten Tags, in der Reihenfolge der
    /// Trends. Gefolgte und neutrale gleich. Vorschläge und Schlüssel ohne
    /// Tag fallen weg; die Oberfläche kann sie nicht öffnen.
    public static func trendingTags(_ trends: [TagTrend], tags: [Tag]) -> [TrendingTag] {
        var byKey: [String: Tag] = [:]
        for tag in tags where tag.origin != .suggestedBySystem && !tag.normalizedKey.isEmpty {
            // Gibt es nach einem Abgleich kurz zwei Tags mit einem Schlüssel,
            // gilt das gefolgte, sonst das erste.
            if let known = byKey[tag.normalizedKey], known.isFollowed || !tag.isFollowed { continue }
            byKey[tag.normalizedKey] = tag
        }
        return trends.compactMap { trend in byKey[trend.normalizedKey].map { TrendingTag(tag: $0, trend: trend) } }
    }
}

// MARK: - Neu

public enum TagNews {

    /// Neue, ungehörte Aussagen je Tag.
    ///
    /// Eine Aussage zählt für ein Tag, wenn sie in einem Kapitel mit diesem
    /// Tag liegt (gleiche Medienfassung, ihr Anfang im Kapitel), die Folge
    /// nach `since[Tag]` erschienen ist und ihre Stelle noch nicht gehört
    /// ist. Ohne Erscheinungsdatum zählt, wann das Kapitel-Tag entstand, wie
    /// beim Zählen im Store. Tags ohne Eintrag in `since` zählen nicht. Jede
    /// Aussage zählt je Tag einmal, auch wenn ihr Kapitel nach dem Abgleich
    /// doppelt vorliegt.
    public static func counts(
        chapterTags: [ChapterTag],
        facts: [EpisodeFact],
        ledger: ListeningLedger,
        since: [InterestID: Date]
    ) -> [InterestID: Int] {
        guard !since.isEmpty else { return [:] }
        var factsByMedia: [MediaVersionID: [EpisodeFact]] = [:]
        for fact in facts { factsByMedia[fact.mediaVersionID, default: []].append(fact) }

        var counted: [InterestID: Set<String>] = [:]
        for chapter in chapterTags {
            guard let visit = since[chapter.interestID],
                  (chapter.publishedAt ?? chapter.createdAt) > visit,
                  let candidates = factsByMedia[chapter.mediaVersionID] else { continue }
            let state = ledger.state(for: chapter.mediaVersionID)
            for fact in candidates
            where ChapterTagRelevance.contains(chapter, fact.range.start.milliseconds) && !state.hasHeard(fact.range) {
                counted[chapter.interestID, default: []].insert(fact.id)
            }
        }
        return counted.mapValues(\.count)
    }

    /// Neue, ungehörte Aussagen zu einem Tag seit `since`. `chapterTags`
    /// sind die Kapitel dieses Tags.
    public static func count(
        forTag tagID: InterestID,
        chapterTags: [ChapterTag],
        facts: [EpisodeFact],
        ledger: ListeningLedger,
        since: Date
    ) -> Int {
        counts(chapterTags: chapterTags, facts: facts, ledger: ledger, since: [tagID: since])[tagID] ?? 0
    }
}

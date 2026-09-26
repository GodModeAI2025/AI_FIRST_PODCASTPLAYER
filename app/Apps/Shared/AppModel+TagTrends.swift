//
//  AppModel+TagTrends.swift
//  PodcastAI
//
//  „Angesagt“ und „Neu“ seit 0.12. Die Regeln stehen in `TrendDetector`
//  und `TagNews` (PodcastAIKnowledge); hier holt das Modell die Zahlen aus
//  dem Store und merkt sich, wann die Seite eines Tags zuletzt offen war.
//
//  Gerechnet wird nur, wenn eine Ansicht es braucht („Meine Tags“, der Tab
//  „Themen-Updates“, die Seite eines Tags), nicht in der Warteschlange.
//  Nichts hier startet Ton.
//

import Foundation
import PodcastAIKit

/// Was „Angesagt“ neu rechnen lässt: neue, geänderte oder gelöschte
/// Kapitel-Tags. Die Einordnung schreibt Kapitel-Tags, ohne
/// `chapterTagsRevision` zu erhöhen; sie ändert aber `chapterTagCounts`.
struct TagTrendsTrigger: Hashable {
    let revision: Int
    let tags: Int
    let chapters: Int
}

/// Wann und wofür „Angesagt“ zuletzt gerechnet wurde.
struct TagTrendsStamp: Equatable {
    let trigger: TagTrendsTrigger
    let computedAt: Date
}

extension AppModel {

    // MARK: - Angesagt

    /// Die angesagten Tags mit ihrem jetzigen Stand, damit Plus und Minus
    /// in einer Zeile sofort gelten.
    public var trendingTags: [TrendingTag] {
        TrendDetector.trendingTags(tagTrends, tags: profile.tags)
    }

    /// Für `.task(id:)` der Ansichten, die „Angesagt“ zeigen.
    var tagTrendsTrigger: TagTrendsTrigger {
        TagTrendsTrigger(revision: chapterTagsRevision, tags: chapterTagCounts.count,
                         chapters: chapterTagCounts.values.reduce(0, +))
    }

    /// So lange gilt ein Ergebnis, solange sich an den Kapitel-Tags nichts
    /// ändert. Das Fenster wandert mit der Zeit weiter.
    static let tagTrendsLifetime: TimeInterval = 3_600

    /// Rechnet „Angesagt“ neu: zwei Zählungen je Tag und Quelle und das
    /// früheste Datum der Bibliothek, alles im Store und damit abseits des
    /// Hauptthreads. Ein Fehler lässt den letzten Stand stehen.
    public func refreshTagTrends(now: Date = Date()) async {
        let trigger = tagTrendsTrigger
        if let stamp = tagTrendsStamp, stamp.trigger == trigger,
           now.timeIntervalSince(stamp.computedAt) < Self.tagTrendsLifetime { return }
        let windows = TrendDetector.windows(now: now)
        let store = store
        do {
            let recent = try await store.chapterTagCounts(
                publishedFrom: windows.recent.lowerBound, to: windows.recent.upperBound)
            let baseline = try await store.chapterTagCounts(
                publishedFrom: windows.baseline.lowerBound, to: windows.baseline.upperBound)
            let earliest = try await store.earliestChapterTagDate()
            guard !Task.isCancelled else { return }
            let trends = await Task.detached(priority: .utility) {
                TrendDetector.detect(recent: recent, baseline: baseline, historyStart: earliest, now: now)
            }.value
            guard !Task.isCancelled else { return }
            if trends != tagTrends { tagTrends = trends }
            tagTrendsStamp = TagTrendsStamp(trigger: trigger, computedAt: now)
        } catch {
            // „Angesagt“ ist eine Beigabe und bekommt keine Fehlermeldung.
            // Der nächste Anlass rechnet neu.
        }
    }

    // MARK: - Neu seit dem letzten Besuch

    /// Je Tag, wann seine Seite auf diesem Gerät zuletzt offen war. Eine
    /// Datei in `DeviceState`, nicht abgeglichen: Ein Besuch auf dem Mac
    /// soll auf dem iPhone nichts als gesehen markieren.
    nonisolated static let tagPageVisitsKey = "tagPageVisits"

    /// Wann die Seite dieses Tags zuletzt offen war. `nil`: noch nie.
    func lastTagPageVisit(_ id: InterestID) -> Date? {
        DeviceState.shared.value([String: Date].self, for: Self.tagPageVisitsKey)?[id.rawValue]
    }

    /// Merkt sich, dass die Seite eines Tags jetzt offen ist. Tags, die es
    /// nicht mehr gibt, fallen dabei aus der Datei.
    func noteTagPageVisit(_ id: InterestID, at date: Date = Date()) {
        var visits = DeviceState.shared.value([String: Date].self, for: Self.tagPageVisitsKey) ?? [:]
        let known = Set(profile.tags.map(\.id.rawValue))
        if !known.isEmpty { visits = visits.filter { known.contains($0.key) } }
        visits[id.rawValue] = date
        DeviceState.shared.set(visits, for: Self.tagPageVisitsKey)
    }

    /// Neue, ungehörte Aussagen in den Kapiteln eines Tags, deren Folge
    /// nach `since` erschienen ist. `chapters` sind die Kapitel des Tags,
    /// wie sie die Tag-Seite schon geladen hat.
    func newStatementCount(forTag id: InterestID, chapters: [ChapterTag], since: Date) async -> Int {
        let fresh = chapters.filter { $0.interestID == id && ($0.publishedAt ?? $0.createdAt) > since }
        guard !fresh.isEmpty,
              let facts = try? await store.facts(forEpisodes: Set(fresh.map(\.episodeID))),
              !facts.isEmpty else { return 0 }
        return await Task.detached(priority: .utility) { [ledger] in
            TagNews.count(forTag: id, chapterTags: fresh, facts: facts, ledger: ledger, since: since)
        }.value
    }
}

//
//  TagTrendTests.swift
//
//  „Angesagt“ und „Neu“ aus 0.12 mit festen Daten: die Schwellen (Faktor 3,
//  drei Quellen, fünf Kapitel), die ersten Wochen ohne Vorgeschichte, die
//  Zählung im Store und die neuen, ungehörten Aussagen je Tag.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIKnowledge

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let recentStart = now.addingTimeInterval(-7 * day)
/// Eine Bibliothek, die weit genug zurückreicht: vier volle Wochen Vergleich.
private let longHistory = now.addingTimeInterval(-90 * day)

private func count(_ key: String, _ source: String, _ chapters: Int) -> ChapterTagCount {
    ChapterTagCount(normalizedKey: key, sourceID: SourceID(rawValue: source), chapterCount: chapters)
}

/// Sechs Kapitel aus drei Quellen im Fenster.
private let sixFromThree = [count("ios27", "a", 2), count("ios27", "b", 2), count("ios27", "c", 2)]

@Suite("Angesagt: Schwellen")
struct TrendDetectorTests {

    @Test("Die Fenster: sieben Tage bis einen Tag nach jetzt, davor vier Wochen")
    func windows() {
        let windows = TrendDetector.windows(now: now)
        #expect(windows.recent.lowerBound == recentStart)
        #expect(windows.recent.upperBound == now.addingTimeInterval(day))
        #expect(windows.baseline.lowerBound == now.addingTimeInterval(-35 * day))
        #expect(windows.baseline.upperBound == recentStart)

        let custom = TrendDetector.windows(now: now, thresholds: TrendThresholds(windowDays: 3, baselineWeeks: 2))
        #expect(custom.recent.lowerBound == now.addingTimeInterval(-3 * day))
        #expect(custom.baseline.lowerBound == now.addingTimeInterval(-17 * day))
    }

    @Test("Angesagt genau beim Dreifachen des Wochenschnitts, knapp darunter nicht")
    func ratioBoundary() {
        // 8 Kapitel in vier Wochen: Schnitt 2, das Dreifache 6.
        let atThreshold = TrendDetector.detect(
            recent: sixFromThree, baseline: [count("ios27", "a", 8)], historyStart: longHistory, now: now)
        #expect(atThreshold.map(\.normalizedKey) == ["ios27"])
        let trend = atThreshold.first
        #expect(trend?.recentChapters == 6)
        #expect(trend?.sourceCount == 3)
        #expect(trend?.baselineChapters == 8)
        #expect(trend?.weeklyAverage == 2)
        #expect(trend?.ratio == 3)

        // 9 Kapitel: Schnitt 2,25, das Dreifache 6,75 und damit mehr als 6.
        let below = TrendDetector.detect(
            recent: sixFromThree, baseline: [count("ios27", "a", 9)], historyStart: longHistory, now: now)
        #expect(below.isEmpty)
    }

    @Test("Zwei Quellen reichen nicht, auch mit vielen Kapiteln; eine Quelle ohne Kennung zählt nicht")
    func fewSources() {
        let two = TrendDetector.detect(
            recent: [count("ki", "a", 10), count("ki", "b", 10), count("ki", "", 4)],
            baseline: [], historyStart: longHistory, now: now)
        #expect(two.isEmpty)

        let three = TrendDetector.detect(
            recent: [count("ki", "a", 10), count("ki", "b", 10), count("ki", "c", 1)],
            baseline: [], historyStart: longHistory, now: now)
        #expect(three.map(\.normalizedKey) == ["ki"])
    }

    @Test("Vier Kapitel reichen nicht, auch aus vier Quellen und ohne Vorkommen davor")
    func fewChapters() {
        let four = TrendDetector.detect(
            recent: [count("ki", "a", 1), count("ki", "b", 1), count("ki", "c", 1), count("ki", "d", 1)],
            baseline: [count("anderes", "a", 3)], historyStart: longHistory, now: now)
        #expect(four.isEmpty)

        let five = TrendDetector.detect(
            recent: [count("ki", "a", 2), count("ki", "b", 1), count("ki", "c", 1), count("ki", "d", 1)],
            baseline: [count("anderes", "a", 3)], historyStart: longHistory, now: now)
        #expect(five.map(\.normalizedKey) == ["ki"])
    }

    @Test("Ohne Vorgeschichte ist nichts angesagt, ab einer Woche schon")
    func noHistory() {
        #expect(TrendDetector.detect(recent: sixFromThree, baseline: [], historyStart: nil, now: now).isEmpty)
        // Die Bibliothek beginnt im Fenster: jedes Tag wäre neu.
        #expect(TrendDetector.detect(
            recent: sixFromThree, baseline: [], historyStart: now.addingTimeInterval(-2 * day), now: now).isEmpty)
        // Drei Tage vor dem Fenster sind zu wenig.
        #expect(TrendDetector.detect(
            recent: sixFromThree, baseline: [], historyStart: recentStart.addingTimeInterval(-3 * day),
            now: now).isEmpty)
        // Genau eine Woche reicht.
        let oneWeek = TrendDetector.detect(
            recent: sixFromThree, baseline: [count("ios27", "a", 1)],
            historyStart: recentStart.addingTimeInterval(-7 * day), now: now)
        #expect(oneWeek.map(\.normalizedKey) == ["ios27"])
        #expect(oneWeek.first?.weeklyAverage == 1)
    }

    @Test("Kurze Vorgeschichte: Schnitt über die Wochen, die die Bibliothek abdeckt")
    func shortHistory() {
        let baseline = [count("ios27", "a", 5)]
        // Zwei Wochen Vorgeschichte: Schnitt 2,5, das Dreifache 7,5, nicht angesagt.
        let twoWeeks = TrendDetector.detect(
            recent: sixFromThree, baseline: baseline,
            historyStart: recentStart.addingTimeInterval(-14 * day), now: now)
        #expect(twoWeeks.isEmpty)
        // Vier volle Wochen: Schnitt 1,25, das Dreifache 3,75, angesagt.
        let fourWeeks = TrendDetector.detect(
            recent: sixFromThree, baseline: baseline, historyStart: longHistory, now: now)
        #expect(fourWeeks.map(\.normalizedKey) == ["ios27"])
        #expect(fourWeeks.first?.weeklyAverage == 1.25)
    }

    @Test("Ein neues Thema ohne Vorkommen davor ist angesagt, wenn die Bibliothek Vorgeschichte hat")
    func newTopic() {
        let trends = TrendDetector.detect(
            recent: sixFromThree, baseline: [count("datenschutz", "a", 12)], historyStart: longHistory, now: now)
        #expect(trends.map(\.normalizedKey) == ["ios27"])
        #expect(trends.first?.baselineChapters == 0)
        #expect(trends.first?.ratio == nil)
    }

    @Test("Ein Tag, das jede Woche gleich oft vorkommt, ist nicht angesagt")
    func steadyTopic() {
        let trends = TrendDetector.detect(
            recent: [count("datenschutz", "a", 3), count("datenschutz", "b", 2), count("datenschutz", "c", 1)],
            baseline: [count("datenschutz", "a", 12), count("datenschutz", "b", 8), count("datenschutz", "c", 4)],
            historyStart: longHistory, now: now)
        #expect(trends.isEmpty)
    }

    @Test("Die Schwellen lassen sich einstellen")
    func customThresholds() {
        let recent = [count("ki", "a", 2), count("ki", "b", 1)]
        let baseline = [count("ki", "a", 4)]
        #expect(TrendDetector.detect(recent: recent, baseline: baseline, historyStart: longHistory, now: now).isEmpty)
        let relaxed = TrendThresholds(minimumRatio: 2, minimumSources: 2, minimumChapters: 3)
        let trends = TrendDetector.detect(
            recent: recent, baseline: baseline, historyStart: longHistory, now: now, thresholds: relaxed)
        #expect(trends.map(\.normalizedKey) == ["ki"])
        #expect(trends.first?.weeklyAverage == 1)

        // Mit weniger Vorgeschichte erlaubt: drei Tage genügen.
        let quick = TrendThresholds(minimumHistoryDays: 3)
        #expect(TrendDetector.detect(
            recent: sixFromThree, baseline: [], historyStart: recentStart.addingTimeInterval(-3 * day),
            now: now, thresholds: quick).map(\.normalizedKey) == ["ios27"])
    }

    @Test("Reihenfolge: mehr Kapitel zuerst, dann mehr Quellen, dann der Schlüssel")
    func ordering() {
        let recent = [
            count("b", "a", 2), count("b", "b", 2), count("b", "c", 2),
            count("a", "a", 2), count("a", "b", 2), count("a", "c", 2),
            count("c", "a", 3), count("c", "b", 2), count("c", "c", 1), count("c", "d", 1),
            count("d", "a", 5), count("d", "b", 1), count("d", "c", 1),
        ]
        let trends = TrendDetector.detect(recent: recent, baseline: [], historyStart: longHistory, now: now)
        #expect(trends.map(\.normalizedKey) == ["c", "d", "a", "b"])
    }

    @Test("Gefolgte und neutrale Tags zählen, Vorschläge und Schlüssel ohne Tag nicht")
    func mapping() {
        let trends = [
            TagTrend(normalizedKey: "ios27", recentChapters: 9, sourceCount: 4, baselineChapters: 0, weeklyAverage: 0),
            TagTrend(normalizedKey: "datenschutz", recentChapters: 7, sourceCount: 3, baselineChapters: 2,
                     weeklyAverage: 0.5),
            TagTrend(normalizedKey: "vorschlag", recentChapters: 6, sourceCount: 3, baselineChapters: 0,
                     weeklyAverage: 0),
            TagTrend(normalizedKey: "weg", recentChapters: 5, sourceCount: 3, baselineChapters: 0, weeklyAverage: 0),
        ]
        let neutral = Tag(id: InterestID(rawValue: "ios"), label: "iOS 27", normalizedKey: "ios27",
                          stance: .neutral, origin: .detected)
        let followed = Tag(id: InterestID(rawValue: "ds"), label: "Datenschutz", normalizedKey: "datenschutz",
                           stance: .follow, origin: .confirmedByUser)
        let suggested = Tag(id: InterestID(rawValue: "v"), label: "Vorschlag", normalizedKey: "vorschlag",
                            stance: .follow, origin: .suggestedBySystem)
        let mapped = TrendDetector.trendingTags(trends, tags: [followed, suggested, neutral])
        #expect(mapped.map(\.tag.label) == ["iOS 27", "Datenschutz"])
        #expect(mapped.map(\.trend.recentChapters) == [9, 7])

        // Zwei Tags mit einem Schlüssel, kurz nach einem Abgleich: das gefolgte gilt.
        let copy = Tag(id: InterestID(rawValue: "ds2"), label: "datenschutz", normalizedKey: "datenschutz",
                       stance: .neutral, origin: .detected)
        #expect(TrendDetector.trendingTags(Array(trends[1...1]), tags: [copy, followed]).map(\.tag.id)
                == [followed.id])
    }
}

@Suite("Angesagt: aus dem Store")
struct TrendStoreTests {

    private func chapterTag(
        _ key: String, interest: String, source: String, episode: String, start: Int = 0,
        publishedAt: Date?, createdAt: Date = now
    ) -> ChapterTag {
        ChapterTag(
            episodeID: EpisodeID(stable: episode), mediaVersionID: MediaVersionID(stable: "fassung " + episode),
            chapterStartMs: start, chapterEndMs: start + 300_000,
            interestID: InterestID(rawValue: interest), normalizedKey: key, confidence: 0.8, matchedKnown: true,
            sourceID: SourceID(rawValue: source), publishedAt: publishedAt, createdAt: createdAt,
            transcriptRevision: .initial)
    }

    private func store() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        for (identifier, label, key) in [("ios", "iOS 27", "ios27"), ("ds", "Datenschutz", "datenschutz")] {
            try await store.insertInterestRowForTesting(
                identifier: identifier, label: label, createdAt: Date(timeIntervalSince1970: 1_000),
                normalizedKey: key, stance: identifier == "ds" ? .follow : .neutral,
                origin: identifier == "ds" ? .confirmedByUser : .detected)
        }
        return store
    }

    /// Eine Folge je Aufruf: Das Speichern ersetzt die Kapitel-Tags einer Folge.
    private func save(_ tags: [ChapterTag], in store: LibraryStore) async throws {
        guard let episode = tags.first?.episodeID else { return }
        #expect(try await store.save(chapterTags: tags, forEpisode: episode, transcriptRevision: .initial))
    }

    @Test("Ohne Kapitel-Tags gibt es kein frühestes Datum, ohne Erscheinungsdatum zählt das Entstehen")
    func earliestDate() async throws {
        let store = try await store()
        #expect(try await store.earliestChapterTagDate() == nil)
        try await save([chapterTag("ios27", interest: "ios", source: "a", episode: "e1",
                                   publishedAt: now.addingTimeInterval(-10 * day))], in: store)
        #expect(try await store.earliestChapterTagDate() == now.addingTimeInterval(-10 * day))
        try await save([chapterTag("ios27", interest: "ios", source: "a", episode: "e2", publishedAt: nil,
                                   createdAt: now.addingTimeInterval(-40 * day))], in: store)
        #expect(try await store.earliestChapterTagDate() == now.addingTimeInterval(-40 * day))
    }

    @Test("Zählung im Store: iOS 27 ist angesagt, das stete Datenschutz nicht")
    func trendFromStore() async throws {
        let store = try await store()
        // iOS 27: je zwei Kapitel aus drei Quellen in dieser Woche, davor eines.
        for (index, source) in ["a", "b", "c"].enumerated() {
            try await save([
                chapterTag("ios27", interest: "ios", source: source, episode: "neu \(source)", start: 0,
                           publishedAt: now.addingTimeInterval(-Double(index + 1) * day)),
                chapterTag("ios27", interest: "ios", source: source, episode: "neu \(source)", start: 300_000,
                           publishedAt: now.addingTimeInterval(-Double(index + 1) * day)),
            ], in: store)
        }
        try await save([chapterTag("ios27", interest: "ios", source: "a", episode: "alt ios",
                                   publishedAt: now.addingTimeInterval(-20 * day))], in: store)
        // Datenschutz: zwei Kapitel je Woche, seit fünf Wochen, abwechselnd
        // aus drei Quellen. In dieser Woche so viele wie sonst.
        for week in 0..<5 {
            for index in 0..<2 {
                let source = index == 0 ? "a" : (week.isMultiple(of: 2) ? "b" : "c")
                try await save([chapterTag(
                    "datenschutz", interest: "ds", source: source, episode: "ds \(week) \(index)",
                    publishedAt: now.addingTimeInterval(-Double(week * 7 + 1 + index) * day))], in: store)
            }
        }
        // Die Bibliothek reicht weiter zurück.
        try await save([chapterTag("datenschutz", interest: "ds", source: "a", episode: "sehr alt",
                                   publishedAt: now.addingTimeInterval(-120 * day))], in: store)
        // Das Bereinigen beim Laden lässt Kapitel-Tags ohne gespeicherte Folge
        // stehen; `-demo-trends` baut darauf.
        _ = try await store.removeDuplicatesWithReport()

        let windows = TrendDetector.windows(now: now)
        let recent = try await store.chapterTagCounts(
            publishedFrom: windows.recent.lowerBound, to: windows.recent.upperBound)
        let baseline = try await store.chapterTagCounts(
            publishedFrom: windows.baseline.lowerBound, to: windows.baseline.upperBound)
        let earliest = try await store.earliestChapterTagDate()
        #expect(earliest == now.addingTimeInterval(-120 * day))

        let trends = TrendDetector.detect(recent: recent, baseline: baseline, historyStart: earliest, now: now)
        #expect(trends.map(\.normalizedKey) == ["ios27"])
        #expect(trends.first?.recentChapters == 6)
        #expect(trends.first?.baselineChapters == 1)

        let tags = try await store.tags()
        let trending = TrendDetector.trendingTags(trends, tags: tags)
        #expect(trending.map(\.tag.label) == ["iOS 27"])
        #expect(trending.first?.tag.isFollowed == false)
    }
}

@Suite("Neu seit dem letzten Besuch")
struct TagNewsTests {

    private let visit = now.addingTimeInterval(-3 * day)
    private let tagID = InterestID(rawValue: "ds")
    private let otherTag = InterestID(rawValue: "ki")
    private let media = MediaVersionID(stable: "fassung 1")
    private let otherMedia = MediaVersionID(stable: "fassung 2")

    private func chapter(
        _ interest: InterestID, media: MediaVersionID, start: Int, end: Int,
        publishedAt: Date?, createdAt: Date = now.addingTimeInterval(-30 * day)
    ) -> ChapterTag {
        ChapterTag(
            episodeID: EpisodeID(stable: media.rawValue), mediaVersionID: media,
            chapterStartMs: start, chapterEndMs: end, interestID: interest, normalizedKey: interest.rawValue,
            confidence: 0.8, matchedKnown: true, sourceID: SourceID(rawValue: "a"),
            publishedAt: publishedAt, createdAt: createdAt, transcriptRevision: .initial)
    }

    private func fact(_ id: String, media: MediaVersionID, seconds: Int64) -> EpisodeFact {
        EpisodeFact(
            id: id, episodeID: EpisodeID(stable: media.rawValue), sourceID: SourceID(rawValue: "a"),
            evidenceID: EvidenceID(rawValue: "beleg \(id)"), mediaVersionID: media, statement: "Aussage \(id)",
            range: MediaTimeRange(start: MediaTime(milliseconds: seconds * 1_000),
                                  end: MediaTime(milliseconds: seconds * 1_000 + 8_000)),
            modelTier: "Test")
    }

    private func heard(_ media: MediaVersionID, from: Int64, to: Int64) -> ListeningLedger {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(
            mediaVersionID: media,
            range: MediaTimeRange(start: MediaTime(milliseconds: from * 1_000), end: MediaTime(milliseconds: to * 1_000)),
            kind: .played, via: .originalEpisode, deviceID: "test"))
        return ledger
    }

    @Test("Zählt ungehörte Aussagen in Kapiteln des Tags aus Folgen nach dem letzten Besuch")
    func countsFreshUnheardFacts() {
        let fresh = visit.addingTimeInterval(day)
        let chapters = [
            chapter(tagID, media: media, start: 0, end: 300_000, publishedAt: fresh),
            // Nach dem Abgleich doppelt: zählt einmal.
            chapter(tagID, media: media, start: 0, end: 300_000, publishedAt: fresh),
            // Ohne bekanntes Ende gilt das Kapitel bis zum Ende der Folge.
            chapter(tagID, media: media, start: 600_000, end: 0, publishedAt: fresh),
            // Vor dem letzten Besuch erschienen.
            chapter(tagID, media: otherMedia, start: 0, end: 300_000, publishedAt: visit.addingTimeInterval(-day)),
        ]
        let facts = [
            fact("im Kapitel", media: media, seconds: 10),
            fact("gehört", media: media, seconds: 100),
            fact("zwischen den Kapiteln", media: media, seconds: 400),
            fact("im offenen Kapitel", media: media, seconds: 900),
            fact("alte Folge", media: otherMedia, seconds: 10),
        ]
        let ledger = heard(media, from: 90, to: 130)
        #expect(TagNews.count(forTag: tagID, chapterTags: chapters, facts: facts, ledger: ledger, since: visit) == 2)
        // Ohne Gehörtes zählt auch die dritte.
        #expect(TagNews.count(forTag: tagID, chapterTags: chapters, facts: facts, ledger: ListeningLedger(),
                              since: visit) == 3)
        // Seit einem früheren Besuch zählt auch die ältere Folge.
        #expect(TagNews.count(forTag: tagID, chapterTags: chapters, facts: facts, ledger: ledger,
                              since: visit.addingTimeInterval(-10 * day)) == 3)
    }

    @Test("Ohne Erscheinungsdatum zählt, wann das Kapitel-Tag entstand")
    func missingPublishDate() {
        let facts = [fact("f", media: media, seconds: 10)]
        let after = [chapter(tagID, media: media, start: 0, end: 300_000, publishedAt: nil,
                             createdAt: visit.addingTimeInterval(day))]
        let before = [chapter(tagID, media: media, start: 0, end: 300_000, publishedAt: nil,
                              createdAt: visit.addingTimeInterval(-day))]
        #expect(TagNews.count(forTag: tagID, chapterTags: after, facts: facts, ledger: ListeningLedger(),
                              since: visit) == 1)
        #expect(TagNews.count(forTag: tagID, chapterTags: before, facts: facts, ledger: ListeningLedger(),
                              since: visit) == 0)
    }

    @Test("Je Tag mit eigenem Besuch; Tags ohne Besuch zählen nicht")
    func perTagVisits() {
        let fresh = visit.addingTimeInterval(day)
        let chapters = [
            chapter(tagID, media: media, start: 0, end: 300_000, publishedAt: fresh),
            chapter(otherTag, media: media, start: 0, end: 300_000, publishedAt: fresh),
            chapter(InterestID(rawValue: "ohne besuch"), media: media, start: 0, end: 300_000, publishedAt: fresh),
        ]
        let facts = [fact("a", media: media, seconds: 10), fact("b", media: media, seconds: 20)]
        let counts = TagNews.counts(
            chapterTags: chapters, facts: facts, ledger: ListeningLedger(),
            since: [tagID: visit, otherTag: fresh.addingTimeInterval(day)])
        #expect(counts == [tagID: 2])
        #expect(TagNews.counts(chapterTags: chapters, facts: facts, ledger: ListeningLedger(), since: [:]).isEmpty)
    }
}

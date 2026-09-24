//
//  ChapterEditionTests.swift
//  PodcastAIKitTests
//
//  Themen-Updates aus Kapiteln (0.11): Auswahl mit „eines“ und „alle“,
//  Teile, Budget, Reihenfolge, Schnitt mit Vorlauf, Zahlen und ältere
//  gespeicherte Ausgaben.
//

import Testing
import Foundation
@testable import PodcastAIKit

@Suite("Themen-Updates aus Kapiteln")
struct ChapterEditionTests {

    // MARK: Bausteine

    private let privacy = InterestID(rawValue: "tag-datenschutz")
    private let usa = InterestID(rawValue: "tag-usa")
    private let cars = InterestID(rawValue: "tag-auto")

    private func ms(_ minutes: Double) -> Int64 { Int64(minutes * 60_000) }

    private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    private func evidence(_ name: String, media: String, _ start: Int64, _ end: Int64,
                          text: String = "Allgemeines Gespräch") -> Evidence {
        Evidence(
            id: EvidenceID(rawValue: name), mediaVersionID: MediaVersionID(rawValue: media),
            episodeID: EpisodeID(rawValue: "ep-\(media)"), sourceID: SourceID(rawValue: "s-\(media)"),
            transcriptID: TranscriptID(rawValue: "t"), transcriptRevision: .initial,
            range: range(start, end), quotedText: text)
    }

    /// Ein Kapitel mit Belegen zu je einer Minute.
    private func chapter(
        media: String, _ start: Int64, _ end: Int64, tags: Set<InterestID>,
        daysAgo: Double? = 1, hits: [Int: Set<InterestID>] = [:], statements: [Int64] = [],
        source: String? = nil
    ) -> EditionChapter {
        var passages: [Evidence] = []
        var cursor = start
        var index = 0
        var hitMap: [EvidenceID: Set<InterestID>] = [:]
        while cursor < end {
            let next = min(end, cursor + 60_000)
            let item = evidence("\(media)-\(start)-\(index)", media: media, cursor, next)
            passages.append(item)
            if let tags = hits[index] { hitMap[item.id] = tags }
            cursor = next
            index += 1
        }
        return EditionChapter(
            episodeID: EpisodeID(rawValue: "ep-\(media)"),
            mediaVersionID: MediaVersionID(rawValue: media),
            sourceID: SourceID(rawValue: source ?? "s-\(media)"),
            sourceTitle: "Quelle \(media)", episodeTitle: "Folge \(media)",
            originalPublishedAt: daysAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 86_400) },
            transcriptRevision: .initial, range: range(start, end), title: "Kapitel \(start / 60_000)",
            tagIDs: tags, passages: passages, passageHits: hitMap,
            statements: statements.map { range($0, $0 + 30_000) })
    }

    private func feed(
        _ tags: [InterestID], mode: TagMatchMode = .any, minutes: Int = 20
    ) -> SmartPodcastFeed {
        SmartPodcastFeed(
            id: SmartFeedID(rawValue: "feed"), title: "Mein Update", topicIDs: tags, matchMode: mode,
            editionMode: .budgeted(MediaDuration(minutes: minutes)), publicationPolicy: .manual)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(
        _ feed: SmartPodcastFeed, _ chapters: [EditionChapter], ledger: ListeningLedger = ListeningLedger(),
        previous: [PersonalEpisode] = [], limits: EditionLimits = EditionLimits()
    ) -> EditionRunOutcome {
        PersonalEpisodePublisher().makeEditions(
            feed: feed, chapters: chapters, ledger: ledger, previousEditions: previous,
            tagLabels: [privacy: "Datenschutz", usa: "USA"], requestedByUser: true,
            limits: limits, now: now)
    }

    private func parts(_ outcome: EditionRunOutcome) -> [PersonalEpisode] {
        if case .published(let run) = outcome { return run.parts }
        return []
    }

    private func chapterKeys(_ editions: [PersonalEpisode]) -> [String] {
        editions.flatMap(\.segments).compactMap { segment in
            segment.chapterRange.map { "\(segment.mediaVersionID.rawValue)|\($0.start.milliseconds)" }
        }
    }

    // MARK: Auswahl

    @Test("„Eines“ nimmt jedes Kapitel mit einem der Tags, „alle“ nur Kapitel mit beiden")
    func anyVersusAll() {
        let chapters = [
            chapter(media: "a", 0, ms(5), tags: [privacy]),
            chapter(media: "b", 0, ms(5), tags: [usa]),
            chapter(media: "c", 0, ms(5), tags: [privacy, usa, cars]),
        ]
        let any = parts(run(feed([privacy, usa]), chapters))
        #expect(Set(any.flatMap(\.segments).map(\.mediaVersionID.rawValue)) == ["a", "b", "c"])

        let all = parts(run(feed([privacy, usa], mode: .all), chapters))
        #expect(all.flatMap(\.segments).map(\.mediaVersionID.rawValue) == ["c"])
        // Die Tags des Kapitels in der Reihenfolge des Updates, nicht das dritte.
        #expect(all.first?.segments.first?.topicIDs == [privacy, usa])
        #expect(all.first?.overviewEntries.first?.tagIDs == [privacy, usa])
    }

    @Test("Ohne eigene Tags gelten die gefolgten")
    func followedTagsWhenFeedHasNone() {
        let chapters = [chapter(media: "a", 0, ms(5), tags: [privacy]), chapter(media: "b", 0, ms(5), tags: [cars])]
        let outcome = PersonalEpisodePublisher().makeEditions(
            feed: feed([]), chapters: chapters, ledger: ListeningLedger(),
            followedTagIDs: [privacy], requestedByUser: true, now: now)
        #expect(parts(outcome).flatMap(\.segments).map(\.mediaVersionID.rawValue) == ["a"])
    }

    @Test("Ein Update mit ausgewählten Quellen nimmt nur deren Kapitel")
    func restrictedSources() {
        var scoped = feed([privacy])
        scoped.restrictedToSourceIDs = [SourceID(rawValue: "s-b")]
        let chapters = [chapter(media: "a", 0, ms(5), tags: [privacy]), chapter(media: "b", 0, ms(5), tags: [privacy])]
        #expect(parts(run(scoped, chapters)).flatMap(\.segments).map(\.sourceID.rawValue) == ["s-b"])
    }

    @Test("Gehörte Kapitel fallen heraus, halb gehörte bringen nur ihren Rest")
    func ledgerRemovesHeard() throws {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(mediaVersionID: MediaVersionID(rawValue: "a"), range: range(0, ms(5)),
                                 kind: .played, via: .originalEpisode, deviceID: "t"))
        ledger.apply(LedgerEvent(mediaVersionID: MediaVersionID(rawValue: "b"), range: range(0, ms(2)),
                                 kind: .played, via: .originalEpisode, deviceID: "t"))
        let edition = try #require(parts(run(feed([privacy]), [
            chapter(media: "a", 0, ms(5), tags: [privacy]),
            chapter(media: "b", 0, ms(5), tags: [privacy]),
        ], ledger: ledger)).first)
        #expect(edition.segments.count == 1)
        #expect(edition.segments[0].coreRange == range(ms(2), ms(5)))
        // Der Rest beginnt mitten im Kapitel und bekommt sechs Sekunden Vorlauf.
        #expect(edition.segments[0].playbackRange == range(ms(2) - 6_000, ms(5)))
    }

    @Test("Die Grenze je Tag greift nach dem Hörzustand")
    func capAfterLedger() {
        var ledger = ListeningLedger()
        // Die zwei neuesten Kapitel sind gehört. Früher hätten sie die
        // Grenze belegt, und das dritte wäre nie gekommen.
        for media in ["n1", "n2"] {
            ledger.apply(LedgerEvent(mediaVersionID: MediaVersionID(rawValue: media), range: range(0, ms(3)),
                                     kind: .played, via: .originalEpisode, deviceID: "t"))
        }
        let chapters = [
            chapter(media: "n1", 0, ms(3), tags: [privacy], daysAgo: 1),
            chapter(media: "n2", 0, ms(3), tags: [privacy], daysAgo: 2),
            chapter(media: "o1", 0, ms(3), tags: [privacy], daysAgo: 3),
            chapter(media: "o2", 0, ms(3), tags: [privacy], daysAgo: 4),
        ]
        guard case .published(let result) = run(
            feed([privacy]), chapters, ledger: ledger, limits: EditionLimits(maximumChaptersPerTag: 1)
        ) else { Issue.record("keine Ausgabe"); return }
        #expect(result.parts.flatMap(\.segments).map(\.mediaVersionID.rawValue) == ["o1"])
        #expect(result.cappedChapterCount == 1)
    }

    // MARK: Teile

    @Test("Jeder Teil hält sein Budget, der Rest wird Teil 2 mit eigenem Titel")
    func partsKeepBudget() {
        // Sechs Kapitel zu je acht Minuten, Teile zu 20 Minuten: je zwei passen.
        let chapters = (0..<6).map { chapter(media: "m\($0)", 0, ms(8), tags: [privacy], daysAgo: Double($0 + 1)) }
        let editions = parts(run(feed([privacy]), chapters))
        #expect(editions.count == 3)
        #expect(editions.map(\.part) == [1, 2, 3])
        for edition in editions {
            #expect(edition.totalMediaDuration <= MediaDuration(minutes: 20))
            #expect(edition.overviewEntries.count == 2)
        }
        let partWord = TestLanguage.pick(de: "Teil", en: "Part")
        #expect(!editions[0].title.contains(partWord))
        #expect(editions[1].title.hasSuffix(", \(partWord) 2"))
        #expect(editions[2].title.hasPrefix("Mein Update"))
        #expect(Set(editions.map(\.id)).count == 3)
        #expect(Set(editions.map(\.batchKey)).count == 3)
        // Teil 1 steht in einer Liste nach Datum oben.
        #expect(editions[0].publishedAt > editions[1].publishedAt)
        // Kein Kapitel zweimal über die Teile.
        let keys = chapterKeys(editions)
        #expect(keys.count == 6 && Set(keys).count == 6)
    }

    @Test("Höchstens fünf Teile, der Rest bleibt liegen und steht in der Abdeckung")
    func partCap() {
        let chapters = (0..<8).map { chapter(media: "m\($0)", 0, ms(15), tags: [privacy], daysAgo: Double($0 + 1)) }
        guard case .published(let result) = run(feed([privacy]), chapters) else {
            Issue.record("keine Ausgabe"); return
        }
        #expect(result.parts.count == 5)
        #expect(result.droppedChapterCount == 3)
        #expect(result.droppedDuration == MediaDuration(minutes: 45))
        #expect(result.parts.allSatisfy { $0.coverage.remaining == MediaDuration(minutes: 45) })
        // Liegen bleiben die ältesten.
        #expect(result.parts.flatMap(\.segments).map(\.mediaVersionID.rawValue) == ["m0", "m1", "m2", "m3", "m4"])
    }

    @Test("Keine Ausgabe wiederholt ein Kapitel, und der nächste Lauf bringt nur Neues")
    func noChapterTwiceAcrossEditions() throws {
        let first = [chapter(media: "a", 0, ms(5), tags: [privacy]), chapter(media: "a", ms(5), ms(10), tags: [privacy])]
        let editions = parts(run(feed([privacy]), first))
        #expect(editions.count == 1)

        // Derselbe Stand noch einmal: schon veröffentlicht.
        guard case .alreadyPublished(let id) = run(feed([privacy]), first, previous: editions) else {
            Issue.record("zweite Ausgabe mit denselben Kapiteln"); return
        }
        #expect(id == editions[0].id)

        // Ein neues Kapitel kommt dazu: nur es erscheint.
        let more = first + [chapter(media: "b", 0, ms(4), tags: [privacy], daysAgo: 0.5)]
        let next = try #require(parts(run(feed([privacy]), more, previous: editions)).first)
        #expect(chapterKeys([next]) == ["b|0"])
        #expect(next.id != editions[0].id)
    }

    @Test("Ein Abschnitt aus einer Ausgabe vor 0.11 wird wie Gehörtes abgezogen")
    func legacySegmentsAreSubtracted() throws {
        let legacy = try #require(parts(run(feed([privacy]), [chapter(media: "a", 0, ms(5), tags: [privacy])])).first)
        let stripped = try decodeWithout(["chapterRange", "chapterTitle", "part", "overviewEntries"], legacy)
        #expect(stripped.segments[0].chapterRange == nil)

        // Früher gespielt: Minute 0 bis 5. Das Kapitel reicht jetzt bis 8.
        let next = try #require(parts(run(
            feed([privacy]), [chapter(media: "a", 0, ms(8), tags: [privacy])], previous: [stripped])).first)
        #expect(next.segments.map(\.coreRange) == [range(ms(5), ms(8))])
    }

    // MARK: Reihenfolge und Schnitt

    @Test("Neueste Quelle zuerst, Folge für Folge, Kapitel in der Zeitfolge")
    func newestSourceFirst() throws {
        let edition = try #require(parts(run(feed([privacy]), [
            chapter(media: "alt", ms(10), ms(12), tags: [privacy], daysAgo: 9),
            chapter(media: "neu", ms(20), ms(22), tags: [privacy], daysAgo: 1),
            chapter(media: "alt", 0, ms(2), tags: [privacy], daysAgo: 9),
            chapter(media: "neu", ms(5), ms(7), tags: [privacy], daysAgo: 1),
        ])).first)
        #expect(edition.segments.map { "\($0.mediaVersionID.rawValue)@\($0.coreRange.start.milliseconds / 60_000)" }
                == ["neu@5", "neu@20", "alt@0", "alt@10"])
        #expect(edition.segments[0].virtualRange.start == .zero)
        #expect(zip(edition.segments, edition.segments.dropFirst()).allSatisfy {
            $0.virtualRange.end < $1.virtualRange.start
        })
    }

    @Test("Ein Kapitel, das in den Teil passt, kommt ganz und ohne Vorlauf")
    func wholeChapterWithoutLeadIn() throws {
        let edition = try #require(parts(run(feed([privacy]), [
            chapter(media: "a", ms(4), ms(16), tags: [privacy]),
        ])).first)
        #expect(edition.segments.count == 1)
        #expect(edition.segments[0].coreRange == range(ms(4), ms(16)))
        #expect(edition.segments[0].playbackRange == edition.segments[0].coreRange)
        #expect(edition.overviewEntries[0].isWholeChapter)
    }

    @Test("Ein zu langes Kapitel bringt die Stellen mit Treffer, je mit sechs Sekunden Vorlauf")
    func longChapterCutsToHits() throws {
        // 30 Minuten Kapitel, Teile zu 20 Minuten. Treffer in Minute 3, 4 und 12.
        let long = chapter(media: "a", 0, ms(30), tags: [privacy],
                           hits: [3: [privacy], 4: [privacy], 12: [privacy], 20: [cars]])
        let edition = try #require(parts(run(feed([privacy]), [long])).first)
        #expect(!edition.overviewEntries[0].isWholeChapter)
        // Minute 3 und 4 liegen aneinander und werden eine Stelle.
        #expect(edition.segments.map(\.coreRange) == [range(ms(3), ms(5)), range(ms(12), ms(13))])
        #expect(edition.segments.map(\.playbackRange)
                == [range(ms(3) - 6_000, ms(5)), range(ms(12) - 6_000, ms(13))])
        #expect(edition.segments.allSatisfy { $0.contextReplay })
        // Beide Stellen gehören zu einem Kapitel der Übersicht.
        #expect(edition.overviewEntries.count == 1)
        #expect(edition.overviewEntries[0].segmentIDs == edition.segments.map(\.id))
    }

    @Test("Ohne wörtlichen Treffer beginnt der Schnitt vorn und hält das Budget")
    func longChapterWithoutHits() throws {
        let edition = try #require(parts(run(feed([privacy], minutes: 5), [
            chapter(media: "a", 0, ms(30), tags: [privacy]),
        ])).first)
        #expect(edition.totalMediaDuration <= MediaDuration(minutes: 5))
        #expect(edition.segments.first?.coreRange.start == .zero)
    }

    // MARK: Zahlen

    @Test("Die Übersicht zählt neue Aussagen je Kapitel und je Tag")
    func overviewCounts() throws {
        let edition = try #require(parts(run(feed([privacy, usa]), [
            chapter(media: "a", 0, ms(5), tags: [privacy, usa], statements: [60_000, 120_000, ms(9)]),
            chapter(media: "b", 0, ms(5), tags: [usa], statements: [30_000]),
        ])).first)
        #expect(edition.overviewEntries.map(\.newStatementCount) == [2, 1])
        #expect(edition.overviewEntries[0].sourceTitle == "Quelle a")
        #expect(edition.overviewEntries[0].episodeTitle == "Folge a")
        #expect(edition.overviewEntries[0].originalPublishedAt != nil)
        #expect(edition.statementsByTag == [privacy: 2, usa: 3])
        #expect(edition.newStatementCount == 3)

        let notes = ShownotesBuilder().markdown(for: edition)
        #expect(notes.contains("Quelle a · Folge a"))
        #expect(notes.contains("2"))
    }

    @Test("Der Kopf zählt je Tag, was seit dem letzten Hören dazukam und ungehört ist")
    func statisticsSinceLastListened() throws {
        let theFeed = feed([privacy, usa])
        let old = chapter(media: "alt", 0, ms(5), tags: [privacy], daysAgo: 10, statements: [0, 60_000])
        let editions = parts(run(theFeed, [old]))
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(mediaVersionID: MediaVersionID(rawValue: "alt"), range: range(0, ms(5)),
                                 kind: .played, via: .smartFeedEpisode, deviceID: "t"))

        let fresh = [
            old,
            chapter(media: "neu", 0, ms(5), tags: [privacy, usa], daysAgo: 1, statements: [0, 60_000, 120_000]),
            chapter(media: "anders", 0, ms(5), tags: [cars], daysAgo: 1, statements: [0]),
        ]
        // Die Ausgabe ist gehört, ihr Datum liegt nach der alten Folge.
        let stats = SmartFeedStatistics.compute(
            feed: theFeed, chapters: fresh, editions: editions.map { published($0, at: now.addingTimeInterval(-5 * 86_400)) },
            ledger: ledger, tagLabels: [privacy: "Datenschutz", usa: "USA"])
        #expect(stats.since != nil)
        #expect(stats.tags.map(\.count) == [3, 3])
        #expect(stats.tags.map(\.label) == ["Datenschutz", "USA"])
        #expect(stats.total == 3)

        // Noch nie gehört: alles Ungehörte zählt.
        let never = SmartFeedStatistics.compute(feed: theFeed, chapters: fresh, editions: editions,
                                                ledger: ListeningLedger())
        #expect(never.since == nil)
        #expect(never.tags.map(\.count) == [5, 3])

        #expect(SmartFeedStatistics.header([stats, never]).map(\.count) == [5, 3])
    }

    // MARK: Regel 5

    @Test("Folge löschen nimmt ihre Abschnitte, ihre Übersicht und ihre Zahlen mit")
    func deletionPrunesSegmentsAndStatistics() throws {
        let chapters = [
            chapter(media: "a", 0, ms(5), tags: [privacy], daysAgo: 1, statements: [0, 60_000]),
            chapter(media: "b", 0, ms(5), tags: [privacy], daysAgo: 2, statements: [0]),
        ]
        let edition = try #require(parts(run(feed([privacy]), chapters)).first)
        #expect(edition.newStatementCount == 3)

        let gone = EpisodeID(rawValue: "ep-a")
        let pruned = try #require(PersonalEpisodePublisher().removingSegments(from: edition) { $0.episodeID == gone })
        #expect(pruned.segments.map(\.episodeID.rawValue) == ["ep-b"])
        #expect(pruned.overviewEntries.map(\.episodeID.rawValue) == ["ep-b"])
        #expect(pruned.overviewEntries[0].virtualStart == .zero)
        #expect(pruned.newStatementCount == 1)
        #expect(pruned.part == edition.part)
        #expect(!ShownotesBuilder().markdown(for: pruned).contains("Quelle a"))

        let remaining = chapters.filter { $0.episodeID != gone }
        let stats = SmartFeedStatistics.compute(feed: feed([privacy]), chapters: remaining,
                                                editions: [pruned], ledger: ListeningLedger())
        #expect(stats.tags.map(\.count) == [1])
    }

    // MARK: Ältere Daten

    @Test("Ein Themen-Update ohne Modus liest sich als „eines“")
    func oldFeedDecodes() throws {
        let decoded = try decodeWithout(["matchMode"], feed([privacy], mode: .all))
        #expect(decoded.matchMode == .any)
        #expect(decoded.topicIDs == [privacy])
        #expect(decoded.partBudget == MediaDuration(minutes: 20))
        // Und zurück: das neue Feld wird geschrieben.
        let current = try roundTrip(feed([privacy], mode: .all))
        #expect(current.matchMode == .all)
    }

    @Test("Eine Ausgabe ohne Teil und Übersicht liest sich als Teil 1 ohne Übersicht")
    func oldEditionDecodes() throws {
        let edition = try #require(parts(run(feed([privacy]), [
            chapter(media: "a", 0, ms(5), tags: [privacy], statements: [0]),
        ])).first)
        let decoded = try decodeWithout(["part", "overviewEntries", "chapterRange", "chapterTitle"], edition)
        #expect(decoded.part == 1)
        #expect(decoded.overviewEntries.isEmpty)
        #expect(decoded.manifestHash == edition.manifestHash)
        #expect(decoded.segments[0].chapterRange == nil)
        #expect(ShownotesBuilder().markdown(for: decoded).contains("###"))

        let again = try roundTrip(edition)
        #expect(again == edition)
    }

    // MARK: Kapitel aus der Bibliothek

    @Test("Aus Kapitel-Tags werden Kapitel mit allen Tags, Belegen, Fakten und Treffern")
    func builderGroupsChapterTags() throws {
        let media = MediaVersionID(rawValue: "a")
        func tag(_ interest: InterestID, _ start: Int, _ end: Int) -> ChapterTag {
            ChapterTag(episodeID: EpisodeID(rawValue: "ep-a"), mediaVersionID: media,
                       chapterStartMs: start, chapterEndMs: end, interestID: interest,
                       normalizedKey: interest.rawValue, confidence: 0.8, matchedKnown: true,
                       sourceID: SourceID(rawValue: "s-a"), publishedAt: nil, transcriptRevision: .initial)
        }
        let evidence = [
            evidence("e1", media: "a", 0, 60_000, text: "Es geht um den Datenschutz."),
            evidence("e2", media: "a", 60_000, 120_000, text: "Neu ist das nicht."),
            evidence("e3", media: "a", 300_000, 360_000, text: "Autos"),
        ]
        let fact = EpisodeFact(id: "f1", episodeID: EpisodeID(rawValue: "ep-a"), sourceID: SourceID(rawValue: "s-a"),
                               evidenceID: EvidenceID(rawValue: "e2"), mediaVersionID: media,
                               statement: "Aussage", range: range(60_000, 120_000), modelTier: "test")
        let chapters = EditionChapterBuilder.build(
            evidence: evidence,
            chapterTags: [tag(privacy, 0, 300_000), tag(usa, 0, 300_000), tag(cars, 300_000, 0)],
            episodes: [:], facts: [fact],
            titles: [EpisodeID(rawValue: "ep-a"): (source: "Quelle", episode: "Folge", published: now)],
            tags: [privacy], terms: [privacy: ["Datenschutz"], usa: ["EU"]],
            jumps: { _ in nil })
        let first = try #require(chapters.first)
        #expect(chapters.count == 1)
        #expect(first.tagIDs == [privacy, usa])
        #expect(first.range == range(0, 300_000))
        #expect(first.passages.map(\.id.rawValue) == ["e1", "e2"])
        #expect(first.statements == [range(60_000, 120_000)])
        #expect(first.passageHits[EvidenceID(rawValue: "e1")] == [privacy])
        // „EU“ trifft nicht in „Neu“.
        #expect(first.passageHits[EvidenceID(rawValue: "e2")] == nil)
        #expect(first.sourceTitle == "Quelle")
    }

    // MARK: Hilfen

    private func published(_ edition: PersonalEpisode, at date: Date) -> PersonalEpisode {
        PersonalEpisode(
            id: edition.id, feedID: edition.feedID, policyRevision: edition.policyRevision,
            batchKey: edition.batchKey, title: edition.title, publishedAt: date,
            segments: edition.segments, shownotes: edition.shownotes, coverage: edition.coverage,
            part: edition.part, overviewEntries: edition.overviewEntries)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try decoder().decode(T.self, from: encoder().encode(value))
    }

    /// Wie eine ältere Fassung es geschrieben hätte: dieselben Daten ohne
    /// die neuen Schlüssel, auf jeder Ebene.
    private func decodeWithout<T: Codable>(_ keys: Set<String>, _ value: T) throws -> T {
        func strip(_ object: Any) -> Any {
            if let dictionary = object as? [String: Any] {
                return dictionary.filter { !keys.contains($0.key) }.mapValues(strip)
            }
            if let array = object as? [Any] { return array.map(strip) }
            return object
        }
        let json = try JSONSerialization.jsonObject(with: encoder().encode(value))
        let old = try JSONSerialization.data(withJSONObject: strip(json))
        for key in keys { #expect(!String(decoding: old, as: UTF8.self).contains("\"\(key)\"")) }
        return try decoder().decode(T.self, from: old)
    }
}

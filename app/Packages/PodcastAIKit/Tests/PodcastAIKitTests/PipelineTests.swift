//
//  PipelineTests.swift
//  PodcastAIKitTests
//
//  Die Zusagen der Verarbeitungskette — Planung, Auswahl, Ausgaben, Export.
//

import Testing
import Foundation
import CoreGraphics
@testable import PodcastAIKit
@testable import PodcastAIExport

// MARK: - Fokusplanung

@Suite("Fokusplanung")
struct FocusPlannerTests {

    struct TestContext: FocusPlanningContext {
        var evidenceByID: [EvidenceID: Evidence] = [:]
        var playable: Set<MediaVersionID> = []

        func evidence(for id: EvidenceID) -> Evidence? { evidenceByID[id] }
        func mediaVersion(for id: MediaVersionID) -> MediaVersion? {
            MediaVersion(id: id, episodeID: EpisodeID(rawValue: "ep"),
                         duration: MediaDuration(minutes: 90))
        }
        func episode(for id: EpisodeID) -> Episode? {
            Episode(id: id, sourceID: SourceID(rawValue: "s"), title: "Folge")
        }
        func source(for id: SourceID) -> Source? {
            Source(id: id, kind: .podcastRSS, title: "Quelle")
        }
        func transcript(for id: MediaVersionID) -> Transcript? { nil }
        func currentMediaVersionID(for episodeID: EpisodeID) -> MediaVersionID? { nil }
        func isPlayable(_ mediaVersionID: MediaVersionID) -> Bool {
            playable.contains(mediaVersionID)
        }
    }

    private func makeEvidence(_ name: String, _ start: Int64, _ end: Int64,
                              media: String = "m1", episode: String = "ep") -> Evidence {
        Evidence(
            id: EvidenceID(rawValue: name),
            mediaVersionID: MediaVersionID(rawValue: media),
            episodeID: EpisodeID(rawValue: episode), sourceID: SourceID(rawValue: "s"),
            transcriptID: TranscriptID(rawValue: "t"), transcriptRevision: .initial,
            range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                  end: MediaTime(milliseconds: end)),
            quotedText: "Text \(name)"
        )
    }

    private func context(_ evidence: [Evidence]) -> TestContext {
        TestContext(
            evidenceByID: Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) }),
            playable: Set(evidence.map(\.mediaVersionID))
        )
    }

    @Test("Drei Stellen bleiben in der Reihenfolge des Vorschlags")
    func keepsProposalOrder() {
        let evidence = [
            makeEvidence("a", 733_000, 902_000),
            makeEvidence("b", 2_091_000, 2_290_000),
            makeEvidence("c", 4_323_000, 4_582_000),
        ]
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "Datenschutz"),
            route: .chatFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        #expect(plan.segments.map(\.evidenceID.rawValue) == ["a", "b", "c"])
        #expect(plan.excluded.isEmpty)
    }

    @Test("Stellen einer Folge laufen in der Zeitfolge der Folge")
    func keepsEpisodeTimeOrder() {
        let evidence = [makeEvidence("spaet", 2_000_000, 2_100_000), makeEvidence("frueh", 100_000, 200_000)]
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "x"),
            route: .interestFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        #expect(plan.segments.map(\.evidenceID.rawValue) == ["frueh", "spaet"])
    }

    @Test("Folgen in der Reihenfolge des Vorschlags, ihre Stellen am Stück")
    func groupsSegmentsByEpisode() {
        let evidence = [
            makeEvidence("a2", 1_000_000, 1_100_000, media: "m1", episode: "a"),
            makeEvidence("b1", 500_000, 600_000, media: "m2", episode: "b"),
            makeEvidence("a1", 200_000, 300_000, media: "m1", episode: "a"),
        ]
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "x"),
            route: .interestFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        #expect(plan.segments.map(\.evidenceID.rawValue) == ["a1", "a2", "b1"])
    }

    @Test("Das Budget kürzt nach Vorschlag, nicht nach Zeitfolge")
    func budgetFollowsProposalBeforeTimeOrder() {
        // Beide Stellen passen nicht zusammen ins Budget. Die vorgeschlagene
        // zuerst bleibt, auch wenn sie in der Folge später kommt.
        let evidence = [makeEvidence("wichtig", 2_000_000, 2_300_000),
                        makeEvidence("frueher", 100_000, 400_000)]
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "x"),
            route: .interestFocus,
            options: FocusPlannerOptions(budget: MediaDuration(minutes: 6), skipAlreadyHeard: false,
                                         minimumSegmentDuration: MediaDuration(minutes: 2))
        )
        #expect(plan.segments.map(\.evidenceID.rawValue) == ["wichtig"])
    }

    @Test("Zwei nahe Stellen verschmelzen zu einer")
    func mergesNearby() {
        let evidence = [makeEvidence("a", 600_000, 660_000), makeEvidence("b", 670_000, 730_000)]
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "x"),
            route: .chatFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].allEvidenceIDs.count == 2)
    }

    @Test("Keine vorgeschlagene Stelle verschwindet stillschweigend")
    func accountsForEveryProposal() {
        let evidence = [makeEvidence("a", 0, 120_000)]
        let proposal = PlaylistProposal(
            evidenceIDs: [EvidenceID(rawValue: "a"), EvidenceID(rawValue: "erfunden")],
            requestSummary: "x"
        )
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: proposal, route: .chatFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        let accounted = Set(plan.segments.flatMap(\.allEvidenceIDs) + plan.excluded.map(\.evidenceID))
        #expect(accounted == Set(proposal.evidenceIDs))
        #expect(plan.excluded.contains { $0.evidenceID.rawValue == "erfunden" })
    }

    @Test("Das Zeitbudget wird nicht überschritten")
    func respectsBudget() {
        let evidence = (0..<6).map { makeEvidence("e\($0)", 0, 600_000, media: "m\($0)") }
        let plan = FocusPlanner(context: context(evidence)).plan(
            from: PlaylistProposal(evidenceIDs: evidence.map(\.id), requestSummary: "x"),
            route: .interestFocus,
            options: FocusPlannerOptions(budget: MediaDuration(minutes: 20), skipAlreadyHeard: false)
        )
        let listening = plan.listeningDuration(rate: 1.0,
                                               transition: MediaDuration(milliseconds: 600))
        #expect(listening <= MediaDuration(minutes: 20))
    }

    @Test("Ein nicht abspielbares Medium wird mit Grund ausgeschlossen")
    func excludesUnplayable() {
        let evidence = [makeEvidence("a", 0, 120_000)]
        var ctx = context(evidence)
        ctx.playable = []
        let plan = FocusPlanner(context: ctx).plan(
            from: PlaylistProposal(evidenceIDs: [EvidenceID(rawValue: "a")], requestSummary: "x"),
            route: .chatFocus, options: FocusPlannerOptions(skipAlreadyHeard: false)
        )
        #expect(plan.isEmpty)
        #expect(plan.excluded.first?.reason == TestLanguage.pick(de: "Medium derzeit nicht verfügbar", en: "Media currently unavailable"))
    }
}

// MARK: - Modellauswahl

@Suite("Belegauswahl des Modells")
struct EvidenceSelectionTests {

    private let candidates = (1...3).map {
        EvidenceCandidate(index: $0, id: EvidenceID(rawValue: "e\($0)"), excerpt: "Text \($0)")
    }

    @Test("Erfundene Verweise werden verworfen, nicht korrigiert")
    func rejectsInvented() {
        let result = EvidenceSelectionValidator()
            .validate(RawSelection(indices: [99, -1, 0]), against: candidates)
        #expect(result.isEmpty)
        #expect(result.audit.outOfRange.count == 3)
    }

    @Test("Die Höchstzahl hält, auch wenn das Modell alles zurückgibt")
    func enforcesLimit() {
        let many = (1...40).map {
            EvidenceCandidate(index: $0, id: EvidenceID(rawValue: "e\($0)"), excerpt: "x")
        }
        let result = EvidenceSelectionValidator(maximumSelections: 12)
            .validate(RawSelection(indices: Array(1...40)), against: many)
        #expect(result.evidenceIDs.count == 12)
        #expect(result.audit.truncated == 28)
    }

    @Test("Steuerzeichen aus Begründungen gelangen nicht in die Oberfläche")
    func sanitizesRationales() {
        let result = EvidenceSelectionValidator().validate(
            RawSelection(indices: [1], rationales: [1: "Zeile eins\n\r\tZeile zwei"]),
            against: candidates
        )
        #expect(result.rationales[EvidenceID(rawValue: "e1")] == "Zeile eins Zeile zwei")
    }

    @Test("Wiederholungen werden entfernt und protokolliert")
    func removesDuplicates() {
        let result = EvidenceSelectionValidator()
            .validate(RawSelection(indices: [1, 1, 2]), against: candidates)
        #expect(result.evidenceIDs.count == 2)
        #expect(result.audit.duplicates == [1])
    }
}

// MARK: - Persönliche Ausgaben

@Suite("Persönliche Ausgaben")
struct PersonalEpisodeTests {

    private func candidate(_ name: String, media: String, _ start: Int64, _ end: Int64,
                           score: Double) -> SegmentCandidate {
        SegmentCandidate(
            evidence: Evidence(
                id: EvidenceID(rawValue: name),
                mediaVersionID: MediaVersionID(rawValue: media),
                episodeID: EpisodeID(rawValue: "ep-\(media)"),
                sourceID: SourceID(rawValue: "s-\(media)"),
                transcriptID: TranscriptID(rawValue: "t"), transcriptRevision: .initial,
                range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                      end: MediaTime(milliseconds: end)),
                quotedText: "Text"
            ),
            episodeID: EpisodeID(rawValue: "ep-\(media)"),
            sourceID: SourceID(rawValue: "s-\(media)"),
            sourceTitle: media, episodeTitle: "Folge", originalPublishedAt: nil,
            transcriptRevision: .initial, topicIDs: [], reason: "Passt zu deinem Thema",
            relevanceScore: score
        )
    }

    private var feed: SmartPodcastFeed {
        SmartPodcastFeed(
            title: "Mein KI Update", topicIDs: [],
            editionMode: .budgeted(MediaDuration(minutes: 20)),
            publicationPolicy: .manual
        )
    }

    @Test("Zweimal derselbe Lauf ergibt eine Ausgabe, nicht zwei")
    func idempotentBatchKey() {
        let candidates = [candidate("a", media: "m1", 0, 300_000, score: 0.9)]
        let publisher = PersonalEpisodePublisher()

        guard case .published(let first) = publisher.makeEdition(
            feed: feed, candidates: candidates, ledger: ListeningLedger()
        ) else { Issue.record("keine Ausgabe"); return }

        let second = publisher.makeEdition(
            feed: feed, candidates: candidates, ledger: ListeningLedger(),
            existingBatchKeys: [first.batchKey]
        )
        guard case .alreadyPublished = second else {
            Issue.record("zweite Ausgabe erzeugt")
            return
        }
    }

    @Test("Eine Ausgabe startet keinen Ton — sie ist ein Zustand")
    func publicationIsState() {
        guard case .published(let episode) = PersonalEpisodePublisher().makeEdition(
            feed: feed, candidates: [candidate("a", media: "m1", 0, 300_000, score: 0.9)],
            ledger: ListeningLedger()
        ) else { Issue.record("keine Ausgabe"); return }

        #expect(episode.publicationState == .published)
        #expect(episode.consumptionState == .unplayed)
    }

    @Test("Gehörtes in der Ausgabe übersetzt sich auf die Originalfassung")
    func mapsBackToOriginal() {
        guard case .published(let episode) = PersonalEpisodePublisher().makeEdition(
            feed: feed,
            candidates: [candidate("a", media: "m1", 600_000, 900_000, score: 0.9)],
            ledger: ListeningLedger()
        ) else { Issue.record("keine Ausgabe"); return }

        let events = episode.ledgerEvents(
            forVirtualRange: MediaTimeRange(start: .zero, end: episode.totalMediaDuration.asTime),
            deviceID: "test"
        )
        #expect(events.count == 1)
        #expect(events[0].mediaVersionID == MediaVersionID(rawValue: "m1"))
        // Der Kontextvorlauf liegt vor dem Kernbereich.
        #expect(events[0].range.start.milliseconds <= 600_000)
        #expect(events[0].range.end.milliseconds == 900_000)
    }

    @Test("Bereits Gehörtes kommt nicht in die Ausgabe")
    func skipsHeard() {
        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(
            mediaVersionID: MediaVersionID(rawValue: "m1"),
            range: MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 1_200_000)),
            kind: .played, via: .originalEpisode, deviceID: "t"
        ))
        let outcome = PersonalEpisodePublisher().makeEdition(
            feed: feed,
            candidates: [candidate("a", media: "m1", 600_000, 900_000, score: 0.9)],
            ledger: ledger
        )
        guard case .noNewMaterial = outcome else {
            Issue.record("gehörte Stelle wurde erneut angeboten")
            return
        }
    }
}

// MARK: - Themen-Updates bauen, eingrenzen, aufräumen

@Suite("Themen-Updates")
struct SmartFeedEditionTests {

    private func candidate(_ name: String, media: String, _ start: Int64, _ end: Int64,
                           score: Double = 0.9) -> SegmentCandidate {
        SegmentCandidate(
            evidence: Evidence(
                id: EvidenceID(rawValue: name),
                mediaVersionID: MediaVersionID(rawValue: media),
                episodeID: EpisodeID(rawValue: "ep-\(media)"),
                sourceID: SourceID(rawValue: "s-\(media)"),
                transcriptID: TranscriptID(rawValue: "t"), transcriptRevision: .initial,
                range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                      end: MediaTime(milliseconds: end)),
                quotedText: "Text"
            ),
            episodeID: EpisodeID(rawValue: "ep-\(media)"),
            sourceID: SourceID(rawValue: "s-\(media)"),
            sourceTitle: media, episodeTitle: "Folge", originalPublishedAt: nil,
            transcriptRevision: .initial, topicIDs: [], reason: "Passt zu deinem Thema",
            relevanceScore: score
        )
    }

    /// Wie ein frisch angelegter Feed: automatische Regel mit fünf Minuten.
    private let automaticFeed = SmartPodcastFeed(title: "Mein KI Update", topicIDs: [])

    @Test("Wer ausdrücklich fragt, bekommt auch drei Minuten Material")
    func manualBuildSkipsAutomaticThreshold() {
        let candidates = [candidate("a", media: "m1", 0, 180_000)]
        let publisher = PersonalEpisodePublisher()

        let automatic = publisher.makeEdition(
            feed: automaticFeed, candidates: candidates, ledger: ListeningLedger())
        guard case .belowThreshold = automatic else {
            Issue.record("Automatik veröffentlicht unter der Schwelle")
            return
        }

        let manual = publisher.makeEdition(
            feed: automaticFeed, candidates: candidates, ledger: ListeningLedger(),
            requestedByUser: true)
        guard case .published(let episode) = manual else {
            Issue.record("ausdrückliche Anforderung scheitert an der Schwelle")
            return
        }
        #expect(episode.segments.count == 1)
    }

    @Test("Ein Feed mit ausgewählten Quellen nimmt nur diese")
    func restrictedSourcesAreHonored() {
        var feed = automaticFeed
        feed.restrictedToSourceIDs = [SourceID(rawValue: "s-m2")]
        let outcome = PersonalEpisodePublisher().makeEdition(
            feed: feed,
            candidates: [candidate("a", media: "m1", 0, 400_000),
                         candidate("b", media: "m2", 0, 400_000)],
            ledger: ListeningLedger(), requestedByUser: true)
        guard case .published(let episode) = outcome else {
            Issue.record("keine Ausgabe"); return
        }
        #expect(episode.segments.map(\.sourceID) == [SourceID(rawValue: "s-m2")])
    }

    @Test("Gelöschte Folgen verschwinden aus der Ausgabe, die Zeitachse rückt zusammen")
    func removingSegmentsRebuildsTimeline() {
        let publisher = PersonalEpisodePublisher()
        guard case .published(let episode) = publisher.makeEdition(
            feed: automaticFeed,
            candidates: [candidate("a", media: "m1", 0, 300_000, score: 0.9),
                         candidate("b", media: "m2", 0, 300_000, score: 0.8)],
            ledger: ListeningLedger(), requestedByUser: true
        ) else { Issue.record("keine Ausgabe"); return }
        #expect(episode.segments.count == 2)

        let gone = EpisodeID(rawValue: "ep-m1")
        guard let pruned = publisher.removingSegments(from: episode, where: { $0.episodeID == gone })
        else { Issue.record("Ausgabe ganz verworfen"); return }

        #expect(pruned.id == episode.id)
        #expect(pruned.batchKey == episode.batchKey)
        #expect(pruned.segments.map(\.episodeID) == [EpisodeID(rawValue: "ep-m2")])
        #expect(pruned.segments[0].virtualRange.start == .zero)
        #expect(pruned.shownotes.count == 1)
        #expect(pruned.shownotes[0].virtualStart == .zero)
        #expect(pruned.manifestHash != episode.manifestHash)
        #expect(pruned.coverage.includedCount == 1)

        let untouched = publisher.removingSegments(from: episode, where: { _ in false })
        #expect(untouched == episode)
        #expect(publisher.removingSegments(from: episode, where: { _ in true }) == nil)
    }

    // MARK: Kapitel und Abspielfolge

    private func chapters(_ starts: [Int64], duration: Int64?) -> EpisodeChapters {
        EpisodeChapters(
            chapters: starts.map {
                Chapter(start: MediaTime(milliseconds: $0), title: "Kapitel", provenance: .original)
            },
            duration: duration.map { MediaDuration(milliseconds: $0) }
        )
    }

    private func edition(
        _ candidates: [SegmentCandidate], chapters: [EpisodeID: EpisodeChapters] = [:]
    ) -> PersonalEpisode? {
        guard case .published(let episode) = PersonalEpisodePublisher().makeEdition(
            feed: automaticFeed, candidates: candidates, ledger: ListeningLedger(),
            chapters: chapters, requestedByUser: true
        ) else { return nil }
        return episode
    }

    private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    @Test("Eine Stelle in einem Kapitel bringt das ganze Kapitel, ohne Vorlauf")
    func snapsToChapter() throws {
        let episode = try #require(edition(
            [candidate("a", media: "m1", 300_000, 360_000)],
            chapters: [EpisodeID(rawValue: "ep-m1"): chapters([0, 240_000, 600_000], duration: 900_000)]
        ))
        #expect(episode.segments.count == 1)
        #expect(episode.segments[0].coreRange == range(240_000, 600_000))
        #expect(episode.segments[0].playbackRange == range(240_000, 600_000))
        #expect(!episode.segments[0].contextReplay)
    }

    @Test("Das letzte Kapitel reicht bis zum Ende der Folge")
    func lastChapterEndsWithEpisode() throws {
        let marks = [EpisodeID(rawValue: "ep-m1"): chapters([0, 240_000], duration: 500_000)]
        let episode = try #require(edition([candidate("a", media: "m1", 300_000, 360_000)], chapters: marks))
        #expect(episode.segments[0].coreRange == range(240_000, 500_000))

        // Ohne bekannte Länge hat das letzte Kapitel kein Ende. Dann bleibt es bei der Stelle.
        let open = [EpisodeID(rawValue: "ep-m1"): chapters([0, 240_000], duration: nil)]
        let fallback = try #require(edition([candidate("a", media: "m1", 300_000, 360_000)], chapters: open))
        #expect(fallback.segments[0].coreRange == range(300_000, 360_000))
    }

    @Test("Ein zu langes Kapitel wird nicht gespielt, dann bleibt es bei der Stelle")
    func longChapterKeepsPassage() throws {
        let episode = try #require(edition(
            [candidate("a", media: "m1", 300_000, 360_000)],
            chapters: [EpisodeID(rawValue: "ep-m1"): chapters([0, 1_200_000], duration: 3_600_000)]
        ))
        #expect(episode.segments[0].coreRange == range(300_000, 360_000))
        // Der übliche Vorlauf von sechs Sekunden.
        #expect(episode.segments[0].playbackRange == range(294_000, 360_000))

        let without = try #require(edition([candidate("a", media: "m1", 300_000, 360_000)]))
        #expect(without.segments[0].coreRange == range(300_000, 360_000))
    }

    @Test("Zwei Stellen im selben Kapitel ergeben einen Abschnitt mit beiden Belegen")
    func passagesInOneChapterShareASegment() throws {
        let episode = try #require(edition(
            [candidate("a", media: "m1", 300_000, 360_000, score: 0.5),
             candidate("b", media: "m1", 420_000, 480_000, score: 0.9)],
            chapters: [EpisodeID(rawValue: "ep-m1"): chapters([0, 240_000, 600_000], duration: 900_000)]
        ))
        #expect(episode.segments.count == 1)
        #expect(Set(episode.segments[0].evidenceIDs.map(\.rawValue)) == ["a", "b"])
        // Der relevantere Beleg trägt den Abschnitt.
        #expect(episode.segments[0].evidenceIDs.first?.rawValue == "b")
    }

    @Test("Stellen einer Folge laufen in der Zeitfolge der Folge")
    func segmentsOfAnEpisodeKeepTimeOrder() throws {
        let episode = try #require(edition([
            candidate("spaet", media: "m1", 700_000, 760_000, score: 0.9),
            candidate("frueh", media: "m1", 100_000, 160_000, score: 0.5),
        ]))
        #expect(episode.segments.map(\.coreRange.start.milliseconds) == [100_000, 700_000])
        #expect(episode.segments.map { $0.evidenceIDs.first?.rawValue } == ["frueh", "spaet"])
        // Die Zeitachse der Ausgabe folgt der Abspielfolge.
        #expect(episode.segments[0].virtualRange.start == .zero)
        #expect(episode.segments[1].virtualRange.start > episode.segments[0].virtualRange.end)
    }

    @Test("Folgen nach Relevanz, ihre Stellen am Stück")
    func episodesByRelevanceSegmentsConsecutive() throws {
        let episode = try #require(edition([
            candidate("a1", media: "m1", 100_000, 160_000, score: 0.6),
            candidate("a2", media: "m1", 700_000, 760_000, score: 0.5),
            candidate("b2", media: "m2", 500_000, 560_000, score: 0.9),
            candidate("b1", media: "m2", 50_000, 110_000, score: 0.4),
        ]))
        #expect(episode.segments.map { $0.evidenceIDs.first?.rawValue } == ["b1", "b2", "a1", "a2"])
        #expect(episode.segments.map(\.episodeID.rawValue) == ["ep-m2", "ep-m2", "ep-m1", "ep-m1"])
    }

    @Test("Gehört zählt nur das Neue, nicht den Kontextvorlauf")
    func heardFractionUsesCoreRange() {
        guard case .published(let episode) = PersonalEpisodePublisher().makeEdition(
            feed: automaticFeed,
            candidates: [candidate("a", media: "m1", 600_000, 900_000)],
            ledger: ListeningLedger(), requestedByUser: true
        ) else { Issue.record("keine Ausgabe"); return }
        #expect(episode.heardFraction(in: ListeningLedger()) == 0)

        var ledger = ListeningLedger()
        ledger.apply(LedgerEvent(
            mediaVersionID: MediaVersionID(rawValue: "m1"),
            range: MediaTimeRange(start: MediaTime(milliseconds: 600_000),
                                  end: MediaTime(milliseconds: 750_000)),
            kind: .played, via: .smartFeedEpisode, deviceID: "t"
        ))
        #expect(abs(episode.heardFraction(in: ledger) - 0.5) < 0.01)
    }
}

// MARK: - Cover der Themen-Updates

@Suite("Cover der Themen-Updates")
struct TopicCoverTests {

    private let feed = SmartPodcastFeed(title: "Datenschutz und JEV", topicIDs: [])

    @Test("Themen werden bereinigt, doppelte fallen weg, höchstens vier")
    func recipeCleansTopics() {
        let recipe = TopicCoverRecipe(
            feed: feed, topics: ["  Datenschutz ", "datenschutz", "", "KI", "Recht", "Europa", "Cloud"],
            languageCode: "de")
        #expect(recipe.concepts == ["Datenschutz", "KI", "Recht", "Europa"])
        #expect(recipe.attempts.first == recipe.concepts + [recipe.abstractConcept])
        // Der letzte Versuch kommt ohne Themen aus.
        #expect(recipe.attempts.last == [TopicCoverRecipe.neutralConcept])
    }

    @Test("Der Fingerabdruck hängt an den Themen, nicht an ihrer Reihenfolge")
    func digestFollowsTopics() {
        let a = TopicCoverRecipe(feed: feed, topics: ["Datenschutz", "KI"])
        let b = TopicCoverRecipe(feed: feed, topics: ["KI", "Datenschutz"])
        let c = TopicCoverRecipe(feed: feed, topics: ["Datenschutz", "Recht"])
        #expect(a.digest == b.digest)
        #expect(a.digest != c.digest)
    }

    @Test("Ohne Themen entsteht das Bild aus dem Titel")
    func recipeFallsBackToTitle() {
        let recipe = TopicCoverRecipe(feed: feed, topics: [" "])
        #expect(recipe.concepts == ["Datenschutz und JEV"])
    }

    @Test("Ein Bild je Update: neue Themen ersetzen das alte, Löschen entfernt es")
    func storeKeepsOneCoverPerFeed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TopicCoverStore(directory: directory)
        let other = SmartPodcastFeed(title: "Anderes", topicIDs: [])
        let first = TopicCoverRecipe(feed: feed, topics: ["Datenschutz"])
        let second = TopicCoverRecipe(feed: feed, topics: ["Datenschutz", "KI"])
        let image = try #require(Self.image(width: 40, height: 20))

        #expect(store.stored(for: feed.id) == nil)
        try store.write(image, for: first)
        try store.write(image, for: TopicCoverRecipe(feed: other, topics: ["Musik"]))
        #expect(store.stored(for: feed.id)?.matches(first) == true)
        #expect(store.stored(for: feed.id)?.matches(second) == false)

        let replaced = try store.write(image, for: second)
        #expect(store.stored(for: feed.id)?.digest == second.digest)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 2)

        // Quadratisch abgelegt, auch wenn das Bild es nicht war.
        let loaded = try #require(TopicCoverStore.loadImage(at: replaced.url))
        #expect(loaded.width == 20 && loaded.height == 20)

        store.remove(feed.id)
        #expect(store.stored(for: feed.id) == nil)
        #expect(store.stored(for: other.id) != nil)
    }

    private static func image(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Export

@Suite("Markdown-Export")
struct ExportTests {

    @Test("Adressen mit Zugangsdaten oder Token werden nicht verlinkt")
    func rejectsPrivateURLs() {
        #expect(SafeSourceLink(publicURL: URL(string: "https://u:p@example.com/f.xml")) == nil)
        #expect(SafeSourceLink(publicURL: URL(string: "https://example.com/f.xml?token=x")) == nil)
        #expect(SafeSourceLink(publicURL: URL(string: "https://example.com/f.xml#a")) == nil)
        #expect(SafeSourceLink(publicURL: URL(string: "file:///tmp/x.m4a")) == nil)
        #expect(SafeSourceLink(publicURL: URL(string: "https://example.com/ep/1")) != nil)
    }

    @Test("Fremder Text zerlegt die Struktur des Exports nicht")
    func escapesForeignText() {
        let escaped = MarkdownExporter.escapeInline("Folge [147](https://evil.invalid)\n# Titel")
        #expect(!escaped.contains("\n"))
        #expect(escaped.contains("\\["))
        #expect(!escaped.hasPrefix("#"))
    }

    @Test("Steuerzeichen überleben den Export nicht")
    func stripsControlCharacters() {
        let escaped = MarkdownExporter.escapeBlock("a\u{0B}b\u{0C}c")
        #expect(!escaped.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }
}

private extension MediaDuration {
    var asTime: MediaTime { MediaTime(milliseconds: milliseconds) }
}

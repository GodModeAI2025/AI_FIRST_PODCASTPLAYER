//
//  PipelineTests.swift
//  PodcastAIKitTests
//
//  Die Zusagen der Verarbeitungskette — Planung, Auswahl, Ausgaben, Export.
//

import Testing
import Foundation
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
                              media: String = "m1") -> Evidence {
        Evidence(
            id: EvidenceID(rawValue: name),
            mediaVersionID: MediaVersionID(rawValue: media),
            episodeID: EpisodeID(rawValue: "ep"), sourceID: SourceID(rawValue: "s"),
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
        #expect(plan.excluded.first?.reason == "Medium derzeit nicht verfügbar")
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

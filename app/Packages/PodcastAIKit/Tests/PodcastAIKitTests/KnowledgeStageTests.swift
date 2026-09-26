//
//  KnowledgeStageTests.swift
//  PodcastAIKitTests
//
//  Schritt 3 der Stufen-Pipeline (docs/plan-pipeline.md): die Stufe
//  „Wissen“ führt Warteschlange, Reihenfolge, Tor und gemerkte Absichten.
//  Geprüft mit einer Arbeit, die nur mitschreibt, einem Tor, das der Test
//  öffnet und schließt, und einem eigenen `DeviceState` je Test. Gewartet
//  wird auf Zeichen der Arbeit, nie eine feste Zeit.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence

// MARK: - Bausteine

private let sourceID = SourceID(stable: "wissen-quelle")
private let ready = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))

private func episodeID(_ name: String) -> EpisodeID { EpisodeID(stable: "wissen-\(name)") }

private func episode(_ name: String, daysAgo: Double) -> Episode {
    Episode(id: episodeID(name), sourceID: sourceID, title: name,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000 - daysAgo * 86_400),
            audioURL: URL(string: "https://example.com/\(name).mp3"))
}

private func makeState() -> DeviceState {
    DeviceState(directory: FileManager.default.temporaryDirectory
        .appending(path: "wissen-\(UUID().uuidString)", directoryHint: .isDirectory))
}

/// Ein Speicher mit einer Quelle und diesen Folgen. Mit `transcripts` auch
/// Transkript und Belege, damit die Stufe ihre Ereignisse mit Fassung senden kann.
private func makeStore(_ episodes: [Episode], transcripts: Bool = false) async throws -> LibraryStore {
    let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
    _ = try await store.upsert(episodes: episodes, forSource: sourceID)
    guard transcripts else { return store }
    for episode in episodes {
        guard let audio = episode.audioURL else { continue }
        let media = MediaVersionID(stable: audio.absoluteString)
        let range = MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 9_000))
        let transcriptID = TranscriptID(stable: "\(media.rawValue)|de_DE")
        let transcript = Transcript(
            id: transcriptID, mediaVersionID: media, revision: .initial, origin: .speechAnalysis,
            locale: "de_DE", segments: [TranscriptSegment(
                id: TranscriptSegment.stableID(mediaVersionID: media, range: range), range: range,
                text: "Ein Satz über \(episode.title).")],
            analyzedRanges: IntervalSet(range))
        try await store.save(transcript: transcript, media: MediaVersion(id: media, episodeID: episode.id, remoteURL: audio),
                             forEpisode: episode.id)
        try await store.store(evidence: [Evidence(
            id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
            mediaVersionID: media, episodeID: episode.id, sourceID: sourceID, transcriptID: transcriptID,
            transcriptRevision: .initial, range: range, quotedText: "Ein Satz über \(episode.title).")])
    }
    return store
}

/// Eine Arbeit, die mitschreibt, was sie tun soll. Fakten einer Folge
/// können hängen, bis die Stufe abbricht; dann kommt `.cancelled` zurück.
private final class RecordingWork: KnowledgeWorking {

    struct Plan: Sendable {
        var facts: [EpisodeID: [FactsOutcome]] = [:]
        var hangs: Set<EpisodeID> = []
    }

    private let state = Mutex<(calls: [String], plan: Plan)>(([], Plan()))
    let started: AsyncStream<String>
    private let startedContinuation: AsyncStream<String>.Continuation

    init(_ plan: Plan = Plan()) {
        state.withLock { $0.plan = plan }
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var calls: [String] { state.withLock { $0.calls } }

    func gatherFacts(for episode: Episode, force: Bool, origin: Origin,
                     since ticket: RemovalLedger.Ticket) async -> FactsOutcome {
        let (outcome, hangs) = state.withLock { state -> (FactsOutcome, Bool) in
            state.calls.append("facts:\(episode.title)\(force ? "!" : "")")
            let hangs = state.plan.hangs.remove(episode.id) != nil
            var list = state.plan.facts[episode.id] ?? []
            let next = list.isEmpty ? FactsOutcome.stored : list.removeFirst()
            state.plan.facts[episode.id] = list
            return (next, hangs)
        }
        startedContinuation.yield("facts:\(episode.title)")
        if hangs {
            try? await Task.sleep(for: .seconds(60))
            return .cancelled
        }
        return outcome
    }

    func classifyChapters(of episode: Episode, origin: Origin,
                          since ticket: RemovalLedger.Ticket) async -> ChapterTagsRun {
        state.withLock { $0.calls.append("tags:\(episode.title):\(origin)") }
        startedContinuation.yield("tags:\(episode.title)")
        return ChapterTagsRun(.stored, current: true)
    }
}

/// Die veränderlichen Angaben des Hauptakteurs, für den Test.
private final class FakeSettings: Sendable {
    private let state: Mutex<KnowledgeSettings>
    init(analyzed: Set<EpisodeID> = [], automaticFacts: Bool = true) {
        state = Mutex(KnowledgeSettings(isLoaded: true, automaticFacts: automaticFacts, analyzed: analyzed))
    }
    var value: KnowledgeSettings { state.withLock { $0 } }
}

/// Eine Uhr, die nur der Test weiterstellt.
private final class TestClock: Sendable {
    private let now = Mutex(Date(timeIntervalSince1970: 2_000_000_000))
    var date: Date { now.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
}

private struct Harness {
    let store: LibraryStore
    let gate: WorkGate
    let ledger: RemovalLedger
    let state: DeviceState
    let work: RecordingWork
    let settings: FakeSettings
    let clock: TestClock
    let host: PipelineHost?
    let stage: KnowledgeStage

    var intents: PipelineIntents { PipelineIntents(state: state) }
}

/// Das Tor steht anfangs zu (Hintergrund ohne Träger), damit Einreihen und
/// Reihenfolge sich prüfen lassen, ohne dass etwas läuft.
private func makeHarness(
    store: LibraryStore, open: Bool = false, work: RecordingWork = RecordingWork(),
    settings: FakeSettings = FakeSettings(), state: DeviceState = makeState(),
    clock: TestClock = TestClock(), host: PipelineHost? = nil, status: ModelStatus = ready
) async -> Harness {
    let gate = WorkGate(alwaysInForeground: false, inForeground: open)
    let ledger = RemovalLedger()
    let monitor = ModelAvailabilityMonitor(initial: status, probe: { _ in status })
    let stage = KnowledgeStage(
        store: store, gate: gate, ledger: ledger, intents: PipelineIntents(state: state), marks: state,
        monitor: monitor, host: host, work: work,
        environment: KnowledgeStage.Environment(settings: { settings.value }, refreshModel: { status }),
        clock: { clock.date }, pauseStep: .milliseconds(1), pauseSteps: 3)
    await stage.start()
    return Harness(store: store, gate: gate, ledger: ledger, state: state, work: work, settings: settings,
                   clock: clock, host: host, stage: stage)
}

/// Wartet auf das nächste Element, höchstens zehn Sekunden.
private func next<Element: Sendable>(_ stream: AsyncStream<Element>) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - Tests

@Suite("Stufe „Wissen“")
struct KnowledgeStageTests {

    @Test("Angefordert kommt ganz nach vorn, von selbst Eingereihtes nach Datum dahinter")
    func order() async throws {
        let a = episode("A", daysAgo: 3), b = episode("B", daysAgo: 1), c = episode("C", daysAgo: 2)
        let harness = await makeHarness(store: try await makeStore([a, b, c]))
        await harness.stage.enqueue(a)
        await harness.stage.enqueue(b)
        await harness.stage.enqueue(c)
        #expect(await harness.stage.queuedFacts == [b.id, c.id, a.id])
        await harness.stage.request(a)
        #expect(await harness.stage.queuedFacts == [a.id, b.id, c.id])
        await harness.stage.request(c)
        #expect(await harness.stage.queuedFacts == [c.id, a.id, b.id])
        // Von selbst Eingereihtes überholt nichts Angefordertes.
        let d = episode("D", daysAgo: 0)
        await harness.stage.enqueue(d)
        #expect(await harness.stage.queuedFacts == [c.id, a.id, d.id, b.id])
        #expect(harness.work.calls.isEmpty, "Das Tor ist zu, nichts darf laufen")
    }

    @Test("Nach den Fakten einer Folge kommen ihre Tags, dann die nächste Folge")
    func factsThenTags() async throws {
        let a = episode("A", daysAgo: 2), b = episode("B", daysAgo: 1)
        let harness = await makeHarness(store: try await makeStore([a, b]))
        await harness.stage.enqueue(a)
        await harness.stage.request(b)
        harness.gate.setInForeground(true)
        #expect(await next(harness.work.started) == "facts:B")
        await harness.stage.untilIdle()
        #expect(harness.work.calls == ["facts:B!", "tags:B:user", "facts:A", "tags:A:automatic"])
        #expect(await harness.stage.queuedFacts.isEmpty)
    }

    @Test("Scheitert eine Folge, kommt sie einmal hinten dran, danach ruht sie bis zum nächsten Start")
    func retryRules() async throws {
        let a = episode("A", daysAgo: 1), b = episode("B", daysAgo: 2)
        var plan = RecordingWork.Plan()
        plan.facts[a.id] = [.failed("Last"), .failed("Last")]
        let harness = await makeHarness(
            store: try await makeStore([a, b]), work: RecordingWork(plan), settings: FakeSettings(analyzed: [a.id, b.id]))
        await harness.stage.enqueue(a)
        await harness.stage.enqueue(b)
        harness.gate.setInForeground(true)
        #expect(await next(harness.work.started) == "facts:A")
        await harness.stage.untilIdle()
        // Nach dem zweiten Fehlschlag keine Tags und kein dritter Versuch.
        #expect(harness.work.calls == ["facts:A", "facts:B", "tags:B:automatic", "facts:A"])
        #expect(await harness.stage.queuedFacts.isEmpty)
        #expect(await harness.stage.snapshot.issues[a.id] == .note("Last"))
        // Vorn zurückgestellt: Der nächste Abgleich nimmt sie nicht wieder.
        harness.intents.markOwn([a.id])
        await harness.stage.reconcile()
        #expect(await !harness.stage.queuedFacts.contains(a.id))
    }

    @Test("Schließt das Tor, hält die Folge an und steht wieder vorn; geht es auf, läuft sie weiter")
    func gateStopsAndResumes() async throws {
        let a = episode("A", daysAgo: 1), b = episode("B", daysAgo: 2)
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b]), work: RecordingWork(plan))
        await harness.stage.enqueue(a)
        await harness.stage.enqueue(b)
        harness.gate.setInForeground(true)
        #expect(await next(harness.work.started) == "facts:A")
        // In den Hintergrund ohne Träger: Die Stufe bricht ab.
        harness.gate.setInForeground(false)
        await harness.stage.untilIdle()
        #expect(await harness.stage.queuedFacts == [a.id, b.id])
        #expect(await harness.stage.snapshot.issues.isEmpty, "Ein Abbruch zählt nicht als Fehlschlag")
        // Die Hintergrundaufgabe gibt Zeit: Es geht weiter, mit derselben Folge.
        let lease = harness.gate.hold(.analysisTask)
        #expect(await next(harness.work.started) == "facts:A")
        await harness.stage.untilIdle()
        lease.release()
        #expect(harness.work.calls == ["facts:A", "facts:A", "tags:A:automatic", "facts:B", "tags:B:automatic"])
    }

    @Test("Pause hält alles an, auch die Tags")
    func pauseHoldsEverything() async throws {
        let a = episode("A", daysAgo: 1)
        let harness = await makeHarness(store: try await makeStore([a]), open: true)
        harness.gate.setPaused(true)
        await harness.stage.request(a)
        await harness.stage.untilIdle()
        #expect(harness.work.calls.isEmpty)
        harness.gate.setPaused(false)
        #expect(await next(harness.work.started) == "facts:A")
        await harness.stage.untilIdle()
        #expect(harness.work.calls == ["facts:A!", "tags:A:user"])
    }

    @Test("Löschen während des Laufs bricht Fakten ab, und nichts von der Folge bleibt")
    func removalWhileRunning() async throws {
        let a = episode("A", daysAgo: 1), b = episode("B", daysAgo: 2)
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b]), work: RecordingWork(plan))
        await harness.stage.reconcile()
        await harness.stage.request(a)
        await harness.stage.enqueue(b)
        #expect(harness.intents.factsQueue()?.map(\.episodeID) == [a.id, b.id])
        harness.gate.setInForeground(true)
        #expect(await next(harness.work.started) == "facts:A")
        harness.ledger.markRemoved([a.id])
        await harness.stage.receive(.episodesRemoved([a.id], .episode))
        await harness.stage.untilIdle()
        #expect(!harness.work.calls.contains("tags:A:user"), "Nach dem Abbruch keine Tags der gelöschten Folge")
        #expect(await harness.stage.queuedFacts.isEmpty)
        #expect(harness.intents.factsQueue()?.contains { $0.episodeID == a.id } != true)
        #expect(harness.intents.firstSeen()?[a.id] == nil)
    }

    @Test("Löschen einer wartenden Folge nimmt sie aus Warteschlange und Absichten")
    func removalWhileQueued() async throws {
        let a = episode("A", daysAgo: 1), b = episode("B", daysAgo: 2)
        let harness = await makeHarness(store: try await makeStore([a, b]))
        await harness.stage.reconcile()
        await harness.stage.enqueue(a)
        await harness.stage.enqueue(b)
        harness.intents.recordFailure("alt", for: a.id)
        harness.ledger.markRemoved([a.id])
        await harness.stage.receive(.episodesRemoved([a.id], .episode))
        #expect(await harness.stage.queuedFacts == [b.id])
        #expect(harness.intents.factsQueue()?.map(\.episodeID) == [b.id])
        #expect(harness.intents.lastFailures()?[a.id] == nil)
    }

    /// `evidenceReady` geht nur hinaus, solange die Folge nicht gelöscht ist,
    /// also liegt es im Postfach vor `episodesRemoved`. Was die Stufe dafür
    /// vermerkt hat, nimmt das Löschen wieder mit.
    @Test("Transkript fertig, dann gelöscht: kein Eintrag bleibt, weder Warteschlange noch erstes Sehen")
    func evidenceThenRemoval() async throws {
        let a = episode("A", daysAgo: 1)
        let harness = await makeHarness(store: try await makeStore([a]), settings: FakeSettings(analyzed: [a.id]))
        await harness.stage.reconcile()
        await harness.stage.receive(.evidenceReady(a.id, InputVersion(
            mediaVersionID: MediaVersionID(rawValue: "m"), transcriptID: TranscriptID(rawValue: "t"),
            revision: .initial, segmentCount: 1, lastEndMs: 1), .automatic))
        #expect(await harness.stage.queuedFacts == [a.id])
        harness.ledger.markRemoved([a.id])
        await harness.stage.receive(.episodesRemoved([a.id], .episode))
        #expect(await harness.stage.queuedFacts.isEmpty)
        #expect(harness.intents.factsQueue() == [])
        #expect(harness.intents.firstSeen()?[a.id] == nil)
    }

    @Test("Nach einem Neustart kommt die Warteschlange zurück, Angefordertes bleibt angefordert und vorn")
    func restoresAfterRestart() async throws {
        let a = episode("A", daysAgo: 3), b = episode("B", daysAgo: 1)
        let store = try await makeStore([a, b])
        let state = makeState()
        let settings = FakeSettings(analyzed: [a.id, b.id])
        let first = await makeHarness(store: store, settings: settings, state: state)
        await first.stage.reconcile()
        await first.stage.enqueue(b)
        await first.stage.request(a)
        await first.stage.stop()
        state.flush()

        let reopened = DeviceState(directory: state.directory)
        let second = await makeHarness(store: store, settings: settings, state: reopened)
        await second.stage.reconcile()
        #expect(await second.stage.queuedFacts == [a.id, b.id])
        #expect(second.intents.factsQueue() == [
            FactsIntent(episodeID: a.id, origin: .user, requested: true),
            FactsIntent(episodeID: b.id, origin: .automatic, requested: false),
        ])
        second.gate.setInForeground(true)
        #expect(await next(second.work.started) == "facts:A")
        await second.stage.untilIdle()
        #expect(second.work.calls.first == "facts:A!", "Nach dem Neustart rechnet die Anforderung neu")
    }

    @Test("Fremde Belege warten 20 Minuten ab dem ersten Sehen, auch über einen Neustart; eigene nicht")
    func syncGraceFromFirstSeen() async throws {
        let foreign = episode("Fremd", daysAgo: 1), own = episode("Eigen", daysAgo: 2)
        let store = try await makeStore([foreign, own])
        let state = makeState()
        let clock = TestClock()
        let settings = FakeSettings(analyzed: [foreign.id, own.id])
        PipelineIntents(state: state).markOwn([own.id])
        let first = await makeHarness(store: store, settings: settings, state: state, clock: clock)
        await first.stage.reconcile()
        #expect(await first.stage.queuedFacts == [own.id])
        #expect(first.intents.firstSeen()?[foreign.id] == clock.date)
        await first.stage.stop()
        state.flush()

        // Neustart nach fünf Minuten: Die Wartezeit läuft weiter, sie beginnt nicht neu.
        clock.advance(5 * 60)
        let second = await makeHarness(
            store: store, settings: settings, state: DeviceState(directory: state.directory), clock: clock)
        await second.stage.reconcile()
        #expect(await second.stage.queuedFacts == [own.id])
        clock.advance(16 * 60)
        await second.stage.reconcile()
        #expect(await second.stage.queuedFacts == [foreign.id, own.id])
    }

    @Test("Ein eigenes Transkript reiht die Fakten ein und wartet nie auf ein anderes Gerät")
    func evidenceReadyMarksOwn() async throws {
        let a = episode("A", daysAgo: 1)
        let harness = await makeHarness(store: try await makeStore([a]), settings: FakeSettings(analyzed: [a.id]))
        await harness.stage.receive(.evidenceReady(a.id, InputVersion(
            mediaVersionID: MediaVersionID(rawValue: "m"), transcriptID: TranscriptID(rawValue: "t"),
            revision: .initial, segmentCount: 1, lastEndMs: 1), .automatic))
        #expect(await harness.stage.queuedFacts == [a.id])
        #expect(harness.intents.firstSeen()?[a.id] == .distantPast)
    }

    @Test("Ohne „Fakten automatisch sammeln“ reiht ein Transkript nichts ein, bleibt aber eigen")
    func evidenceReadyWithoutAutomaticFacts() async throws {
        let a = episode("A", daysAgo: 1)
        let harness = await makeHarness(
            store: try await makeStore([a]), settings: FakeSettings(analyzed: [a.id], automaticFacts: false))
        await harness.stage.receive(.evidenceReady(a.id, InputVersion(
            mediaVersionID: MediaVersionID(rawValue: "m"), transcriptID: TranscriptID(rawValue: "t"),
            revision: .initial, segmentCount: 1, lastEndMs: 1), .automatic))
        #expect(await harness.stage.queuedFacts.isEmpty)
        #expect(harness.intents.firstSeen()?[a.id] == .distantPast)
    }

    @Test("„Alle abbrechen“ leert die Warteschlange, und der nächste Abgleich holt nichts zurück")
    func cancelAllDefers() async throws {
        let a = episode("A", daysAgo: 1), b = episode("B", daysAgo: 2)
        let store = try await makeStore([a, b])
        let settings = FakeSettings(analyzed: [a.id, b.id])
        let harness = await makeHarness(store: store, settings: settings)
        harness.intents.markOwn([a.id, b.id])
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedFacts == [a.id, b.id])
        await harness.stage.cancelAll()
        #expect(await harness.stage.queuedFacts.isEmpty)
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedFacts.isEmpty)
    }

    @Test("Fehlt das Modell, wartet die Folge mit Grund, und nichts läuft")
    func modelMissing() async throws {
        let a = episode("A", daysAgo: 1)
        let missing = ModelStatus(onDevice: .unavailable(.appleIntelligenceDisabled),
                                  privateCloudCompute: .unavailable(.userConsentMissing))
        let harness = await makeHarness(store: try await makeStore([a]), open: true, status: missing)
        await harness.stage.request(a)
        await harness.stage.untilIdle()
        #expect(harness.work.calls.isEmpty)
        #expect(await harness.stage.queuedFacts == [a.id])
        #expect(await harness.stage.snapshot.waitReason == .appleIntelligenceDisabled)
    }

    @Test("Kapitel ohne Tags aus dem Rückstand laufen, wenn keine Fakten warten")
    func tagBacklog() async throws {
        let a = episode("A", daysAgo: 1)
        let store = try await makeStore([a], transcripts: true)
        let media = MediaVersionID(stable: a.audioURL!.absoluteString)
        let evidence = try #require(try await store.evidence(forEpisode: a.id).first)
        try await store.save(facts: [EpisodeFact(
            id: "fakt-a", episodeID: a.id, sourceID: sourceID, evidenceID: evidence.id, mediaVersionID: media,
            statement: "Ein Satz über A.", range: try #require(evidence.range), modelTier: "onDevice")],
            forEpisode: a.id)
        let harness = await makeHarness(store: store, settings: FakeSettings(analyzed: [a.id]))
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedFacts.isEmpty, "Fakten ohne Lücken: nichts zu tun")
        #expect(await harness.stage.queuedTags == [a.id])
        harness.gate.setInForeground(true)
        #expect(await next(harness.work.started) == "tags:A")
        await harness.stage.untilIdle()
        #expect(harness.work.calls == ["tags:A:backlog"])
        // Eingeordnet: Der nächste Abgleich fragt die Folge nicht noch einmal ab.
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedTags.isEmpty)
    }

    @Test("Ein neu erfragtes, bereites Modell lässt Wartendes weiterlaufen, auch ohne Änderung")
    func modelCheckedResumes() async throws {
        let a = episode("A", daysAgo: 1)
        var plan = RecordingWork.Plan()
        plan.facts[episodeID("A")] = [.modelUnavailable(.modelNotReady)]
        let harness = await makeHarness(store: try await makeStore([a]), open: true, work: RecordingWork(plan))
        await harness.stage.request(a)
        #expect(await next(harness.work.started) == "facts:A")
        await harness.stage.untilIdle()
        #expect(await harness.stage.queuedFacts == [a.id])
        #expect(await harness.stage.snapshot.waitReason == .modelNotReady)
        await harness.stage.modelChecked(ready)
        #expect(await next(harness.work.started) == "facts:A")
        await harness.stage.untilIdle()
        #expect(await harness.stage.queuedFacts.isEmpty)
        #expect(harness.work.calls == ["facts:A!", "facts:A!", "tags:A:user"])
    }

    @Test("Fakten und Tags melden sich erst nach dem Lauf, mit der Fassung aus dem Store")
    func announcesAfterWork() async throws {
        let a = episode("A", daysAgo: 1)
        let host = PipelineHost()
        let sink = host.mailbox(for: .sink)
        let harness = await makeHarness(store: try await makeStore([a], transcripts: true), host: host)
        await harness.stage.request(a)
        harness.gate.setInForeground(true)
        let event = await next(sink)
        guard case .tagsDone(let id, let version, let outcome, let origin)? = event else {
            Issue.record("Kein tagsDone bei der Senke: \(String(describing: event))")
            return
        }
        #expect(id == a.id)
        #expect(outcome == .stored)
        #expect(origin == .user)
        #expect(version.mediaVersionID == MediaVersionID(stable: a.audioURL!.absoluteString))
        await harness.stage.untilIdle()
    }
}

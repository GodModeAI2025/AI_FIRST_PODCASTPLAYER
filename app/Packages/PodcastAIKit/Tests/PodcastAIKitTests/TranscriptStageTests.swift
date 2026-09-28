//
//  TranscriptStageTests.swift
//  PodcastAIKitTests
//
//  Schritt 5b der Stufen-Pipeline (docs/plan-pipeline.md): die Stufe
//  „Transkript“ führt Warteschlange, Reihenfolge, den einen Platz, das Tor,
//  die gemerkte Warteschlange und die Ereignisse. Die Arbeit an einer Folge
//  schreibt hier nur mit; sie kann hängen, bis die Stufe abbricht. Befehle
//  gehen direkt an `handle`, gewartet wird auf Zeichen, nie eine feste Zeit.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence

// MARK: - Bausteine

private let sourceID = SourceID(stable: "transkript-quelle")

private func episode(_ name: String) -> Episode {
    Episode(id: EpisodeID(stable: "transkript-\(name)"), sourceID: sourceID, title: name,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            audioURL: URL(string: "https://example.com/\(name).mp3"))
}

private func video(_ name: String) -> Episode {
    Episode(id: EpisodeID(stable: "transkript-video-\(name)"), sourceID: sourceID, title: name,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            webPageURL: URL(string: "https://www.youtube.com/watch?v=abcdefghij\(name.prefix(1))"))
}

private func media(of episode: Episode) -> MediaVersionID {
    CaptionAnalysis.feedMediaVersionID(of: episode)!
}

/// Schreibt Transkript und Beleg einer Folge, wie es die Arbeit täte.
private func writeTranscript(of episode: Episode, into store: LibraryStore) async throws {
    let media = media(of: episode)
    let range = MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 5_000))
    let transcript = Transcript(
        id: TranscriptID(stable: "\(media.rawValue)|de_DE"), mediaVersionID: media, revision: .initial,
        origin: .speechAnalysis, locale: "de_DE",
        segments: [TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: media, range: range),
                                     range: range, text: "Ein Satz.")],
        analyzedRanges: IntervalSet(range))
    try await store.save(transcript: transcript,
                         media: MediaVersion(id: media, episodeID: episode.id, remoteURL: episode.audioURL),
                         forEpisode: episode.id)
    try await store.store(evidence: [Evidence(
        id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
        mediaVersionID: media, episodeID: episode.id, sourceID: sourceID, transcriptID: transcript.id,
        transcriptRevision: .initial, range: range, quotedText: "Ein Satz.")])
}

private func makeStore(_ episodes: [Episode]) async throws -> LibraryStore {
    let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
    _ = try await store.upsert(episodes: episodes, forSource: sourceID)
    return store
}

/// Die Arbeit an einer Folge und was der Hauptakteur gemeldet bekommt.
/// Eine Folge in `outcomes` liefert der Reihe nach diese Ergebnisse, sonst
/// schreibt die Arbeit Transkript und Beleg. Eine Folge in `hangs` hängt,
/// bis die Stufe abbricht.
private final class RecordingWork: Sendable {
    struct Plan: Sendable {
        var outcomes: [EpisodeID: [TranscriptJobOutcome]] = [:]
        var hangs: Set<EpisodeID> = []
        var blocked: Set<EpisodeID> = []
    }

    private let state = Mutex<(calls: [String], plan: Plan, origins: [String])>(([], Plan(), []))
    let signals: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    let store: LibraryStore

    init(store: LibraryStore, plan: Plan = Plan()) {
        self.store = store
        state.withLock { $0.plan = plan }
        (signals, continuation) = AsyncStream.makeStream()
    }

    var calls: [String] { state.withLock { $0.calls } }
    var finalOrigins: [String] { state.withLock { $0.origins } }

    func note(_ call: String) {
        state.withLock { $0.calls.append(call) }
        continuation.yield(call)
    }

    func block(_ id: EpisodeID, _ blocked: Bool) {
        state.withLock { state in
            if blocked { state.plan.blocked.insert(id) } else { state.plan.blocked.remove(id) }
        }
    }

    func runnable(_ items: [TranscriptQueueItem]) -> Set<EpisodeID> {
        let blocked = state.withLock { $0.plan.blocked }
        return Set(items.map(\.episode.id)).subtracting(blocked)
    }

    func transcribe(_ job: TranscriptJob) async -> TranscriptJobOutcome {
        let (planned, hangs) = state.withLock { state -> (TranscriptJobOutcome?, Bool) in
            state.calls.append("job:\(job.episode.title)")
            let hangs = state.plan.hangs.remove(job.episode.id) != nil
            var list = state.plan.outcomes[job.episode.id] ?? []
            let next = list.isEmpty ? nil : list.removeFirst()
            state.plan.outcomes[job.episode.id] = list
            return (next, hangs)
        }
        continuation.yield("job:\(job.episode.title)")
        if hangs {
            try? await Task.sleep(for: .seconds(60))
            let origin = await job.currentOrigin()
            state.withLock { $0.origins.append("\(job.episode.title):\(origin)") }
            return Task.isCancelled ? .interrupted : .transcribed(media(of: job.episode))
        }
        if let planned { return planned }
        try? await writeTranscript(of: job.episode, into: store)
        return .transcribed(media(of: job.episode))
    }
}

/// Räumt die eigene Ablage der Benutzereinstellungen weg, wenn der Test
/// sie nicht mehr hält.
private final class Harness {
    let store: LibraryStore
    let gate: WorkGate
    let ledger: RemovalLedger
    let host: PipelineHost
    let work: RecordingWork
    let suite: String
    let stage: TranscriptStage
    let events: AsyncStream<PipelineEvent>
    let editions: AsyncStream<PipelineEvent>
    private let ownsSuite: Bool

    init(store: LibraryStore, gate: WorkGate, ledger: RemovalLedger, host: PipelineHost, work: RecordingWork,
         suite: String, ownsSuite: Bool, stage: TranscriptStage, events: AsyncStream<PipelineEvent>,
         editions: AsyncStream<PipelineEvent>) {
        self.store = store
        self.gate = gate
        self.ledger = ledger
        self.host = host
        self.work = work
        self.suite = suite
        self.ownsSuite = ownsSuite
        self.stage = stage
        self.events = events
        self.editions = editions
    }

    deinit {
        if ownsSuite { UserDefaults().removePersistentDomain(forName: suite) }
    }
}

private func makeSuite() -> String { "transkript-\(UUID().uuidString)" }

private func savedQueue(in suite: String) -> AnalysisQueueSnapshot? {
    AnalysisQueueSnapshot.decoded(from: UserDefaults(suiteName: suite)?.data(forKey: TranscriptStage.snapshotKey))
}

/// Das Tor steht anfangs zu (Hintergrund), damit sich Einreihen und
/// Reihenfolge prüfen lassen, ohne dass etwas läuft.
private func makeHarness(
    store: LibraryStore, open: Bool = false, plan: RecordingWork.Plan = RecordingWork.Plan(),
    suite: String = makeSuite(), ownsSuite: Bool = true, leases: LeasePolicy? = nil,
    restore: @escaping @Sendable ([AnalysisQueueSnapshot.Entry], [Episode]) async -> [TranscriptQueueItem] = { entries, found in
        entries.compactMap { entry in
            found.first { $0.id == entry.episodeID }.map {
                TranscriptQueueItem(episode: $0, origin: !entry.automatic ? .user : entry.backlog ? .backlog : .automatic)
            }
        }
    }
) async -> Harness {
    let gate = WorkGate(alwaysInForeground: false, inForeground: open)
    let ledger = RemovalLedger()
    let host = PipelineHost(gate: gate)
    // Die Empfänger von `evidenceReady` und `transcriptsIdle`, hier nur zum Mitlesen.
    let events = host.mailbox(for: .knowledge)
    let editions = host.mailbox(for: .editions)
    let work = RecordingWork(store: store, plan: plan)
    let stage = TranscriptStage(
        store: store, gate: gate, ledger: ledger, host: host,
        environment: TranscriptStage.Environment(
            runnable: { work.runnable($0) },
            runStarted: { work.note("start:\($0)") },
            runEnded: { work.note("ende:\($0 ? "angehalten" : "leer")") },
            transcribe: { await work.transcribe($0) },
            settled: { settlement in work.note("gemeldet:\(settlement)") },
            restore: restore),
        defaultsSuite: suite, retryPause: .milliseconds(1), leases: leases)
    await stage.start()
    return Harness(store: store, gate: gate, ledger: ledger, host: host, work: work, suite: suite,
                   ownsSuite: ownsSuite, stage: stage, events: events, editions: editions)
}

/// Wartet auf ein bestimmtes Zeichen, höchstens zehn Sekunden.
private func expectSignal(_ wanted: String, in stream: AsyncStream<String>) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await signal in stream where signal == wanted { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// Das nächste Ereignis, höchstens zehn Sekunden.
private func nextEvent(_ stream: AsyncStream<PipelineEvent>) async -> PipelineEvent? {
    await withTaskGroup(of: PipelineEvent?.self) { group in
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

@Suite("Stufe „Transkript“")
struct TranscriptStageTests {

    @Test("Von Hand vor allem Automatischen, neue Folgen vor den älteren, diese ans Ende")
    func order() async throws {
        let a = episode("A"), b = episode("B"), c = episode("C"), d = episode("D")
        let harness = await makeHarness(store: try await makeStore([a, b, c, d]))
        await harness.stage.handle(.enqueue(a, .backlog))
        await harness.stage.handle(.enqueue(b, .automatic))
        await harness.stage.handle(.request(c))
        await harness.stage.handle(.enqueue(d, .automatic))
        #expect(await harness.stage.queuedIDs == [c.id, b.id, d.id, a.id])
        // Von Hand angefordert rückt eine wartende Folge ganz nach vorn.
        await harness.stage.handle(.request(a))
        #expect(await harness.stage.queuedIDs == [a.id, c.id, b.id, d.id])
        // Von selbst eingereiht ändert an einer wartenden Folge nichts.
        await harness.stage.handle(.enqueue(c, .backlog))
        #expect(await harness.stage.snapshot.queue.first { $0.episode.id == c.id }?.origin == .user)
        #expect(harness.work.calls.isEmpty, "Das Tor ist zu, nichts darf laufen")
    }

    @Test("Geht das Tor auf, läuft eine Folge nach der anderen, danach Ereignisse und `transcriptsIdle`")
    func runsAndAnnounces() async throws {
        let a = episode("A"), b = episode("B")
        let harness = await makeHarness(store: try await makeStore([a, b]))
        await harness.stage.handle(.request(a))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(harness.work.calls == ["start:A", "job:A", "job:B", "ende:leer"])
        guard case .evidenceReady(let first, _, let firstOrigin)? = await nextEvent(harness.events),
              case .evidenceReady(let second, _, let secondOrigin)? = await nextEvent(harness.events) else {
            Issue.record("Zwei Folgen, zwei `evidenceReady`")
            return
        }
        #expect(first == a.id && firstOrigin == .user)
        #expect(second == b.id && secondOrigin == .automatic)
        #expect(await nextEvent(harness.editions) == .transcriptsIdle)
        #expect(await harness.stage.queuedIDs.isEmpty)
    }

    @Test("Hat die Fassung laut Store schon Belege, gibt es keine Arbeit")
    func preCheckSkipsTranscribed() async throws {
        let a = episode("A"), b = episode("B")
        let store = try await makeStore([a, b])
        try await writeTranscript(of: a, into: store)
        let harness = await makeHarness(store: store)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(!harness.work.calls.contains("job:A"), "Ein zweiter Lauf ruft keine Spracherkennung")
        #expect(harness.work.calls.contains(
            "gemeldet:\(TranscriptSettlement.alreadyTranscribed(TranscriptQueueItem(episode: a, origin: .automatic)))"))
        #expect(harness.work.calls.contains("job:B"))
    }

    @Test("Eine ältere Folge, die laut Store schon Belege hat, meldet sich mit Herkunft, damit die nächste nachrückt")
    func preCheckReportsBacklog() async throws {
        let a = episode("A")
        let store = try await makeStore([a])
        try await writeTranscript(of: a, into: store)
        let harness = await makeHarness(store: store)
        await harness.stage.handle(.enqueue(a, .backlog))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(harness.work.calls.contains(
            "gemeldet:\(TranscriptSettlement.alreadyTranscribed(TranscriptQueueItem(episode: a, origin: .backlog)))"))
    }

    @Test("Vor einer Löschung geschickt, danach angekommen: Die Folge kommt nicht in die Warteschlange")
    func commandSentBeforeRemoval() async throws {
        let a = episode("A"), b = episode("B")
        let harness = await makeHarness(store: try await makeStore([a, b]))
        let sent = harness.ledger.ticket
        harness.ledger.markRemoved([a.id, b.id])
        // Das Löschen kam schon an, die Befehle erst jetzt.
        await harness.stage.receive(.episodesRemoved([a.id, b.id], .episode))
        await harness.stage.handle(.enqueue(a, .automatic), ticket: sent)
        await harness.stage.handle(.request(b), ticket: sent)
        #expect(await harness.stage.queuedIDs.isEmpty)
        // Über `submit` gilt der Stand beim Schicken.
        let c = episode("C")
        harness.stage.submit(.enqueue(c, .automatic))
        await harness.stage.settleCommands()
        #expect(await harness.stage.queuedIDs == [c.id])
    }

    @Test("Angehalten, bevor der Befehl ankommt: Der Lauf endet und beginnt nicht mit derselben Folge weiter")
    func interruptedOutcomeEndsRun() async throws {
        let a = episode("A"), b = episode("B")
        var plan = RecordingWork.Plan()
        plan.outcomes[a.id] = [.interrupted]
        let harness = await makeHarness(store: try await makeStore([a, b]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        // Vorn beginnt danach ein neuer Lauf; der angehaltene meldete sich ab.
        #expect(harness.work.calls == ["start:A", "job:A", "ende:angehalten", "start:A", "job:A", "job:B", "ende:leer"])
    }

    @Test("Nach einem anderen Speicher kommt die gemerkte Warteschlange zurück, und die Stufe merkt sich wieder")
    func restoreAfterStoreReset() async throws {
        let a = episode("A"), b = episode("B")
        let store = try await makeStore([a, b])
        let suite = makeSuite()
        UserDefaults(suiteName: suite)?.set(
            AnalysisQueueSnapshot(running: nil, queue: [a.id], automatic: [], backlog: []).encoded(),
            forKey: TranscriptStage.snapshotKey)
        let harness = await makeHarness(store: store, suite: suite)
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedIDs == [a.id])
        await harness.stage.reset(store: store)
        #expect(await harness.stage.queuedIDs.isEmpty)
        await harness.stage.restoreIfNeeded()
        #expect(await harness.stage.queuedIDs == [a.id])
        await harness.stage.handle(.enqueue(b, .automatic))
        // Gemerkt wird gebündelt: bis zu zwei Sekunden warten statt fester
        // 50 ms, die unter Last der ganzen Suite nicht immer reichten.
        for _ in 0..<40 where savedQueue(in: suite)?.entries.map(\.episodeID) != [a.id, b.id] {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(savedQueue(in: suite)?.entries.map(\.episodeID) == [a.id, b.id])
    }

    @Test("Angetippt während des Laufs: Das Ereignis trägt `.user`")
    func requestPromotesRunning() async throws {
        let a = episode("A")
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        await harness.stage.handle(.request(a))
        #expect(await harness.stage.queuedIDs.isEmpty, "Die laufende Folge kommt nicht ein zweites Mal hinein")
        #expect(await harness.stage.snapshot.running?.origin == .user)
        // Die Pause bricht ab; wer sie jetzt will, steht in ihrem Platz.
        harness.gate.setPaused(true)
        #expect(await expectSignal("ende:angehalten", in: harness.work.signals))
        #expect(harness.work.finalOrigins == ["A:user"])
        #expect(await harness.stage.snapshot.queue.first?.origin == .user)
    }

    @Test("Die Pause hält die laufende Folge an, sie steht wieder vorn, kein `transcriptsIdle`")
    func pauseReturnsRunningToFront() async throws {
        let a = episode("A"), b = episode("B")
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        harness.gate.setPaused(true)
        #expect(await expectSignal("ende:angehalten", in: harness.work.signals))
        #expect(await harness.stage.queuedIDs == [a.id, b.id])
        // Der Weg in den Hintergrund hält nichts an, nur die Pause.
        harness.gate.setPaused(false)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(harness.work.calls.filter { $0 == "job:A" }.count == 2)
        #expect(await nextEvent(harness.editions) == .transcriptsIdle, "Erst der leer gelaufene Lauf meldet es")
    }

    @Test("Im Hintergrund läuft der begonnene Lauf weiter, bis die Zeit endet")
    func backgroundKeepsRunning() async throws {
        let a = episode("A"), b = episode("B")
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        harness.gate.setInForeground(false)
        await harness.stage.handle(.conditionsChanged)
        #expect(await harness.stage.snapshot.running?.episode.id == a.id, "Der Hintergrund bricht nichts ab")
        // Die Zeit des Systems endet.
        await harness.stage.handle(.interrupt)
        #expect(await expectSignal("ende:angehalten", in: harness.work.signals))
        #expect(await harness.stage.queuedIDs == [a.id, b.id])
        #expect(!harness.work.calls.contains("job:B"), "Im Hintergrund beginnt kein neuer Lauf")
    }

    @Test("Ein Fehler, der vorbeigeht: einmal zurück an den Platz, beim zweiten Mal weg")
    func retryOnce() async throws {
        let a = episode("A")
        var plan = RecordingWork.Plan()
        let transient = TranscriptJobOutcome.failed(TranscriptFailure(.transient), retry: true)
        plan.outcomes[a.id] = [transient, transient]
        let harness = await makeHarness(store: try await makeStore([a]), plan: plan)
        await harness.stage.handle(.enqueue(a, .backlog))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(harness.work.calls.filter { $0 == "job:A" }.count == 2)
        #expect(harness.work.calls.contains("gemeldet:\(TranscriptSettlement.retrying(a.id))"))
        #expect(harness.work.calls.contains("gemeldet:\(TranscriptSettlement.gaveUpBacklog(a.id))"))
        #expect(await harness.stage.queuedIDs.isEmpty)
        #expect(await harness.stage.snapshot.queue.isEmpty)
    }

    @Test("Keine Sprache für den Podcast: Die übrigen von selbst eingereihten Folgen gehen mit")
    func localeFailureDropsSiblings() async throws {
        let a = episode("A"), b = episode("B"), c = episode("C")
        var plan = RecordingWork.Plan()
        plan.outcomes[a.id] = [.failed(TranscriptFailure(.localeNotSupported), retry: false)]
        let harness = await makeHarness(store: try await makeStore([a, b, c]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        await harness.stage.handle(.request(c))
        harness.work.block(c.id, true)
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(harness.work.calls.contains("gemeldet:\(TranscriptSettlement.preparationFailed([b.id]))"))
        #expect(await harness.stage.queuedIDs == [c.id], "Was jemand angefordert hat, bleibt")
    }

    @Test("Gelöscht: wartend verschwindet sie, laufend kommt nichts zurück und kein Ereignis")
    func removal() async throws {
        let a = episode("A"), b = episode("B")
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.work.block(b.id, true)
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        harness.ledger.markRemoved([a.id, b.id])
        await harness.stage.receive(.episodesRemoved([a.id, b.id], .episode))
        #expect(await harness.stage.queuedIDs.isEmpty)
        #expect(await harness.stage.snapshot.running == nil)
        // Die Arbeit endet (hier über die Pause); die Folge kommt nicht zurück.
        harness.gate.setPaused(true)
        #expect(await expectSignal("ende:angehalten", in: harness.work.signals))
        #expect(await harness.stage.queuedIDs.isEmpty)
    }

    @Test("„Alle abbrechen“ nimmt alles heraus, die laufende vorn, Automatisches ruht")
    func cancelAll() async throws {
        let a = episode("A"), b = episode("B"), c = episode("C")
        var plan = RecordingWork.Plan()
        plan.hangs = [a.id]
        let harness = await makeHarness(store: try await makeStore([a, b, c]), plan: plan)
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.request(b))
        await harness.stage.handle(.enqueue(c, .backlog))
        harness.work.block(b.id, true)
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        harness.gate.setCancelling(true)
        let cancelled = await harness.stage.cancelAll()
        harness.gate.setCancelling(false)
        #expect(cancelled.removed.map(\.episode.id) == [a.id, b.id, c.id])
        #expect(cancelled.resting == [a.id, c.id])
        #expect(await harness.stage.queuedIDs.isEmpty)
    }

    @Test("Die Warteschlange übersteht einen Neustart, auch mit Videos, ohne was inzwischen Belege hat")
    func restoreAfterRestart() async throws {
        let a = episode("A"), b = episode("B"), v = video("V")
        let store = try await makeStore([a, b, v])
        let suite = makeSuite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = await makeHarness(store: store, suite: suite, ownsSuite: false)
        await first.stage.reconcile()
        await first.stage.handle(.request(v))
        await first.stage.handle(.enqueue(a, .automatic))
        await first.stage.handle(.enqueue(b, .backlog))
        // Das Merken ist gebündelt; nach einem Befehl mehr steht es sicher.
        await first.stage.settleCommands()
        for _ in 0..<40 where savedQueue(in: suite)?.entries.map(\.episodeID) != [v.id, a.id, b.id] {
            try await Task.sleep(for: .milliseconds(50))
        }
        let saved = try #require(savedQueue(in: suite))
        #expect(saved.entries.map(\.episodeID) == [v.id, a.id, b.id])
        #expect(saved.entries.map(\.automatic) == [false, true, true])
        #expect(saved.entries.map(\.backlog) == [false, false, true])
        await first.stage.stop()

        // A bekam inzwischen auf einem anderen Gerät Transkript und Belege.
        try await writeTranscript(of: a, into: store)
        let second = await makeHarness(store: store, suite: suite, ownsSuite: false)
        await second.stage.reconcile()
        #expect(await second.stage.queuedIDs == [v.id, b.id])
        #expect(await second.stage.snapshot.queue.map(\.origin) == [.user, .backlog])
    }

    @Test("Vor dem Wiederherstellen überschreibt die Stufe die gemerkte Warteschlange nicht")
    func noPersistBeforeRestore() async throws {
        let a = episode("A"), b = episode("B")
        let store = try await makeStore([a, b])
        let suite = makeSuite()
        UserDefaults(suiteName: suite)?.set(
            AnalysisQueueSnapshot(running: nil, queue: [a.id], automatic: [], backlog: []).encoded(),
            forKey: TranscriptStage.snapshotKey)
        let harness = await makeHarness(store: store, suite: suite)
        await harness.stage.handle(.enqueue(b, .automatic))
        try await Task.sleep(for: .milliseconds(50))
        #expect(savedQueue(in: suite)?.entries.map(\.episodeID) == [a.id])
        await harness.stage.reconcile()
        #expect(await harness.stage.queuedIDs == [a.id, b.id])
    }

    // MARK: - Sperre über Geräte hinweg (Schema nach 0.14)

    @Test("Transkribiert ein anderes Gerät die Folge, wartet sie bis zum Ablauf und übernimmt dann")
    func leaseHeldElsewhereWaitsAndTakesOver() async throws {
        let a = episode("A"), b = episode("B")
        let store = try await makeStore([a, b])
        // Das iPad hält die Sperre für A noch 0,8 Sekunden.
        try await store.insertLeaseForTesting(.transcript, for: a.id, device: "ipad",
                                              acquiredAt: Date(), expiresAt: Date().addingTimeInterval(0.8))
        let harness = await makeHarness(store: store, leases: LeasePolicy(deviceID: "iphone"))
        await harness.stage.handle(.enqueue(a, .automatic))
        await harness.stage.handle(.enqueue(b, .automatic))
        harness.gate.setInForeground(true)
        // B läuft, A wartet an seinem Platz.
        #expect(await expectSignal("job:B", in: harness.work.signals))
        #expect(!harness.work.calls.contains("job:A"))
        #expect(await harness.stage.queuedIDs.contains(a.id), "A bleibt in der Warteschlange")
        // Nach dem Ablauf übernimmt dieses Gerät.
        #expect(await expectSignal("job:A", in: harness.work.signals))
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        // Danach ist die eigene Sperre freigegeben, die abgelaufene fremde weg.
        #expect(try await store.leases(for: a.id).isEmpty)
    }

    @Test("Ohne fremde Sperre nimmt die Stufe die eigene und gibt sie nach dem Transkript frei")
    func leaseTakenAndReleased() async throws {
        let a = episode("A")
        let store = try await makeStore([a])
        let plan = RecordingWork.Plan(hangs: [a.id])
        let harness = await makeHarness(store: store, plan: plan, leases: LeasePolicy(deviceID: "iphone"))
        await harness.stage.handle(.request(a))
        harness.gate.setInForeground(true)
        #expect(await expectSignal("job:A", in: harness.work.signals))
        let held = try await store.leases(for: a.id)
        #expect(held.map(\.deviceID) == ["iphone"])
        #expect(held.first?.kind == .transcript)
        // Die App geht in den Hintergrund ohne fortgesetzte Verarbeitung:
        // angehalten bleibt die Sperre bis zum Ablauf.
        harness.gate.setInForeground(false)
        await harness.stage.handle(.interrupt)
        #expect(await expectSignal("ende:angehalten", in: harness.work.signals))
        #expect(try await store.leases(for: a.id).map(\.deviceID) == ["iphone"])
        // Wieder vorn: dieselbe Sperre gilt weiter, nach dem Transkript ist sie weg.
        harness.gate.setInForeground(true)
        #expect(await expectSignal("ende:leer", in: harness.work.signals))
        #expect(try await store.leases(for: a.id).isEmpty)
    }
}

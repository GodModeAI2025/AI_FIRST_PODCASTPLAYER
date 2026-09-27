//
//  PrepareDownloadStageTests.swift
//  PodcastAIKitTests
//
//  Schritt 5a der Stufen-Pipeline (docs/plan-pipeline.md): die Stufen
//  „Vorbereiten“ und „Download“ führen Auslöser, Tor und die Prüfung im
//  Store. Was in Frage kommt und was geladen wird, entscheidet der
//  Hauptakteur; hier schreibt ein Rekorder mit. Gewartet wird auf Zeichen,
//  nie eine feste Zeit.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence

// MARK: - Bausteine

private let sourceA = SourceID(stable: "vorbereiten-a")
private let sourceB = SourceID(stable: "vorbereiten-b")

private func episode(_ name: String, in source: SourceID = sourceA) -> Episode {
    Episode(id: EpisodeID(stable: "vorbereiten-\(name)"), sourceID: source, title: name,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            audioURL: URL(string: "https://example.com/\(name).mp3"))
}

private func media(of episode: Episode) -> MediaVersionID {
    MediaVersionID(stable: episode.audioURL!.absoluteString)
}

/// Ein Speicher mit zwei Quellen und diesen Folgen. `transcribed` bekommen
/// ein Transkript mit einem Segment.
private func makeStore(_ episodes: [Episode], transcribed: [Episode] = []) async throws -> LibraryStore {
    let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    for source in [sourceA, sourceB] {
        try await store.upsert(source: Source(id: source, kind: .podcastRSS, title: source.rawValue))
        _ = try await store.upsert(episodes: episodes.filter { $0.sourceID == source }, forSource: source)
    }
    for episode in transcribed {
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
    }
    return store
}

/// Schreibt mit, was eine Stufe beim Hauptakteur fragt und ihm aufträgt,
/// und meldet jeden Aufruf als Zeichen.
private final class Recorder: Sendable {
    private let state = Mutex<[String]>([])
    let signals: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        (signals, continuation) = AsyncStream.makeStream()
    }

    var calls: [String] { state.withLock { $0 } }

    func note(_ call: String) {
        state.withLock { $0.append(call) }
        continuation.yield(call)
    }
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

private func prepareStage(
    store: LibraryStore, gate: WorkGate, ledger: RemovalLedger, recorder: Recorder,
    candidates: [Episode], backCatalog: [SourceID: [Episode]] = [:]
) -> PrepareStage {
    PrepareStage(
        store: store, gate: gate, ledger: ledger, host: nil,
        environment: PrepareStage.Environment(
            candidates: { sources in
                recorder.note("candidates:\(sources.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "alle")")
                return candidates.filter { sources?.contains($0.sourceID) ?? true }
                    .map { PreparationCandidate(episode: $0, backlog: false) }
            },
            backCatalog: { source in
                recorder.note("archiv:\(source.rawValue)")
                return (backCatalog[source] ?? []).map { PreparationCandidate(episode: $0, backlog: true) }
            },
            enqueue: { list in
                recorder.note("einreihen:" + list.map { $0.episode.title + ($0.backlog ? "*" : "") }.joined(separator: ","))
            },
            alreadyTranscribed: { ids in
                recorder.note("schon:\(ids.count)")
            },
            markFailed: { id in
                recorder.note("gescheitert:\(id.rawValue)")
            },
            forget: { ids in
                recorder.note("vergessen:\(ids.count)")
            },
            fetchMetadata: {
                recorder.note("metadaten")
            }))
}

// MARK: - Vorbereiten

@Suite("Stufe „Vorbereiten“")
struct PrepareStageTests {

    @Test("Nach dem Aktualisieren reiht sie ein, was laut Store noch kein Transkript hat, und holt Metadaten")
    func refreshSkipsTranscribed() async throws {
        let a = episode("A"), b = episode("B"), c = episode("C", in: sourceB)
        let store = try await makeStore([a, b, c], transcribed: [b])
        let recorder = Recorder()
        let stage = prepareStage(store: store, gate: WorkGate(alwaysInForeground: true), ledger: RemovalLedger(),
                                 recorder: recorder, candidates: [a, b, c])
        await stage.receive(.feedsRefreshed(byUser: false))
        await stage.untilIdle()
        let calls = recorder.calls
        #expect(calls.first == "candidates:alle")
        #expect(calls.contains("schon:1"), "B hat im Store schon ein Transkript")
        #expect(calls.contains("einreihen:A,C"))
        // Danach die älteren Folgen jeder Quelle, zuletzt die Metadaten.
        #expect(calls.contains("archiv:\(sourceA.rawValue)"))
        #expect(calls.contains("archiv:\(sourceB.rawValue)"))
        #expect(calls.last == "metadaten")
    }

    @Test("Neue Folgen bereiten nur ihre Quellen vor, samt deren älteren Folgen")
    func episodesAddedPreparesTheirSources() async throws {
        let a = episode("A"), c = episode("C", in: sourceB), old = episode("Alt", in: sourceB)
        let store = try await makeStore([a, c, old])
        let recorder = Recorder()
        let stage = prepareStage(store: store, gate: WorkGate(alwaysInForeground: true), ledger: RemovalLedger(),
                                 recorder: recorder, candidates: [a, c], backCatalog: [sourceB: [old]])
        await stage.receive(.episodesAdded([c.id], .automatic))
        await stage.untilIdle()
        #expect(recorder.calls.prefix(4) == [
            "candidates:\(sourceB.rawValue)", "einreihen:C", "archiv:\(sourceB.rawValue)", "einreihen:Alt*"])
    }

    @Test("Eine ältere Folge ist fertig oder gescheitert: Die nächste rückt nach")
    func backlogRefills() async throws {
        let a = episode("A"), next = episode("Nächste")
        let store = try await makeStore([a, next])
        let recorder = Recorder()
        let stage = prepareStage(store: store, gate: WorkGate(alwaysInForeground: true), ledger: RemovalLedger(),
                                 recorder: recorder, candidates: [], backCatalog: [sourceA: [next]])
        let version = InputVersion(mediaVersionID: media(of: a), transcriptID: TranscriptID(stable: "t"),
                                   revision: .initial, segmentCount: 1, lastEndMs: 1)
        await stage.receive(.evidenceReady(a.id, version, .automatic))
        await stage.untilIdle()
        #expect(recorder.calls.isEmpty, "Eine neue Folge zieht kein Archiv nach")
        await stage.receive(.evidenceReady(a.id, version, .backlog))
        await stage.untilIdle()
        #expect(recorder.calls == ["archiv:\(sourceA.rawValue)", "einreihen:Nächste*"])
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.transient), .backlog))
        await stage.untilIdle()
        #expect(recorder.calls.suffix(2) == ["archiv:\(sourceA.rawValue)", "einreihen:Nächste*"])
    }

    @Test("Gemerkt wird nur, was von selbst eingereiht war und wieder scheitern würde")
    func failuresAreRemembered() async throws {
        let a = episode("A")
        let store = try await makeStore([a])
        let recorder = Recorder()
        let ledger = RemovalLedger()
        let stage = prepareStage(store: store, gate: WorkGate(alwaysInForeground: true), ledger: ledger,
                                 recorder: recorder, candidates: [])
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.transient), .automatic))
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.permanent), .user))
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.speechUnavailable), .automatic))
        #expect(recorder.calls.isEmpty)
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.permanent), .automatic))
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.localeNotSupported), .backlog))
        await stage.untilIdle()
        #expect(recorder.calls.filter { $0.hasPrefix("gescheitert") }.count == 2)
        // Gelöscht: Das Löschen kommt hinter dem Fehlschlag an und nimmt den
        // Vermerk wieder heraus (Regel 5).
        await stage.receive(.episodesRemoved([a.id], .episode))
        #expect(recorder.calls.last == "vergessen:1")
    }

    @Test("Seit dem Fragen gelöscht: Die Folge kommt nicht in die Warteschlange")
    func removedWhileAskingIsNotQueued() async throws {
        let a = episode("A"), b = episode("B")
        let store = try await makeStore([a, b])
        let recorder = Recorder()
        let ledger = RemovalLedger()
        let stage = PrepareStage(
            store: store, gate: WorkGate(alwaysInForeground: true), ledger: ledger, host: nil,
            environment: PrepareStage.Environment(
                candidates: { _ in
                    // Während der Hauptakteur antwortet, wird A gelöscht.
                    ledger.markRemoved([a.id])
                    return [a, b].map { PreparationCandidate(episode: $0, backlog: false) }
                },
                backCatalog: { _ in [] },
                enqueue: { list in recorder.note("einreihen:" + list.map(\.episode.title).joined(separator: ",")) },
                alreadyTranscribed: { _ in },
                markFailed: { _ in },
                forget: { _ in },
                fetchMetadata: {}))
        await stage.prepare(sources: [sourceA])
        #expect(recorder.calls == ["einreihen:B"])
    }

    @Test("In der Pause reiht sie ein, die Metadaten warten; nach „Alle abbrechen“ erst der nächste Anlass")
    func metadataWaitsForGate() async throws {
        let a = episode("A")
        let store = try await makeStore([a])
        let recorder = Recorder()
        let gate = WorkGate(alwaysInForeground: true)
        gate.setPaused(true)
        let stage = prepareStage(store: store, gate: gate, ledger: RemovalLedger(), recorder: recorder,
                                 candidates: [a])
        await stage.start()
        await stage.prepare(sources: nil)
        #expect(recorder.calls.contains("einreihen:A"), "Einreihen hält keine Pause an")
        #expect(!recorder.calls.contains("metadaten"))
        gate.setPaused(false)
        #expect(await expectSignal("metadaten", in: recorder.signals))

        // Pause, dann „Alle abbrechen“: Das Nachholen fällt weg. Der Stand
        // geht hier direkt an die Stufe, damit kein Zwischenstand im Strom
        // des Tors verloren geht.
        gate.setPaused(true)
        await stage.prepare(sources: nil)
        await stage.gateChanged(WorkConditions(inForeground: true, paused: true, cancelling: true))
        gate.setPaused(false)
        await stage.prepare(sources: [sourceB])
        #expect(recorder.calls.filter { $0 == "metadaten" }.count == 2,
                "Nur der neue Anlass holt Metadaten, nicht die aufgehaltenen")
        await stage.stop()
    }
}

// MARK: - Download

private func downloadStage(
    gate: WorkGate, ledger: RemovalLedger, host: PipelineHost?, recorder: Recorder, prefetchable: [Episode]
) -> DownloadStage {
    let pending = Mutex(prefetchable)
    return DownloadStage(
        gate: gate, ledger: ledger, host: host,
        environment: DownloadStage.Environment(
            nextPrefetch: { pending.withLock { $0.first } },
            prefetch: { episode in
                recorder.note("laden:\(episode.title)")
                pending.withLock { list in list.removeAll { $0.id == episode.id } }
                return media(of: episode)
            },
            tidy: { recorder.note("aufräumen") },
            afterTranscript: { id in recorder.note("nachTranskript:\(id.rawValue)") },
            afterFailedPreparation: { id in recorder.note("nachFehlschlag:\(id.rawValue)") },
            lookahead: { recorder.note("voraus") }))
}

@Suite("Stufe „Download“")
struct DownloadStageTests {

    @Test("Nach dem Aktualisieren hält sie eine Folge nach der anderen vor, meldet den Ton und räumt auf")
    func prefetchAfterRefresh() async throws {
        let a = episode("A"), b = episode("B", in: sourceB)
        let recorder = Recorder()
        let ledger = RemovalLedger()
        let host = PipelineHost(gate: WorkGate(alwaysInForeground: true))
        let transcripts = host.mailbox(for: .transcript)
        let stage = downloadStage(gate: host.gate, ledger: ledger, host: host, recorder: recorder,
                                  prefetchable: [a, b])
        await stage.receive(.feedsRefreshed(byUser: false))
        await stage.untilIdle()
        #expect(recorder.calls == ["laden:A", "laden:B", "aufräumen"])
        var iterator = transcripts.makeAsyncIterator()
        #expect(await iterator.next() == .audioAvailable(a.id, media(of: a)))
        #expect(await iterator.next() == .audioAvailable(b.id, media(of: b)))
    }

    @Test("Die Pause hält das Vorhalten an, danach geht es weiter; nach „Alle abbrechen“ nicht")
    func pauseHoldsPrefetch() async throws {
        let a = episode("A"), b = episode("B")
        let recorder = Recorder()
        let gate = WorkGate(alwaysInForeground: true)
        gate.setPaused(true)
        let stage = downloadStage(gate: gate, ledger: RemovalLedger(), host: nil, recorder: recorder,
                                  prefetchable: [a])
        await stage.start()
        await stage.prefetch()
        await stage.untilIdle()
        #expect(recorder.calls.isEmpty)
        gate.setPaused(false)
        #expect(await expectSignal("aufräumen", in: recorder.signals))
        #expect(recorder.calls == ["laden:A", "aufräumen"])

        let other = downloadStage(gate: gate, ledger: RemovalLedger(), host: nil, recorder: recorder,
                                  prefetchable: [b])
        await other.start()
        gate.setPaused(true)
        await other.prefetch()
        gate.setCancelling(true)
        await other.cancelAll()
        gate.setCancelling(false)
        gate.setPaused(false)
        // Ein Befehl danach läuft wieder: Er ist der nächste Anlass.
        await other.tidy()
        #expect(!recorder.calls.contains("laden:B"), "Das aufgehaltene Vorhalten fällt nach „Alle abbrechen“ weg")
        await other.prefetch()
        await other.untilIdle()
        #expect(recorder.calls.contains("laden:B"))
        await stage.stop()
        await other.stop()
    }

    @Test("Ton geht nach dem Transkript und nach einem gescheiterten Vorbereiten, nicht bei Angefordertem")
    func tidiesAfterTranscript() async throws {
        let a = episode("A")
        let recorder = Recorder()
        let ledger = RemovalLedger()
        let stage = downloadStage(gate: WorkGate(alwaysInForeground: true), ledger: ledger, host: nil,
                                  recorder: recorder, prefetchable: [])
        let version = InputVersion(mediaVersionID: media(of: a), transcriptID: TranscriptID(stable: "t"),
                                   revision: .initial, segmentCount: 1, lastEndMs: 1)
        await stage.receive(.evidenceReady(a.id, version, .user))
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.permanent), .user))
        await stage.receive(.transcriptFailed(a.id, TranscriptFailure(.transient), .backlog))
        #expect(recorder.calls == ["nachTranskript:\(a.id.rawValue)", "nachFehlschlag:\(a.id.rawValue)"])
    }
}

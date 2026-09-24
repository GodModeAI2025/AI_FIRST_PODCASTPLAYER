//
//  ProcessingPerformanceTests.swift
//
//  Die Datenbank arbeitet nicht auf dem Hauptthread, auch wenn die
//  Oberfläche sie fragt. Bis 0.10 lief jede Abfrage des `AppModel` dort,
//  weil der Ausführer von `@ModelActor` einen Auftrag auf dem Thread
//  erledigt, der ihn einreiht (`LibraryStore`, `StoreExecutor`).
//
//  Die Messung läuft nur auf Wunsch, denn allein das Anlegen der
//  Bibliothek dauert:
//
//      PODCASTAI_PROCESSING_BENCH=1 swift test --filter ProcessingBenchmark
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence

extension LibraryStore {
    /// Läuft dieser Auftrag gerade auf dem Hauptthread?
    func runsOnMainThread() -> Bool { pthread_main_np() != 0 }
}

@Suite struct StoreIsolationTests {

    @MainActor
    @Test func storeWorkLeavesTheMainThread() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        #expect(await store.runsOnMainThread() == false)
        // Auch eine echte Abfrage aus der Oberfläche heraus.
        _ = try await store.sources()
        #expect(await store.runsOnMainThread() == false)
    }

    @Test func storeWorkLeavesTheMainThreadWhenBuiltThere() async throws {
        let store = await MainActor.run {
            LibraryStore.make(container: try! LibraryStore.makeContainer(inMemory: true))
        }
        let onMain = await MainActor.run { () -> Task<Bool, Never> in
            Task { @MainActor in await store.runsOnMainThread() }
        }
        #expect(await onMain.value == false)
    }
}

/// Listen dieses Geräts als Dateien statt in den Benutzereinstellungen.
@Suite struct DeviceStateTests {

    private func makeState() -> DeviceState {
        DeviceState(directory: FileManager.default.temporaryDirectory
            .appending(path: "devicestate-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func writesInTheBackgroundAndReadsBack() {
        let state = makeState()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        for count in 1...50 { state.set(Array(repeating: "folge", count: count), for: "liste") }
        #expect(state.value([String].self, for: "liste")?.count == 50)
        state.flush()
        // Ein neuer Start liest die Datei, mit dem letzten Stand.
        let reopened = DeviceState(directory: state.directory)
        #expect(reopened.value([String].self, for: "liste")?.count == 50)
    }

    @Test func removingDeletesTheFile() {
        let state = makeState()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        state.set(["a"], for: "liste")
        state.set([String]?.none, for: "liste")
        state.flush()
        #expect(DeviceState(directory: state.directory).value([String].self, for: "liste") == nil)
    }

    @Test func movesTheOldValueOutOfUserDefaults() {
        let state = makeState()
        let key = "devicestate-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: state.directory)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(["alt-1", "alt-2"], forKey: key)
        let moved = state.value([String].self, for: key) { UserDefaults.standard.stringArray(forKey: key) }
        #expect(moved == ["alt-1", "alt-2"])
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        state.flush()
        #expect(DeviceState(directory: state.directory).value([String].self, for: key) == ["alt-1", "alt-2"])
    }
}

/// Misst, wie lange der Hauptthread steht, während die Oberfläche die
/// Datenbank fragt und nebenher ein Transkript gespeichert wird.
enum ProcessingBenchmarkSwitch {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PODCASTAI_PROCESSING_BENCH"] == "1" }
}

@Suite(.enabled(if: ProcessingBenchmarkSwitch.isEnabled))
struct ProcessingBenchmark {

    /// Tickt auf dem Hauptthread und merkt sich die längste Lücke und die
    /// Summe aller Lücken über einem Bild (16,7 ms).
    @MainActor
    final class Heartbeat {
        private(set) var longest: Double = 0
        private(set) var hitches: Double = 0
        private var task: Task<Void, Never>?

        func start() {
            task = Task { @MainActor in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2))
                    let gap = ChatBenchmark.seconds(since: last) * 1_000
                    last = ContinuousClock.now
                    longest = max(longest, gap)
                    if gap > 16.7 { hitches += gap }
                }
            }
        }

        func stop() { task?.cancel() }
    }

    @Test func mainThreadStaysFree() async throws {
        let library = try await ChatBenchmark.makeLibrary()
        let store = library.store
        let episodes = library.episodes
        print("Bibliothek angelegt in \(String(format: "%.1f", library.seedSeconds)) s")

        // Lesen, wie es die Oberfläche tut: Folgenlisten, Belege, Fakten,
        // Transkript und der Bestand für „Für dich“.
        let reads = await MainActor.run { () -> Task<(Double, Double, Double), Never> in
            Task { @MainActor in
                let beat = Heartbeat()
                beat.start()
                let started = ContinuousClock.now
                do {
                    for source in Set(episodes.map(\.sourceID)) {
                        _ = try? await store.episodes(forSource: source)
                    }
                    for episode in episodes.prefix(60) {
                        _ = try? await store.evidence(forEpisode: episode.id)
                        _ = try? await store.facts(forEpisode: episode.id)
                        _ = try? await store.transcript(forEpisode: episode.id)
                    }
                    await store.forgetCachedEvidence()
                    _ = try? await store.evidenceForAnalyzedEpisodes()
                }
                let elapsed = ChatBenchmark.seconds(since: started) * 1_000
                try? await Task.sleep(for: .milliseconds(20))
                beat.stop()
                return (elapsed, beat.longest, beat.hitches)
            }
        }.value
        print(String(format: "Lesen aus der Oberfläche: %.0f ms, längste Lücke %.1f ms, Ruckler gesamt %.0f ms",
                     reads.0, reads.1, reads.2))

        // Ein Transkript wird gespeichert, wie am Ende eines Laufs, und die
        // Oberfläche fragt zugleich nach Folgen.
        let writes = await MainActor.run { () -> Task<(Double, Double, Double), Never> in
            Task { @MainActor in
                let beat = Heartbeat()
                beat.start()
                let writer = Task.detached {
                    for number in 0..<6 { try? await Self.saveTranscript(number, in: store) }
                }
                let started = ContinuousClock.now
                for episode in episodes.prefix(120) {
                    _ = try? await store.episodes(ids: [episode.id])
                }
                await writer.value
                let elapsed = ChatBenchmark.seconds(since: started) * 1_000
                try? await Task.sleep(for: .milliseconds(20))
                beat.stop()
                return (elapsed, beat.longest, beat.hitches)
            }
        }.value
        print(String(format: "Schreiben nebenher: %.0f ms, längste Lücke %.1f ms, Ruckler gesamt %.0f ms",
                     writes.0, writes.1, writes.2))
    }

    /// Ein Transkript mit 480 Sätzen und 120 Belegen, wie eine zweistündige Folge.
    static func saveTranscript(_ number: Int, in store: LibraryStore) async throws {
        let source = SourceID(stable: "quelle-0")
        let audio = URL(string: "https://example.com/neu-\(number).mp3")!
        let episodeID = EpisodeID(stable: "neu-\(number)")
        let media = MediaVersionID(stable: audio.absoluteString)
        _ = try await store.upsert(episodes: [Episode(
            id: episodeID, sourceID: source, title: "Neu \(number)",
            publishedAt: Date(), audioURL: audio)], forSource: source)
        var generator = ChatBenchmark.Generator(state: UInt64(number + 7))
        var segments: [TranscriptSegment] = []
        for index in 0..<480 {
            let start = Int64(index * 15_000)
            segments.append(TranscriptSegment(
                id: SegmentID(stable: "n-\(number)-\(index)"),
                range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                      end: MediaTime(milliseconds: start + 14_000)),
                text: ChatBenchmark.sentence(&generator, words: 38)))
        }
        let transcript = Transcript(
            id: TranscriptID(stable: "nt-\(number)"), mediaVersionID: media, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 480 * 15_000))))
        try await store.save(transcript: transcript,
                             media: MediaVersion(id: media, episodeID: episodeID, remoteURL: audio),
                             forEpisode: episodeID)
        let evidence = TranscriptAssembler().evidence(
            from: transcript, episodeID: episodeID, sourceID: source,
            ranges: PassageBuilder.passages(from: transcript))
        try await store.store(evidence: evidence)
    }
}

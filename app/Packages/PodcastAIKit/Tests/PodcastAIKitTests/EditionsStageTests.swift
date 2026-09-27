//
//  EditionsStageTests.swift
//  PodcastAIKitTests
//
//  Schritt 4 der Stufen-Pipeline (docs/plan-pipeline.md): Ausgaben, Zahlen
//  und Cover als Stufe.
//
//  - Eine neue Ausgabe wird je Zeile geschrieben. Der Wächter prüft jede
//    ihrer Folgen: Stellen aus einer gelöschten Folge fallen heraus, ohne
//    übrige Stelle wird nichts geschrieben, ohne Update auch nicht.
//  - Ändern und Löschen einer Ausgabe lassen die anderen Zeilen stehen.
//  - Die Stufe prüft die Automatik auf `feedsRefreshed` und
//    `transcriptsIdle`, hält in der Pause an und holt nach, nach „Alle
//    abbrechen“ nicht. `editionPublished` kommt erst nach dem Schreiben.
//  - Das Cover einer Ausgabe gehört zu ihrer Menge von Stellen
//    (Entscheidung 10) und entsteht über die Stelle für Apple Intelligence.
//

import Testing
import Foundation
import CoreGraphics
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAISmartFeeds

// MARK: - Bausteine

private let sourceID = SourceID(stable: "ausgaben-quelle")
private let kept = EpisodeID(stable: "ausgaben-bleibt")
private let gone = EpisodeID(stable: "ausgaben-geht")
private let feed = SmartPodcastFeed(id: SmartFeedID(rawValue: "ausgaben-feed"), title: "Datenschutz", topicIDs: [])

private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
    MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
}

private func episode(_ id: EpisodeID) -> Episode {
    Episode(id: id, sourceID: sourceID, title: id.rawValue,
            audioURL: URL(string: "https://example.com/\(id.rawValue).mp3")!)
}

private func makeStore(feeds: [SmartPodcastFeed] = [feed]) async throws -> LibraryStore {
    let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
    _ = try await store.upsert(episodes: [episode(kept), episode(gone)], forSource: sourceID)
    try await store.save(smartFeeds: feeds)
    return store
}

/// Eine Ausgabe mit einer Stelle je Folge, eine Minute lang.
private func edition(_ name: String, episodes: [EpisodeID] = [kept, gone],
                     feedID: SmartFeedID = feed.id) -> PersonalEpisode {
    var cursor: Int64 = 0
    let segments = episodes.enumerated().map { index, id in
        defer { cursor += 60_000 }
        return PersonalEpisodeSegment(
            id: SegmentID(rawValue: "\(name)-\(index)"), episodeID: id,
            mediaVersionID: MediaVersionID(rawValue: "m-\(id.rawValue)"), transcriptRevision: .initial,
            evidenceIDs: [EvidenceID(rawValue: "e-\(name)-\(index)")], coreRange: range(0, 60_000),
            playbackRange: range(0, 60_000), virtualRange: range(cursor, cursor + 60_000), reason: "",
            topicIDs: [], contextReplay: false, sourceID: sourceID, sourceTitle: "Quelle",
            episodeTitle: id.rawValue)
    }
    return PersonalEpisode(
        id: PersonalEpisodeID(rawValue: name), feedID: feedID, policyRevision: .initial,
        batchKey: name, title: name, segments: segments, shownotes: [],
        coverage: EditionCoverage(candidateCount: segments.count, includedCount: segments.count,
                                  remaining: .zero, partiallyAnalyzedSourceIDs: []))
}

/// Merkt sich, was die Stufe beim Hauptakteur aufruft.
private final class Recorder: Sendable {
    struct Published: Equatable, Sendable {
        let feedID: SmartFeedID
        let parts: [PersonalEpisodeID]
        let hadChapters: Bool
        let origin: Origin
        let covers: Bool
    }

    private let state = Mutex<(composed: [EditionRequest], published: [Published], statistics: Int, covers: Int)>(
        ([], [], 0, 0))

    var composed: [EditionRequest] { state.withLock { $0.composed } }
    var published: [Published] { state.withLock { $0.published } }
    var statistics: Int { state.withLock { $0.statistics } }
    var missingCovers: Int { state.withLock { $0.covers } }

    func compose(_ request: EditionRequest) { state.withLock { $0.composed.append(request) } }
    func publish(_ value: Published) { state.withLock { $0.published.append(value) } }
    func refreshed() { state.withLock { $0.statistics += 1 } }
    func coversRequested() { state.withLock { $0.covers += 1 } }
}

/// Eine Stufe mit Fakes: Das Zusammenstellen schreibt `parts` über den
/// Weg der Stufe, wenn es welche gibt, und wartet vorher auf `hold`.
private func makeStage(
    store: LibraryStore, gate: WorkGate, host: PipelineHost? = nil, ledger: RemovalLedger = RemovalLedger(),
    recorder: Recorder, due: [SmartFeedID] = [feed.id], parts: [PersonalEpisode] = [],
    hold: Duration? = nil
) -> EditionsStage {
    let environment = EditionsStage.Environment(
        dueFeeds: { due },
        compose: { request, committer in
            recorder.compose(request)
            if let hold { try? await Task.sleep(for: hold) }
            guard !parts.isEmpty, let written = try? await committer.commit(parts), !written.isEmpty else {
                return EditionComposition(note: "nichts")
            }
            return EditionComposition(note: "fertig", published: written, chapters: [])
        },
        published: { feedID, parts, chapters, origin, covers in
            recorder.publish(.init(feedID: feedID, parts: parts, hadChapters: chapters != nil,
                                   origin: origin, covers: covers))
        },
        refreshStatistics: { recorder.refreshed() },
        prepareMissingCovers: { recorder.coversRequested() })
    return EditionsStage(store: store, gate: gate, ledger: ledger, host: host, environment: environment)
}

/// Wartet, bis `condition` gilt, höchstens zwei Sekunden.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Schreiben je Zeile

@Suite("Stufe „Ausgaben“: je Zeile hinter dem Wächter")
struct EditionCommitTests {

    @Test("Eine Folge, die während des Zusammenstellens gelöscht wird, verliert ihre Stellen")
    func removedEpisodeLosesItsSegments() async throws {
        let store = try await makeStore()
        let ledger = RemovalLedger()
        let ticket = ledger.ticket
        ledger.markRemoved([gone])

        let result = try await store.commit(edition: edition("a"), since: ticket, ledger: ledger)
        guard case .written(let written, let dropped) = result else {
            Issue.record("nicht geschrieben: \(result)")
            return
        }
        #expect(dropped == [gone])
        #expect(written.segments.map(\.episodeID) == [kept])
        // Die übrige Stelle rückt nach vorn, wie beim späteren Löschen.
        #expect(written.segments.first?.virtualRange.start == .zero)
        #expect(try await store.editions(forFeed: feed.id).map(\.segments.count) == [1])
    }

    @Test("Ohne übrige Stelle oder ohne Update wird nichts geschrieben")
    func nothingLeftWritesNothing() async throws {
        let store = try await makeStore()
        let ledger = RemovalLedger()
        let ticket = ledger.ticket
        ledger.markRemoved([gone])

        let empty = try await store.commit(edition: edition("a", episodes: [gone]), since: ticket, ledger: ledger)
        #expect(empty == .nothingLeft(dropped: [gone]))
        let orphan = edition("b", episodes: [kept], feedID: SmartFeedID(rawValue: "gibt-es-nicht"))
        #expect(try await store.commit(edition: orphan, since: ticket, ledger: ledger) == .feedMissing)
        #expect(try await store.editions().isEmpty)
    }

    @Test("Eine Folge ohne lebende Zeile oder mit Merkzeichen zählt als gelöscht")
    func missingRowCountsAsRemoved() async throws {
        let store = try await makeStore()
        let ledger = RemovalLedger()
        _ = try await store.removeEpisode(gone)
        let unknown = EpisodeID(stable: "ausgaben-unbekannt")

        let result = try await store.commit(
            edition: edition("a", episodes: [kept, gone, unknown]), since: ledger.ticket, ledger: ledger)
        guard case .written(let written, let dropped) = result else {
            Issue.record("nicht geschrieben: \(result)")
            return
        }
        #expect(dropped == [gone, unknown])
        #expect(written.segments.map(\.episodeID) == [kept])
    }

    @Test("Ändern und Löschen einer Ausgabe lassen die anderen Zeilen stehen")
    func rowsStayIndependent() async throws {
        let store = try await makeStore()
        let ledger = RemovalLedger()
        let first = edition("a"), second = edition("b")
        _ = try await store.commit(edition: first, since: ledger.ticket, ledger: ledger)
        _ = try await store.commit(edition: second, since: ledger.ticket, ledger: ledger)

        let pruned = try #require(PersonalEpisodePublisher().removingSegments(from: first) { $0.episodeID == gone })
        try await store.replace(edition: pruned)
        try await store.removeEdition(second.id)
        let stored = try await store.editions(forFeed: feed.id)
        #expect(stored.map(\.id) == [first.id])
        #expect(stored.first?.segments.count == 1)

        // Eine gelöschte Ausgabe kommt über `replace` nicht zurück.
        try await store.replace(edition: second)
        #expect(try await store.editions(forFeed: feed.id).map(\.id) == [first.id])
    }
}

// MARK: - Die Stufe

@Suite("Stufe „Ausgaben“: Auslöser, Tor und Meldung")
struct EditionsStageTests {

    @Test("feedsRefreshed und transcriptsIdle prüfen die fälligen Updates, danach die Zahlen")
    func automaticOnTriggers() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let stage = makeStage(store: store, gate: WorkGate(alwaysInForeground: true), recorder: recorder)

        await stage.receive(.feedsRefreshed(byUser: false))
        #expect(await eventually { recorder.statistics == 1 })
        #expect(recorder.composed == [EditionRequest(feedID: feed.id, origin: .automatic)])

        await stage.receive(.transcriptsIdle)
        #expect(await eventually { recorder.statistics == 2 })
        #expect(recorder.composed.count == 2)

        // Andere Ereignisse stellen nichts zusammen, auch kein Abgleich.
        await stage.receive(.changedElsewhere(.all))
        await stage.receive(.episodesRemoved([gone], .episode))
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.composed.count == 2)
    }

    @Test("In der Pause wartet die Automatik und kommt danach, nach „Alle abbrechen“ nicht")
    func pauseHoldsAutomatic() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let gate = WorkGate(alwaysInForeground: true)
        let stage = makeStage(store: store, gate: gate, recorder: recorder)
        await stage.start()

        gate.setPaused(true)
        #expect(await eventually { !gate.mayRun(.editions, origin: .automatic) })
        await stage.receive(.feedsRefreshed(byUser: false))
        await stage.runAutomatic()
        #expect(recorder.composed.isEmpty)
        // Wer tippt, bekommt die Ausgabe auch in der Pause.
        #expect(gate.mayRun(.editions, origin: .user))

        gate.setPaused(false)
        #expect(await eventually { recorder.composed.count == 1 })

        gate.setCancelling(true)
        await stage.receive(.transcriptsIdle)
        gate.setCancelling(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.composed.count == 1)
        await stage.stop()
    }

    @Test("Die Pause bricht eine laufende automatische Ausgabe ab, ohne dass etwas erscheint")
    func pauseCancelsRunningAutomatic() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let gate = WorkGate(alwaysInForeground: true)
        let stage = makeStage(store: store, gate: gate, recorder: recorder,
                              parts: [edition("a")], hold: .milliseconds(300))
        await stage.start()

        await stage.receive(.feedsRefreshed(byUser: false))
        #expect(await eventually { recorder.composed.count == 1 })
        gate.setPaused(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await store.editions().isEmpty)
        #expect(recorder.published.isEmpty)
        await stage.stop()
    }

    @Test("editionPublished geht erst nach dem Schreiben hinaus und bringt Zahlen und Cover")
    func publishesAfterCommit() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let host = PipelineHost(gate: WorkGate(alwaysInForeground: true))
        let stage = makeStage(store: store, gate: host.gate, host: host, recorder: recorder, parts: [edition("a")])
        await stage.start()

        let note = await stage.build(EditionRequest(feedID: feed.id, origin: .user))
        #expect(note == "fertig")
        // Beim Senden steht die Ausgabe schon in der Datenbank.
        #expect(try await store.editions(forFeed: feed.id).map(\.id) == [PersonalEpisodeID(rawValue: "a")])
        #expect(await eventually { recorder.published.count == 1 })
        #expect(recorder.published.first == .init(
            feedID: feed.id, parts: [PersonalEpisodeID(rawValue: "a")], hadChapters: true, origin: .user,
            covers: true))
        await stage.stop()
    }

    @Test("Cover einer automatischen Ausgabe warten die Pause ab und kommen danach")
    func automaticCoversWaitForPause() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let gate = WorkGate(alwaysInForeground: true)
        let stage = makeStage(store: store, gate: gate, recorder: recorder)
        await stage.start()

        gate.setPaused(true)
        #expect(await eventually { !gate.mayRun(.editions, origin: .automatic) })
        #expect(await stage.mayPrepareAutomaticCovers() == false)
        gate.setPaused(false)
        #expect(await eventually { recorder.missingCovers == 1 })
        #expect(await stage.mayPrepareAutomaticCovers())
        await stage.stop()
    }

    @Test("Eine Folge, die während des Zusammenstellens gelöscht wird, kommt nicht in die Ausgabe")
    func removalDuringComposeReachesTheStage() async throws {
        let store = try await makeStore()
        let recorder = Recorder()
        let ledger = RemovalLedger()
        let stage = makeStage(store: store, gate: WorkGate(alwaysInForeground: true), ledger: ledger,
                              recorder: recorder, parts: [edition("a")], hold: .milliseconds(100))

        async let note = stage.build(EditionRequest(feedID: feed.id, origin: .user))
        #expect(await eventually { !recorder.composed.isEmpty })
        ledger.markRemoved([gone])
        #expect(await note == "fertig")
        let stored = try await store.editions(forFeed: feed.id)
        #expect(stored.flatMap(\.segments).map(\.episodeID) == [kept])
    }
}

// MARK: - Cover

/// Schreibt Art und Vorrang mit und führt nichts aus.
private final class CoverScheduler: AIScheduling {
    struct NotRun: Error {}
    private let calls = Mutex<[(AIWorkKind, AIWorkPriority)]>([])
    var recorded: [(AIWorkKind, AIWorkPriority)] { calls.withLock { $0 } }

    func run<T: Sendable>(
        _ kind: AIWorkKind, priority: AIWorkPriority, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        calls.withLock { $0.append((kind, priority)) }
        throw NotRun()
    }
}

@Suite("Stufe „Ausgaben“: Cover zu den Stellen")
struct EditionCoverKeyTests {

    private static func image() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("edition-cover-keys-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Verliert eine Ausgabe Stellen, passt ihr altes Bild nicht mehr, auch ohne Verwerfen")
    func keyFollowsTheSegments() throws {
        let full = edition("a")
        let pruned = try #require(PersonalEpisodePublisher().removingSegments(from: full) { $0.episodeID == gone })
        #expect(TopicCoverKey(edition: full) != TopicCoverKey(edition: pruned))
        #expect(TopicCoverKey(edition: full).owner == TopicCoverKey(edition: pruned).owner)
        // Die Reihenfolge zählt nicht, nur welche Stellen es sind.
        let reordered = PersonalEpisode(
            id: full.id, feedID: full.feedID, policyRevision: .initial, batchKey: full.batchKey,
            title: full.title, segments: full.segments.reversed(), shownotes: [], coverage: full.coverage)
        #expect(TopicCoverKey(edition: reordered) == TopicCoverKey(edition: full))

        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TopicCoverStore(directory: folder)
        let image = try #require(Self.image())
        try store.write(image, for: TopicCoverRecipe(edition: full, feed: feed, topics: ["Datenschutz"], names: []))
        #expect(store.stored(for: TopicCoverKey(edition: full)) != nil)
        #expect(store.stored(for: TopicCoverKey(edition: pruned)) == nil)

        // Der Abgleich behält nur das Bild zu den Stellen, die es noch gibt.
        store.removeEditionCovers(except: [TopicCoverKey(edition: pruned)])
        #expect(store.stored(for: TopicCoverKey(edition: full)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("Ein Bild aus der Zeit vor 0.13 wird übernommen, beim Lesen wie beim Abgleich")
    func legacyCoverIsAdopted() throws {
        let item = edition("a")
        let key = TopicCoverKey(edition: item)
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TopicCoverStore(directory: folder)
        let image = try #require(Self.image())

        // So hieß das Bild bisher: ohne Fingerabdruck der Stellen.
        func writeLegacy() throws {
            let written = try store.write(image, for: TopicCoverRecipe(
                edition: item, feed: feed, topics: ["Datenschutz"], names: []))
            let legacy = folder.appendingPathComponent(
                TopicCoverStore.prefix(for: key.owner) + written.digest + ".png")
            try FileManager.default.moveItem(at: written.url, to: legacy)
        }

        try writeLegacy()
        let adopted = try #require(store.stored(for: key))
        #expect(adopted.url.lastPathComponent.hasPrefix(TopicCoverStore.prefix(for: key)))
        #expect(adopted.matches(TopicCoverRecipe(edition: item, feed: feed, topics: ["Datenschutz"], names: [])))

        try FileManager.default.removeItem(at: adopted.url)
        try writeLegacy()
        store.removeEditionCovers(except: [key])
        #expect(store.stored(for: key) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

        // Löschen trifft die Ausgabe zu jeder Menge von Stellen.
        store.remove(key.owner)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("Das Bild wartet als .cover auf die Stelle, mit dem Vorrang des Aufrufers")
    func coverGoesThroughTheScheduler() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TopicCoverStore(directory: folder)
        let scheduler = CoverScheduler()
        let recipe = TopicCoverRecipe(edition: edition("a"), feed: feed, topics: ["Datenschutz"], names: [])

        await #expect(throws: CoverScheduler.NotRun.self) {
            _ = try await store.generate(for: recipe, scheduler: scheduler,
                                         priority: AIPriorityPolicy.priority(kind: .cover, origin: .automatic))
        }
        await #expect(throws: CoverScheduler.NotRun.self) {
            _ = try await store.generate(for: recipe, scheduler: scheduler,
                                         priority: AIPriorityPolicy.priority(kind: .cover, origin: .user))
        }
        #expect(scheduler.recorded.map(\.0) == [.cover, .cover])
        #expect(scheduler.recorded.map(\.1) == [.background, .user])
        #expect(store.stored(for: recipe.key) == nil)
    }
}

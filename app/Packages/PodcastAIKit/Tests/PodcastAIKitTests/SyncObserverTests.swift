//
//  SyncObserverTests.swift
//  PodcastAIKitTests
//
//  Abgleich über die Historie (Plan, Sync Phase 2): Was ein anderes Gerät
//  geändert hat, steht im `ChangeSet`, bereinigt wird nur das Betroffene,
//  und mehrere Meldungen werden ein Neuladen.
//
//  Ein zweiter Kontext mit fremdem Namen spielt das andere Gerät, wie der
//  Abgleich mit iCloud.
//

import Testing
import Foundation
import SwiftData
import Synchronization
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Abgleich über die Historie")
struct SyncObserverTests {

    let sourceID = SourceID(stable: "quelle-historie")
    let episodeID = EpisodeID(stable: "folge-historie")

    /// Ein Store in einer Datei, denn nur dort gibt es eine Historie.
    final class FileStore: Sendable {
        let directory: URL
        let container: ModelContainer
        let store: LibraryStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("historie-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try LibraryStore.makeContainer(at: directory.appendingPathComponent("Library.store"))
            store = LibraryStore.make(container: container)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Schreibt wie ein anderes Gerät.
        func foreign(_ change: (ModelContext) throws -> Void) throws {
            let other = ModelContext(container)
            other.author = "NSCloudKitMirroringDelegate.import"
            try change(other)
            try other.save()
        }
    }

    func foreignSource(_ context: ModelContext, addedAt: Date = Date()) -> StoredSource {
        let row = StoredSource(identifier: sourceID.rawValue, kind: .podcastRSS, title: "Fremd")
        row.addedAt = addedAt
        context.insert(row)
        return row
    }

    @Test("Die Historie nennt Art, Kennung, Folge und Quelle einer fremden Änderung")
    func foreignInsertIsNamed() async throws {
        let file = try FileStore()
        let store = file.store
        // Beim ersten Mal ist der Stand unbekannt: alles.
        #expect(await store.foreignChanges() == .all)
        try await store.upsert(source: Source(id: SourceID(stable: "eigen"), kind: .podcastRSS, title: "Eigen"))
        #expect(await store.foreignChanges() == nil, "Eigenes Speichern zählt nicht")

        try file.foreign { context in
            let source = foreignSource(context)
            let episode = StoredEpisode(identifier: episodeID.rawValue, title: "Folge")
            context.insert(episode)
            episode.source = source
        }
        let changes = try #require(await store.foreignChanges())
        #expect(!changes.isEverything)
        #expect(changes.touches(.source, .episode))
        #expect(!changes.touches(.listeningState, .fact, .smartFeed))
        #expect(changes.identifiers(of: .episode) == [episodeID.rawValue])
        #expect(changes.identifiers(of: .source) == [sourceID.rawValue])
        #expect(changes.episodeIDs == [episodeID])
        #expect(changes.sourceIDs == [sourceID])
        #expect(await store.foreignChanges() == nil, "Die Historie ist gelesen")
    }

    @Test("Eine fremde Löschung macht Folgen und Quellen unbekannt")
    func foreignDeleteIsUnknown() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge")],
                                   forSource: sourceID)
        #expect(await store.foreignChanges() == nil)

        try file.foreign { context in
            for row in try context.fetch(FetchDescriptor<StoredEpisode>()) { context.delete(row) }
        }
        let changes = try #require(await store.foreignChanges())
        #expect(changes.deletes(.episode))
        #expect(!changes.deletes(.source))
        #expect(changes.episodeIDs == nil)
        #expect(changes.sourceIDs == nil)
        #expect(changes.identifiers(of: .episode) == [], "Gelöschte Zeilen nennen keine Kennung")
    }

    @Test("Zwei Änderungen ergeben eine, alles bleibt alles")
    func changeSetsMerge() {
        let listening = ChangeSet(rows: [.listeningState: .init(updated: 1, identifiers: nil)])
        let episode = ChangeSet(rows: [.episode: .init(inserted: 1, identifiers: ["a"])],
                                episodeIDs: [EpisodeID(rawValue: "a")], sourceIDs: [sourceID])
        let merged = listening.union(episode)
        #expect(merged.touches(.listeningState))
        #expect(merged.touches(.episode))
        #expect(merged.identifiers(of: .episode) == ["a"])
        #expect(merged.episodeIDs == [EpisodeID(rawValue: "a")])
        #expect(merged.union(.all) == .all)
        #expect(ChangeSet.all.touches(.trail))
        #expect(ChangeSet.empty.isEmpty)
        #expect(ChangeSet(rows: [.fact: .init()]).isEmpty, "Leere Arten zählen nicht")
    }

    @Test("Die Pflege bereinigt nur, was das ChangeSet betrifft")
    func scopedDuplicateRemoval() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = await store.foreignChanges()
        // Das andere Gerät hat dieselbe Quelle angelegt, etwas später.
        try file.foreign { context in _ = foreignSource(context, addedAt: Date().addingTimeInterval(60)) }
        let changes = try #require(await store.foreignChanges())
        #expect(try await store.rowCountForTesting(StoredSource.self) == 2)

        // Ein Abgleich nur von Hörzuständen lässt die Quellen in Ruhe.
        let listening = ChangeSet(rows: [.listeningState: .init(updated: 3, identifiers: nil)])
        _ = try await store.removeDuplicatesWithReport(in: listening)
        #expect(try await store.rowCountForTesting(StoredSource.self) == 2)

        _ = try await store.removeDuplicatesWithReport(in: changes)
        #expect(try await store.rowCountForTesting(StoredSource.self) == 1)
        #expect(try await store.sources().first?.title == "Quelle", "Die ältere Zeile bleibt")
    }

    @Test("Eine gelöschte Kopie vom anderen Gerät löscht die Folge auch im beschränkten Bereinigen")
    func scopedRemovalHonoursTombstone() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge")],
                                   forSource: sourceID)
        _ = await store.foreignChanges()
        let sourceKey = sourceID.rawValue
        try file.foreign { context in
            let source = try #require(try context.fetch(FetchDescriptor<StoredSource>(
                predicate: #Predicate { $0.identifier == sourceKey })).first)
            let copy = StoredEpisode(identifier: episodeID.rawValue, title: "Folge")
            copy.removedAt = Date()
            context.insert(copy)
            copy.source = source
        }
        let changes = try #require(await store.foreignChanges())
        #expect(changes.identifiers(of: .episode) == [episodeID.rawValue])
        _ = try await store.removeDuplicatesWithReport(in: changes)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
    }

    @Test("Mehrere Meldungen werden ein Neuladen, bereinigt wird vorher")
    func observerMergesAndCleansFirst() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = await store.foreignChanges()

        let calls = Mutex<[(ChangeSet, Int)]>([])
        let observer = SyncObserver(
            quietPeriod: .milliseconds(300),
            store: { store },
            apply: { changes, _ in
                let sources = (try? await store.rowCountForTesting(StoredSource.self)) ?? -1
                calls.withLock { $0.append((changes, sources)) }
            })

        try file.foreign { context in _ = foreignSource(context, addedAt: Date().addingTimeInterval(60)) }
        await observer.remoteChangeArrived()
        try file.foreign { context in
            let trail = StoredKnowledgeTrail(identifier: "pfad", question: "Was?", parkedAt: Date(), payload: Data())
            context.insert(trail)
        }
        await observer.remoteChangeArrived()
        // Eine Meldung ohne fremde Änderung hält nichts auf.
        await observer.remoteChangeArrived()
        await observer.settle()

        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        let (changes, sourcesAtApply) = try #require(recorded.first)
        #expect(changes.touches(.source))
        #expect(changes.touches(.trail))
        #expect(!changes.touches(.episode))
        #expect(sourcesAtApply == 1, "Die Pflege hat vor dem Neuladen bereinigt")
    }

    @Test("Eine Meldung während des Neuladens bricht es nicht ab und kommt danach dran")
    func observerReloadsAgainAfterRunningReload() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        let calls = Mutex<[(ChangeSet, Bool)]>([])
        let started = AsyncStream<Void>.makeStream()
        let observer = SyncObserver(
            quietPeriod: .zero,
            store: { store },
            apply: { changes, _ in
                started.continuation.yield()
                // Ein langes Neuladen, das auf Abbruch achtet wie die Abgleiche.
                try? await Task.sleep(for: .milliseconds(300))
                calls.withLock { $0.append((changes, Task.isCancelled)) }
            })
        try file.foreign { context in _ = foreignSource(context) }
        await observer.remoteChangeArrived()
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        try file.foreign { context in
            context.insert(StoredKnowledgeTrail(identifier: "pfad", question: "Was?", parkedAt: Date(), payload: Data()))
        }
        await observer.remoteChangeArrived()
        await iterator.next()
        await observer.settle()

        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { !$0.1 }, "Kein Neuladen läuft abgebrochen")
        #expect(recorded.first?.0.touches(.source) == true)
        #expect(recorded.last?.0.touches(.trail) == true)
        #expect(recorded.last?.0.touches(.source) == false)
    }

    @Test("Ohne fremde Änderung lädt der Beobachter nichts")
    func observerIgnoresOwnSaves() async throws {
        let file = try FileStore()
        let store = file.store
        _ = await store.foreignChanges()
        let calls = Mutex(0)
        let observer = SyncObserver(quietPeriod: .zero, store: { store }, apply: { _, _ in
            calls.withLock { $0 += 1 }
        })
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        await observer.remoteChangeArrived()
        await observer.settle()
        #expect(calls.withLock { $0 } == 0)
    }
}

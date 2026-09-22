//
//  SyncMergeTests.swift
//
//  Was nach dem iCloud-Abgleich zweier Geräte mit Doppelten passiert, und
//  wie der Hörzustand gespeichert und wieder gelesen wird. Jeder Test hier
//  bildet einen Fehler nach, der Daten gekostet hat.
//

import Testing
import Foundation
import CoreData
import SwiftData
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Doppelte aus dem Abgleich zusammenführen")
struct DuplicateMergeTests {

    let sourceID = SourceID(stable: "quelle-abgleich")
    let episodeID = EpisodeID(stable: "folge-abgleich")
    let audio = URL(string: "https://example.com/abgleich.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }
    var source: Source { Source(id: sourceID, kind: .podcastRSS, title: "Quelle") }
    var episode: Episode { Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio) }

    func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    func transcript(for media: MediaVersionID, text: String = "Hallo Welt",
                    createdAt: Date = Date()) -> Transcript {
        let segmentRange = range(1_000, 9_000)
        return Transcript(
            id: TranscriptID(stable: "\(media.rawValue)|de_DE"), mediaVersionID: media,
            revision: .initial, origin: .speechAnalysis, locale: "de_DE",
            segments: [TranscriptSegment(
                id: TranscriptSegment.stableID(mediaVersionID: media, range: segmentRange),
                range: segmentRange, text: text)],
            analyzedRanges: IntervalSet(segmentRange), createdAt: createdAt)
    }

    func emptyStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    func counts(_ store: LibraryStore) async throws -> [Int] {
        [
            try await store.rowCountForTesting(StoredSource.self),
            try await store.rowCountForTesting(StoredEpisode.self),
            try await store.rowCountForTesting(StoredMediaVersion.self),
            try await store.rowCountForTesting(StoredTranscript.self),
            try await store.rowCountForTesting(StoredSegment.self),
        ]
    }

    // Die Kopie der Quelle, an der die erschlossene Folge hängt, kommt einmal
    // früher und einmal später an als die eigene. In beiden Fällen bleibt
    // eine Quelle, und Folge, Fassung, Transkript und Segment bleiben erhalten.
    @Test("Doppelte Quelle: die Folge mit Transkript wandert zur behaltenen Zeile",
          arguments: [-60.0, 60.0])
    func duplicateSourceKeepsAnalyzedEpisode(offset: TimeInterval) async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let copyAddedAt = Date().addingTimeInterval(offset)
        try await store.insertSourceCopyForTesting(source, addedAt: copyAddedAt)
        try await store.insertEpisodeCopyForTesting(
            episode, underSourceAddedAt: copyAddedAt,
            media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
            transcript: transcript(for: mediaID))
        #expect(try await counts(store) == [2, 1, 1, 1, 1])

        try await store.removeDuplicates()

        #expect(try await counts(store) == [1, 1, 1, 1, 1])
        #expect(try await store.sources().count == 1)
        #expect(try await store.episodes(forSource: sourceID).map(\.id) == [episodeID])
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.count == 1)
        // Behalten wird die früher angelegte Zeile, auf jedem Gerät dieselbe.
        let kept = try #require(try await store.sources().first)
        if offset < 0 {
            #expect(abs(kept.addedAt.timeIntervalSince(copyAddedAt)) < 0.001)
        } else {
            #expect(kept.addedAt < copyAddedAt)
        }
    }

    @Test("Doppelte Folge: Fassung, Transkript und Segmente der Kopie bleiben erhalten")
    func duplicateEpisodeKeepsMediaAndTranscript() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        // Die eigene Zeile, noch nicht erschlossen.
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        // Die Zeile des anderen Geräts, dort schon erschlossen.
        try await store.insertEpisodeCopyForTesting(
            episode,
            media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
            transcript: transcript(for: mediaID))
        #expect(try await counts(store) == [1, 2, 1, 1, 1])
        // Schon vor dem Bereinigen erscheint die Folge nur einmal.
        #expect(try await store.episodes(forSource: sourceID).count == 1)

        try await store.removeDuplicates()

        #expect(try await counts(store) == [1, 1, 1, 1, 1])
        let listed = try await store.episodes(forSource: sourceID)
        #expect(listed.map(\.id) == [episodeID])
        #expect(listed.first?.currentMediaVersionID == mediaID)
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.map(\.text) == ["Hallo Welt"])
    }

    // Beide Reihenfolgen: Welche Zeile bleibt, darf nicht davon abhängen,
    // welche die lokale Abfrage zuerst liefert.
    @Test("Doppelte Fassung: eine Kopie bleibt vollständig, und zwar auf jedem Gerät dieselbe",
          arguments: [true, false])
    func duplicateMediaKeepsTranscripts(olderFirst: Bool) async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let older = Date().addingTimeInterval(-600)
        // Zwei Geräte haben dieselbe Folge unabhängig erschlossen.
        let insertOlder = {
            try await store.insertEpisodeCopyForTesting(
                episode, media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
                acquiredAt: older, transcript: transcript(for: mediaID, text: "Älter", createdAt: older))
        }
        let insertNewer = {
            try await store.insertEpisodeCopyForTesting(
                episode, media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
                transcript: transcript(for: mediaID, text: "Neuer"))
        }
        if olderFirst {
            try await insertOlder()
            try await insertNewer()
        } else {
            try await insertNewer()
            try await insertOlder()
        }
        #expect(try await counts(store) == [1, 2, 2, 2, 2])

        try await store.removeDuplicates()

        #expect(try await counts(store) == [1, 1, 1, 1, 1])
        // Das Transkript mit dem früheren Zeitpunkt bleibt, auf jedem Gerät.
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.map(\.text) == ["Älter"])
    }

    @Test("Ein gelöschtes Merkzeichen setzt sich gegen eine lebende Kopie durch")
    func tombstoneSurvivesDedupe() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        // Gerät A hat die Folge gelöscht.
        try await store.insertEpisodeCopyForTesting(episode, removedAt: Date().addingTimeInterval(-3_600))
        // Gerät B hatte sie vorher schon angelegt und erschlossen.
        try await store.insertEpisodeCopyForTesting(
            episode, media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
            transcript: transcript(for: mediaID))
        try await store.record([LedgerEvent(
            mediaVersionID: mediaID, range: range(0, 60_000), kind: .played,
            via: .originalEpisode, deviceID: "b")])

        // Schon vor dem Bereinigen: gelöscht heisst gelöscht.
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        #expect(try await store.upsert(episodes: [episode], forSource: sourceID) == 0)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)

        let report = try await store.removeDuplicatesWithReport()

        #expect(report.mediaVersionIDs.contains(mediaID))
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        #expect(try await store.transcript(forEpisode: episodeID) == nil)
        #expect(try await store.rowCountForTesting(StoredMediaVersion.self) == 0)
        #expect(try await store.ledger().heard(in: mediaID).isEmpty)
        // Der Feed führt die Folge weiter. Sie kommt nicht zurück.
        #expect(try await store.upsert(episodes: [episode], forSource: sourceID) == 0)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        // Die Merkzeichen bleiben stehen, gelöscht wird keine der Kopien.
        #expect(try await store.rowCountForTesting(StoredEpisode.self) == 2)
    }

    @Test("Liegt die lebende Zeile vorn, bleibt die Folge trotzdem gelöscht")
    func upsertChecksEveryCopyForTombstone() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        try await store.insertEpisodeCopyForTesting(episode, removedAt: Date())

        let changed = Episode(id: episodeID, sourceID: sourceID, title: "Neuer Titel", audioURL: audio)
        #expect(try await store.upsert(episodes: [changed], forSource: sourceID) == 0)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        try await store.removeDuplicates()
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        #expect(try await store.episodes(ids: [episodeID]).allSatisfy { $0.title == "Folge" })
    }

    @Test("Zwei Hörzustände derselben Fassung werden vereinigt, keiner geht verloren")
    func listeningStatesAreMerged() async throws {
        let store = try emptyStore()
        let earlier = Date().addingTimeInterval(-600)
        let later = Date().addingTimeInterval(-60)
        try await store.insertListeningStateCopyForTesting(MediaListeningState(
            mediaVersionID: mediaID, heard: IntervalSet(range(0, 60_000)), skipped: IntervalSet(),
            lastEventAt: earlier, resumePosition: MediaTime(milliseconds: 60_000)))
        try await store.insertListeningStateCopyForTesting(MediaListeningState(
            mediaVersionID: mediaID, heard: IntervalSet(range(120_000, 180_000)), skipped: IntervalSet(),
            lastEventAt: later, resumePosition: MediaTime(milliseconds: 180_000)))

        #expect(try await store.ledger().state(for: mediaID).totalHeard.milliseconds == 120_000)
        try await store.removeDuplicates()

        let state = try await store.ledger().state(for: mediaID)
        #expect(state.heard.ranges == [range(0, 60_000), range(120_000, 180_000)])
        // Die Stelle kommt vom Gerät, das zuletzt gehört hat.
        #expect(state.resumePosition == MediaTime(milliseconds: 180_000))
        #expect(try await store.rowCountForTesting(StoredListeningState.self) == 2)
    }
}

@Suite("Hörzustand speichern und lesen")
struct ListeningPersistenceTests {

    let media = MediaVersionID(stable: "https://example.com/hoeren.mp3")

    func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    func emptyStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    // Die Ereignisse entstehen vor dem Schreiben, wie in der App auf dem
    // Main Actor. Früher blieb die Stelle nach dem ersten Abschnitt stehen.
    @Test("Die Fortsetzungsstelle wandert mit jedem gespeicherten Abschnitt")
    func resumeAdvancesAcrossChunks() async throws {
        let store = try emptyStore()
        let start = Date().addingTimeInterval(-60)
        for chunk in 0..<3 {
            let from = Int64(chunk) * 10_000
            try await store.record([LedgerEvent(
                mediaVersionID: media, range: range(from, from + 10_000), kind: .played,
                at: start.addingTimeInterval(Double(chunk) * 10), via: .originalEpisode, deviceID: "test")])
        }
        let state = try await store.ledger().state(for: media)
        #expect(state.heard.ranges == [range(0, 30_000)])
        #expect(state.resumePosition == MediaTime(milliseconds: 30_000))
    }

    @Test("Auch mit dem Standardzeitpunkt der Ereignisse wandert die Stelle")
    func resumeAdvancesWithDefaultTimestamps() async throws {
        let store = try emptyStore()
        let events = (0..<4).map { chunk in
            LedgerEvent(mediaVersionID: media, range: range(Int64(chunk) * 10_000, Int64(chunk + 1) * 10_000),
                        kind: .played, via: .originalEpisode, deviceID: "test")
        }
        for event in events { try await store.record([event]) }
        #expect(try await store.ledger().state(for: media).resumePosition == MediaTime(milliseconds: 40_000))
    }

    @Test("Gehörtes aus dem Chat-Fokus setzt keine Fortsetzungsstelle")
    func focusRouteDoesNotSetResume() async throws {
        let store = try emptyStore()
        try await store.record([LedgerEvent(
            mediaVersionID: media, range: range(2_100_000, 2_160_000), kind: .played,
            via: .chatFocus, deviceID: "test")])
        let state = try await store.ledger().state(for: media)
        #expect(!state.heard.isEmpty)
        #expect(state.resumePosition == nil)
    }

    @Test("Ein Fokus nach der Folge verschiebt die gespeicherte Stelle nicht")
    func focusAfterEpisodeKeepsResume() async throws {
        let store = try emptyStore()
        let now = Date()
        try await store.record([LedgerEvent(
            mediaVersionID: media, range: range(0, 10_000), kind: .played,
            at: now.addingTimeInterval(-20), via: .originalEpisode, deviceID: "test")])
        try await store.record([LedgerEvent(
            mediaVersionID: media, range: range(2_700_000, 2_760_000), kind: .played,
            at: now.addingTimeInterval(-10), via: .interestFocus, deviceID: "test")])
        #expect(try await store.ledger().state(for: media).resumePosition == MediaTime(milliseconds: 10_000))
    }

    @Test("Zusammenführen zweier Hörstände hängt nicht von der Reihenfolge ab")
    func mergedStateIsCommutative() {
        let older = Date().addingTimeInterval(-100)
        let newer = Date()
        let a = MediaListeningState(
            mediaVersionID: media, heard: IntervalSet(range(0, 10_000)),
            skipped: IntervalSet(range(50_000, 60_000)), lastEventAt: older,
            resumePosition: MediaTime(milliseconds: 10_000))
        let b = MediaListeningState(
            mediaVersionID: media, heard: IntervalSet(range(50_000, 55_000)),
            skipped: IntervalSet(), lastEventAt: newer,
            resumePosition: MediaTime(milliseconds: 55_000))
        #expect(a.merged(with: b) == b.merged(with: a))
        let merged = a.merged(with: b)
        #expect(merged.resumePosition == MediaTime(milliseconds: 55_000))
        #expect(merged.skipped.ranges == [range(55_000, 60_000)])
        #expect(merged.lastEventAt == newer)

        // Der Ledger fügt ebenso zusammen und macht die Enden gehörter
        // Bereiche nicht zur Fortsetzungsstelle.
        let left = ListeningLedger(states: [media: a])
        let right = ListeningLedger(states: [media: MediaListeningState(
            mediaVersionID: media, heard: IntervalSet(range(100_000, 200_000)),
            skipped: IntervalSet(), lastEventAt: newer, resumePosition: nil)])
        #expect(left.merged(with: right).state(for: media).resumePosition == MediaTime(milliseconds: 10_000))
    }
}

@Suite("Transkript einer Folge")
struct EpisodeTranscriptTests {

    @Test("Das Transkript der aktuellen Fassung hat Vorrang")
    func transcriptPrefersCurrentMediaVersion() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let sourceID = SourceID(stable: "quelle-fassung")
        let episodeID = EpisodeID(stable: "folge-fassung")
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(
            episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge",
                               audioURL: URL(string: "https://example.com/neu.mp3")!)],
            forSource: sourceID)

        // Zwei Adressen, die Kennungen sind Hashwerte. Aktuell wird die, deren
        // Kennung hinten sortiert, und ihr Transkript ist das ältere. So
        // besteht der Test weder zufällig über die Sortierung noch über das Alter.
        let urls = ["https://example.com/alt.mp3", "https://example.com/neu.mp3"].map { URL(string: $0)! }
        let ids = urls.map { MediaVersionID(stable: $0.absoluteString) }
        let (outdated, current) = ids[0].rawValue < ids[1].rawValue ? (0, 1) : (1, 0)

        func save(_ index: Int, text: String, createdAt: Date) async throws {
            let range = MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 5_000))
            let transcript = Transcript(
                id: TranscriptID(stable: "\(ids[index].rawValue)|de_DE"), mediaVersionID: ids[index],
                revision: .initial, origin: .speechAnalysis, locale: "de_DE",
                segments: [TranscriptSegment(
                    id: TranscriptSegment.stableID(mediaVersionID: ids[index], range: range),
                    range: range, text: text)],
                analyzedRanges: IntervalSet(range), createdAt: createdAt)
            try await store.save(
                transcript: transcript,
                media: MediaVersion(id: ids[index], episodeID: episodeID, remoteURL: urls[index]),
                forEpisode: episodeID)
        }
        try await save(outdated, text: "Überholt", createdAt: Date())
        try await save(current, text: "Aktuell", createdAt: Date().addingTimeInterval(-3_600))

        #expect(try await store.episodes(ids: [episodeID]).first?.currentMediaVersionID == ids[current])
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.map(\.text) == ["Aktuell"])
    }
}

@Suite("Speicher öffnen")
struct StoreOpeningTests {

    @Test("Nur Fehler der Umwandlung gelten als unpassender Speicher")
    func classifiesMigrationErrors() {
        let migration = NSError(domain: NSCocoaErrorDomain, code: 134110)
        let wrapped = NSError(domain: "SwiftData", code: 1,
                              userInfo: [NSUnderlyingErrorKey: migration])
        let hashMismatch = NSError(domain: NSCocoaErrorDomain, code: 134100)
        #expect(LibraryStore.isIncompatibleStoreError(migration))
        #expect(LibraryStore.isIncompatibleStoreError(wrapped))
        #expect(LibraryStore.isIncompatibleStoreError(hashMismatch))
        #expect(LibraryStore.isIncompatibleStoreError(SwiftDataError.backwardMigration))

        let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let openError = NSError(domain: NSCocoaErrorDomain, code: 134080)
        let sqlite = NSError(domain: NSCocoaErrorDomain, code: 134180)
        let cloudKit = NSError(domain: "CKErrorDomain", code: 9)
        for error in [noPermission, openError, sqlite, cloudKit] {
            #expect(!LibraryStore.isIncompatibleStoreError(error))
        }
        #expect(!LibraryStore.isIncompatibleStoreError(SwiftDataError.loadIssueModelContainer))
    }

    func temporaryStoreURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("default.store")
    }

    @Test("Ein passender Speicher wird bei anderen Fehlern nicht beiseitegelegt")
    func compatibleStoreStaysInPlace() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do { _ = try LibraryStore.makeContainer(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let transient = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(!LibraryStore.isIncompatibleStore(transient, at: url))
        #expect(throws: NSError.self) {
            try LibraryStore.openLocalContainer(at: url) { throw transient }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let moved = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains(".alt-") }
        #expect(moved.isEmpty)
    }

    @Test("Ein Speicher mit fremdem Modell wird erkannt und nur dann beiseitegelegt")
    func incompatibleStoreIsMovedAside() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Eine Datei mit einem Modell, das zu diesem nicht passt.
        let entity = NSEntityDescription()
        entity.name = "StoredSource"
        let attribute = NSAttributeDescription()
        attribute.name = "identifier"
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = true
        entity.properties = [attribute]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let opened = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
        try coordinator.remove(opened)

        let generic = SwiftDataError.loadIssueModelContainer
        #expect(LibraryStore.isIncompatibleStore(generic, at: url))

        var attempts = 0
        let result = try LibraryStore.openLocalContainer(at: url) {
            attempts += 1
            if attempts == 1 { throw generic }
            return try LibraryStore.makeContainer(at: url)
        }
        #expect(attempts == 2)
        #expect(result.recoveryNote != nil)
        let moved = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("default.store.alt-") }
        #expect(!moved.isEmpty)
    }
}

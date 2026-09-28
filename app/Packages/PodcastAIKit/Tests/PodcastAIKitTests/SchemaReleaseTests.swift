//
//  SchemaReleaseTests.swift
//  PodcastAIKitTests
//
//  Die Schemaänderung nach 0.14 (Entscheidung 11, docs/cloudkit-schema-0.15.md):
//
//  - Merkzeichen „Quelle abbestellt“ über zwei Speicher, wie zwei Geräte.
//  - `localRelativePath` wird nicht mehr geschrieben, Pfade liegen in
//    `DeviceState`, mit einmaligem Umzug.
//  - Eine feste Sprache in der Kennung des Transkripts.
//  - Die Sperre über Geräte hinweg: nehmen, übernehmen, ablaufen, freigeben.
//  - Die neuen Arten erscheinen in der Historie als eigene Änderung, nicht
//    als „alles neu“.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAITranscription

// MARK: - Bausteine

private let sourceID = SourceID(stable: "schema-quelle")
private let episodeID = EpisodeID(stable: "schema-folge")
private let audio = URL(string: "https://example.com/schema.mp3")!
private var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }

private func span(_ start: Int64, _ end: Int64) -> MediaTimeRange {
    MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
}

/// Ein Speicher in einer eigenen Datei, wie die Datenbank eines Geräts. Die
/// Historie braucht eine Datei.
private final class Device {
    let directory: URL
    let container: ModelContainer
    let store: LibraryStore

    init(_ name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try LibraryStore.makeContainer(at: directory.appendingPathComponent("Library.store"))
        store = LibraryStore.make(container: container)
    }

    /// Ein Kontext ohne den Namen des Stores, wie der Import aus iCloud.
    func cloudImport() -> ModelContext {
        let context = ModelContext(container)
        context.author = "NSCloudKitMirroringDelegate.import"
        return context
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Quelle, Folge, Transkript, Beleg und Fakt, wie nach einem Abgleich auf beiden Geräten.
private func seed(_ store: LibraryStore, locale: String = "de_DE") async throws {
    try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
    _ = try await store.upsert(
        episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)], forSource: sourceID)
    let range = span(1_000, 9_000)
    let transcript = TranscriptAssembler().finish(
        segments: [TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: mediaID, range: range),
                                     range: range, text: "Hallo Welt")],
        mediaVersionID: mediaID, locale: locale, origin: .speechAnalysis)
    try await store.save(transcript: transcript,
                         media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
                         forEpisode: episodeID)
    let evidenceID = Evidence.stableID(mediaVersionID: mediaID, transcriptRevision: .initial, range: range)
    try await store.store(evidence: [Evidence(
        id: evidenceID, mediaVersionID: mediaID, episodeID: episodeID, sourceID: sourceID,
        transcriptID: transcript.id, transcriptRevision: .initial, range: range, quotedText: "Hallo Welt")])
    try await store.save(facts: [EpisodeFact(
        id: "schema-f1", episodeID: episodeID, sourceID: sourceID, evidenceID: evidenceID,
        mediaVersionID: mediaID, statement: "Die Welt wird begrüßt.", range: range, modelTier: "test")],
        forEpisode: episodeID)
}

private func temporaryDeviceState() -> (DeviceState, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("schema-state-\(UUID().uuidString)", isDirectory: true)
    return (DeviceState(directory: directory), directory)
}

// MARK: - Quelle abbestellt

@Suite("Schema nach 0.14: Quelle abbestellt")
struct SourceRemovalTombstoneTests {

    @Test("Das Merkzeichen kommt auf das andere Gerät, das dieselbe Abbestellung nachholt und die Quelle nicht zurückbringt")
    func tombstoneTravelsToSecondStore() async throws {
        let iphone = try Device("iphone"), mac = try Device("mac")
        try await seed(iphone.store)
        try await seed(mac.store)
        _ = await mac.store.foreignChanges()

        // Auf dem iPhone abbestellt: Die Quelle geht, ein Merkzeichen bleibt.
        let report = try await iphone.store.removeSource(sourceID, device: "iphone")
        #expect(report.episodeIDs == [episodeID])
        let removals = try await iphone.store.sourceRemovals()
        #expect(removals.map(\.sourceID) == [sourceID])
        #expect(removals.first?.deviceID == "iphone")
        #expect(try await iphone.store.sources().isEmpty)
        // Ein zweiter Lauf, etwa nach einem Neustart mitten im Abbestellen,
        // schreibt kein zweites Merkzeichen.
        _ = try await iphone.store.removeSource(sourceID, device: "iphone")
        #expect(try await iphone.store.rowCountForTesting(StoredSourceRemoval.self) == 1)

        // Der Abgleich bringt nur das Merkzeichen auf den Mac, die Löschung
        // der Quelle noch nicht.
        let removedAt = try #require(removals.first?.removedAt)
        let context = mac.cloudImport()
        context.insert(StoredSourceRemoval(sourceIdentifier: sourceID.rawValue, removedAt: removedAt,
                                           deviceIdentifier: "iphone"))
        try context.save()
        let changes = try #require(await mac.store.foreignChanges())
        #expect(!changes.isEverything, "Eine neue Art erscheint als eigene Änderung")
        #expect(changes.touches(.sourceRemoval))
        #expect(changes.sourceIDs == [sourceID])

        // Bis der Mac nachgeholt hat, legt das Aktualisieren keine Folgen an.
        #expect(try await mac.store.sourceRemovalsToApply() == [sourceID])
        let refreshed = try await mac.store.upsertEpisodes(
            [Episode(id: EpisodeID(stable: "schema-neu"), sourceID: sourceID, title: "Neu")], forSource: sourceID)
        #expect(refreshed.isEmpty)

        // Derselbe Weg wie beim Abbestellen, ohne zweites Merkzeichen.
        let macReport = try await mac.store.removeSource(sourceID, recordingRemovalAt: nil)
        #expect(macReport.episodeIDs == [episodeID])
        #expect(!macReport.evidenceIDs.isEmpty)
        #expect(try await mac.store.sources().isEmpty)
        #expect(try await mac.store.transcript(forEpisode: episodeID) == nil)
        #expect(try await mac.store.facts(forEpisode: episodeID).isEmpty)
        #expect(try await mac.store.rowCountForTesting(StoredSourceRemoval.self) == 1)
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty, "Nachgeholt ist nachgeholt")

        // Ein Aktualisieren des Feeds bringt die Quelle nicht zurück.
        try await mac.store.updateFeedMetadata(of: Source(id: sourceID, kind: .podcastRSS, title: "Quelle neu"))
        #expect(try await mac.store.sources().isEmpty)
    }

    @Test("Kam die Löschung vor dem Merkzeichen, räumt das Merkzeichen die verwaisten Reste weg")
    func tombstoneAfterDeletionSweepsOrphans() async throws {
        let mac = try Device("mac")
        try await seed(mac.store)
        _ = await mac.store.foreignChanges()
        // Die Löschung der Quellzeile kommt zuerst. Die Folge verliert nur
        // ihre Quelle (`.nullify`), Transkript, Belege und Fakten bleiben.
        let context = mac.cloudImport()
        let key = sourceID.rawValue
        for row in try context.fetch(FetchDescriptor<StoredSource>(predicate: #Predicate { $0.identifier == key })) {
            context.delete(row)
        }
        try context.save()
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty, "Ohne Merkzeichen weiß niemand von der Abbestellung")
        #expect(try await mac.store.evidence(forEpisode: episodeID).count == 1)

        context.insert(StoredSourceRemoval(sourceIdentifier: key, removedAt: Date(), deviceIdentifier: "iphone"))
        try context.save()
        #expect(try await mac.store.sourceRemovalsToApply() == [sourceID])
        let report = try await mac.store.removeSource(sourceID, recordingRemovalAt: nil)
        #expect(report.episodeIDs == [episodeID])
        #expect(try await mac.store.evidence(forEpisode: episodeID).isEmpty)
        #expect(try await mac.store.facts(forEpisode: episodeID).isEmpty)
        #expect(try await mac.store.rowCountForTesting(StoredEpisode.self) == 0)
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty)
    }

    @Test("Ein neues Abo hebt das Merkzeichen auf, ein älteres Merkzeichen trifft es nicht")
    func resubscribeClearsTombstone() async throws {
        let mac = try Device("mac")
        try await seed(mac.store)
        let context = mac.cloudImport()
        context.insert(StoredSourceRemoval(sourceIdentifier: sourceID.rawValue, removedAt: Date(),
                                           deviceIdentifier: "iphone"))
        try context.save()
        #expect(try await mac.store.sourceRemovalsToApply() == [sourceID])

        // Jemand abonniert den Podcast auf dem Mac neu, bevor nachgeholt ist.
        try await mac.store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        #expect(try await mac.store.sourceRemovals().isEmpty)
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty)
        #expect(try await mac.store.sources().map(\.id) == [sourceID])

        // Ein Merkzeichen von vor dem neuen Abo kommt verspätet an: Es gilt nicht.
        context.insert(StoredSourceRemoval(sourceIdentifier: sourceID.rawValue,
                                           removedAt: Date().addingTimeInterval(-3_600), deviceIdentifier: "ipad"))
        try context.save()
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty)
        // Das Bereinigen räumt es als erledigt weg.
        try await mac.store.removeDuplicates()
        #expect(try await mac.store.sourceRemovals().isEmpty)
    }
}

extension SourceRemovalTombstoneTests {

    @Test("Abonniert eine ältere App neu, gewinnt das neue Abo beim Zusammenführen doppelter Quellzeilen")
    func resubscriptionFromOlderAppSurvivesMerge() async throws {
        let mac = try Device("mac")
        try await seed(mac.store)
        let removedAt = Date()
        try await mac.store.insertSourceRemovalForTesting(sourceID, at: removedAt, device: "iphone")
        // Eine ältere App auf dem iPad hat den Podcast danach wieder
        // abonniert, ohne das Merkzeichen zu kennen: eine zweite, neuere Zeile.
        try await mac.store.insertSourceCopyForTesting(
            Source(id: sourceID, kind: .podcastRSS, title: "Quelle"), addedAt: removedAt.addingTimeInterval(60))
        try await mac.store.removeDuplicates()
        #expect(try await mac.store.rowCountForTesting(StoredSource.self) == 1)
        #expect(try await mac.store.sourceRemovalsToApply().isEmpty, "Das neue Abo bleibt")
        #expect(try await mac.store.sources().map(\.id) == [sourceID])
    }
}

// MARK: - localRelativePath

@Suite("Schema nach 0.14: Pfade der Audiodateien je Gerät")
struct LocalMediaPathTests {

    @Test("Die App schreibt `localRelativePath` nicht mehr, der Pfad liegt in DeviceState")
    func pathGoesToDeviceState() async throws {
        let (state, directory) = temporaryDeviceState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        await store.useLocalMediaPaths(LocalMediaPaths(state: state))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(
            episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)], forSource: sourceID)
        let range = span(0, 4_000)
        let transcript = TranscriptAssembler().finish(
            segments: [TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: mediaID, range: range),
                                         range: range, text: "Satz")],
            mediaVersionID: mediaID, locale: "de_DE", origin: .speechAnalysis)
        try await store.save(transcript: transcript,
                             media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio,
                                                 localRelativePath: mediaID.rawValue),
                             forEpisode: episodeID)
        #expect(try await store.legacyLocalRelativePaths().isEmpty, "Das Feld in der Datenbank bleibt leer")
        #expect(LocalMediaPaths(state: state).path(for: mediaID) == mediaID.rawValue)

        // „Audio entfernen“ vergisst den Pfad und lässt die Datenbank stehen.
        try await store.markAudioRemoved([mediaID])
        #expect(LocalMediaPaths(state: state).path(for: mediaID) == nil)
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.count == 1)
    }

    @Test("Beim ersten Start ziehen die alten Pfade um, nur mit Datei auf diesem Gerät, und das Feld bleibt")
    func migrationMovesExistingFilesOnly() async throws {
        let (state, directory) = temporaryDeviceState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        // Wie von 0.14 geschrieben: zwei Fassungen mit Pfad, eine davon von
        // einem anderen Gerät, dessen Datei hier nicht liegt.
        let here = MediaVersionID(stable: "https://example.com/hier.mp3")
        let there = MediaVersionID(stable: "https://example.com/dort.mp3")
        let context = ModelContext(store.modelContainer)
        for id in [here, there] {
            let row = StoredMediaVersion(identifier: id.rawValue)
            row.localRelativePath = id.rawValue
            context.insert(row)
        }
        try context.save()

        let paths = LocalMediaPaths(state: state)
        let herePath = here.rawValue
        #expect(await paths.migrate(from: store) { $0 == herePath })
        #expect(paths.path(for: here) == here.rawValue)
        #expect(paths.path(for: there) == nil)
        // Ein zweiter Start zieht nichts mehr um.
        #expect(await paths.migrate(from: store) { _ in true } == false)
        #expect(paths.path(for: there) == nil)
        // Das alte Feld ist unberührt: auch Leeren wäre ein Schreiben an alle Geräte.
        #expect(try await store.legacyLocalRelativePaths().count == 2)
        // Nach einem Neustart liest DeviceState dasselbe von der Platte.
        state.flush()
        let reread = LocalMediaPaths(state: DeviceState(directory: directory))
        #expect(reread.path(for: here) == here.rawValue)
    }

    @Test("Folge löschen vergisst die Pfade ihrer Fassungen (Regel 5)")
    func removalForgetsPaths() async throws {
        let (state, directory) = temporaryDeviceState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        await store.useLocalMediaPaths(LocalMediaPaths(state: state))
        try await seed(store)
        LocalMediaPaths(state: state).record(mediaID.rawValue, for: mediaID)
        _ = try await store.removeEpisode(episodeID)
        #expect(LocalMediaPaths(state: state).path(for: mediaID) == nil)
    }
}

// MARK: - Feste Sprache in der Kennung des Transkripts

@Suite("Schema nach 0.14: Kennung des Transkripts")
struct StableTranscriptIDTests {

    @Test("Zwei Geräte mit verschiedener Systemsprache bilden dieselbe Kennung", arguments: ["en_US", "fr_FR", "ja_JP"])
    func sameIDAcrossLocales(_ other: String) {
        let range = span(0, 2_000)
        let segments = [TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: mediaID, range: range),
                                          range: range, text: "Satz")]
        let german = TranscriptAssembler().finish(segments: segments, mediaVersionID: mediaID, locale: "de_DE",
                                                  origin: .speechAnalysis)
        let foreign = TranscriptAssembler().finish(segments: segments, mediaVersionID: mediaID, locale: other,
                                                   origin: .speechAnalysis)
        #expect(german.id == foreign.id)
        #expect(german.id == TranscriptID.forMedia(mediaID))
        // Die echte Sprache bleibt im Transkript.
        #expect(german.locale == "de_DE" && foreign.locale == other)
        // Neu ist nicht alt: Die frühere Kennung trug die Sprache.
        #expect(german.id != TranscriptID.legacy(media: mediaID, locale: "de_DE"))
    }

    @Test("Zwei Geräte transkribieren dieselbe Fassung: Das Bereinigen behält eines")
    func duplicatesFromTwoLocalesMerge() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await seed(store, locale: "de_DE")
        // Das Mac mit englischer Systemsprache hat dieselbe Folge transkribiert.
        let range = span(1_000, 9_000)
        let english = TranscriptAssembler().finish(
            segments: [TranscriptSegment(id: SegmentID(stable: "mac"), range: range, text: "Hello world")],
            mediaVersionID: mediaID, locale: "en_US", origin: .speechAnalysis)
        let context = ModelContext(store.modelContainer)
        let row = StoredTranscript(identifier: english.id.rawValue)
        row.locale = "en_US"
        context.insert(row)
        try context.save()
        #expect(try await store.rowCountForTesting(StoredTranscript.self) == 2)
        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredTranscript.self) == 1)
        #expect(try await store.transcript(forMedia: mediaID)?.segments.first?.text == "Hallo Welt")
    }

    @Test("Ein Transkript mit alter Kennung wird weiter gefunden, die Vorprüfung bleibt über die Fassung")
    func legacyTranscriptStillFound() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(
            episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)], forSource: sourceID)
        let range = span(0, 3_000)
        let legacy = Transcript(
            id: TranscriptID.legacy(media: mediaID, locale: "de_DE"), mediaVersionID: mediaID, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE",
            segments: [TranscriptSegment(id: SegmentID(stable: "alt"), range: range, text: "Alt")],
            analyzedRanges: IntervalSet(range))
        try await store.save(transcript: legacy, media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio),
                             forEpisode: episodeID)
        #expect(try await store.transcript(forMedia: mediaID)?.id == legacy.id)
        #expect(try await store.mediaVersionsWithTranscript([mediaID]) == [mediaID])
    }

    @Test("Ein verwaistes Transkript mit fester Kennung findet seine Fassung wieder und geht beim Löschen mit")
    func orphanWithFixedIDReattachesAndPurges() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await seed(store, locale: "en_US")
        let id = TranscriptID.forMedia(mediaID)
        try await store.detachTranscriptForTesting(id)
        #expect(try await store.transcript(forMedia: mediaID) == nil)
        try await store.removeDuplicates()
        #expect(try await store.transcript(forMedia: mediaID)?.id == id)

        try await store.detachTranscriptForTesting(id)
        _ = try await store.removeEpisode(episodeID)
        #expect(try await store.rowCountForTesting(StoredTranscript.self) == 0)
    }
}

// MARK: - Sperre über Geräte hinweg

@Suite("Schema nach 0.14: Sperre über Geräte hinweg")
struct ProcessingLeaseTests {

    private func store() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(
            episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)], forSource: sourceID)
        return store
    }

    @Test("Eine gültige fremde Sperre hält, eine abgelaufene übernimmt dieses Gerät mit frischem Zeitpunkt")
    func heldThenTakenOverAfterExpiry() async throws {
        let store = try await store()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(try await store.acquireLease(.transcript, for: episodeID, device: "ipad", duration: 600, now: start)
                == .granted(until: start.addingTimeInterval(600)))
        // Fünf Minuten später: Das iPhone muss warten.
        let later = start.addingTimeInterval(300)
        #expect(try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600, now: later)
                == .heldElsewhere(device: "ipad", until: start.addingTimeInterval(600)))
        // Die Sperre für Fakten ist eine andere.
        #expect(try await store.acquireLease(.knowledge, for: episodeID, device: "iphone", duration: 600, now: later)
                == .granted(until: later.addingTimeInterval(600)))

        // Nach dem Ablauf übernimmt das iPhone.
        let expired = start.addingTimeInterval(601)
        #expect(try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600, now: expired)
                == .granted(until: expired.addingTimeInterval(600)))
        let transcriptLeases = try await store.leases(for: episodeID).filter { $0.kind == .transcript }
        #expect(transcriptLeases.map(\.deviceID) == ["iphone"])
        #expect(transcriptLeases.first?.acquiredAt == expired, "Übernommen heißt frisch genommen")

        // Das iPad verlängert zu spät: Es hält die Sperre nicht mehr.
        #expect(try await store.renewLease(.transcript, for: episodeID, device: "ipad", duration: 600,
                                           now: expired.addingTimeInterval(1)) == false)
        #expect(try await store.acquireLease(.transcript, for: episodeID, device: "ipad", duration: 600,
                                             now: expired.addingTimeInterval(2))
                == .heldElsewhere(device: "iphone", until: expired.addingTimeInterval(600)))
    }

    @Test("Verlängern hält die Sperre über ihren Ablauf hinaus, Freigeben gibt sie sofort frei")
    func renewAndRelease() async throws {
        let store = try await store()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await store.acquireLease(.knowledge, for: episodeID, device: "mac", duration: 60, now: start)
        #expect(try await store.renewLease(.knowledge, for: episodeID, device: "mac", duration: 60,
                                           now: start.addingTimeInterval(50)))
        // Ohne das Verlängern wäre sie jetzt abgelaufen.
        #expect(try await store.acquireLease(.knowledge, for: episodeID, device: "iphone", duration: 60,
                                             now: start.addingTimeInterval(80))
                == .heldElsewhere(device: "mac", until: start.addingTimeInterval(110)))
        try await store.releaseLease(.knowledge, for: episodeID, device: "mac")
        #expect(try await store.acquireLease(.knowledge, for: episodeID, device: "iphone", duration: 60,
                                             now: start.addingTimeInterval(81))
                == .granted(until: start.addingTimeInterval(141)))
    }

    @Test("Nehmen zwei Geräte fast gleichzeitig, gilt auf beiden die ältere, und die jüngere geht")
    func concurrentAcquisitionResolvesDeterministically() async throws {
        let store = try await store()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600,
                                         now: start.addingTimeInterval(2))
        // Die Sperre des Macs kam über iCloud, genommen zwei Sekunden früher.
        try await store.insertLeaseForTesting(.transcript, for: episodeID, device: "mac", acquiredAt: start,
                                              expiresAt: start.addingTimeInterval(600))
        #expect(try await store.renewLease(.transcript, for: episodeID, device: "iphone", duration: 600,
                                           now: start.addingTimeInterval(3)) == false)
        #expect(try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600,
                                             now: start.addingTimeInterval(3))
                == .heldElsewhere(device: "mac", until: start.addingTimeInterval(600)))
        #expect(try await store.leases(for: episodeID).map(\.deviceID) == ["mac"], "Die eigene Zeile ist weg")
    }

    @Test("Für eine gelöschte Folge entsteht keine Sperre, und Löschen nimmt vorhandene mit (Regel 5)")
    func removedEpisodesHoldNoLease() async throws {
        let store = try await store()
        _ = try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600)
        #expect(try await store.leases(for: episodeID).count == 1)
        _ = try await store.removeEpisode(episodeID)
        #expect(try await store.leases(for: episodeID).isEmpty)
        _ = try await store.acquireLease(.transcript, for: episodeID, device: "iphone", duration: 600)
        #expect(try await store.leases(for: episodeID).isEmpty)
        #expect(try await store.renewLease(.transcript, for: episodeID, device: "iphone", duration: 600) == false)
    }

    @Test("Sperren abgestürzter Geräte gehen beim Start nach einem Tag")
    func staleLeasesAreSwept() async throws {
        let store = try await store()
        let old = Date().addingTimeInterval(-3 * 24 * 3_600)
        try await store.insertLeaseForTesting(.transcript, for: episodeID, device: "alt", acquiredAt: old,
                                              expiresAt: old.addingTimeInterval(600))
        try await store.removeDuplicates()
        #expect(try await store.leases(for: episodeID).isEmpty)
    }
}

// MARK: - Neue Arten in der Historie

@Suite("Schema nach 0.14: neue Arten in der Historie")
struct SchemaChangeSetTests {

    @Test("Sperren und Unterhaltungen von woanders laden nicht alles neu und nennen keine Folgen")
    func leaseAndConversationAreOwnEntities() async throws {
        let device = try Device("historie")
        try await seed(device.store)
        _ = await device.store.foreignChanges()
        let context = device.cloudImport()
        context.insert(StoredProcessingLease(
            identifier: "\(episodeID.rawValue)|transcript", episodeIdentifier: episodeID.rawValue,
            kindRaw: "transcript", deviceIdentifier: "ipad", acquiredAt: Date(), expiresAt: Date().addingTimeInterval(60)))
        context.insert(StoredChatConversation(
            identifier: UUID().uuidString, scopeKey: "library", title: "Frage", createdAt: Date(), updatedAt: Date(),
            turnCount: 1, formatVersion: 1, payload: Data()))
        try context.save()
        let changes = try #require(await device.store.foreignChanges())
        #expect(!changes.isEverything)
        #expect(changes.touches(.lease) && changes.touches(.conversation))
        #expect(!changes.touches(.episode, .source, .transcript, .evidence))
        #expect(changes.episodeIDs == [], "Eine Sperre sagt nichts über neu zu ladende Folgen")
    }

    @Test("Das Schema kennt die neuen Arten, jedes Feld mit Standardwert")
    func schemaContainsNewModels() {
        let names = Set(LibraryStore.schema.entities.map(\.name))
        for type in [Schema.entityName(for: StoredChatConversation.self),
                     Schema.entityName(for: StoredSourceRemoval.self),
                     Schema.entityName(for: StoredProcessingLease.self)] {
            #expect(names.contains(type))
        }
        // CloudKit: keine eindeutigen Attribute in irgendeinem Modell.
        for entity in LibraryStore.schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) trägt eine Eindeutigkeit")
        }
    }
}

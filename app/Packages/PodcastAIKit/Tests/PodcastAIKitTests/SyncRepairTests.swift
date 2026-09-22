//
//  SyncRepairTests.swift
//
//  Fehler aus der zweiten Prüfung der Persistenz: Doppelte nach dem
//  iCloud-Abgleich, Zeilen, die ihre Eltern verloren haben, und der
//  Hörzustand, den zwei Geräte gleichzeitig schreiben.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Abgleich: Listen, Transkripte und verwaiste Zeilen")
struct SyncRepairTests {

    let sourceID = SourceID(stable: "quelle-reparatur")
    let audio = URL(string: "https://example.com/reparatur.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }
    var source: Source { Source(id: sourceID, kind: .podcastRSS, title: "Quelle") }

    func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    func emptyStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    /// Ein Transkript mit den Segmentgrenzen, die ein Gerät gefunden hat.
    func transcript(_ pieces: [(Int64, Int64, String)], createdAt: Date) -> Transcript {
        let segments = pieces.map { start, end, text in
            TranscriptSegment(
                id: TranscriptSegment.stableID(mediaVersionID: mediaID, range: range(start, end)),
                range: range(start, end), text: text)
        }
        return Transcript(
            id: TranscriptID(stable: "\(mediaID.rawValue)|de_DE"), mediaVersionID: mediaID,
            revision: .initial, origin: .speechAnalysis, locale: "de_DE",
            segments: segments, analyzedRanges: IntervalSet(segments.map(\.range)),
            createdAt: createdAt)
    }

    // Beide Geräte haben den Feed abonniert, bevor sie sich abgeglichen
    // haben. Jede Folge liegt danach zweimal vor, und die Kopien lassen
    // sich nicht ordnen, weil keine erschlossen ist.
    @Test("Die Grenze zählt Folgen, nicht Zeilen")
    func limitCountsDistinctEpisodes() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let now = Date()
        let list = (0..<3).map { index in
            Episode(id: EpisodeID(stable: "folge-\(index)"), sourceID: sourceID, title: "Folge \(index)",
                    publishedAt: now.addingTimeInterval(Double(-index) * 3_600))
        }
        _ = try await store.upsert(episodes: list, forSource: sourceID)
        for episode in list { try await store.insertEpisodeCopyForTesting(episode) }
        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredEpisode.self) == 6)

        #expect(try await store.episodes(forSource: sourceID, limit: 3).map(\.id) == list.map(\.id))
        #expect(try await store.episodes(forSource: sourceID, limit: 2).map(\.id) == list.prefix(2).map(\.id))
        #expect(try await store.episodes(forSource: sourceID).count == 3)
    }

    // Zwei Geräte haben dieselbe Folge unabhängig transkribiert. Die
    // Segmentgrenzen weichen leicht ab, also auch die Kennungen der Segmente.
    @Test("Doppeltes Transkript: eine Transkription bleibt ganz, nichts steht doppelt",
          arguments: [true, false])
    func duplicateTranscriptKeepsOneTranscription(olderFirst: Bool) async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let episode = Episode(id: EpisodeID(stable: "folge-transkript"), sourceID: sourceID,
                              title: "Folge", audioURL: audio)
        let older = Date().addingTimeInterval(-600)
        let media = MediaVersion(id: mediaID, episodeID: episode.id, remoteURL: audio)
        let insertOlder = {
            try await store.insertEpisodeCopyForTesting(
                episode, media: media, acquiredAt: older,
                transcript: transcript([(0, 5_000, "Hallo"), (5_000, 9_000, "Welt")], createdAt: older))
        }
        let insertNewer = {
            try await store.insertEpisodeCopyForTesting(
                episode, media: media,
                transcript: transcript([(0, 4_900, "Hallo neu"), (4_900, 9_200, "Welt neu")], createdAt: Date()))
        }
        if olderFirst {
            try await insertOlder(); try await insertNewer()
        } else {
            try await insertNewer(); try await insertOlder()
        }
        #expect(try await store.rowCountForTesting(StoredSegment.self) == 4)

        try await store.removeDuplicates()

        #expect(try await store.rowCountForTesting(StoredTranscript.self) == 1)
        #expect(try await store.rowCountForTesting(StoredSegment.self) == 2)
        let kept = try #require(try await store.transcript(forEpisode: episode.id))
        #expect(kept.segments.map(\.text) == ["Hallo", "Welt"])
        // Die Abdeckung gehört zur behaltenen Transkription, nicht zur Vereinigung.
        #expect(kept.analyzedRanges.ranges == [range(0, 9_000)])
    }

    // Die Folge des anderen Geräts hing an einer doppelten Quellzeile, die
    // dort beim Bereinigen gelöscht wurde. Hier kommt sie ohne Quelle an.
    @Test("Eine Folge ohne Quelle findet über ihre Geschwister zurück")
    func orphanedEpisodeRejoinsItsSource() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let episode = Episode(id: EpisodeID(stable: "folge-waise"), sourceID: sourceID,
                              title: "Folge", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        try await store.insertEpisodeCopyForTesting(
            episode, media: MediaVersion(id: mediaID, episodeID: episode.id, remoteURL: audio),
            transcript: transcript([(0, 5_000, "Hallo")], createdAt: Date()), withoutSource: true)

        try await store.removeDuplicates()

        #expect(try await store.rowCountForTesting(StoredEpisode.self) == 1)
        let listed = try await store.episodes(forSource: sourceID)
        #expect(listed.map(\.id) == [episode.id])
        #expect(listed.first?.currentMediaVersionID == mediaID)
        #expect(try await store.episodes(ids: [episode.id]).first?.sourceID == sourceID)
    }

    @Test("Eine Folge ohne Geschwister findet über ihre Belege zurück")
    func orphanedEpisodeRejoinsThroughEvidence() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let episode = Episode(id: EpisodeID(stable: "folge-beleg"), sourceID: sourceID,
                              title: "Folge", audioURL: audio)
        try await store.insertEpisodeCopyForTesting(episode, withoutSource: true)
        try await store.store(evidence: [Evidence(
            id: EvidenceID(stable: "beleg-waise"), mediaVersionID: mediaID, episodeID: episode.id,
            sourceID: sourceID, transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
            range: range(0, 5_000), quotedText: "Hallo")])
        #expect(try await store.episodes(forSource: sourceID).isEmpty)

        try await store.removeDuplicates()

        #expect(try await store.episodes(forSource: sourceID).map(\.id) == [episode.id])
    }

    @Test("Ein gelöschtes Merkzeichen ohne Quelle wirkt wieder")
    func orphanedTombstoneStillHidesEpisode() async throws {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let episode = Episode(id: EpisodeID(stable: "folge-merkzeichen"), sourceID: sourceID,
                              title: "Folge", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        try await store.insertEpisodeCopyForTesting(episode, removedAt: Date(), withoutSource: true)

        try await store.removeDuplicates()

        #expect(try await store.episodes(forSource: sourceID).isEmpty)
        #expect(try await store.upsert(episodes: [episode], forSource: sourceID) == 0)
    }

    func storeWithTranscript() async throws -> (LibraryStore, EpisodeID, TranscriptID) {
        let store = try emptyStore()
        try await store.upsert(source: source)
        let episode = Episode(id: EpisodeID(stable: "folge-fassung"), sourceID: sourceID,
                              title: "Folge", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)
        let saved = transcript([(0, 5_000, "Hallo"), (5_000, 9_000, "Welt")], createdAt: Date())
        try await store.save(
            transcript: saved, media: MediaVersion(id: mediaID, episodeID: episode.id, remoteURL: audio),
            forEpisode: episode.id)
        return (store, episode.id, saved.id)
    }

    @Test("Ein Transkript ohne Fassung wird wieder angehängt")
    func orphanedTranscriptIsReattached() async throws {
        let (store, episodeID, transcriptID) = try await storeWithTranscript()
        try await store.detachTranscriptForTesting(transcriptID)
        #expect(try await store.transcript(forEpisode: episodeID) == nil)

        try await store.removeDuplicates()

        #expect(try await store.transcript(forEpisode: episodeID)?.segments.map(\.text) == ["Hallo", "Welt"])
    }

    @Test("Ein Transkript ohne Fassung geht mit seiner Folge")
    func orphanedTranscriptIsPurged() async throws {
        let (store, episodeID, transcriptID) = try await storeWithTranscript()
        try await store.detachTranscriptForTesting(transcriptID)

        _ = try await store.removeEpisode(episodeID)

        #expect(try await store.rowCountForTesting(StoredTranscript.self) == 0)
        #expect(try await store.rowCountForTesting(StoredSegment.self) == 0)
    }

    @Test("Die Kennung eines Transkripts lässt sich aus Fassung und Sprache nachrechnen")
    func transcriptKeyMatchesAssembler() {
        let built = TranscriptAssembler().finish(
            segments: [], mediaVersionID: mediaID, locale: "de_DE", origin: .speechAnalysis)
        #expect(LibraryStore.transcriptKey(media: mediaID.rawValue, locale: "de_DE") == built.id.rawValue)
    }
}

@Suite("Hörzustand je Gerät")
struct PerDeviceListeningTests {

    let audio = URL(string: "https://example.com/geraete.mp3")!
    var media: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }

    func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    func emptyStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    func played(_ start: Int64, _ end: Int64, at: Date, via: PlaybackRoute = .originalEpisode,
                device: String) -> LedgerEvent {
        LedgerEvent(mediaVersionID: media, range: range(start, end), kind: .played,
                    at: at, via: via, deviceID: device)
    }

    // Jede Zeile hat genau einen Schreiber. Dann kann der Abgleich, bei dem
    // der letzte Schreiber gewinnt, nichts überschreiben, was ein anderes
    // Gerät gehört hat.
    @Test("Jedes Gerät schreibt nur seine eigene Zeile, gelesen wird die Vereinigung")
    func eachDeviceWritesItsOwnRow() async throws {
        let store = try emptyStore()
        let now = Date()
        try await store.record([played(0, 60_000, at: now.addingTimeInterval(-30), device: "a")])
        try await store.record([played(120_000, 180_000, at: now.addingTimeInterval(-20), device: "b")])
        let before = try await store.listeningRowsForTesting()
        try await store.record([played(60_000, 90_000, at: now.addingTimeInterval(-10), device: "a")])

        let rows = try await store.listeningRowsForTesting()
        #expect(Set(rows.keys) == [media.rawValue + "#a", media.rawValue + "#b"])
        // Das Schreiben von Gerät A lässt die Zeile von Gerät B unverändert.
        #expect(rows[media.rawValue + "#b"] == before[media.rawValue + "#b"])
        #expect(rows[media.rawValue + "#a"]?.heard.ranges == [range(0, 90_000)])
        #expect(rows[media.rawValue + "#b"]?.heard.ranges == [range(120_000, 180_000)])

        let state = try await store.ledger().state(for: media)
        #expect(state.mediaVersionID == media)
        #expect(state.heard.ranges == [range(0, 90_000), range(120_000, 180_000)])
        #expect(state.resumePosition == MediaTime(milliseconds: 90_000))

        // Das Bereinigen fasst die Zeilen der Geräte nicht zusammen.
        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredListeningState.self) == 2)
    }

    @Test("Zeilen im alten Format werden weiter gelesen und mit gelöscht")
    func legacyRowsAreStillRead() async throws {
        let store = try emptyStore()
        let sourceID = SourceID(stable: "quelle-geraete")
        let episodeID = EpisodeID(stable: "folge-geraete")
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(
            episodes: [Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)],
            forSource: sourceID)
        let now = Date()
        try await store.insertListeningStateCopyForTesting(MediaListeningState(
            mediaVersionID: media, heard: IntervalSet(range(0, 60_000)), skipped: IntervalSet(),
            lastEventAt: now.addingTimeInterval(-600), resumePosition: MediaTime(milliseconds: 60_000)))
        try await store.record([played(120_000, 180_000, at: now.addingTimeInterval(-60), device: "a")])

        #expect(try await store.rowCountForTesting(StoredListeningState.self) == 2)
        let state = try await store.ledger().state(for: media)
        #expect(state.heard.ranges == [range(0, 60_000), range(120_000, 180_000)])
        #expect(state.resumePosition == MediaTime(milliseconds: 180_000))

        _ = try await store.removeEpisode(episodeID)
        #expect(try await store.rowCountForTesting(StoredListeningState.self) == 0)
        #expect(try await store.ledger().heard(in: media).isEmpty)
    }

    // Gerät A hört die Folge bis 30:00. Gerät B hatte sie früher bis 5:00
    // gehört und spielt danach einen kurzen Chat-Fokus aus derselben Folge.
    @Test("Die zusammengeführte Stelle folgt nur dem Hören der ganzen Folge")
    func mergedResumeFollowsOriginalEpisodeOnly() async throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-3_000), t1 = now.addingTimeInterval(-2_000)
        let t2 = now.addingTimeInterval(-1_000)

        var deviceA = MediaListeningState(mediaVersionID: media)
        deviceA.apply(played(0, 1_800_000, at: t1, device: "a"))
        var deviceB = MediaListeningState(mediaVersionID: media)
        deviceB.apply(played(0, 300_000, at: t0, device: "b"))
        deviceB.apply(played(2_400_000, 2_460_000, at: t2, via: .chatFocus, device: "b"))

        #expect(deviceA.merged(with: deviceB).resumePosition == MediaTime(milliseconds: 1_800_000))
        #expect(deviceB.merged(with: deviceA).resumePosition == MediaTime(milliseconds: 1_800_000))
        #expect(deviceA.merged(with: deviceB) == deviceB.merged(with: deviceA))

        // Dasselbe über den Speicher, mit einer Zeile je Gerät.
        let store = try emptyStore()
        try await store.record([played(0, 300_000, at: t0, device: "b")])
        try await store.record([played(0, 1_800_000, at: t1, device: "a")])
        try await store.record([played(2_400_000, 2_460_000, at: t2, via: .chatFocus, device: "b")])
        let state = try await store.ledger().state(for: media)
        #expect(state.resumePosition == MediaTime(milliseconds: 1_800_000))
        #expect(state.heard.ranges == [range(0, 1_800_000), range(2_400_000, 2_460_000)])
    }
}

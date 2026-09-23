//
//  RemovalAndSyncTests.swift
//
//  Die Löschregeln aus den Anforderungen:
//  - Audio entfernen lässt Transkript, Belege, Fakten und Hörzustand stehen.
//  - Folge löschen entfernt alles, was aus ihr entstanden ist, und der
//    nächste Feed-Abgleich legt sie nicht wieder an.
//  Dazu der Umgang mit Doppelten, wie sie beim iCloud-Abgleich entstehen.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIIntelligence

@Suite("Löschen und Synchronisation")
struct RemovalAndSyncTests {

    let sourceID = SourceID(stable: "quelle")
    let episodeID = EpisodeID(stable: "folge")
    let audio = URL(string: "https://example.com/folge.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }

    func seededStore() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        let episode = Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)

        let range = MediaTimeRange(start: MediaTime(milliseconds: 1_000), end: MediaTime(milliseconds: 9_000))
        let transcriptID = TranscriptID(stable: "t1")
        let transcript = Transcript(
            id: transcriptID, mediaVersionID: mediaID, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE",
            segments: [TranscriptSegment(id: SegmentID(stable: "s1"), range: range, text: "Hallo Welt")],
            analyzedRanges: IntervalSet(range))
        try await store.save(
            transcript: transcript,
            media: MediaVersion(id: mediaID, episodeID: episodeID, remoteURL: audio, localRelativePath: "x"),
            forEpisode: episodeID)
        let evidenceID = EvidenceID(stable: "e1")
        try await store.store(evidence: [Evidence(
            id: evidenceID, mediaVersionID: mediaID, episodeID: episodeID, sourceID: sourceID,
            transcriptID: transcriptID, transcriptRevision: .initial, range: range, quotedText: "Hallo Welt")])
        try await store.save(facts: [EpisodeFact(
            id: "f1", episodeID: episodeID, sourceID: sourceID, evidenceID: evidenceID,
            mediaVersionID: mediaID, statement: "Die Welt wird begrüßt.", range: range, modelTier: "test")],
            forEpisode: episodeID)
        try await store.record([LedgerEvent(mediaVersionID: mediaID, range: range, kind: .played,
                                            via: .originalEpisode, deviceID: "test")])
        return store
    }

    @Test("Audio entfernen lässt alle Daten der Folge stehen")
    func removingAudioKeepsData() async throws {
        let store = try await seededStore()
        let ids = try await store.mediaVersionIDs(forEpisode: episodeID)
        #expect(ids.contains(mediaID))
        try await store.markAudioRemoved(ids)
        #expect(try await store.transcript(forEpisode: episodeID)?.segments.count == 1)
        #expect(try await store.evidence(forEpisode: episodeID).count == 1)
        #expect(try await store.facts(forEpisode: episodeID).count == 1)
        #expect(try await !store.ledger().heard(in: mediaID).isEmpty)
        #expect(try await store.episodes(forSource: sourceID).count == 1)
    }

    @Test("Folge löschen entfernt alle Daten und bleibt gelöscht")
    func removingEpisodeDeletesEverything() async throws {
        let store = try await seededStore()
        let report = try await store.removeEpisode(episodeID)
        #expect(report.mediaVersionIDs.contains(mediaID))
        #expect(try await store.transcript(forEpisode: episodeID) == nil)
        #expect(try await store.evidence(forEpisode: episodeID).isEmpty)
        #expect(try await store.facts(forEpisode: episodeID).isEmpty)
        #expect(try await store.ledger().heard(in: mediaID).isEmpty)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)

        // Der Feed führt die Folge weiter. Sie darf nicht zurückkommen.
        let again = Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)
        let inserted = try await store.upsert(episodes: [again], forSource: sourceID)
        #expect(inserted == 0)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
    }

    @Test("Quelle abbestellen entfernt Quelle, Folgen und Daten")
    func removingSourceDeletesEverything() async throws {
        let store = try await seededStore()
        let report = try await store.removeSource(sourceID)
        #expect(report.episodeIDs == [episodeID])
        #expect(try await store.sources().isEmpty)
        #expect(try await store.evidence(forEpisode: episodeID).isEmpty)
        #expect(try await store.allFacts().isEmpty)
    }

    @Test("Doppelte Datensätze aus dem Abgleich werden bereinigt")
    func duplicatesAreRemoved() async throws {
        let store = try await seededStore()
        // Wie nach einem Abgleich: derselbe Beleg zweimal.
        let range = MediaTimeRange(start: MediaTime(milliseconds: 1_000), end: MediaTime(milliseconds: 9_000))
        try await store.insertDuplicateEvidenceForTesting(Evidence(
            id: EvidenceID(stable: "e1"), mediaVersionID: mediaID, episodeID: episodeID, sourceID: sourceID,
            transcriptID: TranscriptID(stable: "t1"), transcriptRevision: .initial, range: range,
            quotedText: "Hallo Welt"))
        #expect(try await store.rowCountForTesting(StoredEvidence.self) == 2)
        // Schon vor dem Bereinigen erscheint jede Kennung nur einmal.
        #expect(try await store.evidence(forEpisode: episodeID).count == 1)
        // Darf nicht abstürzen, obwohl die Kennung doppelt vorkommt.
        #expect(try await store.evidence(ids: [EvidenceID(stable: "e1")]).count == 1)
        try await store.removeDuplicates()
        #expect(try await store.rowCountForTesting(StoredEvidence.self) == 1)
        #expect(try await store.evidence(forEpisode: episodeID).count == 1)
        // Behalten wird die vollständigere Zeile, nicht die zuerst gelesene.
        #expect(try await store.evidence(forEpisode: episodeID).first?.transcriptID == TranscriptID(stable: "t1"))
    }
}

@Suite("Antworten mit Belegen")
struct AnswerCitationTests {
    @Test("Verweise im Antworttext werden erkannt")
    func citedNumbers() {
        #expect(KnowledgeExtractor.citedNumbers(in: "A [3] und B [12]. C [x] [ 4 ]") == [3, 12, 4])
        #expect(KnowledgeExtractor.citedNumbers(in: "Keine Verweise") == [])
    }

    @Test("Ohne Freigabe gilt Private Cloud Compute als nicht freigegeben")
    func privateCloudNeedsConsent() {
        let status = KnowledgeExtractor.currentStatus(allowPrivateCloud: false)
        #expect(status.privateCloudCompute == .unavailable(.userConsentMissing))
    }
}

@Suite("Suche für den Chat")
struct PassageRankerTests {
    func evidence(_ text: String, _ key: String) -> Evidence {
        Evidence(id: EvidenceID(stable: key), mediaVersionID: MediaVersionID(stable: "m"),
                 episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "s"),
                 transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                 range: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 1000)),
                 quotedText: text)
    }

    @Test("Die Stelle mit den Begriffen der Frage steht vorn")
    func ranksMatchingPassageFirst() {
        let pool = [
            evidence("Heute sprechen wir über das Wetter und den Urlaub am Meer.", "a"),
            evidence("Federated Learning erlaubt Krankenhäusern, Modelle gemeinsam zu trainieren.", "b"),
            evidence("Zum Schluss noch ein Hinweis auf die nächste Folge.", "c"),
        ]
        let ranked = PassageRanker().rank(pool, for: "Wie trainieren Krankenhäuser gemeinsam Modelle?", limit: 2)
        #expect(ranked.first?.id == EvidenceID(stable: "b"))
    }

    @Test("Mit keepAll bleibt auch Unpassendes im Pool")
    func keepAll() {
        let pool = [evidence("Nichts davon passt.", "a")]
        #expect(PassageRanker().rank(pool, for: "Quantenphysik", limit: 5, keepAll: true).count == 1)
    }
}

@Suite("Gemerkte Stellen aus dem Player")
struct PlayerHighlightRemovalTests {
    @Test("Eine gemerkte Stelle bleibt, wenn die Folge gelöscht wird")
    func noteSurvivesEpisodeRemoval() async throws {
        let base = RemovalAndSyncTests()
        let store = try await base.seededStore()
        // Notizen sind eigenes Wissen. Sie tragen Zitat und Herkunft selbst.
        let highlight = Highlight(evidenceID: EvidenceID(stable: "nicht-gespeichert"), note: "merken",
                                  capturedVia: .player, mediaVersionID: base.mediaID,
                                  quote: "Ein Satz aus der Folge", episodeID: base.episodeID,
                                  episodeTitle: "Folge", sourceTitle: "Quelle", positionMs: 12_000)
        try await store.save(highlights: [highlight])
        _ = try await store.removeEpisode(base.episodeID)
        let left = try await store.highlights()
        #expect(left.map(\.id) == [highlight.id])
        #expect(left.first?.quote == "Ein Satz aus der Folge")
        #expect(left.first?.positionMs == 12_000)
    }
}

@Suite("Merkzeichen aus früheren Abos")
struct OldTombstoneTests {
    @Test("Ein Merkzeichen von vor dem erneuten Abo versteckt die Folge nicht")
    func oldTombstoneDoesNotHideResubscribedEpisode() async throws {
        let base = RemovalAndSyncTests()
        let store = try await base.seededStore()
        _ = try await store.removeEpisode(base.episodeID)
        // Quelle abbestellen und später neu abonnieren.
        _ = try await store.removeSource(base.sourceID)
        try await Task.sleep(for: .milliseconds(20))
        try await store.upsert(source: Source(id: base.sourceID, kind: .podcastRSS, title: "Quelle"))
        let again = Episode(id: base.episodeID, sourceID: base.sourceID, title: "Folge", audioURL: base.audio)
        _ = try await store.upsert(episodes: [again], forSource: base.sourceID)
        try await store.removeDuplicates()
        #expect(try await store.episodes(forSource: base.sourceID).map(\.id) == [base.episodeID])
    }
}

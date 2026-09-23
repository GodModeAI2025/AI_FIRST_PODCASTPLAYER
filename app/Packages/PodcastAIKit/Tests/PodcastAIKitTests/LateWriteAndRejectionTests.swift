//
//  LateWriteAndRejectionTests.swift
//
//  - Eine Erschliessung, die nach dem Löschen noch schreibt, wird
//    weggeräumt, ohne ein neues Merkzeichen zu setzen. Eine neu abonnierte
//    Quelle behält ihre Folge.
//  - Abgelehnte Eingaben des Modells sind von vorübergehenden Fehlern
//    unterscheidbar, damit niemand sie bei jedem Lauf erneut schickt.
//

import Testing
import Foundation
#if canImport(FoundationModels)
// Nur diese Typen: FoundationModels hat einen eigenen `Transcript`.
import class FoundationModels.LanguageModelSession
import enum FoundationModels.LanguageModelError
#endif
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIIntelligence

@Suite("Späte Schreibvorgänge der Erschliessung")
struct LateAnalysisWriteTests {

    let sourceID = SourceID(stable: "quelle")
    let episodeID = EpisodeID(stable: "folge")
    let audio = URL(string: "https://example.com/folge.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }
    let evidenceID = EvidenceID(stable: "e1")
    var episode: Episode { Episode(id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio) }

    func subscribe(_ store: LibraryStore) async throws -> Int {
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        return try await store.upsert(episodes: [episode], forSource: sourceID)
    }

    /// Was die Pipeline am Ende eines Laufs schreibt.
    func writeAnalysis(_ store: LibraryStore) async throws {
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
        try await store.store(evidence: [Evidence(
            id: evidenceID, mediaVersionID: mediaID, episodeID: episodeID, sourceID: sourceID,
            transcriptID: transcriptID, transcriptRevision: .initial, range: range, quotedText: "Hallo Welt")])
    }

    @Test("Abbestellt und neu abonniert: die Folge bleibt sichtbar, der späte Lauf verschwindet")
    func resubscribedEpisodeStaysLive() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        _ = try await subscribe(store)
        _ = try await store.removeSource(sourceID)
        #expect(try await subscribe(store) == 1)

        // Der abgebrochene Lauf von vor dem Abbestellen schreibt noch.
        try await writeAnalysis(store)
        #expect(try await store.episodes(forSource: sourceID).first?.currentMediaVersionID == mediaID)

        let report = try await store.removeAnalysis(ofEpisode: episodeID, mediaVersionID: mediaID)
        #expect(report.evidenceIDs == [evidenceID])
        #expect(report.episodeIDs.isEmpty)
        #expect(try await store.evidence(forEpisode: episodeID).isEmpty)
        #expect(try await store.transcript(forEpisode: episodeID) == nil)
        #expect(try await store.analyzedEpisodeIDs().isEmpty)

        // Kein Merkzeichen: die Folge gehört zum neuen Abo und bleibt dort.
        #expect(try await store.removedEpisodes().isEmpty)
        let listed = try await store.episodes(forSource: sourceID)
        #expect(listed.map(\.id) == [episodeID])
        #expect(listed.first?.currentMediaVersionID == nil)
        #expect(try await store.upsert(episodes: [episode], forSource: sourceID) == 0)
        #expect(try await store.episodes(forSource: sourceID).map(\.id) == [episodeID])
    }

    @Test("Gelöschte Folge: der späte Lauf verschwindet, das Merkzeichen bleibt")
    func removedEpisodeKeepsTombstone() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        _ = try await subscribe(store)
        _ = try await store.removeEpisode(episodeID)

        try await writeAnalysis(store)
        _ = try await store.removeAnalysis(ofEpisode: episodeID, mediaVersionID: mediaID)

        #expect(try await store.evidence(forEpisode: episodeID).isEmpty)
        #expect(try await store.transcript(forMedia: mediaID) == nil)
        #expect(try await store.removedEpisodes().map(\.id) == [episodeID])
        #expect(try await store.removedEpisodes().first?.currentMediaVersionID == nil)
        #expect(try await store.upsert(episodes: [episode], forSource: sourceID) == 0)
        #expect(try await store.episodes(forSource: sourceID).isEmpty)
    }

    @Test("Hörzustand und Fakten der neu abonnierten Folge bleiben")
    func keepsListeningState() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        _ = try await subscribe(store)
        let range = MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 30_000))
        try await store.record([LedgerEvent(mediaVersionID: mediaID, range: range, kind: .played,
                                            via: .originalEpisode, deviceID: "test")])
        try await writeAnalysis(store)
        _ = try await store.removeAnalysis(ofEpisode: episodeID, mediaVersionID: mediaID)
        #expect(try await !store.ledger().heard(in: mediaID).isEmpty)
    }
}

#if canImport(FoundationModels)
@Suite("Abgelehnt oder vorübergehend gescheitert")
struct RejectionClassificationTests {

    @Test("Schutzregeln, Ablehnung und zu langer Kontext gelten als Ablehnung")
    func rejections() {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            #expect(KnowledgeExtractor.isRejection(
                LanguageModelError.guardrailViolation(.init(debugDescription: "Schutzregel"))))
            #expect(KnowledgeExtractor.isRejection(
                LanguageModelError.refusal(.init(explanation: "nein", debugDescription: "nein"))))
            #expect(KnowledgeExtractor.isRejection(
                LanguageModelError.contextSizeExceeded(
                    .init(contextSize: 4_096, tokenCount: 5_000, debugDescription: "zu lang"))))
        }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "alt")
        #expect(KnowledgeExtractor.isRejection(LanguageModelSession.GenerationError.guardrailViolation(context)))
        #expect(KnowledgeExtractor.isRejection(LanguageModelSession.GenerationError.exceededContextWindowSize(context)))
    }

    @Test("Last, Zeitüberschreitung und Unbekanntes lassen einen zweiten Versuch zu")
    func transient() {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            #expect(!KnowledgeExtractor.isRejection(
                LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "später"))))
            #expect(!KnowledgeExtractor.isRejection(
                LanguageModelError.timeout(.init(debugDescription: "zu langsam"))))
        }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "alt")
        #expect(!KnowledgeExtractor.isRejection(LanguageModelSession.GenerationError.rateLimited(context)))
        #expect(!KnowledgeExtractor.isRejection(LanguageModelSession.GenerationError.decodingFailure(context)))
        #expect(!KnowledgeExtractor.isRejection(URLError(.timedOut)))
        #expect(!KnowledgeExtractor.isRejection(CancellationError()))
    }

    @Test("Die Meldung einer Ablehnung nennt keinen zweiten Versuch")
    func rejectedDescription() {
        let error = ExtractorError.generationRejected("Schutzregel")
        #expect(error.errorDescription?.contains("nicht ausgewertet") == true)
        #expect(error.errorDescription?.contains("—") == false)
    }
}
#endif

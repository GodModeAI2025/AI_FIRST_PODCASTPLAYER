//
//  RelevanceSelectionTests.swift
//  PodcastAIKitTests
//
//  Die Relevanzprüfung mit einem gespielten Modell: welche Liste es je
//  Stufe sieht und was seine Auswahl deshalb verwerfen darf.
//
//  Die Stelle für Apple Intelligence führt hier nichts aus und antwortet
//  selbst, mit festen Nummern. Weil die Sitzung erst in der Operation
//  entsteht, läuft dabei kein Modell. Private Cloud Compute ist im Test nie
//  bereit, es antwortet also immer die Stufe „Gerät“.
//

#if canImport(FoundationModels)
import Testing
import Foundation
import FoundationModels
@testable import PodcastAIKit
@testable import PodcastAIIntelligence
@testable import PodcastAIPersistence

/// Spielt das Modell: nennt immer dieselben Nummern.
private struct SelectingScheduler: AIScheduling {
    let numbers: [Int]

    struct UnexpectedRequest: Error {}

    func run<T: Sendable>(
        _ kind: AIWorkKind, priority: AIWorkPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let output = try RelevanceSelectionOutput(
            GeneratedContent(json: #"{"selectedNumbers": \#(numbers), "reasons": ""}"#))
        guard let answer = UncheckedBox(output) as? T else { throw UnexpectedRequest() }
        return answer
    }
}

/// Das Gerätemodell gilt als bereit, Private Cloud Compute nicht.
private let deviceOnly = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))

private func passages(count: Int) -> [Evidence] {
    (0..<count).map { index in
        Evidence(
            id: EvidenceID(stable: "relevanz-\(index)"), mediaVersionID: MediaVersionID(stable: "m"),
            episodeID: EpisodeID(stable: "folge"), sourceID: SourceID(stable: "quelle"),
            transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
            range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 60_000),
                                  end: MediaTime(milliseconds: Int64(index) * 60_000 + 50_000)),
            quotedText: "Stelle \(index) über Datenschutz in Kliniken.")
    }
}

@Suite("Relevanzprüfung mit gespieltem Modell")
struct RelevanceSelectionTests {

    let profile = InterestProfile(interests: [Interest(label: "Datenschutz")])

    /// So viele Stellen sieht das Gerät in einer Liste.
    let shown = ExtractorConfiguration().candidateBuilder(for: .onDevice).maximumCandidates

    @Test("Auf dem Gerät gilt die Liste des Geräts, auch für das Prüfen der Nummern")
    func deviceListOnDevice() async throws {
        let pool = passages(count: ExtractorConfiguration().candidateBuilder.maximumCandidates)
        #expect(shown < pool.count)

        // Die zweite Nummer stünde in der bestellten Liste, das Gerät hat sie nie gesehen.
        let extractor = KnowledgeExtractor(scheduler: SelectingScheduler(numbers: [1, shown + 1]))
        let selection = try await extractor.selectRelevant(from: pool, profile: profile, availability: deviceOnly)
        #expect(selection.evidenceIDs == [pool[0].id])
        #expect(selection.audit.outOfRange == [shown + 1])
    }

    @Test("Abgelehnt ist nur, was dem Modell vorlag und es nicht genannt hat")
    func declinedWasShown() async throws {
        let pool = passages(count: shown + 5)
        let extractor = KnowledgeExtractor(scheduler: SelectingScheduler(numbers: [2, 3]))
        let selection = try await extractor.selectRelevant(from: pool, profile: profile, availability: deviceOnly)

        let named = [pool[1].id, pool[2].id]
        #expect(selection.evidenceIDs == named)
        #expect(selection.declinedIDs == Set(pool.prefix(shown).map(\.id)).subtracting(named))
        // Was nicht mehr in die Liste passte, ist weder bestätigt noch abgelehnt.
        #expect(selection.declinedIDs.isDisjoint(with: pool.dropFirst(shown).map(\.id)))
    }

    @Test("Was über die Höchstzahl hinausgeht, ist nicht bestätigt, aber auch nicht abgelehnt")
    func truncatedIsNotDeclined() {
        let candidates = CandidateListBuilder().build(from: passages(count: 6))
        let result = EvidenceSelectionValidator(maximumSelections: 2)
            .validate(RawSelection(indices: [1, 2, 3, 3, 99]), against: candidates)
        #expect(result.evidenceIDs == [candidates[0].id, candidates[1].id])
        #expect(result.audit.truncated == 1)
        #expect(result.declinedIDs == Set(candidates[3...].map(\.id)))
    }

    @Test("Steht ein Beleg zweimal in der Liste, genügt eine Nennung")
    func namedOnceIsNotDeclined() {
        let pool = passages(count: 2)
        let candidates = CandidateListBuilder().build(from: [pool[0], pool[1], pool[0]])
        let result = EvidenceSelectionValidator().validate(RawSelection(indices: [3]), against: candidates)
        #expect(result.evidenceIDs == [pool[0].id])
        #expect(result.declinedIDs == [pool[1].id])
    }

    @Test("Themen-Update und Kandidaten behalten Stichworttreffer, die das Modell nie gesehen hat")
    func unseenMatchesStay() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let source = SourceID(stable: "quelle")
        try await store.upsert(source: Source(id: source, kind: .podcastRSS, title: "Quelle"))
        let audio = URL(string: "https://example.com/relevanz.mp3")!
        let episode = Episode(id: EpisodeID(stable: "relevanz"), sourceID: source, title: "Relevanz", audioURL: audio)
        _ = try await store.upsert(episodes: [episode], forSource: source)
        let media = MediaVersionID(stable: audio.absoluteString)
        // Eine Bibliothek ohne Kapitel-Tags mit mehr Treffern, als in die Liste passen.
        let count = shown + 4
        let segments = (0..<count).map { index in
            TranscriptSegment(id: SegmentID(stable: "relevanz-\(index)"),
                              range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 60_000),
                                                    end: MediaTime(milliseconds: Int64(index) * 60_000 + 50_000)),
                              text: "Stelle \(index) über Datenschutz in Kliniken.")
        }
        let transcript = Transcript(
            id: TranscriptID(stable: "t-relevanz"), mediaVersionID: media, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(MediaTimeRange(
                start: .zero, end: MediaTime(milliseconds: Int64(count) * 60_000))))
        try await store.save(transcript: transcript,
                             media: MediaVersion(id: media, episodeID: episode.id, remoteURL: audio),
                             forEpisode: episode.id)
        let evidence = segments.map { segment in
            Evidence(id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: segment.range),
                     mediaVersionID: media, episodeID: episode.id, sourceID: source,
                     transcriptID: transcript.id, transcriptRevision: .initial,
                     range: segment.range, quotedText: segment.text)
        }
        try await store.store(evidence: evidence)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAIRelevanz-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        // Das Modell wählt nur die erste Stelle seiner Liste.
        let pipeline = ContentPipeline(
            store: store, mediaDirectory: directory, aiScheduler: SelectingScheduler(numbers: [1]))
        let interest = profile.interests[0]

        // Die Liste folgt der Rangfolge der Vorauswahl. Bleiben müssen die
        // gewählte Stelle und alle, die nicht mehr in die Liste passten.
        let ranked = RelevanceScorer(maximumPerInterest: .max).score(evidence: evidence, profile: profile)
            .map(\.evidenceID)
        #expect(ranked.count == count)
        let kept = Set([ranked[0]] + ranked[shown...])

        let chapters = try await pipeline.editionChapters(
            tags: [interest.id], profile: profile, availability: deviceOnly, titledSections: false)
        #expect(Set(chapters.flatMap { $0.passageHits.keys }) == kept)

        let candidates = try await pipeline.candidates(
            for: SmartPodcastFeed(title: "Datenschutz", topicIDs: [interest.id]),
            profile: profile, availability: deviceOnly)
        #expect(Set(candidates.map(\.evidence.id)) == kept)
        // Nur die gewählte Stelle gilt als vom Modell bestätigt.
        let keywordOnly = TestLanguage.pick(de: "Wort kommt vor", en: "word appears")
        #expect(candidates.filter { !$0.reason.contains(keywordOnly) }.map(\.evidence.id) == [ranked[0]])
    }
}
#endif

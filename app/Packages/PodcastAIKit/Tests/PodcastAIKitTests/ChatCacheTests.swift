//
//  ChatCacheTests.swift
//
//  Was sich der Chat zwischen zwei Fragen merkt, muss dasselbe ergeben wie
//  ohne Speicher und darf nichts überleben, was nicht mehr gilt: eine neue
//  Revision des Transkripts, eine gelöschte Folge, einen anderen Bereich.
//  „Audio entfernen“ lässt die Daten einer Folge stehen, „Folge löschen“
//  nimmt alles mit, was aus ihr entstanden ist.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIKnowledge

@Suite("Zwischenspeicher des Chats")
struct ChatCacheTests {

    static func evidence(_ name: String, episode: String, text: String,
                         revision: Revision = .initial, at second: Int64 = 0) -> Evidence {
        let media = MediaVersionID(stable: "m-\(episode)")
        let range = MediaTimeRange(start: MediaTime(milliseconds: second * 1_000),
                                   end: MediaTime(milliseconds: second * 1_000 + 900))
        return Evidence(
            id: EvidenceID(stable: "\(name)|r\(revision.value)"), mediaVersionID: media,
            episodeID: EpisodeID(stable: episode), sourceID: SourceID(stable: "quelle"),
            transcriptID: TranscriptID(stable: "t-\(episode)-\(revision.value)"), transcriptRevision: revision,
            range: range, quotedText: text)
    }

    static let pool: [Evidence] = (0..<40).map { (index: Int) -> Evidence in
        let text: String = index == 27
            ? "Federated Learning erlaubt Krankenhäusern, Modelle gemeinsam zu trainieren."
            : "Heute sprechen wir über das Wetter, den Urlaub am Meer und Fahrräder, Teil \(index)."
        let episode = index < 20 ? "a" : "b"
        return evidence("p\(index)", episode: episode, text: text, at: Int64(index) * 60)
    }

    // MARK: - Wörter und Einbettungen

    @Test("Mit Speicher dieselbe Rangfolge wie ohne, auch beim zweiten Mal")
    func sameRankingWithCache() {
        let question = "Wie trainieren Krankenhäuser gemeinsam Modelle?"
        let cached = PassageRanker(index: PassageIndex())
        let first = cached.rank(Self.pool, for: question, limit: 10, embeddingLimit: 8)
        let second = cached.rank(Self.pool, for: question, limit: 10, embeddingLimit: 8)
        let fresh = PassageRanker(index: PassageIndex()).rank(Self.pool, for: question, limit: 10, embeddingLimit: 8)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.id) == fresh.map(\.id))
        #expect(first.first?.id == Self.pool[27].id)
        // Der alte Weg summierte in der Reihenfolge einer Menge, die von
        // Start zu Start wechselt. Gleich bis auf die letzte Stelle.
        let gap = zip(cached.keywordScores(Self.pool, for: question),
                      LegacyRanking.keywordScores(Self.pool, for: question)).map { abs($0 - $1) }.max() ?? 0
        #expect(gap < 1e-9)
    }

    @Test("Eine neue Revision des Transkripts wird neu zerlegt")
    func newRevisionIsReindexed() {
        let index = PassageIndex()
        let ranker = PassageRanker(index: index)
        let old = Self.evidence("x", episode: "a", text: "Wir reden über Bienen und Honig.")
        _ = ranker.keywordScores([old], for: "Bienen")
        // Neue Revision: neue Kennung, neuer Text.
        let revised = Self.evidence("x", episode: "a", text: "Wir reden über Wespen.", revision: Revision(2))
        #expect(ranker.keywordScores([revised], for: "Bienen") == [0])
        #expect(ranker.keywordScores([revised], for: "Wespen")[0] > 0)
        #expect(index.counts.terms == 2)
    }

    @Test("Derselbe Beleg mit anderem Text wird nicht aus dem Speicher beantwortet")
    func changedTextIsNotServedFromCache() {
        let ranker = PassageRanker(index: PassageIndex())
        let first = Self.evidence("y", episode: "a", text: "Solaranlagen auf dem Dach.")
        #expect(ranker.keywordScores([first], for: "Solaranlagen")[0] > 0)
        let changed = Self.evidence("y", episode: "a", text: "Windkraft an der Küste.")
        #expect(ranker.keywordScores([changed], for: "Solaranlagen") == [0])
    }

    @Test("Folge löschen nimmt Wörter und Einbettungen der Folge mit, andere bleiben")
    func forgettingAnEpisode() {
        let index = PassageIndex()
        _ = PassageRanker(index: index).rank(Self.pool, for: "Krankenhäuser Modelle", limit: 5, embeddingLimit: 40)
        #expect(index.episodeIDs == [EpisodeID(stable: "a"), EpisodeID(stable: "b")])
        index.forget(episodes: [EpisodeID(stable: "a")])
        #expect(index.episodeIDs == [EpisodeID(stable: "b")])
        #expect(index.counts.terms == 20)
        index.forget(evidence: [Self.pool[30].id])
        #expect(index.counts.terms == 19)
    }

    // MARK: - Belege im Store

    func seededStore() async throws -> (LibraryStore, Episode, Episode) {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let source = SourceID(stable: "quelle")
        try await store.upsert(source: Source(id: source, kind: .podcastRSS, title: "Quelle"))
        var made: [Episode] = []
        for name in ["a", "b"] {
            let audio = URL(string: "https://example.com/\(name).mp3")!
            let episode = Episode(id: EpisodeID(stable: name), sourceID: source, title: name, audioURL: audio)
            _ = try await store.upsert(episodes: [episode], forSource: source)
            let media = MediaVersionID(stable: audio.absoluteString)
            let segments = (0..<3).map { index in
                TranscriptSegment(id: SegmentID(stable: "\(name)-\(index)"),
                                  range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 10_000),
                                                        end: MediaTime(milliseconds: Int64(index) * 10_000 + 9_000)),
                                  text: "Satz \(index) aus \(name).")
            }
            let transcript = Transcript(
                id: TranscriptID(stable: "t-\(name)"), mediaVersionID: media, revision: .initial,
                origin: .speechAnalysis, locale: "de_DE", segments: segments,
                analyzedRanges: IntervalSet(MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 30_000))))
            try await store.save(transcript: transcript,
                                 media: MediaVersion(id: media, episodeID: episode.id, remoteURL: audio),
                                 forEpisode: episode.id)
            try await store.store(evidence: segments.reversed().map { segment in
                Evidence(id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial,
                                               range: segment.range),
                         mediaVersionID: media, episodeID: episode.id, sourceID: source,
                         transcriptID: transcript.id, transcriptRevision: .initial,
                         range: segment.range, quotedText: segment.text)
            })
            made.append(episode)
        }
        return (store, made[0], made[1])
    }

    @Test("Gemerkte Belege folgen Schreiben, Löschen und Abgleich")
    func poolFollowsWrites() async throws {
        let (store, a, b) = try await seededStore()
        #expect(try await store.evidenceForAnalyzedEpisodes().count == 6)

        // Ein neuer Beleg ist bei der nächsten Frage dabei.
        let extra = Self.evidence("neu", episode: "b", text: "Neu.", at: 100)
        try await store.store(evidence: [Evidence(
            id: extra.id, mediaVersionID: extra.mediaVersionID, episodeID: b.id, sourceID: extra.sourceID,
            transcriptID: extra.transcriptID, transcriptRevision: .initial, range: extra.range, quotedText: "Neu.")])
        #expect(try await store.evidenceForAnalyzedEpisodes().count == 7)

        // Audio entfernen lässt alles stehen.
        try await store.markAudioRemoved(try await store.mediaVersionIDs(forEpisode: a.id))
        #expect(try await store.evidenceForAnalyzedEpisodes().count == 7)

        // Folge löschen nimmt ihre Belege mit.
        _ = try await store.removeEpisode(a.id)
        let left = try await store.evidenceForAnalyzedEpisodes()
        #expect(left.count == 4)
        #expect(!left.contains { $0.episodeID == a.id })

        // Nachträglich Geschriebenes einer Erschließung verschwindet ebenso.
        _ = try await store.removeAnalysis(ofEpisode: b.id,
                                           mediaVersionID: MediaVersionID(stable: "https://example.com/b.mp3"))
        #expect(try await store.evidenceForAnalyzedEpisodes().count == 1)

        // Nach einer Änderung von einem anderen Gerät wird neu gelesen.
        await store.forgetCachedEvidence()
        #expect(try await store.evidenceForAnalyzedEpisodes().count == 1)
    }

    @Test("Belege eines Bereichs: dieselben wie einzeln gelesen, und ein anderer Bereich gibt andere")
    func scopedEvidence() async throws {
        let (store, a, b) = try await seededStore()
        _ = try await store.evidenceForAnalyzedEpisodes()
        for scope in [[a.id], [b.id], [b.id, a.id], []] {
            var expected: [Evidence] = []
            for id in scope { expected += try await store.evidence(forEpisode: id) }
            let scoped = try await store.timedEvidence(forEpisodes: scope)
            #expect(scoped == expected.filter { $0.range != nil })
        }
        // Greift die Grenze des Bestands, wird wie bisher einzeln gelesen.
        let limited = try await store.timedEvidence(forEpisodes: [a.id], poolLimit: 2)
        #expect(limited == (try await store.evidence(forEpisode: a.id)))
        _ = try await store.removeEpisode(a.id)
        #expect(try await store.timedEvidence(forEpisodes: [a.id]).isEmpty)
    }

    @Test("Der Fingerabdruck passt zum Transkript und ändert sich mit ihm")
    func transcriptFingerprint() async throws {
        let (store, a, _) = try await seededStore()
        let transcript = try #require(try await store.transcript(forEpisode: a.id))
        let print = try await store.transcriptFingerprint(forEpisode: a.id)
        #expect(print == LibraryStore.TranscriptFingerprint(transcript))
        #expect(print?.segmentCount == 3)
        #expect(print?.lastEndMs == 29_000)

        // Eine neue Revision derselben Fassung ist ein anderes Transkript.
        let media = MediaVersionID(stable: "https://example.com/a.mp3")
        let revised = Transcript(
            id: TranscriptID(stable: "t-a-2"), mediaVersionID: media, revision: Revision(2),
            origin: .speechAnalysis, locale: "de_DE",
            segments: [TranscriptSegment(id: SegmentID(stable: "a-neu"),
                                         range: MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 5_000)),
                                         text: "Neu.")],
            analyzedRanges: IntervalSet(MediaTimeRange(start: .zero, end: MediaTime(milliseconds: 5_000))))
        try await store.save(transcript: revised,
                             media: MediaVersion(id: media, episodeID: a.id, remoteURL: URL(string: "https://example.com/a.mp3")!),
                             forEpisode: a.id)
        let after = try await store.transcriptFingerprint(forEpisode: a.id)
        #expect(after == LibraryStore.TranscriptFingerprint(try #require(try await store.transcript(forEpisode: a.id))))
        #expect(after != print)

        _ = try await store.removeEpisode(a.id)
        #expect(try await store.transcriptFingerprint(forEpisode: a.id) == nil)
    }
}

//
//  ChatScopeAndTrailTests.swift
//
//  Eingrenzung einer Frage auf Podcast und Zeitraum, und was eine
//  Wissenslandkarte mitnimmt, behält und beim Löschen einer Folge verliert.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Eingrenzung und Wissenslandkarten")
struct ChatScopeAndTrailTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let podcast = SourceID(stable: "podcast-a")
    let other = SourceID(stable: "podcast-b")

    // MARK: - Eingrenzung

    @Test("Ohne Eingrenzung zählt jede Folge, auch ohne Datum")
    func unrestrictedAdmitsEverything() {
        let filter = LibraryFilter()
        #expect(filter.isUnrestricted)
        #expect(filter.admits(sourceID: other, publishedAt: nil, now: now))
    }

    @Test("Ein Podcast lässt nur seine eigenen Folgen zu")
    func podcastFilter() {
        let filter = LibraryFilter(sourceID: podcast)
        #expect(!filter.isUnrestricted)
        #expect(filter.admits(sourceID: podcast, publishedAt: nil, now: now))
        #expect(!filter.admits(sourceID: other, publishedAt: now, now: now))
    }

    @Test("Der Zeitraum rechnet vom Erscheinungsdatum")
    func periodFilter() {
        let week = LibraryFilter(period: .lastWeek)
        let month = LibraryFilter(period: .lastMonth)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let fortyDaysAgo = now.addingTimeInterval(-40 * 86_400)
        #expect(week.admits(sourceID: other, publishedAt: threeDaysAgo, now: now))
        #expect(!week.admits(sourceID: other, publishedAt: tenDaysAgo, now: now))
        #expect(month.admits(sourceID: other, publishedAt: tenDaysAgo, now: now))
        #expect(!month.admits(sourceID: other, publishedAt: fortyDaysAgo, now: now))
        // Ohne Datum lässt sich der Zeitraum nicht prüfen.
        #expect(!week.admits(sourceID: other, publishedAt: nil, now: now))
    }

    @Test("Podcast und Zeitraum gelten zusammen")
    func combinedFilter() {
        let filter = LibraryFilter(sourceID: podcast, period: .lastWeek)
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(filter.admits(sourceID: podcast, publishedAt: yesterday, now: now))
        #expect(!filter.admits(sourceID: other, publishedAt: yesterday, now: now))
        #expect(!filter.admits(sourceID: podcast, publishedAt: now.addingTimeInterval(-20 * 86_400), now: now))
    }

    @Test("Derselbe Filter ergibt denselben Bereich, damit Antworten zusammenfinden")
    func scopeIsStable() {
        let first = ChatScope.library(LibraryFilter(sourceID: podcast, period: .lastMonth))
        let second = ChatScope.library(LibraryFilter(sourceID: podcast, period: .lastMonth))
        #expect(first == second)
        #expect(first != .allAnalyzed)
    }

    // MARK: - Wissenslandkarten

    let episodeA = EpisodeID(stable: "folge-a")
    let episodeB = EpisodeID(stable: "folge-b")
    var mediaA: MediaVersionID { MediaVersionID(stable: "media-a") }
    var mediaB: MediaVersionID { MediaVersionID(stable: "media-b") }

    func evidence(_ key: String, episode: EpisodeID, media: MediaVersionID, from: Int64, to: Int64) -> Evidence {
        Evidence(
            id: EvidenceID(stable: key), mediaVersionID: media, episodeID: episode, sourceID: podcast,
            transcriptID: TranscriptID(stable: "t-\(key)"), transcriptRevision: .initial,
            range: MediaTimeRange(start: MediaTime(milliseconds: from), end: MediaTime(milliseconds: to)),
            quotedText: "Zitat \(key)")
    }

    @Test("Eine Karte merkt nur die Notizen ihrer eigenen Belege")
    func notesOfTheAnswerOnly() {
        let cited = evidence("e1", episode: episodeA, media: mediaA, from: 600_000, to: 630_000)
        // Zwanzig Sekunden nach dem Beleg gemerkt: der gemerkte Bereich reicht zurück in den Beleg.
        let near = Highlight(evidenceID: EvidenceID(stable: "n1"), mediaVersionID: mediaA,
                             episodeID: episodeA, positionMs: 650_000)
        let farAway = Highlight(evidenceID: EvidenceID(stable: "n2"), mediaVersionID: mediaA,
                                episodeID: episodeA, positionMs: 1_800_000)
        let otherEpisode = Highlight(evidenceID: EvidenceID(stable: "n3"), mediaVersionID: mediaB,
                                     episodeID: episodeB, positionMs: 615_000)
        let sameStelle = Highlight(evidenceID: cited.id)
        let ids = KnowledgeTrail.noteIDs(in: [near, farAway, otherEpisode, sameStelle], matching: [cited])
        #expect(Set(ids) == [near.id, sameStelle.id])
    }

    @Test("Eine Session behält nur Notizen, die während ihr entstanden sind")
    func sessionNotes() {
        let start = now
        let before = Highlight(evidenceID: EvidenceID(stable: "alt"), capturedAt: start.addingTimeInterval(-3_600))
        let during = Highlight(evidenceID: EvidenceID(stable: "neu"), capturedAt: start.addingTimeInterval(120))
        let supporting = EvidenceID(stable: "beleg")
        let atEvidence = Highlight(evidenceID: supporting, capturedAt: start.addingTimeInterval(-86_400))
        let closure = SessionClosure(question: "Frage", supportingEvidenceIDs: [supporting],
                                     availableFollowUpCount: 0, startedAt: start)
        #expect(Set(closure.noteIDs(in: [before, during, atEvidence])) == [during.id, atEvidence.id])
    }

    @Test("Wird ein zitierter Beleg gelöscht, geht der Antworttext mit")
    func removingCitedEvidenceDropsAnswerText() throws {
        let e1 = EvidenceID(stable: "e1"), e2 = EvidenceID(stable: "e2")
        let trail = KnowledgeTrail(question: "Was sagt A?", evidenceIDs: [e1, e2],
                                   answerText: "A sagt dies [1] und das [2].",
                                   citationNumbers: [1: e1, 2: e2])
        let pruned = try #require(trail.removing(evidence: [e1]))
        #expect(pruned.id == trail.id)
        #expect(pruned.question == trail.question)
        #expect(pruned.evidenceIDs == [e2])
        #expect(pruned.answerText == nil)
        #expect(pruned.citationNumbers == nil)
    }

    @Test("Betrifft das Löschen die Karte nicht, bleibt sie unverändert")
    func unrelatedRemovalKeepsTrail() throws {
        let e1 = EvidenceID(stable: "e1")
        let trail = KnowledgeTrail(question: "Frage", evidenceIDs: [e1], answerText: "Text [1]",
                                   citationNumbers: [1: e1])
        let kept = try #require(trail.removing(evidence: [EvidenceID(stable: "fremd")]))
        #expect(kept.answerText == "Text [1]")
        #expect(kept.evidenceIDs == [e1])
    }

    @Test("Ohne Beleg und ohne Notiz gibt es die Karte nicht mehr")
    func emptyTrailDisappears() {
        let e1 = EvidenceID(stable: "e1")
        let bare = KnowledgeTrail(question: "Frage", evidenceIDs: [e1])
        #expect(bare.removing(evidence: [e1]) == nil)
        // Eigene Notizen überstehen das Löschen einer Folge, die Karte mit ihnen.
        let withNote = KnowledgeTrail(question: "Frage", evidenceIDs: [e1], highlightIDs: [HighlightID()])
        #expect(withNote.removing(evidence: [e1]) != nil)
    }

    @Test("Ältere Karten ohne Antworttext lassen sich weiter lesen")
    func olderPayloadDecodes() throws {
        let json = """
        {"id":"k1","question":"Alte Frage","claimIDs":[],"evidenceIDs":["e1"],"highlightIDs":[],
         "counterpointEvidenceIDs":[],"parkedAt":"2026-01-01T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let trail = try decoder.decode(KnowledgeTrail.self, from: Data(json.utf8))
        #expect(trail.question == "Alte Frage")
        #expect(trail.answerText == nil)
        #expect(trail.citationNumbers == nil)
    }

    @Test("Antworttext und Verweisnummern überstehen das Speichern")
    func trailRoundTripsThroughStore() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let e1 = EvidenceID(stable: "e1"), e3 = EvidenceID(stable: "e3")
        let trail = KnowledgeTrail(question: "Frage", evidenceIDs: [e1, e3],
                                   answerText: "Antwort [1] und [3].", citationNumbers: [1: e1, 3: e3])
        try await store.save(trails: [trail])
        let loaded = try #require(try await store.trails().first)
        #expect(loaded.answerText == "Antwort [1] und [3].")
        #expect(loaded.citationNumbers == [1: e1, 3: e3])
        // Löschen heisst: nicht mehr in der Liste, die gespeichert wird.
        try await store.save(trails: [])
        #expect(try await store.trails().isEmpty)
    }
}

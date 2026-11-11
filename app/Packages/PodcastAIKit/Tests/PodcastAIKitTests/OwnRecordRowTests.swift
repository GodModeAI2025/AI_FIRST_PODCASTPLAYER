//
//  OwnRecordRowTests.swift
//  PodcastAIKitTests
//
//  Themen-Updates, gesicherte Antworten und gemerkte Stellen werden je Zeile
//  geschrieben. Bis 1.2 nahm der Store die ganze Liste aus dem Speicher der
//  App und löschte, was darin fehlte, auch die Zeile, die gerade über iCloud
//  von einem anderen Gerät gekommen war.
//
//  Ein zweiter Kontext spielt das andere Gerät, wie der Abgleich mit iCloud.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Selbst Angelegtes je Zeile")
struct OwnRecordRowTests {

    // MARK: Bausteine

    private func makeStore() throws -> LibraryStore {
        LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
    }

    private func note(_ name: String, _ text: String) -> Highlight {
        Highlight(evidenceID: EvidenceID(stable: name), note: text, quote: "Zitat \(name)")
    }

    private func trail(_ name: String) -> KnowledgeTrail {
        KnowledgeTrail(question: "Frage \(name)", evidenceIDs: [EvidenceID(stable: name), EvidenceID(stable: "zweite")],
                       answerText: "Antwort \(name)")
    }

    private func feed(_ title: String) -> SmartPodcastFeed {
        SmartPodcastFeed(title: title, topicIDs: [InterestID(rawValue: "tag")])
    }

    /// Eine Zeile ohne Prüfung auf Doppelte, wie sie der Abgleich bringt.
    private func insert(_ highlight: Highlight, into context: ModelContext) throws {
        let row = StoredHighlight(identifier: highlight.id.rawValue, evidenceIdentifier: highlight.evidenceID.rawValue)
        row.note = highlight.note
        row.createdAt = highlight.capturedAt
        row.payload = try LibraryStore.encoder.encode(highlight)
        context.insert(row)
    }

    private func insert(_ trail: KnowledgeTrail, into context: ModelContext) throws {
        context.insert(StoredKnowledgeTrail(
            identifier: trail.id.rawValue, question: trail.question, parkedAt: trail.parkedAt,
            payload: try LibraryStore.encoder.encode(trail)))
    }

    private func insert(_ feed: SmartPodcastFeed, into context: ModelContext) throws {
        context.insert(StoredSmartFeed(
            identifier: feed.id.rawValue, title: feed.title, payload: try LibraryStore.encoder.encode(feed)))
    }

    // MARK: Sichern löscht nichts

    @Test("Was ein anderes Gerät angelegt hat, übersteht das Sichern einer Liste, die es noch nicht kennt")
    func rowsFromElsewhereSurviveAStaleSave() async throws {
        let store = try makeStore()
        var ownNote = note("hier", "alt")
        let ownTrail = trail("hier")
        var ownFeed = feed("Hier")
        try await store.save(highlights: [ownNote])
        try await store.save(trails: [ownTrail])
        try await store.save(smartFeeds: [ownFeed])

        // Vom iPhone kommt je eine Zeile. Die Listen im Speicher des Macs
        // kennen sie noch nicht.
        let foreignNote = note("dort", "vom iPhone"), foreignTrail = trail("dort"), foreignFeed = feed("Dort")
        let context = ModelContext(store.modelContainer)
        try insert(foreignNote, into: context)
        try insert(foreignTrail, into: context)
        try insert(foreignFeed, into: context)
        try context.save()

        // Jemand ändert auf dem Mac etwas, und der schreibt, was er kennt.
        ownNote.note = "neu"
        ownFeed.title = "Hier, umbenannt"
        try await store.save(highlights: [ownNote])
        try await store.save(trails: [ownTrail])
        try await store.save(smartFeeds: [ownFeed])

        let notes = try await store.highlights()
        #expect(Set(notes.map(\.id)) == [ownNote.id, foreignNote.id])
        #expect(notes.first { $0.id == ownNote.id }?.note == "neu")
        #expect(notes.first { $0.id == foreignNote.id }?.note == "vom iPhone")
        #expect(Set(try await store.trails().map(\.id)) == [ownTrail.id, foreignTrail.id])
        let feeds = try await store.smartFeeds()
        #expect(Set(feeds.map(\.id)) == [ownFeed.id, foreignFeed.id])
        #expect(feeds.first { $0.id == ownFeed.id }?.title == "Hier, umbenannt")
    }

    // MARK: Löschen und Ändern treffen jede Kopie

    @Test("Ausdrückliches Löschen nimmt jede Kopie der Zeile mit, andere Zeilen bleiben")
    func removingDeletesEveryCopy() async throws {
        let store = try makeStore()
        let goneNote = note("weg", "weg"), keptNote = note("bleibt", "bleibt")
        let goneTrail = trail("weg"), keptTrail = trail("bleibt")
        let goneFeed = feed("Weg"), keptFeed = feed("Bleibt")
        try await store.save(highlights: [goneNote, keptNote])
        try await store.save(trails: [goneTrail, keptTrail])
        try await store.save(smartFeeds: [goneFeed, keptFeed])
        // Dieselben Zeilen noch einmal, wie nach einem Abgleich zweier Geräte.
        let context = ModelContext(store.modelContainer)
        try insert(goneNote, into: context)
        try insert(goneTrail, into: context)
        try insert(goneFeed, into: context)
        try context.save()
        #expect(try await store.rowCountForTesting(StoredHighlight.self) == 3)

        try await store.removeHighlight(goneNote.id)
        try await store.removeTrail(goneTrail.id)
        try await store.removeSmartFeed(goneFeed.id)

        #expect(try await store.rowCountForTesting(StoredHighlight.self) == 1)
        #expect(try await store.rowCountForTesting(StoredKnowledgeTrail.self) == 1)
        #expect(try await store.rowCountForTesting(StoredSmartFeed.self) == 1)
        #expect(try await store.highlights().map(\.id) == [keptNote.id])
        #expect(try await store.trails().map(\.id) == [keptTrail.id])
        #expect(try await store.smartFeeds().map(\.id) == [keptFeed.id])
    }

    @Test("Eine Änderung steht danach in jeder Kopie der Zeile")
    func editingUpdatesEveryCopy() async throws {
        let store = try makeStore()
        var ownNote = note("doppelt", "alt")
        let ownTrail = trail("doppelt")
        var ownFeed = feed("Alt")
        try await store.save(highlights: [ownNote])
        try await store.save(trails: [ownTrail])
        try await store.save(smartFeeds: [ownFeed])
        let context = ModelContext(store.modelContainer)
        try insert(ownNote, into: context)
        try insert(ownTrail, into: context)
        try insert(ownFeed, into: context)
        try context.save()

        ownNote.note = "neu"
        ownFeed.title = "Neu"
        // Nach „Folge löschen“ verliert die Antwort einen Beleg und ihren Text.
        let pruned = try #require(ownTrail.removing(evidence: [EvidenceID(stable: "zweite")]))
        try await store.replace(highlights: [ownNote])
        try await store.replace(trails: [pruned])
        try await store.replace(smartFeeds: [ownFeed])

        let reader = ModelContext(store.modelContainer)
        let noteRows = try reader.fetch(FetchDescriptor<StoredHighlight>())
        #expect(noteRows.map(\.note) == ["neu", "neu"])
        let storedNotes = try noteRows.map { try LibraryStore.decoder.decode(Highlight.self, from: $0.payload ?? Data()) }
        #expect(storedNotes.map(\.note) == ["neu", "neu"])
        let trailRows = try reader.fetch(FetchDescriptor<StoredKnowledgeTrail>())
        let storedTrails = try trailRows.map { try LibraryStore.decoder.decode(KnowledgeTrail.self, from: $0.payload) }
        #expect(storedTrails.map(\.evidenceIDs) == [pruned.evidenceIDs, pruned.evidenceIDs])
        #expect(storedTrails.map(\.answerText) == [nil, nil])
        let feedRows = try reader.fetch(FetchDescriptor<StoredSmartFeed>())
        #expect(feedRows.map(\.title) == ["Neu", "Neu"])
        let storedFeeds = try feedRows.map { try LibraryStore.decoder.decode(SmartPodcastFeed.self, from: $0.payload) }
        #expect(storedFeeds.map(\.title) == ["Neu", "Neu"])
    }

    // MARK: Eine Änderung bringt nichts zurück

    @Test("Hat ein anderes Gerät die Zeile gelöscht, legt eine Änderung hier sie nicht wieder an")
    func editingDoesNotResurrectRowsDeletedElsewhere() async throws {
        let store = try makeStore()
        var ownNote = note("gelöscht", "alt")
        let ownTrail = trail("gelöscht")
        var ownFeed = feed("Alt")
        try await store.save(highlights: [ownNote])
        try await store.save(trails: [ownTrail])
        try await store.save(smartFeeds: [ownFeed])

        // Die Löschung vom iPhone ist in der Datenbank, die Liste im
        // Speicher des Macs zeigt die Zeilen noch.
        let context = ModelContext(store.modelContainer)
        for row in try context.fetch(FetchDescriptor<StoredHighlight>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<StoredKnowledgeTrail>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<StoredSmartFeed>()) { context.delete(row) }
        try context.save()

        ownNote.note = "neu"
        ownFeed.title = "Neu"
        try await store.replace(highlights: [ownNote])
        try await store.replace(trails: [ownTrail])
        try await store.replace(smartFeeds: [ownFeed])

        #expect(try await store.highlights().isEmpty)
        #expect(try await store.trails().isEmpty)
        #expect(try await store.smartFeeds().isEmpty)
    }
}

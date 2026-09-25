//
//  ForeignChangeTests.swift
//  PodcastAIKitTests
//
//  Eigenes Speichern gilt nicht als Änderung von woanders. Bis 0.11 lud die
//  App nach jedem eigenen Speichern die ganze Bibliothek neu.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIPersistence
import PodcastAICore

@Suite("Änderungen von woanders erkennen")
struct ForeignChangeTests {

    @Test("Eigenes Speichern zählt nicht, ein anderer Schreiber schon")
    func ownSavesAreNotForeign() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try LibraryStore.makeContainer(at: directory.appendingPathComponent("Library.store"))
        let store = LibraryStore.make(container: container)

        // Beim ersten Mal ist der Stand unbekannt.
        #expect(await store.hasForeignChanges())
        try await store.upsert(source: Source(id: SourceID(stable: "eigen"), kind: .podcastRSS, title: "Eigen"))
        #expect(await store.hasForeignChanges() == false)

        // Ein anderer Kontext ohne den Namen des Stores, wie der Abgleich mit iCloud.
        let other = ModelContext(container)
        other.author = "NSCloudKitMirroringDelegate.import"
        other.insert(StoredSource(identifier: SourceID(stable: "fremd").rawValue, kind: .podcastRSS, title: "Fremd"))
        try other.save()
        #expect(await store.hasForeignChanges())
        #expect(await store.hasForeignChanges() == false)
    }
}

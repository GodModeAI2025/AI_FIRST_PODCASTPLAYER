//
//  AbandonedDownloadTests.swift
//  PodcastAIKitTests
//
//  Beendet das System die App mitten in einem Download, bleibt die halbe
//  Datei im Zwischenordner liegen. Der nächste `MediaDownloader` räumt sie
//  weg, aber nur, wenn lange niemand mehr daran geschrieben hat: was ein
//  anderer gerade lädt, bleibt.
//

import Testing
import Foundation
@testable import PodcastAIMedia

@Suite("Reste abgebrochener Downloads")
struct AbandonedDownloadTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AbandonedDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Eine Datei, an der seit `age` Sekunden niemand geschrieben hat.
    private func file(_ name: String, in directory: URL, age: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    @Test("Ein alter Rest verschwindet, ein laufender Download und fertige Folgen bleiben")
    func removesOnlyStaleLeftovers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = directory.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let timeout = MediaDownloader.resourceTimeout
        let stale = try file("alt.0001", in: incoming, age: timeout + 60)
        let active = try file("laeuft.0002", in: incoming, age: timeout - 60)
        // Eine fertige Folge liegt eine Ebene höher. Ihr Alter spielt keine Rolle.
        let finished = try file("fertig", in: directory, age: 30 * 24 * 3600)

        _ = MediaDownloader(directory: directory)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: finished.path))
    }

    @Test("Ohne Zwischenordner gibt es nichts aufzuräumen")
    func missingDirectoryIsFine() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Noch nicht angelegt: der Ordner entsteht leer.
        let fresh = directory.appendingPathComponent("Media", isDirectory: true)
        _ = MediaDownloader(directory: fresh)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.appendingPathComponent("incoming").path).isEmpty)

        // Lässt sich nicht anlegen, weil an der Stelle eine Datei liegt.
        let blocked = try file("belegt", in: directory, age: 2 * MediaDownloader.resourceTimeout)
        _ = MediaDownloader(directory: blocked)
        #expect(FileManager.default.fileExists(atPath: blocked.path))
    }
}

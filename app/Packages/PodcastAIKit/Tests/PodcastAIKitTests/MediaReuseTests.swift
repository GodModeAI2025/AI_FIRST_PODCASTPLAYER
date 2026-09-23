//
//  MediaReuseTests.swift
//  PodcastAIKitTests
//
//  Eine Datei, die schon auf dem Gerät liegt, etwa nach „Laden (offline)“,
//  wird beim Auswerten nicht ein zweites Mal geladen.
//

import Testing
import Foundation
import CryptoKit
@testable import PodcastAIKit

@Suite("Geladene Datei wiederverwenden")
struct MediaReuseTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaReuseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Eine vorhandene Datei liefert Grösse und Hash ohne Anfrage")
    func existingFileIsReused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MediaVersionID(stable: "https://example.invalid/folge.mp3")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: directory.appendingPathComponent(id.rawValue))

        let result = await MediaDownloader(directory: directory).existing(mediaVersionID: id)

        let found = try #require(result)
        #expect(found.byteCount == Int64(bytes.count))
        #expect(found.localRelativePath == id.rawValue)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(found.contentHash == expected)
    }

    @Test("Ohne Datei gibt es nichts wiederzuverwenden")
    func missingFileIsNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MediaVersionID(stable: "https://example.invalid/fehlt.mp3")
        #expect(await MediaDownloader(directory: directory).existing(mediaVersionID: id) == nil)
    }

    @Test("Eine leere Datei zählt nicht als geladen")
    func emptyFileIsNil() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = MediaVersionID(stable: "https://example.invalid/leer.mp3")
        try Data().write(to: directory.appendingPathComponent(id.rawValue))
        #expect(await MediaDownloader(directory: directory).existing(mediaVersionID: id) == nil)
    }
}

//
//  PlayerSchemaParityTests.swift
//
//  Das schmale Modell des Players (`PodcastAIPlayerKit`) muss auf dem
//  CloudKit-Schema der Hauptapp liegen: dieselben Entitäten, dieselben
//  Eigenschaften, Typen und Standardwerte. Und der Player darf weder KI-Module
//  noch Apple-Intelligence-, Sprach- oder Bild-Frameworks einbinden.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIPlayerKit
import PodcastAIPersistence

@Suite("Player: Schema und Abhängigkeiten")
struct PlayerSchemaParityTests {

    private func entity(_ name: String, in schema: Schema) throws -> Schema.Entity {
        try #require(schema.entities.first { $0.name == name })
    }

    @Test(arguments: ["StoredSource", "StoredEpisode", "StoredListeningState"])
    func everyPlayerPropertyMatchesTheMainSchema(name: String) throws {
        let player = try entity(name, in: PlayerLibrary.schema)
        let main = try entity(name, in: LibraryStore.schema)

        #expect(Set(player.attributes.map(\.name)) == Set(main.attributes.map(\.name)),
                "\(name): Eigenschaften weichen vom Hauptschema ab")
        for attribute in player.attributes {
            let counterpart = try #require(main.attributes.first { $0.name == attribute.name })
            #expect(String(describing: attribute.valueType) == String(describing: counterpart.valueType),
                    "\(name).\(attribute.name): anderer Typ")
            #expect(String(describing: attribute.defaultValue) == String(describing: counterpart.defaultValue),
                    "\(name).\(attribute.name): anderer Standardwert")
            #expect(String(describing: attribute.options) == String(describing: counterpart.options),
                    "\(name).\(attribute.name): andere Optionen")
        }
        // Beziehungen: höchstens die, die es im Hauptschema auch gibt, mit
        // gleichem Ziel, gleicher Löschregel und gleicher Gegenseite.
        for relationship in player.relationships {
            let counterpart = try #require(main.relationships.first { $0.name == relationship.name })
            #expect(relationship.destination == counterpart.destination)
            #expect(relationship.deleteRule == counterpart.deleteRule)
            #expect(relationship.inverseName == counterpart.inverseName)
            #expect(relationship.isToOneRelationship == counterpart.isToOneRelationship)
        }
    }

    @Test func thePlayerKnowsOnlyThreeEntities() {
        #expect(Set(PlayerLibrary.schema.entities.map(\.name))
                == ["StoredSource", "StoredEpisode", "StoredListeningState"])
    }

    // MARK: Keine KI im Player

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let forbiddenImports = [
        "FoundationModels", "Speech", "Vision", "NaturalLanguage", "CoreML", "AppIntents",
        "PodcastAIIntelligence", "PodcastAIKnowledge", "PodcastAITranscription",
        "PodcastAISmartFeeds", "PodcastAIPersistence", "PodcastAIExport", "PodcastAIPlayback",
        "PodcastAIKit", "PodcastAIShareInbox", "PodcastAIWidgetData",
    ]

    private func imports(inTarget target: String) throws -> Set<String> {
        let directory = Self.packageRoot.appending(path: "Sources/\(target)")
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var result: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@_exported import ")
                    || trimmed.hasPrefix("@preconcurrency import ") else { continue }
                if let module = trimmed.split(separator: " ").last { result.insert(String(module)) }
            }
        }
        return result
    }

    /// Das Player-Ziel und alles, woran es hängt, bleibt frei von KI-,
    /// Sprach- und Bildmodulen.
    @Test(arguments: ["PodcastAIPlayerKit", "PodcastAICore", "PodcastAISources", "PodcastAIMedia"])
    func playerClosureImportsNoAIOrSpeechOrVision(target: String) throws {
        let found = try imports(inTarget: target)
        let bad = found.intersection(Self.forbiddenImports)
        #expect(bad.isEmpty, "\(target) bindet \(bad.sorted()) ein")
    }

    @Test func theManifestKeepsPlayerKitOnCoreSourcesAndMedia() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appending(path: "Package.swift"), encoding: .utf8)
        let start = try #require(manifest.range(of: #".target(name: "PodcastAIPlayerKit""#))
        let block = manifest[start.lowerBound...].prefix { $0 != "]" }
        for allowed in ["PodcastAICore", "PodcastAISources", "PodcastAIMedia"] {
            #expect(block.contains("\"\(allowed)\""))
        }
        for forbidden in ["Intelligence", "Knowledge", "Transcription", "Persistence", "Playback", "SmartFeeds"] {
            #expect(!block.contains(forbidden), "PlayerKit darf nicht an \(forbidden) hängen")
        }
    }
}

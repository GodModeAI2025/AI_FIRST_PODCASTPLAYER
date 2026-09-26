//
//  WidgetSnapshotStore.swift
//  PodcastAIWidgetData
//
//  Die Datei des Schnappschusses im Ordner der App Group:
//  `Widget/snapshot.json`. Geschrieben wird am Stück über eine Kopie, damit
//  das Widget nie eine halbe Datei liest.
//
//  Kein eigener Dateischutz: Die Voreinstellung macht die Datei nach dem
//  ersten Entsperren lesbar, und das braucht ein Widget auf dem
//  Sperrbildschirm.
//

import Foundation

public struct WidgetSnapshotStore: Sendable {

    public let fileURL: URL

    /// - Parameter directory: der Ordner der App Group oder, in Tests, ein
    ///   eigener Ordner.
    public init(directory: URL) {
        fileURL = directory
            .appending(path: "Widget", directoryHint: .isDirectory)
            .appending(path: "snapshot.json", directoryHint: .notDirectory)
    }

    /// Die Datei im Ordner der App Group, `nil` ohne Berechtigung.
    public static func appGroup(fileManager: FileManager = .default) -> WidgetSnapshotStore? {
        AppGroup.containerURL(fileManager: fileManager).map(WidgetSnapshotStore.init(directory:))
    }

    /// Der gespeicherte Schnappschuss. `nil`, wenn es keinen gibt oder er
    /// sich nicht lesen lässt.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// Das JSON, wie es in der Datei steht.
    public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    /// Datumswerte in der Voreinstellung, als Sekunden seit 2001. Sie
    /// kommen genau so zurück, wie sie geschrieben wurden; mit ISO 8601
    /// fielen die Bruchteile weg, und jeder Vergleich mit der Datei hielte
    /// dieselbe Ausgabe für eine andere.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}

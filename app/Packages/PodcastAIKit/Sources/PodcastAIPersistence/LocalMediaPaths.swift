//
//  LocalMediaPaths.swift
//  PodcastAIPersistence
//
//  Wo die Audiodatei einer Fassung auf diesem Gerät liegt, je Gerät in
//  `DeviceState` statt in der Datenbank.
//
//  Bis 0.14 stand der Pfad in `StoredMediaVersion.localRelativePath` und
//  kam über iCloud auf jedes andere Gerät, wo er nichts bedeutete: Dort liegt
//  die Datei nicht, oder unter einem anderen Pfad. Seit dem Schema nach 0.14
//  schreibt die App das Feld nicht mehr. Es bleibt im Modell, damit ältere
//  Fassungen der App ihre Zeilen weiter lesen und schreiben können
//  (CloudKit-Regel: nichts entfernen, nichts umbenennen).
//
//  Beim ersten Start nach dem Update zieht jeder Pfad hierher um, dessen
//  Datei auf diesem Gerät tatsächlich liegt (``migrate(from:fileExists:)``).
//  Das alte Feld wird dabei nicht geleert, denn auch Leeren wäre ein
//  Schreiben, das über iCloud an alle Geräte ginge.
//

import Foundation
import PodcastAICore

public struct LocalMediaPaths: Sendable {

    /// Der Name der Datei in `DeviceState`.
    public static let key = "localMediaPaths"
    /// Merkt sich, dass die alten Pfade aus der Datenbank umgezogen sind.
    public static let migratedKey = "localMediaPathsMigrated"

    public let state: DeviceState

    public init(state: DeviceState) {
        self.state = state
    }

    /// Der Pfad der Datei relativ zum Audioordner, falls sie hier geladen wurde.
    public func path(for id: MediaVersionID) -> String? {
        state.value([String: String].self, for: Self.key)?[id.rawValue]
    }

    /// Alle gemerkten Pfade.
    public var all: [MediaVersionID: String] {
        let stored = state.value([String: String].self, for: Self.key) ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.map { (MediaVersionID(rawValue: $0.key), $0.value) })
    }

    /// Merkt den Pfad einer frisch geladenen oder wiederverwendeten Datei.
    public func record(_ path: String, for id: MediaVersionID) {
        guard !path.isEmpty else { return }
        state.update([String: String].self, for: Self.key) { paths in
            var next = paths ?? [:]
            next[id.rawValue] = path
            paths = next
        }
    }

    /// Vergisst die Pfade dieser Fassungen: nach „Audio entfernen“ und
    /// nach „Folge löschen“ (Regel 5).
    public func forget(_ ids: some Sequence<MediaVersionID>) {
        let keys = Set(ids.map(\.rawValue))
        guard !keys.isEmpty else { return }
        state.update([String: String].self, for: Self.key) { paths in
            guard var next = paths else { return }
            for key in keys { next[key] = nil }
            paths = next.isEmpty ? nil : next
        }
    }

    /// Einmal je Gerät: übernimmt die alten Pfade aus der Datenbank, deren
    /// Datei hier liegt. `true`, wenn die Übernahme jetzt gelaufen ist.
    ///
    /// Lässt sich `DeviceState` gerade nicht lesen, etwa vor dem ersten
    /// Entsperren, läuft nichts, und der nächste Start versucht es wieder.
    @discardableResult
    public func migrate(from store: LibraryStore, fileExists: @Sendable (String) -> Bool) async -> Bool {
        switch state.lookup(Bool.self, for: Self.migratedKey) {
        case .found(true), .unreadable: return false
        case .found(false), .absent: break
        }
        if case .unreadable = state.lookup([String: String].self, for: Self.key) { return false }
        guard let legacy = try? await store.legacyLocalRelativePaths() else { return false }
        let present = legacy.filter { fileExists($0.value) }
        let changed = state.update([String: String].self, for: Self.key) { paths in
            var next = paths ?? [:]
            // Ein schon gemerkter Pfad dieses Geräts gilt vor dem alten Feld.
            for (id, path) in present where next[id.rawValue] == nil { next[id.rawValue] = path }
            paths = next.isEmpty ? nil : next
        }
        guard changed else { return false }
        state.set(true, for: Self.migratedKey)
        return true
    }
}

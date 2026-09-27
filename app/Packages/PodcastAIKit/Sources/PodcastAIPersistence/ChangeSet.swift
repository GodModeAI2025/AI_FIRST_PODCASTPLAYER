//
//  ChangeSet.swift
//  PodcastAIPersistence
//
//  Was ein anderes Gerät geändert hat, gelesen aus der Historie der
//  Datenbank (Plan „Löschen und Sync“, Phase 2).
//
//  Bis 0.13 hieß jede Änderung von woanders: alles neu laden, alles
//  bereinigen, jede Stufe gleicht mit der ganzen Bibliothek ab. Jetzt sagt
//  die Historie, welche Arten von Zeilen sich geändert haben und, soweit
//  sich das sicher sagen lässt, welche Kennungen, Folgen und Quellen. Wer
//  daraus liest, muss mit „unbekannt“ rechnen und dann so handeln, als hätte
//  sich alles dieser Art geändert.
//
//  Gelöschte Zeilen tragen keine Kennung. Das ginge nur mit
//  `preserveValueOnDeletion`, und das ändert den Hash des Modells und damit
//  das Schema. In dieser Release gibt es keine Schemaänderung
//  (Entscheidung 11). Eine Löschung macht deshalb Kennungen, Folgen und
//  Quellen ihrer Art unbekannt.
//

import Foundation
import PodcastAICore

public struct ChangeSet: Sendable, Hashable {

    /// Die Arten von Zeilen in der Datenbank, eine je Modell.
    public enum Entity: String, Sendable, Hashable, CaseIterable {
        case source, episode, mediaVersion, transcript, segment, listeningState, interest
        case evidence, highlight, smartFeed, personalEpisode, trail, fact, chapterTag
    }

    /// Was sich an Zeilen einer Art geändert hat.
    public struct Rows: Sendable, Hashable {
        public internal(set) var inserted = 0
        public internal(set) var updated = 0
        public internal(set) var deleted = 0
        /// Die Kennungen (`identifier`) der eingefügten und geänderten Zeilen,
        /// die es noch gibt. `nil`, wenn sie sich nicht sicher sagen lassen,
        /// etwa bei sehr vielen Zeilen.
        public internal(set) var identifiers: Set<String>? = []

    /// Für Tests und Aufrufer, die eine Änderung selbst beschreiben.
    public init(inserted: Int = 0, updated: Int = 0, deleted: Int = 0, identifiers: Set<String>? = []) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
        self.identifiers = identifiers
    }

        mutating func formUnion(_ other: Rows) {
            inserted += other.inserted
            updated += other.updated
            deleted += other.deleted
            identifiers = ChangeSet.union(identifiers, other.identifiers)
        }
    }

    /// Alles kann sich geändert haben: beim ersten Blick in die Historie
    /// nach dem Start, wenn sie sich nicht lesen lässt, oder bei Zeilen, die
    /// dieser Code nicht kennt.
    public private(set) var isEverything: Bool
    public private(set) var rows: [Entity: Rows]
    /// Folgen, an denen oder unter denen sich etwas geändert hat. `nil`:
    /// unbekannt, etwa nach einer Löschung.
    public private(set) var episodeIDs: Set<EpisodeID>?
    /// Quellen, deren Zeile oder deren Folgen sich geändert haben. `nil`:
    /// unbekannt.
    public private(set) var sourceIDs: Set<SourceID>?

    /// Alles hat sich geändert.
    public static let all = ChangeSet(isEverything: true)
    /// Nichts hat sich geändert.
    public static let none = ChangeSet(isEverything: false)

    init(isEverything: Bool, rows: [Entity: Rows] = [:],
         episodeIDs: Set<EpisodeID>? = [], sourceIDs: Set<SourceID>? = []) {
        self.isEverything = isEverything
        self.rows = isEverything ? [:] : rows
        self.episodeIDs = isEverything ? nil : episodeIDs
        self.sourceIDs = isEverything ? nil : sourceIDs
    }

    /// Für Tests und Aufrufer, die eine Änderung selbst beschreiben.
    public init(rows: [Entity: Rows], episodeIDs: Set<EpisodeID>? = [], sourceIDs: Set<SourceID>? = []) {
        self.init(isEverything: false, rows: rows.filter { !$0.value.isEmpty },
                  episodeIDs: episodeIDs, sourceIDs: sourceIDs)
    }

    /// Hat sich gar nichts geändert?
    public var isEmpty: Bool { !isEverything && rows.isEmpty }

    /// Hat sich an einer dieser Arten etwas geändert, eingefügt, geändert
    /// oder gelöscht? Bei ``all`` immer ja.
    public func touches(_ entities: Entity...) -> Bool { touches(entities) }

    public func touches(_ entities: [Entity]) -> Bool {
        isEverything || entities.contains { rows[$0] != nil }
    }

    /// Wurden Zeilen dieser Art gelöscht? Bei ``all`` immer ja.
    public func deletes(_ entity: Entity) -> Bool {
        isEverything || (rows[entity]?.deleted ?? 0) > 0
    }

    /// Die Kennungen eingefügter oder geänderter Zeilen dieser Art. `nil`
    /// heißt: alle Zeilen dieser Art können betroffen sein.
    public func identifiers(of entity: Entity) -> Set<String>? {
        guard !isEverything else { return nil }
        guard let changed = rows[entity] else { return [] }
        return changed.identifiers
    }

    /// Nimmt eine zweite Änderung auf, etwa eine weitere Meldung während der
    /// Pause vor dem Neuladen.
    public mutating func formUnion(_ other: ChangeSet) {
        guard !isEverything else { return }
        guard !other.isEverything else {
            self = .all
            return
        }
        for (entity, changed) in other.rows { rows[entity, default: Rows()].formUnion(changed) }
        episodeIDs = Self.union(episodeIDs, other.episodeIDs)
        sourceIDs = Self.union(sourceIDs, other.sourceIDs)
    }

    public func union(_ other: ChangeSet) -> ChangeSet {
        var result = self
        result.formUnion(other)
        return result
    }

    /// Das Bereinigen hat Folgen gelöscht oder umgehängt. Welche Quellen
    /// davon betroffen sind, weiß danach niemand sicher: Folgen und Quellen
    /// gelten dann als unbekannt geändert.
    public func widened(by report: LibraryStore.RemovalReport) -> ChangeSet {
        guard !isEverything, !report.isEmpty else { return self }
        var result = self
        for entity in [Entity.episode, .mediaVersion, .evidence, .fact, .chapterTag] {
            result.rows[entity, default: Rows()].deleted += 1
            result.rows[entity]?.identifiers = nil
        }
        result.episodeIDs = nil
        result.sourceIDs = nil
        return result
    }

    static func union<T: Hashable>(_ lhs: Set<T>?, _ rhs: Set<T>?) -> Set<T>? {
        guard let lhs, let rhs else { return nil }
        return lhs.union(rhs)
    }
}

extension ChangeSet.Rows {
    public var isEmpty: Bool { inserted == 0 && updated == 0 && deleted == 0 }
}

extension LibraryStore.RemovalReport {
    public var isEmpty: Bool { mediaVersionIDs.isEmpty && evidenceIDs.isEmpty && episodeIDs.isEmpty }
}

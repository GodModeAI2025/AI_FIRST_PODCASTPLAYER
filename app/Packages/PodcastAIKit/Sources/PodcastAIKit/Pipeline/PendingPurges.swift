//
//  PendingPurges.swift
//  PodcastAIKit
//
//  Angefangenes Löschen, gemerkt auf diesem Gerät, bis das Aufräumen fertig
//  ist (Plan „Löschen und Sync“, Schritt 2 und 5).
//
//  „Folge löschen“ und „Quelle abbestellen“ laufen in dieser Reihenfolge:
//  im Löschprotokoll markieren, hier vermerken, `episodesRemoved` senden,
//  den Vermerk auf die Platte bringen, im Store löschen, aufräumen, den
//  Vermerk streichen. Endet die App mittendrin, setzt der nächste Start das
//  Aufräumen fort: Dateien, Zwischenspeicher und die Einträge der Folge in
//  `DeviceState`. Ohne den Vermerk blieben sie für immer liegen, bei einer
//  abbestellten Quelle erst recht, denn sie hinterlässt kein Merkzeichen.
//
//  Die Liste steht unter einem eigenen Schlüssel. Lässt sich ihre Datei
//  gerade nicht lesen, etwa vor dem ersten Entsperren, ändert niemand sie,
//  und das Aufräumen wartet.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

/// Ein Löschen, dessen Aufräumen noch nicht fertig ist.
public struct PendingPurge: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let requestedAt: Date
    public let scope: RemovalScope
    /// Alle Folgen, die verschwinden.
    public var episodeIDs: [EpisodeID]
    /// Die Folgen, die der Store löschen soll. Bei „Folge löschen“ die Folge
    /// selbst, bei einer Löschung von einem anderen Gerät nur die, zu denen
    /// dieses Gerät etwas erschlossen hat. Eine abbestellte Quelle löscht
    /// der Store über ihre Kennung.
    public var storeEpisodeIDs: [EpisodeID]
    /// Fassungen, unter denen Dateien der Folgen liegen können.
    public var mediaVersionIDs: [MediaVersionID]
    /// Belege, die der Store gelöscht hat. Antworten und Pfade, die sie
    /// zitieren, gehen mit.
    public var evidenceIDs: [EvidenceID]
    /// Schlüssel der Metadaten über Supadata.
    public var metadataKeys: [String]
    /// Erkannte Tags aus einer angefangenen Einordnung der Folgen.
    public var detectedTagIDs: [InterestID]
    /// Hat der Store schon gelöscht?
    public var storeDone: Bool

    public init(
        id: UUID = UUID(), requestedAt: Date = Date(), scope: RemovalScope,
        episodeIDs: [EpisodeID], storeEpisodeIDs: [EpisodeID] = [],
        mediaVersionIDs: [MediaVersionID] = [], metadataKeys: [String] = [],
        detectedTagIDs: [InterestID] = []
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.scope = scope
        self.episodeIDs = episodeIDs
        self.storeEpisodeIDs = storeEpisodeIDs
        self.mediaVersionIDs = mediaVersionIDs
        self.evidenceIDs = []
        self.metadataKeys = metadataKeys
        self.detectedTagIDs = detectedTagIDs
        self.storeDone = false
    }

    /// Trägt ein, was der Store gelöscht hat.
    public mutating func recordStoreRemoval(_ report: LibraryStore.RemovalReport) {
        storeDone = true
        episodeIDs = Self.union(episodeIDs, report.episodeIDs)
        mediaVersionIDs = Self.union(mediaVersionIDs, report.mediaVersionIDs)
        evidenceIDs = Self.union(evidenceIDs, report.evidenceIDs)
    }

    private static func union<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> [T] {
        var seen = Set(lhs)
        return lhs + rhs.filter { seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestedAt, scope, episodeIDs, storeEpisodeIDs, mediaVersionIDs
        case evidenceIDs, metadataKeys, detectedTagIDs, storeDone
    }

    /// Liest auch Einträge, denen ein später hinzugekommenes Feld fehlt.
    /// Ein Eintrag, der sich nicht lesen lässt, nähme sonst die ganze Liste mit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        scope = try container.decode(RemovalScope.self, forKey: .scope)
        episodeIDs = try container.decodeIfPresent([EpisodeID].self, forKey: .episodeIDs) ?? []
        storeEpisodeIDs = try container.decodeIfPresent([EpisodeID].self, forKey: .storeEpisodeIDs) ?? []
        mediaVersionIDs = try container.decodeIfPresent([MediaVersionID].self, forKey: .mediaVersionIDs) ?? []
        evidenceIDs = try container.decodeIfPresent([EvidenceID].self, forKey: .evidenceIDs) ?? []
        metadataKeys = try container.decodeIfPresent([String].self, forKey: .metadataKeys) ?? []
        detectedTagIDs = try container.decodeIfPresent([InterestID].self, forKey: .detectedTagIDs) ?? []
        storeDone = try container.decodeIfPresent(Bool.self, forKey: .storeDone) ?? false
    }
}

/// Die offenen Löschungen in `DeviceState`.
public struct PendingPurges: Sendable {

    public static let key = "pendingPurges"

    public let state: DeviceState

    public init(state: DeviceState = .shared) {
        self.state = state
    }

    /// Alle offenen Löschungen, älteste zuerst. `nil`, wenn sich die Datei
    /// gerade nicht lesen lässt. Dann wartet das Aufräumen.
    public func all() -> [PendingPurge]? {
        switch state.lookup([PendingPurge].self, for: Self.key) {
        case .found(let list): list
        case .absent: []
        case .unreadable: nil
        }
    }

    /// Vermerkt eine Löschung. `false`, wenn sich die Liste gerade nicht
    /// lesen lässt; sie bleibt dann, wie sie ist.
    @discardableResult
    public func add(_ purge: PendingPurge) -> Bool {
        state.update([PendingPurge].self, for: Self.key) { list in
            var entries = list ?? []
            entries.removeAll { $0.id == purge.id }
            entries.append(purge)
            list = entries
        }
    }

    /// Ändert einen Vermerk, falls es ihn noch gibt.
    @discardableResult
    public func update(_ id: UUID, _ change: (inout PendingPurge) -> Void) -> Bool {
        state.update([PendingPurge].self, for: Self.key) { list in
            guard var entries = list, let index = entries.firstIndex(where: { $0.id == id }) else { return }
            change(&entries[index])
            list = entries
        }
    }

    /// Streicht einen Vermerk, wenn das Aufräumen fertig ist.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        state.update([PendingPurge].self, for: Self.key) { list in
            guard var entries = list else { return }
            entries.removeAll { $0.id == id }
            list = entries.isEmpty ? nil : entries
        }
    }

    /// Wartet, bis die Vermerke auf der Platte liegen, ohne zu blockieren.
    public func waitUntilWritten() async {
        await state.waitUntilWritten()
    }
}

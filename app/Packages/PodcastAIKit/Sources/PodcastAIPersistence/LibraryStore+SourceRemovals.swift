//
//  LibraryStore+SourceRemovals.swift
//  PodcastAIPersistence
//
//  Das Merkzeichen „Quelle abbestellt“ (`StoredSourceRemoval`): schreiben
//  beim Abbestellen, lesen nach einem Abgleich, löschen beim neuen Abo.
//
//  Ein Merkzeichen gilt für eine Quellzeile, die vor ihm angelegt wurde
//  (`addedAt <= removedAt`). Eine Zeile, die danach entstand, ist ein neues
//  Abo und bleibt. Neu abonniert wird nur über ``upsert(source:)``, und das
//  räumt die Merkzeichen der Quelle weg. Das Aktualisieren eines Feeds
//  schreibt über ``updateFeedMetadata(of:)`` und legt keine Quelle an.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore

/// Eine Abbestellung, wie sie in der Datenbank steht.
public struct SourceRemoval: Sendable, Equatable {
    public let sourceID: SourceID
    public let removedAt: Date
    public let deviceID: String?
}

extension LibraryStore {

    /// Alle Merkzeichen, je Quelle das jüngste.
    public func sourceRemovals() throws -> [SourceRemoval] {
        var newest: [String: StoredSourceRemoval] = [:]
        for row in try modelContext.fetch(FetchDescriptor<StoredSourceRemoval>()) where !row.sourceIdentifier.isEmpty {
            if let known = newest[row.sourceIdentifier], known.removedAt >= row.removedAt { continue }
            newest[row.sourceIdentifier] = row
        }
        return newest.values
            .map { SourceRemoval(sourceID: SourceID(rawValue: $0.sourceIdentifier), removedAt: $0.removedAt,
                                 deviceID: $0.deviceIdentifier) }
            .sorted { $0.sourceID.rawValue < $1.sourceID.rawValue }
    }

    /// Die Quellen, deren Abbestellung dieses Gerät noch nachholen muss:
    /// Es gibt eine Quellzeile von vor dem Merkzeichen, oder Belege, Fakten
    /// oder Kapitel-Tags der Quelle, deren Folge nicht unter einer anderen
    /// Quelle weiterlebt. Wiederholt sich beliebig oft, und nach dem
    /// Nachholen ist die Liste leer.
    public func sourceRemovalsToApply() throws -> [SourceID] {
        var result: [SourceID] = []
        for removal in try sourceRemovals() where try hasRemains(of: removal) {
            result.append(removal.sourceID)
        }
        return result
    }

    /// Hält die Datenbank noch etwas von einer abbestellten Quelle?
    private func hasRemains(of removal: SourceRemoval) throws -> Bool {
        let key = removal.sourceID.rawValue
        let removedAt = removal.removedAt
        let rows = try modelContext.fetchCount(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.identifier == key && $0.addedAt <= removedAt }))
        if rows > 0 { return true }
        // Lebt die Quelle als neues Abo, gehört alles ihr.
        let newer = try modelContext.fetchCount(FetchDescriptor<StoredSource>(
            predicate: #Predicate { $0.identifier == key }))
        if newer > 0 { return false }
        return !(try orphanedEpisodeKeys(ofSource: key)).isEmpty
    }

    /// Folgen, die laut Belegen, Fakten oder Kapitel-Tags zu dieser Quelle
    /// gehören, aber an keiner lebenden Quelle hängen. Das bleibt, wenn die
    /// Löschung der Quelle hier ankam, bevor dieses Gerät fertig war.
    func orphanedEpisodeKeys(ofSource key: String) throws -> Set<String> {
        var keys: Set<String> = []
        keys.formUnion(try modelContext.fetch(FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.sourceIdentifier == key })).map(\.episodeIdentifier))
        keys.formUnion(try modelContext.fetch(FetchDescriptor<StoredFact>(
            predicate: #Predicate { $0.sourceIdentifier == key })).map(\.episodeIdentifier))
        keys.formUnion(try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { $0.sourceIdentifier == key })).map(\.episodeIdentifier))
        keys.remove("")
        guard !keys.isEmpty else { return [] }
        // Folgen, die unter einer anderen Quelle weiterleben, bleiben.
        let candidates = keys
        let living = Set(try modelContext.fetch(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { candidates.contains($0.identifier) && $0.removedAt == nil && $0.source != nil }))
            .filter { $0.source?.identifier != key }
            .map(\.identifier))
        return keys.subtracting(living)
    }

    /// Schreibt das Merkzeichen beim Abbestellen.
    func recordSourceRemoval(_ sourceID: SourceID, at removedAt: Date, device: String?) {
        modelContext.insert(StoredSourceRemoval(
            sourceIdentifier: sourceID.rawValue, removedAt: removedAt, deviceIdentifier: device))
    }

    /// Ein neues Abo: Die Merkzeichen der Quelle gehen, und eine Quellzeile,
    /// die noch von vor der Abbestellung steht, gilt ab jetzt als neu
    /// angelegt. Sonst holte ein Abgleich die Abbestellung gleich wieder nach.
    func clearSourceRemovals(for identifier: String, rows: [StoredSource], now: Date = Date()) throws {
        let removals = try modelContext.fetch(FetchDescriptor<StoredSourceRemoval>(
            predicate: #Predicate { $0.sourceIdentifier == identifier }))
        guard let newest = removals.map(\.removedAt).max() else { return }
        for row in rows where row.addedAt <= newest { row.addedAt = max(now, newest.addingTimeInterval(1)) }
        for removal in removals { modelContext.delete(removal) }
    }

    /// Steht die Quellzeile unter einem Merkzeichen, das noch nachzuholen
    /// ist? Dann legt das Aktualisieren keine Folgen mehr an ihr an.
    func isAwaitingRemoval(_ source: StoredSource) throws -> Bool {
        let key = source.identifier
        let addedAt = source.addedAt
        return try modelContext.fetchCount(FetchDescriptor<StoredSourceRemoval>(
            predicate: #Predicate { $0.sourceIdentifier == key && $0.removedAt >= addedAt })) > 0
    }

    /// Bereinigen: je Quelle ein Merkzeichen, das jüngste. Merkzeichen, die
    /// älter sind als ein neues Abo derselben Quelle, sind erledigt.
    func settleSourceRemovals() throws {
        let rows = try modelContext.fetch(FetchDescriptor<StoredSourceRemoval>())
        guard !rows.isEmpty else { return }
        var bySource: [String: [StoredSourceRemoval]] = [:]
        for row in rows { bySource[row.sourceIdentifier, default: []].append(row) }
        var changed = false
        for (key, group) in bySource {
            let sorted = group.sorted { $0.removedAt > $1.removedAt }
            for extra in sorted.dropFirst() {
                modelContext.delete(extra)
                changed = true
            }
            guard let newest = sorted.first else { continue }
            if key.isEmpty {
                modelContext.delete(newest)
                changed = true
                continue
            }
            let removedAt = newest.removedAt
            let resubscribed = try modelContext.fetchCount(FetchDescriptor<StoredSource>(
                predicate: #Predicate { $0.identifier == key && $0.addedAt > removedAt }))
            let stale = try modelContext.fetchCount(FetchDescriptor<StoredSource>(
                predicate: #Predicate { $0.identifier == key && $0.addedAt <= removedAt }))
            if resubscribed > 0, stale == 0 {
                modelContext.delete(newest)
                changed = true
            }
        }
        if changed { try modelContext.save() }
    }

    /// Nur für Tests: ein Merkzeichen, wie es über iCloud ankäme.
    func insertSourceRemovalForTesting(_ sourceID: SourceID, at removedAt: Date, device: String?) throws {
        recordSourceRemoval(sourceID, at: removedAt, device: device)
        try modelContext.save()
    }
}
#endif

//
//  LibraryStore+Leases.swift
//  PodcastAIPersistence
//
//  Sperren über Geräte hinweg (`StoredProcessingLease`): nehmen,
//  verlängern, freigeben. Die Regel, wer gilt:
//
//    - Abgelaufene Sperren zählen nicht. Wer eine abgelaufene findet, auch
//      die eigene, nimmt die Sperre neu, mit frischem `acquiredAt`.
//    - Unter den gültigen gilt die älteste (`acquiredAt`), bei Gleichstand
//      die kleinere Gerätekennung. Jedes Gerät rechnet dasselbe, sobald es
//      beide Zeilen kennt.
//    - Verliert ein Gerät, löscht es seine eigene Zeile, damit das andere
//      nicht auf sie wartet.
//
//  Die Zeiten kommen vom Aufrufer (`now`), damit Tests eine Uhr steuern.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore

/// Wofür ein Gerät eine Folge sperrt.
public enum ProcessingLeaseKind: String, Sendable, CaseIterable {
    /// Ton und Transkript, Stufe „Transkript“.
    case transcript
    /// Fakten und die Kapitel-Tags gleich danach, Stufe „Wissen“.
    case knowledge
}

/// Wie der Versuch ausging, eine Folge zu sperren.
public enum LeaseDecision: Sendable, Equatable {
    /// Dieses Gerät hält die Sperre bis `until`.
    case granted(until: Date)
    /// Ein anderes Gerät hält sie bis `until`.
    case heldElsewhere(device: String, until: Date)
}

/// Eine Sperre, wie sie in der Datenbank steht.
public struct ProcessingLease: Sendable, Equatable {
    public let episodeID: EpisodeID
    public let kind: ProcessingLeaseKind
    public let deviceID: String
    public let acquiredAt: Date
    public let expiresAt: Date
}

extension LibraryStore {

    static func leaseKey(_ kind: ProcessingLeaseKind, _ episodeID: EpisodeID) -> String {
        "\(episodeID.rawValue)|\(kind.rawValue)"
    }

    /// Sperrt eine Folge für dieses Gerät oder sagt, wer sie hält.
    ///
    /// Gibt es die Folge nicht oder trägt sie ein Merkzeichen, schreibt der
    /// Store nichts und meldet `.granted`: Die Arbeit fällt dann ohnehin am
    /// Wächter (`CommitGuard`), und eine Sperre für eine gelöschte Folge
    /// bliebe sonst liegen (Regel 5).
    public func acquireLease(
        _ kind: ProcessingLeaseKind, for episodeID: EpisodeID, device: String,
        duration: TimeInterval, now: Date = Date()
    ) throws -> LeaseDecision {
        let episodeKey = episodeID.rawValue
        let living = try modelContext.fetchCount(FetchDescriptor<StoredEpisode>(
            predicate: #Predicate { $0.identifier == episodeKey && $0.removedAt == nil }))
        guard living > 0 else { return .granted(until: now) }

        let rows = try leaseRows(kind, episodeID)
        let own = rows.filter { $0.deviceIdentifier == device }
        if let winner = Self.winner(of: rows, at: now), winner.deviceIdentifier != device {
            for row in own { modelContext.delete(row) }
            if !own.isEmpty { try modelContext.save() }
            return .heldElsewhere(device: winner.deviceIdentifier, until: winner.expiresAt)
        }
        let until = now.addingTimeInterval(duration)
        // Abgelaufenes geht, auch vom anderen Gerät. Eine eigene gültige
        // Zeile wird verlängert, sonst entsteht eine neue.
        for row in rows where row.expiresAt <= now { modelContext.delete(row) }
        let validOwn = own.filter { $0.expiresAt > now }.sorted { $0.acquiredAt < $1.acquiredAt }
        if let keep = validOwn.first {
            keep.expiresAt = until
            for extra in validOwn.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredProcessingLease(
                identifier: Self.leaseKey(kind, episodeID), episodeIdentifier: episodeKey,
                kindRaw: kind.rawValue, deviceIdentifier: device, acquiredAt: now, expiresAt: until))
        }
        try modelContext.save()
        return .granted(until: until)
    }

    /// Verlängert die eigene Sperre während der Arbeit. Legt nichts neu an:
    /// Wurde die Folge inzwischen gelöscht, ist mit ihr auch die Sperre weg,
    /// und so bleibt es. `false`, wenn dieses Gerät die Sperre nicht mehr
    /// hält, etwa weil sie abgelaufen ist und ein anderes übernommen hat.
    @discardableResult
    public func renewLease(
        _ kind: ProcessingLeaseKind, for episodeID: EpisodeID, device: String,
        duration: TimeInterval, now: Date = Date()
    ) throws -> Bool {
        let rows = try leaseRows(kind, episodeID)
        guard let winner = Self.winner(of: rows, at: now), winner.deviceIdentifier == device else { return false }
        winner.expiresAt = now.addingTimeInterval(duration)
        try modelContext.save()
        return true
    }

    /// Gibt die eigene Sperre frei, nach getaner Arbeit.
    public func releaseLease(_ kind: ProcessingLeaseKind, for episodeID: EpisodeID, device: String) throws {
        let own = try leaseRows(kind, episodeID).filter { $0.deviceIdentifier == device }
        guard !own.isEmpty else { return }
        for row in own { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Die Sperren einer Folge, wie sie in der Datenbank stehen.
    public func leases(for episodeID: EpisodeID) throws -> [ProcessingLease] {
        let key = episodeID.rawValue
        return try modelContext.fetch(FetchDescriptor<StoredProcessingLease>(
            predicate: #Predicate { $0.episodeIdentifier == key }))
            .compactMap { row in
                guard let kind = ProcessingLeaseKind(rawValue: row.kindRaw) else { return nil }
                return ProcessingLease(episodeID: episodeID, kind: kind, deviceID: row.deviceIdentifier,
                                       acquiredAt: row.acquiredAt, expiresAt: row.expiresAt)
            }
    }

    /// Räumt Sperren weg, die seit `age` abgelaufen sind, etwa von einem
    /// Gerät, das mitten in der Arbeit beendet wurde. Beim Start.
    func removeStaleLeases(olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-age)
        let stale = try modelContext.fetch(FetchDescriptor<StoredProcessingLease>(
            predicate: #Predicate { $0.expiresAt < cutoff }))
        guard !stale.isEmpty else { return }
        for row in stale { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Nur für Tests: legt die Sperre eines anderen Geräts an, wie sie über
    /// iCloud ankäme.
    func insertLeaseForTesting(
        _ kind: ProcessingLeaseKind, for episodeID: EpisodeID, device: String, acquiredAt: Date, expiresAt: Date
    ) throws {
        modelContext.insert(StoredProcessingLease(
            identifier: Self.leaseKey(kind, episodeID), episodeIdentifier: episodeID.rawValue,
            kindRaw: kind.rawValue, deviceIdentifier: device, acquiredAt: acquiredAt, expiresAt: expiresAt))
        try modelContext.save()
    }

    private func leaseRows(_ kind: ProcessingLeaseKind, _ episodeID: EpisodeID) throws -> [StoredProcessingLease] {
        let key = Self.leaseKey(kind, episodeID)
        return try modelContext.fetch(FetchDescriptor<StoredProcessingLease>(
            predicate: #Predicate { $0.identifier == key }))
    }

    /// Die gültige Sperre, die gilt: die älteste, bei Gleichstand die der
    /// kleineren Gerätekennung.
    private static func winner(of rows: [StoredProcessingLease], at now: Date) -> StoredProcessingLease? {
        rows.filter { $0.expiresAt > now && !$0.deviceIdentifier.isEmpty }
            .min { ($0.acquiredAt, $0.deviceIdentifier) < ($1.acquiredAt, $1.deviceIdentifier) }
    }
}
#endif

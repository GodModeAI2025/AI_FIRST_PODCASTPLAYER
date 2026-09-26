//
//  StoredIDs.swift
//  PodcastAIPersistence
//
//  Eine gemerkte Liste von Kennungen auf diesem Gerät, etwa Folgen oder
//  Podcasts, als Datei in `DeviceState`, bis 0.10 in den
//  Benutzereinstellungen. Die ältesten Einträge fallen ab einer Grenze weg.
//
//  Bis zur Stufe „Wissen“ lag der Typ in der App. Die Stufe führt dieselben
//  Listen (Fakten und Tags ohne Ergebnis) im Paket, unter denselben Namen.
//

import Foundation
import PodcastAICore

public struct StoredIDs<Subject> {
    public let key: String
    public let limit: Int
    private let state: DeviceState
    private var ids: [TypedID<Subject>]
    /// Dieselben Kennungen zum Nachsehen. Das Vorbereiten fragt für jede
    /// Folge eines Archivs, ob sie hier steht.
    private var lookup: Set<TypedID<Subject>>

    public init(key: String, limit: Int = 500, state: DeviceState = .shared) {
        self.key = key
        self.limit = limit
        self.state = state
        let stored = state.value([String].self, for: key) {
            UserDefaults.standard.stringArray(forKey: key)
        }
        ids = (stored ?? []).map(TypedID<Subject>.init(rawValue:))
        lookup = Set(ids)
    }

    public func contains(_ id: TypedID<Subject>) -> Bool { lookup.contains(id) }

    public mutating func insert(_ id: TypedID<Subject>) {
        ids.removeAll { $0 == id }
        ids.append(id)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        lookup = Set(ids)
        save()
    }

    /// Mehrere auf einmal, mit einem Schreiben statt einem je Kennung.
    public mutating func insert(contentsOf new: some Sequence<TypedID<Subject>>) {
        let added = new.filter { !lookup.contains($0) }
        guard !added.isEmpty else { return }
        ids.append(contentsOf: added)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        lookup = Set(ids)
        save()
    }

    public mutating func remove(_ id: TypedID<Subject>) {
        guard lookup.contains(id) else { return }
        ids.removeAll { $0 == id }
        lookup.remove(id)
        save()
    }

    public mutating func removeAll() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        lookup.removeAll()
        save()
    }

    public mutating func removeAll(where shouldRemove: (TypedID<Subject>) -> Bool) {
        let kept = ids.filter { !shouldRemove($0) }
        guard kept.count != ids.count else { return }
        ids = kept
        lookup = Set(ids)
        save()
    }

    private func save() { state.set(ids.map(\.rawValue), for: key) }
}

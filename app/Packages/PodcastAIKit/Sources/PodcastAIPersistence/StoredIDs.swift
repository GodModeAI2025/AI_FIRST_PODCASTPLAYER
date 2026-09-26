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
//  Jede Änderung liest, ändert und schreibt die Liste in einem Zug unter der
//  Sperre von `DeviceState` (`update`). Seit Schritt 3b ändern die Stufe und
//  die Pflege dieselben Listen aus verschiedenen Threads. Schriebe jede
//  Instanz ihren Stand vom Anlegen zurück, ginge die Änderung der anderen
//  verloren, und eine gelöschte Folge stünde womöglich wieder darin.
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
        // Liest auch den alten Wert aus den Benutzereinstellungen und zieht
        // ihn um. Die Änderungen unten lesen danach nur noch `DeviceState`.
        let stored = state.value([String].self, for: key) {
            UserDefaults.standard.stringArray(forKey: key)
        }
        ids = (stored ?? []).map(TypedID<Subject>.init(rawValue:))
        lookup = Set(ids)
    }

    public func contains(_ id: TypedID<Subject>) -> Bool { lookup.contains(id) }

    public mutating func insert(_ id: TypedID<Subject>) {
        let limit = limit
        change { list in
            list.removeAll { $0 == id }
            list.append(id)
            if list.count > limit { list.removeFirst(list.count - limit) }
        }
    }

    /// Mehrere auf einmal, mit einem Schreiben statt einem je Kennung.
    public mutating func insert(contentsOf new: some Sequence<TypedID<Subject>>) {
        let candidates = Array(new)
        guard !candidates.isEmpty else { return }
        let limit = limit
        change { list in
            var present = Set(list)
            let added = candidates.filter { present.insert($0).inserted }
            list.append(contentsOf: added)
            if list.count > limit { list.removeFirst(list.count - limit) }
        }
    }

    public mutating func remove(_ id: TypedID<Subject>) {
        change { list in list.removeAll { $0 == id } }
    }

    public mutating func removeAll() {
        change { list in list.removeAll() }
    }

    public mutating func removeAll(where shouldRemove: (TypedID<Subject>) -> Bool) {
        change { list in list.removeAll(where: shouldRemove) }
    }

    /// Ändert die gespeicherte Liste in einem Zug und übernimmt den neuen
    /// Stand. Geschrieben wird nur, was sich geändert hat. Lässt sich die
    /// Datei gerade nicht lesen, etwa vor dem ersten Entsperren, bleibt sie,
    /// wie sie ist: Ein Schreiben überschriebe sie mit einem Stand, der nur
    /// die Änderung kennt. Diese Instanz merkt sich die Änderung dann nur im
    /// Speicher.
    private mutating func change(_ modify: (inout [TypedID<Subject>]) -> Void) {
        var result: [TypedID<Subject>]?
        let written = state.update([String].self, for: key) { stored in
            let before = (stored ?? []).map(TypedID<Subject>.init(rawValue:))
            var after = before
            modify(&after)
            result = after
            guard after != before else { return }
            stored = after.map(\.rawValue)
        }
        if !written {
            var local = ids
            modify(&local)
            result = local
        }
        guard let result else { return }
        ids = result
        lookup = Set(result)
    }
}

//
//  PipelineIntents.swift
//  PodcastAIKit
//
//  Was die Stufe „Wissen“ vorhat und sich nicht aus dem Store ableiten
//  lässt, gemerkt in `DeviceState` (docs/plan-pipeline.md, „Gespeicherte
//  Absicht“). Bis 0.12 stand das nur im Speicher und war nach einem Ende
//  der App weg: wer „Jetzt ermitteln“ angetippt hatte, seit wann eine
//  Folge von einem anderen Gerät auf ihre Fakten wartet, und woran der
//  letzte Lauf scheiterte.
//
//  Drei Absichten, jede unter einem eigenen Schlüssel, damit eine Datei,
//  die sich gerade nicht lesen lässt, nicht die anderen mitnimmt:
//
//  - Die Warteschlange der Fakten in ihrer Reihenfolge, samt Herkunft und
//    ob jemand sie angefordert hat. Nach einem Neustart kommt sie so zurück.
//  - `firstSeen`: seit wann dieses Gerät Belege einer Folge ohne Fakten
//    kennt. Kam das Transkript von einem anderen Gerät, wartet die Folge
//    20 Minuten auf dessen Fakten, gerechnet ab hier und nicht ab dem
//    Anlegen des Transkripts. Eigene Transkripte stehen mit
//    `Date.distantPast`: Sie warten nicht, auch nicht nach einem Neustart.
//  - `lastFailure`: woran der letzte Lauf einer Folge scheiterte. Nur zum
//    Anzeigen, nie eine Anweisung (Regel 2). Gezeigt wird wie bisher.
//
//  Lässt sich eine Datei gerade nicht lesen, etwa vor dem ersten
//  Entsperren, ändert niemand sie, und wer lesen wollte, bekommt `nil`.
//  Das angefangene Löschen (`PendingPurges`) steht unter seinem eigenen
//  Schlüssel daneben. Die Pflege nimmt die Einträge gelöschter Folgen
//  heraus (`forget`), die Stufe prüft vor jedem Schreiben das Löschprotokoll.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

/// Eine Folge in der Warteschlange der Fakten.
public struct FactsIntent: Codable, Sendable, Equatable {
    public let episodeID: EpisodeID
    /// Wer die Fakten wollte. Die Tags danach erben den Wert.
    public var origin: Origin
    /// „Jetzt ermitteln“: rechnet neu und meldet, was fehlt.
    public var requested: Bool

    public init(episodeID: EpisodeID, origin: Origin, requested: Bool) {
        self.episodeID = episodeID
        self.origin = origin
        self.requested = requested
    }
}

public struct PipelineIntents: Sendable {

    public static let factsQueueKey = "pipelineIntents-factsQueue"
    public static let firstSeenKey = "pipelineIntents-firstSeen"
    public static let lastFailureKey = "pipelineIntents-lastFailure"

    public let state: DeviceState

    public init(state: DeviceState = .shared) {
        self.state = state
    }

    // MARK: - Warteschlange der Fakten

    /// Die gemerkte Warteschlange, vorn zuerst. `nil`, wenn sich die Datei
    /// gerade nicht lesen lässt.
    public func factsQueue() -> [FactsIntent]? {
        switch state.lookup([FactsIntent].self, for: Self.factsQueueKey) {
        case .found(let list): list
        case .absent: []
        case .unreadable: nil
        }
    }

    /// Merkt sich die Warteschlange. `false`, wenn sich die Datei gerade
    /// nicht lesen lässt; sie bleibt dann, wie sie ist.
    @discardableResult
    public func setFactsQueue(_ list: [FactsIntent]) -> Bool {
        state.update([FactsIntent].self, for: Self.factsQueueKey) { stored in
            stored = list.isEmpty ? nil : list
        }
    }

    // MARK: - Zuerst gesehen

    /// Seit wann dieses Gerät Belege ohne Fakten kennt, je Folge. `nil`,
    /// wenn sich die Datei gerade nicht lesen lässt.
    public func firstSeen() -> [EpisodeID: Date]? {
        switch state.lookup([String: Date].self, for: Self.firstSeenKey) {
        case .found(let stored):
            Dictionary(uniqueKeysWithValues: stored.map { (EpisodeID(rawValue: $0.key), $0.value) })
        case .absent: [:]
        case .unreadable: nil
        }
    }

    /// Trägt neu Gesehenes ein und streicht, was keine Wartezeit mehr
    /// braucht, in einem Zug. Was inzwischen jemand anderes eingetragen hat,
    /// etwa ein eigenes Transkript, bleibt stehen.
    @discardableResult
    public func updateFirstSeen(adding added: [EpisodeID: Date], removing removed: Set<EpisodeID>) -> Bool {
        guard !added.isEmpty || !removed.isEmpty else { return true }
        return state.update([String: Date].self, for: Self.firstSeenKey) { stored in
            var entries = stored ?? [:]
            for id in removed { entries[id.rawValue] = nil }
            for (id, date) in added where entries[id.rawValue] == nil { entries[id.rawValue] = date }
            stored = entries.isEmpty ? nil : entries
        }
    }

    /// Ein Transkript von diesem Gerät: Die Fakten warten nicht auf ein
    /// anderes Gerät. Überschreibt ein früheres erstes Sehen.
    @discardableResult
    public func markOwn(_ ids: some Sequence<EpisodeID>) -> Bool {
        let list = Array(ids)
        guard !list.isEmpty else { return true }
        return state.update([String: Date].self, for: Self.firstSeenKey) { stored in
            var entries = stored ?? [:]
            for id in list { entries[id.rawValue] = .distantPast }
            stored = entries
        }
    }

    // MARK: - Letzter Fehlschlag

    /// Woran der letzte Lauf einer Folge scheiterte. `nil` streicht den Eintrag.
    @discardableResult
    public func recordFailure(_ message: String?, for id: EpisodeID) -> Bool {
        if message == nil, case .absent = state.lookup([String: String].self, for: Self.lastFailureKey) {
            return true
        }
        return state.update([String: String].self, for: Self.lastFailureKey) { stored in
            var entries = stored ?? [:]
            guard entries[id.rawValue] != message else { return }
            entries[id.rawValue] = message
            stored = entries.isEmpty ? nil : entries
        }
    }

    /// Die gemerkten Fehlschläge, je Folge.
    public func lastFailures() -> [EpisodeID: String]? {
        switch state.lookup([String: String].self, for: Self.lastFailureKey) {
        case .found(let stored):
            Dictionary(uniqueKeysWithValues: stored.map { (EpisodeID(rawValue: $0.key), $0.value) })
        case .absent: [:]
        case .unreadable: nil
        }
    }

    // MARK: - Löschen

    /// Nimmt alle Absichten zu diesen Folgen heraus (Regel 5). Lässt sich
    /// beliebig oft wiederholen. `false`, wenn eine Datei gerade nicht
    /// lesbar war; die Pflege versucht es dann beim nächsten Mal.
    @discardableResult
    public func forget(_ ids: Set<EpisodeID>) -> Bool {
        guard !ids.isEmpty else { return true }
        let raw = Set(ids.map(\.rawValue))
        let queue = state.update([FactsIntent].self, for: Self.factsQueueKey) { stored in
            guard let list = stored else { return }
            let kept = list.filter { !ids.contains($0.episodeID) }
            guard kept.count != list.count else { return }
            stored = kept.isEmpty ? nil : kept
        }
        let seen = state.update([String: Date].self, for: Self.firstSeenKey) { stored in
            guard let entries = stored, entries.keys.contains(where: raw.contains) else { return }
            let kept = entries.filter { !raw.contains($0.key) }
            stored = kept.isEmpty ? nil : kept
        }
        let failures = state.update([String: String].self, for: Self.lastFailureKey) { stored in
            guard let entries = stored, entries.keys.contains(where: raw.contains) else { return }
            let kept = entries.filter { !raw.contains($0.key) }
            stored = kept.isEmpty ? nil : kept
        }
        return queue && seen && failures
    }
}

//
//  WorkGate.swift
//  PodcastAIKit
//
//  Wann Arbeit laufen darf: vorn, pausiert, beim Leeren der Warteschlange
//  und mit welcher Zeit vom System. Ein Zustand, kein Ereignis: Wer fragt,
//  bekommt immer den letzten Wert, über `current` sofort oder über
//  `updates()` bei jeder Änderung.
//
//  Die Regeln sind genau die bisherigen: `AnalysisQueueControl.mayStart`
//  für Transkripte, `AppModel.factsMayRun` für Fakten und
//  `AppModel.tagsMayRun` für Kapitel-Tags. Gefragt wird je Art von Arbeit
//  und nicht je Stufe, denn Fakten und Tags liegen in einer Stufe, und die
//  leichte Aufgabe `com.podcastai.tagging` gibt nur den Tags Zeit.
//
//  Zeit vom System ist ein Träger, der sich mit `hold(_:)` anmeldet und mit
//  dem Ende seiner Leihe wieder geht. `.uikit` und `.siri` geben heute
//  weder Fakten noch Tags Zeit. Sie stehen hier, damit die Stufen später
//  sehen, wer die App gerade wach hält.
//
//  Seit Schritt 3a speist das Modell das Tor: Pause, „Alle abbrechen“,
//  Vorder- und Hintergrund. Die Träger melden sich an den Stellen an, an
//  denen bis 0.13 `factsGrants` und `tagGrants` zählten: der Worker der
//  Transkripte und die beiden Hintergrundaufgaben. Die Stufe „Wissen“
//  fragt hier. Seit Schritt 4
//  fragt auch die Stufe „Ausgaben“ (`.editions`): Pause und „Alle
//  abbrechen“ halten ihre Automatik an (Entscheidung 3). Seit Schritt 5a
//  fragen „Download“ fürs Vorhalten (`.prefetch`) und „Vorbereiten“ für die
//  Metadaten (`.metadata`), aus demselben Grund.
//

import Foundation
import Synchronization
import PodcastAICore

/// Wer der App Zeit gibt, obwohl sie nicht vorn ist.
public enum WorkCarrier: String, Sendable, Hashable, CaseIterable {
    /// Transkripte entstehen, getragen von der fortgesetzten Verarbeitung
    /// (`BGContinuedProcessingTask`), angemeldet von der Stufe „Transkript“.
    case continued
    /// Die Hintergrundaufgabe `com.podcastai.analysis`.
    case analysisTask
    /// Die leichte Hintergrundaufgabe `com.podcastai.tagging`.
    case taggingTask
    /// Die kurze Hintergrundzeit von UIKit nach dem Wechsel in den Hintergrund.
    case uikit
    /// Eine Anfrage über Siri oder Kurzbefehle.
    case siri
}

/// Die Arten von Arbeit, nach denen das Tor unterscheidet.
public enum GatedWork: String, Sendable, Hashable, CaseIterable {
    /// Ein Transkript beginnen.
    case transcript
    /// Fakten einer Folge sammeln.
    case facts
    /// Kapitel einer Folge einordnen.
    case tags
    /// Eine Ausgabe eines Themen-Updates zusammenstellen und ihr Cover
    /// erzeugen (Stufe „Ausgaben“, seit Schritt 4).
    case editions
    /// Die neueste Folge je Podcast von selbst aufs Gerät laden (Stufe
    /// „Download“, seit Schritt 5a).
    case prefetch
    /// Metadaten zu Videos über Supadata holen (Stufe „Vorbereiten“, seit
    /// Schritt 5a).
    case metadata
}

/// Der Stand, nach dem das Tor entscheidet.
public struct WorkConditions: Sendable, Equatable {
    public var inForeground: Bool
    /// „Pausieren“ in der Warteschlange.
    public var paused: Bool
    /// „Alle abbrechen“ leert gerade die Warteschlangen.
    public var cancelling: Bool
    /// Wie viele Leihen je Träger gerade laufen. Nur Träger mit Leihe stehen darin.
    public var carriers: [WorkCarrier: Int]

    public init(inForeground: Bool, paused: Bool = false, cancelling: Bool = false,
                carriers: [WorkCarrier: Int] = [:]) {
        self.inForeground = inForeground
        self.paused = paused
        self.cancelling = cancelling
        self.carriers = carriers.filter { $0.value > 0 }
    }

    /// Pausiert oder beim Leeren: dann läuft nichts (`AppModel.queueHeld`).
    public var held: Bool { paused || cancelling }

    public func holds(_ carrier: WorkCarrier) -> Bool { (carriers[carrier] ?? 0) > 0 }

    /// Darf diese Arbeit jetzt laufen? `origin` ändert daran heute nichts;
    /// auch „Jetzt ermitteln“ wartet in der Pause.
    public func mayRun(_ work: GatedWork, origin: Origin) -> Bool {
        switch work {
        case .transcript:
            // Transkripte beginnen nur vorn. Die fortgesetzte Verarbeitung
            // trägt eine laufende Warteschlange, beginnen lässt sie keine.
            AnalysisQueueControl.mayStart(paused: paused, inForeground: inForeground, cancelling: cancelling)
        case .facts:
            // Vorn immer, sonst nur mit Zeit vom System: solange Transkripte
            // entstehen, oder in `com.podcastai.analysis`.
            !held && (inForeground || holds(.continued) || holds(.analysisTask))
        case .tags:
            // Wie die Fakten, und zusätzlich in `com.podcastai.tagging`.
            mayRun(.facts, origin: origin) || (holds(.taggingTask) && !held)
        case .editions:
            // Pause und „Alle abbrechen“ halten die Automatik an
            // (Entscheidung 3). Vorder- und Hintergrund bleiben wie bis 0.13:
            // Die Automatik läuft nach dem Aktualisieren, nach den
            // Transkripten und in `com.podcastai.analysis`. Wer „Neue Ausgabe
            // zusammenstellen“ antippt oder Siri fragt, bekommt die Ausgabe
            // auch in der Pause; Siri wartet auf den Satz, den es vorliest.
            origin == .user || !held
        case .prefetch, .metadata:
            // Pause und „Alle abbrechen“ halten auch Vorhalten und
            // Metadaten an (Entscheidung 3). Sonst gilt wie bis 0.13 nur die
            // Regel fürs Netz, die die Stufe beim Hauptakteur fragt.
            !held
        }
    }
}

public final class WorkGate: Sendable {

    private struct State {
        var conditions: WorkConditions
        var observers: [UInt64: AsyncStream<WorkConditions>.Continuation] = [:]
        var nextToken: UInt64 = 0
    }

    /// Auf dem Mac gilt die laufende App immer als vorn.
    public static let platformAlwaysInForeground: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    private let alwaysInForeground: Bool
    private let state: Mutex<State>

    /// `inForeground`: der Stand beim Anlegen. Auf dem iPhone kann die App
    /// auch im Hintergrund starten, etwa für einen Download.
    public init(alwaysInForeground: Bool = WorkGate.platformAlwaysInForeground, inForeground: Bool = true) {
        self.alwaysInForeground = alwaysInForeground
        state = Mutex(State(conditions: WorkConditions(inForeground: alwaysInForeground || inForeground)))
    }

    /// Der letzte Stand.
    public var current: WorkConditions { state.withLock { $0.conditions } }

    /// Darf diese Arbeit jetzt laufen?
    public func mayRun(_ work: GatedWork, origin: Origin) -> Bool {
        current.mayRun(work, origin: origin)
    }

    /// Jede Änderung, beginnend mit dem Stand jetzt. Wer langsam liest,
    /// bekommt nur den neuesten Stand, keine Liste alter.
    public func updates() -> AsyncStream<WorkConditions> {
        let (stream, continuation) = AsyncStream<WorkConditions>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = state.withLock { state -> UInt64 in
            state.nextToken += 1
            state.observers[state.nextToken] = continuation
            continuation.yield(state.conditions)
            return state.nextToken
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: token) }
        }
        return stream
    }

    public func setInForeground(_ value: Bool) {
        change { $0.inForeground = alwaysInForeground || value }
    }

    public func setPaused(_ value: Bool) {
        change { $0.paused = value }
    }

    public func setCancelling(_ value: Bool) {
        change { $0.cancelling = value }
    }

    /// Meldet einen Träger an. Er zählt, bis die Leihe endet.
    public func hold(_ carrier: WorkCarrier) -> WorkLease {
        change { $0.carriers[carrier, default: 0] += 1 }
        return WorkLease(gate: self, carrier: carrier)
    }

    fileprivate func release(_ carrier: WorkCarrier) {
        change { conditions in
            let remaining = (conditions.carriers[carrier] ?? 0) - 1
            conditions.carriers[carrier] = remaining > 0 ? remaining : nil
        }
    }

    /// Ändert den Stand und meldet ihn nur, wenn er sich wirklich geändert hat.
    private func change(_ update: (inout WorkConditions) -> Void) {
        state.withLock { state in
            var next = state.conditions
            update(&next)
            guard next != state.conditions else { return }
            state.conditions = next
            for observer in state.observers.values { observer.yield(next) }
        }
    }
}

/// Eine Leihe von Zeit vom System. Endet genau einmal: mit `release()` oder,
/// falls niemand daran denkt, wenn sie verschwindet. Ein zweites Ende, etwa
/// aus dem `expirationHandler` und nach dem Ergebnis, tut nichts.
public final class WorkLease: Sendable {

    public let carrier: WorkCarrier
    private let gate: WorkGate
    private let released = Mutex(false)

    fileprivate init(gate: WorkGate, carrier: WorkCarrier) {
        self.gate = gate
        self.carrier = carrier
    }

    /// Gibt den Träger zurück. Ein zweiter Aufruf tut nichts.
    public func release() {
        let first = released.withLock { released -> Bool in
            defer { released = true }
            return !released
        }
        if first { gate.release(carrier) }
    }

    /// Ist die Leihe schon zu Ende?
    public var isReleased: Bool { released.withLock { $0 } }

    deinit { release() }
}

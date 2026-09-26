//
//  ModelAvailabilityMonitor.swift
//  PodcastAIIntelligence
//
//  Ob Gerätemodell und Private Cloud Compute bereit sind, als Zustand und
//  nicht als Ereignis: Wer fragt, bekommt immer den letzten Wert, über
//  `current` sofort oder über `updates()` bei jeder Änderung.
//
//  Die Frage an FoundationModels geht an einen Dienst des Systems und kann
//  warten, während das Modell rechnet. Deshalb fragt `refresh` abseits des
//  Hauptthreads mit Priorität `utility`, wie bis 0.12 das Modell der App,
//  und meldet nur einen neuen Stand.
//
//  Der Monitor stößt selbst nichts an. Was die App tut, wenn ein Modell
//  bereit wird (Fakten weiterlaufen lassen, Zurückgestelltes einreihen),
//  bleibt beim Aufrufer.
//

import Foundation
import Synchronization
import PodcastAICore
#if canImport(FoundationModels)
import FoundationModels
#endif

public actor ModelAvailabilityMonitor {

    public static let shared = ModelAvailabilityMonitor()

    /// Der Stand, bevor jemand gefragt hat: kein Modell bereit, Private
    /// Cloud Compute nicht freigegeben.
    public static let unchecked = ModelStatus(
        onDevice: .unavailable(.modelNotReady),
        privateCloudCompute: .unavailable(.userConsentMissing))

    /// Fragt das System nach dem Zustand. `allowPrivateCloud` ist die
    /// Einstellung des Nutzers.
    public typealias Probe = @Sendable (_ allowPrivateCloud: Bool) -> ModelStatus

    private struct State {
        var status: ModelStatus
        var observers: [UInt64: AsyncStream<ModelStatus>.Continuation] = [:]
        var nextToken: UInt64 = 0
    }

    private let probe: Probe
    private nonisolated let state: Mutex<State>
    /// Jede Frage bekommt eine Nummer. Ein Ergebnis gilt nur, wenn keine
    /// später gestellte Frage schon geantwortet hat: Nach dem Abschalten von
    /// Private Cloud Compute überschreibt eine langsame ältere Antwort den
    /// neuen Stand nicht.
    private var asked: UInt64 = 0
    private var answered: UInt64 = 0

    public init(
        initial: ModelStatus = ModelAvailabilityMonitor.unchecked,
        probe: @escaping Probe = { KnowledgeExtractor.currentStatus(allowPrivateCloud: $0) }
    ) {
        self.probe = probe
        state = Mutex(State(status: initial))
    }

    /// Der letzte Stand.
    public nonisolated var current: ModelStatus { state.withLock { $0.status } }

    /// Jede Änderung, beginnend mit dem Stand jetzt. Wer langsam liest,
    /// bekommt nur den neuesten Stand, keine Liste alter.
    public nonisolated func updates() -> AsyncStream<ModelStatus> {
        let (stream, continuation) = AsyncStream<ModelStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = state.withLock { state -> UInt64 in
            state.nextToken += 1
            state.observers[state.nextToken] = continuation
            continuation.yield(state.status)
            return state.nextToken
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: token) }
        }
        return stream
    }

    /// Fragt das System neu und gibt den Stand zurück. Gemeldet wird nur,
    /// was sich geändert hat.
    @discardableResult
    public func refresh(allowPrivateCloud: Bool) async -> ModelStatus {
        asked += 1
        let number = asked
        let probe = self.probe
        let status = await Task.detached(priority: .utility) { probe(allowPrivateCloud) }.value
        guard number > answered else { return current }
        answered = number
        state.withLock { state in
            guard state.status != status else { return }
            state.status = status
            for observer in state.observers.values { observer.yield(status) }
        }
        return status
    }

    // MARK: - Fenster des Gerätemodells

    /// Wie viele Token das Gerätemodell für Anweisungen, Prompt und Antwort
    /// zusammen fasst. Unter iOS 27 und macOS 27 sind es 8.192.
    /// Einmal gefragt und gemerkt: Die Frage geht an einen Dienst des Systems
    /// und hielt bei jeder Folge den Hauptthread an, während das Modell rechnete.
    /// Gemerkt wird nur eine echte Größe, solange das Modell noch lädt, gilt 4.096.
    public static var onDeviceContextSize: Int {
        if let known = contextSizeCache.withLock({ $0 }) { return known }
        #if canImport(FoundationModels)
        let size = SystemLanguageModel.default.contextSize
        #else
        let size = 0
        #endif
        guard size > 0 else { return 4_096 }
        contextSizeCache.withLock { $0 = size }
        return size
    }
    private static let contextSizeCache = Mutex<Int?>(nil)
}

//
//  AIScheduler.swift
//  PodcastAIIntelligence
//
//  Der eine Weg zu Apple Intelligence. Jeder Aufruf eines Sprachmodells,
//  auf dem Gerät oder über Private Cloud Compute, geht durch diese Stelle:
//  Fakten, Satz je Kapitel, Tags, Relevanz, Auswahl für Themen-Updates und
//  Antworten im Chat.
//
//  Warum eine Stelle: Das Gerätemodell rechnet auf GPU und Neural Engine.
//  Zwei Anfragen gleichzeitig teilen sich beide, und die Oberfläche verliert
//  Bilder, auch wenn der Hauptthread frei ist. Deshalb gilt:
//
//  1. Es läuft genau eine Anfrage, in der ganzen App.
//  2. Was jemand selbst ausgelöst hat (eine Frage im Chat, der Satz je
//     Kapitel beim Öffnen des Reiters, „Jetzt ermitteln“), kommt sofort dran.
//     Läuft gerade Arbeit im Hintergrund, wird sie abgebrochen und danach
//     von vorn wiederholt; ihr Aufrufer merkt davon nichts außer der Zeit.
//  3. Arbeit im Hintergrund wartet, solange jemand scrollt oder tippt, und
//     beginnt erst nach zwei ruhigen Sekunden. Zwischen zwei Anfragen im
//     Hintergrund liegt eine kurze Pause.
//  4. Während einer Frage im Chat (`withUserActivity`) beginnt nichts im
//     Hintergrund, auch nicht zwischen Token zählen und Antwort.
//
//  Die Stelle ruft selbst kein Modell. Sie entscheidet nur, wer wann darf.
//

import Foundation
import Synchronization
import os

/// Welche Art Arbeit eine Anfrage ist. Für die Anzeige in der Warteschlange.
public enum AIWorkKind: String, Sendable, CaseIterable, Codable {
    case answer, chapterSummary, facts, tags, relevance, other
}

/// Wer auf das Ergebnis wartet.
public enum AIWorkPriority: Sendable, Equatable {
    /// Jemand hat getippt und wartet jetzt.
    case user
    /// Von selbst, ohne dass jemand wartet.
    case background
}

/// Stand der Stelle für die Warteschlange.
public struct AIPipelineSnapshot: Sendable, Equatable {
    public var running: AIWorkKind?
    public var runningPriority: AIWorkPriority?
    public var queued: [AIWorkKind: Int]
    /// Arbeit im Hintergrund wartet, weil jemand die App gerade bedient.
    public var yieldingToUser: Bool

    public init(running: AIWorkKind? = nil, runningPriority: AIWorkPriority? = nil,
                queued: [AIWorkKind: Int] = [:], yieldingToUser: Bool = false) {
        self.running = running; self.runningPriority = runningPriority
        self.queued = queued; self.yieldingToUser = yieldingToUser
    }

    public var queuedCount: Int { queued.values.reduce(0, +) }
}

public actor AIScheduler {

    public static let shared = AIScheduler()
    static let signposter = OSSignposter(subsystem: ChatTrace.subsystem, category: "ai")

    /// So lange nach der letzten Berührung wartet Arbeit im Hintergrund.
    public let idleInterval: Duration
    /// Pause zwischen zwei Anfragen im Hintergrund.
    public let backgroundPause: Duration

    private struct Waiter {
        let id: UInt64
        let kind: AIWorkKind
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Running {
        let id: UInt64
        let kind: AIWorkKind
        let priority: AIWorkPriority
        var cancel: (@Sendable () -> Void)?
        var preempted = false
    }

    private var userWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var running: Running?
    private var nextID: UInt64 = 0
    private var userActivities = 0
    private var lastBackgroundEnd: ContinuousClock.Instant?
    private var wakeTask: Task<Void, Never>?

    /// Zeitpunkt der letzten Berührung, ohne Umweg über den Akteur lesbar
    /// und schreibbar: der Hauptthread meldet ihn beim Scrollen.
    private nonisolated let lastInteraction = Mutex<ContinuousClock.Instant?>(nil)
    /// Hält die Arbeit im Hintergrund an, etwa im Stromsparmodus bei laufendem Ton.
    private nonisolated let held = Mutex(false)
    /// Seit wann eine Liste scrollt. Meldet eine verschwundene Liste ihr
    /// Ende nie, gilt das Scrollen nach ``scrollExpiry`` als vorbei.
    private nonisolated let scrollingSince = Mutex<ContinuousClock.Instant?>(nil)
    static let scrollExpiry = Duration.seconds(20)

    private let updates: AsyncStream<AIPipelineSnapshot>.Continuation
    /// Jeder neue Stand der Stelle, für die Warteschlange.
    public nonisolated let snapshots: AsyncStream<AIPipelineSnapshot>
    private var lastSnapshot = AIPipelineSnapshot()

    public init(idleInterval: Duration = .seconds(2), backgroundPause: Duration = .milliseconds(500)) {
        self.idleInterval = idleInterval
        self.backgroundPause = backgroundPause
        (snapshots, updates) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Signale aus der Oberfläche

    /// Wann das Gerätemodell zuletzt für den Hintergrund gerechnet hat.
    private nonisolated let backgroundActivity = Mutex<(running: Bool, ended: ContinuousClock.Instant?)>((false, nil))

    /// Rechnet das Modell gerade für den Hintergrund, oder hat es das in den
    /// letzten zehn Sekunden getan? Dann ist es für eine Frage noch nicht frei.
    public nonisolated var modelBusyRecently: Bool {
        let (running, ended) = backgroundActivity.withLock { $0 }
        if running { return true }
        guard let ended else { return false }
        return ContinuousClock.now - ended < .seconds(10)
    }

    /// Jemand tippt oder hat eben etwas berührt. Billig genug für den Hauptthread.
    public nonisolated func noteInteraction() {
        lastInteraction.withLock { $0 = .now }
    }

    /// Eine Liste beginnt oder endet zu scrollen. Solange eine scrollt,
    /// beginnt nichts im Hintergrund; danach erst nach der Ruhezeit.
    public nonisolated func noteScrolling(_ active: Bool) {
        lastInteraction.withLock { $0 = .now }
        let ended = scrollingSince.withLock { since -> Bool in
            defer { since = active ? (since ?? .now) : nil }
            return since != nil && !active
        }
        if ended { Task { await self.pump() } }
    }

    /// Hält die Arbeit im Hintergrund an oder gibt sie frei.
    public nonisolated func setBackgroundHeld(_ hold: Bool) {
        let changed = held.withLock { value -> Bool in
            defer { value = hold }
            return value != hold
        }
        if changed { Task { await self.pump() } }
    }

    // MARK: - Anfragen

    /// Führt `operation` aus, sobald die Regeln es erlauben, und gibt ihr
    /// Ergebnis zurück. Arbeit im Hintergrund, die für eine Anfrage eines
    /// Menschen abgebrochen wurde, läuft danach von vorn; ein Abbruch des
    /// Aufrufers selbst endet mit `CancellationError`.
    public func run<T: Sendable>(
        _ kind: AIWorkKind, priority: AIWorkPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        while true {
            let id = try await acquire(kind, priority: priority)
            let task = Task.detached(priority: priority == .user ? .userInitiated : .utility) {
                // Jede Anfrage ist ein Intervall in Instruments (Kategorie `ai`).
                let signposter = AIScheduler.signposter
                let state = signposter.beginInterval(
                    "KI-Anfrage", id: signposter.makeSignpostID(),
                    "\(kind.rawValue, privacy: .public) \(priority == .user ? "Mensch" : "Hintergrund", privacy: .public)")
                defer { signposter.endInterval("KI-Anfrage", state) }
                return try await operation()
            }
            running?.cancel = { task.cancel() }
            // Kam eine Anfrage eines Menschen dazwischen, gilt der Abbruch jetzt.
            if running?.preempted == true { task.cancel() }
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            let preempted = running?.id == id && running?.preempted == true
            release(id)
            if case .failure = result, preempted, priority == .background, !Task.isCancelled {
                continue
            }
            return try result.get()
        }
    }

    /// Solange `work` läuft, beginnt nichts im Hintergrund, und was dort
    /// gerade läuft, wird abgebrochen und später wiederholt. Für eine Frage
    /// im Chat mit ihren Schritten vor der Antwort.
    public func withUserActivity<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        beginUserActivity()
        defer { endUserActivity() }
        return try await work()
    }

    public func beginUserActivity() {
        userActivities += 1
        preemptBackground()
        publish()
    }

    public func endUserActivity() {
        userActivities = max(0, userActivities - 1)
        pump()
    }

    /// Der aktuelle Stand.
    public func snapshot() -> AIPipelineSnapshot { makeSnapshot() }

    // MARK: - Intern

    private func acquire(_ kind: AIWorkKind, priority: AIWorkPriority) async throws -> UInt64 {
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, kind: kind, continuation: continuation)
                if priority == .user {
                    userWaiters.append(waiter)
                    preemptBackground()
                } else {
                    backgroundWaiters.append(waiter)
                }
                pump()
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
        return id
    }

    private func dropWaiter(_ id: UInt64) {
        if let index = userWaiters.firstIndex(where: { $0.id == id }) {
            userWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        publish()
    }

    private func preemptBackground() {
        guard var current = running, current.priority == .background, !current.preempted else { return }
        current.preempted = true
        running = current
        Self.signposter.emitEvent("Hintergrund abgebrochen")
        current.cancel?()
    }

    private func release(_ id: UInt64) {
        guard running?.id == id else { return }
        if running?.priority == .background {
            lastBackgroundEnd = .now
            backgroundActivity.withLock { $0 = (false, .now) }
        }
        running = nil
        pump()
    }

    /// Vergibt die Stelle, wenn sie frei ist und die Regeln es erlauben.
    private func pump() {
        defer { publish() }
        guard running == nil else { return }
        if !userWaiters.isEmpty {
            let next = userWaiters.removeFirst()
            running = Running(id: next.id, kind: next.kind, priority: .user)
            next.continuation.resume()
            return
        }
        guard !backgroundWaiters.isEmpty, userActivities == 0, !held.withLock({ $0 }) else { return }
        let now = ContinuousClock.now
        var earliest = now
        if let since = scrollingSince.withLock({ $0 }), now - since < Self.scrollExpiry {
            earliest = max(earliest, since + Self.scrollExpiry)
        }
        if let touched = lastInteraction.withLock({ $0 }) { earliest = max(earliest, touched + idleInterval) }
        if let ended = lastBackgroundEnd { earliest = max(earliest, ended + backgroundPause) }
        guard earliest <= now else {
            scheduleWake(at: earliest)
            return
        }
        let next = backgroundWaiters.removeFirst()
        running = Running(id: next.id, kind: next.kind, priority: .background)
        backgroundActivity.withLock { $0.running = true }
        next.continuation.resume()
    }

    private func scheduleWake(at instant: ContinuousClock.Instant) {
        wakeTask?.cancel()
        wakeTask = Task {
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled else { return }
            self.pump()
        }
    }

    private func makeSnapshot() -> AIPipelineSnapshot {
        var queued: [AIWorkKind: Int] = [:]
        for waiter in userWaiters + backgroundWaiters { queued[waiter.kind, default: 0] += 1 }
        let yielding = running == nil && !backgroundWaiters.isEmpty && userWaiters.isEmpty
        return AIPipelineSnapshot(running: running?.kind, runningPriority: running?.priority,
                                  queued: queued, yieldingToUser: yielding)
    }

    private func publish() {
        let snapshot = makeSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        updates.yield(snapshot)
    }
}

/// Trägt einen Wert über die Grenze einer Aufgabe, wenn der Aufrufer
/// wartet und niemand sonst darauf zugreift. Für Ergebnisse und Aufrufe
/// von FoundationModels, die nicht `Sendable` sind.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

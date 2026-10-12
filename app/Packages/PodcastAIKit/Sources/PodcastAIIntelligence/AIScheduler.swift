//
//  AIScheduler.swift
//  PodcastAIIntelligence
//
//  Der eine Weg zu Apple Intelligence. Jeder Aufruf eines Sprachmodells,
//  auf dem Gerät oder über Private Cloud Compute, geht durch diese Stelle:
//  Fakten, Satz je Kapitel, Tags, Relevanz, Auswahl für Themen-Updates und
//  Antworten im Chat. Seit Schritt 4 der Pipeline auch die Bilder von Image
//  Playground für die Cover der Themen-Updates (`.cover`).
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
//  5. Hängt eine Anfrage, gibt die Stelle sie frei. Eine Anfrage, die keinen
//     Fortschritt meldet und sich nicht abbrechen lässt, würde sonst die
//     einzige Stelle der App für immer besetzen und jede weitere Frage und
//     jede Arbeit im Hintergrund festhalten (siehe ``AIStall``).
//
//  Die Stelle ruft selbst kein Modell. Sie entscheidet nur, wer wann darf.
//

import Foundation
import Synchronization
import os

/// Welche Art Arbeit eine Anfrage ist. Für die Anzeige in der Warteschlange.
public enum AIWorkKind: String, Sendable, CaseIterable, Codable {
    case answer, chapterSummary, facts, tags, relevance
    /// Ein Bild von Image Playground für ein Themen-Update oder eine Ausgabe.
    /// Es rechnet auf derselben GPU und Neural Engine wie die Sprachmodelle.
    case cover
    case other
}

/// Wer auf das Ergebnis wartet.
public enum AIWorkPriority: Sendable, Equatable {
    /// Jemand hat getippt und wartet jetzt.
    case user
    /// Von selbst, ohne dass jemand wartet.
    case background
}

/// Wer Anfragen an ein Sprachmodell zuteilt. `AIScheduler` erfüllt es; wer
/// ein Modell ruft (`KnowledgeExtractor`, `TagSelector`, später die Stufen),
/// bekommt die Stelle übergeben, statt `AIScheduler.shared` selbst zu
/// greifen. Tests reichen so eine Stelle hinein, die den Vorrang mitschreibt.
///
/// `operation` enthält den ganzen Aufruf, auch das Anlegen der Sitzung: Wird
/// Arbeit im Hintergrund für eine Anfrage eines Menschen abgebrochen und
/// wiederholt, beginnt sie mit einer frischen Sitzung ohne alten Verlauf.
public protocol AIScheduling: Sendable {
    func run<T: Sendable>(
        _ kind: AIWorkKind, priority: AIWorkPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T
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

/// Eine Anfrage hat zu lange nichts gemeldet und wurde freigegeben.
///
/// Das Modell kann dabei durchaus noch rechnen. Die Stelle wartet nicht
/// länger darauf, damit die nächste Anfrage drankommt. Die Aufrufer
/// behandeln den Fehler wie jeden anderen der Modelle: Private Cloud
/// Compute fällt auf das Gerät zurück, Arbeit im Hintergrund wartet.
public struct AIStalledError: Error, LocalizedError, Sendable, Equatable {
    public let kind: AIWorkKind
    public let seconds: Int

    public init(kind: AIWorkKind, seconds: Int) {
        self.kind = kind; self.seconds = seconds
    }

    public var errorDescription: String? {
        String(localized: "Das Modell hat seit \(seconds) Sekunden nicht geantwortet.", bundle: .module)
    }
}

/// Wie lange eine Anfrage ohne Lebenszeichen laufen darf.
///
/// Ein Lebenszeichen ist neuer Text einer streamenden Antwort oder der
/// Aufruf eines Werkzeugs. Anfragen, die nichts melden, haben nur ihre
/// Gesamtzeit. Die Werte sind großzügig: Private Cloud Compute braucht
/// bei vollem Fenster und Werkzeugen auch einmal eine Minute.
public struct AIStallLimits: Sendable, Equatable {
    public var answer: Duration
    public var summary: Duration
    public var background: Duration
    public var cover: Duration
    /// So lange darf eine Anfrage nach einem Abbruch noch zurückkehren,
    /// bevor die Stelle sie freigibt.
    public var cancellationGrace: Duration

    public init(answer: Duration = .seconds(90), summary: Duration = .seconds(90),
                background: Duration = .seconds(240), cover: Duration = .seconds(180),
                cancellationGrace: Duration = .seconds(5)) {
        self.answer = answer; self.summary = summary
        self.background = background; self.cover = cover
        self.cancellationGrace = cancellationGrace
    }

    public static let standard = AIStallLimits()

    func limit(for kind: AIWorkKind) -> Duration {
        switch kind {
        case .answer: answer
        case .chapterSummary: summary
        case .cover: cover
        case .facts, .tags, .relevance, .other: background
        }
    }
}

/// Der Herzschlag einer Anfrage. Wer streamt oder ein Werkzeug ruft,
/// meldet mit ``AIStall/beat()``, dass es weitergeht.
public enum AIStall {
    final class Heartbeat: Sendable {
        private let last = Mutex(ContinuousClock.now)
        func touch() { last.withLock { $0 = .now } }
        var idle: Duration { ContinuousClock.now - last.withLock { $0 } }
    }

    @TaskLocal static var heartbeat: Heartbeat?

    /// Meldet ein Lebenszeichen der Anfrage, in der der Aufruf läuft.
    /// Außerhalb einer Anfrage der Stelle tut es nichts.
    public static func beat() { heartbeat?.touch() }
}

/// Lässt genau einen von mehreren Ausgängen zu: das Ergebnis der Anfrage,
/// ihre Freigabe wegen Stillstand oder die Rückkehr nach einem Abbruch.
private final class Outcome<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Result<T, any Error>, Never>?>(nil)
    private let decided = Mutex(false)
    private let pending = Mutex<Result<T, any Error>?>(nil)

    func attach(_ continuation: CheckedContinuation<Result<T, any Error>, Never>) {
        let early = pending.withLock { value -> Result<T, any Error>? in defer { value = nil }; return value }
        if let early { continuation.resume(returning: early) } else {
            self.continuation.withLock { $0 = continuation }
        }
    }

    /// Gibt `true` zurück, wenn dieser Ausgang gilt.
    @discardableResult
    func decide(_ result: Result<T, any Error>) -> Bool {
        let first = decided.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return false }
        let waiting = continuation.withLock { value -> CheckedContinuation<Result<T, any Error>, Never>? in
            defer { value = nil }
            return value
        }
        if let waiting { waiting.resume(returning: result) } else { pending.withLock { $0 = result } }
        return true
    }

    var isDecided: Bool { decided.withLock { $0 } }
}

public actor AIScheduler: AIScheduling {

    public static let shared = AIScheduler()
    static let signposter = OSSignposter(subsystem: ChatTrace.subsystem, category: "ai")

    /// So lange nach der letzten Berührung wartet Arbeit im Hintergrund.
    public let idleInterval: Duration
    /// Pause zwischen zwei Anfragen im Hintergrund.
    public let backgroundPause: Duration
    /// Wie lange eine Anfrage ohne Lebenszeichen laufen darf.
    public let stallLimits: AIStallLimits

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

    public init(idleInterval: Duration = .seconds(2), backgroundPause: Duration = .milliseconds(500),
                stallLimits: AIStallLimits = .standard) {
        self.idleInterval = idleInterval
        self.backgroundPause = backgroundPause
        self.stallLimits = stallLimits
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
            let heartbeat = AIStall.Heartbeat()
            let task = Task.detached(priority: priority == .user ? .userInitiated : .utility) {
                // Jede Anfrage ist ein Intervall in Instruments (Kategorie `ai`).
                let signposter = AIScheduler.signposter
                let state = signposter.beginInterval(
                    "KI-Anfrage", id: signposter.makeSignpostID(),
                    "\(kind.rawValue, privacy: .public) \(priority == .user ? "Mensch" : "Hintergrund", privacy: .public)")
                defer { signposter.endInterval("KI-Anfrage", state) }
                // Die Frist zählt ab dem Beginn der Anfrage, nicht ab dem Anlegen der Aufgabe.
                heartbeat.touch()
                return try await AIStall.$heartbeat.withValue(heartbeat) { try await operation() }
            }
            let outcome = Outcome<T>()
            let limits = stallLimits
            let limit = limits.limit(for: kind)
            // Ein Abbruch erreicht eine hängende Anfrage nicht. Deshalb gibt die
            // Stelle sie nach der Schonfrist frei, auch ohne dass sie zurückkehrt.
            let cancelRequest = { @Sendable in
                task.cancel()
                Task {
                    try? await Task.sleep(for: limits.cancellationGrace)
                    outcome.decide(.failure(CancellationError()))
                }
            }
            running?.cancel = cancelRequest
            // Kam eine Anfrage eines Menschen dazwischen, gilt der Abbruch jetzt.
            if running?.preempted == true { cancelRequest() }
            let watchdog = Task {
                while !outcome.isDecided {
                    try? await Task.sleep(for: min(.seconds(1), limit / 4))
                    if Task.isCancelled { return }
                    if heartbeat.idle >= limit {
                        let seconds = Int(limit.components.seconds)
                        if outcome.decide(.failure(AIStalledError(kind: kind, seconds: seconds))) {
                            task.cancel()
                            AIScheduler.signposter.emitEvent("KI-Anfrage freigegeben")
                        }
                        return
                    }
                }
            }
            let result: Result<T, any Error> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    outcome.attach(continuation)
                    // Wartet unstrukturiert: Hängt die Anfrage, bleibt dieser Warter
                    // zurück, aber die Stelle ist frei.
                    Task { outcome.decide(await task.result) }
                }
            } onCancel: {
                cancelRequest()
            }
            watchdog.cancel()
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

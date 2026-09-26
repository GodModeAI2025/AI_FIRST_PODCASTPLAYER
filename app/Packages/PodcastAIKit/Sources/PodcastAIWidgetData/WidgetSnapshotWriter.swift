//
//  WidgetSnapshotWriter.swift
//  PodcastAIWidgetData
//
//  Schreibt den Schnappschuss selten und nur, wenn sich etwas ändert.
//
//  Während die Warteschlange arbeitet, rechnet die App ihre Zahlen oft neu,
//  und jedes Neuladen eines Widgets kostet Budget beim System. Deshalb:
//
//  - Gleicher Inhalt wie in der Datei: nichts tun.
//  - Etwas verschwindet oder wird kleiner, etwa nach „Folge löschen“:
//    sofort schreiben (Regel 5).
//  - Etwas kommt nur dazu: höchstens alle fünf Minuten. Was dazwischen
//    kommt, ersetzt den wartenden Stand, geschrieben wird der letzte.
//

import Foundation

/// Die Regel, wann geschrieben wird, ohne Uhr und ohne Datei.
public struct WidgetSnapshotThrottle: Sendable {

    public enum Decision: Equatable, Sendable {
        /// Steht schon so in der Datei.
        case unchanged
        case now
        /// Frühestens zu diesem Zeitpunkt.
        case later(Date)
    }

    public static let defaultInterval: TimeInterval = 5 * 60

    public let minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = WidgetSnapshotThrottle.defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    /// - Parameters:
    ///   - next: der neue Stand.
    ///   - lastWritten: was in der Datei steht, `nil` ohne Datei.
    ///   - lastWriteAt: wann dieser Lauf zuletzt geschrieben hat, `nil`
    ///     vor dem ersten Schreiben.
    public func decide(
        _ next: WidgetSnapshot, lastWritten: WidgetSnapshot?, lastWriteAt: Date?, now: Date
    ) -> Decision {
        guard let lastWritten else { return .now }
        if next.hasSameContent(as: lastWritten) { return .unchanged }
        guard let lastWriteAt else { return .now }
        if next.withdraws(from: lastWritten) { return .now }
        let due = lastWriteAt.addingTimeInterval(minimumInterval)
        return now >= due ? .now : .later(due)
    }
}

/// Nimmt jeden neuen Stand an und schreibt nach ``WidgetSnapshotThrottle``.
public actor WidgetSnapshotWriter {

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let store: WidgetSnapshotStore
    private let throttle: WidgetSnapshotThrottle
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let didWrite: @Sendable () async -> Void

    /// Was in der Datei steht. Beim ersten Stand einmal gelesen.
    private var lastWritten: WidgetSnapshot?
    private var hasReadFile = false
    private var lastWriteAt: Date?
    /// Der neueste Stand, der auf seinen Zeitpunkt wartet.
    private var pending: WidgetSnapshot?
    private var deferredWrite: Task<Void, Never>?
    /// Welches Warten gilt. Ein abgebrochenes, das trotzdem aufwacht,
    /// schreibt nichts.
    private var deferredToken = 0

    /// - Parameter didWrite: nach jedem Schreiben, etwa um das Widget neu
    ///   zu laden. Erst wenn die Datei steht.
    public init(
        store: WidgetSnapshotStore,
        throttle: WidgetSnapshotThrottle = WidgetSnapshotThrottle(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        didWrite: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.throttle = throttle
        self.now = now
        self.sleep = sleep
        self.didWrite = didWrite
    }

    /// Ein neuer Stand. Schreibt sofort, später oder gar nicht.
    public func submit(_ snapshot: WidgetSnapshot) async {
        loadFileIfNeeded()
        switch throttle.decide(snapshot, lastWritten: lastWritten, lastWriteAt: lastWriteAt, now: now()) {
        case .unchanged:
            // Was wartete, ist überholt: Die Datei zeigt schon den neuesten Stand.
            cancelDeferred()
        case .now:
            await write(snapshot)
        case .later(let due):
            pending = snapshot
            scheduleDeferred(at: due)
        }
    }

    /// Schreibt, was wartet, ohne die Frist abzuwarten. Etwa bevor die App
    /// in den Hintergrund geht.
    public func flush() async {
        guard let pending else { return }
        await write(pending)
    }

    /// Wie oft geschrieben wurde, für Tests und das Protokoll.
    public private(set) var writeCount = 0

    // MARK: - Intern

    private func loadFileIfNeeded() {
        guard !hasReadFile else { return }
        hasReadFile = true
        lastWritten = store.read()
    }

    private func write(_ snapshot: WidgetSnapshot) async {
        cancelDeferred()
        do {
            try store.write(snapshot)
        } catch {
            // Ohne Datei bleibt das Widget beim alten Stand. Der nächste
            // Stand versucht es wieder, denn `lastWritten` bleibt stehen.
            return
        }
        lastWritten = snapshot
        lastWriteAt = now()
        writeCount += 1
        await didWrite()
    }

    private func scheduleDeferred(at due: Date) {
        // Ein Warten läuft schon. Es schreibt dann den neuesten Stand.
        guard deferredWrite == nil else { return }
        deferredToken += 1
        let token = deferredToken
        let delay = max(0, due.timeIntervalSince(now()))
        deferredWrite = Task { [sleep] in
            do { try await sleep(.seconds(delay)) } catch { return }
            await self.deferredWriteFired(token: token)
        }
    }

    private func deferredWriteFired(token: Int) async {
        guard token == deferredToken, let snapshot = pending else { return }
        deferredWrite = nil
        pending = nil
        // Noch einmal nach der Regel: Die Uhr kann gesprungen sein.
        await submit(snapshot)
    }

    private func cancelDeferred() {
        deferredWrite?.cancel()
        deferredWrite = nil
        deferredToken += 1
        pending = nil
    }
}

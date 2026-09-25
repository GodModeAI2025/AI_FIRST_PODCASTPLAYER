//
//  StoreExecutor.swift
//  PodcastAIPersistence
//
//  Der Ausführer der Datenbank: eine eigene serielle Queue.
//
//  `@ModelActor` setzt `DefaultSerialModelExecutor` ein. Der erledigt einen
//  Auftrag auf dem Thread, der ihn einreiht. Fragt das `AppModel` (Hauptakteur)
//  die Datenbank, lief jede Abfrage und jedes Speichern damit auf dem
//  Hauptthread, gleich wo der Speicher gebaut wurde. Hielt zugleich ein Lauf
//  im Hintergrund den Kontext, etwa beim Speichern eines Transkripts, wartete
//  der Hauptthread auf ihn. Beides zeigte sich als Ruckeln in der Oberfläche.
//
//  Hier läuft jeder Auftrag auf derselben seriellen Queue. Der Kontext wird
//  auf ihr gebaut und nur auf ihr benutzt. Die Dienstgüte des Auftrags geht
//  mit, damit eine Abfrage der Oberfläche die Queue anhebt, während dort
//  Arbeit mit niedriger Priorität wartet.
//

#if canImport(SwiftData)
import Foundation
import Dispatch
import SwiftData

/// `@unchecked Sendable` wie `DefaultSerialModelExecutor` selbst: der
/// Kontext ist nicht `Sendable`, wird aber nur auf `queue` benutzt, und die
/// Queue arbeitet einen Auftrag nach dem anderen ab.
final class StoreExecutor: SerialModelExecutor, @unchecked Sendable {

    let modelContext: ModelContext
    private let queue: DispatchSerialQueue

    init(modelContainer: ModelContainer) {
        let queue = DispatchSerialQueue(label: "com.godmodeai.podcastai.store", qos: .default)
        self.queue = queue
        self.modelContext = queue.sync {
            let context = ModelContext(modelContainer)
            // Gespeichert wird ausdrücklich, einmal je Schritt, nicht nach
            // jeder Änderung.
            context.autosaveEnabled = false
            // Eigene Änderungen tragen diesen Namen in der Historie. So erkennt
            // `LibraryStore.hasForeignChanges()` Änderungen von anderen Geräten.
            context.author = LibraryStore.localAuthor
            return context
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority)
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async(qos: qos) {
            unowned.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Die Priorität der Aufgabe als Dienstgüte für die Queue.
    static func qos(for priority: JobPriority) -> DispatchQoS {
        switch TaskPriority(priority) {
        case let value? where value >= .high: .userInitiated
        case let value? where value >= .medium: .default
        case let value? where value >= .low: .utility
        case .some: .background
        case nil: .default
        }
    }
}
#endif

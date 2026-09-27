//
//  SyncObserver.swift
//  PodcastAIKit
//
//  Hört auf Änderungen von anderen Geräten und sagt der App, was sich
//  geändert hat (Plan „Löschen und Sync“, Phase 2). Ersetzt die Schleife in
//  `AppModel.observeRemoteChanges`.
//
//  Der Ablauf je Abgleich:
//  1. Eine Meldung `NSPersistentStoreRemoteChange` kommt. Der Store liest
//     die Historie weiter und liefert ein `ChangeSet`, oder nichts, wenn nur
//     dieses Gerät gespeichert hat.
//  2. Gemerkte Belege vergisst der Store sofort, nicht erst nach der Pause.
//  3. Weitere Meldungen in den nächsten zwei Sekunden kommen dazu. Das
//     Neuladen beginnt erst, wenn es still wird.
//  4. Die Pflege bereinigt Doppelte, beschränkt auf das `ChangeSet`.
//  5. Die App lädt neu, was betroffen ist, und sendet danach
//     `changedElsewhere` an die Stufen.
//
//  Die Reihenfolge von 4 und 5 ist Absicht: Die Stufen gleichen nach
//  `changedElsewhere` mit dem Store ab und sollen dabei keine Doppelten
//  mehr sehen. Deshalb ist das Bereinigen hier ein Schritt vor dem Neuladen
//  und kein Empfänger von `changedElsewhere`.
//
//  Ist alles betroffen (`ChangeSet.all`, etwa bei der ersten Meldung nach
//  dem Start), bereinigt `load()` der App wie beim Start. Hier läuft das
//  Bereinigen dann nicht noch einmal.
//

import Foundation
import CoreData
import PodcastAIPersistence

public actor SyncObserver {

    /// Was die App nach einem Abgleich tut: Dateien der bereinigten Folgen
    /// löschen, neu laden, `changedElsewhere` senden.
    public typealias Apply = @MainActor @Sendable (ChangeSet, LibraryStore.RemovalReport) async -> Void
    /// Der aktuelle Store. Er kann wechseln, wenn die App ihren Speicher
    /// im zweiten Versuch öffnet.
    public typealias StoreProvider = @MainActor @Sendable () -> LibraryStore?

    /// So lange wartet das Neuladen nach der letzten Meldung.
    public static let defaultQuietPeriod: Duration = .seconds(2)

    private let quietPeriod: Duration
    private let currentStore: StoreProvider
    private let apply: Apply

    /// Was sich seit dem letzten Neuladen geändert hat.
    private var pending = ChangeSet.empty
    /// Die Pause vor dem Neuladen. Eine neue Meldung beginnt sie von vorn.
    /// Sie wartet nur; das Neuladen läuft in einer eigenen Aufgabe, die
    /// niemand abbricht. Sonst bräche eine neue Meldung ein laufendes
    /// Neuladen mitten in seinen Abgleichen ab.
    private var quietTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var observing: Task<Void, Never>?
    private var reloading = false
    private var reloadAgain = false

    public init(quietPeriod: Duration = SyncObserver.defaultQuietPeriod,
                store: @escaping StoreProvider, apply: @escaping Apply) {
        self.quietPeriod = quietPeriod
        self.currentStore = store
        self.apply = apply
    }

    /// Hört auf `NSPersistentStoreRemoteChange`. Ein zweiter Aufruf ändert nichts.
    public func start() {
        guard observing == nil else { return }
        observing = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                await self?.remoteChangeArrived()
            }
        }
    }

    /// Hört auf eine eigene Folge von Meldungen, für Tests.
    public func observe(_ triggers: AsyncStream<Void>) async {
        for await _ in triggers { await remoteChangeArrived() }
    }

    /// Eine Meldung ist da. Die Meldung kommt auch nach jedem eigenen
    /// Speichern, etwa nach jedem Abschnitt der Fakten. Weiter geht es nur,
    /// wenn etwas von woanders kam; sonst lud die App während der
    /// Auswertung alle paar Sekunden die ganze Bibliothek neu.
    public func remoteChangeArrived() async {
        guard let store = await currentStore(), let changes = await store.foreignChanges() else { return }
        // Gemerkte Belege und Wörter können überholt sein. Sofort vergessen,
        // nicht erst nach der Pause fürs Neuladen.
        await store.forgetCachedEvidence()
        pending.formUnion(changes)
        quietTask?.cancel()
        let quiet = quietPeriod
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            await self?.quietPeriodEnded()
        }
    }

    /// Die Pause ist um: Neuladen, oder nach dem laufenden noch einmal.
    private func quietPeriodEnded() {
        guard !reloading else {
            reloadAgain = true
            return
        }
        reloading = true
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    /// Wartet, bis Pause und Neuladen fertig sind. Für Tests.
    public func settle() async {
        await quietTask?.value
        await reloadTask?.value
    }

    /// Bereinigt und lädt neu, was sich seit dem letzten Mal geändert hat.
    /// Läuft schon ein Neuladen, kommt das Neue danach dran, nicht daneben.
    private func reload() async {
        defer { reloading = false }
        repeat {
            reloadAgain = false
            let changes = pending
            pending = .empty
            guard !changes.isEmpty, let store = await currentStore() else { continue }
            var report = LibraryStore.RemovalReport()
            if !changes.isEverything {
                // Pflege: nur, was die Änderungen doppelt gemacht haben können.
                report = (try? await store.removeDuplicatesWithReport(in: changes)) ?? LibraryStore.RemovalReport()
            }
            await apply(changes.widened(by: report), report)
        } while reloadAgain
    }
}

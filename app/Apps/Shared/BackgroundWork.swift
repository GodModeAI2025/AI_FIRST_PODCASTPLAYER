//
//  BackgroundWork.swift
//  PodcastAI
//
//  Hintergrundarbeit unter den Regeln des Systems.
//
//  Die ehrliche Version davon: iOS sagt nicht zu, wann BGAppRefresh oder
//  BGProcessing laufen. Ein Produktversprechen „morgens um sieben ist dein
//  Update fertig“ wäre deshalb nicht haltbar. Was die App stattdessen
//  zusagt: sobald das System Zeit gibt, wird gearbeitet — und der Zustand
//  ist jederzeit sichtbar („bereit seit …“, „wartet auf Material“).
//
//  Der Audio-Hintergrundmodus wird ausdrücklich **nicht** als Schlupfloch
//  für Dauerarbeit benutzt. Analyse läuft über BGProcessing und hält an
//  Checkpoints an.
//

import Foundation
import PodcastAIKit

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
public final class BackgroundWork {

    public static let refreshIdentifier = "com.podcastai.refresh"
    public static let analysisIdentifier = "com.podcastai.analysis"

    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    #if canImport(BackgroundTasks) && os(iOS)

    /// Muss beim Start registriert werden, bevor die App fertig geladen ist —
    /// `AppBootstrap.start(with:)` ruft das aus `init` des App-Typs.
    ///
    /// `using: .main` ist kein Geschmack: mit `nil` läuft der Startblock auf
    /// einer Hintergrundwarteschlange, und die `BGTask`-Instanz müsste eine
    /// Actor-Grenze überqueren. Sie ist nicht `Sendable`; Swift 6 lehnt das
    /// ab. Auf dem Hauptthread ist `assumeIsolated` keine Behauptung,
    /// sondern eine Feststellung.
    public func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleRefresh(refresh)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.analysisIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleAnalysis(processing)
            }
        }
    }

    public func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        // Frühestens in einer Stunde. Häufiger anzufragen bringt nichts —
        // das System entscheidet ohnehin, und zu häufige Anfragen führen
        // dazu, dass es seltener zustimmt.
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    public func scheduleAnalysis() {
        let request = BGProcessingTaskRequest(identifier: Self.analysisIdentifier)
        // Analyse ist rechenintensiv. Netz ja, Strom ja — sonst leert sie
        // unterwegs den Akku.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date().addingTimeInterval(60 * 15)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        // Immer zuerst die nächste Ausführung anfragen, bevor gearbeitet
        // wird: bricht die Arbeit ab, ist die Kette sonst unterbrochen.
        scheduleRefresh()

        let work = Task { @MainActor in await model.refreshAll() }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    /// Das Fenster, in dem lange Arbeit tatsächlich erlaubt ist.
    ///
    /// Hier wird erschlossen — nicht im Audio-Hintergrundmodus. Der ist für
    /// Wiedergabe da, und ihn für Dauerarbeit zu benutzen wäre genau der
    /// Missbrauch, den die Systemvorgaben verbieten und den dieses Projekt
    /// ausdrücklich ausgeschlossen hat.
    ///
    /// `expirationHandler` bricht ab, wenn das Fenster zugeht. Das ist kein
    /// Verlust: die Pipeline hält am nächsten Prüfpunkt an und der Stand
    /// liegt in der Datenbank. Beim nächsten Fenster geht es dort weiter.
    private func handleAnalysis(_ task: BGProcessingTask) {
        scheduleAnalysis()

        let work = Task { @MainActor [model] in
            // Erst erschliessen, dann Ausgaben bauen. Die Reihenfolge ist
            // wichtig: eine Ausgabe entsteht aus Belegen, und die entstehen
            // beim Erschliessen. Andersherum bliebe die erste Ausgabe nach
            // jedem Hintergrundlauf eine Runde hinterher.
            await model.workQueue()?.value
            await model.processPendingEditions()
        }
        task.expirationHandler = {
            work.cancel()
            // Der Warteschlangenarbeiter hält seine laufende Analyse selbst
            // an; `work.cancel()` allein erreicht sie nicht, weil sie in
            // einem eigenen Vorgang läuft.
            Task { @MainActor in model.pauseQueue() }
        }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    /// Meldet an, sobald überhaupt etwas zu tun ist.
    ///
    /// Ohne diesen Aufruf käme der erste Analyselauf erst nach dem
    /// Zeitfenster, das beim App-Start angefragt wurde — im Zweifel Stunden
    /// später, obwohl der Nutzer gerade eben auf „Erschliessen“ gedrückt hat.
    public func scheduleAnalysisSoon() {
        let request = BGProcessingTaskRequest(identifier: Self.analysisIdentifier)
        request.requiresNetworkConnectivity = true
        // **Kein** `requiresExternalPower` hier. Die reguläre Anfrage
        // verlangt Strom, weil Transkription teuer ist; diese hier soll
        // aber zeitnah drankommen, und am Ladekabel hängt ein Telefon
        // tagsüber selten. Der Unterschied entscheidet darüber, ob aus
        // „im Hintergrund“ Minuten oder Stunden werden.
        request.requiresExternalPower = false
        request.earliestBeginDate = nil
        try? BGTaskScheduler.shared.submit(request)
    }

    #else

    /// Auf dem Mac gibt es keinen BGTaskScheduler — dort läuft die App als
    /// Prozess weiter, solange sie nicht beendet wird. Fenster schliessen
    /// und App beenden sind verschiedene Zustände.
    public func register() {}
    public func scheduleRefresh() {}
    public func scheduleAnalysis() {}
    public func scheduleAnalysisSoon() {}

    #endif
}

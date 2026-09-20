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

    /// Muss beim Start registriert werden, bevor die App fertig geladen ist.
    public func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await self.handleRefresh(refresh) }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.analysisIdentifier, using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await self.handleAnalysis(processing) }
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

    private func handleRefresh(_ task: BGAppRefreshTask) async {
        // Immer zuerst die nächste Ausführung anfragen, bevor gearbeitet
        // wird: bricht die Arbeit ab, ist die Kette sonst unterbrochen.
        scheduleRefresh()

        let work = Task { await model.refreshAll() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    private func handleAnalysis(_ task: BGProcessingTask) async {
        scheduleAnalysis()

        let work = Task { await model.processPendingEditions() }
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    #else

    /// Auf dem Mac gibt es keinen BGTaskScheduler — dort läuft die App als
    /// Prozess weiter, solange sie nicht beendet wird. Fenster schliessen
    /// und App beenden sind verschiedene Zustände.
    public func register() {}
    public func scheduleRefresh() {}
    public func scheduleAnalysis() {}

    #endif
}

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
        submit(request)
    }

    public func scheduleAnalysis() {
        let request = BGProcessingTaskRequest(identifier: Self.analysisIdentifier)
        // Analyse ist rechenintensiv. Netz ja, Strom ja — sonst leert sie
        // unterwegs den Akku.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date().addingTimeInterval(60 * 15)
        submit(request)
    }

    /// Reicht einen Auftrag ein. Ein abgelehnter Auftrag wird protokolliert,
    /// nicht verschluckt: ohne passenden Hintergrundmodus in der Info.plist
    /// lehnt iOS ihn still ab, und niemand merkt, dass nichts mehr läuft.
    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Hintergrundauftrag %@ nicht eingereicht: %@",
                  request.identifier, error.localizedDescription)
        }
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        // Immer zuerst die nächste Ausführung anfragen, bevor gearbeitet
        // wird: bricht die Arbeit ab, ist die Kette sonst unterbrochen.
        scheduleRefresh()

        // Nach einem Start im Hintergrund hat noch niemand geladen.
        let work = Task { @MainActor in
            await model.ensureLoaded()
            await model.refreshAll()
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    private func handleAnalysis(_ task: BGProcessingTask) {
        scheduleAnalysis()

        let work = Task { @MainActor in
            await model.ensureLoaded()
            await model.processPendingEditions()
            // Fakten, die noch fehlen: nach einem Abbruch, einem Fehlschlag
            // oder für Folgen, die ein anderes Gerät transkribiert hat. Endet
            // die Zeit, bricht die laufende Folge ab und bleibt vorn stehen.
            await model.processPendingFacts()
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    #else

    /// Auf dem Mac gibt es keinen BGTaskScheduler — dort läuft die App als
    /// Prozess weiter, solange sie nicht beendet wird. Fenster schliessen
    /// und App beenden sind verschiedene Zustände. Die Fakten sammelt dort
    /// die Warteschlange im Modell, solange die App läuft.
    public func register() {}
    public func scheduleRefresh() {}
    public func scheduleAnalysis() {}

    #endif
}

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
//  Checkpoints an. Die Fakten arbeiten im Hintergrund nur hier in der
//  Aufgabe `com.podcastai.analysis` oder neben Transkripten, die unter der
//  fortgesetzten Verarbeitung entstehen. Geht die App sonst in den
//  Hintergrund, hält die laufende Folge an und bleibt vorn in der
//  Warteschlange.
//

import Foundation
import Synchronization
import PodcastAIKit

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
public final class BackgroundWork {

    public static let refreshIdentifier = "com.podcastai.refresh"
    public static let analysisIdentifier = "com.podcastai.analysis"
    /// Leichte Aufgabe nur für die Tags je Kapitel, ohne Strom.
    public static let taggingIdentifier = "com.podcastai.tagging"

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

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taggingIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleTagging(processing)
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

    /// Tags je Kapitel für die übrige Bibliothek. Leichter als die Analyse:
    /// ein Aufruf wählt nur aus einer Liste, deshalb ohne Strom und ohne
    /// Netz. Das System darf die Aufgabe trotzdem auf später legen, wenn der
    /// Akku es verlangt. Ohne Strom bleibt die CPU-Überwachung des Systems
    /// an; läuft die Zeit ab, bleibt der Stand der Folge gemerkt.
    public func scheduleTagging() {
        let request = BGProcessingTaskRequest(identifier: Self.taggingIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(60 * 30)
        submit(request)
    }

    /// Reicht einen Auftrag ein. Ein abgelehnter Auftrag wird protokolliert,
    /// nicht verschluckt: ohne passenden Hintergrundmodus in der Info.plist
    /// lehnt iOS ihn still ab, und niemand merkt, dass nichts mehr läuft.
    private func submit(_ request: sending BGTaskRequest) {
        // Das System will die Anfrage nicht vom Hauptthread.
        Task.detached(priority: .utility) {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                NSLog("Hintergrundauftrag %@ nicht eingereicht: %@",
                      request.identifier, error.localizedDescription)
            }
        }
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        // Immer zuerst die nächste Ausführung anfragen, bevor gearbeitet
        // wird: bricht die Arbeit ab, ist die Kette sonst unterbrochen.
        scheduleRefresh()

        // Nach einem Start im Hintergrund hat noch niemand geladen. Nur die
        // Feeds: Transkripte beginnen nur vorn, und Fakten und Themen-Updates
        // gehören in die Aufgabe `com.podcastai.analysis`, die Strom hat.
        let work = Task { @MainActor in
            await model.ensureLoaded()
            await model.refreshAll(feedsOnly: true)
        }
        let completion = TaskCompletion(task)
        task.expirationHandler = { [model] in
            work.cancel()
            // Laufen Transkripte ohne fortgesetzte Verarbeitung, halten sie
            // mit Zwischenstand an, statt mitten im Schub eingefroren zu werden.
            Task { @MainActor in model.stopTranscriptsWithoutCarrier() }
            completion.finish(success: false)
        }
        Task { @MainActor in
            _ = await work.result
            completion.finish(success: !work.isCancelled)
        }
    }

    private func handleAnalysis(_ task: BGProcessingTask) {
        scheduleAnalysis()

        // Die Aufgabe gibt Fakten und Themen-Updates Zeit, auch im
        // Hintergrund. Der Träger steht am Tor, bevor gearbeitet wird.
        let carrier = model.holdCarrier(.analysisTask)
        let work = Task { @MainActor in
            await model.ensureLoaded()
            await model.processPendingEditions()
            // Fakten, die noch fehlen: nach einem Abbruch, einem Fehlschlag
            // oder für Folgen, die ein anderes Gerät transkribiert hat. Endet
            // die Zeit, bricht die laufende Folge ab und bleibt vorn stehen.
            await model.processPendingFacts()
        }
        let completion = TaskCompletion(task)
        task.expirationHandler = { [model] in
            // Erst den Träger entziehen: Die Stufe „Wissen“ hält am Tor an,
            // ohne dass es als Fehlschlag zählt.
            carrier?.release()
            work.cancel()
            Task { @MainActor in
                model.releaseCarrier(carrier)
                model.stopTranscriptsWithoutCarrier()
            }
            completion.finish(success: false)
        }
        Task { @MainActor in
            _ = await work.result
            model.releaseCarrier(carrier)
            completion.finish(success: !work.isCancelled)
        }
    }

    private func handleTagging(_ task: BGProcessingTask) {
        scheduleTagging()

        // Zeit nur für die Tags, nicht für die Fakten.
        let carrier = model.holdCarrier(.taggingTask)
        let work = Task { @MainActor in
            await model.ensureLoaded()
            // Nur Tags. Fakten und Themen-Updates bleiben der Aufgabe mit Strom.
            await model.processPendingTags()
        }
        let completion = TaskCompletion(task)
        task.expirationHandler = { [model] in
            carrier?.release()
            work.cancel()
            Task { @MainActor in model.releaseCarrier(carrier) }
            completion.finish(success: false)
        }
        Task { @MainActor in
            _ = await work.result
            model.releaseCarrier(carrier)
            completion.finish(success: !work.isCancelled)
        }
    }

    #else

    /// Auf dem Mac gibt es keinen BGTaskScheduler — dort läuft die App als
    /// Prozess weiter, solange sie nicht beendet wird. Fenster schließen
    /// und App beenden sind verschiedene Zustände. Die Fakten sammelt dort
    /// die Warteschlange im Modell, solange die App läuft.
    public func register() {}
    public func scheduleRefresh() {}
    public func scheduleAnalysis() {}
    public func scheduleTagging() {}

    #endif
}

#if canImport(BackgroundTasks) && os(iOS)
/// Meldet eine Hintergrundaufgabe genau einmal als fertig. Endet ihre Zeit,
/// meldet der `expirationHandler` selbst, und die Arbeit meldet danach
/// nicht noch einmal. Ein zweiter Aufruf von `setTaskCompleted` wäre ein
/// Fehler gegenüber dem System.
///
/// `@unchecked`: `BGTask` ist nicht als `Sendable` markiert. Das System ruft
/// den `expirationHandler` auf einer eigenen Queue, und `setTaskCompleted`
/// ist von dort vorgesehen. Hier geschieht es genau einmal, hinter der Sperre.
private final class TaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let done = Mutex(false)

    init(_ task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        let first = done.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { task.setTaskCompleted(success: success) }
    }
}
#endif

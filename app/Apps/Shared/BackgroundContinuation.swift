//
//  BackgroundContinuation.swift
//  PodcastAI
//
//  Hält die Erschließung am Leben, wenn die App in den Hintergrund geht.
//
//  Auf dem iPhone meldet die App dafür eine „fortgesetzte Verarbeitung“ an
//  (`BGContinuedProcessingTask`). Das System zeigt dann eine
//  Fortschrittsanzeige und lässt die Arbeit weiterlaufen, solange die
//  Anzeige Fortschritt sieht; eine Aufgabe, die hängend wirkt, beendet es
//  (BGTask.h im SDK 27.0). Die Anmeldung gilt nur für die App, die gerade
//  vorn ist. Deshalb meldet die App sie an, wenn ein Lauf beginnt und
//  spätestens, wenn sie inaktiv wird, noch bevor sie in den Hintergrund geht
//  (`AppModel.beginBackgroundRunIfNeeded`). Klappt die Anmeldung nicht,
//  bleibt die kurze Hintergrundzeit von UIKit. Der Mac braucht nichts davon.
//
//  Eine Anmeldung trägt den ganzen Lauf: Transkripte, danach Fakten und
//  Kapitel-Tags, bis nichts mehr ansteht. Solange sie läuft, hält sie den
//  Träger `.continued` am Tor, damit Fakten und Tags auch nach dem letzten
//  Transkript im Hintergrund weiterlaufen dürfen. Den Fortschritt rechnet
//  `BackgroundRunProgress` im Paket: eine Summe über die Warteschlange, die
//  nur wächst, mit einem Herzschlag für lange Schritte ohne Meldung.
//
//  Endet die Zeit, gibt die Anmeldung den Träger zurück. Transkripte halten
//  mit Zwischenstand an, Fakten und Tags am Tor; alles bleibt vorn in der
//  Warteschlange und läuft weiter, sobald die App wieder vorn ist.
//

import Foundation
import PodcastAIKit

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@MainActor
public final class BackgroundContinuation {

    public static let identifierPrefix = "com.godmodeai.podcastai.mobile.analysis"

    /// Die Überschrift der Fortschrittsanzeige für einen Schritt.
    static func title(for step: BackgroundRunProgress.Step) -> String {
        switch step {
        case .transcript:
            String(localized: "Transkripte erstellen", comment: "Titel der Fortschrittsanzeige im Hintergrund")
        case .facts:
            String(localized: "Fakten sammeln", comment: "Titel der Fortschrittsanzeige im Hintergrund")
        case .tags:
            String(localized: "Kapitel einordnen", comment: "Titel der Fortschrittsanzeige im Hintergrund")
        }
    }

    #if os(iOS)
    private var task: BGContinuedProcessingTask?
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid
    private var heartbeat: Task<Void, Never>?
    #endif
    private var title: String
    private var subtitle: String
    /// Der Fortschritt über den ganzen Lauf.
    private(set) var progress = BackgroundRunProgress()
    /// Der Träger `.continued` am Tor, solange die Anmeldung trägt.
    private var lease: WorkLease?
    private var ended = false
    /// Wird gerufen, wenn die Zeit des Systems endet. Die Arbeit hält dann an
    /// und bleibt vorn in der Warteschlange.
    private let onExpire: @MainActor () -> Void

    /// Wer die Arbeit im Hintergrund gerade trägt, für die Mitteilung
    /// „Transkripte pausieren“.
    public private(set) var carrier: TranscriptPauseNotice.Carrier = .none

    private init(title: String, subtitle: String, lease: WorkLease?, onExpire: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.lease = lease
        self.onExpire = onExpire
    }

    /// Beginnt eine Hintergrundphase für den ganzen Lauf. `lease` ist der
    /// Träger am Tor; er geht mit dem Ende oder dem Ablauf zurück.
    public static func begin(
        title: String, subtitle: String, lease: WorkLease? = nil,
        onExpire: @escaping @MainActor () -> Void = {}
    ) -> BackgroundContinuation {
        let continuation = BackgroundContinuation(title: title, subtitle: subtitle, lease: lease, onExpire: onExpire)
        #if os(iOS)
        continuation.start()
        #endif
        return continuation
    }

    /// Angemeldet oder schon getragen, und nicht zu Ende.
    public var isActive: Bool {
        !ended && (carrier == .pending || carrier == .carrying)
    }

    /// Gehört der laufende Schritt schon zu dieser Folge?
    func isCurrent(_ step: BackgroundRunProgress.Step, episode: EpisodeID) -> Bool {
        progress.current == step && progress.currentEpisode == episode
    }

    /// Meldet eine neue Folge, die gerade erschlossen wird.
    public func setSubtitle(_ subtitle: String) {
        self.subtitle = subtitle
        #if os(iOS)
        task?.updateTitle(title, subtitle: subtitle)
        #endif
    }

    /// Ein Schritt meldet, wie weit er ist. Ein neuer Schritt schließt den
    /// vorigen ab; der Stand wächst nur. Mit `subtitle` wechselt auch die
    /// Zeile unter der Überschrift, etwa auf den Titel der Folge.
    func report(_ step: BackgroundRunProgress.Step, episode: EpisodeID,
                _ phase: BackgroundRunProgress.Phase, subtitle: String? = nil) {
        guard !ended else { return }
        let changedStep = progress.current != step
        progress.report(step, episode: episode, phase)
        if changedStep || subtitle != nil {
            title = Self.title(for: step)
            if let subtitle { self.subtitle = subtitle }
            #if os(iOS)
            task?.updateTitle(title, subtitle: self.subtitle)
            #endif
        }
        applyProgress()
    }

    /// Wie bisher aus dem Transkript: die Stufe der Folge, dazu der Anteil
    /// des Transkripts (`fraction`) oder des Downloads (`downloadFraction`).
    public func update(_ stage: ProcessingStage, episode: EpisodeID,
                       fraction: Double? = nil, downloadFraction: Double? = nil) {
        let phase: BackgroundRunProgress.Phase
        if let fraction {
            phase = .transcription(fraction)
        } else if let downloadFraction {
            phase = .download(downloadFraction)
        } else {
            phase = switch stage {
            case .discovered: .download(0)
            case .mediaDownloaded: .download(1)
            case .transcribed, .evidenceExtracted, .failed: .transcribed
            }
        }
        report(.transcript, episode: episode, phase)
    }

    /// Was nach dem laufenden Schritt noch aussteht.
    func expect(_ expected: BackgroundRunProgress.Expected) {
        guard !ended, expected != progress.expected else { return }
        progress.expect(expected)
        applyProgress()
    }

    public func end() {
        guard !ended else { return }
        ended = true
        carrier = .none
        lease?.release()
        lease = nil
        #if os(iOS)
        heartbeat?.cancel()
        heartbeat = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
            self.task = nil
        }
        if fallbackID != .invalid {
            UIApplication.shared.endBackgroundTask(fallbackID)
            fallbackID = .invalid
        }
        #endif
    }

    private func applyProgress() {
        #if os(iOS)
        guard let task else { return }
        // Erst die Gesamtzahl, sie liegt immer über dem Stand.
        let total = progress.totalUnitCount
        if task.progress.totalUnitCount != total { task.progress.totalUnitCount = total }
        let completed = progress.completedUnitCount
        if task.progress.completedUnitCount != completed { task.progress.completedUnitCount = completed }
        #endif
    }

    #if os(iOS)
    private func start() {
        // Kurze Hintergrundzeit als Netz, bis die fortgesetzte Verarbeitung läuft.
        fallbackID = UIApplication.shared.beginBackgroundTask(withName: "Erschließen") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fallbackID != .invalid else { return }
                UIApplication.shared.endBackgroundTask(self.fallbackID)
                self.fallbackID = .invalid
                // Ohne fortgesetzte Verarbeitung war das die letzte Zeit.
                if self.task == nil, !self.ended { self.expire() }
            }
        }

        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] bgTask in
            MainActor.assumeIsolated {
                guard let processing = bgTask as? BGContinuedProcessingTask else {
                    bgTask.setTaskCompleted(success: false)
                    return
                }
                guard let self, !self.ended else {
                    processing.setTaskCompleted(success: true)
                    return
                }
                self.attach(processing)
            }
        }
        guard registered else { return }
        carrier = .pending
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Sofort oder gar nicht: Die Mitteilung „Transkripte pausieren“
        // wartet nur kurz auf die Antwort.
        request.strategy = .fail
        // Das System will die Anfrage nicht vom Hauptthread.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                // Abgelehnt, etwa weil die App schon im Hintergrund war.
                await self?.submissionFailed()
            }
        }
    }

    private func submissionFailed() {
        if carrier == .pending { carrier = .none }
    }

    private func attach(_ processing: BGContinuedProcessingTask) {
        task = processing
        carrier = .carrying
        processing.progress.totalUnitCount = progress.totalUnitCount
        processing.progress.completedUnitCount = progress.completedUnitCount
        processing.updateTitle(title, subtitle: subtitle)
        processing.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let task = self.task else { return }
                task.setTaskCompleted(success: false)
                self.task = nil
                self.expire()
            }
        }
        startHeartbeat()
    }

    /// Ein Takt alle paar Sekunden: Steht der laufende Schritt ohne Meldung,
    /// rückt die Anzeige ein wenig vor (`BackgroundRunProgress.tick`).
    private func startHeartbeat() {
        heartbeat?.cancel()
        let interval = BackgroundRunProgress.creepInterval
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, !self.ended, self.task != nil else { return }
                self.progress.tick(seconds: interval)
                self.applyProgress()
            }
        }
    }

    /// Die Zeit ist um. Der Träger geht zurück, die Arbeit hält an, ihr
    /// Zwischenstand bleibt.
    private func expire() {
        guard !ended else { return }
        carrier = .expired
        heartbeat?.cancel()
        heartbeat = nil
        lease?.release()
        lease = nil
        onExpire()
    }
    #endif
}

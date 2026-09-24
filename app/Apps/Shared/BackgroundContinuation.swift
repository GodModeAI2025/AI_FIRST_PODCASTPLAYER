//
//  BackgroundContinuation.swift
//  PodcastAI
//
//  Hält die Erschließung am Leben, wenn die App in den Hintergrund geht.
//
//  Auf dem iPhone meldet die App dafür eine „fortgesetzte Verarbeitung“ an.
//  Das System zeigt dann eine Fortschrittsanzeige und lässt die Arbeit
//  weiterlaufen, solange die Anzeige Fortschritt sieht. Klappt die
//  Anmeldung nicht, etwa weil die App schon im Hintergrund ist, bleibt die
//  kurze Hintergrundzeit von UIKit. Der Mac braucht nichts davon.
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

    #if os(iOS)
    /// Die Überschrift der Fortschrittsanzeige des Systems.
    private static var displayTitle: String {
        String(localized: "Transkripte erstellen", comment: "Titel der Fortschrittsanzeige im Hintergrund")
    }

    private var task: BGContinuedProcessingTask?
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid
    private var pendingProgress: Int64 = 0
    private var pendingSubtitle: String
    #endif
    private var ended = false
    /// Wird gerufen, wenn die Zeit des Systems endet. Die Arbeit hält dann an
    /// und bleibt vorn in der Warteschlange.
    private let onExpire: @MainActor () -> Void

    /// Wer die Arbeit im Hintergrund gerade trägt, für die Mitteilung
    /// „Transkripte pausieren“.
    public private(set) var carrier: TranscriptPauseNotice.Carrier = .none

    private init(title: String, onExpire: @escaping @MainActor () -> Void) {
        self.onExpire = onExpire
        #if os(iOS)
        pendingSubtitle = title
        #endif
    }

    /// Beginnt eine Hintergrundphase für die ganze Warteschlange.
    public static func begin(
        title: String, onExpire: @escaping @MainActor () -> Void = {}
    ) -> BackgroundContinuation {
        let continuation = BackgroundContinuation(title: title, onExpire: onExpire)
        #if os(iOS)
        continuation.start(subtitle: title)
        #endif
        return continuation
    }

    /// Meldet eine neue Folge, die gerade erschlossen wird.
    public func setSubtitle(_ subtitle: String) {
        #if os(iOS)
        pendingSubtitle = subtitle
        task?.updateTitle(Self.displayTitle, subtitle: subtitle)
        #endif
    }

    /// Meldet den Fortschritt der laufenden Folge. `fraction` ist der Anteil
    /// des Transkripts, von 0 bis 1. Er füllt die Strecke zwischen „geladen“
    /// und „transkribiert“ in feinen Schritten, damit das System Fortschritt
    /// sieht und die Arbeit nicht für hängend hält.
    public func update(_ stage: ProcessingStage, fraction: Double? = nil) {
        #if os(iOS)
        let value: Int64
        if let fraction {
            value = 100 + Int64((min(max(fraction, 0), 1) * 850).rounded())
        } else {
            value = switch stage {
            case .discovered: 20
            case .mediaDownloaded: 100
            case .transcribed: 950
            case .evidenceExtracted, .failed: 1_000
            }
        }
        // Eine neue Folge beginnt wieder vorn. Innerhalb einer Folge geht es
        // nur vorwärts.
        guard stage == .discovered || value >= pendingProgress else { return }
        pendingProgress = value
        task?.progress.completedUnitCount = value
        #endif
    }

    public func end() {
        guard !ended else { return }
        ended = true
        carrier = .none
        #if os(iOS)
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

    #if os(iOS)
    private func start(subtitle: String) {
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
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: Self.displayTitle, subtitle: subtitle
        )
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
        processing.progress.totalUnitCount = 1_000
        processing.progress.completedUnitCount = pendingProgress
        processing.updateTitle(Self.displayTitle, subtitle: pendingSubtitle)
        processing.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let task = self.task else { return }
                task.setTaskCompleted(success: false)
                self.task = nil
                self.expire()
            }
        }
    }

    /// Die Zeit ist um. Die Arbeit hält an, ihr Zwischenstand bleibt.
    private func expire() {
        guard !ended else { return }
        carrier = .expired
        onExpire()
    }
    #endif
}

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

    private init(title: String) {
        #if os(iOS)
        pendingSubtitle = title
        #endif
    }

    /// Beginnt eine Hintergrundphase für die ganze Warteschlange.
    public static func begin(title: String) -> BackgroundContinuation {
        let continuation = BackgroundContinuation(title: title)
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

    /// Meldet den Fortschritt der laufenden Folge.
    public func update(_ stage: ProcessingStage) {
        #if os(iOS)
        let value: Int64 = switch stage {
        case .discovered: 5
        case .mediaDownloaded: 30
        case .transcribed: 85
        case .evidenceExtracted, .failed: 100
        }
        pendingProgress = value
        task?.progress.completedUnitCount = value
        #endif
    }

    public func end() {
        guard !ended else { return }
        ended = true
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
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: Self.displayTitle, subtitle: subtitle
        )
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    private func attach(_ processing: BGContinuedProcessingTask) {
        task = processing
        processing.progress.totalUnitCount = 100
        processing.progress.completedUnitCount = pendingProgress
        processing.updateTitle(Self.displayTitle, subtitle: pendingSubtitle)
        processing.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let task = self.task else { return }
                task.setTaskCompleted(success: false)
                self.task = nil
            }
        }
    }
    #endif
}

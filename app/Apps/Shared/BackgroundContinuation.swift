//
//  BackgroundContinuation.swift
//  PodcastAI
//
//  Der Moment, in dem der Nutzer die App verlässt.
//
//  Das ist der häufigste Fall und der, den ein Hintergrundfenster **nicht**
//  abdeckt: wer „Erschliessen“ drückt und dann zu etwas anderem wechselt,
//  wird von iOS binnen Sekunden angehalten. Ohne das hier wäre die Arbeit
//  mitten im Satz weg — nicht verloren, seit es Prüfpunkte gibt, aber der
//  Weg bis zum nächsten schon.
//
//  `beginBackgroundTask` kauft dafür rund dreissig Sekunden. **Das reicht
//  nicht, um eine Folge fertig zu analysieren, und soll es auch nicht.**
//  Es reicht, um den nächsten Prüfpunkt zu erreichen und sauber anzuhalten.
//  Den Rest erledigt `BGProcessingTask`, wenn das System Zeit gibt.
//
//  Was hier ausdrücklich nicht passiert: den Audio-Hintergrundmodus
//  benutzen, um weiterzurechnen. Der ist für Wiedergabe da. Ihn dafür zu
//  missbrauchen ist der klassische Weg, sich aus dem App Store zu
//  entfernen — und es wäre auch schlicht unredlich gegenüber dem Akku des
//  Nutzers.
//

import Foundation

#if canImport(UIKit) && os(iOS)
import UIKit

@MainActor
public final class BackgroundContinuation {

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: Task<Void, Never>?

    public init() {}

    /// Die App geht in den Hintergrund. Noch einen Prüfpunkt schaffen.
    public func appDidEnterBackground(model: AppModel) {
        guard model.isWorkingQueue, identifier == .invalid else { return }

        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Erschliessen bis zum Prüfpunkt"
        ) { [weak self] in
            // Das System nimmt die Zeit zurück. Sofort anhalten — wer hier
            // weiterrechnet, wird hart beendet, und *das* kostet den Stand
            // seit dem letzten Prüfpunkt.
            self?.stop(model: model)
        }

        // Nicht bis zur letzten Sekunde warten: `backgroundTimeRemaining`
        // ist eine Schätzung, und ein Prüfpunkt braucht selbst noch einen
        // Moment zum Schreiben.
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.stop(model: model)
        }
    }

    /// Die App ist wieder da. Die geliehene Zeit zurückgeben und
    /// weiterarbeiten.
    public func appWillEnterForeground(model: AppModel) {
        endAssertion()
        model.workQueue()
    }

    private func stop(model: AppModel) {
        model.pauseQueue()
        endAssertion()
    }

    private func endAssertion() {
        watchdog?.cancel()
        watchdog = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

#else

/// Auf dem Mac gibt es diesen Übergang nicht: eine App im Hintergrund läuft
/// weiter, solange sie nicht beendet wird. Fenster schliessen und App
/// beenden sind verschiedene Zustände.
@MainActor
public final class BackgroundContinuation {
    public init() {}
    public func appDidEnterBackground(model: AppModel) {}
    public func appWillEnterForeground(model: AppModel) { model.workQueue() }
}

#endif

//
//  AppBootstrap.swift
//  PodcastAI
//
//  Was beim Start passieren muss, bevor irgendetwas anderes passiert.
//
//  Drei Dinge standen bisher nirgends, und alle drei fallen erst zur
//  Laufzeit auf — nicht beim Übersetzen:
//
//  1. `@Dependency var model: AppModel` in den App Intents löst die
//     Abhängigkeit über `AppDependencyManager` auf. Wird sie dort nie
//     eingetragen, stürzt **jeder** Intent beim ersten Zugriff ab. Genau
//     die Aufrufe von Siri und aus der Kurzbefehle-App, für die das
//     Kapitel „agentenfähig“ steht.
//  2. Ohne konfigurierte `AVAudioSession` bricht der Ton ab, sobald die App
//     in den Hintergrund geht, und mischt sich falsch mit anderem Ton. Die
//     Kategorie ist `.playback` mit Modus `.spokenAudio` — gesprochenes
//     Wort, nicht Musik: das System wählt danach die Sprachverbesserung und
//     das richtige Verhalten bei AirPlay und Auto.
//  3. `BGTaskScheduler.register` muss laufen, **bevor** der Start fertig
//     ist. In `.task` einer Ansicht ist es zu spät; iOS wirft dann eine
//     Ausnahme über einen nicht registrierten Bezeichner.
//

import Foundation
import PodcastAIKit

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public enum AppBootstrap {

    /// Richtet alles ein, was vor dem ersten Bild stehen muss, und gibt die
    /// Hintergrundarbeit zurück, damit der Aufrufer sie behält.
    ///
    /// Die Rückgabe ist kein Zierrat: `BackgroundWork` muss jemand halten.
    @discardableResult
    public static func start(with model: AppModel) -> BackgroundWork {
        registerIntentDependencies(model)
        configureAudioSession()

        let background = BackgroundWork(model: model)
        background.register()
        // Ein neuer Auftrag fragt sofort ein Hintergrundfenster an, statt
        // auf das nächste reguläre zu warten. Ohne das läge eine Folge, die
        // der Nutzer gerade angestossen hat, im Zweifel Stunden herum.
        model.onAnalysisRequested = { [weak background] in
            background?.scheduleAnalysisSoon()
        }
        return background
    }

    private static func registerIntentDependencies(_ model: AppModel) {
        #if canImport(AppIntents)
        AppDependencyManager.shared.add(dependency: model)
        #endif
    }

    /// Die Audiositzung für gesprochenes Wort.
    ///
    /// `.spokenAudio` statt `.default` ist kein Detail: damit pausiert die
    /// App anderes gesprochenes Audio, statt darüberzulegen, und im Auto
    /// verhält sie sich wie ein Podcast und nicht wie ein Klingelton.
    private static func configureAudioSession() {
        #if canImport(AVFoundation) && os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            // Kein Abbruch: die App bleibt bedienbar, nur der Ton kann sich
            // anders verhalten. Gemeldet wird es trotzdem.
            NSLog("Audiositzung konnte nicht eingerichtet werden: %@",
                  error.localizedDescription)
        }
        #endif
    }
}

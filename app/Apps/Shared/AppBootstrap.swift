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
import SwiftData
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
        return background
    }

    /// Öffnet die Datenbank, wenn möglich mit iCloud-Abgleich.
    ///
    /// UI-Tests starten mit `-uitest-fresh` und einem leeren Speicher im
    /// Arbeitsspeicher, damit Quellen aus einem früheren Test nicht mitzählen.
    /// Klappt der Abgleich nicht, bleibt der Speicher lokal; klappt auch das
    /// nicht, läuft die App mit einem flüchtigen Speicher und sagt es.
    public static func openStore() -> (container: ModelContainer, description: String, failure: String?) {
        #if DEBUG
        // Entwicklerschalter: CloudKit-Schema anlegen und beenden.
        if ProcessInfo.processInfo.arguments.contains("-initialize-cloudkit-schema") {
            do {
                try LibraryStore.initializeCloudKitSchema(containerIdentifier: "iCloud.com.godmodeai.podcastai")
                print("CLOUDKIT-SCHEMA: angelegt")
                exit(0)
            } catch {
                print("CLOUDKIT-SCHEMA: Fehler \(error)")
                exit(1)
            }
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("-uitest-fresh") {
            return (try! LibraryStore.makeContainer(inMemory: true), "Test, nur im Arbeitsspeicher", nil)
        }
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        if let container = try? LibraryStore.openPersistentContainer(sync: true) {
            let description = signedIn
                ? "Aktiv, über deine private iCloud-Datenbank"
                : "Nicht bei iCloud angemeldet, die Daten bleiben auf diesem Gerät"
            return (container, description, nil)
        }
        // Erst hier, nachdem auch der Abgleich gescheitert ist, darf ein
        // unpassender alter Speicher beiseitegelegt werden. Dann sagt die
        // App es auch.
        if let opened = try? LibraryStore.openLocalContainer() {
            return (opened.container, "Aus, die Daten bleiben auf diesem Gerät", opened.recoveryNote)
        }
        let container = try! LibraryStore.makeContainer(inMemory: true)
        return (container, "Aus", "Die Datenbank liess sich nicht öffnen. Die App läuft ohne Speicher.")
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

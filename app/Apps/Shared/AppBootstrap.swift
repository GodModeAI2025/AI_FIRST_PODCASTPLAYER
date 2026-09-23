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
import SwiftUI
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

    /// Was `openStore()` geöffnet hat, und was der Nutzer davon wissen muss.
    public struct OpenedStore {
        public let container: ModelContainer
        public let description: String
        /// Gesetzt, wenn beim Öffnen etwas schiefging.
        public let failure: String?
        /// Die App läuft ohne Speicher auf der Platte. Nur dann bringt ein
        /// zweiter Versuch etwas.
        public var isTemporary = false
    }

    /// Öffnet die Datenbank, wenn möglich mit iCloud-Abgleich.
    ///
    /// UI-Tests starten mit `-uitest-fresh` und einem leeren Speicher im
    /// Arbeitsspeicher, damit Quellen aus einem früheren Test nicht mitzählen.
    /// Klappt der Abgleich nicht, bleibt der Speicher lokal; klappt auch das
    /// nicht, läuft die App mit einem flüchtigen Speicher und sagt es.
    public static func openStore() -> OpenedStore {
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
            clearDeviceStateForUITest()
            return OpenedStore(container: try! LibraryStore.makeContainer(inMemory: true),
                               description: String(localized: "Test, nur im Arbeitsspeicher"), failure: nil)
        }
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        if let container = try? LibraryStore.openPersistentContainer(sync: true) {
            let description = signedIn
                ? String(localized: "Aktiv, über deine private iCloud-Datenbank")
                : String(localized: "Nicht bei iCloud angemeldet, die Daten bleiben auf diesem Gerät")
            return OpenedStore(container: container, description: description, failure: nil)
        }
        // Erst hier, nachdem auch der Abgleich gescheitert ist, darf ein
        // unpassender alter Speicher beiseitegelegt werden. Dann sagt die
        // App es auch.
        if let opened = try? LibraryStore.openLocalContainer() {
            return OpenedStore(container: opened.container,
                               description: String(localized: "Aus, die Daten bleiben auf diesem Gerät"),
                               failure: opened.recoveryNote)
        }
        let container = try! LibraryStore.makeContainer(inMemory: true)
        return OpenedStore(container: container,
                           description: String(localized: "Aus", comment: "iCloud-Abgleich in den Einstellungen"),
                           failure: String(localized: """
                               Die Datenbank liess sich nicht öffnen. Die App läuft ohne Speicher, \
                               und was du jetzt anlegst, ist beim nächsten Start weg.
                               """),
                           isTemporary: true)
    }

    /// Ein leerer Speicher reicht für einen frischen UI-Test nicht. Neben der
    /// Datenbank merkt sich das Gerät geladene Audiodateien und Listen von
    /// Folgen in den Benutzereinstellungen. Blieben sie stehen, fände ein
    /// Test die Datei oder die Stelle aus dem letzten Lauf wieder.
    ///
    /// Läuft vor `AppModel(store:)`: Modell und Player lesen diese Listen
    /// beim Anlegen. Die Schlüssel stehen in `AppModel` und `EpisodePlayer`.
    private static func clearDeviceStateForUITest() {
        _ = LocalMediaLocator.removeAllFiles()
        let defaults = UserDefaults.standard
        for key in [
            "episodePlaybackPositions", "recentEpisodeIDs", "upNextEpisodeIDs",
            "dismissedFromPreparation", "keptOfflineEpisodes", AppModel.dismissedRelevantKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Der zweite Versuch aus dem Startdialog.
    ///
    /// Gelingt das Öffnen jetzt, bekommt das laufende Modell den neuen
    /// Speicher und liest alles neu. Das Modell selbst bleibt dasselbe:
    /// Kurzbefehle, Hintergrundarbeit und Player hängen an ihm. Gibt es
    /// danach noch etwas zu sagen, kommt es als neuer Hinweis zurück.
    public static func retryOpeningStore(for model: AppModel) async -> StartupIssue? {
        let opened = openStore()
        guard !opened.isTemporary else {
            return StartupIssue(
                title: String(localized: "Der Speicher lässt sich immer noch nicht öffnen"),
                message: String(localized: """
                    Die App läuft weiter ohne Speicher, und was du jetzt anlegst, ist beim \
                    nächsten Start weg.
                    """),
                canRetry: true)
        }
        model.syncDescription = opened.description
        await model.replaceStore(LibraryStore.make(container: opened.container))
        return StartupIssue(opened)
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

/// Ein Hinweis beim Start, wenn der Speicher nicht wie gewohnt aufging.
public struct StartupIssue: Equatable, Sendable {
    public let title: String
    public let message: String
    /// Nur wenn die App ohne Speicher läuft, hat ein zweiter Versuch Sinn.
    /// Ist die alte Mediathek beiseitegelegt, ist der Speicher ja offen.
    public let canRetry: Bool

    public init(title: String, message: String, canRetry: Bool) {
        self.title = title
        self.message = message
        self.canRetry = canRetry
    }

    /// `nil`, wenn es nichts zu sagen gibt.
    public init?(_ opened: AppBootstrap.OpenedStore) {
        guard let failure = opened.failure else { return nil }
        self.init(
            title: opened.isTemporary
                ? String(localized: "Der Speicher konnte nicht geöffnet werden")
                : String(localized: "Der Speicher wurde neu angelegt"),
            message: failure,
            canRetry: opened.isTemporary)
    }
}

/// Zeigt den Hinweis vom Start. „Erneut versuchen“ öffnet den Speicher
/// wirklich noch einmal, statt nur den Dialog zu schliessen.
private struct StartupIssueAlert: ViewModifier {

    @Binding var issue: StartupIssue?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            issue?.title ?? "",
            isPresented: Binding(
                get: { issue != nil },
                set: { shown in if !shown { issue = nil } }
            ),
            presenting: issue
        ) { current in
            if current.canRetry {
                Button("Erneut versuchen") { retry() }
                Button("Ohne Speicher weiter", role: .cancel) { issue = nil }
            } else {
                Button("OK") { issue = nil }
            }
        } message: { current in
            Text(current.message)
        }
    }

    private func retry() {
        issue = nil
        Task { issue = await AppBootstrap.retryOpeningStore(for: model) }
    }
}

extension View {
    func startupIssueAlert(_ issue: Binding<StartupIssue?>) -> some View {
        modifier(StartupIssueAlert(issue: issue))
    }
}

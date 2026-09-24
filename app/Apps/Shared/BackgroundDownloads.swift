//
//  BackgroundDownloads.swift
//  PodcastAI
//
//  Die beiden Sitzungen, die Ton im WLAN auch im Hintergrund laden: eine
//  für Angefordertes, die sofort lädt, und eine für von selbst
//  Eingereihtes, deren Zeitpunkt das System wählt.
//
//  Nur auf dem iPhone und iPad. Der Mac hält die App nicht an, dort lädt
//  wie bisher `SafeHTTP` im Vordergrund.
//
//  Beide Sitzungen entstehen einmal beim Start (`AppBootstrap.start`), auch
//  wenn das System die App nur für ihre Ereignisse im Hintergrund startet.
//  Den Abschlussblock aus `handleEventsForBackgroundURLSession` ruft die
//  App, sobald das System alle Ereignisse einer Sitzung zugestellt hat.
//

import Foundation
import PodcastAIKit

@MainActor
final class BackgroundDownloads {

    static let shared = BackgroundDownloads()

    #if os(iOS)
    private let manual: BackgroundDownloadSession
    private let automatic: BackgroundDownloadSession
    /// Abschlussblöcke des Systems je Sitzung.
    private var eventCompletions: [String: () -> Void] = [:]
    /// Sitzungen, deren Ereignisse schon zugestellt waren, bevor der
    /// Abschlussblock kam. Beide laufen über den Hauptthread, aber in
    /// keiner festen Reihenfolge.
    private var finishedEarly: Set<String> = []
    #endif
    /// Eine Datei ist angekommen, während niemand auf sie wartete.
    var onArrival: ((MediaVersionID) -> Void)?

    private init() {
        #if os(iOS)
        let finished: @Sendable (String) -> Void = { identifier in
            Task { @MainActor in BackgroundDownloads.shared.eventsFinished(identifier) }
        }
        let arrived: @Sendable (MediaVersionID) -> Void = { id in
            Task { @MainActor in BackgroundDownloads.shared.onArrival?(id) }
        }
        (manual, automatic) = BackgroundDownloadSession.makePair(
            mediaDirectory: LocalMediaLocator.mediaDirectory, onEventsFinished: finished, onArrival: arrived)
        #endif
    }

    /// Die Sitzung für einen Download, oder `nil` für den Vordergrund.
    /// `unmeteredWiFi`: WLAN ohne Datenlimit, kein Mobilfunk.
    func session(unmeteredWiFi: Bool, automatic isAutomatic: Bool, inForeground: Bool) -> BackgroundDownloadSession? {
        #if os(iOS)
        switch DownloadRoute.choose(unmeteredWiFi: unmeteredWiFi, automatic: isAutomatic,
                                    inForeground: inForeground, backgroundAvailable: true) {
        case .foreground: return nil
        case .background(.manual): return manual
        case .background(.automatic): return automatic
        }
        #else
        return nil
        #endif
    }

    /// Bricht die Übertragungen dieser Fassungen ab, in beiden Sitzungen.
    /// Wer noch wartet, bekommt einen Abbruch. Für „Folge löschen“.
    func cancel(_ ids: some Sequence<MediaVersionID>) {
        #if os(iOS)
        // Beide teilen sich den Stand; eine Sitzung erreicht beide.
        for id in ids { manual.cancel(id) }
        #endif
    }

    /// Bricht nur ab, worauf niemand mehr wartet. Für „Laden abbrechen“ und
    /// „Alle abbrechen“: lädt dieselbe Datei noch für das Transkript oder
    /// für „Laden (offline)“, läuft sie weiter.
    func cancelUnlessAwaited(_ ids: some Sequence<MediaVersionID>) {
        #if os(iOS)
        for id in ids { manual.cancelUnlessAwaited(id) }
        #endif
    }

    /// Hält die Übertragungen an, auf die niemand mehr wartet, und merkt
    /// sich den Stand zum Fortsetzen.
    func suspend(_ ids: some Sequence<MediaVersionID>) {
        #if os(iOS)
        for id in ids { manual.suspend(id) }
        #endif
    }

    #if os(iOS)
    /// Aus `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Die Sitzung steht schon; ihr Delegat bekommt jetzt die Ereignisse.
    func handleEvents(for identifier: String, completion: @escaping () -> Void) {
        guard identifier == manual.identifier || identifier == automatic.identifier else {
            completion()
            return
        }
        if finishedEarly.remove(identifier) != nil {
            completion()
        } else {
            eventCompletions[identifier] = completion
        }
    }

    private func eventsFinished(_ identifier: String) {
        if let completion = eventCompletions.removeValue(forKey: identifier) {
            completion()
        } else {
            finishedEarly.insert(identifier)
        }
    }
    #endif
}

extension AppModel {

    /// Die Sitzung im Hintergrund für den Ton einer Folge, oder `nil` für
    /// den Vordergrund. Im WLAN ohne Datenlimit lädt das System, sonst die
    /// App selbst, über Mobilfunk nur mit Zustimmung.
    func backgroundDownloadSession(automatic: Bool) -> BackgroundDownloadSession? {
        BackgroundDownloads.shared.session(
            unmeteredWiFi: networkLimit == nil && !onMobileData,
            automatic: automatic, inForeground: appInForeground)
    }

    /// Die Fassung, unter der der Ton einer Folge lädt.
    static func downloadID(of episode: Episode) -> MediaVersionID? {
        episode.audioURL.map { MediaVersionID(stable: $0.absoluteString) }
    }

    /// Ein Download aus dem Hintergrund liegt jetzt auf dem Gerät. Ein
    /// Transkript, das auf ihn wartete, kann laufen, sobald die App vorn ist.
    func backgroundDownloadArrived() {
        mediaStorageChanged += 1
        queueConditionsChanged()
    }
}

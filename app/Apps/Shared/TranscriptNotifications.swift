//
//  TranscriptNotifications.swift
//  PodcastAI
//
//  Die lokale Mitteilung „Transkripte pausieren“ und die Frage nach der
//  Erlaubnis dafür.
//
//  Transkripte laufen im Hintergrund nur unter der fortgesetzten
//  Verarbeitung. Trägt sie die Arbeit nicht oder endet ihre Zeit, steht die
//  Warteschlange bis zum nächsten Öffnen. Das sagt die App dann, statt so zu
//  tun, als arbeite sie weiter. Gefragt wird einmal, beim ersten Transkript,
//  das jemand selbst anfordert, mit einem Satz dazu, wofür. Ein Nein bleibt
//  ein Nein. Nur auf dem iPhone und iPad; der Mac arbeitet, solange die App
//  läuft.
//

import Foundation
import SwiftUI
import PodcastAIKit

#if os(iOS)
import UserNotifications
#endif

extension AppModel {

    /// Schon gefragt, ob die App Bescheid sagen darf. Die Antwort zählt,
    /// nicht die Erlaubnis selbst; die kennt das System.
    static let transcriptNotificationsAskedKey = "transcriptNotificationsAsked"
    nonisolated static let transcriptPauseNotificationID = "com.podcastai.transcriptsPaused"

    /// Beim ersten von Hand angeforderten Transkript: fragen, ob die App
    /// Bescheid sagen darf, wenn es im Hintergrund pausiert.
    func askForTranscriptNotificationsIfNeeded() {
        #if os(iOS)
        guard !asksForTranscriptNotifications,
              !UserDefaults.standard.bool(forKey: Self.transcriptNotificationsAskedKey) else { return }
        // In UI-Tests stünde die Frage sonst jedem Test im Weg, der ein
        // Transkript anfordert. Nur der Test für die Frage selbst sieht sie.
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains { $0 == "-uitest-fresh" || $0 == "-skip-onboarding" }
        guard !isUITest || arguments.contains("-uitest-notification-prompt") else { return }
        Task { [weak self] in
            // Hat jemand schon in den Einstellungen des Systems entschieden,
            // fragt die App nicht mehr.
            guard await Self.notificationStatus() == .notDetermined else {
                UserDefaults.standard.set(true, forKey: Self.transcriptNotificationsAskedKey)
                return
            }
            self?.asksForTranscriptNotifications = true
        }
        #endif
    }

    /// Die Antwort auf die Frage. Erst nach „Erlauben“ fragt das System.
    public func answerTranscriptNotifications(allow: Bool) {
        asksForTranscriptNotifications = false
        UserDefaults.standard.set(true, forKey: Self.transcriptNotificationsAskedKey)
        #if os(iOS)
        guard allow else { return }
        Task { _ = await Self.requestNotificationPermission() }
        #endif
    }

    // MARK: Vorder- und Hintergrund

    /// Die App geht in den Hintergrund. Trägt nichts die Transkripte, die
    /// noch ausstehen, sagt die App das. Die Anmeldung der fortgesetzten
    /// Verarbeitung braucht einen Moment; ist sie noch offen, wartet die App
    /// kurz und sieht dann nach.
    func transcriptsEnteredBackground() {
        #if os(iOS)
        Task { [weak self] in
            if self?.transcriptContinuation?.carrier == .pending {
                try? await Task.sleep(for: .seconds(3))
            }
            guard let self else { return }
            await self.noticeTranscriptPauseIfNeeded(carrier: self.transcriptContinuation?.carrier ?? .none)
        }
        #endif
    }

    /// Wieder vorn: die Mitteilung ist erledigt, und was pausierte, läuft weiter.
    func transcriptsBecameActive() {
        transcriptPauseNotified = false
        #if os(iOS)
        Self.withdrawTranscriptPause()
        #endif
        queueConditionsChanged()
    }

    /// Die Zeit im Hintergrund ist um, während Transkripte liefen: anhalten,
    /// Zwischenstand behalten, Bescheid sagen.
    func transcriptTimeExpired() {
        let pending = hasPendingTranscripts
        pauseTranscripts()
        guard pending else { return }
        Task { await noticeTranscriptPauseIfNeeded(carrier: .expired, pending: true) }
    }

    /// Endet die Zeit einer Hintergrundaufgabe (`BGAppRefresh`,
    /// `BGProcessing`), halten auch Transkripte an, die ohne fortgesetzte
    /// Verarbeitung laufen. Trägt sie diese, laufen sie weiter.
    public func stopTranscriptsWithoutCarrier() {
        guard transcriptContinuation?.carrier != .carrying else { return }
        pauseTranscripts()
    }

    private func noticeTranscriptPauseIfNeeded(
        carrier: TranscriptPauseNotice.Carrier, pending: Bool? = nil
    ) async {
        #if os(iOS)
        let pending = pending ?? hasPendingTranscripts
        guard pending, !transcriptPauseNotified else { return }
        let permitted = Self.allowsAlerts(await Self.notificationStatus())
        guard TranscriptPauseNotice.shouldNotify(
            inBackground: !appInForeground, pendingTranscripts: pending, carrier: carrier,
            permitted: permitted, alreadyNotified: transcriptPauseNotified) else { return }
        transcriptPauseNotified = true
        await Self.postTranscriptPause()
        #endif
    }

    // MARK: Mitteilungszentrale

    #if os(iOS)
    /// Außerhalb des Hauptthreads: die Objekte der Mitteilungszentrale sind
    /// nicht `Sendable`, heraus kommen nur Status und Wahrheitswerte.
    nonisolated static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated static func allowsAlerts(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    nonisolated static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    nonisolated static func postTranscriptPause() async {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "Transkripte pausieren, bis du PodcastAI wieder öffnest.",
                              comment: "Lokale Mitteilung, wenn Transkripte im Hintergrund nicht weiterlaufen")
        // Eine feste Kennung: eine neue Mitteilung ersetzt die alte, statt
        // sich zu stapeln.
        let request = UNNotificationRequest(identifier: transcriptPauseNotificationID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func withdrawTranscriptPause() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [transcriptPauseNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [transcriptPauseNotificationID])
    }
    #endif
}

/// Die Frage „Bescheid sagen, wenn Transkripte pausieren?“. Hängt wie die
/// Mobilfunk-Rückfrage an `AppAlerts`, damit sie auch über einem Blatt
/// erscheint.
struct TranscriptNotificationQuestion: ViewModifier {

    @Environment(AppModel.self) private var model
    var isActive = true

    func body(content: Content) -> some View {
        content
            .alert("Bescheid sagen, wenn Transkripte pausieren?", isPresented: Binding(
                get: { isActive && model.asksForTranscriptNotifications },
                set: { if !$0, isActive, model.asksForTranscriptNotifications {
                    model.answerTranscriptNotifications(allow: false)
                } }
            )) {
                Button("Erlauben") { model.answerTranscriptNotifications(allow: true) }
                Button("Nicht jetzt", role: .cancel) { model.answerTranscriptNotifications(allow: false) }
            } message: {
                Text("""
                    Im Hintergrund schreibt iOS Transkripte nur eine Zeit lang weiter. \
                    Hält es sie an, sagt dir eine Mitteilung, dass sie beim nächsten Öffnen weiterlaufen.
                    """)
            }
    }
}

extension AppModel {
    /// Zwischenstände der Transkripte, neben dem Ordner der Audiodateien.
    /// Sie gehören zur Folge: „Folge löschen“ nimmt sie mit.
    nonisolated static let transcriptCheckpoints = TranscriptCheckpointStore(
        directory: ContentPipeline.checkpointDirectory(besides: LocalMediaLocator.mediaDirectory))
}

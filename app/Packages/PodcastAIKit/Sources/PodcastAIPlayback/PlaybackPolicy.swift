//
//  PlaybackPolicy.swift
//  PodcastAIPlayback
//
//  Die einzige Stelle, an der eine Wiedergabefreigabe entsteht.
//
//  Das Entscheidende ist, was hier **nicht** aufgerufen werden kann: es gibt
//  keine Methode, die aus einer Empfehlung, einem Feed-Refresh, einem
//  Sync-Ereignis oder einer Modellantwort eine Freigabe macht. Der
//  Auslösertyp ist ein geschlossenes Enum, und jeder seiner Fälle
//  entspricht einer ausdrücklichen Handlung eines Menschen.
//

import Foundation
import PodcastAICore

@MainActor
public final class PlaybackPolicy {

    private let deviceID: String
    /// Läuft gerade eine bewusst gestartete Fokus-Sitzung? Nur dann darf der
    /// nächste Abschnitt ohne erneute Bestätigung folgen.
    private var activeFocusSessionUntil: Date?

    /// Wie lange eine gestartete Fokus-Sitzung nachwirkt. Danach braucht es
    /// wieder eine ausdrückliche Handlung — eine Sitzung von gestern darf
    /// heute keinen Ton auslösen.
    public static let focusSessionLifetime: TimeInterval = 60 * 90

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    /// Der Nutzer hat Play gedrückt.
    public func grantForUserTap(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        beginFocusSession()
        return PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                             deviceID: deviceID, trigger: .userTappedPlay)
    }

    /// Der Nutzer hat im Chat ausdrücklich „spiel sie mir vor“ gesagt und die
    /// Vorschau bestätigt.
    public func grantForConfirmedChatPlayback(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        beginFocusSession()
        return PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                             deviceID: deviceID, trigger: .userConfirmedChatPlayback)
    }

    /// Der Nutzer hat einen App Intent ausgelöst — per Siri, Kurzbefehl oder
    /// Bildschirmaktion. Das ist eine Handlung, kein Systemvorschlag.
    public func grantForUserIntent(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        beginFocusSession()
        return PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                             deviceID: deviceID, trigger: .userInvokedIntent)
    }

    /// Fortsetzung innerhalb einer laufenden Fokus-Sitzung.
    ///
    /// Gibt `nil` zurück, wenn keine Sitzung läuft oder sie abgelaufen ist.
    /// Es gibt keinen Weg, das zu erzwingen.
    public func grantForContinuation(on plan: ValidatedPlaybackPlan) -> PlaybackGrant? {
        guard let until = activeFocusSessionUntil, Date() < until else { return nil }
        return PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                             deviceID: deviceID, trigger: .continuingActiveFocusSession)
    }

    /// Beendet die Sitzung. Danach braucht jeder Ton wieder eine Handlung.
    public func endFocusSession() {
        activeFocusSessionUntil = nil
    }

    private func beginFocusSession() {
        activeFocusSessionUntil = Date().addingTimeInterval(Self.focusSessionLifetime)
    }

    public var hasActiveFocusSession: Bool {
        guard let until = activeFocusSessionUntil else { return false }
        return Date() < until
    }
}

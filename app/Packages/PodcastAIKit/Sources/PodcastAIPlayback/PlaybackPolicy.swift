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

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    /// Der Nutzer hat Play gedrückt.
    public func grantForUserTap(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                      deviceID: deviceID, trigger: .userTappedPlay)
    }

    /// Der Nutzer hat im Chat ausdrücklich „spiel sie mir vor“ gesagt und die
    /// Vorschau bestätigt.
    public func grantForConfirmedChatPlayback(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                      deviceID: deviceID, trigger: .userConfirmedChatPlayback)
    }

    /// Der Nutzer hat einen App Intent ausgelöst — per Siri, Kurzbefehl oder
    /// Bildschirmaktion. Das ist eine Handlung, kein Systemvorschlag.
    public func grantForUserIntent(on plan: ValidatedPlaybackPlan) -> PlaybackGrant {
        PlaybackGrant(planID: plan.id, planHash: plan.planHash,
                      deviceID: deviceID, trigger: .userInvokedIntent)
    }
}

//
//  PlaybackPlan.swift
//  PodcastAICore
//
//  Die Trennung, auf der die gesamte Wiedergabesicherheit beruht:
//
//    PlaylistProposal      — nicht vertrauenswürdig, kommt vom Modell
//    ValidatedPlaybackPlan — von Swift geprüft, unveränderlich, gehasht
//    PlaybackGrant         — kurzlebige Startfreigabe aus einer Nutzeraktion
//
//  Ein Modell kann einen Vorschlag machen. Es kann keinen Plan erzeugen und
//  keine Freigabe ausstellen. Ein Feedtext, eine Folge oder ein Tool-Ergebnis
//  kann sich nicht selbst autorisieren.
//

import Foundation

/// Rohvorschlag eines Modells. Enthält **nur** Kennungen — keine Zeiten,
/// keine URLs, keine Reihenfolgegarantien.
///
/// Alles, was ein Modell hier hineinschreibt, ist eine Behauptung. Zeiten,
/// Rechte, Fassung und Reihenfolge löst der ``FocusPlanner`` deterministisch auf.
public struct PlaylistProposal: Hashable, Codable, Sendable {

    /// Vom Modell ausgewählte Fundstellen, in vorgeschlagener Reihenfolge.
    public let evidenceIDs: [EvidenceID]
    /// Begründung je Fundstelle, für „Warum diese Stelle?“.
    public let rationales: [EvidenceID: String]
    /// Wonach der Nutzer gefragt hat — wird unverändert in den Plan übernommen.
    public let requestSummary: String

    public init(evidenceIDs: [EvidenceID], rationales: [EvidenceID: String] = [:], requestSummary: String) {
        self.evidenceIDs = evidenceIDs
        self.rationales = rationales
        self.requestSummary = requestSummary
    }
}

/// Ein geprüfter Abschnitt eines Hörplans.
public struct PlanSegment: Hashable, Codable, Sendable, Identifiable {

    public var id: EvidenceID { evidenceID }

    public let evidenceID: EvidenceID
    public let mediaVersionID: MediaVersionID
    public let episodeID: EpisodeID
    public let sourceID: SourceID

    /// Der tatsächlich abzuspielende Bereich — bereits auf Satzkontext
    /// ausgedehnt und mit überlappenden Nachbarn verschmolzen.
    public let range: MediaTimeRange

    /// Zur Anzeige: Quelle und Folge, damit ein Quellenwechsel sichtbar ist.
    public let sourceTitle: String
    public let episodeTitle: String
    /// Warum diese Stelle im Plan ist.
    public let rationale: String?

    /// Weitere Fundstellen, die beim Verschmelzen überlappender Bereiche in
    /// diesen Abschnitt eingegangen sind. Sie bleiben erhalten, damit der
    /// Beleg-Nachweis vollständig ist und keine Quelle stillschweigend
    /// verschwindet.
    public let mergedEvidenceIDs: [EvidenceID]

    public init(
        evidenceID: EvidenceID, mediaVersionID: MediaVersionID, episodeID: EpisodeID,
        sourceID: SourceID, range: MediaTimeRange, sourceTitle: String,
        episodeTitle: String, rationale: String? = nil,
        mergedEvidenceIDs: [EvidenceID] = []
    ) {
        self.evidenceID = evidenceID; self.mediaVersionID = mediaVersionID
        self.episodeID = episodeID; self.sourceID = sourceID; self.range = range
        self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.rationale = rationale; self.mergedEvidenceIDs = mergedEvidenceIDs
    }

    /// Alle Fundstellen, die dieser Abschnitt belegt.
    public var allEvidenceIDs: [EvidenceID] { [evidenceID] + mergedEvidenceIDs }

    public var duration: MediaDuration { range.duration }
}

/// Warum eine vorgeschlagene Fundstelle nicht in den Plan gelangt ist.
/// Wird dem Nutzer angezeigt — ein stillschweigend gekürzter Plan wäre eine
/// falsche Vollständigkeitsaussage.
public enum PlanExclusion: Hashable, Codable, Sendable {
    case unknownEvidence(EvidenceID)
    case outOfScope(EvidenceID)
    case noTimingAvailable(EvidenceID)
    case mediaUnavailable(EvidenceID)
    case staleMediaVersion(EvidenceID)
    case notSeekable(EvidenceID)
    case alreadyHeard(EvidenceID)
    case budgetExhausted(EvidenceID)

    public var evidenceID: EvidenceID {
        switch self {
        case .unknownEvidence(let id), .outOfScope(let id), .noTimingAvailable(let id),
             .mediaUnavailable(let id), .staleMediaVersion(let id), .notSeekable(let id),
             .alreadyHeard(let id), .budgetExhausted(let id):
            id
        }
    }

    public var reason: String {
        switch self {
        case .unknownEvidence: "Fundstelle nicht im freigegebenen Bestand"
        case .outOfScope: "Außerhalb des gewählten Bereichs"
        case .noTimingAvailable: "Für diese Stelle liegt kein Zeitbezug vor"
        case .mediaUnavailable: "Medium derzeit nicht verfügbar"
        case .staleMediaVersion: "Bezieht sich auf eine veraltete Fassung"
        case .notSeekable: "Diese Fassung erlaubt keine exakten Sprünge"
        case .alreadyHeard: "Bereits gehört"
        case .budgetExhausted: "Passt nicht mehr ins Zeitbudget"
        }
    }
}

/// Ein geprüfter, unveränderlicher Hörplan.
///
/// Der ``planHash`` bindet die Freigabe an genau diesen Plan: ändert sich der
/// Plan, verliert eine bereits ausgestellte Freigabe ihre Gültigkeit.
public struct ValidatedPlaybackPlan: Hashable, Codable, Sendable, Identifiable {

    public let id: PlaybackPlanID
    public let segments: [PlanSegment]
    public let excluded: [PlanExclusion]
    public let requestSummary: String
    public let route: PlaybackRoute
    public let createdAt: Date
    public let planHash: String

    public init(
        id: PlaybackPlanID = PlaybackPlanID(), segments: [PlanSegment],
        excluded: [PlanExclusion] = [], requestSummary: String,
        route: PlaybackRoute, createdAt: Date = Date()
    ) {
        self.id = id
        self.segments = segments
        self.excluded = excluded
        self.requestSummary = requestSummary
        self.route = route
        self.createdAt = createdAt
        self.planHash = StableDigest.hex(ofOrdered: segments.map {
            "\($0.mediaVersionID.rawValue):\($0.range.start.milliseconds)-\($0.range.end.milliseconds)"
        })
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Reine Medienzeit, ohne Übergänge.
    public var totalMediaDuration: MediaDuration {
        MediaDuration(milliseconds: segments.reduce(0) { $0 + $1.duration.milliseconds })
    }

    /// Tatsächliche Hördauer bei einer Geschwindigkeit, inklusive hörbarer Übergänge.
    /// Wird getrennt von der Medienzeit angezeigt — „6 Minuten“ bei 1,5-facher
    /// Geschwindigkeit sind neun Minuten Medienzeit.
    public func listeningDuration(rate: Double, transition: MediaDuration) -> MediaDuration {
        let transitions = max(0, segments.count - 1)
        return MediaDuration(
            milliseconds: totalMediaDuration.listeningDuration(atRate: rate).milliseconds
                + Int64(transitions) * transition.milliseconds
        )
    }

    /// Wie oft die Quelle wechselt — für die Anzeige „4 Quellen, 6 Stellen“.
    public var sourceChangeCount: Int {
        zip(segments, segments.dropFirst()).count { $0.sourceID != $1.sourceID }
    }

    public var distinctSourceCount: Int { Set(segments.map(\.sourceID)).count }
}

/// Die Startfreigabe. Kurzlebig, an ein Gerät und an genau einen Plan gebunden.
///
/// Wird ausschließlich aus einer ausdrücklichen Nutzeraktion erzeugt: Tippen
/// auf Play, ein bewusst ausgelöster App Intent oder ein klarer Wiedergabe-
/// wunsch im Chat. Eine eintreffende Empfehlung, ein Feed-Refresh oder ein
/// Sync-Ereignis erzeugen niemals eine Freigabe.
///
/// Nicht über CloudKit übertragbar und nicht von einem Modell ausstellbar.
public struct PlaybackGrant: Hashable, Sendable {

    public enum Trigger: String, Sendable {
        case userTappedPlay
        case userConfirmedChatPlayback
        case userInvokedIntent
        /// Innerhalb einer bereits bewusst gestarteten Fokus-Sitzung darf der
        /// nächste Abschnitt ohne erneute Bestätigung folgen.
        case continuingActiveFocusSession
    }

    public let planID: PlaybackPlanID
    public let planHash: String
    public let deviceID: String
    public let trigger: Trigger
    public let issuedAt: Date
    public let expiresAt: Date
    public let nonce: String

    public init(
        planID: PlaybackPlanID, planHash: String, deviceID: String,
        trigger: Trigger, issuedAt: Date = Date(),
        validFor: TimeInterval = 120, nonce: String = UUID().uuidString
    ) {
        self.planID = planID; self.planHash = planHash; self.deviceID = deviceID
        self.trigger = trigger; self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(validFor)
        self.nonce = nonce
    }

    public func isValid(for plan: ValidatedPlaybackPlan, on device: String, at now: Date = Date()) -> Bool {
        planID == plan.id
            && planHash == plan.planHash   // Plan geändert -> Freigabe ungültig
            && deviceID == device
            && now >= issuedAt
            && now < expiresAt
    }
}

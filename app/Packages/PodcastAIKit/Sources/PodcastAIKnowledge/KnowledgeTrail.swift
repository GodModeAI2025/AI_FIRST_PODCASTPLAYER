//
//  KnowledgeTrail.swift
//  PodcastAIKnowledge
//
//  Der Abschluss einer Hörsession: vertiefen, parken oder verwerfen.
//
//  Zwei Regeln, die das Ganze erst tragbar machen:
//
//  - Die Frage erscheint **nur bei einem bewussten Ende**. Wer den
//    Kopfhörer absetzt oder in eine andere App wechselt, hat nicht
//    entschieden, fertig zu sein — und bekommt keine Abschlusskarte.
//  - **Verwerfen verwirft nur den Vorschlag.** Highlights, Notizen und
//    Belege bleiben unberührt. Sonst wäre ein unbedachter Tipp
//    gleichbedeutend mit Datenverlust.
//

import Foundation
import PodcastAICore

/// Wie eine Hörsession geendet hat.
public enum SessionEnding: Sendable, Equatable {
    /// Der Plan ist vollständig durchgelaufen.
    case completedPlan
    /// Der Nutzer hat ausdrücklich gestoppt.
    case userStopped
    /// Unterbrochen — Anruf, Routenwechsel, App im Hintergrund beendet.
    case interrupted
    /// Die Wiedergabe lief ins Leere, etwa weil das Medium wegfiel.
    case failed

    /// Nur ein bewusstes Ende rechtfertigt die Abschlussfrage.
    public var isDeliberate: Bool {
        switch self {
        case .completedPlan, .userStopped: true
        case .interrupted, .failed: false
        }
    }
}

public enum TrailDecision: String, Sendable, Codable {
    case deepen
    case park
    case discard

    public var label: String {
        switch self {
        case .deepen: "Vertiefen"
        case .park: "Parken"
        case .discard: "Verwerfen"
        }
    }
}

/// Was am Ende einer Session angeboten wird.
public struct SessionClosure: Sendable {

    public let question: String
    /// Die Belege, aus denen die Frage entstanden ist.
    public let supportingEvidenceIDs: [EvidenceID]
    /// Wie viele weiterführende Quellen es **tatsächlich** gibt.
    ///
    /// Eine echte Zahl, keine Andeutung: „drei weitere Quellen“ muss
    /// bedeuten, dass drei erschlossene Quellen vorliegen. Sonst führt
    /// „Vertiefen“ ins Leere.
    public let availableFollowUpCount: Int
    /// Vorgeschlagenes Zeitbudget für die Vertiefung.
    public let suggestedBudget: MediaDuration

    public init(
        question: String, supportingEvidenceIDs: [EvidenceID],
        availableFollowUpCount: Int, suggestedBudget: MediaDuration = MediaDuration(minutes: 10)
    ) {
        self.question = question
        self.supportingEvidenceIDs = supportingEvidenceIDs
        self.availableFollowUpCount = availableFollowUpCount
        self.suggestedBudget = suggestedBudget
    }

    /// „Vertiefen“ wird nur angeboten, wenn es etwas zu vertiefen gibt.
    public var canDeepen: Bool { availableFollowUpCount > 0 }

    public var followUpLabel: String {
        switch availableFollowUpCount {
        case 0: "Dazu ist nichts weiter erschlossen."
        case 1: "Eine weitere Quelle dazu."
        default: "\(availableFollowUpCount) weitere Quellen dazu."
        }
    }
}

/// Entscheidet, ob eine Abschlusskarte gezeigt wird.
public struct SessionBoundaryPolicy: Sendable {

    /// Mindesthördauer, bevor ein Abschluss überhaupt sinnvoll ist.
    /// Wer nach zwanzig Sekunden stoppt, hat nichts abgeschlossen.
    public let minimumListened: MediaDuration

    public init(minimumListened: MediaDuration = MediaDuration(minutes: 2)) {
        self.minimumListened = minimumListened
    }

    public func shouldOfferClosure(
        ending: SessionEnding,
        listened: MediaDuration,
        alreadyOfferedForSession: Bool
    ) -> Bool {
        guard ending.isDeliberate else { return false }
        guard listened >= minimumListened else { return false }
        // Einmalig. Eine wiederkehrende Frage ist eine Belästigung.
        return !alreadyOfferedForSession
    }
}

/// Eine geparkte Wissenslandkarte.
public struct KnowledgeTrail: Sendable, Identifiable, Codable {

    public let id: KnowledgeNodeID
    public let question: String
    public let claimIDs: [ClaimID]
    public let evidenceIDs: [EvidenceID]
    public let highlightIDs: [HighlightID]
    /// Gegenpositionen, sofern der Nutzer danach gefragt hat.
    public let counterpointEvidenceIDs: [EvidenceID]
    public var userNote: String?
    public let parkedAt: Date

    public init(
        id: KnowledgeNodeID = KnowledgeNodeID(), question: String,
        claimIDs: [ClaimID] = [], evidenceIDs: [EvidenceID] = [],
        highlightIDs: [HighlightID] = [], counterpointEvidenceIDs: [EvidenceID] = [],
        userNote: String? = nil, parkedAt: Date = Date()
    ) {
        self.id = id; self.question = question; self.claimIDs = claimIDs
        self.evidenceIDs = evidenceIDs; self.highlightIDs = highlightIDs
        self.counterpointEvidenceIDs = counterpointEvidenceIDs
        self.userNote = userNote; self.parkedAt = parkedAt
    }

    /// Parken heißt aufbewahren, nicht zustimmen.
    ///
    /// Die Unterscheidung ist bewusst als Eigenschaft ausgedrückt und nicht
    /// als Kommentar: eine geparkte Landkarte darf nirgendwo als
    /// Standpunkt des Nutzers gelesen werden.
    public var impliesAgreement: Bool { false }
}

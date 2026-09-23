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
    /// Wann die Session begann. Notizen, die seitdem entstanden sind,
    /// gehören zu ihr. Ältere Notizen der Mediathek nicht.
    public let startedAt: Date?

    public init(
        question: String, supportingEvidenceIDs: [EvidenceID],
        availableFollowUpCount: Int, suggestedBudget: MediaDuration = MediaDuration(minutes: 10),
        startedAt: Date? = nil
    ) {
        self.question = question
        self.supportingEvidenceIDs = supportingEvidenceIDs
        self.availableFollowUpCount = availableFollowUpCount
        self.suggestedBudget = suggestedBudget
        self.startedAt = startedAt
    }

    /// Die Notizen dieser Session: an einem ihrer Belege gemerkt oder
    /// während sie lief.
    public func noteIDs(in highlights: [Highlight]) -> [HighlightID] {
        let supporting = Set(supportingEvidenceIDs)
        return highlights.filter { note in
            if supporting.contains(note.evidenceID) { return true }
            guard let startedAt else { return false }
            return note.capturedAt >= startedAt
        }.map(\.id)
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
    /// Der Antworttext, wenn die Karte aus einer Chat-Antwort stammt.
    /// Ältere Karten haben keinen.
    public let answerText: String?
    /// Verweisnummern im Antworttext wie [3] → Beleg.
    public let citationNumbers: [Int: EvidenceID]?

    public init(
        id: KnowledgeNodeID = KnowledgeNodeID(), question: String,
        claimIDs: [ClaimID] = [], evidenceIDs: [EvidenceID] = [],
        highlightIDs: [HighlightID] = [], counterpointEvidenceIDs: [EvidenceID] = [],
        userNote: String? = nil, parkedAt: Date = Date(),
        answerText: String? = nil, citationNumbers: [Int: EvidenceID]? = nil
    ) {
        self.id = id; self.question = question; self.claimIDs = claimIDs
        self.evidenceIDs = evidenceIDs; self.highlightIDs = highlightIDs
        self.counterpointEvidenceIDs = counterpointEvidenceIDs
        self.userNote = userNote; self.parkedAt = parkedAt
        self.answerText = answerText; self.citationNumbers = citationNumbers
    }

    /// Die Karte ohne diese Belege, etwa weil ihre Folge gelöscht wurde.
    ///
    /// Der Antworttext ist aus den Belegen formuliert und gibt sie ohne
    /// Modell sogar wörtlich wieder. Fällt ein zitierter Beleg weg, geht der
    /// Text deshalb mit. Frage, übrige Belege und Notizen bleiben. Bleibt
    /// weder ein Beleg noch eine Notiz, gibt es die Karte nicht mehr (`nil`).
    public func removing(evidence removed: Set<EvidenceID>) -> KnowledgeTrail? {
        let kept = evidenceIDs.filter { !removed.contains($0) }
        let keptCounterpoints = counterpointEvidenceIDs.filter { !removed.contains($0) }
        let numbersHit = citationNumbers?.values.contains { removed.contains($0) } ?? false
        guard kept.count < evidenceIDs.count || keptCounterpoints.count < counterpointEvidenceIDs.count
                || numbersHit else { return self }
        if kept.isEmpty && keptCounterpoints.isEmpty && highlightIDs.isEmpty { return nil }
        return KnowledgeTrail(
            id: id, question: question, claimIDs: claimIDs, evidenceIDs: kept,
            highlightIDs: highlightIDs, counterpointEvidenceIDs: keptCounterpoints,
            userNote: userNote, parkedAt: parkedAt, answerText: nil, citationNumbers: nil)
    }

    /// Die Notizen, die zu diesen Belegen gehören: an derselben Stelle
    /// gemerkt oder an einem Moment derselben Folge, dessen gemerkter
    /// Bereich den Beleg überlappt. Alle anderen Notizen der Mediathek
    /// gehören nicht dazu.
    public static func noteIDs(
        in highlights: [Highlight], matching evidence: [Evidence],
        capture: HighlightCapture = HighlightCapture()
    ) -> [HighlightID] {
        let ids = Set(evidence.map(\.id))
        return highlights.filter { note in
            if ids.contains(note.evidenceID) { return true }
            guard let ms = note.positionMs else { return false }
            let noted = capture.range(around: MediaTime(milliseconds: Int64(ms)), limit: nil)
            return evidence.contains { item in
                guard let range = item.range else { return false }
                let sameEpisode = note.episodeID.map { $0 == item.episodeID }
                    ?? (note.mediaVersionID == item.mediaVersionID)
                return sameEpisode && noted.touchesOrOverlaps(range)
            }
        }.map(\.id)
    }

    /// Parken heißt aufbewahren, nicht zustimmen.
    ///
    /// Die Unterscheidung ist bewusst als Eigenschaft ausgedrückt und nicht
    /// als Kommentar: eine geparkte Landkarte darf nirgendwo als
    /// Standpunkt des Nutzers gelesen werden.
    public var impliesAgreement: Bool { false }
}

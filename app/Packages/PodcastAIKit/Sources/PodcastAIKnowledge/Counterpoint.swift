//
//  Counterpoint.swift
//  PodcastAIKnowledge
//
//  Der Widerspruchs-Mixer: eine eigene These an belegten Gegenpositionen
//  prüfen.
//
//  Der heikle Teil ist nicht die Suche, sondern die Buchführung darüber,
//  was der Nutzer eigentlich denkt. Drei Dinge bleiben strikt getrennt:
//
//    Quelle    — wer etwas gesagt hat.
//    Position  — was gesagt wurde.
//    Zustimmung— ob der Nutzer das teilt.
//
//  Ein gespeichertes Highlight ist keine Zustimmung. Eine gehörte Passage
//  ist keine Zustimmung. Nur eine ausdrückliche Bestätigung macht aus einer
//  These den Standpunkt des Nutzers — und auch die ist widerrufbar.
//

import Foundation
import PodcastAICore

/// Der Status einer These.
public enum StanceStatus: String, Sendable, Codable {
    case proposed
    case confirmed
    case rejected
    case withdrawn
}

/// Woher eine These stammt.
public enum StanceOrigin: String, Sendable, Codable {
    /// Der Nutzer hat sie selbst formuliert.
    case explicitUser
    /// Aus einem Inhalt abgeleitet und zur Bestätigung vorgelegt.
    case derivedFromContent
}

public struct Stance: Sendable, Identifiable, Codable, Hashable {

    public let id: UUID
    public let text: String
    public var status: StanceStatus
    public let origin: StanceOrigin
    public let createdAt: Date

    public init(
        id: UUID = UUID(), text: String, status: StanceStatus = .proposed,
        origin: StanceOrigin, createdAt: Date = Date()
    ) {
        self.id = id; self.text = text; self.status = status
        self.origin = origin; self.createdAt = createdAt
    }

    /// Darf das als Standpunkt des Nutzers bezeichnet werden?
    ///
    /// Beide Bedingungen zusammen — eine vom System abgeleitete These wird
    /// auch durch Bestätigung nicht zur Eigenformulierung, und eine selbst
    /// formulierte wird ohne Bestätigung nicht zum Standpunkt.
    public var isUserPosition: Bool {
        status == .confirmed && origin == .explicitUser
    }
}

/// Wie sich eine Quellenposition zu einer These verhält.
public enum CounterpointRelation: String, Sendable, Codable {
    /// Widerspricht der These direkt.
    case contradicts
    /// Stützt sie.
    case supports
    /// Geht von anderen Voraussetzungen aus — weder Beleg noch Gegenbeleg.
    case differentPremise
    /// Schränkt sie ein, ohne sie zu verwerfen.
    case qualifies

    public var label: String {
        switch self {
        case .contradicts: "Gegenposition"
        case .supports: "Stützt die These"
        case .differentPremise: "Andere Voraussetzung"
        case .qualifies: "Schränkt ein"
        }
    }

    /// Eine andere Annahme ist **kein** Gegenbeweis. Diese Unterscheidung
    /// ist der Unterschied zwischen Urteilsbildung und Rechthaberei.
    public var isEvidenceAgainst: Bool { self == .contradicts }
}

public struct CounterpointCandidate: Sendable, Identifiable {
    public var id: EvidenceID { evidenceID }

    public let evidenceID: EvidenceID
    public let relation: CounterpointRelation
    /// Wie sicher die Zuordnung ist. Wird angezeigt, nicht verschwiegen —
    /// eine vermutete Gegenposition als Tatsache auszugeben wäre genau der
    /// Fehler, den dieser Modus vermeiden soll.
    public let isModelConfirmed: Bool
    public let sourceTitle: String
    public let excerpt: String

    public init(
        evidenceID: EvidenceID, relation: CounterpointRelation,
        isModelConfirmed: Bool, sourceTitle: String, excerpt: String
    ) {
        self.evidenceID = evidenceID; self.relation = relation
        self.isModelConfirmed = isModelConfirmed
        self.sourceTitle = sourceTitle; self.excerpt = excerpt
    }
}

/// Stellt eine ausgewogene Auswahl zusammen.
public struct CounterpointMixer: Sendable {

    /// Wie viele Positionen je Seite höchstens.
    public let perSide: Int

    public init(perSide: Int = 3) {
        self.perSide = perSide
    }

    /// Wählt aus Kandidaten eine faire Zusammenstellung.
    ///
    /// Bewusst **keine** Optimierung auf Widerspruch: die Auswahl nimmt
    /// beide Seiten und die abweichenden Voraussetzungen mit. Wer nur
    /// Gegenpositionen hört, wechselt nicht die Meinung, sondern verhärtet
    /// sie — und das Paket verbietet ausdrücklich, auf Meinungsänderung
    /// oder Empörung zu optimieren.
    public func balance(_ candidates: [CounterpointCandidate]) -> [CounterpointCandidate] {
        var byRelation: [CounterpointRelation: [CounterpointCandidate]] = [:]
        for candidate in candidates {
            byRelation[candidate.relation, default: []].append(candidate)
        }

        // Reihenfolge bewusst: erst was stützt, dann was widerspricht, dann
        // was anders ansetzt. Wer mit der Gegenposition anfängt, hört sie
        // als Angriff statt als Argument.
        let order: [CounterpointRelation] = [.supports, .contradicts, .differentPremise, .qualifies]
        return order.flatMap { relation in
            (byRelation[relation] ?? [])
                .sorted { lhs, rhs in
                    lhs.isModelConfirmed != rhs.isModelConfirmed
                        ? lhs.isModelConfirmed && !rhs.isModelConfirmed
                        : lhs.evidenceID.rawValue < rhs.evidenceID.rawValue
                }
                .prefix(perSide)
        }
    }

    /// Ist die Zusammenstellung überhaupt vorzeigbar?
    ///
    /// Eine „Prüfung“, die nur eine Seite kennt, ist keine Prüfung. Dann
    /// sagt die App das, statt eine Ausgewogenheit zu behaupten.
    public func isBalanced(_ selection: [CounterpointCandidate]) -> Bool {
        let relations = Set(selection.map(\.relation))
        return relations.contains(.contradicts)
            && (relations.contains(.supports) || relations.contains(.differentPremise))
    }

    public func imbalanceNotice(_ selection: [CounterpointCandidate]) -> String? {
        guard !isBalanced(selection) else { return nil }
        let relations = Set(selection.map(\.relation))
        if selection.isEmpty {
            return "Zu dieser These ist in deinem Bestand nichts erschlossen."
        }
        if !relations.contains(.contradicts) {
            return "Im erschlossenen Bestand findet sich keine Gegenposition. "
                + "Das heißt nicht, dass es keine gibt."
        }
        return "Im erschlossenen Bestand findet sich nur die Gegenseite. "
            + "Das ist keine ausgewogene Prüfung."
    }
}

/// Verhindert, dass aus Hörverhalten ein politisches Überzeugungsprofil wird.
public enum SensitiveTopicPolicy {

    /// Themenfelder, zu denen keine Haltung abgeleitet wird.
    ///
    /// Die App darf dazu Sachaussagen erschließen, vergleichen und
    /// wiedergeben. Sie leitet aber keine Position des Nutzers daraus ab,
    /// schlägt dazu keine Interessen vor und ordnet nichts nach
    /// Überzeugungsnähe.
    public static let restrictedDerivation = Set([
        "partei", "wahl", "regierung", "opposition", "abstimmung",
        "religion", "glaube", "konfession",
        "migration", "asyl",
        "abtreibung", "sterbehilfe",
    ])

    /// Darf aus diesem Inhalt ein Interesse vorgeschlagen werden?
    public static func allowsInterestDerivation(from text: String) -> Bool {
        let normalized = RelevanceScorer.normalize(text)
        return !restrictedDerivation.contains { normalized.contains($0) }
    }
}

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
public enum CounterpointRelation: String, Sendable, Codable, CaseIterable {
    /// Widerspricht der These direkt.
    case contradicts
    /// Stützt sie.
    case supports
    /// Geht von anderen Voraussetzungen aus — weder Beleg noch Gegenbeleg.
    case differentPremise
    /// Schränkt sie ein, ohne sie zu verwerfen.
    case qualifies
    /// Passt zum Thema, ist aber nicht eingeordnet: das Modell fehlte,
    /// scheiterte oder hat zu dieser Stelle nichts gesagt. Früher landete
    /// so eine Stelle unter „Andere Voraussetzung“, und die App schloss
    /// daraus, es gebe keine Gegenposition.
    case unclassified

    /// Die Bezeichnungen, zwischen denen das Modell wählen darf.
    /// „Nicht eingeordnet“ gehört nicht dazu, das entscheidet der Code.
    public static var classifiable: [CounterpointRelation] {
        [.contradicts, .supports, .differentPremise, .qualifies]
    }

    public var label: String {
        switch self {
        case .contradicts: String(localized: "Gegenposition", bundle: .module)
        case .supports: String(localized: "Stützt die These", bundle: .module)
        case .differentPremise: String(localized: "Andere Voraussetzung", bundle: .module)
        case .qualifies: String(localized: "Schränkt ein", bundle: .module)
        case .unclassified: String(localized: "Zum Thema, nicht eingeordnet", bundle: .module)
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
    /// Folge und Stelle, damit eine Zeile sagt, woher sie stammt, und sich
    /// abspielen und merken lässt.
    public let episodeID: EpisodeID?
    public let episodeTitle: String?
    public let range: MediaTimeRange?

    public init(
        evidenceID: EvidenceID, relation: CounterpointRelation,
        isModelConfirmed: Bool, sourceTitle: String, excerpt: String,
        episodeID: EpisodeID? = nil, episodeTitle: String? = nil, range: MediaTimeRange? = nil
    ) {
        self.evidenceID = evidenceID; self.relation = relation
        self.isModelConfirmed = isModelConfirmed
        self.sourceTitle = sourceTitle; self.excerpt = excerpt
        self.episodeID = episodeID; self.episodeTitle = episodeTitle; self.range = range
    }
}

/// Was eine Suche zu einer These ergeben hat.
public struct CounterpointSearch: Sendable {
    /// Die passendsten Stellen, beste zuerst.
    public let candidates: [CounterpointCandidate]
    /// Warum die Einordnung ganz oder teilweise fehlt. `nil`, wenn das
    /// Modell jede Stelle gesehen hat.
    public let classificationProblem: String?

    public init(candidates: [CounterpointCandidate], classificationProblem: String? = nil) {
        self.candidates = candidates
        self.classificationProblem = classificationProblem
    }
}

/// Eine geprüfte These mit ihrem Ergebnis.
///
/// Sie lebt im App-Modell und nicht in der Ansicht. So ist das Ergebnis nach
/// dem Zurückgehen noch da, und die Stellen gehören immer zu der These, die
/// geprüft wurde, nicht zu dem, was gerade im Textfeld steht.
public struct CounterpointCheck: Sendable, Identifiable {
    public let id: UUID
    public let thesis: String
    public var isRunning: Bool
    /// Schon ausgewogen zusammengestellt, siehe ``CounterpointMixer/balance(_:)``.
    public var candidates: [CounterpointCandidate]
    public var classificationProblem: String?
    /// Als Wissenslandkarte gesichert.
    public var isSaved: Bool

    public init(
        id: UUID = UUID(), thesis: String, isRunning: Bool = true,
        candidates: [CounterpointCandidate] = [], classificationProblem: String? = nil,
        isSaved: Bool = false
    ) {
        self.id = id; self.thesis = thesis; self.isRunning = isRunning
        self.candidates = candidates; self.classificationProblem = classificationProblem
        self.isSaved = isSaved
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
        // als Angriff statt als Argument. Nicht Eingeordnetes steht am Ende.
        let order: [CounterpointRelation] = [.supports, .contradicts, .differentPremise, .qualifies, .unclassified]
        return order.flatMap { relation in
            // Innerhalb einer Gruppe zählt die Eingangsreihenfolge, also die
            // Relevanz. Nach der Kennung sortiert standen dort die drei
            // Stellen mit der kleinsten Kennung, nicht die passendsten.
            (byRelation[relation] ?? []).enumerated()
                .sorted { lhs, rhs in
                    lhs.element.isModelConfirmed != rhs.element.isModelConfirmed
                        ? lhs.element.isModelConfirmed
                        : lhs.offset < rhs.offset
                }
                // Ohne Einordnung gibt es keine Seiten, die sich die Waage
                // halten müssen. Dann dürfen es ein paar Stellen mehr sein.
                .prefix(relation == .unclassified ? perSide * 2 : perSide)
                .map(\.element)
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
        if selection.isEmpty {
            return String(localized: "Zu dieser These passt nichts aus deinen Folgen mit Transkript.", bundle: .module)
        }
        // Ohne Einordnung lässt sich über Gegenpositionen nichts sagen. Den
        // Grund nennt die App an anderer Stelle, hier wird nichts behauptet.
        let relations = Set(selection.map(\.relation)).subtracting([.unclassified])
        guard !relations.isEmpty else { return nil }
        if !relations.contains(.contradicts) {
            return String(localized: """
                In deinen Folgen mit Transkript findet sich keine Gegenposition. \
                Das heißt nicht, dass es keine gibt.
                """, bundle: .module)
        }
        return String(localized: """
            In deinen Folgen mit Transkript findet sich nur die Gegenseite. \
            Das ist keine ausgewogene Prüfung.
            """, bundle: .module)
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

//
//  RelevanceScorer.swift
//  PodcastAIKnowledge
//
//  Die Vorauswahl, bevor ein Modell überhaupt gefragt wird.
//
//  Warum es diese Stufe gibt: ein Apple-Modell auf dem Gerät hat ein
//  begrenztes Kontextfenster und kostet Zeit und Akku. Tausend Belege
//  einzeln vorzulegen ist weder möglich noch nötig. Diese Stufe verengt
//  deterministisch auf eine Kandidatenliste; erst darüber entscheidet das
//  Modell inhaltlich.
//
//  Gleichzeitig ist sie der Rückfall, wenn Apple Intelligence nicht zur
//  Verfügung steht. Dann ist die App schwächer, aber nicht kaputt — und sie
//  sagt es (siehe ``RelevanceMatch.isModelConfirmed``).
//
//  Bewusst ohne Apple-Frameworks und damit prüfbar.
//

import Foundation
import PodcastAICore

/// Warum ein Beleg als Kandidat gilt.
public struct RelevanceMatch: Sendable, Hashable {
    public let evidenceID: EvidenceID
    public let interestID: InterestID
    public let interestLabel: String
    public let kind: InterestKind
    /// Zwischen 0 und 1. Nur eine Rangfolge für die Vorauswahl — **keine**
    /// Aussage über Wichtigkeit, die man dem Nutzer zeigen sollte.
    public let score: Double
    /// Die Begriffe, die tatsächlich getroffen haben. Machen die Auswahl
    /// nachvollziehbar, statt eine Zahl zu behaupten.
    public let matchedTerms: [String]
    /// Hat ein Modell die Relevanz bestätigt, oder ist das bloß ein Treffer
    /// auf Stichwortebene?
    public let isModelConfirmed: Bool

    public init(
        evidenceID: EvidenceID, interestID: InterestID, interestLabel: String,
        kind: InterestKind, score: Double, matchedTerms: [String],
        isModelConfirmed: Bool = false
    ) {
        self.evidenceID = evidenceID; self.interestID = interestID
        self.interestLabel = interestLabel; self.kind = kind; self.score = score
        self.matchedTerms = matchedTerms; self.isModelConfirmed = isModelConfirmed
    }

    /// Der Satz, der unter „Warum für dich relevant?“ steht.
    public func explanation() -> String {
        let terms = matchedTerms.prefix(3).joined(separator: ", ")
        let base: String = switch kind {
        case .topic: "Passt zu deinem Thema „\(interestLabel)“"
        case .activeProject: "Passt zu deinem Vorhaben „\(interestLabel)“"
        case .openQuestion: "Könnte deine Frage „\(interestLabel)“ berühren"
        }
        let suffix = terms.isEmpty ? "" : " (\(terms))"
        // Ohne Modellbestätigung wird das ausdrücklich gesagt.
        let qualifier = isModelConfirmed ? "" : " · nur Stichworttreffer"
        return base + suffix + qualifier
    }

    public func personalRelevance() -> PersonalRelevance {
        // `switch` ist als Ausdruck nur in Zuweisung, `return` oder
        // Variableninitialisierung erlaubt — nicht als Argument.
        let reason: PersonalRelevance.Reason = switch kind {
        case .topic: .confirmedInterest
        case .activeProject: .activeProject
        case .openQuestion: .openQuestion
        }
        return PersonalRelevance(
            reason: reason,
            interestID: interestID,
            interestLabel: interestLabel,
            explanation: explanation()
        )
    }
}

public struct RelevanceScorer: Sendable {

    /// Ab welchem Wert ein Beleg überhaupt Kandidat wird.
    public let threshold: Double
    /// Wie viele Kandidaten je Interesse höchstens weitergereicht werden.
    public let maximumPerInterest: Int

    public init(threshold: Double = 0.18, maximumPerInterest: Int = 25) {
        self.threshold = threshold
        self.maximumPerInterest = maximumPerInterest
    }

    /// Bewertet Belege gegen das Profil.
    ///
    /// Nur **bestätigte** Interessen zählen. Ein vermutetes Interesse darf
    /// keine persönliche Ausgabe auslösen — es taucht in den Vorschlägen auf
    /// und wartet dort auf eine Entscheidung.
    public func score(
        evidence: [Evidence],
        profile: InterestProfile,
        now: Date = Date()
    ) -> [RelevanceMatch] {

        let drivers = profile.publicationDrivers(at: now)
        guard !drivers.isEmpty else { return [] }

        var byInterest: [InterestID: [RelevanceMatch]] = [:]

        for interest in drivers {
            let terms = Self.terms(for: interest)
            guard !terms.isEmpty else { continue }

            for item in evidence {
                let haystack = Self.normalize(item.quotedText)
                guard !haystack.isEmpty else { continue }

                let (value, matched) = Self.match(terms: terms, in: haystack)
                guard value >= threshold else { continue }

                byInterest[interest.id, default: []].append(RelevanceMatch(
                    evidenceID: item.id, interestID: interest.id,
                    interestLabel: interest.label, kind: interest.kind,
                    score: value, matchedTerms: matched
                ))
            }
        }

        // Je Interesse begrenzen, damit ein breit formuliertes Thema nicht
        // alle anderen verdrängt.
        return byInterest.values.flatMap { matches in
            matches
                .sorted { lhs, rhs in
                    lhs.score != rhs.score
                        ? lhs.score > rhs.score
                        : lhs.evidenceID.rawValue < rhs.evidenceID.rawValue
                }
                .prefix(maximumPerInterest)
        }
        .sorted { lhs, rhs in
            lhs.score != rhs.score
                ? lhs.score > rhs.score
                : lhs.evidenceID.rawValue < rhs.evidenceID.rawValue
        }
    }

    // MARK: - Begriffe

    /// Alle Suchbegriffe eines Interesses: Beschriftung, Stichworte und die
    /// Einzelwörter daraus.
    static func terms(for interest: Interest) -> [String] {
        var result = Set<String>()
        for raw in [interest.label] + interest.keywords {
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { continue }
            result.insert(normalized)
            // Mehrwortbegriffe zusätzlich in Einzelwörter zerlegen, aber
            // Füllwörter weglassen: „für“ trifft sonst überall.
            for word in normalized.split(separator: " ") where word.count >= 4 {
                if !stopWords.contains(String(word)) { result.insert(String(word)) }
            }
        }
        return Array(result).sorted()
    }

    /// Bewertet, wie gut die Begriffe im Text vorkommen.
    ///
    /// Ein Mehrworttreffer zählt mehr als ein Einzelwort, und mehrere
    /// verschiedene Treffer zählen mehr als derselbe Begriff zehnmal —
    /// sonst gewinnt ein Text, der ein Wort ständig wiederholt.
    static func match(terms: [String], in haystack: String) -> (Double, [String]) {
        var matched: [String] = []
        var value = 0.0

        for term in terms where haystack.contains(term) {
            matched.append(term)
            // Mehrwortbegriffe sind spezifischer und wiegen schwerer.
            value += term.contains(" ") ? 0.5 : 0.2
        }
        guard !matched.isEmpty else { return (0, []) }

        // Sättigung: der zehnte Treffer macht einen Abschnitt nicht zehnmal
        // relevanter.
        return (min(1.0, value), matched.sorted { $0.count > $1.count })
    }

    /// Kleinschreibung; alles, was kein Buchstabe und keine Ziffer ist, wird
    /// zu einem Leerzeichen.
    ///
    /// Das ist kein Detail: wer „KI Modelle“ einträgt, erwartet einen Treffer
    /// auf „KI-Modelle“, und ein Punkt am Satzende darf ein Wort nicht
    /// unauffindbar machen. Umlaute bleiben erhalten — „ä“ auf „a“ zu falten
    /// würde im Deutschen mehr falsche Treffer erzeugen als richtige.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        result.reserveCapacity(lowered.count)
        var lastWasSpace = true
        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static let stopWords: Set<String> = [
        "und", "oder", "aber", "denn", "dass", "diese", "dieser", "dieses",
        "eine", "einen", "einem", "einer", "eines", "nicht", "auch", "noch",
        "beim", "durch", "gegen", "ohne", "über", "unter", "zwischen",
        "mein", "meine", "meinen", "mit", "von", "vom", "zum", "zur",
        "the", "and", "for", "with", "from", "that", "this",
    ]
}

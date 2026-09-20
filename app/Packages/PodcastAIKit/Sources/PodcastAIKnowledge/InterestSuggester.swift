//
//  InterestSuggester.swift
//  PodcastAIKnowledge
//
//  Woher ein *vermutetes* Interesse kommt.
//
//  `InterestOrigin.suggestedBySystem` war von Anfang an im Modell, und die
//  Oberfläche hatte einen eigenen Abschnitt dafür. Nur erzeugt hat die
//  Vorschläge nie jemand: `profile.suggested` war immer leer, und damit war
//  die Hälfte des Kapitels „Interessenmodell“ eine leere Überschrift.
//
//  Drei Entscheidungen, die diesem Vorschlagswesen seine Form geben:
//
//  1. **Nur aus tatsächlich Gehörtem.** Nicht aus allem, was in der
//     Mediathek liegt — sonst schlägt die App vor, was der Nutzer
//     abonniert und nie angehört hat. Was er gehört hat, hat er gewählt.
//  2. **Nie automatisch wirksam.** Ein Vorschlag steht in einem eigenen
//     Abschnitt und wirkt erst nach Bestätigung. `RelevanceScorer` lässt
//     nur bestätigte Interessen publizieren; dieser Typ umgeht das nicht.
//  3. **Ohne Modell.** Ein Vorschlag, den der Nutzer nicht nachvollziehen
//     kann, ist keine Transparenz. Die Regel steht hier und ist
//     nachlesbar: ein Begriff, der über mehrere gehörte Stellen hinweg
//     auftaucht und noch nicht abgedeckt ist.
//

import Foundation
import PodcastAICore

public struct InterestSuggester: Sendable {

    /// In wie vielen **verschiedenen** gehörten Stellen ein Begriff vorkommen
    /// muss. Über eine Stelle hinweg heisst gar nichts — jeder Podcast
    /// wiederholt sein eigenes Thema.
    public let minimumDistinctMentions: Int
    public let maximumSuggestions: Int
    /// Kürzere Wörter sind fast immer Füllwörter, längere fast immer
    /// Komposita und damit aussagekräftig.
    public let minimumLength: Int

    public init(
        minimumDistinctMentions: Int = 3,
        maximumSuggestions: Int = 5,
        minimumLength: Int = 6
    ) {
        self.minimumDistinctMentions = minimumDistinctMentions
        self.maximumSuggestions = maximumSuggestions
        self.minimumLength = minimumLength
    }

    /// Schlägt Themen vor, die im Gehörten wiederkehren.
    ///
    /// `heard` sind die Belege, deren Stelle der Hörzustand abdeckt — die
    /// Auswahl trifft der Aufrufer, weil nur er den Ledger hat.
    public func suggestions(
        fromHeard heard: [Evidence], existing profile: InterestProfile
    ) -> [Interest] {

        guard profile.learningEnabled else { return [] }

        // Was schon im Profil steht — bestätigt **oder** vorgeschlagen —
        // wird nicht noch einmal vorgeschlagen.
        var covered = Set<String>()
        for interest in profile.interests {
            for term in RelevanceScorer.terms(for: interest) { covered.insert(term) }
        }

        // Je Begriff die Menge der Stellen, in denen er vorkommt. Eine
        // Menge, keine Zählung: zehnmal dasselbe Wort in einer Stelle ist
        // ein Hinweis auf diese Stelle, nicht auf ein Interesse.
        var mentions: [String: Set<String>] = [:]
        for item in heard {
            let normalized = RelevanceScorer.normalize(item.quotedText)
            guard !normalized.isEmpty else { continue }
            var seenHere = Set<String>()
            for word in normalized.split(separator: " ") {
                let term = String(word)
                guard term.count >= minimumLength else { continue }
                guard !RelevanceScorer.stopWords.contains(term) else { continue }
                guard !covered.contains(term) else { continue }
                guard !term.allSatisfy(\.isNumber) else { continue }
                seenHere.insert(term)
            }
            for term in seenHere {
                mentions[term, default: []].insert(item.id.rawValue)
            }
        }

        let candidates = mentions
            .filter { $0.value.count >= minimumDistinctMentions }
            // Häufigkeit zuerst, bei Gleichstand alphabetisch: eine
            // Reihenfolge, die zwischen zwei Starts gleich bleibt.
            .sorted { lhs, rhs in
                lhs.value.count != rhs.value.count
                    ? lhs.value.count > rhs.value.count
                    : lhs.key < rhs.key
            }
            .prefix(maximumSuggestions)

        return candidates.map { term, sources in
            Interest(
                // Stabil aus dem Begriff: derselbe Vorschlag bekommt bei
                // jedem Lauf dieselbe Kennung und erscheint nicht doppelt,
                // wenn er schon einmal abgelehnt und wieder gefunden wurde.
                id: InterestID(stable: "suggested|" + term),
                label: term,
                kind: .topic,
                origin: .suggestedBySystem,
                keywords: [],
                createdAt: Date()
            )
        }
        .sorted { $0.label < $1.label }
    }
}

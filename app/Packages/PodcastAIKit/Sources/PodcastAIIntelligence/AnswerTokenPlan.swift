//
//  AnswerTokenPlan.swift
//  PodcastAIIntelligence
//
//  Wie viele Stellen in eine Antwort passen, gezählt in Token.
//
//  Bis 0.7 rechnete die App mit drei Zeichen je Token. Das war vorsichtig
//  und ließ auf dem Gerät viel Fenster leer: Deutscher Text braucht je nach
//  Folge mehr oder weniger Zeichen je Token, und mit 8.192 Token unter
//  iOS 27 passt deutlich mehr als die festen 16 Stellen. Jetzt zählt der
//  Tokenizer des Modells mit.
//
//  Gezählt wird grob, damit die Frage nicht auf das Zählen wartet: einmal
//  der feste Teil (Anweisungen, Rahmen, Bibliothek und Frage), einmal eine
//  Probe aus bis zu acht Stellen. Aus der Probe ergibt sich, was eine Stelle
//  im Schnitt kostet, und die Zahl der Stellen wird auf ein Vielfaches von
//  vier abgerundet. Scheitert das Zählen, gilt die alte Schätzung.
//
//  Dieser Baustein kennt FoundationModels nicht. Das Zählen kommt als
//  Funktion herein, damit Tests es ersetzen können.
//

import Foundation

public enum AnswerTokenPlan {

    /// Platz für die Antwort selbst: zwei bis sechs Sätze und bis zu sechs
    /// Zeilen mit Aussagen, dazu die Struktur des Schemas.
    public static let answerReserve = 800
    /// Die Zahl der Stellen springt in diesen Schritten.
    public static let step = 4
    /// Weniger Stellen gibt es nicht. Passt nicht einmal das, meldet das
    /// Modell einen zu langen Kontext, und der Chat zeigt die Stellen im
    /// Wortlaut.
    public static let minimumCandidates = 4
    /// So groß ist die Probe, an der die Kosten einer Stelle gemessen werden.
    public static let sampleSize = 8
    /// Die alte Schätzung, nur noch Rückfall, wenn der Tokenizer nicht antwortet.
    public static let fallbackCharactersPerToken = 3.0
    /// Zeilennummer „[12] “ und Umbruch je Stelle.
    static let lineOverhead = 8

    /// Wie viele Stellen passen, als Vielfaches von ``step``, höchstens
    /// `ceiling` und mindestens ``minimumCandidates`` (oder `ceiling`, wenn
    /// das kleiner ist).
    public static func candidateCount(
        contextSize: Int, fixedTokens: Int, tokensPerCandidate: Double, ceiling: Int
    ) -> Int {
        let floor = min(minimumCandidates, ceiling)
        guard tokensPerCandidate > 0 else { return ceiling }
        let free = max(0, contextSize - fixedTokens - answerReserve)
        let raw = Int(Double(free) / tokensPerCandidate)
        return min(ceiling, max(floor, raw / step * step))
    }

    /// Das Budget, gefüllt nach Token.
    ///
    /// - Parameters:
    ///   - budget: die Obergrenze der Stufe. Ihre Stellenzahl ist die Decke,
    ///     Auszugslänge und Bibliothek bleiben, wie sie sind.
    ///   - contextSize: das Fenster des Modells in Token.
    ///   - fixedText: Anweisungen und Prompt ohne Stellen.
    ///   - schemaTokens: was das Antwortschema kostet, falls gemessen.
    ///   - sample: die Probe als Liste, genau so, wie das Modell sie sieht.
    ///   - sampleCount: wie viele Stellen in der Probe stehen.
    ///   - margin: Aufschlag auf die gemessenen Token. Private Cloud Compute
    ///     hat einen anderen Tokenizer als das Gerät, dort ist er größer.
    ///   - reservedTokens: Platz, der frei bleiben muss, etwa für die
    ///     Werkzeuge des Chats und ihre Ergebnisse (``ChatLookupLimits``).
    ///   - count: der Tokenizer.
    public static func fitted(
        _ budget: ContextBudget, contextSize: Int,
        fixedText: String, schemaTokens: Int?,
        sample: String, sampleCount: Int, margin: Double = 1.0, reservedTokens: Int = 0,
        count: (String) async throws -> Int
    ) async -> ContextBudget {
        var fixed: Int
        var perCandidate: Double
        do {
            fixed = try await count(fixedText)
            if sampleCount > 0 {
                perCandidate = Double(try await count(sample)) / Double(sampleCount)
            } else {
                perCandidate = estimatedTokensPerCandidate(excerptLimit: budget.excerptLimit)
            }
        } catch {
            fixed = estimatedTokens(characters: fixedText.count)
            perCandidate = estimatedTokensPerCandidate(excerptLimit: budget.excerptLimit)
        }
        // Ohne gemessenes Schema: der Wert, mit dem die App bisher rechnete.
        fixed += schemaTokens ?? 350
        fixed += max(0, reservedTokens)
        let scaled = Int((Double(fixed) * margin).rounded(.up))
        let candidates = candidateCount(
            contextSize: contextSize, fixedTokens: scaled,
            tokensPerCandidate: perCandidate * margin, ceiling: budget.maximumCandidates)
        return ContextBudget(
            maximumCandidates: candidates, excerptLimit: budget.excerptLimit,
            libraryContextLimit: budget.libraryContextLimit)
    }

    static func estimatedTokens(characters: Int) -> Int {
        Int((Double(characters) / fallbackCharactersPerToken).rounded(.up))
    }

    static func estimatedTokensPerCandidate(excerptLimit: Int) -> Double {
        Double(excerptLimit + lineOverhead) / fallbackCharactersPerToken
    }
}

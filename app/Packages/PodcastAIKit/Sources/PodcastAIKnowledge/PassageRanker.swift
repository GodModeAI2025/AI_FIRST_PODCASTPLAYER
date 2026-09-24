//
//  PassageRanker.swift
//  PodcastAIKnowledge
//
//  Findet zu einer Frage die passenden Stellen. Zwei Signale zählen:
//  Stichworte der Frage (gewichtet nach Seltenheit, wie BM25) und die
//  semantische Nähe der Sätze aus Apples NaturalLanguage-Einbettungen.
//  Beides läuft auf dem Gerät, ohne Modellaufruf. Das Sprachmodell bekommt
//  danach nur die besten Stellen zu sehen.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public struct PassageRanker: Sendable {

    /// Zerlegte Wörter und Satzeinbettungen je Stelle, zwischen zwei Fragen
    /// gemerkt. Das Ergebnis ist dasselbe wie ohne.
    let index: PassageIndex

    public init(index: PassageIndex = .shared) {
        self.index = index
    }

    /// Die besten `limit` Belege zur Frage, beste zuerst. Stellen ohne jeden
    /// Bezug fallen weg, außer `keepAll` ist gesetzt (etwa für „fasse die
    /// Folge zusammen“, wo alles relevant ist).
    ///
    /// Eine Satzeinbettung kostet je Stelle einige zehn Millisekunden. Mit
    /// `embeddingLimit` bekommen nur so viele Stellen eine: zuerst die besten
    /// Stichworttreffer, danach gleichmäßig verteilte Stellen aus dem Rest,
    /// damit auch Umschreibungen ohne gemeinsames Wort gefunden werden. Ohne
    /// Grenze wird jede Stelle eingebettet.
    public func rank(_ evidence: [Evidence], for question: String,
                     limit: Int, keepAll: Bool = false, embeddingLimit: Int? = nil) -> [Evidence] {
        guard !evidence.isEmpty else { return [] }
        // Erster Durchgang: Stichworte für alle Stellen, das ist billig.
        let keywords = ChatTrace.measure("Rangfolge Stichworte") {
            keywordScores(evidence, for: question)
        }

        // Zweiter Durchgang: Einbettungen nur für die Auswahl.
        var semantics = [Double](repeating: 0, count: evidence.count)
        #if canImport(NaturalLanguage)
        let selection = Self.embeddingSelection(keywords: keywords, limit: embeddingLimit)
        if let scores = ChatTrace.measure("Rangfolge Einbettungen", {
            index.semanticScores(question: question, evidence: evidence, selection: selection)
        }) {
            semantics = scores
        }
        #endif

        var scored: [(Evidence, Double)] = []
        for (index, item) in evidence.enumerated() {
            let keyword = keywords[index]
            let semantic = semantics[index]
            let score = keyword + 4 * semantic
            if keepAll || keyword > 0 || semantic > 0.35 { scored.append((item, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Stichworte der Frage in jeder Stelle, gewichtet nach Seltenheit wie
    /// BM25. Die Wörter der Stellen kommen aus dem Speicher.
    func keywordScores(_ evidence: [Evidence], for question: String) -> [Double] {
        let terms = Set(Self.terms(question))
        let documents = index.terms(for: evidence)
        let count = Double(documents.count)
        let averageLength = max(1, Double(documents.reduce(0) { $0 + $1.length }) / count)
        // Nur die Wörter der Frage zählen, also auch nur ihre Seltenheit.
        // Sortiert, damit die Summe in jedem Lauf gleich gebildet wird. Die
        // Reihenfolge einer Menge wechselt von Start zu Start, und damit
        // wechselte die letzte Stelle der Punktzahl.
        let keys = terms.sorted().map(PassageIndex.termKey)
        var documentFrequency = keys.map { _ in 0 }
        for document in documents {
            for (position, key) in keys.enumerated() where document.frequency(of: key) > 0 {
                documentFrequency[position] += 1
            }
        }

        var keywords = [Double](repeating: 0, count: evidence.count)
        for (index, document) in documents.enumerated() {
            var keyword = 0.0
            for (position, key) in keys.enumerated() {
                let tf = document.frequency(of: key)
                guard tf > 0 else { continue }
                let df = Double(documentFrequency[position])
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let norm = Double(tf) * 2.2 / (Double(tf) + 1.2 * (0.25 + 0.75 * Double(document.length) / averageLength))
                keyword += idf * norm
            }
            keywords[index] = keyword
        }
        return keywords
    }

    /// Welche Stellen eingebettet werden. Ohne Grenze alle. Mit Grenze die
    /// besten Stichworttreffer, aufgefüllt mit gleichmäßig verteilten
    /// Stellen ohne Treffer.
    static func embeddingSelection(keywords: [Double], limit: Int?) -> [Int] {
        guard let limit, limit < keywords.count else { return Array(keywords.indices) }
        guard limit > 0 else { return [] }
        let hits = keywords.indices
            .filter { keywords[$0] > 0 }
            .sorted { keywords[$0] > keywords[$1] }
        var chosen = Array(hits.prefix(limit))
        let missing = limit - chosen.count
        if missing > 0 {
            let rest = keywords.indices.filter { keywords[$0] <= 0 }
            let step = Double(rest.count) / Double(missing)
            chosen += (0..<min(missing, rest.count)).map { rest[Int(Double($0) * step)] }
        }
        return chosen
    }

    // MARK: - Hilfen

    static let stopwords: Set<String> = [
        "der", "die", "das", "und", "oder", "ein", "eine", "einer", "eines", "einem", "einen",
        "ist", "sind", "war", "wird", "werden", "hat", "haben", "was", "wie", "wer", "wo",
        "warum", "welche", "welcher", "welches", "zu", "zum", "zur", "im", "in", "an", "am",
        "auf", "aus", "mit", "von", "vom", "für", "über", "bei", "nach", "den", "dem", "des",
        "es", "ich", "du", "er", "sie", "wir", "ihr", "man", "sich", "nicht", "auch", "noch",
        "nur", "so", "dass", "da", "dann", "denn", "als", "wenn", "ob", "gibt", "sagt", "folge",
        "podcast", "the", "a", "an", "and", "or", "of", "to", "is", "are", "what", "how",
        "who", "why", "which", "in", "on", "for", "about", "does", "do", "episode",
    ]

    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }
            .map { $0.count > 6 ? String($0.prefix(6)) : $0 }   // grober Wortstamm
    }

    #if canImport(NaturalLanguage)
    static func embedding(for text: String) -> NLEmbedding? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage ?? .german
        return NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for index in a.indices { dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
    #endif
}

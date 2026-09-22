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
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public struct PassageRanker: Sendable {

    public init() {}

    /// Die besten `limit` Belege zur Frage, beste zuerst. Stellen ohne jeden
    /// Bezug fallen weg, ausser `keepAll` ist gesetzt (etwa für „fasse die
    /// Folge zusammen“, wo alles relevant ist).
    public func rank(_ evidence: [Evidence], for question: String,
                     limit: Int, keepAll: Bool = false) -> [Evidence] {
        guard !evidence.isEmpty else { return [] }
        let terms = Self.terms(question)
        let documents = evidence.map { Self.terms($0.quotedText) }
        let count = Double(documents.count)
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { documentFrequency[term, default: 0] += 1 }
        }
        let averageLength = max(1, Double(documents.map(\.count).reduce(0, +)) / count)

        #if canImport(NaturalLanguage)
        let embedding = Self.embedding(for: question)
        let questionVector = embedding?.vector(for: question)
        #endif

        var scored: [(Evidence, Double)] = []
        for (index, item) in evidence.enumerated() {
            let document = documents[index]
            var frequencies: [String: Int] = [:]
            for term in document { frequencies[term, default: 0] += 1 }
            var keyword = 0.0
            for term in Set(terms) {
                guard let tf = frequencies[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let norm = Double(tf) * 2.2 / (Double(tf) + 1.2 * (0.25 + 0.75 * Double(document.count) / averageLength))
                keyword += idf * norm
            }
            var semantic = 0.0
            #if canImport(NaturalLanguage)
            if let embedding, let questionVector,
               let vector = embedding.vector(for: String(item.quotedText.prefix(600))) {
                semantic = max(0, Self.cosine(questionVector, vector))
            }
            #endif
            let score = keyword + 4 * semantic
            if keepAll || keyword > 0 || semantic > 0.35 { scored.append((item, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
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

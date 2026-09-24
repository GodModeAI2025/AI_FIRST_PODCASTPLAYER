//
//  TagSimilarity.swift
//  PodcastAIKnowledge
//
//  „Zusammenlegen?“ auf der Tag-Seite. Zwei Tags mit gleichem Schlüssel legt
//  der Speicher selbst zusammen. Was nur nahe beieinander liegt, legt der Code
//  nie von selbst zusammen; er schlägt es vor, und jemand entscheidet.
//
//  Nahe heißt:
//  - Ein Schlüssel beginnt oder endet mit dem anderen, und der kürzere hat
//    mindestens vier Zeichen („datenschutz“ und „datenschutzgesetz“,
//    „modelle“ und „sprachmodelle“).
//  - Die Schlüssel unterscheiden sich um höchstens zwei Zeichen, bei
//    Schlüsseln ab sechs Zeichen, etwa bei Tippfehlern in Shownotes.
//  - Der Satzvektor (`NLEmbedding.sentenceEmbedding`) der Sprache beider
//    Bezeichnungen liegt sehr nah. Bei einzelnen Wörtern trennt er schlecht,
//    deshalb gilt eine enge Grenze, und nur bei gleicher erkannter Sprache.
//
//  Länder (`region:`) liegen nur über ihren Schlüssel nahe, nie über den
//  Vektor.
//

import Foundation
import NaturalLanguage
import PodcastAICore

public enum TagSimilarity {

    /// Die Grenze für den Satzvektor, als Kosinusabstand zwischen 0 und 2.
    /// Gemessen unter macOS 27 mit dem deutschen Vektor: fremde Begriffe
    /// liegen meist über 0,95, auch verwandte oft darüber („Klimawandel“ und
    /// „Erderwärmung“ 0,98). Die Grenze ist eng, damit kein Unsinn kommt;
    /// die meisten Vorschläge kommen deshalb über die Schlüssel.
    static let embeddingThreshold: Double = 0.85

    /// Tags, die nahe an `tag` liegen, die nächsten zuerst.
    public static func nearTags(to tag: Tag, in tags: [Tag], limit: Int = 5) -> [Tag] {
        let key = tag.normalizedKey
        guard !key.isEmpty else { return [] }
        var embeddings: [NLLanguage: NLEmbedding] = [:]
        let ownLanguage = language(of: tag.label)
        var scored: [(tag: Tag, score: Double)] = []
        for other in tags where other.id != tag.id && !other.normalizedKey.isEmpty && other.normalizedKey != key {
            if let score = lexicalScore(key, other.normalizedKey) {
                scored.append((other, score))
                continue
            }
            guard !key.hasPrefix("region:"), !other.normalizedKey.hasPrefix("region:"),
                  let language = ownLanguage, language == self.language(of: other.label) else { continue }
            if embeddings[language] == nil { embeddings[language] = NLEmbedding.sentenceEmbedding(for: language) }
            guard let embedding = embeddings[language] else { continue }
            let distance = embedding.distance(between: tag.label, and: other.label)
            if distance < embeddingThreshold { scored.append((other, distance)) }
        }
        return scored
            .sorted { ($0.score, $0.tag.label) < ($1.score, $1.tag.label) }
            .prefix(limit)
            .map(\.tag)
    }

    /// Die Sprache einer Bezeichnung, nur Deutsch oder Englisch. Der Vektor
    /// einer Sprache sagt über Wörter einer anderen nichts: Der englische
    /// legte „Datenschutz“ und „Fußball“ nah zusammen. Deshalb vergleicht
    /// der Code nur Bezeichnungen derselben erkannten Sprache.
    static func language(of label: String) -> NLLanguage? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: label),
              language == .german || language == .english else { return nil }
        return language
    }

    /// Nähe allein über die Schlüssel, oder `nil`. Kleiner ist näher.
    static func lexicalScore(_ lhs: String, _ rhs: String) -> Double? {
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        if shorter.count >= 4, longer.hasPrefix(shorter) || longer.hasSuffix(shorter) {
            return 0
        }
        if shorter.count >= 6, longer.count - shorter.count <= 2, editDistance(lhs, rhs) <= 2 {
            return 0.1
        }
        return nil
    }

    /// Levenshtein-Abstand, für kurze Schlüssel.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

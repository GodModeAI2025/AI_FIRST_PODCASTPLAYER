//
//  TopicTags.swift
//  PodcastAIKnowledge
//
//  Die Themen einer Folge als kurze Schlagworte.
//
//  Ohne Modell und ohne eigene Tabelle: die Schlagworte entstehen beim
//  Anzeigen aus dem, was schon da ist. Zuerst die eigenen Interessen, die in
//  der Folge vorkommen, danach Hauptwörter, die in mehreren Aussagen der
//  Folge stehen oder in einer Aussage und oft im Transkript. Ein neues
//  Schlagwort ist nur ein Angebot. Zum Interesse wird es erst, wenn jemand
//  darauf tippt.
//

import Foundation
import PodcastAICore

public struct TopicTag: Sendable, Hashable, Identifiable {
    public let label: String
    /// Gesetzt, wenn das Schlagwort schon eines der eigenen Interessen ist.
    public let interestID: InterestID?

    public var id: String { label.lowercased() }
    public var isInterest: Bool { interestID != nil }

    public init(label: String, interestID: InterestID? = nil) {
        self.label = label
        self.interestID = interestID
    }
}

public struct TopicTagger: Sendable {

    public let maximumTags: Int
    /// Höchstens so viele der Schlagworte sind schon bekannte Interessen,
    /// damit auch Neues Platz hat.
    public let maximumInterests: Int

    public init(maximumTags: Int = 5, maximumInterests: Int = 3) {
        self.maximumTags = maximumTags
        self.maximumInterests = maximumInterests
    }

    /// Schlagworte zu einer Folge.
    ///
    /// - Parameters:
    ///   - statements: die Aussagen der Folge, also die Fakten.
    ///   - passages: die Belege der Folge.
    ///   - profile: das Interessenprofil. Nur bestätigte Themen zählen.
    public func tags(statements: [String], passages: [Evidence], profile: InterestProfile) -> [TopicTag] {
        let interests = interestTags(passages: passages, profile: profile)
        let covered = Set(interests.flatMap { tag in
            RelevanceScorer.normalize(tag.label).split(separator: " ").map(String.init)
        })
        let nouns = nounTags(statements: statements, passages: passages)
            .filter { !Self.isCovered(RelevanceScorer.normalize($0.label), by: covered) }
        return Array((interests + nouns).prefix(maximumTags))
    }

    // MARK: - Eigene Interessen

    /// Themen, zu denen die Folge etwas sagt. Bei kurzen Folgen genügt
    /// eine Stelle, sonst braucht es zwei, damit ein Nebensatz kein Thema macht.
    ///
    /// Nur Interessen der Art Thema. Offene Fragen und Vorhaben sind ganze
    /// Sätze wie „Welche Möglichkeiten bietet iOS 27 für agentische Apps?“
    /// und taugen nicht als Schlagwort.
    func interestTags(passages: [Evidence], profile: InterestProfile) -> [TopicTag] {
        let needed = passages.count < 8 ? 1 : 2
        var hits: [InterestID: Set<EvidenceID>] = [:]
        for match in RelevanceScorer().score(evidence: passages, profile: profile) {
            hits[match.interestID, default: []].insert(match.evidenceID)
        }
        return profile.topics
            .filter { (hits[$0.id]?.count ?? 0) >= needed }
            .sorted { lhs, rhs in
                let left = hits[lhs.id]?.count ?? 0, right = hits[rhs.id]?.count ?? 0
                return left != right ? left > right : lhs.label < rhs.label
            }
            .prefix(maximumInterests)
            .map { TopicTag(label: $0.label, interestID: $0.id) }
    }

    // MARK: - Hauptwörter

    /// Hauptwörter aus den Aussagen. Erkannt am großen Anfangsbuchstaben
    /// mitten im Satz; das trägt im Deutschen weit, im Englischen bleiben
    /// Namen übrig, und auch die sind brauchbare Schlagworte.
    ///
    /// Ein Schlagwort steht in der kürzesten Form, die die Folge belegt:
    /// „Sprachmodell“, wenn irgendwo „Sprachmodell“ fällt, auch wenn die
    /// Aussagen nur „bei Sprachmodellen“ sagen. Wer darauf tippt, legt diese
    /// Form als Interesse an, und die trifft am Wortanfang alle längeren
    /// Formen. Mit „Sprachmodellen“ als Interesse blieben „Sprachmodell“
    /// und „Sprachmodelle“ ohne Treffer.
    func nounTags(statements: [String], passages: [Evidence]) -> [TopicTag] {
        // Normalisierter Begriff → wie er zuerst geschrieben stand, und in
        // welchen Aussagen er vorkommt.
        var spelling: [String: String] = [:]
        var inStatements: [String: Set<Int>] = [:]
        for (index, statement) in statements.enumerated() {
            for word in Self.nounCandidates(in: statement) {
                let key = RelevanceScorer.normalize(word)
                guard !key.isEmpty, Self.isUsable(key) else { continue }
                if spelling[key] == nil { spelling[key] = word }
                inStatements[key, default: []].insert(index)
            }
        }

        // Was in Aussagen und Belegen steht, normalisiert und mit Leerzeichen
        // an beiden Enden, dazu die einzelnen Wörter.
        let padded = passages.map { " " + RelevanceScorer.normalize($0.quotedText) + " " }
        let texts = statements.map { " " + RelevanceScorer.normalize($0) + " " } + padded
        let words = Set(texts.flatMap { $0.split(separator: " ").map(String.init) })
        let occurs: (String) -> Bool = { form in
            form.contains(" ") ? texts.contains { $0.contains(" \(form) ") } : words.contains(form)
        }

        // Einzahl, Mehrzahl und Fälle zusammenlegen: „Batterie“ und
        // „Batterien“ sind ein Thema. Kürzere Schlüssel zuerst, damit die
        // Schreibweise möglichst schon die Grundform ist.
        let keys = inStatements.keys.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        var grouped: [String: Set<Int>] = [:]
        var label: [String: String] = [:]
        for key in keys {
            let base = Self.baseForm(of: key, occurs: occurs)
            // Ist die Grundform ein Allerweltswort („Punkt“ zu „Punkten“),
            // ist es auch die gebeugte Form.
            guard Self.isUsable(base) else { continue }
            grouped[base, default: []].formUnion(inStatements[key] ?? [])
            if label[base] == nil {
                let written = spelling[key] ?? key
                label[base] = String(written.dropLast(key.count - base.count))
            }
        }

        var scored: [(label: String, facts: Int, passages: Int)] = []
        for (base, indices) in grouped {
            let inPassages = padded.filter { text in
                Self.suffixes.contains { text.contains(" \(base)\($0) ") }
            }.count
            guard indices.count >= 2 || inPassages >= 3 else { continue }
            scored.append((label[base] ?? base, indices.count, inPassages))
        }
        return scored
            .sorted { lhs, rhs in
                let left = lhs.facts * 3 + lhs.passages, right = rhs.facts * 3 + rhs.passages
                return left != right ? left > right : lhs.label < rhs.label
            }
            .map { TopicTag(label: $0.label) }
    }

    /// Die kürzeste Form eines Begriffs, die entsteht, wenn eine Endung aus
    /// ``suffixes`` wegfällt, und die selbst in der Folge vorkommt. Sonst der
    /// Begriff, wie er ist.
    ///
    /// Nur belegte Formen, nichts Erfundenes: aus „Batterien“ wird
    /// „Batterie“, aber nie „Batteri“, und „Unternehmen“ bleibt, auch wenn
    /// „Unternehmer“ vorkommt. Eine Form unter fünf Buchstaben zählt nicht,
    /// sonst würde aus „Daten“ ein „Date“.
    static func baseForm(of key: String, occurs: (String) -> Bool) -> String {
        suffixes
            .filter { !$0.isEmpty && key.hasSuffix($0) }
            .map { String(key.dropLast($0.count)) }
            .filter { $0.filter(\.isLetter).count >= 5 && occurs($0) }
            .min { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            ?? key
    }

    /// Wörter mit großem Anfangsbuchstaben, die nicht am Satzanfang stehen.
    /// Satzzeichen am Rand fallen weg, ein Bindestrich im Wort bleibt.
    static func nounCandidates(in statement: String) -> [String] {
        var result: [String] = []
        var sentenceStart = true
        for raw in statement.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            defer { sentenceStart = raw.last.map { ".!?:…".contains($0) } ?? false }
            guard !sentenceStart, let first = word.first, first.isUppercase else { continue }
            guard word.filter(\.isLetter).count >= 5 else { continue }
            result.append(word)
        }
        return result
    }

    static func isUsable(_ key: String) -> Bool {
        !RelevanceScorer.stopWords.contains(key)
            && !PassageRanker.stopwords.contains(key)
            && !generic.contains(key)
            && !key.allSatisfy { $0.isNumber || $0 == " " }
            // Zu Parteien, Wahlen, Religion und ähnlichem schlägt die App
            // keine Interessen vor.
            && SensitiveTopicPolicy.allowsInterestDerivation(from: key)
    }

    static let suffixes = ["", "n", "en", "e", "s", "es", "er"]

    static func isCovered(_ key: String, by words: Set<String>) -> Bool {
        key.split(separator: " ").contains { part in
            words.contains { word in
                word.count >= 4 && (part.hasPrefix(word) || word.hasPrefix(part))
            }
        }
    }

    /// Hauptwörter, die in fast jeder Folge stehen und kein Thema sind.
    static let generic: Set<String> = [
        "folge", "folgen", "podcast", "podcasts", "episode", "sendung", "beispiel", "beispiele",
        "thema", "themen", "frage", "fragen", "antwort", "prozent", "jahre", "jahren", "menschen",
        "leute", "zeiten", "anfang", "sprecher", "sprecherin", "gastgeber", "moderator",
        "moderatorin", "studie", "studien", "dinge", "sache", "sachen", "punkt", "punkte",
        "weise", "seite", "seiten", "millionen", "milliarden", "hälfte", "grund",
        "gründe", "ende", "teil", "teile", "welt", "stunde", "stunden", "minuten",
    ]
}

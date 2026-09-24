//
//  ChapterClassifier.swift
//  PodcastAIKnowledge
//
//  Tags je Kapitel, ohne Datenbank. Drei Schritte:
//
//  1. Kandidaten ohne Modell (``ChapterTagCandidates``): Tags, denen jemand
//     folgt, bekannte Tags, die im Kapitel vorkommen, Namen von Orten und
//     Organisationen aus `NLTagger` und Hauptwörter aus `TopicTagger`.
//     Gerankt über den Satzvektor gegen den Kapiteltext, die besten 20
//     bleiben.
//  2. Das Modell wählt daraus höchstens fünf (``TagSelector``), über
//     Kennungen, die der Code vergeben hat.
//  3. Ein Oberbegriff, der noch kein Tag ist, kommt nur aus den Kandidaten
//     von Schritt 1, nie als freier Text. Je Kapitel höchstens einer.
//
//  Lange Kapitel teilt der Code in Teile, die ins Fenster des Modells
//  passen. Die Teile werden vereinigt, gezählt wird, wie viele Teile ein
//  Tag gewählt haben. Die Sicherheit rechnet der Code, nicht das Modell.
//

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
import PodcastAICore
import PodcastAIIntelligence

/// Ein Schlagwort, das für ein Kapitel in Frage kommt.
public struct TagCandidate: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        /// Ein Tag, dem jemand folgt.
        case followed
        /// Ein bekanntes Tag, das im Kapitel vorkommt.
        case known
        /// Ein Ort oder eine Organisation aus der Namenserkennung.
        case name
        /// Ein Hauptwort aus `TopicTagger`.
        case noun
    }

    public let label: String
    public let normalizedKey: String
    /// Gesetzt, wenn der Kandidat schon ein Tag ist.
    public let tagID: InterestID?
    public let origin: Origin
    /// Wie oft der Kandidat im Kapitel vorkommt.
    public let occurrences: Int
    /// Satzvektor-Nähe zum Kapiteltext, 0 bis 1, oder 0 ohne Vektor.
    public let similarity: Double

    public init(label: String, normalizedKey: String, tagID: InterestID?, origin: Origin,
                occurrences: Int, similarity: Double) {
        self.label = label; self.normalizedKey = normalizedKey; self.tagID = tagID
        self.origin = origin; self.occurrences = occurrences; self.similarity = similarity
    }

    public var isKnown: Bool { tagID != nil }

    /// Rang in der Liste. Nähe zählt am meisten, dann Vorkommen, dann ob
    /// jemand dem Tag folgt.
    public var score: Double {
        similarity + 0.15 * Double(min(occurrences, 3)) + (origin == .followed ? 0.1 : 0)
    }
}

/// Stoff eines Kapitels für die Einordnung.
public struct ChapterMaterial: Sendable {
    public let section: ChapterSection
    public let evidence: [Evidence]
    /// Die Fakten des Kapitels, für die Hauptwörter.
    public let statements: [String]

    public init(section: ChapterSection, evidence: [Evidence], statements: [String]) {
        self.section = section; self.evidence = evidence; self.statements = statements
    }

    /// Der Text des Kapitels, wie ihn Kandidaten und Ranking lesen.
    public var text: String { evidence.map(\.quotedText).joined(separator: " ") }
}

public enum ChapterTagCandidates {

    /// So viele Kandidaten sieht das Modell höchstens.
    public static let limit = 20
    /// Bis zu so vielen Tags wiegt der Satzvektor auch Tags, die im Kapitel
    /// nicht wörtlich vorkommen.
    public static let maximumLooseTags = 300
    /// So nah muss ein solches Tag dem Kapitel mindestens sein.
    public static let looseSimilarity = 0.35

    /// Nähe von Schlagworten zu einem Text, eine Zahl je Schlagwort, oder
    /// `nil`, wenn sie sich nicht messen lässt.
    public typealias Similarity = @Sendable (_ text: String, _ labels: [String]) -> [Double]?

    /// Die Kandidaten eines Kapitels, beste zuerst, höchstens `limit`.
    public static func build(
        _ material: ChapterMaterial, tags: [Tag], limit: Int = ChapterTagCandidates.limit,
        similarity: Similarity = ChapterTagCandidates.embeddingSimilarity
    ) -> [TagCandidate] {
        let text = material.text
        guard !text.isEmpty else { return [] }
        let padded = " " + RelevanceScorer.normalize(text) + " "

        struct Draft { var label: String; var key: String; var tagID: InterestID?; var origin: TagCandidate.Origin; var occurrences: Int }
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        func add(_ draft: Draft) {
            guard !draft.key.isEmpty else { return }
            if var existing = drafts[draft.key] {
                // Ein Tag geht vor dem Namen gleichen Schlüssels, Plus vor bekannt.
                if existing.tagID == nil, draft.tagID != nil { existing = draft }
                if draft.origin == .followed { existing.origin = .followed }
                existing.occurrences = max(existing.occurrences, draft.occurrences)
                drafts[draft.key] = existing
            } else {
                drafts[draft.key] = draft
                order.append(draft.key)
            }
        }

        // Bekannte Tags: denen jemand folgt, immer; die übrigen, wenn sie
        // im Kapitel vorkommen, über Bezeichnung oder Alias. Die anderen
        // zählen nur, wenn der Satzvektor sie nahe am Kapitel sieht, und
        // nur bei einer überschaubaren Zahl von Tags, denn jedes kostet
        // einen Vektor je Kapitel.
        var loose: Set<String> = []
        let weighLoose = tags.count <= maximumLooseTags
        for tag in tags where !tag.normalizedKey.isEmpty {
            let hits = ([tag.label] + tag.aliases).map { occurrences(of: $0, in: padded) }.max() ?? 0
            guard tag.isFollowed || hits > 0 || weighLoose else { continue }
            if !tag.isFollowed, hits == 0, drafts[tag.normalizedKey] == nil { loose.insert(tag.normalizedKey) }
            add(Draft(label: tag.label, key: tag.normalizedKey, tagID: tag.id,
                      origin: tag.isFollowed ? .followed : .known, occurrences: hits))
        }

        // Neue Kandidaten aus dem Text. Was schon ein Tag ist, zählt als
        // bekannt. Was keines werden darf (Parteien, Religion, ganze Sätze),
        // fällt weg.
        let nouns = TopicTagger().nounTags(statements: material.statements, passages: material.evidence)
            .map(\.label)
        for (label, origin) in names(in: text).map({ ($0, TagCandidate.Origin.name) })
            + nouns.map({ ($0, TagCandidate.Origin.noun) }) {
            let hits = occurrences(of: label, in: padded)
            if let tag = TagNormalizer.resolve(label, in: tags) {
                loose.remove(tag.normalizedKey)
                add(Draft(label: tag.label, key: tag.normalizedKey, tagID: tag.id,
                          origin: tag.isFollowed ? .followed : .known, occurrences: hits))
                continue
            }
            guard TagNormalizer.admitsDetectedTag(label) else { continue }
            add(Draft(label: label, key: TagNormalizer.key(for: label), tagID: nil,
                      origin: origin, occurrences: hits))
        }

        let list = order.compactMap { drafts[$0] }
        guard !list.isEmpty else { return [] }
        let near = similarity(text, list.map(\.label))
        let scored = list.enumerated().map { index, draft in
            TagCandidate(label: draft.label, normalizedKey: draft.key, tagID: draft.tagID,
                         origin: draft.origin, occurrences: draft.occurrences,
                         similarity: near.flatMap { $0.count == list.count ? max(0, min(1, $0[index])) : nil } ?? 0)
        }
        return Array(scored.enumerated()
            .filter { !loose.contains($0.element.normalizedKey) || $0.element.similarity >= looseSimilarity }
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
            }
            .map(\.element)
            .prefix(max(0, limit)))
    }

    /// Wie oft eine Schreibweise im normalisierten Text am Wortanfang
    /// steht. „Batterie“ trifft auch „Batterien“.
    static func occurrences(of label: String, in padded: String) -> Int {
        let form = RelevanceScorer.normalize(label)
        guard form.count >= 2 else { return 0 }
        return padded.components(separatedBy: " " + form).count - 1
    }

    /// Kennungen für das Modell: „k1“ … für bekannte Tags, „n1“ … für neue
    /// Kandidaten, in der Reihenfolge der Liste.
    public static func choices(for candidates: [TagCandidate]) -> [TagChoice] {
        var known = 0, new = 0
        return candidates.map { candidate in
            if candidate.isKnown {
                known += 1
                return TagChoice(id: "k\(known)", label: candidate.label)
            }
            new += 1
            return TagChoice(id: "n\(new)", label: candidate.label)
        }
    }

    // MARK: - Namen

    /// Orte und Organisationen im Text, jede Schreibweise einmal, in der
    /// Reihenfolge ihres ersten Auftretens. Personen nicht: ein Mensch ist
    /// kein Thema, und die App leitet aus Namen von Menschen keine Tags ab.
    public static func names(in text: String) -> [String] {
        #if canImport(NaturalLanguage)
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        if let language = recognizer.dominantLanguage { tagger.setLanguage(language, range: whole) }
        var seen: Set<String> = []
        var result: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: whole, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard tag == .placeName || tag == .organizationName else { return true }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.filter(\.isLetter).count >= 2, name.first?.isUppercase == true,
                  TopicTagger.isTagShaped(name) else { return true }
            if seen.insert(TagNormalizer.fold(name)).inserted { result.append(name) }
            return true
        }
        return result
        #else
        return []
        #endif
    }

    // MARK: - Satzvektoren

    /// Kosinus zwischen Kapiteltext und jedem Schlagwort, über Apples
    /// Satzvektoren in der Sprache des Kapitels. Ohne Vektor `nil`, dann
    /// zählen nur Vorkommen und Plus.
    public static let embeddingSimilarity: Similarity = { text, labels in
        #if canImport(NaturalLanguage)
        let sample = String(text.prefix(2_000))
        guard let embedding = PassageRanker.embedding(for: sample),
              let textVector = embedding.vector(for: sample) else { return nil }
        return labels.map { label in
            guard let vector = embedding.vector(for: label) else { return 0 }
            return PassageRanker.cosine(textVector, vector)
        }
        #else
        return nil
        #endif
    }
}

/// Ein Tag, das die Einordnung einem Kapitel gibt.
public struct ChapterTagPick: Sendable, Hashable {
    public let label: String
    public let normalizedKey: String
    /// Gesetzt bei einem bekannten Tag. Ohne Kennung ist es ein neuer
    /// Oberbegriff aus den Kandidaten, der als erkanntes Tag angelegt wird.
    public let tagID: InterestID?
    /// Zwischen 0 und 1, vom Code gerechnet.
    public let confidence: Double

    public init(label: String, normalizedKey: String, tagID: InterestID?, confidence: Double) {
        self.label = label; self.normalizedKey = normalizedKey; self.tagID = tagID
        self.confidence = confidence
    }
}

public enum ChapterClassifier {

    /// Neue Oberbegriffe je Kapitel. Die Hauptwörter aus `TopicTagger` sind
    /// laut, und jedes neue Tag landet im Abgleich.
    public static let newTagsPerChapter = 1
    /// Mehr Teile bekommt ein Kapitel nicht. Ein langes Kapitel wird dann
    /// gleichmäßig ausgedünnt.
    public static let maximumParts = 6

    /// Wählt aus einer Liste für einen Teil des Kapitels. In der App
    /// ``TagSelector/select(from:passages:title:availability:preferCloud:)``.
    public typealias Select = @Sendable (_ choices: [TagChoice], _ passages: [Evidence]) async throws -> [String]

    /// Teilt die Belege eines Kapitels in Teile, die ins Fenster passen.
    ///
    /// `cost` schätzt die Token eines Belegs, `budget` ist das Fenster für
    /// Transkript je Aufruf. Aufeinanderfolgende Belege bleiben zusammen.
    /// Ein Beleg, der allein zu groß ist, wird ein eigener Teil. Wären es
    /// mehr als ``maximumParts``, werden die Belege vorher gleichmäßig
    /// ausgedünnt, damit jede Stelle des Kapitels vertreten bleibt.
    public static func parts(of evidence: [Evidence], budget: Int, cost: (Evidence) -> Int) -> [[Evidence]] {
        let budget = max(1, budget)
        func split(_ items: [Evidence]) -> [[Evidence]] {
            var result: [[Evidence]] = []
            var current: [Evidence] = []
            var used = 0
            for item in items {
                let price = max(1, cost(item))
                if !current.isEmpty, used + price > budget {
                    result.append(current)
                    current = []
                    used = 0
                }
                current.append(item)
                used += price
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        var result = split(evidence)
        var kept = evidence
        while result.count > maximumParts, kept.count > 1 {
            kept = ChapterSections.evenlySpaced(kept, count: max(1, kept.count * maximumParts / result.count))
            result = split(kept)
        }
        return result
    }

    /// Führt die Auswahl der Teile zusammen.
    ///
    /// Zuerst, was die meisten Teile gewählt haben, bei Gleichstand der
    /// bessere Rang. Höchstens ``TagSelectionRules/maximumChosen`` Tags,
    /// davon höchstens ``newTagsPerChapter`` neue. Die Sicherheit ist der
    /// Anteil der Teile, die das Tag gewählt haben, gemischt mit der Nähe.
    public static func merge(_ chosen: [[String]], candidates: [TagCandidate]) -> [ChapterTagPick] {
        let choices = ChapterTagCandidates.choices(for: candidates)
        var byID: [String: (rank: Int, candidate: TagCandidate)] = [:]
        for (rank, pair) in zip(choices, candidates).enumerated() { byID[pair.0.id] = (rank, pair.1) }
        let parts = max(1, chosen.count)
        var votes: [String: Int] = [:]
        for part in chosen {
            for id in Set(part) where byID[id] != nil { votes[id, default: 0] += 1 }
        }
        let ranked = votes.keys.sorted { lhs, rhs in
            votes[lhs]! != votes[rhs]! ? votes[lhs]! > votes[rhs]! : byID[lhs]!.rank < byID[rhs]!.rank
        }
        var picks: [ChapterTagPick] = []
        var newCount = 0
        var keys: Set<String> = []
        for id in ranked {
            guard picks.count < TagSelectionRules.maximumChosen, let candidate = byID[id]?.candidate,
                  keys.insert(candidate.normalizedKey).inserted else { continue }
            if !candidate.isKnown {
                guard newCount < newTagsPerChapter else { continue }
                newCount += 1
            }
            let share = Double(votes[id] ?? 0) / Double(parts)
            let confidence = 0.6 * share + 0.4 * min(1, max(0, candidate.similarity))
            picks.append(ChapterTagPick(label: candidate.label, normalizedKey: candidate.normalizedKey,
                                        tagID: candidate.tagID, confidence: confidence))
        }
        return picks
    }

    /// Ordnet ein Kapitel ein: Kandidaten, Teile, Auswahl je Teil, Zusammenführen.
    ///
    /// Ohne Kandidaten oder ohne Belege läuft kein Modell, und das Kapitel
    /// bekommt keine Tags.
    public static func classify(
        _ material: ChapterMaterial, tags: [Tag], budget: Int, cost: (Evidence) -> Int,
        similarity: ChapterTagCandidates.Similarity = ChapterTagCandidates.embeddingSimilarity,
        select: Select
    ) async throws -> [ChapterTagPick] {
        let candidates = ChapterTagCandidates.build(material, tags: tags, similarity: similarity)
        guard !candidates.isEmpty, !material.evidence.isEmpty else { return [] }
        let choices = ChapterTagCandidates.choices(for: candidates)
        var chosen: [[String]] = []
        for part in parts(of: material.evidence, budget: budget, cost: cost) {
            try Task.checkCancellation()
            chosen.append(TagSelectionRules.accepted(try await select(choices, part), from: choices))
        }
        return merge(chosen, candidates: candidates)
    }
}

/// Wie weit die Einordnung einer Folge gekommen ist. Liegt nur auf diesem
/// Gerät und hält die fertigen Kapitel, bis die Folge ganz eingeordnet ist.
/// Erst dann gehen die Kapitel-Tags in die Datenbank, in einem Schritt,
/// damit der Abgleich nicht nach jedem Kapitel alle Zeilen neu schreibt.
public struct ChapterTaggingProgress: Codable, Sendable, Equatable {
    public let mediaVersionID: MediaVersionID
    public let transcriptRevision: Int
    /// Aus den Kapitelgrenzen. Ändern sie sich, etwa weil die Kapiteldatei
    /// nachgeladen wurde, beginnt die Einordnung von vorn.
    public let signature: String
    /// Anfang des letzten fertigen Kapitels in Millisekunden.
    public private(set) var lastFinishedStartMs: Int64?
    /// Die Kapitel-Tags der fertigen Kapitel.
    public private(set) var tags: [ChapterTag]

    public init(mediaVersionID: MediaVersionID, transcriptRevision: Int, sections: [ChapterSection]) {
        self.mediaVersionID = mediaVersionID
        self.transcriptRevision = transcriptRevision
        self.signature = Self.signature(of: sections)
        self.lastFinishedStartMs = nil
        self.tags = []
    }

    public static func signature(of sections: [ChapterSection]) -> String {
        sections.map { "\($0.range.start.milliseconds)-\($0.range.end.milliseconds)" }.joined(separator: ",")
    }

    /// Gehört dieser Stand zu Fassung, Revision und Kapiteln?
    public func matches(mediaVersionID: MediaVersionID, transcriptRevision: Int, sections: [ChapterSection]) -> Bool {
        self.mediaVersionID == mediaVersionID && self.transcriptRevision == transcriptRevision
            && signature == Self.signature(of: sections)
    }

    /// Die Kapitel, die noch fehlen.
    public func remaining(_ sections: [ChapterSection]) -> [ChapterSection] {
        guard let lastFinishedStartMs else { return sections }
        return sections.filter { $0.range.start.milliseconds > lastFinishedStartMs }
    }

    public var isStarted: Bool { lastFinishedStartMs != nil }

    /// Ein Kapitel ist fertig, mit seinen Tags.
    public mutating func finish(_ section: ChapterSection, tags new: [ChapterTag]) {
        let start = section.range.start.milliseconds
        tags.removeAll { Int64($0.chapterStartMs) == start }
        tags += new
        lastFinishedStartMs = max(lastFinishedStartMs ?? start, start)
    }
}

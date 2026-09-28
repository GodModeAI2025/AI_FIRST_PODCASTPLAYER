//
//  ChatFollowUp.swift
//  PodcastAIKnowledge
//
//  Welche Stellen eine Folgefrage bekommt.
//
//  „Und was sagt er dazu?“ trifft kein Stichwort. Die Suche allein fände
//  irgendetwas, nur nicht die Stelle, über die gerade gesprochen wurde.
//  Deshalb zählt bei einer Folgefrage auch, was die Antwort davor belegt
//  hat: ihre Stellen selbst und die Folgen, aus denen sie stammen.
//
//  Der Code grenzt vorher ein (`ChatNarrowing`). Hier wird nur innerhalb
//  des Bestands gewählt, den die Frage ohnehin geladen hat. Ein früherer
//  Beleg außerhalb dieses Bestands kommt nicht zurück, auch wenn die
//  Antwort davor auf ihm stand. Hat jemand die Eingrenzung geändert, gilt
//  die neue.
//

import Foundation
import PodcastAICore

/// Was eine Folgefrage von der Unterhaltung davor weiß.
public struct ChatFollowUp: Sendable, Equatable {

    /// Frühere Fragen, die älteste zuerst.
    public let questions: [String]
    /// Die Belege der letzten Antwort, die noch Belege hat, in ihrer Reihenfolge.
    public let evidenceIDs: [EvidenceID]
    /// Die Folgen dieser Belege.
    public let episodeIDs: Set<EpisodeID>

    public init(questions: [String] = [], evidenceIDs: [EvidenceID] = [], episodeIDs: Set<EpisodeID> = []) {
        self.questions = questions
        self.evidenceIDs = evidenceIDs
        self.episodeIDs = episodeIDs
    }

    /// Keine Frage davor: dann ist es keine Folgefrage.
    public var isEmpty: Bool { questions.isEmpty }

    /// So viele Stellen der Antwort davor stehen höchstens vorn in der Liste.
    public static func carriedLimit(for limit: Int) -> Int { max(2, limit / 4) }

    /// Die Stellen für die Folgefrage, die besten zuerst, höchstens `limit`.
    ///
    /// Vorn stehen Belege der Antwort davor, soweit sie im Bestand liegen.
    /// Danach wechseln sich zwei Listen ab: die Suche nach der Frage selbst
    /// und die Suche nach letzter und neuer Frage zusammen, nur in den
    /// Folgen, aus denen die Antwort davor stammt. So findet „Und was sagt
    /// er dazu?“ denselben Sprecher, und eine Frage zu einem neuen Thema
    /// findet trotzdem ihre eigenen Stellen.
    public func rank(_ pool: [Evidence], for question: String, limit: Int,
                     embeddingLimit: Int? = nil, ranker: PassageRanker = PassageRanker()) -> [Evidence] {
        let direct = ranker.rank(pool, for: question, limit: limit, embeddingLimit: embeddingLimit)
        guard !isEmpty, limit > 0 else { return direct }

        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenCarried: Set<EvidenceID> = []
        let carried = evidenceIDs.compactMap { byID[$0] }
            .filter { seenCarried.insert($0.id).inserted }
            .prefix(Self.carriedLimit(for: limit))

        var related: [Evidence] = []
        let focus = pool.filter { episodeIDs.contains($0.episodeID) }
        if !focus.isEmpty {
            let combined = ((questions.last.map { [$0] } ?? []) + [question]).joined(separator: " ")
            related = ranker.rank(focus, for: combined, limit: limit,
                                  embeddingLimit: embeddingLimit.map { max(1, $0 / 2) })
        }

        var result: [Evidence] = []
        var seen: Set<EvidenceID> = []
        func take(_ item: Evidence) {
            guard result.count < limit, seen.insert(item.id).inserted else { return }
            result.append(item)
        }
        carried.forEach(take)
        var position = 0
        while result.count < limit, position < max(direct.count, related.count) {
            if position < related.count { take(related[position]) }
            if position < direct.count { take(direct[position]) }
            position += 1
        }
        return result
    }
}

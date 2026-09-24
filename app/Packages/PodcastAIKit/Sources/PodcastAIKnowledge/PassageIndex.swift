//
//  PassageIndex.swift
//  PodcastAIKnowledge
//
//  Was `PassageRanker` je Stelle ausrechnet und zwischen zwei Fragen gleich
//  bleibt: die zerlegten Wörter einer Stelle und ihre Satzeinbettung. Bis
//  0.9 entstand beides bei jeder Frage neu, für 18.000 Stellen einige
//  Sekunden. Dazu das Einbettungsmodell je Sprache, das sonst jede Frage
//  neu lud.
//
//  Der Schlüssel ist die Kennung des Belegs. Sie enthält Fassung, Revision
//  des Transkripts und Zeitbereich, eine neue Revision bekommt also von
//  selbst neue Einträge. Zusätzlich muss der Text passen (Länge und
//  Prüfsumme), sonst wird neu gerechnet. „Folge löschen“ nimmt die Einträge
//  der Folge mit (`forget(episodes:)`), „Audio entfernen“ lässt sie stehen.
//
//  Die Ergebnisse sind dieselben wie ohne Zwischenspeicher: gleiche Wörter,
//  gleiche Häufigkeiten, gleiche Vektoren.
//

import Foundation
import Synchronization
import PodcastAICore
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public final class PassageIndex: Sendable {

    /// Der gemeinsame Speicher der App.
    public static let shared = PassageIndex()

    /// Die Wörter einer Stelle, als Prüfsummen mit Häufigkeit, sortiert.
    struct Terms: Sendable {
        let textLength: Int
        let textHash: Int
        let episodeID: EpisodeID
        /// Wie viele Wörter nach dem Filtern, mit Wiederholungen.
        let length: Int
        let keys: [UInt64]
        let counts: [UInt32]

        func frequency(of key: UInt64) -> Int {
            var low = 0, high = keys.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if keys[middle] == key { return Int(counts[middle]) }
                if keys[middle] < key { low = middle + 1 } else { high = middle - 1 }
            }
            return 0
        }

        func matches(_ text: String, hash: Int) -> Bool {
            textLength == text.utf8.count && textHash == hash
        }
    }

    struct Vector: Sendable {
        let textLength: Int
        let textHash: Int
        let episodeID: EpisodeID
        let values: [Double]
    }

    struct VectorKey: Hashable, Sendable {
        let id: EvidenceID
        let language: String
    }

    private let terms = Mutex<[EvidenceID: Terms]>([:])
    private let vectors = Mutex<[VectorKey: Vector]>([:])
    #if canImport(NaturalLanguage)
    /// Die Einbettungsmodelle je Sprache. Gerechnet wird unter derselben
    /// Sperre, denn ob ein Modell mehrere Aufrufe zugleich verträgt, sagt
    /// Apple nicht.
    private let embeddings = Mutex<[String: NLEmbedding]>([:])
    #endif

    /// Höchstens so viele Stellen mit Wörtern. Darüber beginnt der Speicher
    /// von vorn, wie bei den Nennungen.
    let termLimit: Int
    /// Höchstens so viele Satzeinbettungen, etwa 4 KB je Stelle.
    let vectorLimit: Int

    public init(termLimit: Int = 60_000, vectorLimit: Int = 3_000) {
        self.termLimit = termLimit
        self.vectorLimit = vectorLimit
    }

    // MARK: - Wörter

    /// Die Wörter jeder Stelle, aus dem Speicher oder neu zerlegt. Neu
    /// Zerlegtes wird auf alle Kerne verteilt.
    func terms(for evidence: [Evidence]) -> [Terms] {
        let hashes = evidence.map { Self.hash($0.quotedText) }
        var result: [Terms?] = terms.withLock { stored in
            evidence.indices.map { index in
                guard let known = stored[evidence[index].id],
                      known.matches(evidence[index].quotedText, hash: hashes[index]) else { return nil }
                return known
            }
        }
        let missing = result.indices.filter { result[$0] == nil }
        guard !missing.isEmpty else { return result.map { $0! } }

        let fresh = Self.parallelMap(missing) { index in
            Self.makeTerms(evidence[index], hash: hashes[index])
        }
        for (offset, index) in missing.enumerated() { result[index] = fresh[offset] }
        terms.withLock { stored in
            if stored.count + fresh.count > termLimit { stored.removeAll(keepingCapacity: true) }
            for (offset, index) in missing.enumerated() { stored[evidence[index].id] = fresh[offset] }
        }
        return result.map { $0! }
    }

    /// Zerlegt die Stellen im Voraus, etwa wenn der Chat aufgeht. Die erste
    /// Frage findet sie dann schon vor.
    public func prepare(_ evidence: [Evidence]) {
        _ = terms(for: evidence)
    }

    static func makeTerms(_ evidence: Evidence, hash: Int) -> Terms {
        let words = PassageRanker.terms(evidence.quotedText)
        var frequencies: [UInt64: UInt32] = [:]
        for word in words { frequencies[termKey(word), default: 0] += 1 }
        let keys = frequencies.keys.sorted()
        return Terms(textLength: evidence.quotedText.utf8.count, textHash: hash,
                     episodeID: evidence.episodeID, length: words.count,
                     keys: keys, counts: keys.map { frequencies[$0]! })
    }

    /// Eine feste Prüfsumme je Wort (FNV-1a, 64 Bit). Anders als `hashValue`
    /// ist sie in jedem Lauf gleich.
    static func termKey(_ word: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in word.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func hash(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    /// Verteilt Arbeit ohne gemeinsamen Zustand auf alle Kerne. Jeder
    /// Eintrag des Ergebnisses wird von genau einem Durchgang geschrieben.
    static func parallelMap<T: Sendable>(_ indices: [Int], _ transform: @escaping @Sendable (Int) -> T) -> [T] {
        guard indices.count > 64 else { return indices.map(transform) }
        let chunks = min(indices.count / 32, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
        let chunkSize = (indices.count + chunks - 1) / chunks
        return [T](unsafeUninitializedCapacity: indices.count) { buffer, initialized in
            let output = Output(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let start = chunk * chunkSize
                let end = min(start + chunkSize, indices.count)
                guard start < end else { return }
                for position in start..<end {
                    (output.base + position).initialize(to: transform(indices[position]))
                }
            }
            initialized = indices.count
        }
    }

    /// Der Zielspeicher für `parallelMap`. Jeder Durchgang schreibt nur
    /// seine eigenen Plätze, deshalb darf er über Threads hinweg gehen.
    private struct Output<T>: @unchecked Sendable {
        let base: UnsafeMutablePointer<T>
    }

    // MARK: - Satzeinbettungen

    #if canImport(NaturalLanguage)
    /// Ähnlichkeit jeder gewählten Stelle zur Frage, 0 für alle anderen und
    /// für Stellen ohne Vektor. `nil`, wenn es kein Einbettungsmodell gibt.
    func semanticScores(question: String, evidence: [Evidence], selection: [Int]) -> [Double]? {
        let language = Self.language(of: question)
        let hashes = selection.map { Self.hash(evidence[$0].quotedText) }
        var known: [Int: [Double]] = [:]
        var missing: [(position: Int, index: Int)] = []
        vectors.withLock { stored in
            for (position, index) in selection.enumerated() {
                let item = evidence[index]
                if let vector = stored[VectorKey(id: item.id, language: language.rawValue)],
                   vector.textLength == item.quotedText.utf8.count, vector.textHash == hashes[position] {
                    known[index] = vector.values
                } else {
                    missing.append((position, index))
                }
            }
        }

        // Das Modell rechnet unter seiner Sperre. Nur was fehlt, wird eingebettet.
        let computed: (question: [Double], fresh: [Int: [Double]])? = embeddings.withLock { models in
            guard let model = Self.model(for: language, in: &models),
                  let questionVector = model.vector(for: question) else { return nil }
            var fresh: [Int: [Double]] = [:]
            for (_, index) in missing {
                if let vector = model.vector(for: String(evidence[index].quotedText.prefix(600))) {
                    fresh[index] = vector
                }
            }
            return (questionVector, fresh)
        }
        guard let computed else { return nil }

        if !computed.fresh.isEmpty {
            vectors.withLock { stored in
                if stored.count + computed.fresh.count > vectorLimit { stored.removeAll(keepingCapacity: true) }
                for (position, index) in missing {
                    guard let values = computed.fresh[index] else { continue }
                    let item = evidence[index]
                    stored[VectorKey(id: item.id, language: language.rawValue)] = Vector(
                        textLength: item.quotedText.utf8.count, textHash: hashes[position],
                        episodeID: item.episodeID, values: values)
                }
            }
        }

        var scores = [Double](repeating: 0, count: evidence.count)
        for index in selection {
            guard let vector = known[index] ?? computed.fresh[index] else { continue }
            scores[index] = max(0, PassageRanker.cosine(computed.question, vector))
        }
        return scores
    }

    /// Die Sprache der Frage, wie bisher: erkannt, sonst Deutsch.
    static func language(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .german
    }

    /// Das Modell für die Sprache, ersatzweise das englische, einmal geladen.
    /// Der Schlüssel ist die gewünschte Sprache, damit die Vektoren im
    /// Speicher zu dem Modell passen, das sie gerechnet hat.
    private static func model(for language: NLLanguage, in models: inout [String: NLEmbedding]) -> NLEmbedding? {
        if let known = models[language.rawValue] { return known }
        guard let loaded = NLEmbedding.sentenceEmbedding(for: language)
                ?? NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        models[language.rawValue] = loaded
        return loaded
    }
    #endif

    // MARK: - Aufräumen

    /// Vergisst alles, was aus diesen Folgen entstanden ist.
    public func forget(episodes: some Sequence<EpisodeID>) {
        let gone = Set(episodes)
        guard !gone.isEmpty else { return }
        terms.withLock { stored in stored = stored.filter { !gone.contains($0.value.episodeID) } }
        vectors.withLock { stored in stored = stored.filter { !gone.contains($0.value.episodeID) } }
    }

    /// Vergisst einzelne Belege, etwa nach einer neuen Erschließung.
    public func forget(evidence ids: some Sequence<EvidenceID>) {
        let gone = Set(ids)
        guard !gone.isEmpty else { return }
        terms.withLock { stored in for id in gone { stored[id] = nil } }
        vectors.withLock { stored in stored = stored.filter { !gone.contains($0.key.id) } }
    }

    public func removeAll() {
        terms.withLock { $0.removeAll() }
        vectors.withLock { $0.removeAll() }
    }

    /// Wie viele Stellen Wörter und wie viele einen Vektor im Speicher haben.
    public var counts: (terms: Int, vectors: Int) {
        (terms.withLock { $0.count }, vectors.withLock { $0.count })
    }

    /// Die Folgen, von denen etwas im Speicher liegt. Für Tests.
    var episodeIDs: Set<EpisodeID> {
        var ids = Set(terms.withLock { $0.values.map(\.episodeID) })
        ids.formUnion(vectors.withLock { $0.values.map(\.episodeID) })
        return ids
    }
}

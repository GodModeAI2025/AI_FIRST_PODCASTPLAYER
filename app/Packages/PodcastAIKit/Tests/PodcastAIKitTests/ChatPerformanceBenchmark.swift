//
//  ChatPerformanceBenchmark.swift
//
//  Misst die Schritte des Chats, die ohne Sprachmodell laufen, an einer
//  großen erfundenen Bibliothek: 300 Folgen mit je 60 Belegen, Transkript,
//  Fakten und Shownotes. Gemessen wird, nicht geprüft. Die Zahlen stehen
//  in der Ausgabe von `swift test`.
//
//  Läuft nur auf Wunsch, denn allein das Anlegen der Bibliothek dauert:
//
//      PODCASTAI_CHAT_BENCH=1 swift test --filter ChatPerformanceBenchmark
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIIntelligence
@testable import PodcastAIKnowledge
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ChatBenchmark {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PODCASTAI_CHAT_BENCH"] == "1" }

    static let episodeCount = 300
    static let passagesPerEpisode = 60
    static let segmentsPerPassage = 4

    /// Ein fester Wortschatz, damit jede Messung dieselbe Bibliothek sieht.
    static let vocabulary: [String] = """
        Heute sprechen wir über künstliche Intelligenz Datenschutz Klimawandel Energiewende Wärmepumpe \
        Solaranlage Batterie Speicher Netzausbau Windkraft Wasserstoff Mobilität Fahrrad Bahn Verkehr \
        Stadtplanung Wohnungsbau Miete Inflation Zinsen Notenbank Haushalt Schulden Rente Pflege Gesundheit \
        Krankenhaus Medizin Forschung Studie Universität Schule Bildung Lehrer Kinder Familie Arbeit \
        Homeoffice Produktivität Software Entwicklung Programmierung Sicherheit Verschlüsselung Passwort \
        Netzwerk Cloud Rechenzentrum Chip Halbleiter Smartphone Tablet Kamera Musik Film Serie Buch Roman \
        Geschichte Politik Wahl Parlament Regierung Opposition Europa Amerika China Handel Export Import \
        Landwirtschaft Ernährung Bienen Imkerei Garten Wald Boden Wasser Meer Küste Urlaub Reise Wetter \
        Sport Fußball Training Marathon Schlaf Stress Meditation Psychologie Gesellschaft Demokratie Medien \
        Journalismus Podcast Gespräch Interview Gast Moderator Beispiel Erfahrung Meinung These Argument \
        also dann eben halt eigentlich wirklich natürlich sozusagen genau vielleicht ungefähr ziemlich \
        wir haben sie hat er sagt man kann dass weil wenn aber oder und mit bei nach für über unter zwischen \
        Federated Learning Modelle trainieren gemeinsam Krankenhäuser Daten teilen ohne zentral speichern
        """.split(separator: " ").map(String.init)

    /// Ein einfacher, fester Zufallsgenerator.
    struct Generator {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
    }

    static func sentence(_ generator: inout Generator, words: Int) -> String {
        (0..<words).map { _ in vocabulary[generator.next() % vocabulary.count] }.joined(separator: " ") + "."
    }

    struct Library {
        let store: LibraryStore
        let episodes: [Episode]
        let seedSeconds: Double
    }

    /// Legt die Bibliothek an: Quellen, Folgen mit Shownotes, Transkripte,
    /// Belege und Fakten.
    static func makeLibrary() async throws -> Library {
        let started = ContinuousClock.now
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        var generator = Generator(state: 42)
        var episodes: [Episode] = []
        let sources = (0..<10).map { SourceID(stable: "quelle-\($0)") }
        for (index, source) in sources.enumerated() {
            try await store.upsert(source: Source(id: source, kind: .podcastRSS, title: "Podcast \(index)"))
        }
        for number in 0..<episodeCount {
            let source = sources[number % sources.count]
            let audio = URL(string: "https://example.com/folge-\(number).mp3")!
            let episodeID = EpisodeID(stable: "folge-\(number)")
            let media = MediaVersionID(stable: audio.absoluteString)
            let shownotes = "<p>" + (0..<12).map { _ in sentence(&generator, words: 18) }.joined(separator: " ")
                + " Mehr unter https://example.org/folge-\(number) und am 12. März 2026 in Berlin.</p>"
            let episode = Episode(
                id: episodeID, sourceID: source, title: "Folge \(number): " + sentence(&generator, words: 5),
                publishedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(number) * 86_400),
                audioURL: audio, shownotesHTML: shownotes)
            _ = try await store.upsert(episodes: [episode], forSource: source)
            episodes.append(episode)

            let transcriptID = TranscriptID(stable: "t-\(number)")
            var segments: [TranscriptSegment] = []
            var evidence: [Evidence] = []
            for passage in 0..<passagesPerEpisode {
                var texts: [String] = []
                for part in 0..<segmentsPerPassage {
                    let start = Int64((passage * segmentsPerPassage + part) * 15_000)
                    let text = sentence(&generator, words: 38)
                    texts.append(text)
                    segments.append(TranscriptSegment(
                        id: SegmentID(stable: "s-\(number)-\(passage)-\(part)"),
                        range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                              end: MediaTime(milliseconds: start + 14_000)),
                        text: text))
                }
                let start = Int64(passage * 60_000)
                let range = MediaTimeRange(start: MediaTime(milliseconds: start),
                                           end: MediaTime(milliseconds: start + 59_000))
                evidence.append(Evidence(
                    id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
                    mediaVersionID: media, episodeID: episodeID, sourceID: source,
                    transcriptID: transcriptID, transcriptRevision: .initial, range: range,
                    quotedText: texts.joined(separator: " ")))
            }
            let transcript = Transcript(
                id: transcriptID, mediaVersionID: media, revision: .initial, origin: .speechAnalysis,
                locale: "de_DE", segments: segments,
                analyzedRanges: IntervalSet(MediaTimeRange(
                    start: .zero, end: MediaTime(milliseconds: Int64(passagesPerEpisode) * 60_000))))
            try await store.save(transcript: transcript,
                                 media: MediaVersion(id: media, episodeID: episodeID, remoteURL: audio),
                                 forEpisode: episodeID)
            try await store.insertEvidenceInBulkForTesting(evidence)
            let facts = evidence.prefix(8).enumerated().map { offset, item in
                EpisodeFact(id: "f-\(number)-\(offset)", episodeID: episodeID, sourceID: source,
                            evidenceID: item.id, mediaVersionID: media,
                            statement: sentence(&generator, words: 12), range: item.range!, modelTier: "test")
            }
            try await store.save(facts: facts, forEpisode: episodeID)
        }
        return Library(store: store, episodes: episodes, seedSeconds: seconds(since: started))
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }

    /// Misst einen Schritt und gibt Ergebnis und Millisekunden zurück.
    static func measure<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await work()
        return (value, seconds(since: start) * 1_000)
    }
}

/// Die Rangfolge, wie sie bis 0.9 bei jeder Frage lief: alle Stellen neu
/// zerlegt, das Einbettungsmodell neu geladen, jede Einbettung neu gerechnet.
/// Nur zum Vergleich in derselben Messung.
enum LegacyRanking {
    static func keywordScores(_ evidence: [Evidence], for question: String) -> [Double] {
        let terms = Set(PassageRanker.terms(question))
        let documents = evidence.map { PassageRanker.terms($0.quotedText) }
        let count = Double(documents.count)
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in Set(document) { documentFrequency[term, default: 0] += 1 }
        }
        let averageLength = max(1, Double(documents.map(\.count).reduce(0, +)) / count)
        var keywords = [Double](repeating: 0, count: evidence.count)
        for (index, document) in documents.enumerated() {
            var frequencies: [String: Int] = [:]
            for term in document { frequencies[term, default: 0] += 1 }
            var keyword = 0.0
            for term in terms {
                guard let tf = frequencies[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let norm = Double(tf) * 2.2 / (Double(tf) + 1.2 * (0.25 + 0.75 * Double(document.count) / averageLength))
                keyword += idf * norm
            }
            keywords[index] = keyword
        }
        return keywords
    }

    #if canImport(NaturalLanguage)
    static func semanticScores(_ evidence: [Evidence], for question: String, selection: [Int]) -> [Double] {
        var semantics = [Double](repeating: 0, count: evidence.count)
        let embedding = PassageRanker.embedding(for: question)
        if let embedding, let questionVector = embedding.vector(for: question) {
            for index in selection {
                guard let vector = embedding.vector(for: String(evidence[index].quotedText.prefix(600)))
                else { continue }
                semantics[index] = max(0, PassageRanker.cosine(questionVector, vector))
            }
        }
        return semantics
    }
    #endif
}

@Suite("Chat-Leistung, gemessen", .enabled(if: ChatBenchmark.isEnabled), .serialized)
struct ChatPerformanceBenchmark {

    static let questions = [
        "Wie trainieren Krankenhäuser gemeinsam Modelle, ohne Daten zu teilen?",
        "Was wurde über Wärmepumpen und die Energiewende gesagt?",
    ]

    /// Eine Zeile der Tabelle: vorher, nachher bei der ersten Frage (nichts
    /// gemerkt) und nachher bei einer weiteren Frage.
    struct Row {
        var before: [Double] = []
        var cold: [Double] = []
        var warm: [Double] = []
    }

    static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        return String(format: "%.1f", sorted[sorted.count / 2])
    }

    @Test("Schritte ohne Modell an 300 Folgen mit je 60 Belegen, vorher und nachher")
    func stages() async throws {
        let library = try await ChatBenchmark.makeLibrary()
        let store = library.store
        let question = Self.questions[0]
        let other = Self.questions[1]
        let podcast = library.episodes.filter { $0.sourceID == SourceID(stable: "quelle-3") }.map(\.id)
        let newest = Array(library.episodes.suffix(5))
        let scan = Array(library.episodes.suffix(40))
        var rows: [String: Row] = [:]
        var order: [String] = []
        func add(_ name: String, _ keyPath: WritableKeyPath<Row, [Double]>, _ ms: Double) {
            if rows[name] == nil { rows[name] = Row(); order.append(name) }
            rows[name]![keyPath: keyPath].append(ms)
        }

        #if canImport(NaturalLanguage)
        let embeddingAvailable = NLEmbedding.sentenceEmbedding(for: .german) != nil
        #else
        let embeddingAvailable = false
        #endif

        for _ in 0..<3 {
            // Vorher: jede Frage liest und rechnet alles neu.
            await store.forgetCachedEvidence()
            let (pool, fetchBefore) = try await ChatBenchmark.measure {
                try await store.evidenceForAnalyzedEpisodes(limit: 20_000)
            }
            add("Belege holen (18.000)", \.before, fetchBefore)
            let (_, scopedBefore) = try await ChatBenchmark.measure {
                var all: [Evidence] = []
                for id in podcast { all += try await store.evidence(forEpisode: id) }
                return all.filter { $0.range != nil }
            }
            add("Belege eines Podcasts (1.800)", \.before, scopedBefore)
            let (legacyKeywords, keywordBefore) = await ChatBenchmark.measure {
                LegacyRanking.keywordScores(pool, for: question)
            }
            add("Rangfolge Stichworte", \.before, keywordBefore)
            let selection = PassageRanker.embeddingSelection(keywords: legacyKeywords, limit: 64)
            #if canImport(NaturalLanguage)
            let (legacySemantics, embedBefore) = await ChatBenchmark.measure {
                LegacyRanking.semanticScores(pool, for: question, selection: selection)
            }
            add("Rangfolge 64 Einbettungen", \.before, embedBefore)
            #endif
            let (_, fiveBefore) = try await ChatBenchmark.measure {
                for episode in newest { _ = try await store.transcript(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 5 Folgen", \.before, fiveBefore)
            let (_, fortyBefore) = try await ChatBenchmark.measure {
                for episode in scan { _ = try await store.transcript(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 40 Folgen", \.before, fortyBefore)

            // Nachher, erste Frage: nichts gemerkt.
            await store.forgetCachedEvidence()
            let index = PassageIndex()
            let ranker = PassageRanker(index: index)
            // Eine neue Abfrage liefert die Zeilen nicht unbedingt in derselben
            // Reihenfolge. Verglichen wird deshalb an `pool`.
            let (_, fetchCold) = try await ChatBenchmark.measure {
                try await store.evidenceForAnalyzedEpisodes(limit: 20_000)
            }
            add("Belege holen (18.000)", \.cold, fetchCold)
            let (scoped, scopedCold) = try await ChatBenchmark.measure {
                try await store.timedEvidence(forEpisodes: podcast)
            }
            add("Belege eines Podcasts (1.800)", \.cold, scopedCold)
            #expect(scoped.count == podcast.count * ChatBenchmark.passagesPerEpisode)
            let (keywords, keywordCold) = await ChatBenchmark.measure {
                ranker.keywordScores(pool, for: question)
            }
            add("Rangfolge Stichworte", \.cold, keywordCold)
            let keywordGap = zip(keywords, legacyKeywords).map { abs($0 - $1) }.max() ?? 0
            let differing = zip(keywords, legacyKeywords).filter { $0 != $1 }.count
            #expect(keywordGap < 1e-9, "Abweichung \(keywordGap) an \(differing) Stellen")
            #if canImport(NaturalLanguage)
            let (semantics, embedCold) = await ChatBenchmark.measure {
                index.semanticScores(question: question, evidence: pool, selection: selection)
            }
            add("Rangfolge 64 Einbettungen", \.cold, embedCold)
            #expect(semantics == legacySemantics)
            #endif
            let (_, fiveCold) = try await ChatBenchmark.measure {
                for episode in newest { _ = try await store.transcriptFingerprint(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 5 Folgen", \.cold, fiveCold)
            let (_, fortyCold) = try await ChatBenchmark.measure {
                for episode in scan { _ = try await store.transcriptFingerprint(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 40 Folgen", \.cold, fortyCold)

            // Nachher, weitere Frage: Belege, Wörter und Modell sind gemerkt,
            // Einbettungen nur dort, wo dieselben Stellen wiederkommen.
            let (warmPool, fetchWarm) = try await ChatBenchmark.measure {
                try await store.evidenceForAnalyzedEpisodes(limit: 20_000)
            }
            add("Belege holen (18.000)", \.warm, fetchWarm)
            let (_, scopedWarm) = try await ChatBenchmark.measure {
                try await store.timedEvidence(forEpisodes: podcast)
            }
            add("Belege eines Podcasts (1.800)", \.warm, scopedWarm)
            let (otherKeywords, keywordWarm) = await ChatBenchmark.measure {
                ranker.keywordScores(warmPool, for: other)
            }
            add("Rangfolge Stichworte", \.warm, keywordWarm)
            #expect(otherKeywords == LegacyRanking.keywordScores(warmPool, for: other))
            #if canImport(NaturalLanguage)
            let otherSelection = PassageRanker.embeddingSelection(keywords: otherKeywords, limit: 64)
            let (_, embedOther) = await ChatBenchmark.measure {
                index.semanticScores(question: other, evidence: warmPool, selection: otherSelection)
            }
            add("Rangfolge 64 Einbettungen", \.warm, embedOther)
            let (_, embedSame) = await ChatBenchmark.measure {
                index.semanticScores(question: question, evidence: warmPool, selection: selection)
            }
            add("Rangfolge 64 Einbettungen, dieselben Stellen", \.warm, embedSame)
            #endif
            let (_, fiveWarm) = try await ChatBenchmark.measure {
                for episode in newest { _ = try await store.transcriptFingerprint(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 5 Folgen", \.warm, fiveWarm)
            let (_, fortyWarm) = try await ChatBenchmark.measure {
                for episode in scan { _ = try await store.transcriptFingerprint(forEpisode: episode.id) }
            }
            add("Schlüssel Nennungen, 40 Folgen", \.warm, fortyWarm)

            let ranked = ranker.rank(warmPool, for: question, limit: 60, embeddingLimit: 64)
            let (_, promptMs) = await ChatBenchmark.measure {
                let config = ExtractorConfiguration(
                    candidateBuilder: CandidateListBuilder(excerptLimit: 900, maximumCandidates: 60))
                let context = String(repeating: "Podcast: Beispiel, Folge, Transkript fertig\n", count: 120)
                _ = config.answerRequest(question: question, evidence: ranked,
                                         libraryContext: context, tier: .privateCloudCompute)
                _ = config.answerRequest(question: question, evidence: ranked,
                                         libraryContext: context, tier: .onDevice)
            }
            add("Prompt bauen (beide Stufen)", \.warm, promptMs)
        }

        #if canImport(FoundationModels)
        if SystemLanguageModel.default.isAvailable {
            let pool = try await store.evidenceForAnalyzedEpisodes(limit: 20_000)
            let sample = ChatBenchmark.evenlySpaced(pool, count: AnswerTokenPlan.sampleSize)
            let context = String(repeating: "Podcast: Beispiel, Folge, Transkript fertig\n", count: 60)
            let budget = ContextBudget(maximumCandidates: 40, excerptLimit: 420, libraryContextLimit: 3_000)
            let model = SystemLanguageModel.default
            let builder = CandidateListBuilder(excerptLimit: 420, maximumCandidates: 40)
            let block = builder.promptBlock(for: builder.build(from: sample), usage: .referenceNumbers)
            let instructions = KnowledgeExtractor().answerInstructions()
            for round in 0..<4 {
                // Vorher: Schema, Rahmen und Probe, jedes Mal gezählt. Die
                // erste Runde lädt den Tokenizer und zählt nicht mit.
                let question = Self.questions[round % 2]
                let (_, before) = await ChatBenchmark.measure {
                    _ = try? await model.tokenCount(for: AnswerOutput.generationSchema)
                    _ = try? await model.tokenCount(for: instructions + "\n\n" + question + context)
                    _ = try? await model.tokenCount(for: block)
                }
                if round > 0 { add("Token zählen (Gerät)", \.before, before) }
                let (_, after) = await ChatBenchmark.measure {
                    _ = await KnowledgeExtractor().fittedAnswerBudget(
                        budget, tier: .onDevice, question: question, sample: sample, libraryContext: context)
                }
                if round > 0 { add("Token zählen (Gerät)", \.warm, after) }
            }
        }
        #endif

        var report = "\nChat-Messung, Anlegen der Bibliothek \(Int(library.seedSeconds)) s, "
        report += "Einbettungen \(embeddingAvailable ? "verfügbar" : "NICHT verfügbar"), Median aus 3 Läufen in ms\n"
        report += "Schritt".padding(toLength: 46, withPad: " ", startingAt: 0) + "   vorher   1. Frage   weitere\n"
        for name in order {
            let row = rows[name]!
            report += name.padding(toLength: 46, withPad: " ", startingAt: 0)
                + Self.median(row.before).leftPadded(9) + Self.median(row.cold).leftPadded(11)
                + Self.median(row.warm).leftPadded(10) + "\n"
        }
        print(report)
    }
}

extension String {
    fileprivate func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}


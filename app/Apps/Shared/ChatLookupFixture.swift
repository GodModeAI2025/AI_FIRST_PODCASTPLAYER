//
//  ChatLookupFixture.swift
//  PodcastAI
//
//  Das Nachschlagen im Chat für UI-Tests, ohne Apple Intelligence. Der
//  Simulator hat meist kein Sprachmodell; ohne diesen Ersatz ließe sich der
//  Weg über die Werkzeuge dort nie sehen.
//
//  Nur in Debug-Builds und nur mit dem Startargument `-uitest-chat-lookup`,
//  zusammen mit `-demo-content`. Ersetzt wird allein das Modell: Buch,
//  Quelle, Prüfung der Kennungen, Nummern und die Zuordnung der Belege sind
//  dieselben wie bei einer echten Antwort. Die Quelle antwortet etwas
//  verzögert, damit die Anzeige „Sucht weitere Stellen …“ zu sehen ist.
//

#if DEBUG
import Foundation
import PodcastAIKit

enum ChatLookupFixture {

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-chat-lookup") }

    /// So lange braucht jede Abfrage.
    static let delay = Duration.seconds(2)

    /// Reicht jede Abfrage an die echte Quelle weiter, nach einer Pause.
    struct Slowed: ChatLookupSource {
        let base: any ChatLookupSource

        var episodes: Set<EpisodeID> { base.episodes }

        func title(of episode: EpisodeID) async -> String? { await base.title(of: episode) }

        func available(_ episodes: Set<EpisodeID>) async -> Set<EpisodeID> { await base.available(episodes) }

        func passages(matching query: String, in episode: EpisodeID?, within range: MediaTimeRange?,
                      excluding known: Set<EvidenceID>, limit: Int) async -> [Evidence] {
            try? await Task.sleep(for: ChatLookupFixture.delay)
            return await base.passages(matching: query, in: episode, within: range, excluding: known, limit: limit)
        }

        func facts(of episode: EpisodeID) async -> [ChatLookupFact] {
            try? await Task.sleep(for: ChatLookupFixture.delay)
            return await base.facts(of: episode)
        }

        func mentions(of episode: EpisodeID) async -> [ChatLookupMention] {
            try? await Task.sleep(for: ChatLookupFixture.delay)
            return await base.mentions(of: episode)
        }

        func chapters(of episode: EpisodeID) async -> [ChatLookupChapter] {
            try? await Task.sleep(for: ChatLookupFixture.delay)
            return await base.chapters(of: episode)
        }
    }

    /// Spielt das Modell: Es sieht nur die ersten zwei Abschnitte, holt sich
    /// mit der Frage als Suchbegriff weitere Stellen und verweist auf die
    /// erste, die das Werkzeug geliefert hat. Der Text steht für eine
    /// Modellantwort und ist deshalb nicht übersetzt.
    static func answer(question: String, candidates: [Evidence], budget: ContextBudget,
                       lookup: ChatLookupLedger) async throws -> ComposedAnswer {
        let listed = CandidateListBuilder(excerptLimit: budget.excerptLimit, maximumCandidates: 2)
            .build(from: candidates)
        lookup.begin(initial: listed, tier: .onDevice)
        let result = try await lookup.perform(.passages(query: question, episode: nil, chapter: nil))
        let fetched = result.split(separator: "\n").compactMap { line in
            line.prefixMatch(of: /\[(\d+)\]/).flatMap { Int($0.output.1) }
        }
        let text = fetched.first.map { "Nachgeschlagen: Eine weitere Stelle sagt dazu mehr [\($0)]." }
            ?? "Nachgeschlagen, aber keine weitere Stelle gefunden. Das steht schon hier [1]."
        return KnowledgeExtractor.scriptedAnswer(text, candidates: listed, lookup: lookup)
    }
}
#endif

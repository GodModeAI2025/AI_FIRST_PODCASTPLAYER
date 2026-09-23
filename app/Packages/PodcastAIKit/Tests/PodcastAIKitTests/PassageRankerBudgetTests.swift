//
//  PassageRankerBudgetTests.swift
//  PodcastAIKitTests
//
//  Bei großen Beständen bekommen nur wenige Stellen eine Einbettung.
//  Die Auswahl muss die Stichworttreffer enthalten und darf die Grenze
//  nicht überschreiten.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIKnowledge

@Suite("Einbettungen mit Grenze")
struct PassageRankerBudgetTests {

    @Test("Ohne Grenze wird jede Stelle eingebettet")
    func withoutLimitEverything() {
        let selection = PassageRanker.embeddingSelection(keywords: [0, 1, 0, 2], limit: nil)
        #expect(selection == [0, 1, 2, 3])
    }

    @Test("Mit Grenze kommen die besten Stichworttreffer zuerst")
    func bestKeywordHitsFirst() {
        let keywords: [Double] = [0, 0.5, 0, 3, 0, 1, 0, 0, 0, 0]
        let selection = PassageRanker.embeddingSelection(keywords: keywords, limit: 2)
        #expect(selection == [3, 5])
    }

    @Test("Fehlende Plätze füllen verteilte Stellen ohne Treffer auf")
    func fillsWithSpreadPassages() {
        let keywords: [Double] = [0, 0, 0, 2, 0, 0, 0, 0, 0, 0]
        let selection = PassageRanker.embeddingSelection(keywords: keywords, limit: 4)
        #expect(selection.count == 4)
        #expect(selection.first == 3)
        #expect(Set(selection).count == 4)
        #expect(selection.contains(0))
    }

    @Test("Die Grenze gilt auch für die Rangfolge")
    func rankingStillWorksWithLimit() {
        let pool = (0..<30).map { index in
            Evidence(id: EvidenceID(stable: "p\(index)"), mediaVersionID: MediaVersionID(stable: "m"),
                     episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "s"),
                     transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                     range: MediaTimeRange(start: MediaTime(milliseconds: Int64(index) * 1000),
                                           end: MediaTime(milliseconds: Int64(index) * 1000 + 900)),
                     quotedText: index == 17
                        ? "Federated Learning erlaubt Krankenhäusern, Modelle gemeinsam zu trainieren."
                        : "Heute sprechen wir über das Wetter und den Urlaub am Meer, Teil \(index).")
        }
        let ranked = PassageRanker().rank(pool, for: "Wie trainieren Krankenhäuser gemeinsam Modelle?",
                                          limit: 3, embeddingLimit: 5)
        #expect(ranked.first?.id == EvidenceID(stable: "p17"))
    }
}

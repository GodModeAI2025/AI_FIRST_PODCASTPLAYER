//
//  EpisodeArchiveTests.swift
//
//  Ältere Folgen: die Liste endet nicht mehr bei 200, die Suche findet
//  Wörter in Titel und Shownotes, Filter und Reihenfolge tun, was sie
//  sagen, und die Kopfzeile nennt beide Zahlen.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIKnowledge
@testable import PodcastAIPersistence

@Suite("Ältere Folgen finden und auswählen")
struct EpisodeArchiveTests {

    let sourceID = SourceID(stable: "quelle-archiv")
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func episode(_ index: Int, title: String? = nil, notes: String? = nil,
                 daysAgo: Double? = nil, minutes: Int? = nil) -> Episode {
        Episode(id: EpisodeID(stable: "archiv-\(index)"), sourceID: sourceID,
                title: title ?? "Folge \(index)",
                publishedAt: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
                declaredDuration: minutes.map { MediaDuration(minutes: $0) },
                shownotesHTML: notes)
    }

    // MARK: Speicher

    @Test("Ohne Grenze liefert die Quelle alle Folgen, neueste zuerst")
    func storeReturnsMoreThanTwoHundred() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Archiv"))
        let list = (0..<412).map { episode($0, daysAgo: Double($0)) }
        _ = try await store.upsert(episodes: list, forSource: sourceID)

        let all = try await store.episodes(forSource: sourceID)
        #expect(all.count == 412)
        #expect(all.first?.id == list.first?.id)
        #expect(all.last?.id == list.last?.id)
        #expect(try await store.episodes(forSource: sourceID, limit: 5).map(\.id) == list.prefix(5).map(\.id))
    }

    @Test("Auch ohne Grenze bleibt eine gelöschte Folge weg")
    func storeSkipsRemovedWithoutLimit() async throws {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Archiv"))
        let list = (0..<3).map { episode($0, daysAgo: Double($0)) }
        _ = try await store.upsert(episodes: list, forSource: sourceID)
        _ = try await store.removeEpisode(list[1].id)

        #expect(try await store.episodes(forSource: sourceID).map(\.id) == [list[0].id, list[2].id])
    }

    // MARK: Suche

    @Test("Die Suche findet Wörter in Shownotes, nicht in HTML-Tags")
    func searchReadsShownotesWithoutMarkup() {
        let item = episode(1, title: "Über die Wahl",
                           notes: "<p>Wir sprechen mit <a href=\"https://example.com/strong\">Anna</a> "
                               + "&amp; Ben über Klimapolitik.</p>")
        let text = EpisodeArchive.searchableText(of: item)

        #expect(EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "klima")))
        #expect(EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "uber wahl")))
        #expect(EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "ANNA ben")))
        #expect(EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "anna & ben")))
        #expect(!EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "href")))
        #expect(!EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "example")))
        #expect(!EpisodeArchive.matches(text, terms: EpisodeArchive.terms(of: "klima rente")))
    }

    @Test("Zahlenentitäten werden aufgelöst")
    func numericEntities() {
        #expect(EpisodeArchive.plainText("Caf&#233; &#x2013; M&uuml;nchen &amp;lt;") == "Café – München &lt;")
        #expect(EpisodeArchive.plainText("Kein Ende &#") == "Kein Ende &#")
    }

    @Test("Leere Suche heisst: keine Einschränkung")
    func emptyQueryMatchesEverything() {
        let index = [episode(1), episode(2)].map { (id: $0.id, text: EpisodeArchive.searchableText(of: $0)) }
        #expect(EpisodeArchive.matchingIDs(for: EpisodeArchive.terms(of: "   "), in: index) == nil)
        #expect(EpisodeArchive.matchingIDs(for: EpisodeArchive.terms(of: "folge 2"), in: index) == [episode(2).id])
    }

    // MARK: Filter und Reihenfolge

    @Test("Älteste zuerst, Folgen ohne Datum am Ende")
    func oldestFirstKeepsUndatedLast() {
        let list = [episode(1, daysAgo: 1), episode(2, daysAgo: 30), episode(3), episode(4, daysAgo: 400)]
        let arranged = EpisodeArchive.arrange(
            list, options: .init(oldestFirst: true), analyzed: [], matches: nil)
        #expect(arranged.map(\.id) == [episode(4).id, episode(2).id, episode(1).id, episode(3).id])
    }

    @Test("Nur nicht ausgewertete, zusammen mit der Suche")
    func filterAndSearchCombine() {
        let list = [episode(1, daysAgo: 1), episode(2, daysAgo: 2), episode(3, daysAgo: 3)]
        let arranged = EpisodeArchive.arrange(
            list, options: .init(onlyUnanalyzed: true),
            analyzed: [episode(1).id], matches: [episode(1).id, episode(3).id])
        #expect(arranged.map(\.id) == [episode(3).id])
    }

    // MARK: Kopfzeile

    @Test("Die Kopfzeile nennt beide Zahlen und was automatisch passiert")
    func coverageLine() {
        #expect(EpisodeArchive.coverage(total: 412, analyzed: 3, analyzable: true, automatic: .newest(3))
                == "3 von 412 Folgen ausgewertet, automatisch die 3 neuesten")
        #expect(EpisodeArchive.coverage(total: 1, analyzed: 0, analyzable: true, automatic: .newest(1))
                == "0 von 1 Folge ausgewertet, automatisch die neueste")
        #expect(EpisodeArchive.coverage(total: 20, analyzed: 2, analyzable: true, automatic: .off)
                == "2 von 20 Folgen ausgewertet, automatisches Auswerten ist aus")
        #expect(EpisodeArchive.coverage(total: 20, analyzed: 2, analyzable: true, automatic: .paused)
                == "2 von 20 Folgen ausgewertet, automatisch gerade keine")
        #expect(EpisodeArchive.coverage(total: 15, analyzed: 0, analyzable: false, automatic: .newest(3))
                == "15 Folgen, keine davon auswertbar")
    }

    @Test("Die Auswahl nennt Anzahl und Länge")
    func selectionLine() {
        #expect(EpisodeArchive.selectionSummary([episode(1, minutes: 60), episode(2, minutes: 100)])
                == "2 Folgen ausgewählt, zusammen 2 Std 40 Min Ton")
        #expect(EpisodeArchive.selectionSummary([episode(1, minutes: 45), episode(2)])
                == "2 Folgen ausgewählt, zusammen mindestens 45 Min Ton")
        #expect(EpisodeArchive.selectionSummary([episode(1)]) == "1 Folge ausgewählt")
    }
}

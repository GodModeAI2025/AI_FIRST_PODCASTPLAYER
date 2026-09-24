//
//  EditionCoverTests.swift
//  PodcastAIKitTests
//
//  Cover je Ausgabe (0.11): Rezept aus Tags und Namen, Ablage neben dem
//  Cover des Updates, Aufräumen, die häufigsten Namen und „Teil 2 von 3“.
//

import Testing
import Foundation
import CoreGraphics
@testable import PodcastAIKit

@Suite("Cover je Ausgabe")
struct EditionCoverTests {

    private let feed = SmartPodcastFeed(id: SmartFeedID(rawValue: "feed-1"), title: "Datenschutz", topicIDs: [])

    private func range(_ start: Int64, _ end: Int64) -> MediaTimeRange {
        MediaTimeRange(start: MediaTime(milliseconds: start), end: MediaTime(milliseconds: end))
    }

    private func edition(_ name: String, part: Int = 1, runKey: String = "run",
                         segments: [(episode: String, start: Int64, end: Int64)] = [("ep", 0, 60_000)])
        -> PersonalEpisode {
        var cursor: Int64 = 0
        let built = segments.enumerated().map { index, item in
            let length = item.end - item.start
            defer { cursor += length }
            return PersonalEpisodeSegment(
                id: SegmentID(rawValue: "\(name)-\(index)"), episodeID: EpisodeID(rawValue: item.episode),
                mediaVersionID: MediaVersionID(rawValue: "m-\(item.episode)"), transcriptRevision: .initial,
                evidenceIDs: [], coreRange: range(item.start, item.end), playbackRange: range(item.start, item.end),
                virtualRange: range(cursor, cursor + length), reason: "", topicIDs: [], contextReplay: false,
                sourceID: SourceID(rawValue: "s"), sourceTitle: "Quelle", episodeTitle: "Folge")
        }
        return PersonalEpisode(
            id: PersonalEpisodeID(rawValue: name), feedID: feed.id, policyRevision: .initial,
            batchKey: name, title: name, segments: built, shownotes: [],
            coverage: EditionCoverage(candidateCount: 1, includedCount: 1, remaining: .zero,
                                      partiallyAnalyzedSourceIDs: []),
            part: part, runKey: runKey)
    }

    private func name(_ display: String, _ kind: Mention.Kind = .person, at seconds: [Int64],
                      shownotes: Bool = false) -> Mention {
        var occurrences = seconds.map {
            Mention.Occurrence(origin: .transcript, time: MediaTime(milliseconds: $0 * 1_000), context: display)
        }
        if shownotes { occurrences.append(Mention.Occurrence(origin: .shownotes, time: nil, context: display)) }
        return Mention(kind: kind, normalized: display.lowercased(), display: display, occurrences: occurrences)
    }

    // MARK: Rezept

    @Test("Eine Ausgabe nimmt höchstens drei Tags und zwei Namen, ein Name als Tag zählt nicht doppelt")
    func editionRecipe() {
        let recipe = TopicCoverRecipe(
            edition: edition("a"), feed: feed, topics: ["Datenschutz", "USA", "KI", "Recht"],
            names: ["usa", "Max Schrems", "Meta", "Apple"], languageCode: "de")
        #expect(recipe.concepts == ["Datenschutz", "USA", "KI"])
        #expect(recipe.names == ["Max Schrems", "Meta"])
        #expect(recipe.editionID == PersonalEpisodeID(rawValue: "a"))
        // Erst mit Namen, dann ohne, zuletzt neutral.
        #expect(recipe.attempts.count == 3)
        #expect(recipe.attempts[0] == recipe.concepts + recipe.names + [recipe.abstractConcept])
        #expect(recipe.attempts[1] == recipe.concepts + [recipe.abstractConcept])
        #expect(recipe.attempts[2] == [TopicCoverRecipe.neutralConcept])
    }

    @Test("Ohne Namen bleibt es bei zwei Versuchen, das Update-Cover ist unverändert")
    func recipeWithoutNames() {
        let recipe = TopicCoverRecipe(edition: edition("a"), feed: feed, topics: [], names: [])
        #expect(recipe.concepts == ["Datenschutz"])
        #expect(recipe.attempts.count == 2)
        let feedRecipe = TopicCoverRecipe(feed: feed, topics: ["Datenschutz"])
        #expect(feedRecipe.editionID == nil && feedRecipe.names.isEmpty)
    }

    // MARK: Ablage

    @Test("Update und Ausgaben haben je ein Bild, ohne sich gegenseitig zu löschen")
    func storeSeparatesFeedAndEditions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edition-covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TopicCoverStore(directory: directory)
        let image = try #require(Self.image())
        let first = edition("a"), second = edition("b")
        let feedRecipe = TopicCoverRecipe(feed: feed, topics: ["Datenschutz"])
        let firstRecipe = TopicCoverRecipe(edition: first, feed: feed, topics: ["Datenschutz"], names: ["Meta"])
        let secondRecipe = TopicCoverRecipe(edition: second, feed: feed, topics: ["Datenschutz"], names: [])

        try store.write(image, for: feedRecipe)
        try store.write(image, for: firstRecipe)
        try store.write(image, for: secondRecipe)
        #expect(store.stored(for: feed.id)?.editionID == nil)
        #expect(store.stored(for: feed.id)?.matches(feedRecipe) == true)
        #expect(store.stored(for: firstRecipe.key)?.matches(firstRecipe) == true)
        // Eine Ausgabe ändert sich nicht: andere Namen machen ihr Bild nicht alt.
        let renamed = TopicCoverRecipe(edition: first, feed: feed, topics: ["Datenschutz"], names: ["Apple"])
        #expect(store.stored(for: firstRecipe.key)?.matches(renamed) == true)
        #expect(store.stored(for: firstRecipe.key)?.matches(secondRecipe) == false)

        // Neue Tags am Update ersetzen nur sein Bild.
        try store.write(image, for: TopicCoverRecipe(feed: feed, topics: ["Datenschutz", "USA"]))
        #expect(store.stored(for: firstRecipe.key) != nil)
        #expect(store.stored(for: secondRecipe.key) != nil)
        // Ein neues Bild einer Ausgabe ersetzt nur ihr altes.
        try store.write(image, for: renamed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)

        // Eine verschwundene Ausgabe nimmt ihr Bild mit, das Update behält seins.
        store.removeEditionCovers(except: [secondRecipe.key])
        #expect(store.stored(for: firstRecipe.key) == nil)
        #expect(store.stored(for: secondRecipe.key) != nil)
        #expect(store.stored(for: feed.id) != nil)

        store.remove(secondRecipe.key)
        #expect(store.stored(for: secondRecipe.key) == nil)
        #expect(store.stored(for: feed.id) != nil)
    }

    @Test("Ein gelöschtes Update nimmt die Bilder seiner Ausgaben mit")
    func feedRemovalTakesEditionCovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edition-covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TopicCoverStore(directory: directory)
        let image = try #require(Self.image())
        let other = SmartPodcastFeed(id: SmartFeedID(rawValue: "feed-2"), title: "Anderes", topicIDs: [])
        let recipe = TopicCoverRecipe(edition: edition("a"), feed: feed, topics: ["Datenschutz"], names: [])
        let kept = TopicCoverRecipe(feed: other, topics: ["Musik"])
        try store.write(image, for: recipe)
        try store.write(image, for: kept)

        store.removeAll(except: [other.id])
        #expect(store.stored(for: recipe.key) == nil)
        #expect(store.stored(for: other.id) != nil)

        try store.write(image, for: recipe)
        store.remove(feed.id)
        #expect(store.stored(for: recipe.key) == nil)
        #expect(store.stored(for: other.id) != nil)
    }

    // MARK: Namen

    @Test("Es zählen Namen im gespielten Teil des Transkripts, nicht in den Shownotes")
    func namesFromPlayedRanges() {
        let item = edition("a", segments: [("ep1", 0, 60_000), ("ep2", 120_000, 180_000)])
        let mentions: [EpisodeID: [Mention]] = [
            EpisodeID(rawValue: "ep1"): [
                name("Meta", .organization, at: [10, 20, 30]),
                name("Max Schrems", at: [5, 90, 100], shownotes: true),
                name("Irland", .place, at: [200, 300]),
            ],
            EpisodeID(rawValue: "ep2"): [
                name("Max Schrems", at: [130]),
                name("Datenschutz", .organization, at: [121, 122, 123, 124]),
                Mention(kind: .link, normalized: "example.org", display: "example.org",
                        occurrences: [.init(origin: .transcript, time: MediaTime(milliseconds: 125_000),
                                            context: "")]),
            ],
            EpisodeID(rawValue: "nicht-dabei"): [name("Apple", .organization, at: [1, 2, 3, 4, 5])],
        ]
        let names = EditionCoverNames.mostFrequent(in: item, mentions: mentions, excluding: ["datenschutz"])
        // Meta 3, Max Schrems 2 (5 s und 130 s), Irland liegt außerhalb.
        #expect(names == ["Meta", "Max Schrems"])
    }

    // MARK: Teile

    @Test("„Teil 2 von 3“ zählt den Lauf, auch wenn ein Teil gelöscht ist")
    func partCount() {
        let parts = [edition("a", part: 1), edition("b", part: 2), edition("c", part: 3)]
        let other = edition("x", part: 1, runKey: "anderer")
        #expect(parts[1].partCount(in: parts + [other]) == 3)
        #expect(other.partCount(in: parts + [other]) == 1)
        #expect(parts[2].partCount(in: [parts[0], parts[2]]) == 3)
    }

    private static func image() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }
}

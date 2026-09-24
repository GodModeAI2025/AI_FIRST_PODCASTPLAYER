//
//  TagInterfaceTests.swift
//
//  Was die Oberfläche der Tags aus 0.10 braucht: Auswahl über Kapitel-Tags
//  mit Stichworten als Rückfall, Zusammenlegen von der Tag-Seite und die
//  Zahl der Kapitel je Tag.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence
@testable import PodcastAIKnowledge
@testable import PodcastAISmartFeeds

@Suite("Tags: Auswahl über Kapitel")
struct ChapterTagRelevanceTests {

    let media = MediaVersionID(stable: "fassung")
    let otherMedia = MediaVersionID(stable: "andere fassung")
    let tagged = EpisodeID(stable: "eingeordnet")
    let untagged = EpisodeID(stable: "ohne tags")
    let source = SourceID(stable: "quelle")

    func evidence(_ name: String, episode: EpisodeID, media: MediaVersionID, startMs: Int64, text: String) -> Evidence {
        let range = MediaTimeRange(start: MediaTime(milliseconds: startMs), end: MediaTime(milliseconds: startMs + 30_000))
        return Evidence(
            id: EvidenceID(stable: name), mediaVersionID: media, episodeID: episode, sourceID: source,
            transcriptID: TranscriptID(stable: "t-\(name)"), transcriptRevision: .initial, range: range,
            quotedText: text)
    }

    func chapterTag(_ interest: Interest, startMs: Int, endMs: Int) -> ChapterTag {
        ChapterTag(
            episodeID: tagged, mediaVersionID: media, chapterStartMs: startMs, chapterEndMs: endMs,
            interestID: interest.id, normalizedKey: interest.normalizedKey, confidence: 0.9,
            matchedKnown: true, sourceID: source, publishedAt: nil, transcriptRevision: .initial)
    }

    @Test("Folgen mit Kapitel-Tags wählen über Kapitel, andere über Stichworte")
    func chaptersFirstKeywordsAsFallback() {
        let followed = Interest(label: "Datenschutz", normalizedKey: "datenschutz")
        let neutral = Interest(label: "Robotik", origin: .detected, stance: .neutral, normalizedKey: "robotik")
        let profile = InterestProfile(interests: [followed, neutral])

        let inChapter = evidence("im kapitel", episode: tagged, media: media, startMs: 100_000,
                                 text: "Hier geht es um etwas ganz anderes.")
        let outside = evidence("außerhalb", episode: tagged, media: media, startMs: 400_000,
                               text: "Datenschutz ist wichtig.")
        let wrongMedia = evidence("andere fassung", episode: tagged, media: otherMedia, startMs: 100_000,
                                  text: "Kein Wort dazu.")
        let neutralChapter = evidence("neutral", episode: tagged, media: media, startMs: 700_000,
                                      text: "Roboter bauen.")
        let fallback = evidence("ohne tags", episode: untagged, media: otherMedia, startMs: 0,
                                text: "Der Datenschutz im Verein.")

        let matches = ChapterTagRelevance.matches(
            evidence: [inChapter, outside, wrongMedia, neutralChapter, fallback],
            chapterTags: [chapterTag(followed, startMs: 90_000, endMs: 300_000),
                          chapterTag(neutral, startMs: 600_000, endMs: 900_000)],
            profile: profile)

        let ids = Set(matches.map(\.evidenceID))
        // Im Kapitel mit gefolgtem Tag, auch ohne das Wort.
        #expect(ids.contains(inChapter.id))
        // Die Folge ist eingeordnet: Stichworte zählen hier nicht mehr.
        #expect(!ids.contains(outside.id))
        #expect(!ids.contains(wrongMedia.id))
        // Minus: ein neutrales Tag wählt nichts aus.
        #expect(!ids.contains(neutralChapter.id))
        // Ohne Kapitel-Tag der Rückfall über das Wort.
        #expect(ids.contains(fallback.id))
        #expect(matches.first { $0.evidenceID == inChapter.id }?.isModelConfirmed == true)
        #expect(matches.first { $0.evidenceID == fallback.id }?.isModelConfirmed == false)
    }

    @Test("Kapitel-Tags liegen in einem Abschnitt, wenn ihr Anfang darin liegt")
    func tagsInSection() {
        let interest = Interest(label: "KI", normalizedKey: "ki")
        let tags = [chapterTag(interest, startMs: 0, endMs: 60_000),
                    chapterTag(interest, startMs: 61_000, endMs: 120_000)]
        let section = MediaTimeRange(start: MediaTime(milliseconds: 60_000), end: MediaTime(milliseconds: 180_000))
        #expect(ChapterTagRelevance.tags(tags, in: section).map(\.chapterStartMs) == [61_000])
    }
}

@Suite("Tags: Zusammenlegen und Zählen")
struct TagMergeTests {

    let sourceID = SourceID(stable: "quelle")
    let episodeID = EpisodeID(stable: "folge")
    let audio = URL(string: "https://example.com/folge.mp3")!
    var mediaID: MediaVersionID { MediaVersionID(stable: audio.absoluteString) }

    func seededStore() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        let created = Date(timeIntervalSince1970: 1_000)
        try await store.insertInterestRowForTesting(
            identifier: "ki", label: "KI", createdAt: created, normalizedKey: "ki", stance: .neutral,
            origin: .detected)
        try await store.insertInterestRowForTesting(
            identifier: "ai", label: "Künstliche Intelligenz", createdAt: created,
            normalizedKey: "kunstlicheintelligenz", stance: .follow, origin: .confirmedByUser)
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(episodes: [Episode(
            id: episodeID, sourceID: sourceID, title: "Folge", audioURL: audio)], forSource: sourceID)
        return store
    }

    func chapterTag(_ interest: String, key: String, start: Int) -> ChapterTag {
        ChapterTag(
            episodeID: episodeID, mediaVersionID: mediaID, chapterStartMs: start, chapterEndMs: start + 60_000,
            interestID: InterestID(rawValue: interest), normalizedKey: key, confidence: 0.7,
            matchedKnown: true, sourceID: sourceID, publishedAt: nil, transcriptRevision: .initial)
    }

    @Test("Zusammenlegen: Alias, Plus, Kapitel-Tags mit neuem Schlüssel, Verweise umgeschrieben")
    func mergeFromTagPage() async throws {
        let store = try await seededStore()
        #expect(try await store.save(
            chapterTags: [chapterTag("ki", key: "ki", start: 0),
                          chapterTag("ki", key: "ki", start: 60_000),
                          chapterTag("ai", key: "kunstlicheintelligenz", start: 60_000)],
            forEpisode: episodeID, transcriptRevision: .initial))
        let feed = SmartPodcastFeed(title: "Update", topicIDs: [InterestID(rawValue: "ai")])
        try await store.save(smartFeeds: [feed])

        #expect(try await store.chapterCountsByTag() == [InterestID(rawValue: "ki"): 2, InterestID(rawValue: "ai"): 1])

        try await store.mergeTag(InterestID(rawValue: "ai"), into: InterestID(rawValue: "ki"))

        let tags = try await store.tags()
        #expect(tags.map(\.id.rawValue) == ["ki"])
        #expect(tags.first?.aliases.contains("Künstliche Intelligenz") == true)
        // Wer einem der beiden folgte, folgt dem zusammengelegten.
        #expect(tags.first?.stance == .follow)

        let chapterTags = try await store.chapterTags(forEpisode: episodeID)
        #expect(chapterTags.allSatisfy { $0.interestID.rawValue == "ki" && $0.normalizedKey == "ki" })
        // Dasselbe Kapitel trug beide Tags, jetzt ist es eine Zeile.
        #expect(chapterTags.map(\.chapterStartMs) == [0, 60_000])
        #expect(try await store.chapterCountsByTag() == [InterestID(rawValue: "ki"): 2])
        #expect(try await store.smartFeeds().first?.topicIDs == [InterestID(rawValue: "ki")])
        #expect(try await store.chapterTags(forTag: InterestID(rawValue: "ki")).count == 2)
    }

    @Test("Zusammenlegen mit sich selbst oder einem unbekannten Tag ändert nichts")
    func mergeNoOps() async throws {
        let store = try await seededStore()
        try await store.mergeTag(InterestID(rawValue: "ki"), into: InterestID(rawValue: "ki"))
        try await store.mergeTag(InterestID(rawValue: "gibt es nicht"), into: InterestID(rawValue: "ki"))
        #expect(try await store.tags().count == 2)
    }
}

@Suite("Tags: Zusammenlegen vorschlagen")
struct TagSimilarityTests {

    func tag(_ label: String, _ key: String) -> PodcastAICore.Tag {
        PodcastAICore.Tag(id: InterestID(rawValue: key), label: label, normalizedKey: key,
                          stance: .neutral, origin: .detected)
    }

    @Test("Nahe über den Schlüssel: Anfang, Ende, Tippfehler; Länder nur über den Schlüssel")
    func lexical() {
        let base = tag("Datenschutz", "datenschutz")
        let tags = [base, tag("Datenschutzgesetz", "datenschutzgesetz"), tag("Datenschuzt", "datenschuzt"),
                    tag("Sprachmodelle", "sprachmodelle"), tag("USA", "region:US")]
        let near = TagSimilarity.nearTags(to: base, in: tags).map(\.normalizedKey)
        #expect(near.contains("datenschutzgesetz"))
        #expect(near.contains("datenschuzt"))
        #expect(!near.contains("datenschutz"))
        #expect(!near.contains("region:US"))
        #expect(TagSimilarity.lexicalScore("modelle", "sprachmodelle") == 0)
        #expect(TagSimilarity.lexicalScore("ki", "kiverordnung") == nil)
        #expect(TagSimilarity.editDistance("haftung", "haftungg") == 1)
    }

    @Test("Über den Satzvektor nur in derselben Sprache: Datenschutz liegt nicht bei Fußball")
    func embedding() {
        let privacy = tag("Datenschutz", "datenschutz")
        #expect(TagSimilarity.nearTags(to: privacy, in: [privacy, tag("Fußball", "fussball")]).isEmpty)
        // Verschieden erkannte Sprachen vergleicht der Vektor nicht.
        #expect(TagSimilarity.language(of: "Datenschutz") == .german)
        #expect(TagSimilarity.language(of: "") == nil)
    }
}

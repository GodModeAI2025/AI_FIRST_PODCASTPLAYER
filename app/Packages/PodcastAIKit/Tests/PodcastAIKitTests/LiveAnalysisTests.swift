//
//  LiveAnalysisTests.swift
//
//  Ende-zu-Ende auf echtem Netz und echter Spracherkennung: Feed lesen,
//  Folge laden, transkribieren, Belege speichern. Läuft nur mit
//  PODCASTAI_LIVE=1, weil er Minuten dauert und ein Sprachmodell braucht.
//

import Testing
import Foundation
@testable import PodcastAIKit

@Suite("Live-Erschließung", .enabled(if: ProcessInfo.processInfo.environment["PODCASTAI_LIVE"] == "1"))
struct LiveAnalysisTests {

    @Test("Eine echte englische Folge wird mit Zeitmarken erschlossen", .timeLimit(.minutes(20)))
    func analyzesRealEpisode() async throws {
        let feedURL = URL(string: "https://feeds.npr.org/510325/podcast.xml")!
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        let feed = try FeedParser().parse(data)
        #expect(feed.language?.hasPrefix("en") == true)
        let item = try #require(feed.items.first(where: { $0.audioURL != nil }))
        let audioURL = try #require(item.audioURL)

        let container = try LibraryStore.makeContainer(inMemory: true)
        let store = LibraryStore.make(container: container)
        let sourceID = SourceID(stable: feedURL.absoluteString)
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: feed.title,
                                              feedURL: feedURL, language: feed.language))
        let episode = Episode(id: EpisodeID(stable: audioURL.absoluteString), sourceID: sourceID,
                              title: item.title, audioURL: audioURL)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)

        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcastai-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: media) }

        let started = Date()
        let pipeline = ContentPipeline(store: store, mediaDirectory: media) { progress in
            print("[live] \(progress.stage.label) \(progress.detail ?? "")")
        }
        let evidence = try await pipeline.process(
            episode: episode, audioURL: audioURL, sourceID: sourceID,
            locale: Locale(identifier: feed.language ?? "en"))
        print("[live] \(evidence.count) Belege in \(Int(Date().timeIntervalSince(started))) s")
        if let first = evidence.first {
            print("[live] erster Beleg: \(first.range.map { "\($0.start.timecode)–\($0.end.timecode)" } ?? "-") \(first.quotedText.prefix(160))")
        }
        #expect(evidence.count > 3)
        #expect(evidence.allSatisfy { $0.range != nil })
        #expect(evidence.contains { $0.quotedText.split(separator: " ").count > 20 })
    }
}

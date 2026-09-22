//
//  RemovedEpisodeQueryTests.swift
//  PodcastAIKitTests
//
//  Eine gelöschte Folge bleibt als Merkzeichen stehen. Sie darf über die
//  Kennung nicht wieder auftauchen, etwa in „Als Nächstes“, und ein
//  anderes Gerät muss sie als gelöscht erkennen können.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIPersistence

@Suite("Gelöschte Folgen abfragen")
struct RemovedEpisodeQueryTests {

    let sourceID = SourceID(stable: "quelle-merkzeichen")
    let kept = EpisodeID(stable: "bleibt")
    let removed = EpisodeID(stable: "geloescht")
    let audio = URL(string: "https://example.com/geloescht.mp3")!

    func store() async throws -> LibraryStore {
        let store = LibraryStore.make(container: try LibraryStore.makeContainer(inMemory: true))
        try await store.upsert(source: Source(id: sourceID, kind: .podcastRSS, title: "Quelle"))
        _ = try await store.upsert(episodes: [
            Episode(id: kept, sourceID: sourceID, title: "Bleibt"),
            Episode(id: removed, sourceID: sourceID, title: "Gelöscht", audioURL: audio),
        ], forSource: sourceID)
        return store
    }

    @Test("Über die Kennung kommt eine gelöschte Folge nicht zurück")
    func episodesByIDSkipTombstones() async throws {
        let store = try await store()
        _ = try await store.removeEpisode(removed)
        let found = try await store.episodes(ids: [kept, removed]).map(\.id)
        #expect(found == [kept])
    }

    @Test("Die Merkzeichen lassen sich abfragen, mit Audioadresse")
    func tombstonesAreListed() async throws {
        let store = try await store()
        #expect(try await store.removedEpisodes().isEmpty)
        _ = try await store.removeEpisode(removed)
        let tombstones = try await store.removedEpisodes()
        #expect(tombstones.map(\.id) == [removed])
        #expect(tombstones.first?.streamMediaVersionID == MediaVersionID(stable: audio.absoluteString))
    }
}

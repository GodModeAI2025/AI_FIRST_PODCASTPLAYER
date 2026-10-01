//
//  PlayerKitTests.swift
//
//  Der Player für Uhr und Fernseher: Warteschlange, Schlaf-Timer, Bibliothek
//  auf dem schmalen Modell, Fortsetzungsstelle über Geräte, Regel 1.
//

import Testing
import Foundation
import SwiftData
@testable import PodcastAIPlayerKit
import PodcastAICore
import PodcastAISources

private func makeItem(
    _ name: String, source: String = "show", seconds: Int = 600, resume: Int64? = nil,
    audio: String? = nil
) -> PlayerItem {
    let sourceID = SourceID(rawValue: source)
    let episode = Episode(
        id: EpisodeID(rawValue: name), sourceID: sourceID, title: name,
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        declaredDuration: MediaDuration(seconds: Double(seconds)),
        audioURL: URL(string: audio ?? "https://example.com/\(name).mp3"))
    return PlayerItem(episode: episode, showTitle: "Show", showArtworkURL: nil,
                      resume: resume.map { MediaTime(milliseconds: $0) })
}

@Suite("Player: Warteschlange und Wertetypen")
struct PlayerValueTests {

    @Test func upNextAppendMovesDuplicateToEnd() {
        var queue = UpNextQueue()
        queue.append(makeItem("a")); queue.append(makeItem("b")); queue.append(makeItem("a"))
        #expect(queue.items.map(\.id.rawValue) == ["b", "a"])
    }

    @Test func upNextPrependPopAndMove() {
        var queue = UpNextQueue(items: [makeItem("a"), makeItem("b"), makeItem("c")])
        queue.prepend(makeItem("c"))
        #expect(queue.items.map(\.id.rawValue) == ["c", "a", "b"])
        queue.move(from: IndexSet(integer: 0), to: 3)
        #expect(queue.items.map(\.id.rawValue) == ["a", "b", "c"])
        #expect(queue.popFirst()?.id.rawValue == "a")
        #expect(queue.items.count == 2)
    }

    @Test func upNextStoresOnlyIdentifiers() {
        let defaults = UserDefaults(suiteName: "pai-test-\(UUID().uuidString)")!
        UpNextQueue(items: [makeItem("a"), makeItem("b")]).save(to: defaults)
        #expect(UpNextQueue.storedIdentifiers(in: defaults) == ["a", "b"])
    }

    @Test func sleepTimerCountsPlayedTimeAndEndOfEpisodeNeverExpires() {
        var timer = SleepTimerState(.minutes(1))
        #expect(timer.tick(playedSeconds: 30) == false)
        #expect(timer.remaining == 30)
        #expect(timer.tick(playedSeconds: 31) == true)
        var end = SleepTimerState(.endOfEpisode)
        #expect(end.tick(playedSeconds: 10_000) == false)
        #expect(end.stopsAtEndOfEpisode)
    }

    @Test func resumeNearTheEndStartsFromTheBeginning() {
        #expect(makeItem("a", seconds: 600, resume: 120_000).startPosition.milliseconds == 120_000)
        #expect(makeItem("a", seconds: 600, resume: 590_000).startPosition == .zero)
        #expect(makeItem("a", seconds: 600, resume: nil).startPosition == .zero)
    }

    @Test func speedCyclesThroughTheOptions() {
        #expect(PlaybackSpeed.next(after: 1.0) == 1.2)
        #expect(PlaybackSpeed.next(after: 2.0) == 0.8)
        #expect(PlaybackSpeed.next(after: 1.3) == 1.0)
    }

    @Test func onlyHTTPSAndHTTPStreamAndHTTPIsUpgraded() {
        #expect(makeItem("a", audio: "http://example.com/a.mp3").streamURL?.scheme == "https")
        #expect(makeItem("a", audio: "file:///etc/passwd").streamURL == nil)
        #expect(makeItem("a", audio: "ftp://example.com/a.mp3").streamURL == nil)
    }

    @Test func episodeIdentifierFollowsTheRuleOfTheMainApp() {
        var parsed = ParsedItem(guid: "guid-1", title: "Titel", audioURL: URL(string: "https://example.com/a.mp3"))
        let source = SourceID(stable: "https://example.com/feed.xml")
        let episode = FeedImport.episode(from: parsed, sourceID: source)
        #expect(episode.id == EpisodeID(stable: "\(source.rawValue)|guid-1"))
        parsed.guid = nil
        let byURL = FeedImport.episode(from: parsed, sourceID: source)
        #expect(byURL.id == EpisodeID(stable: "\(source.rawValue)|https://example.com/a.mp3"))
    }
}

@Suite("Player: Bibliothek und Fortsetzungsstelle")
@MainActor
struct PlayerLibraryTests {

    private func library(device: String = "watch-1") throws -> PlayerLibrary {
        PlayerLibrary(container: try PlayerLibrary.makeContainer(storeURL: nil, sync: false),
                      storage: .temporary, deviceID: device)
    }

    private func source(_ id: String, title: String, subscribed: Bool = true, added: TimeInterval = 0) -> Source {
        Source(id: SourceID(rawValue: id), kind: .podcastRSS, title: title,
               feedURL: URL(string: "https://example.com/\(id).xml"),
               isSubscribed: subscribed, addedAt: Date(timeIntervalSince1970: added))
    }

    @Test func showsAreSubscribedOnlyDeduplicatedAndSorted() throws {
        let library = try library()
        library.insertForTesting(source: source("b", title: "Beta"))
        library.insertForTesting(source: source("a", title: "Alpha"))
        library.insertForTesting(source: source("a", title: "Alpha Kopie", added: 5))
        library.insertForTesting(source: source("x", title: "Weg", subscribed: false))
        library.reload()
        #expect(library.shows.map(\.title) == ["Alpha", "Beta"])
    }

    @Test func episodesSkipRemovedOnesAndSortNewestFirst() throws {
        let library = try library()
        let show = source("a", title: "Alpha")
        library.insertForTesting(source: show)
        func episode(_ id: String, day: Int) -> Episode {
            Episode(id: EpisodeID(rawValue: id), sourceID: show.id, title: id,
                    publishedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                    audioURL: URL(string: "https://example.com/\(id).mp3"))
        }
        library.insertForTesting(episode: episode("old", day: 1))
        library.insertForTesting(episode: episode("new", day: 3))
        library.insertForTesting(episode: episode("gone", day: 2), removedAt: Date())
        library.reload()
        #expect(library.episodes(for: show).map(\.id.rawValue) == ["new", "old"])
        #expect(library.latest.map(\.id.rawValue) == ["new", "old"])
    }

    @Test func resumeComesFromTheDeviceThatListenedLast() throws {
        let library = try library()
        let item = makeItem("e1")
        let media = try #require(item.episode.streamMediaVersionID)
        func state(resume: Int64, at: TimeInterval) -> MediaListeningState {
            MediaListeningState(
                mediaVersionID: media, heard: IntervalSet(), skipped: IntervalSet(),
                lastEventAt: Date(timeIntervalSince1970: at),
                resumePosition: MediaTime(milliseconds: resume))
        }
        library.insertListeningRowForTesting(media: media, deviceID: "phone", state: state(resume: 100_000, at: 10))
        library.insertListeningRowForTesting(media: media, deviceID: "mac", state: state(resume: 50_000, at: 20))
        #expect(library.resume(for: item.episode)?.milliseconds == 50_000)
    }

    @Test func recordingWritesOnlyTheOwnRowAndAdvancesResume() throws {
        let library = try library(device: "watch-1")
        let item = makeItem("e1")
        let media = try #require(item.episode.streamMediaVersionID)
        let foreign = MediaListeningState(
            mediaVersionID: media, heard: IntervalSet(), skipped: IntervalSet(),
            lastEventAt: Date(timeIntervalSince1970: 10), resumePosition: MediaTime(milliseconds: 30_000))
        library.insertListeningRowForTesting(media: media, deviceID: "phone", state: foreign)

        let range = MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 90_000))
        library.recordPlayed(item, range: range, at: Date(timeIntervalSince1970: 100))

        let keys = Set(library.listeningRowKeysForTesting())
        #expect(keys == ["\(media.rawValue)#phone", "\(media.rawValue)#watch-1"])
        #expect(library.resume(for: item.episode)?.milliseconds == 90_000)
    }

    @Test func emptyRangesAreNotRecorded() throws {
        let library = try library()
        let item = makeItem("e1")
        library.recordPlayed(item, range: MediaTimeRange(start: .zero, end: .zero))
        #expect(library.listeningRowKeysForTesting().isEmpty)
    }

    @Test func upNextIdentifiersResolveInOrderAndDropMissingOnes() throws {
        let library = try library()
        let show = source("a", title: "Alpha")
        library.insertForTesting(source: show)
        for id in ["one", "two"] {
            library.insertForTesting(episode: Episode(
                id: EpisodeID(rawValue: id), sourceID: show.id, title: id,
                audioURL: URL(string: "https://example.com/\(id).mp3")))
        }
        library.reload()
        let items = library.items(forIdentifiers: ["two", "missing", "one"])
        #expect(items.map(\.id.rawValue) == ["two", "one"])
    }
}

@Suite("Player: Regel 1")
@MainActor
struct PlayerRuleOneTests {

    @Test func aFreshEngineIsIdleAndTransportCommandsStartNothing() {
        let engine = PlaybackEngine(defaults: UserDefaults(suiteName: "pai-test-\(UUID().uuidString)")!)
        #expect(engine.state == .idle)
        engine.resume()
        engine.togglePlayPause()
        engine.skip(by: 30)
        #expect(engine.state == .idle)
        #expect(engine.current == nil)
        #expect(engine.playNextInQueue() == false)
    }

    @Test func enqueueingDoesNotPlay() {
        let engine = PlaybackEngine(defaults: UserDefaults(suiteName: "pai-test-\(UUID().uuidString)")!)
        engine.enqueue(makeItem("a"))
        engine.restoreUpNext([makeItem("b")])
        #expect(engine.state == .idle)
        #expect(engine.current == nil)
    }

    @Test func anItemWithoutAudioFailsInsteadOfPlaying() {
        let engine = PlaybackEngine(defaults: UserDefaults(suiteName: "pai-test-\(UUID().uuidString)")!)
        engine.play(makeItem("a", audio: "file:///x.mp3"))
        if case .failed = engine.state {} else { Issue.record("erwartet: failed, war \(engine.state)") }
        #expect(!engine.isPlaying)
    }
}

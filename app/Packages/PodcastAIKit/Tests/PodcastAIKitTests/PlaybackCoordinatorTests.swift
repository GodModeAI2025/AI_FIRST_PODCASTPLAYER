//
//  PlaybackCoordinatorTests.swift
//  PodcastAIKitTests
//
//  Der Koordinator gegen einen echten Player. Die Audiodatei ist Stille,
//  hier im Test erzeugt, damit keine fremden Inhalte in den Testdaten landen.
//

#if canImport(AVFoundation)
import Testing
import Foundation
import AVFoundation
@testable import PodcastAIKit

@Suite("Fokus-Wiedergabe")
@MainActor
struct PlaybackCoordinatorTests {

    private struct FixedLocator: MediaLocating {
        let url: URL?
        func playbackURL(for mediaVersionID: MediaVersionID) -> URL? { url }
    }

    private func makePlan(start: Double, end: Double) -> ValidatedPlaybackPlan {
        ValidatedPlaybackPlan(
            segments: [PlanSegment(
                evidenceID: EvidenceID(rawValue: "e1"),
                mediaVersionID: MediaVersionID(rawValue: "m1"),
                episodeID: EpisodeID(rawValue: "ep1"),
                sourceID: SourceID(rawValue: "s1"),
                range: MediaTimeRange(start: MediaTime(seconds: start), end: MediaTime(seconds: end)),
                sourceTitle: "Quelle", episodeTitle: "Folge"
            )],
            requestSummary: "Test", route: .chatFocus
        )
    }

    /// Stille als WAV in der verlangten Länge.
    private func makeSilence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stille-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("Ein Plan ohne abspielbares Medium gilt danach nicht als laufend")
    func unavailableMediaLeavesNoActivePlan() {
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: nil))
        let plan = makePlan(start: 1, end: 3)
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        #expect(throws: PlaybackCoordinator.StartRefusal.self) {
            try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        }
        #expect(coordinator.activePlan == nil)
        #expect(coordinator.currentOriginalPosition() == nil)
    }

    @Test("Eine Pause während der Vorbereitung gilt auch nach dem Sprung")
    func pauseWhilePreparingIsKept() async throws {
        let url = try makeSilence(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url))
        let plan = makePlan(start: 2, end: 8)
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        #expect(coordinator.state == .preparing(segmentIndex: 0))

        coordinator.pause()
        #expect(coordinator.state == .paused(segmentIndex: 0))

        // Der Sprung ist in dieser Zeit bestätigt. Ohne gemerkte Pause stünde
        // der Plan jetzt auf „spielt“.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(coordinator.state == .paused(segmentIndex: 0))

        coordinator.resume()
        let playing = await waitUntil { coordinator.state == .playing(segmentIndex: 0) }
        #expect(playing)
        coordinator.stop()
    }

    /// Merkt sich, was der Koordinator meldet.
    private final class Recorder: PlaybackObserver {
        var states: [PlaybackState] = []
        var completed: [Int] = []
        func playbackStateChanged(_ state: PlaybackState) { states.append(state) }
        func playbackProgressed(segmentIndex: Int, position: MediaTime) {}
        func segmentCompleted(segmentIndex: Int, heard: MediaTimeRange, mediaVersionID: MediaVersionID) {
            completed.append(segmentIndex)
        }
        func willChangeSource(to segment: PlanSegment) {}
    }

    @Test("Nach einer Stelle folgt von selbst die nächste, jede genau einmal")
    func nextSegmentFollowsOnItsOwn() async throws {
        let url = try makeSilence(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url), observer: recorder)
        let segments = [(1.0, 2.5), (5.0, 6.5), (9.0, 10.5)].enumerated().map { index, bounds in
            PlanSegment(
                evidenceID: EvidenceID(rawValue: "e\(index)"),
                mediaVersionID: MediaVersionID(rawValue: "m1"),
                episodeID: EpisodeID(rawValue: "ep1"),
                sourceID: SourceID(rawValue: "s1"),
                range: MediaTimeRange(start: MediaTime(seconds: bounds.0), end: MediaTime(seconds: bounds.1)),
                sourceTitle: "Quelle", episodeTitle: "Folge"
            )
        }
        let plan = ValidatedPlaybackPlan(segments: segments, requestSummary: "Test", route: .smartFeedEpisode)
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        let finished = await waitUntil(.seconds(15)) { coordinator.state == .finished }
        #expect(finished)
        // Jede Stelle hat wirklich gespielt, keine wurde durch ein doppelt
        // gemeldetes Ende übersprungen.
        #expect(recorder.states.contains(.playing(segmentIndex: 1)))
        #expect(recorder.states.contains(.playing(segmentIndex: 2)))
        #expect(recorder.completed == [0, 1, 2])
    }
}
#endif

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
        /// Fassungen ohne Adresse, wie nach „Audio entfernen“.
        var missing: Set<MediaVersionID> = []
        func playbackURL(for mediaVersionID: MediaVersionID) -> URL? {
            missing.contains(mediaVersionID) ? nil : url
        }
    }

    private func makePlan(start: Double, end: Double) -> ValidatedPlaybackPlan {
        makePlan([("m1", start, end)])
    }

    /// Eine Stelle je Eintrag: Fassung, Anfang und Ende in Sekunden.
    private func makePlan(_ parts: [(media: String, start: Double, end: Double)]) -> ValidatedPlaybackPlan {
        ValidatedPlaybackPlan(
            segments: parts.enumerated().map { index, part in
                PlanSegment(
                    evidenceID: EvidenceID(rawValue: "e\(index + 1)"),
                    mediaVersionID: MediaVersionID(rawValue: part.media),
                    episodeID: EpisodeID(rawValue: "ep1"),
                    sourceID: SourceID(rawValue: "s1"),
                    range: MediaTimeRange(start: MediaTime(seconds: part.start), end: MediaTime(seconds: part.end)),
                    sourceTitle: "Quelle", episodeTitle: "Folge"
                )
            },
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

    @Test("Fehlt das Medium der nächsten Stelle, endet der Plan mit dem Grund", arguments: [false, true])
    func missingNextMediaFailsThePlan(skipping: Bool) async throws {
        let url = try makeSilence(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = MediaVersionID(rawValue: "m2")
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url, missing: [missing]))
        let plan = makePlan([("m1", 1, 2.5), ("m2", 1, 2.5)])
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        // Zur zweiten Stelle führt das Ende der ersten oder das Überspringen.
        if skipping { coordinator.skipSegment() }
        // Ohne den Fehler bliebe der Plan für immer auf „spielt“ stehen.
        let reason = PlaybackCoordinator.StartRefusal.mediaUnavailable(missing).localizedDescription
        let failed = await waitUntil(.seconds(10)) { coordinator.state == .failed(reason) }
        #expect(failed)
        #expect(coordinator.activePlan == nil)
        #expect(coordinator.currentOriginalPosition() == nil)
    }

    @Test("Stopp zählt das Gehörte und beginnt die nächste Stelle nicht")
    func stopDoesNotStartTheNextSegment() async throws {
        let url = try makeSilence(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url), observer: recorder)
        let plan = makePlan([("m1", 1, 8), ("m1", 2, 9)])
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        // Erst stoppen, wenn schon etwas erklungen ist.
        let heard = await waitUntil {
            (coordinator.currentOriginalPosition()?.1 ?? .zero) > MediaTime(seconds: 1.2)
        }
        #expect(heard)

        coordinator.stop()
        #expect(coordinator.state == .idle)
        #expect(recorder.completed == [0])
        // Früher bereitete Stopp noch die zweite Stelle vor und sagte sie an.
        #expect(!recorder.states.contains(.preparing(segmentIndex: 1)))
    }

    @Test("Nach dem Ende des Plans stellt ein verspäteter Sprung ihn nicht wieder auf „spielt“")
    func lateSeekAfterTheEndChangesNothing() async throws {
        let url = try makeSilence(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url))
        let plan = makePlan([("m1", 1, 8), ("m1", 2, 9)])
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        // Die letzte Stelle fällt weg, während ihr Sprung noch läuft.
        coordinator.skipSegment()
        coordinator.skipSegment()
        #expect(coordinator.state == .finished)

        // Die Bestätigung des Sprungs trifft erst jetzt ein.
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.state == .finished)
    }

    /// Hält das Item der ersten Stelle fest. Der Koordinator gibt es nicht heraus.
    @MainActor
    private final class ItemBox {
        var item: AVPlayerItem?
    }

    @Test("Ein doppelt gemeldetes Ende zählt die nächste Stelle nicht als gehört")
    func doubleEndDoesNotCompleteTheNextSegment() async throws {
        let url = try makeSilence(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let coordinator = PlaybackCoordinator(locator: FixedLocator(url: url), observer: recorder)
        let plan = makePlan([("m1", 1, 8), ("m1", 2, 9), ("m1", 3, 9.5)])
        let grant = PlaybackPolicy(deviceID: "device").grantForUserTap(on: plan)

        // Der Sprung an den Anfang der Stelle meldet sich mit dem Item. Andere
        // Tests spielen im selben Prozess, deshalb zählt nur die eigene Datei.
        let box = ItemBox()
        let jump = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: nil
        ) { note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                if box.item == nil, (item.asset as? AVURLAsset)?.url == url { box.item = item }
            }
        }
        defer { NotificationCenter.default.removeObserver(jump) }

        try coordinator.start(plan: plan, grant: grant, deviceID: "device")
        let playing = await waitUntil { coordinator.state == .playing(segmentIndex: 0) && box.item != nil }
        #expect(playing)
        let item = try #require(box.item)

        // Das Ende kommt zweimal an, bevor der Koordinator auf die erste
        // Meldung reagiert hat. So treffen sonst End- und Zeitbeobachter ein.
        // Gedeckt ist damit nur die Prüfung am Endbeobachter. Die am
        // Zeitbeobachter trifft ein Test nur, wenn er den Hauptthread eine
        // halbe Sekunde über das Ende der Stelle hinweg besetzt hält. Daran
        // scheitern andere Tests im selben Prozess, etwa `SyncObserverTests`
        // mit seiner Ruhezeit von 300 ms.
        for _ in 0..<2 {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }

        let second = await waitUntil { coordinator.state == .playing(segmentIndex: 1) }
        #expect(second)
        #expect(recorder.completed == [0])
        coordinator.stop()
    }
}
#endif

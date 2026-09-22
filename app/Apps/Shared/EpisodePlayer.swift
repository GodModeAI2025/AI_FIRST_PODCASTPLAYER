//
//  EpisodePlayer.swift
//  PodcastAI
//
//  Spielt ganze Folgen, gestreamt oder aus der geladenen Datei. Ergänzt den
//  Fokus-Player, der nur ausgewählte Stellen spielt.
//
//  Was hier gehört wird, landet im selben Hörzustand wie jede andere
//  Wiedergabe. „Für dich“ und die Themen-Updates wissen deshalb auch, was in
//  einer ganzen Folge schon gehört wurde.
//

import Foundation
import AVFoundation
import Observation
import PodcastAIKit

#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
@Observable
public final class EpisodePlayer {

    public private(set) var episode: Episode?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var chapters: [Chapter] = []
    public var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = rate } }
    }

    /// Wird für jedes gehörte Stück aufgerufen, spätestens alle zehn Sekunden.
    @ObservationIgnored public var onHeard: ((MediaTimeRange, MediaVersionID) -> Void)?
    /// Wird am Ende einer Folge aufgerufen.
    @ObservationIgnored public var onFinished: ((Episode) -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var heardStart: Double?

    public init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        configureRemoteCommands()
    }

    public var currentChapter: Chapter? {
        chapters.last { $0.start.seconds <= currentTime + 0.5 }
    }

    /// Startet eine Folge an einer Stelle. `localFile` hat Vorrang vor dem Stream.
    public func play(_ episode: Episode, at seconds: Double = 0, localFile: URL? = nil) {
        guard let url = localFile ?? episode.audioURL else { return }
        flushHeard()
        if self.episode?.id != episode.id {
            self.episode = episode
            chapters = episode.publisherChapters
            duration = episode.declaredDuration?.seconds ?? 0
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finished() }
            }
            Task { [weak self] in
                if let loaded = try? await item.asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                    self?.duration = loaded.seconds
                    self?.updateNowPlaying()
                }
            }
        }
        seek(to: seconds)
        resume()
    }

    public func setChapters(_ chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        self.chapters = chapters
    }

    public func resume() {
        guard episode != nil else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.playImmediately(atRate: rate)
        isPlaying = true
        heardStart = currentTime
        updateNowPlaying()
    }

    public func pause() {
        flushHeard()
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    public func togglePlayPause() { isPlaying ? pause() : resume() }

    public func seek(to seconds: Double) {
        flushHeard()
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        if isPlaying { heardStart = target }
        updateNowPlaying()
    }

    public func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    public func nextChapter() {
        if let next = chapters.first(where: { $0.start.seconds > currentTime + 1 }) {
            seek(to: next.start.seconds)
        }
    }

    public func previousChapter() {
        let earlier = chapters.filter { $0.start.seconds < currentTime - 3 }
        seek(to: earlier.last?.start.seconds ?? 0)
    }

    public func stop() {
        flushHeard()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        episode = nil
        chapters = []
        currentTime = 0
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    // MARK: - Hörzustand

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, let start = heardStart, seconds - start >= 10 { flushHeard() }
    }

    private func flushHeard() {
        guard let start = heardStart, let episode, let mediaID = episode.streamMediaVersionID else {
            heardStart = isPlaying ? currentTime : nil
            return
        }
        let end = currentTime
        heardStart = isPlaying ? end : nil
        guard end - start >= 1, end - start < 600 else { return }
        let range = MediaTimeRange(
            start: MediaTime(milliseconds: Int64(start * 1000)),
            end: MediaTime(milliseconds: Int64(end * 1000))
        )
        onHeard?(range, mediaID)
    }

    private func finished() {
        flushHeard()
        isPlaying = false
        if let episode { onFinished?(episode) }
    }

    // MARK: - Sperrbildschirm und Kopfhörertasten

    private func updateNowPlaying() {
        #if canImport(MediaPlayer)
        guard let episode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let chapter = currentChapter { info[MPMediaItemPropertyAlbumTitle] = chapter.title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 30) }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -15) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
        #endif
    }
}

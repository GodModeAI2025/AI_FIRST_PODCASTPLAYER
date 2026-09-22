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
    /// Der Player wartet auf Daten, etwa beim Start eines Streams.
    public private(set) var isBuffering = false
    /// Was schiefging, in einem Satz für die Anzeige.
    public private(set) var playbackError: String?
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
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    /// Solange ein Sprung läuft, meldet der Zeitbeobachter noch die alte
    /// Stelle. Ohne diese Sperre springt die Anzeige hin und her.
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var usingLocalFile = false
    /// Gewünschte Startstelle, solange die Folge noch nicht bereit ist.
    /// Ein Sprung vor `readyToPlay` verpufft, und die Folge lief dann
    /// irgendwo statt an der gewünschten Stelle.
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var resumeWhenReady = false
    @ObservationIgnored private let positionsKey = "episodePlaybackPositions"
    @ObservationIgnored private var positions: [String: Double]

    public init() {
        positions = (UserDefaults.standard.dictionary(forKey: "episodePlaybackPositions") as? [String: Double]) ?? [:]
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        configureRemoteCommands()
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.controlStatusChanged(status) }
        }
    }

    public var currentChapter: Chapter? {
        chapters.last { $0.start.seconds <= currentTime + 0.5 }
    }

    /// Startet eine Folge an einer Stelle. `localFile` hat Vorrang vor dem Stream.
    public func play(_ episode: Episode, at seconds: Double = 0, localFile: URL? = nil) {
        guard let url = localFile ?? episode.audioURL else {
            playbackError = "Zu dieser Folge gibt es keine Audiodatei."
            return
        }
        if self.episode?.id == episode.id {
            seek(to: seconds)
            resume()
            return
        }
        // Erst die alte Folge sauber abschließen. Sonst landet die zuletzt
        // gehörte Zeit der alten Folge auf der neuen.
        flushHeard()
        savePosition()
        heardStart = nil
        isPlaying = false
        self.episode = episode
        chapters = episode.publisherChapters
        duration = episode.declaredDuration?.seconds ?? 0
        currentTime = seconds
        pendingStart = seconds
        resumeWhenReady = true
        load(url, isLocal: localFile != nil)
        updateNowPlaying()
    }

    /// Die zuletzt gehörte Stelle einer Folge, sofern sie gemerkt wurde.
    public func savedPosition(for episodeID: EpisodeID) -> Double? {
        positions[episodeID.rawValue]
    }

    private func savePosition() {
        guard let episode, currentTime > 5 else { return }
        // Fast zu Ende heisst: beim nächsten Mal wieder von vorn.
        let value = duration > 0 && currentTime > duration - 15 ? 0 : currentTime
        positions[episode.id.rawValue] = value
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    private func load(_ url: URL, isLocal: Bool) {
        playbackError = nil
        usingLocalFile = isLocal
        let item = AVPlayerItem(asset: PlayableAsset.make(url: url))
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, message: message, item: item) }
        }
        Task { [weak self] in
            if let loaded = try? await item.asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                self?.duration = loaded.seconds
                self?.updateNowPlaying()
            }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        if status == .readyToPlay {
            if let start = pendingStart {
                pendingStart = nil
                seek(to: start)
            }
            if resumeWhenReady {
                resumeWhenReady = false
                resume()
            }
            return
        }
        guard status == .failed else { return }
        // Die geladene Datei ließ sich nicht öffnen: dann eben der Stream.
        if usingLocalFile, let stream = episode?.audioURL {
            pendingStart = currentTime
            resumeWhenReady = isPlaying || resumeWhenReady
            load(stream, isLocal: false)
            return
        }
        isPlaying = false
        isBuffering = false
        resumeWhenReady = false
        pendingStart = nil
        playbackError = "Die Folge lässt sich nicht abspielen. "
            + (message.map { "Grund: \($0)" } ?? "Der Server liefert kein abspielbares Audio.")
        updateNowPlaying()
    }

    private func controlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        isBuffering = status == .waitingToPlayAtSpecifiedRate
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
        savePosition()
        resumeWhenReady = false
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    public func togglePlayPause() { isPlaying ? pause() : resume() }

    public func seek(to seconds: Double) {
        flushHeard()
        // Vor `readyToPlay` verpufft ein Sprung. Dann wird er gemerkt.
        if player.currentItem?.status != .readyToPlay {
            let target = max(0, seconds)
            pendingStart = target
            currentTime = target
            if isPlaying { heardStart = target }
            updateNowPlaying()
            return
        }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        seekGeneration += 1
        let generation = seekGeneration
        seekInFlight = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seekInFlight = false
            }
        }
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
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        playbackError = nil
        statusObservation = nil
        episode = nil
        chapters = []
        currentTime = 0
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    // MARK: - Hörzustand

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !seekInFlight else { return }
        currentTime = seconds
        if isPlaying, let start = heardStart, seconds - start >= 10 {
            flushHeard()
            savePosition()
        }
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
        if let episode {
            positions[episode.id.rawValue] = 0
            UserDefaults.standard.set(positions, forKey: positionsKey)
        }
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

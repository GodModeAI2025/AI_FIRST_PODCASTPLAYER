//
//  PlaybackEngine.swift
//  PodcastAIPlayerKit
//
//  Die Wiedergabe für Uhr und Fernseher: AVPlayer, Systemanzeige „Wiedergabe“,
//  Fernbedienung, Tempo, Schlaf-Timer, Kapitel und „Als Nächstes“.
//
//  Regel 1: Nichts spielt von selbst. Ton beginnt nur in `play(_:)`, und das
//  ruft die Oberfläche als Folge einer Handlung: ein Tipp, ein Druck auf die
//  Fernbedienung, eine Anforderung über Siri. Eine geladene Liste, ein
//  geöffnetes „Wiedergabe“ und der Start der App starten keinen Ton. Nach dem
//  Ende einer Folge läuft nur weiter, was jemand selbst in „Als Nächstes“
//  gelegt hat. Nach einer Unterbrechung (Anruf, Wecker) beginnt der Ton nicht
//  von selbst wieder.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MediaPlayer
import Observation
import PodcastAICore
import PodcastAISources
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class PlaybackEngine {

    public enum State: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var current: PlayerItem?
    /// Stelle in Sekunden.
    public private(set) var position: TimeInterval = 0
    /// Länge in Sekunden, 0 solange unbekannt.
    public private(set) var duration: TimeInterval = 0
    public private(set) var chapters: [Chapter] = []
    public private(set) var speed: Float = 1.0
    public private(set) var sleepTimer: SleepTimerState?
    public private(set) var upNext = UpNextQueue()

    public var isPlaying: Bool { state == .playing }

    /// Das Kapitel an der aktuellen Stelle.
    public var currentChapter: Chapter? {
        chapters.last { $0.start.seconds <= position + 0.25 }
    }

    public static let skipForwardSeconds: TimeInterval = 30
    public static let skipBackSeconds: TimeInterval = 15

    // MARK: Anschlüsse

    /// Eine geladene Datei dieser Folge, sonst wird gestreamt.
    @ObservationIgnored public var localFileURL: (@MainActor (PlayerItem) -> URL?)?
    /// Die aktuelle Fortsetzungsstelle aus der Bibliothek, damit ein Start
    /// dort weitergeht, wo ein anderes Gerät aufgehört hat.
    @ObservationIgnored public var resumeProvider: (@MainActor (Episode) -> MediaTime?)?
    /// Meldet einen gehörten Bereich, wenn er endet (Pause, Sprung, Ende) und
    /// alle 30 Sekunden währenddessen.
    @ObservationIgnored public var onListened: (@MainActor (PlayerItem, MediaTimeRange) -> Void)?

    // MARK: Innenleben

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var sessionObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var segmentStart: TimeInterval?
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var sinceFlush: TimeInterval = 0
    @ObservationIgnored private var chapterTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private lazy var session = SafeHTTP.makeSession()
    @ObservationIgnored private let defaults: UserDefaults

    private static let tickInterval: TimeInterval = 1
    private static let flushInterval: TimeInterval = 30

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.float(forKey: "playerSpeed")
        if PlaybackSpeed.options.contains(where: { abs($0 - stored) < 0.01 }) { speed = stored }
    }

    // MARK: - Abspielen

    /// Spielt die Folge. Nur aufrufen, wenn jemand es verlangt hat (Regel 1).
    public func play(_ item: PlayerItem, from start: MediaTime? = nil) {
        endSegment()
        var item = item
        if let resumeProvider, let fresh = resumeProvider(item.episode) { item.resume = fresh }
        let startPosition = start ?? item.startPosition
        let url = localFileURL?(item) ?? item.streamURL
        guard let url else {
            current = item
            state = .failed(String(localized: "Diese Folge hat keine Audioadresse.", bundle: .module))
            return
        }
        teardownPlayer()
        current = item
        position = startPosition.seconds
        duration = item.declaredSeconds
        chapters = item.episode.publisherChapters.sorted { $0.start < $1.start }
        state = .loading
        loadChaptersIfNeeded(for: item)
        loadArtwork(for: item)

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = speed
        self.player = player
        installRemoteCommands()
        installSessionObservers()
        observe(playerItem, player: player)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.activateAudioSession()
            } catch {
                guard self.current?.id == item.id else { return }
                self.state = .failed(String(
                    localized: "Kein Audioweg frei. Verbinde Kopfhörer oder Lautsprecher.", bundle: .module))
                return
            }
            guard self.current?.id == item.id, self.player === player else { return }
            if startPosition.seconds > 0 {
                await player.seek(to: CMTime(seconds: startPosition.seconds, preferredTimescale: 600))
            }
            guard self.current?.id == item.id, self.player === player else { return }
            player.playImmediately(atRate: self.speed)
            self.state = .playing
            self.beginSegment()
            self.updateNowPlaying()
        }
    }

    /// Setzt eine pausierte Folge fort. Tut nichts, wenn nichts geladen ist:
    /// ohne Handlung und ohne Folge beginnt kein Ton.
    public func resume() {
        guard let player, current != nil, state == .paused else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Self.activateAudioSession()
            guard self.player === player else { return }
            player.playImmediately(atRate: self.speed)
            self.state = .playing
            self.beginSegment()
            self.updateNowPlaying()
        }
    }

    public func pause() {
        guard state == .playing || state == .loading else { return }
        endSegment()
        player?.pause()
        state = .paused
        updateNowPlaying()
    }

    public func togglePlayPause() {
        switch state {
        case .playing, .loading: pause()
        case .paused: resume()
        case .idle, .failed:
            if let current { play(current) }
        }
    }

    /// Hält an und gibt Player und Hörsitzung frei, die Folge bleibt gewählt.
    public func stop() {
        pause()
        position = player?.currentTime().seconds.finiteOrZero ?? position
    }

    // MARK: - Springen

    public func skip(by seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    public func seek(to seconds: TimeInterval) {
        guard let player, current != nil else { return }
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max(0, seconds), upper)
        let wasPlaying = state == .playing
        if wasPlaying { endSegment() }
        position = target
        lastTick = nil
        Task { [weak self] in
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            guard let self, self.player === player else { return }
            if wasPlaying { self.beginSegment() }
            self.updateNowPlaying()
        }
    }

    public func jump(to chapter: Chapter) {
        seek(to: chapter.start.seconds)
    }

    public func previousChapter() {
        // Innerhalb der ersten Sekunden eines Kapitels geht es zum vorigen,
        // sonst an den Anfang des aktuellen.
        let earlier = chapters.filter { $0.start.seconds < position - 3 }
        if let target = earlier.last { seek(to: target.start.seconds) } else { seek(to: 0) }
    }

    public func nextChapter() {
        if let target = chapters.first(where: { $0.start.seconds > position + 0.5 }) {
            seek(to: target.start.seconds)
        }
    }

    // MARK: - Tempo und Schlaf-Timer

    public func setSpeed(_ rate: Float) {
        guard PlaybackSpeed.options.contains(where: { abs($0 - rate) < 0.01 }) else { return }
        speed = rate
        defaults.set(rate, forKey: "playerSpeed")
        player?.defaultRate = rate
        if state == .playing { player?.rate = rate }
        updateNowPlaying()
    }

    public func cycleSpeed() {
        setSpeed(PlaybackSpeed.next(after: speed))
    }

    /// `nil` schaltet den Timer aus.
    public func setSleepTimer(_ setting: SleepTimerSetting?) {
        sleepTimer = setting.map(SleepTimerState.init)
    }

    // MARK: - Als Nächstes

    /// Ersetzt die Warteschlange, etwa beim Start mit den gemerkten Folgen.
    public func restoreUpNext(_ items: [PlayerItem]) {
        upNext = UpNextQueue(items: items)
    }

    public func enqueue(_ item: PlayerItem) {
        upNext.append(item)
        upNext.save(to: defaults)
    }

    public func enqueueNext(_ item: PlayerItem) {
        upNext.prepend(item)
        upNext.save(to: defaults)
    }

    public func removeFromUpNext(_ id: EpisodeID) {
        upNext.remove(id)
        upNext.save(to: defaults)
    }

    public func moveUpNext(from source: IndexSet, to destination: Int) {
        upNext.move(from: source, to: destination)
        upNext.save(to: defaults)
    }

    public func clearUpNext() {
        upNext.removeAll()
        upNext.save(to: defaults)
    }

    /// Spielt die nächste Folge aus „Als Nächstes“. `false`, wenn die
    /// Warteschlange leer ist.
    @discardableResult
    public func playNextInQueue() -> Bool {
        guard let next = upNext.popFirst() else { return false }
        upNext.save(to: defaults)
        play(next)
        return true
    }

    /// Spielt eine Folge aus der Warteschlange an und lässt die davor stehen.
    public func playFromUpNext(_ id: EpisodeID) {
        guard let item = upNext.items.first(where: { $0.id == id }) else { return }
        upNext.remove(id)
        upNext.save(to: defaults)
        play(item)
    }

    // MARK: - Hörsitzung

    private static func activateAudioSession() async throws {
        #if os(watchOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        _ = try await session.activate(options: [])
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
    }

    // MARK: - Beobachten

    private func observe(_ item: AVPlayerItem, player: AVPlayer) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let length = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                if failed {
                    self.endSegment()
                    self.state = .failed(String(localized: "Die Audiodatei lässt sich nicht abspielen.", bundle: .module))
                } else if length.isFinite, length > 0 {
                    self.duration = length
                    self.updateNowPlaying()
                }
            }
        }
        // Hält das System die Wiedergabe an (Siri, Kopfhörer, andere App), folgt
        // der Zustand. Von selbst setzt sich nichts fort.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            Task { @MainActor [weak self] in
                guard let self, self.player === player, paused, self.state == .playing else { return }
                self.endSegment()
                self.state = .paused
                self.updateNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        let interval = CMTime(seconds: Self.tickInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(at: seconds) }
        }
    }

    private func tick(at seconds: TimeInterval) {
        guard state == .playing, seconds.isFinite else { return }
        position = seconds
        // Ein Sprung (Spulen am Rad, Kapitel) beendet den Bereich davor.
        if let last = lastTick, abs(seconds - last) > Self.tickInterval * 4 + 2 {
            if let start = segmentStart { emit(from: start, to: last) }
            segmentStart = seconds
            sinceFlush = 0
        }
        lastTick = seconds
        sinceFlush += Self.tickInterval
        if sinceFlush >= Self.flushInterval {
            endSegment()
            beginSegment()
        }
        if var timer = sleepTimer {
            if timer.tick(playedSeconds: Self.tickInterval) {
                sleepTimer = nil
                pause()
                return
            }
            sleepTimer = timer
        }
    }

    private func didFinish() {
        guard let finished = current else { return }
        if let start = segmentStart { emit(from: start, to: max(position, duration)) }
        segmentStart = nil
        lastTick = nil
        position = duration
        let stopHere = sleepTimer?.stopsAtEndOfEpisode == true
        if stopHere { sleepTimer = nil }
        // Die Folge ist zu Ende: die Stelle gilt als Ende der Folge.
        if !stopHere, playNextInQueue() { return }
        player?.pause()
        state = .paused
        current = finished
        updateNowPlaying()
    }

    // MARK: - Gehörte Bereiche

    private func beginSegment() {
        segmentStart = position
        lastTick = position
        sinceFlush = 0
    }

    private func endSegment() {
        if let start = segmentStart {
            let end = player?.currentTime().seconds.finiteOrZero ?? position
            emit(from: start, to: max(end, position))
        }
        segmentStart = nil
        lastTick = nil
        sinceFlush = 0
    }

    private func emit(from start: TimeInterval, to end: TimeInterval) {
        guard let current, end - start >= 1 else { return }
        let range = MediaTimeRange(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
        onListened?(current, range)
    }

    // MARK: - Kapitel und Cover

    private func loadChaptersIfNeeded(for item: PlayerItem) {
        chapterTask?.cancel()
        guard chapters.isEmpty, let url = item.episode.chaptersURL else { return }
        chapterTask = Task { [weak self] in
            guard let self else { return }
            guard let data = try? await SafeHTTP.load(url, using: self.session, limit: 2 * 1024 * 1024),
                  let loaded = try? ChapterFile.parse(data), !Task.isCancelled,
                  self.current?.id == item.id else { return }
            self.chapters = loaded.sorted { $0.start < $1.start }
        }
    }

    private func loadArtwork(for item: PlayerItem) {
        artworkTask?.cancel()
        artwork = nil
        #if canImport(UIKit)
        guard let url = item.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            guard let data = try? await SafeHTTP.load(url, using: self.session, limit: 8 * 1024 * 1024),
                  let image = UIImage(data: data), !Task.isCancelled,
                  self.current?.id == item.id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
        #endif
    }

    // MARK: - Systemanzeige und Fernbedienung

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyAlbumTitle: current.showTitle,
            MPMediaItemPropertyArtist: current.showTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = switch state {
        case .playing: .playing
        case .paused: .paused
        case .idle, .failed: .stopped
        case .loading: .playing
        }
    }

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: Self.skipForwardSeconds) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -Self.skipBackSeconds) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNextInQueue() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self?.seek(to: target) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackSpeed.options.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in self?.setSpeed(rate) }
            return .success
        }
    }

    /// Eine Unterbrechung oder ein abgezogener Kopfhörer hält an. Weiter geht
    /// es erst, wenn jemand es verlangt (Regel 1).
    private func installSessionObservers() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Seit 27: die Sitzung wird inaktiv (Anruf, Wecker, andere App). Die
        // Empfehlung, danach fortzusetzen, bleibt ungenutzt.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let lost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            MainActor.assumeIsolated { if lost { self?.pause() } }
        })
        #endif
    }

    private func teardownPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        rateObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
#endif

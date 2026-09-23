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
//  Sperrbildschirm und Kopfhörertasten gehören immer genau einem Player.
//  Solange ein Fokus-Plan besteht, leitet dieser Player die Befehle an ihn
//  weiter und zeigt ihn am Sperrbildschirm. Die Folge bleibt dann still.
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

    /// Schlaf-Timer: nach einer Zeit, am Ende des Kapitels oder der Folge.
    public enum SleepTimer: Equatable, Sendable {
        case minutes(Int), endOfChapter, endOfEpisode
        public var label: String {
            switch self {
            case .minutes(let value): "\(value) Minuten"
            case .endOfChapter: "Ende des Kapitels"
            case .endOfEpisode: "Ende der Folge"
            }
        }
    }
    public private(set) var sleepTimer: SleepTimer?
    /// Wann ein Minuten-Timer abläuft. Gesetzt nur, solange die Folge spielt.
    public private(set) var sleepDeadline: Date?
    /// Restzeit eines Minuten-Timers während einer Pause. In der Pause zählt
    /// der Timer nicht weiter. Sonst hielte er gleich nach dem Fortsetzen an.
    public private(set) var sleepPausedRemaining: TimeInterval?
    /// Eine Stelle in dem Kapitel, dessen Ende der Timer abwartet. Das Ende
    /// selbst wird bei jedem Tick aus den aktuellen Kapiteln bestimmt, damit
    /// nachgeladene Kapitel und Sprünge es richtig verschieben.
    @ObservationIgnored private var sleepChapterAnchor: Double?
    public var rate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    /// Wie lange ein Minuten-Timer noch läuft.
    public var sleepRemaining: TimeInterval? {
        if let sleepDeadline { return max(0, sleepDeadline.timeIntervalSinceNow) }
        return sleepPausedRemaining
    }

    /// Wird für jedes gehörte Stück aufgerufen, spätestens alle zehn Sekunden.
    @ObservationIgnored public var onHeard: ((MediaTimeRange, MediaVersionID) -> Void)?
    /// Wird am Ende einer Folge aufgerufen.
    @ObservationIgnored public var onFinished: ((Episode) -> Void)?
    /// Wird aufgerufen, bevor die Folge Ton startet, egal über welchen Weg.
    /// Das Modell beendet hier einen Fokus-Plan, damit nie beide klingen.
    @ObservationIgnored public var onWillResume: (() -> Void)?
    /// Die Steuerung eines Fokus-Plans. Solange `current` etwas liefert,
    /// gehen Sperrbildschirm und Kopfhörertasten an den Plan.
    @ObservationIgnored public var focusRemote: FocusRemote?

    /// Was ein Fokus-Plan am Sperrbildschirm zeigt.
    public struct FocusNowPlaying {
        public var title: String
        public var artist: String
        public var album: String
        public var isPlaying: Bool

        public init(title: String, artist: String, album: String, isPlaying: Bool) {
            self.title = title; self.artist = artist; self.album = album; self.isPlaying = isPlaying
        }
    }

    /// Wie Sperrbildschirm und Kopfhörer einen Fokus-Plan bedienen.
    /// `current` liefert `nil`, solange kein Plan besteht.
    public struct FocusRemote {
        public var current: @MainActor () -> FocusNowPlaying?
        public var pause: @MainActor () -> Void
        public var resume: @MainActor () -> Void

        public init(current: @escaping @MainActor () -> FocusNowPlaying?,
                    pause: @escaping @MainActor () -> Void,
                    resume: @escaping @MainActor () -> Void) {
            self.current = current; self.pause = pause; self.resume = resume
        }
    }

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
    /// Die zuletzt geladene Adresse. Nach einem Fehler wird sie neu geladen.
    @ObservationIgnored private var loadedURL: URL?
    /// Gewünschte Startstelle, solange die Folge noch nicht bereit ist.
    /// Ein Sprung vor `readyToPlay` verpufft, und die Folge lief dann
    /// irgendwo statt an der gewünschten Stelle.
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var resumeWhenReady = false
    /// Die Folge ist bis zum Ende gelaufen. Wer dann auf Abspielen drückt,
    /// meint den Anfang und nicht die letzte Sekunde.
    @ObservationIgnored private var reachedEnd = false
    /// Das Kapitel, das zuletzt am Sperrbildschirm stand.
    @ObservationIgnored private var nowPlayingChapterStart: Double?
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
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            // Der Zustand wird beim Eintreffen frisch gelesen. Ein verspäteter
            // Wert könnte sonst eine gerade fortgesetzte Folge als pausiert führen.
            Task { @MainActor in self?.controlStatusChanged() }
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
        let sameEpisode = self.episode?.id == episode.id
        // Nach einem Fehler hilft nur neu laden. Ein fehlgeschlagenes Element
        // bleibt stumm, auch wenn man es erneut startet.
        if sameEpisode, playbackError == nil, !needsReload {
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
        if !sameEpisode {
            // Das Kapitelende gehörte zur alten Folge.
            if sleepTimer == .endOfChapter { setSleepTimer(nil) }
            self.episode = episode
            chapters = episode.publisherChapters
            duration = episode.declaredDuration?.seconds ?? 0
        }
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

    /// Vergisst die gemerkten Stellen gelöschter Folgen. Sonst bietet eine
    /// neu abonnierte Quelle „Weiter ab …“ an, obwohl der Hörstand gelöscht ist.
    public func forgetPositions(for episodeIDs: [EpisodeID]) {
        var changed = false
        for id in episodeIDs where positions.removeValue(forKey: id.rawValue) != nil { changed = true }
        if changed { UserDefaults.standard.set(positions, forKey: positionsKey) }
    }

    private func savePosition() {
        guard let episode, currentTime > 5 else { return }
        // Fast zu Ende heisst: beim nächsten Mal wieder von vorn.
        let value = duration > 0 && currentTime > duration - 15 ? 0 : currentTime
        positions[episode.id.rawValue] = value
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    /// Das geladene Element ist unbrauchbar und muss neu geladen werden.
    private var needsReload: Bool {
        // Nach einer Meldung (auch vom Wächter für hängende Wiedergabe) lädt
        // erneutes Abspielen neu, statt das hängende Element weiter zu nutzen.
        player.currentItem == nil || player.currentItem?.status == .failed || playbackError != nil
    }

    private func load(_ url: URL, isLocal: Bool) {
        playbackError = nil
        usingLocalFile = isLocal
        loadedURL = url
        reachedEnd = false
        let item = AVPlayerItem(asset: PlayableAsset.make(url: url))
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        // `.initial`, damit ein Element, das schon bereit ist, bevor die
        // Beobachtung steht, nicht übersehen wird.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, message: message, item: item) }
        }
        // Wächter: Bleibt das Element hängen, etwa weil die Audioausgabe des
        // Systems nicht reagiert, wechselt die Folge auf den Stream. Hilft auch
        // das nicht, steht eine Meldung da statt einer stummen Pause-Taste.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.player.currentItem === item, item.status == .unknown,
                  self.resumeWhenReady else { return }
            if isLocal, let stream = self.episode?.audioURL {
                self.pendingStart = self.pendingStart ?? self.currentTime
                self.load(stream, isLocal: false)
            } else {
                self.resumeWhenReady = false
                self.isBuffering = false
                self.playbackError = "Die Wiedergabe startet nicht. Prüfe die Audioausgabe und das Netz, "
                    + "dann tippe erneut auf Abspielen."
                self.updateNowPlaying()
            }
        }
        Task { [weak self] in
            guard let loaded = try? await item.asset.load(.duration),
                  loaded.seconds.isFinite, loaded.seconds > 0 else { return }
            // Ein später Wert eines abgelösten Elements gehört zu einer
            // anderen Folge und darf die Dauer der laufenden nicht ersetzen.
            guard let self, self.player.currentItem === item else { return }
            self.duration = loaded.seconds
            self.updateNowPlaying()
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        if status == .readyToPlay {
            // Kommt ein langsamer Stream doch noch, gilt die Meldung des Wächters nicht mehr.
            playbackError = nil
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
            // Eine noch ausstehende Startstelle bleibt gültig. Die Anzeige kann
            // inzwischen auf 0 stehen, weil das Element nie bereit war.
            pendingStart = pendingStart ?? currentTime
            resumeWhenReady = isPlaying || resumeWhenReady
            load(stream, isLocal: false)
            return
        }
        isPlaying = false
        isBuffering = false
        resumeWhenReady = false
        pendingStart = nil
        suspendSleepCountdown()
        playbackError = "Die Folge lässt sich nicht abspielen. "
            + (message.map { "Grund: \($0)" } ?? "Der Server liefert kein abspielbares Audio.")
        updateNowPlaying()
    }

    private func controlStatusChanged() {
        let status = player.timeControlStatus
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        // Das System hat angehalten: Anruf, Siri, Kopfhörer gezogen. Dann gilt
        // die Folge als pausiert, sonst zeigt die Taste weiter „Pause“ und
        // braucht zwei Anläufe. Ein Fehler des Elements behandelt
        // `itemStatusChanged`.
        guard status == .paused, isPlaying, player.currentItem?.status == .readyToPlay else { return }
        let now = player.currentTime().seconds
        if now.isFinite, !seekInFlight, pendingStart == nil { currentTime = now }
        enterPaused()
    }

    public func setChapters(_ chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        self.chapters = chapters
        updateNowPlaying()
    }

    public func resume() {
        guard let episode else { return }
        onWillResume?()
        if needsReload {
            // Nach einem Fehler neu laden, an der zuletzt gezeigten Stelle.
            guard let url = loadedURL ?? episode.audioURL else { return }
            pendingStart = pendingStart ?? currentTime
            resumeWhenReady = true
            load(url, isLocal: url == loadedURL && usingLocalFile)
            updateNowPlaying()
            return
        }
        if reachedEnd { seek(to: 0) }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.playImmediately(atRate: rate)
        isPlaying = true
        heardStart = currentTime
        if let remaining = sleepPausedRemaining {
            sleepPausedRemaining = nil
            sleepDeadline = Date().addingTimeInterval(remaining)
        }
        updateNowPlaying()
    }

    public func pause() {
        resumeWhenReady = false
        player.pause()
        enterPaused()
    }

    /// Was zu jeder Pause gehört, ob der Nutzer oder das System angehalten hat.
    private func enterPaused() {
        flushHeard()
        savePosition()
        isPlaying = false
        heardStart = nil
        suspendSleepCountdown()
        updateNowPlaying()
    }

    public func togglePlayPause() { isPlaying ? pause() : resume() }

    /// Abspielen oder Pause für das, was gerade den Ton besitzt: den
    /// Fokus-Plan, solange einer besteht, sonst die Folge. Kopfhörer,
    /// Sperrbildschirm und das Menü auf dem Mac gehen alle hier durch und
    /// entscheiden deshalb gleich.
    public func toggleActivePlayback() {
        if let focus = activeFocus {
            // `isPlaying` folgt dem Koordinator, der auch Pausen des Systems
            // mitbekommt. Ein Abschnitt in Vorbereitung zählt als laufend.
            if focus.info.isPlaying { focus.remote.pause() } else { focus.remote.resume() }
        } else {
            togglePlayPause()
        }
    }

    // MARK: - Schlaf-Timer

    public func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        sleepDeadline = nil
        sleepPausedRemaining = nil
        sleepChapterAnchor = nil
        switch timer {
        case .minutes(let value):
            let seconds = TimeInterval(value * 60)
            if isPlaying {
                sleepDeadline = Date().addingTimeInterval(seconds)
            } else {
                sleepPausedRemaining = seconds
            }
        case .endOfChapter:
            sleepChapterAnchor = currentTime
        case .endOfEpisode, nil:
            break
        }
    }

    /// Setzt einen Timer mit seiner Restzeit wieder ein, etwa nachdem die
    /// Folge neu geladen wurde. `stop()` räumt den Timer sonst ab, und wer
    /// eingeschlafen ist, hört die ganze Nacht weiter.
    public func restoreSleepTimer(_ timer: SleepTimer?, remaining: TimeInterval?) {
        setSleepTimer(timer)
        guard case .minutes = timer, let remaining else { return }
        if isPlaying {
            sleepDeadline = Date().addingTimeInterval(remaining)
        } else {
            // Die Folge lädt noch. `resume()` macht daraus die Frist.
            sleepPausedRemaining = remaining
        }
    }

    /// Hält den Minuten-Timer an. Beim Fortsetzen läuft er mit der Restzeit weiter.
    private func suspendSleepCountdown() {
        guard let deadline = sleepDeadline else { return }
        sleepDeadline = nil
        sleepPausedRemaining = max(0, deadline.timeIntervalSinceNow)
    }

    /// Wo das Kapitel endet, in dem `position` liegt. `nil` im letzten
    /// Kapitel: das endet mit der Folge. Die Toleranz passt zu `currentChapter`.
    private func chapterEnd(containing position: Double) -> Double? {
        chapters.map(\.start.seconds).filter { $0 > position + 0.5 }.min()
    }

    private func checkSleepTimer() {
        guard isPlaying, let timer = sleepTimer else { return }
        let due: Bool = switch timer {
        case .minutes:
            sleepDeadline.map { Date() >= $0 } ?? false
        case .endOfChapter:
            // Die Grenze gilt auch dann, wenn ein Tick sie knapp übersprungen hat.
            sleepChapterAnchor.flatMap { chapterEnd(containing: $0) }.map { currentTime >= $0 - 0.5 } ?? false
        case .endOfEpisode:
            false
        }
        if due {
            pause()
            setSleepTimer(nil)
        }
    }

    // MARK: - Springen

    public func seek(to seconds: Double) {
        flushHeard()
        reachedEnd = false
        let target: Double
        if player.currentItem?.status != .readyToPlay {
            // Vor `readyToPlay` verpufft ein Sprung. Dann wird er gemerkt.
            target = max(0, seconds)
            pendingStart = target
        } else {
            target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
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
        }
        currentTime = target
        if isPlaying { heardStart = target }
        // Wer springt, meint das Kapitel an der neuen Stelle.
        if sleepTimer == .endOfChapter { sleepChapterAnchor = target }
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
        resumeWhenReady = false
        pendingStart = nil
        heardStart = nil
        setSleepTimer(nil)
        episode = nil
        chapters = []
        currentTime = 0
        // Ohne Folge räumt das den Sperrbildschirm, bei einem Fokus-Plan zeigt es ihn.
        updateNowPlaying()
    }

    // MARK: - Hörzustand

    private func tick(_ seconds: Double) {
        // Solange eine Startstelle aussteht, meldet der Beobachter noch die
        // Zeit eines Elements, das nicht bereit ist, oft 0.
        guard seconds.isFinite, !seekInFlight, pendingStart == nil else { return }
        currentTime = seconds
        if currentChapter?.start.seconds != nowPlayingChapterStart { updateNowPlaying() }
        checkSleepTimer()
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
        let end = player.currentTime().seconds
        if end.isFinite, !seekInFlight, pendingStart == nil { currentTime = end }
        flushHeard()
        heardStart = nil
        isPlaying = false
        reachedEnd = true
        suspendSleepCountdown()
        if let episode {
            positions[episode.id.rawValue] = 0
            UserDefaults.standard.set(positions, forKey: positionsKey)
        }
        // „Ende der Folge“ hält hier an. Ein Kapitel-Timer auch: sein Kapitel
        // endet mit der Folge. In beiden Fällen startet nichts aus „Als Nächstes“.
        if sleepTimer == .endOfEpisode || sleepTimer == .endOfChapter {
            setSleepTimer(nil)
            updateNowPlaying()
            return
        }
        updateNowPlaying()
        if let episode { onFinished?(episode) }
    }

    // MARK: - Sperrbildschirm und Kopfhörertasten

    /// Aktualisiert den Sperrbildschirm, etwa nach einem Wechsel im Fokus-Plan.
    public func refreshNowPlaying() { updateNowPlaying() }

    private func updateNowPlaying() {
        nowPlayingChapterStart = currentChapter?.start.seconds
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        let focus = focusRemote?.current()
        setSeekCommandsEnabled(focus == nil)
        if let focus {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: focus.title,
                MPMediaItemPropertyArtist: focus.artist,
                MPMediaItemPropertyAlbumTitle: focus.album,
                MPNowPlayingInfoPropertyPlaybackRate: focus.isPlaying ? 1.0 : 0.0,
            ]
            #if os(macOS)
            center.playbackState = focus.isPlaying ? .playing : .paused
            #endif
            return
        }
        guard let episode else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let chapter = currentChapter { info[MPMediaItemPropertyAlbumTitle] = chapter.title }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
        #endif
    }

    /// Der Fokus-Plan, sofern er gerade Sperrbildschirm und Tasten besitzt.
    private var activeFocus: (remote: FocusRemote, info: FocusNowPlaying)? {
        guard let focusRemote, let info = focusRemote.current() else { return nil }
        return (focusRemote, info)
    }

    private func remotePlay() {
        if let focus = activeFocus { focus.remote.resume() } else { resume() }
    }

    private func remotePause() {
        if let focus = activeFocus { focus.remote.pause() } else { pause() }
    }

    /// Springen gilt nur für die Folge. Ein Fokus-Plan hat feste Stellen.
    private func remoteSeek(to seconds: Double) -> Bool {
        guard activeFocus == nil, episode != nil else { return false }
        seek(to: seconds)
        return true
    }

    #if canImport(MediaPlayer)
    private func setSeekCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
    }
    #endif

    private func configureRemoteCommands() {
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remotePlay() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remotePause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleActivePlayback() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.remoteSeek(to: self.currentTime + 30)
            }
            return handled ? .success : .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.remoteSeek(to: self.currentTime - 15)
            }
            return handled ? .success : .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            let handled = MainActor.assumeIsolated { self?.remoteSeek(to: position) ?? false }
            return handled ? .success : .commandFailed
        }
        #endif
    }
}

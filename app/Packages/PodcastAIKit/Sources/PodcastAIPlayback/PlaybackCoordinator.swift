//
//  PlaybackCoordinator.swift
//  PodcastAIPlayback
//
//  Der einzige Tonpfad der App. Alles, was klingt, geht hier durch.
//
//  Die Fallen, die ein segmentgenauer Player stellt, und wie sie hier
//  behandelt werden:
//
//  1. Ein Zeitbeobachter ist **kein** Sicherheitsendanschlag. Er feuert in
//     Intervallen und kann eine Grenze überspringen — bei doppelter
//     Geschwindigkeit doppelt so leicht. Deshalb ist
//     `forwardPlaybackEndTime` die eigentliche Grenze; der Beobachter dient
//     nur der Anzeige und als zweite Sicherung.
//
//  2. Callbacks kommen verspätet. Ein Sprung zur nächsten Quelle kann
//     eintreffen, nachdem der Nutzer längst gestoppt hat. Jede Session
//     trägt deshalb ein Token; ein Callback mit altem Token wird verworfen.
//
//  3. `seek` ist nicht exakt, wenn man ihn nicht dazu zwingt. Ohne
//     `toleranceBefore`/`toleranceAfter` auf `.zero` landet man irgendwo in
//     der Nähe — und „irgendwo in der Nähe“ ist bei einem Zitat falsch.
//
//  4. Wiedergabe startet erst, wenn der Sprung bestätigt ist. Sonst hört
//     man die Sekunden vor der Stelle.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PodcastAICore
import PodcastAIMedia

public enum PlaybackState: Sendable, Equatable {
    case idle
    case preparing(segmentIndex: Int)
    case playing(segmentIndex: Int)
    case paused(segmentIndex: Int)
    case finished
    case failed(String)
}

/// Was der Koordinator nach außen meldet.
///
/// `@MainActor`, weil der Koordinator es ist: diese Rückmeldungen kommen aus
/// Player-Callbacks und gehen direkt in die Oberfläche und in den
/// Hörzustand. Sie über eine Actor-Grenze zu schicken würde nur Latenz
/// erzeugen, wo Genauigkeit gebraucht wird.
@MainActor
public protocol PlaybackObserver: AnyObject {
    func playbackStateChanged(_ state: PlaybackState)
    /// Fortschritt in der Zeitachse des Plans — für Anzeige und Hörhistorie.
    func playbackProgressed(segmentIndex: Int, position: MediaTime)
    /// Ein Abschnitt wurde vollständig gehört. Erzeugt das Ledger-Ereignis.
    func segmentCompleted(segmentIndex: Int, heard: MediaTimeRange, mediaVersionID: MediaVersionID)
    /// Die Quelle wechselt. Für den sichtbaren Hinweis und optionale Haptik.
    func willChangeSource(to segment: PlanSegment)
}

/// Liefert die abspielbare Adresse einer Medienfassung.
public protocol MediaLocating: Sendable {
    func playbackURL(for mediaVersionID: MediaVersionID) -> URL?
}

@MainActor
public final class PlaybackCoordinator {

    public private(set) var state: PlaybackState = .idle
    public private(set) var activePlan: ValidatedPlaybackPlan?

    private let player: AVQueuePlayer
    private let locator: any MediaLocating
    private weak var observer: (any PlaybackObserver)?

    private var segmentIndex = 0
    private let observers: PlayerObservers

    /// Kennzeichnet die laufende Sitzung. Jeder Start erhöht sie; jeder
    /// Callback prüft sie. Damit können verspätete Ereignisse einer
    /// beendeten Sitzung nichts mehr auslösen.
    private var sessionToken = 0

    /// Bereits eingelöste Freigaben. Eine Freigabe gilt genau einmal —
    /// ein zweiter Aufruf mit demselben Nonce startet nichts.
    private var consumedGrants: Set<String> = []

    /// Der Zustand der normalen Warteschlange vor einer Fokus-Sitzung.
    /// Nach dem Ende wird er wiederhergestellt, statt den Nutzer
    /// irgendwo zurückzulassen.
    private var queueSnapshot: QueueSnapshot?

    public struct QueueSnapshot: Sendable {
        public let mediaVersionID: MediaVersionID
        public let position: MediaTime
        public let wasPlaying: Bool
    }

    public init(locator: any MediaLocating, observer: (any PlaybackObserver)? = nil) {
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .pause
        self.player = player
        self.observers = PlayerObservers(player: player)
        self.locator = locator
        self.observer = observer
    }

    /// Nachträglich setzen, weil der Beobachter den Koordinator meist selbst
    /// besitzt und sich deshalb nicht vor ihm bauen lässt.
    public func setObserver(_ observer: any PlaybackObserver) {
        self.observer = observer
    }

    // MARK: - Start

    public enum StartRefusal: Error, LocalizedError {
        case grantInvalid
        case grantAlreadyUsed
        case planEmpty
        case mediaUnavailable(MediaVersionID)

        public var errorDescription: String? {
            switch self {
            case .grantInvalid: "Die Wiedergabefreigabe ist nicht mehr gültig."
            case .grantAlreadyUsed: "Diese Wiedergabefreigabe wurde bereits verwendet."
            case .planEmpty: "Der Hörplan enthält keine abspielbaren Stellen."
            case .mediaUnavailable: "Das Medium ist derzeit nicht verfügbar."
            }
        }
    }

    /// Der **einzige** Weg, Ton zu starten.
    ///
    /// Ohne gültige, noch nicht eingelöste Freigabe passiert nichts. Ein
    /// Modell, ein Feed-Refresh oder ein Sync-Ereignis kann hier nicht
    /// hineinkommen, weil keiner von ihnen eine Freigabe ausstellen kann.
    @discardableResult
    public func start(
        plan: ValidatedPlaybackPlan,
        grant: PlaybackGrant,
        deviceID: String,
        snapshot: QueueSnapshot? = nil
    ) throws -> Int {

        guard !plan.isEmpty else { throw StartRefusal.planEmpty }
        guard grant.isValid(for: plan, on: deviceID) else { throw StartRefusal.grantInvalid }
        guard consumedGrants.insert(grant.nonce).inserted else { throw StartRefusal.grantAlreadyUsed }

        queueSnapshot = snapshot
        activePlan = plan
        segmentIndex = 0
        sessionToken += 1
        try playSegment(at: 0, token: sessionToken)
        return sessionToken
    }

    // MARK: - Abschnittswiedergabe

    private func playSegment(at index: Int, token: Int) throws {
        guard token == sessionToken else { return }          // verspäteter Aufruf
        guard let plan = activePlan, index < plan.segments.count else {
            finish(token: token)
            return
        }

        let segment = plan.segments[index]
        guard let url = locator.playbackURL(for: segment.mediaVersionID) else {
            throw StartRefusal.mediaUnavailable(segment.mediaVersionID)
        }

        segmentIndex = index
        setState(.preparing(segmentIndex: index))
        if index > 0 { observer?.willChangeSource(to: segment) }

        let item = AVPlayerItem(url: url)
        // Die eigentliche Grenze. Der Player stoppt hier von sich aus —
        // unabhängig davon, ob ein Zeitbeobachter rechtzeitig feuert.
        item.forwardPlaybackEndTime = segment.range.end.cmTime

        teardownObservers()
        player.removeAllItems()
        player.insert(item, after: nil)

        installEndObserver(for: item, token: token)
        installTimeObserver(for: segment, token: token)

        // Exakt springen: ohne Nulltoleranz landet man „in der Nähe“, und
        // das ist bei einem Zitat der falsche Satz.
        item.seek(to: segment.range.start.cmTime,
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, token == self.sessionToken else { return }
                guard finished else {
                    self.setState(.failed("Der Sprung zur Stelle ist fehlgeschlagen."))
                    return
                }
                // Erst nach bestätigtem Sprung abspielen. Sonst hört man die
                // Sekunden davor.
                self.player.play()
                self.setState(.playing(segmentIndex: index))
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem, token: Int) {
        let registration = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, token == self.sessionToken else { return }
                self.completeCurrentSegment(token: token, reachedEnd: true)
            }
        }
        observers.replaceEnd(registration)
    }

    private func installTimeObserver(for segment: PlanSegment, token: Int) {
        // Nur für Anzeige und als zweite Sicherung. Die Grenze selbst hängt
        // nicht an diesem Intervall.
        let interval = CMTime(value: 1, timescale: 4)
        let handle = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            Task { @MainActor in
                guard let self, token == self.sessionToken else { return }
                let position = MediaTime(time)
                self.observer?.playbackProgressed(segmentIndex: self.segmentIndex, position: position)

                // Zweite Sicherung: sollte forwardPlaybackEndTime einmal nicht
                // greifen, wird hier trotzdem beendet.
                if position >= segment.range.end {
                    self.completeCurrentSegment(token: token, reachedEnd: true)
                }
            }
        }
        observers.replaceTime(handle)
    }

    private func completeCurrentSegment(token: Int, reachedEnd: Bool) {
        guard token == sessionToken, let plan = activePlan,
              segmentIndex < plan.segments.count else { return }

        let segment = plan.segments[segmentIndex]
        let heardEnd = reachedEnd ? segment.range.end : MediaTime(player.currentTime())
        let heard = MediaTimeRange(start: segment.range.start, end: heardEnd)

        teardownObservers()
        observer?.segmentCompleted(segmentIndex: segmentIndex, heard: heard,
                                   mediaVersionID: segment.mediaVersionID)

        let next = segmentIndex + 1
        if next < plan.segments.count {
            // Innerhalb einer bewusst gestarteten Sitzung darf der nächste
            // Abschnitt ohne erneute Bestätigung folgen — das ist der Sinn
            // einer Fokus-Sitzung. Die Sitzung selbst wurde freigegeben.
            try? playSegment(at: next, token: token)
        } else {
            finish(token: token)
        }
    }

    // MARK: - Steuerung

    public func pause() {
        player.pause()
        if case .playing(let index) = state { setState(.paused(segmentIndex: index)) }
    }

    public func resume() {
        guard case .paused(let index) = state else { return }
        player.play()
        setState(.playing(segmentIndex: index))
    }

    /// Überspringt den laufenden Abschnitt. Das Übersprungene zählt
    /// ausdrücklich **nicht** als gehört.
    public func skipSegment() {
        let token = sessionToken
        guard let plan = activePlan, segmentIndex < plan.segments.count else { return }
        let segment = plan.segments[segmentIndex]
        let position = MediaTime(player.currentTime())

        teardownObservers()
        // Nur der tatsächlich abgespielte Teil gilt als gehört.
        if position > segment.range.start {
            observer?.segmentCompleted(
                segmentIndex: segmentIndex,
                heard: MediaTimeRange(start: segment.range.start, end: position),
                mediaVersionID: segment.mediaVersionID
            )
        }
        let next = segmentIndex + 1
        if next < plan.segments.count {
            try? playSegment(at: next, token: token)
        } else {
            finish(token: token)
        }
    }

    /// Bricht ab und stellt die vorherige Warteschlange wieder her.
    public func stop() {
        let token = sessionToken
        if case .playing = state { completeCurrentSegment(token: token, reachedEnd: false) }
        sessionToken += 1                                   // alle Callbacks entwerten
        teardownObservers()
        player.pause()
        player.removeAllItems()
        activePlan = nil
        setState(.idle)
        restoreQueueSnapshot()
    }

    /// Springt aus dem Plan in die vollständige Originalfolge an dieser Stelle.
    /// Erzeugt einen neuen Plan und braucht deshalb eine neue Freigabe —
    /// der Wechsel ist eine Nutzeraktion.
    public func currentOriginalPosition() -> (MediaVersionID, MediaTime)? {
        guard let plan = activePlan, segmentIndex < plan.segments.count else { return nil }
        return (plan.segments[segmentIndex].mediaVersionID, MediaTime(player.currentTime()))
    }

    // MARK: - Intern

    private func finish(token: Int) {
        guard token == sessionToken else { return }
        teardownObservers()
        player.pause()
        player.removeAllItems()
        activePlan = nil
        setState(.finished)
        restoreQueueSnapshot()
    }

    private func restoreQueueSnapshot() {
        guard let snapshot = queueSnapshot else { return }
        queueSnapshot = nil
        // Die Wiederherstellung ist absichtlich nur eine Zustandsmeldung:
        // Ton startet danach nur, wenn der Nutzer es will.
        observer?.playbackProgressed(segmentIndex: -1, position: snapshot.position)
    }

    private func teardownObservers() {
        observers.removeAll()
    }

    private func setState(_ new: PlaybackState) {
        state = new
        observer?.playbackStateChanged(new)
    }

}

/// Hält die Beobachter-Token außerhalb der Actor-Isolation.
///
/// Der vorige `deinit` griff auf `timeObserver`, `endObserver` und `player`
/// zu — Eigenschaften einer `@MainActor`-Klasse. In Swift 6 ist `deinit`
/// nicht isoliert, und das ist kein Formfehler, sondern die Stelle, an der
/// der Build stehen bleibt.
///
/// Abmelden muss trotzdem jemand: ein periodischer Beobachter hält den
/// Spieler am Leben, und eine nicht abgemeldete Benachrichtigung feuert in
/// ein totes Objekt. Deshalb liegen die Token hier, in einem Objekt ohne
/// Isolation — sein `deinit` darf aufräumen.
///
/// Der reguläre Weg bleibt `teardownObservers()` beim Wechsel eines
/// Segments; dieser `deinit` ist die Sicherung für den Fall, dass der
/// Koordinator ohne Aufräumen verschwindet.
private final class PlayerObservers: @unchecked Sendable {

    private let player: AVQueuePlayer
    /// `@unchecked` ist hier keine Behauptung ins Blaue: die Token werden vom
    /// Hauptthread gesetzt und können im `deinit` von einem beliebigen Thread
    /// gelesen werden, und genau dieser Zugriff läuft über das Schloss.
    private let lock = NSLock()
    private var time: Any?
    private var end: (any NSObjectProtocol)?

    init(player: AVQueuePlayer) { self.player = player }

    func replaceTime(_ token: Any?) {
        lock.lock()
        let previous = time
        time = token
        lock.unlock()
        if let previous { player.removeTimeObserver(previous) }
    }

    func replaceEnd(_ token: (any NSObjectProtocol)?) {
        lock.lock()
        let previous = end
        end = token
        lock.unlock()
        if let previous { NotificationCenter.default.removeObserver(previous) }
    }

    func removeAll() {
        replaceTime(nil)
        replaceEnd(nil)
    }

    deinit { removeAll() }
}
#endif

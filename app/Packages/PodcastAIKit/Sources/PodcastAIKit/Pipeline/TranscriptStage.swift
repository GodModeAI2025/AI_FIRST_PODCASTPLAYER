//
//  TranscriptStage.swift
//  PodcastAIKit
//
//  Die Stufe „Transkript“: Ton, Transkript des Podcasts, Zwilling und
//  Untertitel über Supadata, eine Folge nach der anderen
//  (docs/plan-pipeline.md, Schritt 5b). Bis 0.13 lag das im `AppModel`:
//  `analysisQueue`, `analyzing`, der Worker `startAnalysisWorker` und die
//  Vermerke `automaticallyQueued` und `backlogQueued`. Die Stufe übernimmt
//  Warteschlange, Reihenfolge, den einen Platz, das Tor, das Merken über
//  einen Neustart und die Ereignisse. Die Regeln sind dieselben:
//
//  - Von Hand Angefordertes vor alles, was die App von selbst eingereiht
//    hat, neue Folgen vor die älteren aus „Ältere Folgen auch vorbereiten“,
//    diese ans Ende.
//  - Transkripte beginnen nur vorn. Einmal begonnen, trägt die fortgesetzte
//    Verarbeitung die Warteschlange auch im Hintergrund weiter, bis sie
//    leer ist oder die Zeit des Systems endet. Pause und „Alle abbrechen“
//    halten die laufende Folge an; sie steht dann wieder vorn.
//  - Scheitert eine Folge an etwas, das vorbeigeht, kommt sie einmal an
//    ihren Platz zurück, nach drei Sekunden Luft. Danach erst beim nächsten
//    Anlass.
//  - Die Warteschlange steht im bisherigen Format (`AnalysisQueueSnapshot`)
//    in den Benutzereinstellungen. 0.13 liest sie weiter. Neu kommen auch
//    Videos mit Untertiteln zurück.
//
//  Der Store ist die Wahrheit: Vor dem Start fragt die Stufe, ob die
//  Fassung schon Belege hat (Vertrag (I)); hat ein anderes Gerät die Folge
//  schon transkribiert, fällt sie still heraus. Über das Schreiben wacht der
//  Wächter im Store. Erst wenn es zurückgekehrt ist, gehen
//  `transcriptSaved` und `evidenceReady` hinaus, mit der Herkunft, die beim
//  Ende gilt: Wer „Transkript jetzt erstellen“ während des Laufs antippt,
//  macht daraus eine Anforderung von Hand.
//
//  Befehle kommen über `submit(_:)` in der Reihenfolge, in der der
//  Hauptakteur sie schickt. Die Arbeit an einer Folge (`Environment.transcribe`)
//  läuft noch auf dem Hauptakteur, wie in Schritt 3a bei der Stufe „Wissen“:
//  Sie liest Netz, Abos, Schalter und schreibt, was die Oberfläche zeigt.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

/// Eine Folge in der Warteschlange der Transkripte und wer sie wollte.
public struct TranscriptQueueItem: Sendable, Equatable {
    public let episode: Episode
    public let origin: Origin

    public init(episode: Episode, origin: Origin) {
        self.episode = episode
        self.origin = origin
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episode.id == rhs.episode.id && lhs.origin == rhs.origin
    }
}

/// Die Arbeit an einer Folge.
public struct TranscriptJob: Sendable {
    public let episode: Episode
    /// Wer die Folge beim Start wollte.
    public let origin: Origin
    /// Stand des Löschprotokolls beim Start. Wird die Folge danach gelöscht,
    /// bleibt nichts von ihr zurück.
    public let ticket: RemovalLedger.Ticket
    /// Wie viele Folgen danach noch warten, für die Zeile „danach noch 3 Folgen“.
    public let remaining: Int
    /// Wer die Folge jetzt will. Kann sich während des Laufs ändern.
    public let currentOrigin: @Sendable () async -> Origin

    public init(episode: Episode, origin: Origin, ticket: RemovalLedger.Ticket, remaining: Int,
                currentOrigin: @escaping @Sendable () async -> Origin) {
        self.episode = episode
        self.origin = origin
        self.ticket = ticket
        self.remaining = remaining
        self.currentOrigin = currentOrigin
    }
}

/// Wie die Arbeit an einer Folge ausging.
public enum TranscriptJobOutcome: Sendable, Equatable {
    /// Transkript und Belege liegen im Store, an dieser Fassung.
    case transcribed(MediaVersionID)
    /// Gescheitert. `retry`: Der Fehler geht vorbei, ein zweiter Versuch lohnt.
    case failed(TranscriptFailure, retry: Bool)
    /// Angehalten, etwa weil die Zeit im Hintergrund endete. Die Folge
    /// steht wieder vorn und setzt an ihrem Zwischenstand an.
    case interrupted
    /// Überholt, gelöscht oder nicht mehr möglich. Die Folge geht still.
    case dropped

    /// Kam dabei ein Ereignis heraus, auf das andere Stufen hören?
    public var announces: Bool {
        switch self {
        case .transcribed, .failed: true
        case .interrupted, .dropped: false
        }
    }
}

/// Was die Stufe dem Hauptakteur nach einer Folge meldet, damit die
/// Oberfläche und die Vermerke dieses Geräts stimmen.
public enum TranscriptSettlement: Sendable, Equatable {
    /// Wartet auf den zweiten Versuch.
    case retrying(EpisodeID)
    /// Eine ältere Folge ist zweimal kurz gescheitert: in diesem Start nicht wieder.
    case gaveUpBacklog(EpisodeID)
    /// Eine ältere Folge ist durch. `announced`: mit `evidenceReady` oder
    /// `transcriptFailed`, auf die „Vorbereiten“ selbst hört.
    case backlogFinished(SourceID, announced: Bool)
    /// Folgen desselben Podcasts, deren Sprache es kein Modell gibt. Sie
    /// fallen heraus und gelten als gescheitert.
    case preparationFailed([EpisodeID])
    /// Von selbst Eingereihtes fällt heraus, weil das Gerät nicht transkribieren kann.
    case droppedAutomatic([EpisodeID])
    /// Die Fassung hatte laut Store schon Belege, etwa von einem anderen Gerät.
    case alreadyTranscribed(EpisodeID)
}

/// Was „Alle abbrechen“ aus der Warteschlange genommen hat, die laufende
/// Folge vorn.
public struct TranscriptCancellation: Sendable {
    public let removed: [TranscriptQueueItem]
    /// Von selbst Eingereihtes, das bis zum nächsten Aktualisieren von Hand ruht.
    public let resting: Set<EpisodeID>
}

/// Der Stand der Stufe für die Oberfläche. Die Senke schreibt daraus
/// `analysisQueue`, `analyzing` und die Vermerke der Herkunft.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var queue: [TranscriptQueueItem]
    public var running: TranscriptQueueItem?

    public init(queue: [TranscriptQueueItem] = [], running: TranscriptQueueItem? = nil) {
        self.queue = queue
        self.running = running
    }
}

/// Ein Befehl an die Stufe. Befehle kommen in der Reihenfolge an, in der
/// sie geschickt wurden.
public enum TranscriptCommand: Sendable {
    /// Von selbst eingereiht (`.automatic`, `.backlog`). Wartet oder läuft
    /// die Folge schon, bleibt es, wie es ist.
    case enqueue(Episode, Origin)
    /// Von Hand angefordert: nach vorn, oder die laufende Folge gilt ab
    /// jetzt als angefordert.
    case request(Episode)
    /// Von Hand eingereiht und wartet auf die Zustimmung zu Mobilfunk: nach vorn.
    case moveToFront(EpisodeID)
    /// Diese Folgen gehen aus der Warteschlange. `onlyAutomatic`: nur, was
    /// die App von selbst eingereiht hat.
    case drop(Set<EpisodeID>, onlyAutomatic: Bool)
    /// Die Reihenfolge, die jemand in der Liste gezogen hat.
    case reorder([EpisodeID])
    /// Netz, Zustimmung, eine Datei oder ein Sprachmodell hat sich geändert.
    case conditionsChanged
    /// Die Zeit im Hintergrund endet: Die laufende Folge hält an.
    case interrupt
    /// Wartet, bis alle Befehle davor angekommen sind.
    case barrier(CheckedContinuation<Void, Never>)
}

public actor TranscriptStage {

    /// Was die Stufe beim Hauptakteur fragt und ihm meldet.
    public struct Environment: Sendable {
        /// Welche dieser Folgen jetzt laufen dürfen: Netz, Zustimmung zu
        /// Mobilfunk, Ton auf dem Gerät, Sprachmodell.
        public var runnable: @Sendable ([TranscriptQueueItem]) async -> Set<EpisodeID>
        /// Eine Folge beginnt, die erste eines Laufs: Die fortgesetzte
        /// Verarbeitung meldet sich an.
        public var runStarted: @Sendable (_ title: String) async -> Void
        /// Der Lauf ist zu Ende, auch einer, in dem keine Folge laufen
        /// durfte. `cancelled`: angehalten, nicht leer gelaufen.
        public var runEnded: @Sendable (_ cancelled: Bool) async -> Void
        /// Die Arbeit an einer Folge.
        public var transcribe: @Sendable (TranscriptJob) async -> TranscriptJobOutcome
        /// Was nach einer Folge für Oberfläche und Vermerke zu tun ist.
        public var settled: @Sendable (TranscriptSettlement) async -> Void
        /// Was von der gemerkten Warteschlange zurückkommt, in ihrer
        /// Reihenfolge, nach den Regeln des Hauptakteurs (Abos, Schalter,
        /// Vermerke, Portionen).
        public var restore: @Sendable (_ entries: [AnalysisQueueSnapshot.Entry], _ episodes: [Episode]) async
            -> [TranscriptQueueItem]

        public init(
            runnable: @escaping @Sendable ([TranscriptQueueItem]) async -> Set<EpisodeID>,
            runStarted: @escaping @Sendable (String) async -> Void,
            runEnded: @escaping @Sendable (Bool) async -> Void,
            transcribe: @escaping @Sendable (TranscriptJob) async -> TranscriptJobOutcome,
            settled: @escaping @Sendable (TranscriptSettlement) async -> Void,
            restore: @escaping @Sendable ([AnalysisQueueSnapshot.Entry], [Episode]) async -> [TranscriptQueueItem]
        ) {
            self.runnable = runnable
            self.runStarted = runStarted
            self.runEnded = runEnded
            self.transcribe = transcribe
            self.settled = settled
            self.restore = restore
        }
    }

    /// Der Schlüssel in den Benutzereinstellungen, derselbe wie bis 0.13.
    public static let snapshotKey = "analysisQueueSnapshot"
    /// So lange wartet eine Folge vor ihrem zweiten Versuch.
    public static let retryPause: Duration = .seconds(3)

    /// Eine Folge in der Warteschlange.
    private struct Entry: Sendable {
        var episode: Episode
        var origin: Origin
        /// Stand des Löschprotokolls beim Einreihen. Beim Entnehmen prüft die
        /// Stufe, ob die Folge seitdem gelöscht wurde.
        var ticket: RemovalLedger.Ticket
        var id: EpisodeID { episode.id }
        var item: TranscriptQueueItem { TranscriptQueueItem(episode: episode, origin: origin) }
    }

    private var store: LibraryStore
    private let gate: WorkGate
    private let ledger: RemovalLedger
    private let host: PipelineHost?
    private let mailbox: AsyncStream<PipelineEvent>?
    private let environment: Environment
    private let defaults: UserDefaults
    private let snapshotKey: String
    private let retryPause: Duration

    private var queue: [Entry] = []
    /// Die Folge im Platz und wer sie jetzt will.
    private var running: Entry?
    /// Der laufende Lauf: eine Folge nach der anderen, bis keine mehr darf.
    private var run: Task<Void, Never>?
    /// Die Stufe hat den Lauf angehalten: Pause, „Alle abbrechen“ oder das
    /// Ende der Zeit im Hintergrund.
    private var runStopped = false
    /// Während des Laufs kam ein Anlass, etwa eine neue Folge oder ein
    /// anderes Netz. Nach dem Lauf wird dann noch einmal gefragt.
    private var runAgain = false
    /// Ist die gemerkte Warteschlange schon zurück? Vorher wird sie nicht
    /// überschrieben.
    private var restored = false
    private var persistScheduled = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeners: [Task<Void, Never>] = []
    private var started = false

    private let commandContinuation: AsyncStream<TranscriptCommand>.Continuation
    private let commands: AsyncStream<TranscriptCommand>
    private let snapshotContinuation: AsyncStream<TranscriptSnapshot>.Continuation
    private var lastSnapshot = TranscriptSnapshot()

    /// Jeder neue Stand für die Oberfläche. Wer langsam liest, bekommt nur
    /// den neuesten. Ein Leser.
    public nonisolated let snapshots: AsyncStream<TranscriptSnapshot>

    public init(
        store: LibraryStore, gate: WorkGate, ledger: RemovalLedger = .shared, host: PipelineHost?,
        environment: Environment, defaultsSuite: String? = nil,
        snapshotKey: String = TranscriptStage.snapshotKey, retryPause: Duration = TranscriptStage.retryPause
    ) {
        self.store = store
        self.gate = gate
        self.ledger = ledger
        self.host = host
        // Das Postfach öffnet sich schon hier, damit kein Ereignis zwischen
        // Anlegen und `start()` verloren geht.
        self.mailbox = host?.mailbox(for: .transcript)
        self.environment = environment
        // Die Benutzereinstellungen der App, in Tests eine eigene Ablage.
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.snapshotKey = snapshotKey
        self.retryPause = retryPause
        (commands, commandContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Hört zu: auf Befehle, das Postfach der Stufe und das Tor. Ein zweiter
    /// Aufruf tut nichts.
    public func start() {
        guard !started else { return }
        started = true
        let commands = self.commands
        listeners.append(Task(priority: .utility) { [weak self] in
            for await command in commands { await self?.handle(command) }
        })
        if let mailbox {
            listeners.append(Task(priority: .utility) { [weak self] in
                for await event in mailbox { await self?.receive(event) }
            })
        }
        let conditions = gate.updates()
        listeners.append(Task(priority: .utility) { [weak self] in
            for await next in conditions { await self?.gateChanged(next) }
        })
    }

    /// Hört auf. Für Tests.
    public func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        run?.cancel()
        started = false
    }

    /// Schickt einen Befehl. Wartet nie; die Befehle kommen in dieser
    /// Reihenfolge an.
    public nonisolated func submit(_ command: TranscriptCommand) {
        commandContinuation.yield(command)
    }

    /// Wartet, bis alle vorher geschickten Befehle angekommen sind.
    public func settleCommands() async {
        guard started else { return }
        await withCheckedContinuation { submit(.barrier($0)) }
    }

    // MARK: - Befehle

    func handle(_ command: TranscriptCommand) {
        switch command {
        case .enqueue(let episode, let origin):
            enqueue(episode, origin: origin == .user ? .automatic : origin)
        case .request(let episode):
            request(episode)
        case .moveToFront(let id):
            guard let index = queue.firstIndex(where: { $0.id == id }), queue[index].origin == .user else { return }
            queue.insert(queue.remove(at: index), at: 0)
            changed()
        case .drop(let ids, let onlyAutomatic):
            let before = queue.count
            queue.removeAll { ids.contains($0.id) && (!onlyAutomatic || $0.origin != .user) }
            if queue.count != before { changed() }
        case .reorder(let order):
            reorder(order)
        case .conditionsChanged:
            startRunIfNeeded()
        case .interrupt:
            stopRun()
        case .barrier(let continuation):
            continuation.resume()
        }
    }

    private func enqueue(_ episode: Episode, origin: Origin) {
        guard running?.id != episode.id, !queue.contains(where: { $0.id == episode.id }) else { return }
        insert(Entry(episode: episode, origin: origin, ticket: ledger.ticket))
        changed()
        startRunIfNeeded()
    }

    private func request(_ episode: Episode) {
        if running?.id == episode.id {
            // Läuft schon: Ab jetzt gilt sie als angefordert. Die Ansage und
            // die Fehlermeldung richten sich danach.
            running?.origin = .user
            changed()
            return
        }
        if let index = queue.firstIndex(where: { $0.id == episode.id }) {
            var entry = queue.remove(at: index)
            entry.origin = .user
            queue.insert(entry, at: 0)
        } else {
            insert(Entry(episode: episode, origin: .user, ticket: ledger.ticket))
        }
        changed()
        startRunIfNeeded()
    }

    /// Reiht an ihrem Platz ein: von Hand Angefordertes vor alles, was die
    /// App von selbst eingereiht hat, neue Folgen vor die älteren, diese ans Ende.
    private func insert(_ entry: Entry) {
        let index: Int? = switch entry.origin {
        case .user: queue.firstIndex { $0.origin != .user }
        case .automatic: queue.firstIndex { $0.origin == .backlog }
        case .backlog: nil
        }
        if let index { queue.insert(entry, at: index) } else { queue.append(entry) }
    }

    private func reorder(_ order: [EpisodeID]) {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = queue.enumerated().sorted { lhs, rhs in
            let left = position[lhs.element.id] ?? order.count + lhs.offset
            let right = position[rhs.element.id] ?? order.count + rhs.offset
            return left < right
        }.map(\.element)
        guard sorted.map(\.id) != queue.map(\.id) else { return }
        queue = sorted
        changed()
    }

    /// „Alle abbrechen“: Die laufende Folge hält an und stellt sich wieder
    /// vorn an; dann geht alles aus der Warteschlange. Ihr Zwischenstand
    /// bleibt. Zurück kommt, was herausging.
    public func cancelAll() async -> TranscriptCancellation {
        await settleCommands()
        stopRun()
        await untilIdle()
        let plan = AnalysisQueueControl.cancelAll(
            running: nil, queue: queue.map(\.id), automatic: Set(queue.filter { $0.origin != .user }.map(\.id)))
        let byID = Dictionary(queue.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        queue.removeAll()
        changed()
        return TranscriptCancellation(removed: plan.removed.compactMap { byID[$0] }, resting: plan.restingUntilRefresh)
    }

    /// Wartet, bis kein Lauf mehr läuft.
    public func untilIdle() async {
        guard run != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Ein anderer Speicher: Was wartete, gehörte zum alten.
    public func reset(store newStore: LibraryStore) {
        stopRun()
        store = newStore
        queue.removeAll()
        restored = false
        changed()
    }

    // MARK: - Ereignisse

    func receive(_ event: PipelineEvent) async {
        switch event {
        case .audioAvailable, .audioRemoved:
            // Worauf eine Folge wartet, hat sich geändert. Daten ändert das
            // Entfernen des Tons nicht (Regel 5).
            startRunIfNeeded()
        case .episodesRemoved(let ids, _):
            forget(Set(ids))
        case .changedElsewhere:
            // Ein anderes Gerät kann Transkripte gebracht haben. Geprüft wird
            // nur, was hier wartet, nicht die ganze Bibliothek.
            await reconcile()
        case .episodesAdded, .transcriptSaved, .transcriptFailed, .evidenceReady, .transcriptsIdle, .factsDone,
             .tagsDone, .feedsRefreshed, .editionPublished:
            // Laut Router nicht für diese Stufe.
            break
        }
    }

    /// Diese Folgen verschwinden: aus der Warteschlange und aus dem Platz.
    private func forget(_ gone: Set<EpisodeID>) {
        guard !gone.isEmpty else { return }
        queue.removeAll { gone.contains($0.id) }
        if let id = running?.id, gone.contains(id) {
            // Die Arbeit bricht das Löschen über ihre eigene Aufgabe ab. Die
            // Folge kommt danach nirgends mehr hin.
            running = nil
        }
        changed()
    }

    /// Pause und „Alle abbrechen“ halten die laufende Folge an. Der Weg in
    /// den Hintergrund nicht: Dort trägt die fortgesetzte Verarbeitung die
    /// Warteschlange, bis ihre Zeit endet.
    func gateChanged(_ conditions: WorkConditions) {
        if conditions.held {
            stopRun()
        } else {
            startRunIfNeeded()
        }
    }

    // MARK: - Abgleich mit dem Store

    /// Beim Start: Die gemerkte Warteschlange kommt zurück, ohne die Folgen,
    /// die inzwischen Belege haben. Danach, etwa nach einem Abgleich: Was
    /// wartet und inzwischen Belege hat, fällt heraus.
    public func reconcile() async {
        if !restored {
            await restore()
        }
        let waiting = queue.compactMap { entry in CaptionAnalysis.feedMediaVersionID(of: entry.episode) }
        guard !waiting.isEmpty, let done = try? await store.mediaVersionsWithEvidence(waiting), !done.isEmpty
        else { return }
        let finished = queue.filter { entry in
            CaptionAnalysis.feedMediaVersionID(of: entry.episode).map(done.contains) ?? false
        }
        guard !finished.isEmpty else { return }
        let ids = Set(finished.map(\.id))
        queue.removeAll { ids.contains($0.id) }
        changed()
        for id in ids { await environment.settled(.alreadyTranscribed(id)) }
    }

    private func restore() async {
        let saved = AnalysisQueueSnapshot.decoded(from: defaults.data(forKey: snapshotKey))
        let ids = saved?.entries.map(\.episodeID) ?? []
        let ticket = ledger.ticket
        let found = ids.isEmpty ? [] : ((try? await store.episodes(ids: ids)) ?? [])
        guard !restored else { return }
        restored = true
        guard let saved else {
            schedulePersist()
            return
        }
        let items = await environment.restore(saved.entries, found)
        let media = items.compactMap { CaptionAnalysis.feedMediaVersionID(of: $0.episode) }
        let done = (try? await store.mediaVersionsWithEvidence(media)) ?? []
        for item in items {
            guard !ledger.wasRemoved(item.episode.id, since: ticket), running?.id != item.episode.id,
                  !queue.contains(where: { $0.id == item.episode.id }),
                  !(CaptionAnalysis.feedMediaVersionID(of: item.episode).map(done.contains) ?? false)
            else { continue }
            insert(Entry(episode: item.episode, origin: item.origin, ticket: ticket))
        }
        changed()
        startRunIfNeeded()
    }

    // MARK: - Der eine Platz

    private func startRunIfNeeded() {
        guard run == nil else {
            runAgain = true
            return
        }
        guard !queue.isEmpty, gate.mayRun(.transcript, origin: .automatic) else { return }
        runStopped = false
        runAgain = false
        run = Task(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    private func stopRun() {
        guard let run else { return }
        runStopped = true
        run.cancel()
    }

    /// Eine Folge nach der anderen, solange eine laufen darf. Die erste
    /// meldet die fortgesetzte Verarbeitung an, das Ende meldet sie ab.
    private func runLoop() async {
        var began = false
        var lease: WorkLease?
        var retried: Set<EpisodeID> = []
        while !Task.isCancelled, !runStopped, !gate.current.held, !queue.isEmpty {
            let runnable = await environment.runnable(queue.map(\.item))
            guard !Task.isCancelled, !runStopped,
                  let index = queue.firstIndex(where: { runnable.contains($0.id) }) else { break }
            let entry = queue.remove(at: index)
            // Seit dem Einreihen gelöscht, das Löschen kam aber noch nicht an.
            guard !ledger.wasRemoved(entry.id, since: entry.ticket) else {
                changed()
                continue
            }
            running = entry
            changed()
            if !began {
                began = true
                await environment.runStarted(entry.episode.title)
                // Solange Transkripte entstehen, dürfen die Fakten mitlaufen,
                // auch im Hintergrund.
                lease = gate.hold(.continued)
            }
            // Vorprüfung im Store: Hat die Fassung schon Belege, etwa von
            // einem anderen Gerät, gibt es nichts zu tun.
            if let media = CaptionAnalysis.feedMediaVersionID(of: entry.episode),
               (try? await store.mediaVersionsWithEvidence([media]))?.contains(media) == true {
                running = nil
                changed()
                await environment.settled(.alreadyTranscribed(entry.id))
                continue
            }
            let ticket = ledger.ticket
            let id = entry.id
            let job = TranscriptJob(
                episode: entry.episode, origin: entry.origin, ticket: ticket, remaining: queue.count,
                currentOrigin: { [weak self] in await self?.origin(of: id) ?? entry.origin })
            let outcome = await environment.transcribe(job)
            // Wer die Folge jetzt will, und ob sie noch im Platz steht. Nach
            // dem Löschen steht sie dort nicht mehr.
            let current = running?.id == id ? running : nil
            running = nil
            await finish(entry, current: current, outcome: outcome, ticket: ticket, retried: &retried)
            changed()
        }
        let cancelled = Task.isCancelled || runStopped
        lease?.release()
        // Erst abmelden, dann den Platz freigeben: Sonst begänne ein Befehl
        // während des Abmeldens einen zweiten Lauf, dessen fortgesetzte
        // Verarbeitung das Abmelden gleich wieder beendete.
        await environment.runEnded(cancelled)
        if began, !cancelled { host?.emit(.transcriptsIdle) }
        run = nil
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
        // Kam während des Laufs ein Anlass, oder ist die App nach einem
        // Anhalten schon wieder vorn, geht es gleich weiter. Pausiert oder im
        // Hintergrund nicht, das prüft das Tor. Ohne Anlass nicht: Eine
        // Warteschlange, in der nichts laufen darf, fragte sonst ohne Ende.
        if cancelled || runAgain { startRunIfNeeded() }
    }

    /// Wer die Folge im Platz jetzt will.
    private func origin(of id: EpisodeID) -> Origin? {
        running?.id == id ? running?.origin : nil
    }

    private func finish(
        _ entry: Entry, current: Entry?, outcome: TranscriptJobOutcome, ticket: RemovalLedger.Ticket,
        retried: inout Set<EpisodeID>
    ) async {
        let origin = current?.origin ?? entry.origin
        switch outcome {
        case .transcribed(let media):
            guard current != nil else { break }
            // Die Eingangsfassung, wie der Store sie jetzt sieht. Erst nach
            // dem Schreiben, und nur, wenn die Folge nicht inzwischen gelöscht wurde.
            if let host, let fingerprint = try? await store.transcriptFingerprint(forMedia: media) {
                let version = InputVersion(mediaVersionID: media, fingerprint: fingerprint)
                host.emit([.transcriptSaved(entry.id, version, origin), .evidenceReady(entry.id, version, origin)],
                          about: entry.id, unlessRemovedSince: ticket, in: ledger)
            }
        case .failed(let failure, let retry):
            guard current != nil else { break }
            host?.emit([.transcriptFailed(entry.id, failure, origin)], about: entry.id,
                       unlessRemovedSince: ticket, in: ledger)
            if retry {
                if retried.insert(entry.id).inserted, !ledger.wasRemoved(entry.id, since: ticket) {
                    insert(Entry(episode: entry.episode, origin: origin, ticket: entry.ticket))
                    changed()
                    await environment.settled(.retrying(entry.id))
                    try? await Task.sleep(for: retryPause)
                } else if origin == .backlog {
                    await environment.settled(.gaveUpBacklog(entry.id))
                }
            } else if failure.kind == .localeNotSupported, origin != .user, entry.episode.audioURL != nil {
                // Die anderen Folgen des Podcasts scheiterten genauso, erst
                // nach dem Laden. Sie gelten gleich als gescheitert.
                let siblings = queue.filter { $0.origin != .user && $0.episode.sourceID == entry.episode.sourceID }
                if !siblings.isEmpty {
                    let ids = Set(siblings.map(\.id))
                    queue.removeAll { ids.contains($0.id) }
                    changed()
                    await environment.settled(.preparationFailed(siblings.map(\.id)))
                }
            } else if failure.kind == .speechUnavailable {
                // Das Gerät kann gar nicht transkribieren: Was von selbst
                // wartet, lädt nicht noch umsonst.
                let automatic = queue.filter { $0.origin != .user }
                if !automatic.isEmpty {
                    queue.removeAll { $0.origin != .user }
                    changed()
                    await environment.settled(.droppedAutomatic(automatic.map(\.id)))
                }
            }
        case .interrupted:
            // Steht wieder ganz vorn und setzt an ihrem Zwischenstand an.
            if current != nil { queue.insert(Entry(episode: entry.episode, origin: origin, ticket: entry.ticket), at: 0) }
        case .dropped:
            break
        }
        if entry.origin == .backlog || origin == .backlog {
            await environment.settled(.backlogFinished(entry.episode.sourceID, announced: outcome.announces))
        }
    }

    // MARK: - Merken und Melden

    private func changed() {
        schedulePersist()
        publish()
    }

    private func publish() {
        let snapshot = TranscriptSnapshot(queue: queue.map(\.item), running: running?.item)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        snapshotContinuation.yield(snapshot)
    }

    /// Gebündelt: viele Änderungen hintereinander schreiben einmal. Vor dem
    /// Wiederherstellen nie, sonst wäre der gemerkte Stand weg, bevor ihn
    /// jemand gelesen hat.
    private func schedulePersist() {
        guard restored, !persistScheduled else { return }
        persistScheduled = true
        Task(priority: .utility) { [weak self] in await self?.persist() }
    }

    private func persist() {
        persistScheduled = false
        let all = [running].compactMap { $0 } + queue
        let snapshot = AnalysisQueueSnapshot(
            running: running?.id, queue: queue.map(\.id),
            automatic: Set(all.filter { $0.origin != .user }.map(\.id)),
            backlog: Set(all.filter { $0.origin == .backlog }.map(\.id)))
        defaults.set(snapshot.encoded(), forKey: snapshotKey)
    }

    // MARK: - Für Tests

    var queuedIDs: [EpisodeID] { queue.map(\.id) }
    var snapshot: TranscriptSnapshot { lastSnapshot }
}

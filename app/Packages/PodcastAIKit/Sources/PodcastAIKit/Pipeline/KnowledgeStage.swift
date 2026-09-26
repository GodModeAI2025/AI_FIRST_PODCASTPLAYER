//
//  KnowledgeStage.swift
//  PodcastAIKit
//
//  Die Stufe „Wissen“: Fakten und Kapitel-Tags, eine Folge nach der anderen
//  (docs/plan-pipeline.md, Schritt 3). Bis 0.12 lag das im `AppModel`:
//  `factsQueue`, `tagsQueue`, `runFactsQueue` und die Zähler für Zeit vom
//  System. Die Stufe übernimmt Warteschlange, Reihenfolge, Tor und die
//  gemerkten Absichten. Die Regeln sind dieselben:
//
//  - Angefordert kommt ganz nach vorn, von selbst Eingereihtes vor die
//    älteren Folgen, hinter das Angeforderte.
//  - Nach den Fakten einer Folge kommen ihre Tags, im selben Platz, dann
//    die nächsten Fakten. Tags aus dem Rückstand laufen nur, wenn keine
//    Fakten bereit sind.
//  - Scheitert eine Folge, kommt sie einmal hinten wieder dran, danach
//    erst nach dem nächsten Start (vorn) oder ohne Wartezeit beim nächsten
//    Einreihen (im Hintergrund). Nach jedem Fehlschlag eine Minute Luft,
//    die eine angeforderte Folge abkürzt.
//  - In Portionen, neueste zuerst (`AutomaticWorkBudget`).
//
//  Der Aufbau folgt dem Plan: Der Store ist die Wahrheit, ein Ereignis ist
//  ein Hinweis. Die Stufe hört auf `evidenceReady`, `feedsRefreshed`,
//  `episodesRemoved` und `changedElsewhere`, auf das Tor (`WorkGate`) und
//  auf den Zustand der Modelle. Befehle eines Menschen kommen direkt.
//
//  Warteschlange und Platz ändern sich nur in Abschnitten ohne `await`.
//  Die Arbeit an einer Folge läuft als eigene Aufgabe, auf die die Stufe
//  nicht wartet, und meldet sich danach zurück. So nimmt die Stufe auch
//  während eines Laufs Ereignisse an, etwa das Löschen der laufenden Folge.
//
//  Was die Arbeit an einer Folge tut, sagt `KnowledgeWorking`. Die Stufe
//  liest Folge, Kapitel und Belege dafür beim Start frisch aus dem Store,
//  nie aus dem Wert, der in der Warteschlange steht.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence
import PodcastAIPersistence

/// Wie eine Einordnung der Kapitel ausging, und ob die Kapitel-Tags der
/// Folge danach zum aktuellen Transkript passen. Dann fragt dieser Start
/// sie beim Einreihen nicht noch einmal ab.
public struct ChapterTagsRun: Sendable, Equatable {
    public var outcome: ChapterTagsOutcome
    public var current: Bool

    public init(_ outcome: ChapterTagsOutcome, current: Bool = false) {
        self.outcome = outcome
        self.current = current
    }
}

/// Die Arbeit an einer Folge. `episode` kommt frisch aus dem Store.
/// `ticket` ist der Stand des Löschprotokolls beim Start: Wird die Folge
/// danach gelöscht, bleibt nichts von ihr zurück.
public protocol KnowledgeWorking: Sendable {
    func gatherFacts(for episode: Episode, force: Bool, origin: Origin,
                     since ticket: RemovalLedger.Ticket) async -> FactsOutcome
    func classifyChapters(of episode: Episode, origin: Origin,
                          since ticket: RemovalLedger.Ticket) async -> ChapterTagsRun
}

/// Was die Stufe vom Hauptakteur wissen muss. Sie fragt beim Einreihen,
/// nicht der Router beim Senden.
public struct KnowledgeSettings: Sendable, Equatable {
    /// Hat der Start den Bestand einmal gelesen?
    public var isLoaded: Bool
    /// „Fakten automatisch sammeln“.
    public var automaticFacts: Bool
    /// Folgen mit Transkript und Belegen, wie der Hauptakteur sie kennt.
    /// Aus dem Speicher statt aus dem Store: dort läse das jedes Mal alle
    /// Belege der Bibliothek auf der einen Queue des Stores.
    public var analyzed: Set<EpisodeID>

    public init(isLoaded: Bool, automaticFacts: Bool, analyzed: Set<EpisodeID>) {
        self.isLoaded = isLoaded
        self.automaticFacts = automaticFacts
        self.analyzed = analyzed
    }

    public static let notLoaded = KnowledgeSettings(isLoaded: false, automaticFacts: false, analyzed: [])
}

/// Was beim letzten Lauf einer Folge fehlte, für den Reiter „Fakten“.
public enum KnowledgeIssue: Sendable, Equatable {
    case note(String)
    /// Gescheitert, ohne dass der Lauf einen Grund nannte.
    case unspecified
}

/// Der Stand der Stufe für die Oberfläche. Die Senke schreibt daraus die
/// Felder, die Ansichten heute lesen (`factsQueue`, `gatheringFacts`,
/// `factsWait`, `factsIssues`).
public struct KnowledgeSnapshot: Sendable, Equatable {
    /// Was auf Fakten wartet, vorn zuerst.
    public var queue: [Episode]
    /// Die Folge, deren Fakten gerade entstehen.
    public var running: Episode?
    /// Warum die Fakten stehen: das Modell fehlt.
    public var waitReason: ModelUnavailability?
    public var issues: [EpisodeID: KnowledgeIssue]

    public init(queue: [Episode] = [], running: Episode? = nil, waitReason: ModelUnavailability? = nil,
                issues: [EpisodeID: KnowledgeIssue] = [:]) {
        self.queue = queue
        self.running = running
        self.waitReason = waitReason
        self.issues = issues
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Nach Kennungen: Eine Folge in der Warteschlange trägt Shownotes,
        // die hier niemand vergleichen muss.
        lhs.queue.map(\.id) == rhs.queue.map(\.id) && lhs.running?.id == rhs.running?.id
            && lhs.waitReason == rhs.waitReason && lhs.issues == rhs.issues
    }
}

public actor KnowledgeStage {

    /// Was die Stufe beim Hauptakteur fragt.
    public struct Environment: Sendable {
        /// Die Schalter und der Bestand, beim Einreihen gelesen.
        public var settings: @Sendable () async -> KnowledgeSettings
        /// Fragt das System nach den Modellen, vor jeder Folge.
        public var refreshModel: @Sendable () async -> ModelStatus

        public init(settings: @escaping @Sendable () async -> KnowledgeSettings,
                    refreshModel: @escaping @Sendable () async -> ModelStatus) {
            self.settings = settings
            self.refreshModel = refreshModel
        }
    }

    /// Wie lange eine Folge, deren Transkript von einem anderen Gerät kam,
    /// auf dessen Fakten wartet, bevor dieses Gerät sie selbst sammelt.
    public static let syncGrace: TimeInterval = 20 * 60

    /// Eine Folge in der Warteschlange der Fakten.
    private struct Entry: Sendable {
        /// Nur zum Anzeigen und für die Reihenfolge. Die Arbeit liest frisch.
        var episode: Episode
        var requested: Bool
        var origin: Origin
        /// Stand des Löschprotokolls beim Einreihen. Vor dem Merken prüft
        /// die Stufe, ob die Folge seitdem gelöscht wurde.
        var ticket: RemovalLedger.Ticket
        var id: EpisodeID { episode.id }

        var intent: FactsIntent { FactsIntent(episodeID: id, origin: origin, requested: requested) }
    }

    /// Was im einen Platz läuft.
    private enum Work: Sendable {
        /// Vor jeder Folge: Ist das Modell bereit?
        case probe
        case facts(Entry)
        case tags(Episode)
        /// Die nächste Portion Fakten oder Tags suchen.
        case refillFacts
        case refillTags

        var episodeID: EpisodeID? {
            switch self {
            case .facts(let entry): entry.id
            case .tags(let episode): episode.id
            case .probe, .refillFacts, .refillTags: nil
            }
        }
    }

    private struct Slot {
        let token: UInt64
        let work: Work
        var task: Task<Void, Never>?
        /// Die Stufe hat angehalten, weil das Tor zu ist oder die Folge
        /// gelöscht wurde. Kein Grund, den Lauf ganz zu beenden.
        var stoppedByStage = false
        /// Die Minute Luft nach einem Fehlschlag.
        var cooling = false
    }

    /// Was ein Lauf von `runFactsQueue` bis 0.12 im Speicher trug. Beginnt
    /// neu, wenn die Stufe ruhte und wieder Arbeit bekommt.
    private struct Session {
        /// Ein zweiter Versuch je Folge und Lauf.
        var retried: Set<EpisodeID> = []
        /// Hat die letzte Portion etwas fertig gemacht? Nur dann kommt die nächste.
        var progressed = false
        /// Das Modell fehlt: keine Fakten mehr in diesem Lauf, nur Tags.
        var factsBlocked = false
        /// Die Tags sind an Modell, Netz oder Abbruch hängen geblieben.
        var tagsHalted = false
        /// Der Lauf ist zu Ende, bis neue Arbeit oder ein Modell kommt.
        var halted = false
    }

    private var store: LibraryStore
    private let gate: WorkGate
    private let ledger: RemovalLedger
    private let intents: PipelineIntents
    private let marks: DeviceState
    private let monitor: ModelAvailabilityMonitor
    private let host: PipelineHost?
    private let work: any KnowledgeWorking
    private let environment: Environment
    private let clock: @Sendable () -> Date
    private let pauseStep: Duration
    private let pauseSteps: Int

    private var factsQueue: [Entry] = []
    private var tagsQueue: [Episode] = []
    private var slot: Slot?
    private var session = Session()
    private var nextToken: UInt64 = 0
    /// Nach zwei vergeblichen Versuchen im Vordergrund. Erst der nächste
    /// Start oder ein wieder bereites Modell versucht es erneut.
    private var deferred: Set<EpisodeID> = []
    /// Einordnung in diesem Start an Last oder Zeit gescheitert.
    private var tagsFailed: Set<EpisodeID> = []
    /// Kapitel-Tags passen in diesem Start schon zum aktuellen Transkript.
    private var tagsCurrent: Set<EpisodeID> = []
    private var issues: [EpisodeID: KnowledgeIssue] = [:]
    private var waitReason: ModelUnavailability?
    private var factsBackfillPending = false
    private var tagsBackfillPending = false
    /// Ist die gemerkte Warteschlange schon zurück? Vorher wird sie nicht
    /// überschrieben.
    private var restored = false
    private var persisted: [FactsIntent]?
    private var extractReady = false
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private var started = false
    private var listeners: [Task<Void, Never>] = []

    private let snapshotContinuation: AsyncStream<KnowledgeSnapshot>.Continuation
    private var lastSnapshot = KnowledgeSnapshot()

    /// Jeder neue Stand für die Oberfläche. Wer langsam liest, bekommt nur
    /// den neuesten. Ein Leser.
    public nonisolated let snapshots: AsyncStream<KnowledgeSnapshot>

    public init(
        store: LibraryStore, gate: WorkGate, ledger: RemovalLedger = .shared,
        intents: PipelineIntents = PipelineIntents(), marks: DeviceState = .shared,
        monitor: ModelAvailabilityMonitor = .shared, host: PipelineHost? = nil,
        work: any KnowledgeWorking, environment: Environment,
        clock: @escaping @Sendable () -> Date = { Date() },
        pauseStep: Duration = .seconds(5), pauseSteps: Int = 12
    ) {
        self.store = store
        self.gate = gate
        self.ledger = ledger
        self.intents = intents
        self.marks = marks
        self.monitor = monitor
        self.host = host
        self.work = work
        self.environment = environment
        self.clock = clock
        self.pauseStep = pauseStep
        self.pauseSteps = pauseSteps
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Start

    /// Hört zu: auf das Postfach der Stufe, das Tor und den Zustand der
    /// Modelle. Ein zweiter Aufruf tut nichts.
    public func start() {
        guard !started else { return }
        started = true
        if let host {
            let mailbox = host.mailbox(for: .knowledge)
            listeners.append(Task { [weak self] in
                for await event in mailbox { await self?.receive(event) }
            })
        }
        let conditions = gate.updates()
        listeners.append(Task { [weak self] in
            for await state in conditions { await self?.gateChanged(state) }
        })
        let models = monitor.updates()
        listeners.append(Task { [weak self] in
            for await status in models { await self?.modelChanged(status) }
        })
    }

    /// Hört auf. Für Tests und einen neuen Speicher im selben Prozess.
    public func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        slot?.task?.cancel()
        slot = nil
        started = false
        becameIdle()
    }

    // MARK: - Ereignisse

    func receive(_ event: PipelineEvent) async {
        switch event {
        case .evidenceReady(let id, _, _):
            await evidenceReady(id)
        case .factsDone:
            // Kommt aus dieser Stufe: Die Tags derselben Folge liefen schon
            // im selben Platz, gleich nach den Fakten.
            break
        case .feedsRefreshed, .changedElsewhere:
            requestReconcile()
        case .episodesRemoved(let ids, _):
            forget(Set(ids))
        case .episodesAdded, .audioAvailable, .audioRemoved, .transcriptSaved, .transcriptFailed,
             .transcriptsIdle, .tagsDone, .editionPublished:
            // Laut Router nicht für diese Stufe.
            break
        }
    }

    /// Transkript und Belege einer Folge sind gespeichert.
    private func evidenceReady(_ id: EpisodeID) async {
        let ticket = ledger.ticket
        // Ein eigenes Transkript: Die Fakten warten nicht auf ein anderes
        // Gerät, auch nicht nach einem Neustart oder wenn „Fakten
        // automatisch sammeln“ erst später angeht.
        if !ledger.wasRemoved(id, since: ticket) { intents.markOwn([id]) }
        // Ein neues Transkript: Die Tags bekommen eine neue Gelegenheit,
        // auch wenn die letzte Einordnung ohne Tag endete.
        tagsCurrent.remove(id)
        tagsFailed.remove(id)
        var tagsSettled = KnowledgeMarks.tagsSettled(in: marks)
        tagsSettled.remove(id)
        let settings = await environment.settings()
        guard settings.automaticFacts, let episode = try? await store.episodes(ids: [id]).first,
              !ledger.wasRemoved(id, since: ticket) else { return }
        enqueue(episode, requested: false, origin: .automatic, ticket: ticket)
    }

    /// Diese Folgen verschwinden. Aus beiden Warteschlangen, aus dem Platz
    /// und aus den gemerkten Absichten (Regel 5).
    private func forget(_ gone: Set<EpisodeID>) {
        guard !gone.isEmpty else { return }
        factsQueue.removeAll { gone.contains($0.id) }
        tagsQueue.removeAll { gone.contains($0.id) }
        deferred.subtract(gone)
        tagsFailed.subtract(gone)
        tagsCurrent.subtract(gone)
        session.retried.subtract(gone)
        for id in gone { issues[id] = nil }
        if var current = slot, let id = current.work.episodeID, gone.contains(id) {
            // Auch Fakten und Tags brechen ab, nicht nur das Transkript.
            current.stoppedByStage = true
            slot = current
            current.task?.cancel()
        }
        intents.forget(gone)
        persistQueue()
        publish()
    }

    // MARK: - Tor und Modell

    func gateChanged(_ conditions: WorkConditions) {
        guard var current = slot else {
            kick()
            return
        }
        let facts = conditions.mayRun(.facts, origin: .automatic)
        let tags = conditions.mayRun(.tags, origin: .automatic)
        // Wie `pauseFactsWithoutTime` bis 0.12: Fakten halten an, wenn sie
        // keine Zeit mehr haben. Tags laufen weiter, solange die leichte
        // Aufgabe für Tags ihnen Zeit gibt.
        let stop: Bool = if current.cooling {
            !facts && !tags
        } else {
            switch current.work {
            case .probe, .facts: !facts
            case .tags: !tags
            case .refillFacts, .refillTags: !facts && !tags
            }
        }
        guard stop, !current.stoppedByStage else { return }
        current.stoppedByStage = true
        slot = current
        current.task?.cancel()
    }

    func modelChanged(_ status: ModelStatus) {
        let ready = Self.isReady(status, for: .extract)
        let wasReady = extractReady
        extractReady = ready
        guard ready else {
            // Nur ein Modell für Tags, etwa Private Cloud Compute ohne
            // Gerätemodell: Die Einordnung darf laufen, die Fakten warten.
            if Self.isReady(status, for: .tag) { kick() }
            return
        }
        if slot == nil, waitReason != nil {
            waitReason = nil
            publish()
        }
        if !wasReady {
            // Eben erst bereit geworden: Auch Zurückgestelltes bekommt eine
            // Gelegenheit, und was bisher gar nicht eingereiht war.
            deferred.removeAll()
            tagsFailed.removeAll()
            session.halted = false
            session.factsBlocked = false
            requestReconcile()
        }
        kick()
    }

    // MARK: - Befehle

    /// „Jetzt ermitteln“ und „Neu ermitteln“: Die Folge kommt als Nächste
    /// dran, rechnet neu und meldet, was fehlt.
    public func request(_ episode: Episode) {
        var factsSettled = KnowledgeMarks.factsSettled(in: marks)
        factsSettled.remove(episode.id)
        var tagsSettled = KnowledgeMarks.tagsSettled(in: marks)
        tagsSettled.remove(episode.id)
        issues[episode.id] = nil
        enqueue(episode, requested: true, origin: .user, ticket: ledger.ticket)
    }

    /// Reiht eine Folge von selbst ein, etwa wenn ihre gespeicherten Fakten
    /// nur noch Listenreste einer alten Version sind.
    public func enqueue(_ episode: Episode) {
        enqueue(episode, requested: false, origin: .automatic, ticket: ledger.ticket)
    }

    /// „Fakten automatisch sammeln“ ist aus: Was von selbst wartet, fällt
    /// heraus. Angefordertes und was gerade läuft, bleibt.
    public func dropAutomatic() {
        factsQueue.removeAll { !$0.requested }
        tagsQueue.removeAll()
        persistQueue()
        publish()
    }

    /// „Alle abbrechen“: Die laufende Folge hält an, fertige Abschnitte der
    /// Fakten bleiben gespeichert. Alles Wartende geht aus der Warteschlange
    /// und kommt erst nach dem nächsten Start wieder von selbst dazu.
    public func cancelAll() async {
        if var current = slot {
            current.stoppedByStage = true
            slot = current
            current.task?.cancel()
            // Die laufende Folge stellt sich beim Aufräumen wieder vorn an
            // und geht unten mit den anderen.
            await current.task?.value
        }
        deferred.formUnion(factsQueue.map(\.id))
        factsQueue.removeAll()
        tagsQueue.removeAll()
        waitReason = nil
        persistQueue()
        publish()
    }

    /// Ein anderer Speicher: Was wartete, gehörte zum alten.
    public func reset(store newStore: LibraryStore) {
        slot?.task?.cancel()
        slot = nil
        store = newStore
        factsQueue.removeAll()
        tagsQueue.removeAll()
        session = Session()
        deferred.removeAll()
        tagsFailed.removeAll()
        tagsCurrent.removeAll()
        issues.removeAll()
        waitReason = nil
        factsBackfillPending = false
        tagsBackfillPending = false
        restored = false
        persisted = nil
        publish()
        becameIdle()
    }

    /// Wartet, bis die Stufe ruht: nichts läuft, oder das Tor lässt nichts
    /// laufen. Für die Hintergrundaufgaben. Ein Abbruch beendet nur das Warten.
    public func untilIdle() async {
        guard slot != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancelledWaiters.remove(id) != nil || slot == nil {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = idleWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledWaiters.insert(id)
        }
    }

    private func becameIdle() {
        let waiting = idleWaiters.values
        idleWaiters.removeAll()
        cancelledWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    // MARK: - Einreihen

    private func enqueue(_ episode: Episode, requested: Bool, origin: Origin,
                         ticket: RemovalLedger.Ticket, kick shouldKick: Bool = true) {
        guard runningFactsID != episode.id,
              requested || Self.isExpected(monitor.current, for: .extract) else { return }
        guard !ledger.wasRemoved(episode.id, since: ticket) else { return }
        if let index = factsQueue.firstIndex(where: { $0.id == episode.id }) {
            guard requested else { return }
            factsQueue.remove(at: index)
        }
        let entry = Entry(episode: episode, requested: requested, origin: requested ? .user : origin,
                          ticket: ticket)
        if requested {
            deferred.remove(episode.id)
            factsQueue.insert(entry, at: 0)
        } else {
            let date = episode.publishedAt ?? .distantPast
            let index = factsQueue.firstIndex {
                !$0.requested && ($0.episode.publishedAt ?? .distantPast) < date
            } ?? factsQueue.count
            factsQueue.insert(entry, at: index)
        }
        persistQueue()
        publish()
        if shouldKick { kick() }
    }

    private var runningFactsID: EpisodeID? {
        if case .facts(let entry) = slot?.work { return entry.id }
        return nil
    }

    // MARK: - Abgleich mit dem Store

    /// Reiht ein, was laut Store offen ist: Folgen mit Belegen ohne Fakten,
    /// Folgen mit Lücken und Kapitel ohne Tags. Beim Start, nach einem
    /// Abgleich, nach dem Aktualisieren, wenn das Modell bereit wird und
    /// wenn die App aus dem Hintergrund zurückkommt. Kommen Anlässe
    /// während eines Abgleichs, läuft danach genau einer mehr.
    public func reconcile() async {
        if let running = reconcileTask {
            reconcileAgain = true
            await running.value
            return
        }
        let task = Task { await reconcileLoop() }
        reconcileTask = task
        await task.value
    }

    /// Wie ``reconcile()``, ohne zu warten.
    public nonisolated func requestReconcile() {
        Task { await reconcile() }
    }

    /// Nur die Kapitel-Tags, für die leichte Hintergrundaufgabe.
    public func reconcileTags() async {
        let settings = await environment.settings()
        guard let withFacts = try? await store.episodeIDsWithFacts() else { return }
        await queueMissingChapterTags(withFacts: withFacts, settings: settings, ticket: ledger.ticket)
        kick()
    }

    private func reconcileLoop() async {
        repeat {
            reconcileAgain = false
            await reconcileOnce()
        } while reconcileAgain
        reconcileTask = nil
    }

    private func reconcileOnce() async {
        let settings = await environment.settings()
        guard settings.isLoaded else { return }
        let ticket = ledger.ticket
        if !restored { await restoreQueue(settings: settings, ticket: ticket) }
        guard settings.automaticFacts, let withFacts = try? await store.episodeIDsWithFacts() else { return }
        // Tags brauchen nur ein Modell für Tags. Auf einem Gerät ohne
        // Gerätemodell, aber mit Private Cloud Compute, gibt es sie trotzdem.
        guard Self.isExpected(monitor.current, for: .extract) else {
            await queueMissingChapterTags(withFacts: withFacts, settings: settings, ticket: ticket)
            kick()
            return
        }
        // Vor dem ersten Entsperren: nichts schließen, beim nächsten Anlass neu.
        guard let firstSeen = intents.firstSeen() else { return }
        let settled = KnowledgeMarks.factsSettled(in: marks)
        let gapped = KnowledgeMarks.episodesWithFactGaps(in: marks)
        var busy = Set(factsQueue.map(\.id))
        if let running = runningFactsID { busy.insert(running) }
        let now = clock()
        var missing: [EpisodeID] = []
        var seen: [EpisodeID: Date] = [:]
        for id in settings.analyzed where !busy.contains(id) {
            guard !settled.contains(id), !deferred.contains(id) else { continue }
            if withFacts.contains(id) {
                // Lücken aus einem Lauf auf diesem Gerät: ohne Wartezeit,
                // kein anderes Gerät holt sie nach.
                if gapped.contains(id) { missing.append(id) }
                continue
            }
            // Zum ersten Mal gesehen: Kam das Transkript von einem anderen
            // Gerät, sammelt meist das gerade die Fakten. Eigene Transkripte
            // stehen schon mit `distantPast` da.
            let since = firstSeen[id] ?? now
            if firstSeen[id] == nil, !ledger.wasRemoved(id, since: ticket) { seen[id] = now }
            if now.timeIntervalSince(since) >= Self.syncGrace { missing.append(id) }
        }
        // Was inzwischen Fakten hat oder nicht mehr erschlossen ist, braucht
        // keine Wartezeit mehr.
        let done = Set(firstSeen.keys.filter { !settings.analyzed.contains($0) || withFacts.contains($0) })
        intents.updateFirstSeen(adding: seen, removing: done)

        if !missing.isEmpty, let found = try? await store.episodes(ids: missing) {
            // In Portionen, neueste zuerst: bis 0.11 kam jede Folge der
            // Bibliothek ohne Fakten auf einmal dazu. Ist die Portion durch,
            // holt die Stufe die nächste.
            let current = await environment.settings()
            let newest = found
                .filter { current.automaticFacts && current.analyzed.contains($0.id)
                    && !ledger.wasRemoved($0.id, since: ticket) }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            let waiting = factsQueue.count { !$0.requested }
            let portion = AutomaticWorkBudget.refill(
                newest, alreadyWaiting: waiting, batch: AutomaticWorkBudget.factsBackfillBatch)
            factsBackfillPending = portion.count < newest.count
            for episode in portion {
                enqueue(episode, requested: false, origin: .automatic, ticket: ticket, kick: false)
            }
        }
        // Folgen mit Fakten, deren Kapitel noch keine Tags haben.
        await queueMissingChapterTags(withFacts: withFacts, settings: settings, ticket: ticket)
        kick()
    }

    /// Holt die gemerkte Warteschlange zurück, einmal je Start. Angefordertes
    /// bleibt angefordert und vorn, von selbst Eingereihtes wartet nicht auf
    /// ein anderes Gerät.
    private func restoreQueue(settings: KnowledgeSettings, ticket: RemovalLedger.Ticket) async {
        guard let saved = intents.factsQueue() else { return }
        guard !saved.isEmpty else {
            restored = true
            return
        }
        let ids = saved.map(\.episodeID)
        guard let found = try? await store.episodes(ids: ids) else { return }
        // Ein zweiter Abgleich kann in der Zwischenzeit schon zurückgeholt haben.
        guard !restored else { return }
        restored = true
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let withFacts = (try? await store.episodeIDsWithFacts()) ?? []
        let gapped = KnowledgeMarks.episodesWithFactGaps(in: marks)
        let settled = KnowledgeMarks.factsSettled(in: marks)
        var front = 0
        for intent in saved {
            guard let episode = byID[intent.episodeID], settings.analyzed.contains(intent.episodeID),
                  !ledger.wasRemoved(intent.episodeID, since: ticket),
                  !factsQueue.contains(where: { $0.id == intent.episodeID }),
                  runningFactsID != intent.episodeID else { continue }
            if !intent.requested {
                // Inzwischen fertig oder ohne Ergebnis: nichts mehr zu tun.
                let finished = withFacts.contains(intent.episodeID) && !gapped.contains(intent.episodeID)
                guard settings.automaticFacts, !finished, !settled.contains(intent.episodeID) else { continue }
            }
            let entry = Entry(episode: episode, requested: intent.requested, origin: intent.origin, ticket: ticket)
            if intent.requested {
                factsQueue.insert(entry, at: front)
                front += 1
            } else {
                factsQueue.append(entry)
            }
        }
        persistQueue()
        publish()
    }

    /// Reiht Folgen ein, deren Kapitel noch keine Tags aus dem aktuellen
    /// Transkript haben, neueste zuerst. Nur mit „Fakten automatisch
    /// sammeln“. Eine Folge wartet, bis sie Fakten hat oder ein Lauf ohne
    /// Fakten endete, außer dieses Gerät kann gar keine Fakten sammeln.
    private func queueMissingChapterTags(
        withFacts: Set<EpisodeID>, settings: KnowledgeSettings, ticket: RemovalLedger.Ticket
    ) async {
        let status = monitor.current
        guard settings.automaticFacts, settings.isLoaded, Self.isExpected(status, for: .tag) else { return }
        let settled = KnowledgeMarks.tagsSettled(in: marks)
        let factsSettled = KnowledgeMarks.factsSettled(in: marks)
        let factsHere = Self.isExpected(status, for: .extract)
        var busy = Set(tagsQueue.map(\.id)).union(factsQueue.map(\.id))
        if let id = slot?.work.episodeID { busy.insert(id) }
        let pool = settings.analyzed.filter {
            (!factsHere || withFacts.contains($0) || factsSettled.contains($0))
                && !busy.contains($0) && !settled.contains($0) && !tagsFailed.contains($0)
                && !tagsCurrent.contains($0)
        }
        guard !pool.isEmpty, let backlog = try? await store.chapterTagBacklog(among: pool) else { return }
        // Was nicht offen ist, fragt dieser Start nicht noch einmal ab.
        tagsCurrent.formUnion(pool.subtracting(backlog).filter { !ledger.wasRemoved($0, since: ticket) })
        guard !backlog.isEmpty, let found = try? await store.episodes(ids: Array(backlog)) else { return }
        let newest = found
            .filter { episode in
                !tagsQueue.contains(where: { $0.id == episode.id }) && !ledger.wasRemoved(episode.id, since: ticket)
            }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let portion = AutomaticWorkBudget.refill(
            newest, alreadyWaiting: tagsQueue.count, batch: AutomaticWorkBudget.tagsBackfillBatch)
        tagsBackfillPending = portion.count < newest.count
        tagsQueue.append(contentsOf: portion)
    }

    // MARK: - Der eine Platz

    /// Neue Arbeit. Ruhte die Stufe, beginnt ein neuer Lauf.
    private func kick() {
        guard started else { return }
        if slot == nil { session = Session() }
        pump()
    }

    /// Wählt die nächste Arbeit, wenn der Platz frei ist. Ohne `await`.
    private func pump() {
        guard slot == nil else { return }
        defer { if slot == nil { becameIdle() } }
        guard started, !session.halted else { return }
        let conditions = gate.current
        let factsMayRun = conditions.mayRun(.facts, origin: .automatic)
        let tagsMayRun = conditions.mayRun(.tags, origin: .automatic)
        if factsMayRun, !session.factsBlocked, !factsQueue.isEmpty {
            begin(.probe)
            return
        }
        // Die Portion ist durch: die nächste, falls noch Folgen fehlen.
        if factsMayRun, !session.factsBlocked, factsQueue.isEmpty, factsBackfillPending, session.progressed {
            factsBackfillPending = false
            session.progressed = false
            begin(.refillFacts)
            return
        }
        // Keine Folge wartet auf Fakten, die Fakten dürfen gerade nicht
        // oder das Modell fehlt: die Tags, die noch fehlen.
        guard tagsMayRun, !session.tagsHalted,
              session.factsBlocked || factsQueue.isEmpty || !factsMayRun else { return }
        if let next = tagsQueue.first {
            tagsQueue.removeFirst()
            begin(.tags(next))
        } else if tagsBackfillPending {
            tagsBackfillPending = false
            begin(.refillTags)
        }
    }

    private func begin(_ work: Work) {
        nextToken += 1
        let token = nextToken
        slot = Slot(token: token, work: work)
        let task: Task<Void, Never> = switch work {
        case .probe:
            Task(priority: .utility) { await runProbe(token) }
        case .facts(let entry):
            Task(priority: .utility) { await runFacts(entry, token: token) }
        case .tags(let episode):
            Task(priority: .utility) { await runTags(episode, token: token) }
        case .refillFacts:
            Task(priority: .utility) {
                await reconcile()
                end(token)
            }
        case .refillTags:
            Task(priority: .utility) {
                let settings = await environment.settings()
                if let withFacts = try? await store.episodeIDsWithFacts() {
                    await queueMissingChapterTags(withFacts: withFacts, settings: settings, ticket: ledger.ticket)
                }
                end(token)
            }
        }
        if slot?.token == token { slot?.task = task }
        persistQueue()
        publish()
    }

    /// Der Platz ist wieder frei.
    private func end(_ token: UInt64) {
        guard slot?.token == token else { return }
        slot = nil
        persistQueue()
        publish()
        pump()
    }

    /// Vor jeder Folge: Das Modell kann bereit geworden oder weggefallen sein.
    private func runProbe(_ token: UInt64) async {
        let status = await environment.refreshModel()
        guard let current = slot, current.token == token else { return }
        slot = nil
        if current.stoppedByStage {
            publish()
            pump()
            return
        }
        if case .failure(let reason) = status.resolve(.extract) {
            waitReason = reason
            // Tags können mit Private Cloud Compute trotzdem weitergehen.
            session.factsBlocked = true
            publish()
            pump()
            return
        }
        waitReason = nil
        // Während der Prüfung kann die Folge gelöscht worden sein.
        guard gate.current.mayRun(.facts, origin: .automatic), !factsQueue.isEmpty else {
            publish()
            pump()
            return
        }
        begin(.facts(factsQueue.removeFirst()))
    }

    private func runFacts(_ entry: Entry, token: UInt64) async {
        // Stand der Löschungen beim Entnehmen. Was danach auf diesem Gerät
        // vermerkt wird, gilt nur für eine Folge, die es noch gibt.
        let ticket = ledger.ticket
        var outcome = FactsOutcome.nothingToDo
        var tags: ChapterTagsRun?
        if let episode = try? await store.episodes(ids: [entry.id]).first, !ledger.wasRemoved(entry.id, since: ticket) {
            let work = self.work
            outcome = await ProcessingTrace.interval("Fakten einer Folge") {
                await work.gatherFacts(for: episode, force: entry.requested, origin: entry.origin, since: ticket)
            }
            await announce([.factsDone], of: entry.id, since: ticket) {
                [.factsDone(entry.id, $0, outcome, entry.origin)]
            }
            // Gleich danach die Tags der Kapitel, dieselbe Folge, derselbe
            // Platz. Sie erben, wer die Fakten wollte.
            switch outcome {
            case .stored, .partial, .noFacts:
                let run = await ProcessingTrace.interval("Kapitel-Tags einer Folge") {
                    await work.classifyChapters(of: episode, origin: entry.origin, since: ticket)
                }
                tags = run
                await announce([.tagsDone], of: entry.id, since: ticket) {
                    [.tagsDone(entry.id, $0, run.outcome, entry.origin)]
                }
            default:
                break
            }
        }
        guard slot?.token == token else { return }
        if let tags { applyChained(tags, to: entry.id, since: ticket) }
        if factsFinished(entry, outcome: outcome, since: ticket) { await coolDown(token) }
        end(token)
    }

    private func runTags(_ episode: Episode, token: UInt64) async {
        let ticket = ledger.ticket
        var run = ChapterTagsRun(.nothingToDo)
        if let fresh = try? await store.episodes(ids: [episode.id]).first, !ledger.wasRemoved(episode.id, since: ticket) {
            let work = self.work
            // Aus dem Rückstand der Bibliothek, nicht nach den Fakten einer Folge.
            run = await ProcessingTrace.interval("Kapitel-Tags einer Folge") {
                await work.classifyChapters(of: fresh, origin: .backlog, since: ticket)
            }
            let outcome = run.outcome
            await announce([.tagsDone], of: episode.id, since: ticket) {
                [.tagsDone(episode.id, $0, outcome, .backlog)]
            }
        }
        guard slot?.token == token else { return }
        if tagsFinished(episode, run: run, since: ticket) { await coolDown(token) }
        end(token)
    }

    /// Die Tags nach den Fakten einer Folge.
    private func applyChained(_ run: ChapterTagsRun, to id: EpisodeID, since ticket: RemovalLedger.Ticket) {
        guard !ledger.wasRemoved(id, since: ticket) else { return }
        if run.current { tagsCurrent.insert(id) }
        if run.outcome == .failed { tagsFailed.insert(id) }
    }

    /// Die Regeln nach einem Lauf der Fakten. `true`: vor der nächsten
    /// Folge eine Minute Luft.
    private func factsFinished(_ entry: Entry, outcome: FactsOutcome, since ticket: RemovalLedger.Ticket) -> Bool {
        let id = entry.id
        // Während des Laufs gelöscht: Das Löschen hat die Folge schon aus
        // den Warteschlangen genommen. Sie kommt weder zurück noch in einen
        // Vermerk auf diesem Gerät.
        guard !ledger.wasRemoved(id, since: ticket) else {
            session.progressed = true
            return false
        }
        switch outcome {
        case .stored, .nothingToDo:
            session.progressed = true
            issues[id] = nil
            intents.updateFirstSeen(adding: [:], removing: [id])
            intents.recordFailure(nil, for: id)
        case .noFacts(let note):
            session.progressed = true
            issues[id] = .note(note)
            intents.recordFailure(note, for: id)
            var settled = KnowledgeMarks.factsSettled(in: marks)
            settled.insert(id)
        case .failed(let note), .partial(let note):
            issues[id] = note.map(KnowledgeIssue.note) ?? .unspecified
            intents.recordFailure(note ?? "", for: id)
            // Wer selbst gefragt hat, hat den Grund gesehen und entscheidet
            // selbst. Gemerkte Lücken holt ein späterer Lauf trotzdem nach.
            guard !entry.requested else { return false }
            if session.retried.insert(id).inserted {
                factsQueue.append(entry)
            } else if gate.current.inForeground {
                // Im Hintergrund nicht zurückstellen: dort ist das Modell
                // eher ausgelastet. Vorn kommt die Folge wieder dran.
                deferred.insert(id)
            } else {
                // Ohne die Wartezeit für Fakten von anderen Geräten.
                intents.markOwn([id])
            }
            // Meist ist das Modell ausgelastet. Etwas Luft lassen.
            return true
        case .modelUnavailable(let reason):
            factsQueue.insert(entry, at: 0)
            waitReason = reason
            session.halted = true
        case .cancelled:
            factsQueue.insert(entry, at: 0)
            // Angehalten vom Tor: Es geht weiter, sobald es wieder aufgeht.
            if slot?.stoppedByStage != true { session.halted = true }
        }
        return false
    }

    /// Die Regeln nach einer Einordnung aus dem Rückstand.
    private func tagsFinished(_ episode: Episode, run: ChapterTagsRun, since ticket: RemovalLedger.Ticket) -> Bool {
        let id = episode.id
        guard !ledger.wasRemoved(id, since: ticket) else { return false }
        switch run.outcome {
        case .stored:
            if run.current { tagsCurrent.insert(id) }
            return false
        case .nothingToDo:
            // Sonst holte die nächste Portion dieselbe Folge wieder.
            tagsCurrent.insert(id)
            return false
        case .failed:
            // Ein zweiter Anlauf erst beim nächsten Start, ohne die Folge
            // dauerhaft aufzugeben: Der gemerkte Stand bleibt.
            tagsFailed.insert(id)
            return true
        case .modelUnavailable, .waiting, .cancelled:
            tagsQueue.insert(episode, at: 0)
            if slot?.stoppedByStage != true { session.tagsHalted = true }
            return false
        }
    }

    /// Eine Minute Pause nach einem Fehlschlag. Wer inzwischen selbst eine
    /// Folge anfordert, wartet nicht darauf.
    private func coolDown(_ token: UInt64) async {
        guard slot?.token == token else { return }
        slot?.cooling = true
        for _ in 0..<pauseSteps {
            if Task.isCancelled || slot?.token != token { return }
            if factsQueue.first?.requested == true { return }
            try? await Task.sleep(for: pauseStep)
        }
    }

    // MARK: - Merken und Melden

    /// Merkt die Warteschlange samt laufender Folge in `DeviceState`. Ohne
    /// gelöschte Folgen, und erst, wenn die gemerkte zurück ist.
    private func persistQueue() {
        guard restored else { return }
        var list: [FactsIntent] = []
        if case .facts(let entry) = slot?.work, !ledger.wasRemoved(entry.id, since: entry.ticket) {
            list.append(entry.intent)
        }
        for entry in factsQueue where !ledger.wasRemoved(entry.id, since: entry.ticket) {
            list.append(entry.intent)
        }
        guard list != persisted else { return }
        if intents.setFactsQueue(list) { persisted = list }
    }

    private func publish() {
        var running: Episode?
        if case .facts(let entry) = slot?.work { running = entry.episode }
        let snapshot = KnowledgeSnapshot(
            queue: factsQueue.map(\.episode), running: running, waitReason: waitReason, issues: issues)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        snapshotContinuation.yield(snapshot)
    }

    /// Sendet `factsDone` oder `tagsDone`, nachdem das Ergebnis gespeichert
    /// ist, mit der Eingangsfassung aus dem Store. Nur, wenn jemand zuhört,
    /// und nicht mehr, wenn die Folge seit `ticket` gelöscht wurde.
    private nonisolated func announce(
        _ kinds: [PipelineEvent.Kind], of id: EpisodeID, since ticket: RemovalLedger.Ticket,
        _ make: (InputVersion) -> [PipelineEvent]
    ) async {
        guard let host, kinds.contains(where: host.hasListeners(for:)) else { return }
        let store = await currentStore
        guard let media = try? await store.episodes(ids: [id]).first?.currentMediaVersionID,
              let fingerprint = try? await store.transcriptFingerprint(forMedia: media) else { return }
        host.emit(make(InputVersion(mediaVersionID: media, fingerprint: fingerprint)),
                  about: id, unlessRemovedSince: ticket, in: ledger)
    }

    private var currentStore: LibraryStore { store }

    // MARK: - Modelle

    static func isReady(_ status: ModelStatus, for profile: TaskProfile) -> Bool {
        if case .success = status.resolve(profile) { return true }
        return false
    }

    /// Ist ein Modell da oder wird es gerade vorbereitet? Fehlt es ganz,
    /// etwa weil Apple Intelligence aus ist, reiht die Stufe nichts ein.
    static func isExpected(_ status: ModelStatus, for profile: TaskProfile) -> Bool {
        switch status.resolve(profile) {
        case .success: true
        case .failure(let reason): reason == .modelNotReady
        }
    }

    // MARK: - Für Tests

    /// Die Kennungen der Warteschlange der Fakten, vorn zuerst.
    var queuedFacts: [EpisodeID] { factsQueue.map(\.id) }
    var queuedTags: [EpisodeID] { tagsQueue.map(\.id) }
    var isIdle: Bool { slot == nil }
    var snapshot: KnowledgeSnapshot { lastSnapshot }
}

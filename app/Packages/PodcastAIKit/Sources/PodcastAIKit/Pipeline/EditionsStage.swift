//
//  EditionsStage.swift
//  PodcastAIKit
//
//  Die Stufe „Ausgaben“: Ausgaben der Themen-Updates, ihre Zahlen und Cover
//  (docs/plan-pipeline.md, Schritt 4). Bis 0.13 rief das `AppModel` die
//  Automatik an drei Stellen direkt auf (nach dem Aktualisieren, wenn die
//  Transkripte durch sind, in `com.podcastai.analysis`) und schrieb jede
//  neue Ausgabe als ganze Liste ihres Updates.
//
//  Die Stufe übernimmt Auslöser, Tor und das Schreiben:
//
//  - Sie hört auf `feedsRefreshed` und `transcriptsIdle`, dieselben Stellen
//    wie bisher, und prüft dann die automatischen Updates. Beim Start und
//    nach einem Abgleich stellt sie nichts zusammen: Das wären neue
//    Auslöser, und diese Release ändert kein Verhalten. Der Start
//    aktualisiert ohnehin und sendet dabei `feedsRefreshed`.
//  - Befehle eines Menschen (Knopf, Siri, ein neues Update) kommen direkt,
//    mit `origin: .user`.
//  - Pause und „Alle abbrechen“ halten die Automatik an (Entscheidung 3).
//    Eine laufende automatische Ausgabe bricht ab, ohne dass es als
//    Fehlschlag zählt. Nach einer Pause holt die Stufe die Prüfung nach,
//    nach „Alle abbrechen“ erst der nächste Auslöser.
//  - Jeder Teil eines Laufs wird einzeln geschrieben, hinter dem Wächter
//    für jede seiner Folgen (`LibraryStore.commit(edition:since:)`). Der
//    Stand des Löschprotokolls ist der vom Beginn des Zusammenstellens:
//    Eine Folge, die währenddessen gelöscht wurde, verliert ihre Stellen,
//    auch wenn das Löschen die Stufe nie erreicht hat (Regel 5).
//  - Erst wenn das Schreiben zurückgekehrt ist, geht `editionPublished`
//    hinaus. Darauf rechnet die Stufe die Zahlen des Updates und legt die
//    Cover an.
//
//  Was eine Ausgabe enthält, entscheidet weiter der Code im `AppModel`
//  (`Environment.compose`): Kapitel, Auswahl, Teile und die Rückmeldung.
//  Er kennt Bestand, Tags und Hörstand. Die Stufe reicht ihm den Weg zum
//  Schreiben (`EditionCommitter`), damit keine Ausgabe am Wächter vorbei in
//  die Datenbank kommt.
//

import Foundation
import PodcastAICore
import PodcastAIIntelligence
import PodcastAIPersistence
import PodcastAISmartFeeds

/// Eine Ausgabe, um die jemand gebeten hat oder die die Automatik prüft.
public struct EditionRequest: Sendable, Equatable {
    public let feedID: SmartFeedID
    /// Eine andere Länge nur für diese Ausgabe, etwa von Siri.
    public let budget: MediaDuration?
    public let origin: Origin

    public init(feedID: SmartFeedID, budget: MediaDuration? = nil, origin: Origin) {
        self.feedID = feedID
        self.budget = budget
        self.origin = origin
    }

    /// Von Hand angefordert: ohne Mindestmenge, mit Anzeige.
    public var requestedByUser: Bool { origin == .user }
}

/// Der Weg, auf dem eine neue Ausgabe in die Datenbank kommt: je Teil eine
/// Zeile, hinter dem Wächter, mit dem Stand des Löschprotokolls vom Beginn
/// des Zusammenstellens.
public struct EditionCommitter: Sendable {
    /// Der Stand des Löschprotokolls, als das Zusammenstellen begann.
    public let ticket: RemovalLedger.Ticket
    public let ledger: RemovalLedger
    private let store: LibraryStore

    public init(store: LibraryStore, ledger: RemovalLedger, ticket: RemovalLedger.Ticket) {
        self.store = store
        self.ledger = ledger
        self.ticket = ticket
    }

    /// Schreibt die Teile eines Laufs in ihrer Reihenfolge und gibt zurück,
    /// was geschrieben wurde, ohne Stellen aus Folgen, die der Wächter
    /// ablehnte. Ein Teil ohne übrige Stelle fehlt, und gibt es das Update
    /// nicht mehr, wird nichts mehr geschrieben.
    ///
    /// Wurde die Arbeit vorher abgebrochen, etwa weil die Pause begann,
    /// schreibt es nichts und wirft `CancellationError`. Einmal begonnen,
    /// schreibt es alle Teile: Ein halber Lauf wäre schlimmer als ein
    /// ganzer, der einen Augenblick nach der Pause erscheint.
    public func commit(_ parts: [PersonalEpisode]) async throws -> [PersonalEpisode] {
        try Task.checkCancellation()
        var written: [PersonalEpisode] = []
        for part in parts {
            switch try await store.commit(edition: part, since: ticket, ledger: ledger) {
            case .written(let edition, _): written.append(edition)
            case .nothingLeft: continue
            case .feedMissing: return written
            }
        }
        return written
    }
}

/// Was beim Zusammenstellen herauskam.
public struct EditionComposition: Sendable {
    /// Der Satz für die Rückmeldung.
    public var note: String
    /// Die Teile, wie sie geschrieben wurden. Leer, wenn nichts erschien.
    public var published: [PersonalEpisode]
    /// Die Kapitel, aus denen ausgewählt wurde. Die Zahlen des Updates
    /// rechnen damit, statt die Bibliothek ein zweites Mal zu lesen.
    public var chapters: [EditionChapter]?

    public init(note: String, published: [PersonalEpisode] = [], chapters: [EditionChapter]? = nil) {
        self.note = note
        self.published = published
        self.chapters = chapters
    }
}

public actor EditionsStage {

    /// Was die Stufe beim Hauptakteur fragt und ihm meldet.
    public struct Environment: Sendable {
        /// Die automatischen Updates, deren nächste Ausgabe jetzt entstehen
        /// darf (`AppModel.earliestAutomaticEdition` ist `nil`).
        public var dueFeeds: @Sendable () async -> [SmartFeedID]
        /// Stellt eine Ausgabe zusammen und schreibt sie über den
        /// `EditionCommitter`. Gibt die Rückmeldung und das Geschriebene zurück.
        public var compose: @Sendable (EditionRequest, EditionCommitter) async -> EditionComposition
        /// Eine Ausgabe ist gespeichert und gemeldet: Zahlen des Updates,
        /// dazu die Cover, wenn `covers` gilt.
        public var published: @Sendable (_ feedID: SmartFeedID, _ parts: [PersonalEpisodeID],
                                         _ chapters: [EditionChapter]?, _ origin: Origin,
                                         _ covers: Bool) async -> Void
        /// Nach einem Durchgang der Automatik: die Zahlen aller Updates.
        public var refreshStatistics: @Sendable () async -> Void
        /// Holt die Cover der neuesten Ausgaben nach, die während der Pause
        /// ausblieben.
        public var prepareMissingCovers: @Sendable () async -> Void

        public init(
            dueFeeds: @escaping @Sendable () async -> [SmartFeedID],
            compose: @escaping @Sendable (EditionRequest, EditionCommitter) async -> EditionComposition,
            published: @escaping @Sendable (SmartFeedID, [PersonalEpisodeID], [EditionChapter]?, Origin, Bool)
                async -> Void,
            refreshStatistics: @escaping @Sendable () async -> Void,
            prepareMissingCovers: @escaping @Sendable () async -> Void
        ) {
            self.dueFeeds = dueFeeds
            self.compose = compose
            self.published = published
            self.refreshStatistics = refreshStatistics
            self.prepareMissingCovers = prepareMissingCovers
        }
    }

    /// Ein Lauf, der geschrieben ist und auf sein Ereignis wartet.
    private struct PublishedRun: Sendable {
        let parts: [PersonalEpisodeID]
        let chapters: [EditionChapter]?
        let origin: Origin
    }

    private var store: LibraryStore
    private let gate: WorkGate
    private let ledger: RemovalLedger
    private let host: PipelineHost?
    private let mailbox: AsyncStream<PipelineEvent>?
    private let environment: Environment

    /// Der laufende Durchgang der Automatik.
    private var automatic: Task<Void, Never>?
    /// Während des Durchgangs kam ein weiterer Auslöser.
    private var automaticAgain = false
    /// Die Pause hielt eine Prüfung auf. Sie kommt, sobald das Tor aufgeht.
    private var heldCheck = false
    /// Die Pause hielt Cover auf.
    private var heldCovers = false
    /// Geschriebene Läufe je Update, bis ihr `editionPublished` ankommt.
    private var awaitingEvent: [SmartFeedID: PublishedRun] = [:]
    private var listeners: [Task<Void, Never>] = []
    private var started = false

    public init(store: LibraryStore, gate: WorkGate, ledger: RemovalLedger = .shared,
                host: PipelineHost?, environment: Environment) {
        self.store = store
        self.gate = gate
        self.ledger = ledger
        self.host = host
        // Das Postfach öffnet sich schon hier, damit kein Ereignis zwischen
        // Anlegen und `start()` verloren geht.
        self.mailbox = host?.mailbox(for: .editions)
        self.environment = environment
    }

    /// Hört auf Postfach und Tor. Einmal, aus `AppBootstrap.start`.
    public func start() {
        guard !started else { return }
        started = true
        if let mailbox {
            listeners.append(Task { [weak self] in
                for await event in mailbox { await self?.receive(event) }
            })
        }
        let conditions = gate.updates()
        listeners.append(Task { [weak self] in
            for await next in conditions { await self?.gateChanged(next) }
        })
    }

    /// Hört auf und bricht die Automatik ab.
    public func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        automatic?.cancel()
        started = false
    }

    /// Ein anderer Speicher, etwa nach einem zweiten Versuch beim Start.
    /// Was für den alten wartete, fällt weg.
    public func reset(store newStore: LibraryStore) {
        store = newStore
        automatic?.cancel()
        automaticAgain = false
        heldCheck = false
        awaitingEvent.removeAll()
    }

    // MARK: - Ereignisse

    func receive(_ event: PipelineEvent) async {
        switch event {
        case .feedsRefreshed, .transcriptsIdle:
            // Neue Folgen oder frisch ausgewertetes Material: genau das,
            // worauf die automatischen Updates warten.
            triggerAutomatic()
        case .editionPublished(let feedID, let parts):
            published(feedID, parts)
        case .changedElsewhere:
            // Die Ausgaben liest der Hauptakteur neu. Die Stufe merkt sich
            // nur, was auf sein Ereignis wartet, und das ist dann alt.
            awaitingEvent.removeAll()
        case .episodesRemoved:
            // Nichts zu vergessen: Die Stellen einer gelöschten Folge nimmt
            // der Wächter beim Schreiben heraus, schon geschriebene die Pflege.
            break
        case .episodesAdded, .audioAvailable, .audioRemoved, .transcriptSaved, .transcriptFailed,
             .evidenceReady, .factsDone, .tagsDone:
            // Laut Router nicht für diese Stufe.
            break
        }
    }

    /// Das Tor hat sich geändert. Pause und „Alle abbrechen“ halten die
    /// Automatik an, ohne dass es als Fehlschlag zählt.
    func gateChanged(_ conditions: WorkConditions) {
        guard conditions.mayRun(.editions, origin: .automatic) else {
            if automatic != nil {
                automatic?.cancel()
                // Nach „Alle abbrechen“ kommt die Prüfung erst mit dem
                // nächsten Auslöser, nach einer Pause, sobald sie endet.
                if !conditions.cancelling { heldCheck = true }
            }
            if conditions.cancelling { heldCheck = false }
            return
        }
        if heldCheck {
            heldCheck = false
            triggerAutomatic()
        }
        if heldCovers {
            heldCovers = false
            let environment = self.environment
            Task { await environment.prepareMissingCovers() }
        }
    }

    // MARK: - Befehle

    /// Stellt eine Ausgabe zusammen, um die jemand gebeten hat, und gibt
    /// die Rückmeldung zurück. Startet nie Ton.
    public func build(_ request: EditionRequest) async -> String {
        let committer = EditionCommitter(store: store, ledger: ledger, ticket: ledger.ticket)
        let result = await environment.compose(request, committer)
        announce(result, for: request)
        return result.note
    }

    /// Prüft die automatischen Updates und wartet, bis der Durchgang fertig
    /// ist. Für `com.podcastai.analysis`: Die Aufgabe endet erst danach.
    public func runAutomatic() async {
        guard gate.mayRun(.editions, origin: .automatic) else {
            if !gate.current.cancelling { heldCheck = true }
            return
        }
        if automatic == nil { startAutomatic() } else { automaticAgain = true }
        await automatic?.value
    }

    /// „Alle abbrechen“: Die Automatik hält an, bis der nächste Auslöser kommt.
    public func cancelAll() async {
        let running = automatic
        running?.cancel()
        automaticAgain = false
        heldCheck = false
        await running?.value
    }

    /// Darf ein Cover, das von selbst entsteht, jetzt beginnen? Merkt sich
    /// sonst, dass es nach der Pause nachzuholen ist.
    public func mayPrepareAutomaticCovers() -> Bool {
        if gate.mayRun(.editions, origin: .automatic) { return true }
        heldCovers = true
        return false
    }

    // MARK: - Automatik

    private func triggerAutomatic() {
        guard gate.mayRun(.editions, origin: .automatic) else {
            if !gate.current.cancelling { heldCheck = true }
            return
        }
        if automatic == nil { startAutomatic() } else { automaticAgain = true }
    }

    private func startAutomatic() {
        automatic = Task { [weak self] in
            guard let self else { return }
            await self.automaticLoop()
        }
    }

    private func automaticLoop() async {
        repeat {
            automaticAgain = false
            await automaticPass()
        } while automaticAgain && !Task.isCancelled
        automatic = nil
    }

    /// Veröffentlicht höchstens eine Ausgabe je Update und Durchgang: fünf
    /// auf einmal wären keine Neuigkeit mehr, sondern eine Flut.
    private func automaticPass() async {
        for feedID in await environment.dueFeeds() {
            guard !Task.isCancelled, gate.mayRun(.editions, origin: .automatic) else { return }
            let request = EditionRequest(feedID: feedID, origin: .automatic)
            let committer = EditionCommitter(store: store, ledger: ledger, ticket: ledger.ticket)
            let result = await environment.compose(request, committer)
            announce(result, for: request)
        }
        guard !Task.isCancelled else { return }
        await environment.refreshStatistics()
    }

    // MARK: - Nach dem Schreiben

    /// Meldet einen geschriebenen Lauf. Das Ereignis geht erst hinaus, wenn
    /// das Schreiben zurückgekehrt ist, und das ist es hier.
    private func announce(_ result: EditionComposition, for request: EditionRequest) {
        guard let feedID = result.published.first?.feedID else { return }
        let parts = result.published.map(\.id)
        awaitingEvent[feedID] = PublishedRun(parts: parts, chapters: result.chapters, origin: request.origin)
        if let host, host.listeningStages.contains(.editions) {
            host.emit(.editionPublished(feedID, parts))
        } else {
            // Ohne Postfach, etwa in einem Test ohne Host: gleich weiter.
            published(feedID, parts)
        }
    }

    /// Eine Ausgabe ist erschienen: Zahlen des Updates und Cover. Cover
    /// einer automatischen Ausgabe warten die Pause ab. Die Stufe wartet
    /// nicht darauf, damit das Postfach weiter angenommen wird.
    private func published(_ feedID: SmartFeedID, _ parts: [PersonalEpisodeID]) {
        let run = awaitingEvent[feedID].flatMap { $0.parts == parts ? $0 : nil }
        if run != nil { awaitingEvent[feedID] = nil }
        let origin = run?.origin ?? .automatic
        let covers = origin == .user || mayPrepareAutomaticCovers()
        let environment = self.environment
        Task { await environment.published(feedID, parts, run?.chapters, origin, covers) }
    }
}

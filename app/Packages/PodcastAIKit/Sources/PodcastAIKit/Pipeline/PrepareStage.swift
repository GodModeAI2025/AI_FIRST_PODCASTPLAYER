//
//  PrepareStage.swift
//  PodcastAIKit
//
//  Die Stufe „Vorbereiten“: was von selbst in die Warteschlange der
//  Transkripte kommt, samt Metadaten von Supadata (docs/plan-pipeline.md,
//  Schritt 5a). Bis 0.13 rief das `AppModel` `prepareNewEpisodes` an jeder
//  Stelle direkt auf, an der neue Folgen ankamen, und nach jeder fertigen
//  älteren Folge `refillBackCatalog`.
//
//  Die Stufe übernimmt Auslöser, Reihenfolge der Durchgänge und die
//  Prüfung im Store:
//
//  - Sie hört auf `episodesAdded` (die Quellen dieser Folgen) und
//    `feedsRefreshed` (alle Quellen), dieselben Stellen wie bisher. Auch
//    ohne neue Folgen: Nach „Alle abbrechen“ und einem Aktualisieren von
//    Hand reiht sie wieder ein, was ruhte.
//  - Befehle kommen direkt: ein Schalter, „Ältere Folgen auch vorbereiten“,
//    das Öffnen einer Quelle.
//  - Nach einer älteren Folge rückt die nächste nach, auf `evidenceReady`
//    und `transcriptFailed` mit Herkunft `.backlog`.
//  - Ein von selbst eingereihtes Transkript, das an etwas scheiterte, das
//    beim nächsten Versuch wieder käme, merkt sie sich auf `transcriptFailed`
//    (`failedInPreparation`), damit das nächste Aktualisieren es nicht
//    wieder nimmt.
//  - Vor dem Einreihen fragt sie den Store, ob die Fassung schon Belege
//    mit Zeitmarke hat (Vertrag (I)), dasselbe Merkmal wie bisher. Bis 0.13 fragte die App nur ihren
//    Speicher, und der kannte ein Transkript von einem anderen Gerät erst
//    nach dem nächsten Laden.
//  - Einreihen hält keine Pause an (architektur.md: „Was das Vorbereiten
//    währenddessen findet, reiht sich nur ein.“). Die Metadaten von
//    Supadata warten dagegen auf das Tor (Entscheidung 3).
//
//  Welche Folgen in Frage kommen, entscheidet weiter der Code im `AppModel`
//  (`Environment.candidates`): Er kennt Abos, Schalter, Warteschlange und
//  die Vermerke dieses Geräts. Der Auftrag an das Transkript geht ebenso
//  über den Hauptakteur, wie in Schritt 3a bei der Stufe „Wissen“.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

/// Eine Folge, die das Vorbereiten einreihen würde.
public struct PreparationCandidate: Sendable, Equatable {
    public let episode: Episode
    /// Eine ältere Folge aus „Ältere Folgen auch vorbereiten“.
    public let backlog: Bool

    public init(episode: Episode, backlog: Bool) {
        self.episode = episode
        self.backlog = backlog
    }

    /// Die Fassung, an der ihr Transkript hängen würde: die Audiodatei aus
    /// dem Feed oder die Adresse des Videos. Dieselbe Regel wie im Wächter.
    public var media: MediaVersionID? { CaptionAnalysis.feedMediaVersionID(of: episode) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episode.id == rhs.episode.id && lhs.backlog == rhs.backlog
    }
}

public actor PrepareStage {

    /// Was die Stufe beim Hauptakteur fragt und ihm aufträgt.
    public struct Environment: Sendable {
        /// Die jüngsten offenen Folgen dieser Quellen (`nil`: aller), die das
        /// Vorbereiten nähme. Leer, wenn es von selbst nichts vorbereiten soll.
        public var candidates: @Sendable (_ sources: [SourceID]?) async -> [PreparationCandidate]
        /// Die Portion älterer Folgen eines Podcasts, die jetzt nachrücken darf.
        public var backCatalog: @Sendable (_ source: SourceID) async -> [PreparationCandidate]
        /// Reiht ein, von selbst, in dieser Reihenfolge.
        public var enqueue: @Sendable ([PreparationCandidate]) async -> Void
        /// Diese Folgen haben laut Store schon Transkript und Belege. Das
        /// Vorbereiten nimmt sie in diesem Start nicht wieder.
        public var alreadyTranscribed: @Sendable (Set<EpisodeID>) async -> Void
        /// Ein von selbst eingereihtes Transkript ist gescheitert, und der
        /// Fehler käme beim nächsten Versuch wieder.
        public var markFailed: @Sendable (EpisodeID) async -> Void
        /// Diese Folgen sind gelöscht: Was die Stufe über sie vermerkt hat, geht.
        public var forget: @Sendable (Set<EpisodeID>) async -> Void
        /// Holt fehlende Metadaten über Supadata.
        public var fetchMetadata: @Sendable () async -> Void

        public init(
            candidates: @escaping @Sendable ([SourceID]?) async -> [PreparationCandidate],
            backCatalog: @escaping @Sendable (SourceID) async -> [PreparationCandidate],
            enqueue: @escaping @Sendable ([PreparationCandidate]) async -> Void,
            alreadyTranscribed: @escaping @Sendable (Set<EpisodeID>) async -> Void,
            markFailed: @escaping @Sendable (EpisodeID) async -> Void,
            forget: @escaping @Sendable (Set<EpisodeID>) async -> Void,
            fetchMetadata: @escaping @Sendable () async -> Void
        ) {
            self.candidates = candidates
            self.backCatalog = backCatalog
            self.enqueue = enqueue
            self.alreadyTranscribed = alreadyTranscribed
            self.markFailed = markFailed
            self.forget = forget
            self.fetchMetadata = fetchMetadata
        }
    }

    /// Was ein Durchgang vorbereiten soll.
    private enum Scope: Sendable, Equatable {
        /// Alle Quellen, samt ihrer älteren Folgen.
        case all
        /// Diese Quellen, samt ihrer älteren Folgen.
        case sources(Set<SourceID>)

        func merged(with other: Scope) -> Scope {
            switch (self, other) {
            case (.sources(let a), .sources(let b)): .sources(a.union(b))
            default: .all
            }
        }
    }

    /// So oft rückt die nächste Portion älterer Folgen in einem Zug nach,
    /// wenn der Store Folgen der vorigen schon als transkribiert kannte.
    static let refillRounds = 5

    private var store: LibraryStore
    private let gate: WorkGate
    private let ledger: RemovalLedger
    private let mailbox: AsyncStream<PipelineEvent>?
    private let environment: Environment

    /// Der laufende Durchgang.
    private var pass: Task<Void, Never>?
    /// Was nach dem laufenden Durchgang noch vorzubereiten ist.
    private var pendingScope: Scope?
    /// Quellen, deren ältere Folgen nachrücken sollen.
    private var pendingRefills: [SourceID] = []
    /// Die Pause hielt die Metadaten auf. Sie kommen, sobald das Tor aufgeht.
    private var heldMetadata = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeners: [Task<Void, Never>] = []
    private var started = false

    public init(store: LibraryStore, gate: WorkGate, ledger: RemovalLedger = .shared,
                host: PipelineHost?, environment: Environment) {
        self.store = store
        self.gate = gate
        self.ledger = ledger
        // Das Postfach öffnet sich schon hier, damit kein Ereignis zwischen
        // Anlegen und `start()` verloren geht.
        self.mailbox = host?.mailbox(for: .prepare)
        self.environment = environment
    }

    /// Hört auf Postfach und Tor. Einmal, aus `AppBootstrap.start`.
    public func start() {
        guard !started else { return }
        started = true
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
        pass?.cancel()
        started = false
    }

    /// Ein anderer Speicher, etwa nach einem zweiten Versuch beim Start.
    public func reset(store newStore: LibraryStore) {
        store = newStore
        pendingScope = nil
        pendingRefills.removeAll()
    }

    // MARK: - Ereignisse

    func receive(_ event: PipelineEvent) async {
        switch event {
        case .episodesAdded(let ids, _):
            // Die Quellen der neuen Folgen. Welche das sind, weiß der Store.
            let sources = (try? await store.episodes(ids: ids))?.map(\.sourceID) ?? []
            guard !sources.isEmpty else { return }
            schedule(.sources(Set(sources)))
        case .feedsRefreshed:
            // Auch ohne neue Folgen: Was nach „Alle abbrechen“ ruhte und von
            // Hand aktualisiert wurde, kommt wieder dazu.
            schedule(.all)
        case .evidenceReady(let id, _, let origin):
            // Eine ältere Folge ist fertig: Die nächste rückt nach.
            if origin == .backlog { await refill(after: id) }
        case .transcriptFailed(let id, let failure, let origin):
            // Merken, was beim nächsten Aktualisieren wieder scheiterte. Nur
            // für Folgen mit Ton, die die App von selbst eingereiht hat; was
            // jemand anfordert, versucht sie immer. Die Wartezeit nach einem
            // Fehlversuch bei Supadata merkt sich die Folge selbst.
            if origin != .user, failure.kind == .permanent || failure.kind == .localeNotSupported {
                await environment.markFailed(id)
            }
            if origin == .backlog { await refill(after: id) }
        case .episodesRemoved(let ids, _):
            // Die Vermerke gelöschter Folgen räumt die Pflege. Kam ein
            // Fehlschlag vor dem Löschen an und wurde erst danach vermerkt,
            // nimmt ihn dieser Schritt wieder heraus: Das Löschen steht im
            // Postfach hinter jedem früheren Ereignis derselben Folge (Regel 5).
            await environment.forget(Set(ids))
        case .changedElsewhere:
            // Kein neuer Auslöser: Bis 0.13 bereitete ein Abgleich nichts vor.
            break
        case .audioAvailable, .audioRemoved, .transcriptSaved, .transcriptsIdle, .factsDone, .tagsDone,
             .editionPublished:
            // Laut Router nicht für diese Stufe.
            break
        }
    }

    /// Nach der Pause kommen die Metadaten, die sie aufhielt. Nach „Alle
    /// abbrechen“ erst mit dem nächsten Auslöser.
    func gateChanged(_ conditions: WorkConditions) {
        if conditions.cancelling { heldMetadata = false }
        guard heldMetadata, conditions.mayRun(.metadata, origin: .automatic) else { return }
        heldMetadata = false
        let environment = self.environment
        Task(priority: .utility) { await environment.fetchMetadata() }
    }

    // MARK: - Befehle

    /// Bereitet vor, was in diesen Quellen offen ist (`nil`: in allen), und
    /// wartet, bis der Durchgang fertig ist. Für Schalter, das Öffnen einer
    /// Quelle und „Ältere Folgen auch vorbereiten“.
    public func prepare(sources: [SourceID]? = nil) async {
        schedule(sources.map { .sources(Set($0)) } ?? .all)
        await untilIdle()
    }

    /// Die nächste Portion älterer Folgen eines Podcasts, nach einer älteren
    /// Folge, die ohne Ereignis endete.
    public func refill(_ source: SourceID) {
        if !pendingRefills.contains(source) { pendingRefills.append(source) }
        startPassIfNeeded()
    }

    /// Wartet, bis kein Durchgang mehr läuft.
    public func untilIdle() async {
        guard pass != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Durchgänge

    private func refill(after id: EpisodeID) async {
        guard let source = try? await store.episodes(ids: [id]).first?.sourceID else { return }
        refill(source)
    }

    private func schedule(_ scope: Scope) {
        pendingScope = pendingScope.map { $0.merged(with: scope) } ?? scope
        startPassIfNeeded()
    }

    private func startPassIfNeeded() {
        guard pass == nil else { return }
        pass = Task(priority: .utility) { [weak self] in
            await self?.runPasses()
        }
    }

    /// Arbeitet ab, was ansteht, bis nichts mehr ansteht. Anlässe während
    /// eines Durchgangs sammeln sich zu einem weiteren.
    private func runPasses() async {
        while !Task.isCancelled {
            if let scope = pendingScope {
                pendingScope = nil
                await runPass(scope)
            } else if !pendingRefills.isEmpty {
                let source = pendingRefills.removeFirst()
                await refillBackCatalog(source)
            } else {
                break
            }
        }
        pass = nil
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Erst die neuesten Folgen aller Podcasts, dann die älteren. So wartet
    /// eine neue Folge nicht hinter dem Archiv eines anderen Podcasts.
    private func runPass(_ scope: Scope) async {
        let requested: [SourceID]? = switch scope {
        case .all: nil
        case .sources(let set): Array(set)
        }
        let ticket = ledger.ticket
        let newest = await environment.candidates(requested)
        await enqueue(newest, since: ticket)
        // Dann die älteren Folgen jeder dieser Quellen, in der Reihenfolge
        // des Stores. Ob eine Quelle „Ältere Folgen auch vorbereiten“ hat,
        // weiß der Hauptakteur; die übrigen liefern nichts.
        var sources = requested ?? []
        if requested == nil { sources = (try? await store.sources())?.map(\.id) ?? [] }
        for source in sources {
            await refillBackCatalog(source)
        }
        await fetchMetadataIfAllowed()
    }

    /// Die nächste Portion älterer Folgen eines Podcasts. Kannte der Store
    /// eine davon schon als transkribiert, rückt gleich die nächste nach.
    private func refillBackCatalog(_ source: SourceID) async {
        for _ in 0..<Self.refillRounds {
            let ticket = ledger.ticket
            let batch = await environment.backCatalog(source)
            guard !batch.isEmpty else { return }
            let skipped = await enqueue(batch, since: ticket)
            guard !skipped.isEmpty else { return }
        }
    }

    /// Reiht ein, was laut Store noch keine Belege hat. Gibt die Folgen
    /// zurück, die schon welche hatten. `ticket`: der Stand des Löschprotokolls,
    /// bevor die Stufe den Hauptakteur fragte.
    @discardableResult
    private func enqueue(_ candidates: [PreparationCandidate], since ticket: RemovalLedger.Ticket) async
        -> Set<EpisodeID> {
        guard !candidates.isEmpty else { return [] }
        let media = candidates.compactMap(\.media)
        let done = (try? await store.mediaVersionsWithEvidence(media)) ?? []
        var skipped: Set<EpisodeID> = []
        var open: [PreparationCandidate] = []
        for candidate in candidates {
            // Seit dem Fragen gelöscht: Das Löschen hat die Folge vielleicht
            // noch nicht aus den Listen des Hauptakteurs genommen.
            guard !ledger.wasRemoved(candidate.episode.id, since: ticket) else { continue }
            if let id = candidate.media, done.contains(id) {
                skipped.insert(candidate.episode.id)
            } else {
                open.append(candidate)
            }
        }
        if !skipped.isEmpty { await environment.alreadyTranscribed(skipped) }
        if !open.isEmpty { await environment.enqueue(open) }
        return skipped
    }

    private func fetchMetadataIfAllowed() async {
        guard gate.mayRun(.metadata, origin: .automatic) else {
            if !gate.current.cancelling { heldMetadata = true }
            return
        }
        await environment.fetchMetadata()
    }
}

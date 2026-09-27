//
//  DownloadStage.swift
//  PodcastAIKit
//
//  Die Stufe „Download“: die neueste Folge je Podcast vorhalten, den Ton
//  der nächsten Folgen der Warteschlange vorausladen und Ton aufräumen, der
//  nicht mehr aufs Gerät gehört (docs/plan-pipeline.md, Schritt 5a).
//
//  Den Ton für ein Transkript lädt weiter `ContentPipeline`: Laden hätte
//  sonst zwei Besitzer (Gegenprüfung). Die Stufe übernimmt nur die Auslöser
//  und das Tor, die bis 0.13 verstreut im `AppModel` lagen:
//
//  - Vorhalten auf `episodesAdded` und `feedsRefreshed`, wie bisher nach
//    jedem Vorbereiten, eine Folge nach der anderen. Liegt der Ton danach
//    auf dem Gerät, geht `audioAvailable` hinaus: Ein Transkript, das aufs
//    Netz wartete, kann laufen.
//  - Pause und „Alle abbrechen“ halten das Vorhalten an (Entscheidung 3).
//    Die laufende Übertragung lädt zu Ende, sonst gälte sie als von Hand
//    abgebrochen, und die App holte die Folge nie wieder von selbst. Nach
//    der Pause geht es weiter, nach „Alle abbrechen“ erst mit dem nächsten
//    Auslöser.
//  - Ton aufräumen nach dem Transkript (`evidenceReady`), nach einem
//    gescheiterten Vorbereiten (`transcriptFailed`, nicht bei einer Folge,
//    die jemand angefordert hat) und nach dem Aktualisieren.
//  - Vorausladen ist ein Befehl der Warteschlange der Transkripte, wenn sie
//    die nächste Folge beginnt.
//
//  Was „die neueste Folge“ ist und was aufgeräumt wird, entscheidet weiter
//  der Code im `AppModel` (`AudioRetention`, Speicher, Player). Er läuft
//  über `Environment`, wie in Schritt 3a bei der Stufe „Wissen“.
//

import Foundation
import PodcastAICore

public actor DownloadStage {

    /// Was die Stufe beim Hauptakteur fragt und ihm aufträgt.
    public struct Environment: Sendable {
        /// Die nächste neueste Folge, die aufs Gerät gehört und noch fehlt.
        /// `nil`, wenn keine fehlt oder das Netz das Vorbereiten nicht erlaubt.
        public var nextPrefetch: @Sendable () async -> Episode?
        /// Lädt den Ton dieser Folge. Gibt die Fassung zurück, wenn er danach
        /// auf dem Gerät liegt.
        public var prefetch: @Sendable (Episode) async -> MediaVersionID?
        /// Räumt Ton weg, der nach den Einstellungen nicht mehr aufs Gerät gehört.
        public var tidy: @Sendable () async -> Void
        /// Das Transkript dieser Folge ist fertig: ihr Ton geht, wenn so eingestellt.
        public var afterTranscript: @Sendable (EpisodeID) async -> Void
        /// Das Transkript dieser von selbst eingereihten Folge ist gescheitert:
        /// Der Ton war nur dafür da.
        public var afterFailedPreparation: @Sendable (EpisodeID) async -> Void
        /// Lädt den Ton der nächsten Folgen der Warteschlange im Voraus.
        public var lookahead: @Sendable () async -> Void

        public init(
            nextPrefetch: @escaping @Sendable () async -> Episode?,
            prefetch: @escaping @Sendable (Episode) async -> MediaVersionID?,
            tidy: @escaping @Sendable () async -> Void,
            afterTranscript: @escaping @Sendable (EpisodeID) async -> Void,
            afterFailedPreparation: @escaping @Sendable (EpisodeID) async -> Void,
            lookahead: @escaping @Sendable () async -> Void
        ) {
            self.nextPrefetch = nextPrefetch
            self.prefetch = prefetch
            self.tidy = tidy
            self.afterTranscript = afterTranscript
            self.afterFailedPreparation = afterFailedPreparation
            self.lookahead = lookahead
        }
    }

    private let gate: WorkGate
    private let ledger: RemovalLedger
    private let host: PipelineHost?
    private let mailbox: AsyncStream<PipelineEvent>?
    private let environment: Environment

    /// Das laufende Vorhalten.
    private var prefetching: Task<Void, Never>?
    /// Während des Vorhaltens kam ein weiterer Anlass.
    private var prefetchAgain = false
    /// Das Tor hielt das Vorhalten auf. Es kommt, sobald das Tor aufgeht.
    private var heldPrefetch = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeners: [Task<Void, Never>] = []
    private var started = false

    public init(gate: WorkGate, ledger: RemovalLedger = .shared, host: PipelineHost?, environment: Environment) {
        self.gate = gate
        self.ledger = ledger
        self.host = host
        // Das Postfach öffnet sich schon hier, damit kein Ereignis zwischen
        // Anlegen und `start()` verloren geht.
        self.mailbox = host?.mailbox(for: .download)
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
        prefetching?.cancel()
        started = false
    }

    // MARK: - Ereignisse

    func receive(_ event: PipelineEvent) async {
        switch event {
        case .episodesAdded:
            // Eine neue neueste Folge: vorhalten, danach die bisherige aufräumen.
            requestPrefetch()
        case .feedsRefreshed:
            // Wie bis 0.13 nach dem Aktualisieren: vorhalten und aufräumen.
            requestPrefetch()
            await tidyUnlessPrefetching()
        case .evidenceReady(let id, _, _):
            // Die Datei gehört jetzt zum Transkript. Ob sie bleibt, sagen die
            // Einstellungen. Eine inzwischen gelöschte Folge findet der
            // Hauptakteur nicht mehr, ihre Datei räumt die Pflege.
            await environment.afterTranscript(id)
        case .transcriptFailed(let id, _, let origin):
            // Was jemand angefordert hat, behält seinen Ton. Von selbst
            // Geladenes ginge sonst nie wieder vom Gerät.
            guard origin != .user else { return }
            await environment.afterFailedPreparation(id)
        case .audioRemoved:
            // Der Ton ist schon weg. Worauf ein Transkript nun wartet, rechnet
            // die Warteschlange der Transkripte neu.
            break
        case .episodesRemoved:
            // Laufende Übertragungen gelöschter Folgen bricht das Löschen
            // selbst ab, samt ihren Vermerken fürs Vorhalten.
            break
        case .changedElsewhere:
            // Kein neuer Auslöser: Bis 0.13 lud ein Abgleich nichts.
            break
        case .audioAvailable, .transcriptSaved, .transcriptsIdle, .factsDone, .tagsDone, .editionPublished:
            // Laut Router nicht für diese Stufe.
            break
        }
    }

    /// Nach der Pause geht das Vorhalten weiter. Nach „Alle abbrechen“ erst
    /// mit dem nächsten Auslöser.
    func gateChanged(_ conditions: WorkConditions) {
        if conditions.cancelling { heldPrefetch = false }
        guard heldPrefetch, conditions.mayRun(.prefetch, origin: .automatic) else { return }
        heldPrefetch = false
        requestPrefetch()
    }

    // MARK: - Befehle

    /// Hält die neueste Folge je Podcast vor, eine nach der anderen, und
    /// räumt danach auf. Für Schalter, das Netz und das Vorbereiten.
    public func prefetch() {
        requestPrefetch()
    }

    /// Räumt auf, sobald kein Vorhalten mehr läuft. Läuft eines, räumt es
    /// am Ende ohnehin auf.
    public func tidy() async {
        await tidyUnlessPrefetching()
    }

    /// Lädt den Ton der nächsten Folgen der Warteschlange im Voraus.
    public func lookahead() async {
        await environment.lookahead()
    }

    /// „Alle abbrechen“: Nach der laufenden Übertragung kommt keine weitere,
    /// bis der nächste Auslöser kommt.
    public func cancelAll() {
        prefetchAgain = false
        heldPrefetch = false
        prefetching?.cancel()
    }

    /// Wartet, bis kein Vorhalten mehr läuft.
    public func untilIdle() async {
        guard prefetching != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Vorhalten

    private func requestPrefetch() {
        guard gate.mayRun(.prefetch, origin: .automatic) else {
            if !gate.current.cancelling { heldPrefetch = true }
            return
        }
        guard prefetching == nil else {
            prefetchAgain = true
            return
        }
        prefetching = Task(priority: .utility) { [weak self] in
            await self?.prefetchLoop()
        }
    }

    private func prefetchLoop() async {
        repeat {
            prefetchAgain = false
            await prefetchPass()
        } while prefetchAgain && !Task.isCancelled
        prefetching = nil
        // Die bisherige neueste Folge bleibt, bis der Ton der neuen da ist.
        // Jetzt ist er da, oder er kommt nicht.
        await environment.tidy()
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func prefetchPass() async {
        // Jede Folge einmal je Durchgang. Käme dieselbe wieder, etwa weil
        // ihre Datei nach dem Laden doch fehlt, endete die Schleife nie.
        var tried: Set<EpisodeID> = []
        while !Task.isCancelled {
            guard gate.mayRun(.prefetch, origin: .automatic) else {
                if !gate.current.cancelling { heldPrefetch = true }
                return
            }
            guard let episode = await environment.nextPrefetch(),
                  tried.insert(episode.id).inserted else { return }
            let ticket = ledger.ticket
            guard let media = await environment.prefetch(episode) else { continue }
            // Erst wenn die Datei liegt, und nur für eine Folge, die es noch gibt.
            if let host {
                host.emit([.audioAvailable(episode.id, media)], about: episode.id,
                          unlessRemovedSince: ticket, in: ledger)
            }
        }
    }

    /// Läuft ein Vorhalten, räumt es an seinem Ende auf.
    private func tidyUnlessPrefetching() async {
        guard prefetching == nil else { return }
        await environment.tidy()
    }
}

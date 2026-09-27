//
//  PipelineSink.swift
//  PodcastAI
//
//  Die App an der Stufen-Pipeline (docs/plan-pipeline.md).
//
//  Der alte Code sendet an den Stellen, an denen er bisher die nächste
//  Arbeit direkt aufruft, ein Ereignis an den `PipelineHost`. Ein Ereignis
//  ohne Zuhörer fällt im Host weg und kostet fast nichts. Ereignisse mit
//  Eingangsfassung müssen erst im Store lesen; das geschieht nur, wenn
//  jemand zuhört (`emit(_:of:media:_:)`).
//
//  Seit Schritt 3 hört die Stufe „Wissen“ zu (`KnowledgeStage` im Paket).
//  Im neuen Weg ersetzt `evidenceReady` den direkten Aufruf von
//  `enqueueFacts`, `feedsRefreshed` den von `queueMissingFacts` und
//  `episodesRemoved` den von `dropFromFactsQueue`.
//
//  Seit Schritt 4 hört die Stufe „Ausgaben“ zu (`EditionsStage` im Paket).
//  Im neuen Weg ersetzen `feedsRefreshed` und `transcriptsIdle` die
//  direkten Aufrufe von `processPendingEditions`, und `editionPublished`
//  stößt Zahlen und Cover an, die bisher gleich nach dem Zusammenstellen kamen.
//
//  Die Senke ist das Ende der Pipeline auf dem Hauptakteur. Sie schreibt
//  die Felder, die die Oberfläche heute liest, sobald eine Stufe sie
//  übernommen hat: für „Wissen“ `factsQueue`, `gatheringFacts`,
//  `factsWait`, `factsIssues` und `chapterTagsRevision`, dazu aus der
//  Arbeit an einer Folge (`KnowledgeJobs`, seit Schritt 3b abseits des
//  Hauptakteurs) `facts`, `factsInProgress`, `factsProgress`, `lastError`
//  und `chapterCache`. Stufe und Angabe der Transkripte folgen mit
//  Schritt 5; bis dahin schreibt sie dort nichts, denn sonst stünde jede
//  Änderung doppelt da und jede Ansage käme zweimal.
//

import Foundation
import PodcastAIKit

/// Das Ende der Pipeline auf dem Hauptakteur. Keine Ansicht abonniert
/// Ereignisse, die Oberfläche liest weiter das `AppModel`.
@MainActor
final class PipelineSink {

    private weak var model: AppModel?
    private var listeners: [Task<Void, Never>] = []

    init(model: AppModel) {
        self.model = model
    }

    /// Hört auf das Postfach der Senke. Einmal, aus `AppBootstrap.start`.
    func start(host: PipelineHost) {
        guard listeners.isEmpty else { return }
        let mailbox = host.mailbox(for: .sink)
        listeners.append(Task { [weak self] in
            for await event in mailbox { self?.receive(event) }
        })
    }

    /// Schreibt den Stand der Stufe „Wissen“ in die Felder, die Ansichten lesen.
    func follow(_ stage: KnowledgeStage) {
        let snapshots = stage.snapshots
        listeners.append(Task { [weak self] in
            for await snapshot in snapshots { self?.apply(snapshot) }
        })
    }

    /// Was die Senke mit einem Ereignis tut. Erschöpfend, damit ein neues
    /// Ereignis hier eine Entscheidung verlangt. Jeder offene Fall nennt,
    /// welcher Schritt ihn füllt.
    func receive(_ event: PipelineEvent) {
        guard let model else { return }
        switch event {
        case .transcriptSaved:
            // Schritt 5b: Stufe `.transcribed` der Folge.
            break
        case .evidenceReady:
            // Schritt 5b: Stufe `.evidenceExtracted`. Angesagt wird nur bei
            // `.user`, nie für Arbeit, die `reconcile()` gefunden hat.
            break
        case .tagsDone(_, _, let outcome, _):
            // Neue Kapitel-Tags: Offene Folgen und Tag-Seiten laden sie neu.
            // Ein Themen-Update lösen sie nicht aus (Entscheidung 6).
            if outcome == .stored { model.chapterTagsRevision += 1 }
        case .episodesRemoved:
            // Schritt 5: Stufe, Angabe und Fortschritt der Folgen fallen weg.
            // Fakten und Vermerke räumt bis dahin die Pflege.
            break
        case .episodesAdded, .audioAvailable, .audioRemoved, .transcriptFailed, .transcriptsIdle,
             .factsDone, .feedsRefreshed, .editionPublished, .changedElsewhere:
            // Laut Router nicht für die Senke.
            break
        }
    }

    /// Ein neuer Stand der Stufe „Wissen“. Geschrieben wird nur, was sich
    /// geändert hat, damit keine Ansicht ohne Grund neu zeichnet. Die Sätze
    /// entstehen hier, mit denselben Schlüsseln wie bisher im Modell.
    func apply(_ snapshot: KnowledgeSnapshot) {
        guard let model else { return }
        if model.factsQueue.map(\.id) != snapshot.queue.map(\.id) { model.factsQueue = snapshot.queue }
        if model.gatheringFacts?.id != snapshot.running?.id { model.gatheringFacts = snapshot.running }
        let wait = snapshot.waitReason.map { String(localized: "wartet: \($0.message)") }
        if model.factsWait != wait { model.factsWait = wait }
        let issues = snapshot.issues.mapValues { issue in
            switch issue {
            case .note(let note): note
            case .unspecified: String(localized: "Die Fakten konnten nicht ermittelt werden.")
            }
        }
        if model.factsIssues != issues { model.factsIssues = issues }
    }
}

// MARK: - Stufe „Wissen“: Meldungen der Arbeit an einer Folge

/// Fakten, Fortschritt, Fehlermeldung und nachgeladene Kapitel aus
/// `KnowledgeJobs`. Die Arbeit läuft seit Schritt 3b abseits des
/// Hauptakteurs, in beiden Stellungen des Schalters; was die Oberfläche
/// zeigt, schreibt nur die Senke.
extension PipelineSink: KnowledgeReporting {

    func factsStarted(_ id: EpisodeID) {
        model?.factsInProgress.insert(id)
    }

    func factsProgress(_ id: EpisodeID, fraction: Double) {
        model?.factsProgress[id] = fraction
    }

    func factsFinished(_ id: EpisodeID) {
        model?.factsInProgress.remove(id)
        model?.factsProgress[id] = nil
    }

    /// Geprüft wird hier, auf dem Hauptakteur, wo auch gelöscht wird. Eine
    /// späte Meldung legt die Fakten einer gelöschten Folge nicht wieder an,
    /// nachdem die Pflege sie weggeräumt hat.
    func showFacts(_ facts: [EpisodeFact]?, for id: EpisodeID, unlessRemovedSince ticket: RemovalLedger.Ticket) {
        guard let model else { return }
        guard let facts else {
            model.facts[id] = nil
            return
        }
        guard !model.wasRemoved(id, since: ticket) else { return }
        model.facts[id] = facts
    }

    func reportError(_ message: String) {
        model?.lastError = message
    }

    /// Wie beim Öffnen der Folge (`loadChapters(for:)`): Die Kapitel gelten
    /// für diese Sitzung, und liegt die Folge im Player, bekommt er sie.
    func chaptersLoaded(_ chapters: [Chapter], for id: EpisodeID, unlessRemovedSince ticket: RemovalLedger.Ticket) {
        guard let model, !model.wasRemoved(id, since: ticket) else { return }
        model.chapterCache[id] = chapters
        if model.episodePlayer.episode?.id == id { model.episodePlayer.setChapters(chapters) }
    }
}

extension AppModel {

    /// Was die Stufe beim Einreihen wissen muss.
    var knowledgeSettings: KnowledgeSettings {
        KnowledgeSettings(isLoaded: isLoaded, automaticFacts: automaticFacts, analyzed: analyzedEpisodes)
    }

    /// Die Arbeit an einer Folge, für beide Stellungen des Schalters. Entsteht
    /// beim ersten Gebrauch, mit dem Speicher von jetzt.
    var knowledgeJobs: KnowledgeJobs {
        if let knowledgeJobsStorage { return knowledgeJobsStorage }
        let jobs = makeKnowledgeJobs(store: store)
        knowledgeJobsStorage = jobs
        return jobs
    }

    private func makeKnowledgeJobs(store: LibraryStore) -> KnowledgeJobs {
        // Ohne Pipeline, etwa in einer Vorschau, meldet eine Senke ohne Postfach.
        let reporter = pipelineSink ?? PipelineSink(model: self)
        let gate = pipeline?.gate
        let environment = KnowledgeJobs.Environment(
            refreshModel: { [weak self] in
                guard let self else { return ModelAvailabilityMonitor.shared.current }
                await self.refreshModelStatus(notifyingStage: false)
                return await MainActor.run { self.modelStatus }
            },
            networkAllowsPreparation: { [weak self] in
                await MainActor.run { self.map { $0.preparationWait == nil && !$0.isOffline } ?? false }
            },
            tagsMayContinue: { gate?.mayRun(.tags, origin: .automatic) ?? true },
            cachedChapters: { [weak self] id in
                await MainActor.run { self?.chapterCache[id] }
            },
            loadChapterFile: { [weak self] url in
                guard let refresher = await MainActor.run(body: { self?.refresher }) else { return nil }
                return await refresher.loadChapters(from: url)
            },
            describeError: { UserFacingError.describe($0) })
        return KnowledgeJobs(store: store, ledger: removals, reporter: reporter, environment: environment)
    }

    /// Legt die Stufe „Wissen“ an, wenn der Schalter an ist. Einmal, aus
    /// `AppBootstrap.start`, nach Host und Senke.
    func startKnowledgeStage() {
        // Die Arbeit meldet an die Senke, die es jetzt gibt.
        knowledgeJobsStorage = nil
        guard usesKnowledgeStage, knowledgeStage == nil, let pipeline, let pipelineSink else { return }
        let environment = KnowledgeStage.Environment(
            settings: { [weak self] in
                await MainActor.run { self?.knowledgeSettings ?? .notLoaded }
            },
            refreshModel: { [weak self] in
                guard let self else { return ModelAvailabilityMonitor.shared.current }
                await self.refreshModelStatus(notifyingStage: false)
                return await MainActor.run { self.modelStatus }
            })
        let stage = KnowledgeStage(
            store: store, gate: pipeline.gate, ledger: removals, host: pipeline,
            work: knowledgeJobs, environment: environment)
        knowledgeStage = stage
        pipelineSink.follow(stage)
        Task { await stage.start() }
    }

    /// Legt die Stufe „Ausgaben“ an, wenn der Schalter an ist. Einmal, aus
    /// `AppBootstrap.start`, nach Host und Senke. Ab dann entstehen die
    /// Cover über die eine Stelle für Apple Intelligence.
    func startEditionsStage() {
        guard usesEditionsStage, editionsStage == nil, let pipeline else { return }
        coverArt.scheduler = AIScheduler.shared
        let environment = EditionsStage.Environment(
            dueFeeds: { [weak self] in
                await MainActor.run { self?.dueAutomaticFeeds() ?? [] }
            },
            compose: { [weak self] request, committer in
                guard let self else { return EditionComposition(note: "") }
                return await self.runEdition(request, committer: committer)
            },
            published: { [weak self] feedID, parts, chapters, origin, covers in
                await self?.editionPublished(feedID, parts: parts, chapters: chapters, origin: origin, covers: covers)
            },
            refreshStatistics: { [weak self] in
                await MainActor.run { self?.scheduleStatisticsRefresh() }
            },
            prepareMissingCovers: { [weak self] in
                await self?.prepareMissingEditionCovers()
            })
        let stage = EditionsStage(
            store: store, gate: pipeline.gate, ledger: removals, host: pipeline, environment: environment)
        editionsStage = stage
        Task { await stage.start() }
    }

// MARK: - Senden aus dem alten Code

    /// Sendet ein Ereignis an die Pipeline. Vor `AppBootstrap.start` fällt es weg.
    func emit(_ event: PipelineEvent) {
        pipeline?.emit(event)
    }

    /// Sendet Ereignisse, die eine Eingangsfassung tragen. Die Fassung liest
    /// der Store, und nur, wenn eine Stufe zuhört, die eines davon bekäme.
    /// Die Ereignisse kommen deshalb etwas nach dem Aufruf; der Vertrag
    /// verlangt nur, dass sie nach dem Schreiben kommen. Untereinander
    /// bleiben sie in der Reihenfolge der Aufrufe.
    ///
    /// Wird die Folge in der Zwischenzeit gelöscht, fällt alles weg. Sonst
    /// käme etwa `evidenceReady` hinter `episodesRemoved` an, das ohne
    /// Warten hinausgeht.
    ///
    /// `media`: die Fassung, falls bekannt. Sonst gilt die aktuelle der Folge.
    func emit(_ kinds: [PipelineEvent.Kind], of id: EpisodeID, media: MediaVersionID? = nil,
              _ make: @escaping @Sendable (InputVersion) -> [PipelineEvent]) {
        guard let pipeline, kinds.contains(where: pipeline.hasListeners(for:)) else { return }
        let store = store
        let removals = removals
        // Der Stand jetzt, beim Aufruf: Was danach gelöscht wird, sendet nichts mehr.
        let ticket = removals.ticket
        let previous = pendingEmission
        pendingEmission = Task {
            let version = await Self.inputVersion(of: id, media: media, in: store)
            await previous?.value
            guard let version else { return }
            pipeline.emit(make(version), about: id, unlessRemovedSince: ticket, in: removals)
        }
    }

    /// Sendet ein Ereignis, sobald ein Schreiben zurückgekehrt ist, das als
    /// eigene Aufgabe läuft. So gilt der Vertrag der Pipeline (erst
    /// speichern, dann melden), ohne dass der Aufrufer auf das Speichern wartet.
    func emit(_ event: PipelineEvent, after write: Task<Void, Never>) {
        guard let pipeline, pipeline.hasListeners(for: event.kind) else { return }
        Task {
            await write.value
            pipeline.emit(event)
        }
    }

    /// Die Eingangsfassung einer Folge, wie der Store sie jetzt sieht.
    private nonisolated static func inputVersion(
        of id: EpisodeID, media: MediaVersionID?, in store: LibraryStore
    ) async -> InputVersion? {
        var mediaID = media
        if mediaID == nil { mediaID = try? await store.episodes(ids: [id]).first?.currentMediaVersionID }
        guard let mediaID, let fingerprint = try? await store.transcriptFingerprint(forMedia: mediaID) else {
            return nil
        }
        return InputVersion(mediaVersionID: mediaID, fingerprint: fingerprint)
    }

    /// Transkript und Belege sind gespeichert: `transcriptSaved`, dann
    /// `evidenceReady`. Der alte Weg meldet das Speichern des Transkripts
    /// nicht einzeln, und seine Stufe `.transcribed` kommt noch vor dem
    /// Speichern. Also gehen beide erst nach den Belegen hinaus.
    func emitTranscriptFinished(_ id: EpisodeID, media: MediaVersionID, origin: Origin) {
        emit([.transcriptSaved, .evidenceReady], of: id, media: media) { version in
            [.transcriptSaved(id, version, origin), .evidenceReady(id, version, origin)]
        }
    }

    /// Ein Lauf der Fakten ist zu Ende. Die Fakten sind da schon gespeichert.
    func emitFactsDone(_ id: EpisodeID, _ outcome: FactsOutcome, origin: Origin) {
        emit([.factsDone], of: id) { [.factsDone(id, $0, outcome, origin)] }
    }

    /// Eine Einordnung der Kapitel ist zu Ende. Die Kapitel-Tags sind da
    /// schon gespeichert.
    func emitTagsDone(_ id: EpisodeID, _ outcome: ChapterTagsOutcome, origin: Origin) {
        emit([.tagsDone], of: id) { [.tagsDone(id, $0, outcome, origin)] }
    }

    /// Welche Art von Fehlschlag ein Transkript hatte. Dieselben Regeln, nach
    /// denen `runAnalysis` entscheidet.
    static func transcriptFailure(_ error: Error, message: String?) -> TranscriptFailure {
        let kind: TranscriptFailure.Kind = switch error {
        case TranscriptionError.localeNotSupported: .localeNotSupported
        case TranscriptionError.speechUnavailableOnDevice: .speechUnavailable
        default:
            UserFacingError.isTransient(error) ? .transient
                : UserFacingError.isPermanent(error) ? .permanent : .other
        }
        return TranscriptFailure(kind, message: message)
    }

    /// Dasselbe für Untertitel über Supadata. Ein Fehler am Schlüssel oder
    /// Konto betrifft jedes Video, nicht diese Folge.
    static func transcriptFailure(_ failure: SupadataError) -> TranscriptFailure {
        let kind: TranscriptFailure.Kind = if failure.isTransient {
            .transient
        } else if failure.affectsAccount {
            .other
        } else {
            .permanent
        }
        return TranscriptFailure(kind, message: failure.errorDescription)
    }
}

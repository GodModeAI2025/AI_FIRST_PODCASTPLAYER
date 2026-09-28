//
//  PipelineSink.swift
//  PodcastAI
//
//  Die App an der Stufen-Pipeline (docs/plan-pipeline.md).
//
//  Das Modell sendet dort, wo etwas geschieht, ein Ereignis an den
//  `PipelineHost`: neue Folgen, Ton da oder weg, Feeds aktualisiert,
//  Folgen gelöscht, Änderungen von anderen Geräten. Ein Ereignis ohne
//  Zuhörer fällt im Host weg und kostet fast nichts. Ereignisse mit
//  Eingangsfassung (`transcriptSaved`, `evidenceReady`, `factsDone`,
//  `tagsDone`) senden die Stufen selbst, nach dem Schreiben.
//
//  Zu hören die Stufen im Paket: „Vorbereiten“ (`PrepareStage`),
//  „Download“ (`DownloadStage`), „Transkript“ (`TranscriptStage`),
//  „Wissen“ (`KnowledgeStage`) und „Ausgaben“ (`EditionsStage`). Die Wege
//  zwischen ihnen stehen im `PipelineRouter`. Hier werden die Stufen
//  angelegt, mit dem, was sie vom Modell brauchen.
//
//  Die Senke ist das Ende der Pipeline auf dem Hauptakteur. Sie schreibt
//  die Felder, die die Oberfläche liest: für „Wissen“ `factsQueue`,
//  `gatheringFacts`, `factsWait`, `factsIssues` und `chapterTagsRevision`,
//  dazu aus der Arbeit an einer Folge (`KnowledgeJobs`, abseits des
//  Hauptakteurs) `facts`, `factsInProgress`, `factsProgress`, `lastError`
//  und `chapterCache`. Die Stufe „Transkript“ spiegelt sie in
//  `analysisQueue`, `analyzing`, `automaticallyQueued` und
//  `backlogQueued`, setzt auf `transcriptSaved` und `evidenceReady` die
//  Stufe der Folge und sagt ein fertiges Transkript an, das jemand
//  angefordert hat.
//

import Foundation
import SwiftUI
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

    /// Schreibt den Stand der Stufe „Transkript“ in die Felder, die Ansichten
    /// und die Regeln fürs Netz lesen.
    func follow(_ stage: TranscriptStage) {
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
        case .transcriptSaved(let id, _, _):
            // Die Arbeit hat die Stufe meist schon weiter gesetzt, samt der
            // Zahl der Fundstellen. Zurück geht sie nie.
            switch model.stages[id] {
            case nil, .discovered, .mediaDownloaded: model.stages[id] = .transcribed
            case .transcribed, .evidenceExtracted, .failed: break
            }
        case .evidenceReady(let id, _, let origin):
            if model.stages[id] != .evidenceExtracted { model.stages[id] = .evidenceExtracted }
            // Nur was jemand selbst angefordert hat, wird angesagt. Das
            // automatische Vorbereiten spräche sonst Folge um Folge dazwischen.
            // Die Herkunft setzt nur der Code beim Anfordern (Regel 2).
            if origin == .user, let title = model.episodes.values.lazy.joined().first(where: { $0.id == id })?.title {
                AccessibilityNotification.Announcement(String(localized: "Transkript fertig: \(title)")).post()
            }
        case .tagsDone(_, _, let outcome, _):
            // Neue Kapitel-Tags: Offene Folgen und Tag-Seiten laden sie neu.
            // Ein Themen-Update lösen sie nicht aus (Entscheidung 6).
            if outcome == .stored { model.chapterTagsRevision += 1 }
        case .episodesRemoved(let ids, _):
            // Stufe, Angabe und Fortschritt der Folgen fallen gleich weg.
            // Fakten und Vermerke räumt die Pflege.
            for id in ids {
                model.stages[id] = nil
                model.stageDetails[id] = nil
                model.factsProgress[id] = nil
                model.downloadProgress[id] = nil
            }
        case .episodesAdded, .audioAvailable, .audioRemoved, .transcriptFailed, .transcriptsIdle,
             .factsDone, .feedsRefreshed, .editionPublished, .changedElsewhere:
            // Laut Router nicht für die Senke.
            break
        }
    }

    /// Ein neuer Stand der Stufe „Transkript“. Geschrieben wird nur, was
    /// sich geändert hat. Die Stufe merkt sich die Warteschlange selbst;
    /// diese Felder schreiben dann nichts in die Benutzereinstellungen.
    func apply(_ snapshot: TranscriptSnapshot) {
        guard let model else { return }
        if model.analysisQueue.map(\.id) != snapshot.queue.map(\.episode.id) {
            model.analysisQueue = snapshot.queue.map(\.episode)
        }
        if model.analyzing?.id != snapshot.running?.episode.id { model.analyzing = snapshot.running?.episode }
        let items = snapshot.queue + [snapshot.running].compactMap { $0 }
        let automatic = Set(items.filter { $0.origin != .user }.map(\.episode.id))
        let backlog = Set(items.filter { $0.origin == .backlog }.map(\.episode.id))
        if model.automaticallyQueued != automatic { model.automaticallyQueued = automatic }
        if model.backlogQueued != backlog { model.backlogQueued = backlog }
        model.backgroundWorkChanged()
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
        model.knowledgeTagsQueued = snapshot.tagsQueued
        model.knowledgeTagsRunning = snapshot.tagsRunning
        model.backgroundWorkChanged()
    }
}

// MARK: - Stufe „Wissen“: Meldungen der Arbeit an einer Folge

/// Fakten, Fortschritt, Fehlermeldung und nachgeladene Kapitel aus
/// `KnowledgeJobs`. Die Arbeit läuft abseits des Hauptakteurs; was die
/// Oberfläche zeigt, schreibt nur die Senke.
extension PipelineSink: KnowledgeReporting {

    func factsStarted(_ id: EpisodeID) {
        model?.factsInProgress.insert(id)
        model?.backgroundFactsProgress(id, fraction: 0)
    }

    func factsProgress(_ id: EpisodeID, fraction: Double) {
        model?.factsProgress[id] = fraction
        model?.backgroundFactsProgress(id, fraction: fraction)
    }

    func factsFinished(_ id: EpisodeID) {
        model?.factsInProgress.remove(id)
        model?.factsProgress[id] = nil
        model?.backgroundFactsProgress(id, fraction: 1)
    }

    /// Nur für die Anzeige der fortgesetzten Verarbeitung.
    func tagsProgress(_ id: EpisodeID, fraction: Double) {
        model?.backgroundTagsProgress(id, fraction: fraction)
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

    /// Die Arbeit an einer Folge für die Stufe „Wissen“. Entsteht beim
    /// ersten Gebrauch, mit dem Speicher von jetzt.
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

    /// Legt die Stufe „Wissen“ an. Einmal, aus `AppBootstrap.start`, nach
    /// Host und Senke.
    func startKnowledgeStage() {
        // Die Arbeit meldet an die Senke, die es jetzt gibt.
        knowledgeJobsStorage = nil
        guard knowledgeStage == nil, let pipeline, let pipelineSink else { return }
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
            work: knowledgeJobs, environment: environment, leases: leasePolicy)
        knowledgeStage = stage
        pipelineSink.follow(stage)
        Task { await stage.start() }
    }

    /// Legt die Stufe „Ausgaben“ an. Einmal, aus `AppBootstrap.start`, nach
    /// Host und Senke. Ab dann entstehen die Cover über die eine Stelle für
    /// Apple Intelligence.
    func startEditionsStage() {
        guard editionsStage == nil, let pipeline else { return }
        coverArt.scheduler = AIScheduler.shared
        let environment = EditionsStage.Environment(
            dueFeeds: { [weak self] in
                // „Angesagt“ folgt vorher den Trends, auch im Hintergrund, wo
                // keine Ansicht sie rechnet (AppModel+TrendingFeed.swift).
                guard let self else { return [] }
                await self.refreshTrendingFeed()
                return await MainActor.run { self.dueAutomaticFeeds() }
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

    /// Legt die Stufe „Vorbereiten“ an. Einmal, aus `AppBootstrap.start`,
    /// nach Host und Senke.
    func startPrepareStage() {
        guard prepareStage == nil, let pipeline else { return }
        let environment = PrepareStage.Environment(
            candidates: { [weak self] sources in
                await MainActor.run { self?.preparationCandidates(in: sources) ?? [] }
            },
            backCatalog: { [weak self] source in
                await MainActor.run { self?.backCatalogRefill(in: source) ?? [] }
            },
            enqueue: { [weak self] candidates in
                await MainActor.run { self?.enqueuePrepared(candidates) }
            },
            alreadyTranscribed: { [weak self] ids in
                await MainActor.run { self?.knownTranscribed.formUnion(ids) }
            },
            markFailed: { [weak self] id in
                await MainActor.run { self?.markPreparationFailed(id) }
            },
            forget: { [weak self] ids in
                await MainActor.run { self?.failedInPreparation.removeAll { ids.contains($0) } }
            },
            fetchMetadata: { [weak self] in
                await MainActor.run { self?.fetchMissingMetadata() }
            })
        let stage = PrepareStage(store: store, gate: pipeline.gate, ledger: removals, host: pipeline,
                                 environment: environment)
        prepareStage = stage
        Task { await stage.start() }
    }

    /// Legt die Stufe „Download“ an. Einmal, aus `AppBootstrap.start`, nach
    /// Host und Senke.
    func startDownloadStage() {
        guard downloadStage == nil, let pipeline else { return }
        let environment = DownloadStage.Environment(
            nextPrefetch: { [weak self] in
                await MainActor.run { self?.nextEpisodeToPrefetch() }
            },
            prefetch: { [weak self] episode in
                await self?.prefetchForStage(episode)
            },
            tidy: { [weak self] in
                await self?.tidyLocalAudio()
            },
            afterTranscript: { [weak self] id in
                guard let self, let episode = await self.knownEpisode(id) else { return }
                await self.removeAudioAfterAnalysisIfWanted(episode)
            },
            afterFailedPreparation: { [weak self] id in
                guard let self, let episode = await self.knownEpisode(id) else { return }
                await self.removeAudioAfterFailedPreparation(episode)
            },
            lookahead: { [weak self] in
                await MainActor.run { self?.startDownloadLookahead() }
            })
        let stage = DownloadStage(gate: pipeline.gate, ledger: removals, host: pipeline, environment: environment)
        downloadStage = stage
        Task { await stage.start() }
    }

    /// Hält die neueste Folge je Podcast vor, über die Stufe „Download“.
    func requestPrefetch() {
        guard let downloadStage else { return }
        Task { await downloadStage.prefetch() }
    }

    /// Lädt den Ton der nächsten Folgen der Warteschlange im Voraus, über die
    /// Stufe „Download“.
    func requestLookahead() {
        guard let downloadStage else { return }
        Task { await downloadStage.lookahead() }
    }

    /// Ein von selbst eingereihtes Transkript ist an etwas gescheitert, das
    /// beim nächsten Versuch wieder käme. Nur Folgen mit Ton: Die Wartezeit
    /// eines Videos nach einem Fehlversuch bei Supadata steht in
    /// `captionFailures`.
    func markPreparationFailed(_ id: EpisodeID) {
        guard let episode = episodes.values.lazy.joined().first(where: { $0.id == id }),
              episode.audioURL != nil else { return }
        failedInPreparation.insert(id)
    }

    /// Eine Folge aus den geladenen Listen, sonst aus dem Store.
    func knownEpisode(_ id: EpisodeID) async -> Episode? {
        if let known = episodes.values.lazy.joined().first(where: { $0.id == id }) { return known }
        return try? await store.episodes(ids: [id]).first
    }

// MARK: - Senden

    /// Sendet ein Ereignis an die Pipeline. Vor `AppBootstrap.start` fällt es weg.
    func emit(_ event: PipelineEvent) {
        pipeline?.emit(event)
    }

    /// Welche Art von Fehlschlag ein Transkript hatte. Dieselben Regeln, nach
    /// denen `transcribe` entscheidet.
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

//
//  AppModel+Transcripts.swift
//  PodcastAI
//
//  Die Arbeit an einer Folge der Warteschlange: laden, transkribieren oder
//  Untertitel über Supadata holen, Belege bilden (docs/plan-pipeline.md,
//  Schritt 5b). Die Warteschlange führt die Stufe „Transkript“ im Paket
//  (`TranscriptStage`); die Arbeit hier berührt sie nicht. Was danach mit
//  der Warteschlange geschieht, entscheidet die Stufe.
//
//  Wer die Folge wollte, fragt die Arbeit am Ende über
//  `TranscriptJob.currentOrigin`: „Transkript jetzt erstellen“ während des
//  Laufs macht aus einer von selbst eingereihten Folge eine angeforderte.
//  Gefragt wird erst nach der Prüfung auf eine Löschung und nach dem
//  Einreihen der Fakten; dazwischen darf kein `await` liegen.
//

import Foundation
import SwiftUI
import PodcastAIKit

extension AppModel {

    // MARK: - Die Arbeit an einer Folge

    /// Erschließt eine Folge, ohne die Warteschlange zu berühren.
    func transcribe(_ job: TranscriptJob, background: BackgroundContinuation?) async -> TranscriptJobOutcome {
        let episode = job.episode
        guard let audioURL = episode.audioURL else {
            return isCaptionVideo(episode) ? await transcribeCaptions(job, background: background) : .dropped
        }
        // Stand der Löschungen beim Start. Wird die Folge währenddessen
        // gelöscht, darf nichts von ihr zurückkommen.
        let ticket = job.ticket
        // Inzwischen gelöscht, hier oder auf einem anderen Gerät: überspringen.
        let live = try? await store.episodes(ids: [episode.id])
        if live?.isEmpty == true || wasRemoved(episode.id, since: ticket) {
            forgetOverdueStage(of: episode)
            return .dropped
        }
        // Die Folge wird in ihrer eigenen Sprache transkribiert, nicht in der
        // des Geräts. Ohne Angabe im Feed bleibt es bei der Gerätesprache.
        let locale = transcriptionLocale(for: episode)
        stages[episode.id] = .discovered
        stageDetails[episode.id] = nil
        background?.update(.discovered)
        let remaining = job.remaining
        if remaining > 0 {
            // Zahl und Wort für sich, der Titel außerhalb des Markdowns.
            let more = String(AttributedString(localized: "^[\(remaining) Folge](inflect: true)").characters)
            activity = String(localized: "Transkript für „\(episode.title)“ wird erstellt, danach noch \(more) …")
        } else {
            activity = String(localized: "Transkript für „\(episode.title)“ wird erstellt …")
        }

        let automatic = job.origin != .user
        let pipeline = ContentPipeline(
            store: store,
            mediaDirectory: LocalMediaLocator.mediaDirectory,
            // Zwischen dem Transkript des Podcasts und der eigenen Erkennung:
            // die Untertitel des YouTube-Zwillings, nur mit eigenem Schlüssel.
            twin: twinCaptionHook(for: episode, automatic: automatic),
            // Im WLAN lädt die Sitzung des Systems und lädt weiter, wenn die
            // App anhält. Das Transkript entsteht danach, sobald sie vorn ist.
            backgroundDownloads: backgroundDownloadSession(automatic: automatic),
            onProgress: { [weak self] progress in
                let hop = ProcessingTrace.begin("Sprung auf den Hauptakteur")
                Task { @MainActor in
                    defer { ProcessingTrace.end("Sprung auf den Hauptakteur", hop) }
                    // Eine gelöschte Folge taucht nicht wieder unter „Erschließen“ auf.
                    guard let self, !self.wasRemoved(progress.episodeID, since: ticket) else { return }
                    // Nur ein Schritt im Transkript oder beim Laden: die
                    // Anzeige des Systems bekommt ihn, die Stufe der Folge bleibt.
                    if let fraction = progress.fraction {
                        background?.update(progress.stage, fraction: fraction)
                        return
                    }
                    if let fraction = progress.downloadFraction {
                        background?.update(progress.stage, downloadFraction: fraction)
                        return
                    }
                    ProcessingTrace.event("Neue Stufe")
                    self.stages[progress.episodeID] = progress.stage
                    // Nach dem Download ändert sich der belegte Speicher.
                    if progress.stage == .mediaDownloaded { self.mediaStorageChanged += 1 }
                    if let detail = progress.detail {
                        self.stageDetails[progress.episodeID] = detail
                    }
                    background?.update(progress.stage)
                }
            }
        )
        // Als eigene Aufgabe, damit Löschen genau diese Folge abbrechen kann.
        // Gespeichert wird hinter dem Wächter im Store, gegen den Stand der
        // Löschungen von oben.
        let run = Task(priority: .utility) {
            try await pipeline.analyze(
                episode: episode, audioURL: audioURL,
                sourceID: episode.sourceID, locale: locale, since: ticket
            ).receipt
        }
        pipelineRun = run
        pipelineEpisodeID = episode.id
        defer {
            pipelineRun = nil
            pipelineEpisodeID = nil
        }
        let media = MediaVersionID(stable: audioURL.absoluteString)
        do {
            // Die eigene Aufgabe erbt keinen Abbruch. Hält die Warteschlange
            // an, bevor `pipelineRun` steht, liefe das Transkript sonst ohne
            // Träger im Hintergrund weiter.
            let receipt = try await withTaskCancellationHandler {
                try await run.value
            } onCancel: {
                run.cancel()
            }
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode, receipt: receipt)
                return .dropped
            }
            analyzedEpisodes.insert(episode.id)
            // Transkript und Belege sind gespeichert. Die Stufe „Wissen“ reiht
            // auf `evidenceReady` selbst ein, und das nächste Transkript
            // wartet nicht auf sie.
            // Die Datei gehört jetzt zum Transkript. Ab hier gelten für sie die
            // Regeln nach dem Transkript, nicht mehr die fürs Vorhalten. Die
            // Stufe „Download“ räumt auf `evidenceReady` selbst auf.
            prefetchedNewest.remove(episode.id)
            // Das Sprachmodell liegt jetzt auf dem Gerät, aber nur, wenn die
            // App selbst transkribiert hat. Für das Transkript vom Podcast
            // wurde keins geladen.
            if await TimedTranscriptionEngine.hasInstalledModel(for: locale) {
                installedSpeechModels.insert(locale.identifier)
            }
            await refreshRelevantToday()
            return .transcribed(media)
        } catch {
            // Abgebrochen, weil gelöscht: kein zweiter Versuch, nur aufräumen.
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode)
                return .dropped
            }
            // Der Wächter im Store hat widersprochen: Die Folge ist inzwischen
            // woanders gelöscht, ihre Quelle fehlt, oder die Datei, auf die
            // der Feed jetzt zeigt, hat schon ein Transkript. Wie oben, wenn
            // die Folge schon vor dem Start fehlte: still zurück, kein
            // zweiter Versuch.
            if let stale = error as? StaleWriteError {
                await settleStaleAnalysis(of: episode, reason: stale.reason, media: media,
                                          origin: await job.currentOrigin())
                return .dropped
            }
            // Angehalten, weil die Zeit im Hintergrund endete: kein Fehler.
            // Die Folge kommt wieder nach vorn und setzt beim nächsten Lauf
            // an ihrem Zwischenstand an.
            if error is CancellationError || Task.isCancelled {
                stages[episode.id] = nil
                stageDetails[episode.id] = String(localized: "pausiert")
                return .interrupted
            }
            if UserFacingError.isTransient(error) {
                stages[episode.id] = nil
                return .failed(TranscriptFailure(.transient), retry: true)
            }
            stages[episode.id] = .failed
            let message = UserFacingError.describe(error)
            stageDetails[episode.id] = message
            let failure = Self.transcriptFailure(error, message: message)
            let wasAutomatic = await job.currentOrigin() != .user
            // Käme der Fehler bei einer von selbst eingereihten Folge beim
            // nächsten Start wieder, merkt sich das die Stufe „Vorbereiten“
            // auf `transcriptFailed`. Der Ton war nur fürs Transkript da;
            // die Stufe „Download“ räumt ihn auf demselben Ereignis auf.
            // Kann das Gerät überhaupt nicht transkribieren, hat es keinen
            // Sinn, die nächsten Folgen trotzdem zu laden.
            if case TranscriptionError.speechUnavailableOnDevice = error {
                preparationUnavailable = message
            }
            // Nur selbst angeforderte Arbeit meldet sich mit einem Dialog.
            if !wasAutomatic { lastError = String(localized: "„\(episode.title)“: \(message)") }
            return .failed(failure, retry: false)
        }
    }

    /// Eine Erschließung ist überholt, bevor sie etwas geschrieben hat: die
    /// Folge fehlt, ist gelöscht, oder der Store hat das Schreiben abgelehnt.
    /// Sie verschwindet still aus der Anzeige.
    private func forgetOverdueStage(of episode: Episode) {
        stages[episode.id] = nil
        stageDetails[episode.id] = nil
    }

    /// Der Wächter im Store hat das Schreiben abgelehnt. Die Folge verlässt
    /// die Warteschlange still, ohne zweiten Versuch. Nach einer Löschung
    /// räumt das Löschen selbst auf. Hat dagegen die Fassung, auf die der
    /// Feed jetzt zeigt, schon ein Transkript, war die Arbeit nur überholt:
    /// Ihr Zwischenstand geht, und von selbst geladener Ton geht wie nach
    /// einem gescheiterten Vorbereiten.
    private func settleStaleAnalysis(
        of episode: Episode, reason: CommitGuard.StaleReason, media: MediaVersionID?, origin: Origin
    ) async {
        forgetOverdueStage(of: episode)
        guard !reason.meansRemoved else { return }
        if let media { Self.transcriptCheckpoints.remove([media]) }
        if origin != .user { await removeAudioAfterFailedPreparation(episode) }
    }

    // MARK: YouTube-Untertitel in der Warteschlange

    /// Holt die Untertitel eines YouTube-Videos über Supadata und macht daraus
    /// Transkript und Belege.
    ///
    /// Scheitert es, gibt es keinen Dialog, auch nicht auf Wunsch: die Folge
    /// sagt in einem Satz, woran es lag, und die Reihenfolge greift weiter
    /// (Audio-Podcast, sonst nur Metadaten). Der Fehlversuch wird gemerkt,
    /// damit dasselbe Video nicht nach jedem Start wieder angefragt wird.
    /// Die Spracherkennung braucht es dafür nicht, und die Frist des
    /// Clients hält die Warteschlange höchstens anderthalb Minuten auf.
    private func transcribeCaptions(_ job: TranscriptJob, background: BackgroundContinuation?) async
        -> TranscriptJobOutcome {
        let episode = job.episode
        let ticket = job.ticket
        let live = try? await store.episodes(ids: [episode.id])
        if live?.isEmpty == true || wasRemoved(episode.id, since: ticket) {
            forgetOverdueStage(of: episode)
            return .dropped
        }
        guard let watchURL = captionURL(of: episode), let key = SupadataKeychain.read(),
              canTranscribe(episode, byHand: true) else {
            // Inzwischen ohne Schlüssel oder ausgeschaltet: still zurück.
            stages[episode.id] = nil
            stageDetails[episode.id] = nil
            hasSupadataKey = SupadataKeychain.hasKey
            return .dropped
        }
        stages[episode.id] = .discovered
        stageDetails[episode.id] = nil
        background?.update(.discovered)
        activity = String(localized: "Untertitel für „\(episode.title)“ werden über Supadata geholt …")

        let client = supadata
        let store = store
        let preferred = [AppLanguage.current.rawValue]
        let origin: TranscriptOrigin = isYouTubeVideo(episode) ? .youTubeCaptions : .postCaptions
        let fallbackLocale = sources.first { $0.id == episode.sourceID }?.language ?? AppLanguage.current.rawValue
        let writeGuard = commitGuard(for: episode, since: ticket)
        // Als eigene Aufgabe, damit Löschen genau diese Folge abbrechen kann.
        // Losgelöst vom Hauptakteur: das Aufbereiten der Untertitel rechnet.
        let run = Task.detached(priority: .utility) {
            let captions = try await ProcessingTrace.interval("Untertitel von Supadata") {
                try await client.transcript(videoURL: watchURL, apiKey: key, preferredLanguages: preferred)
            }
            // Wie der Download bei Ton: Die Untertitel sind da. Die Anzeige
            // der fortgesetzten Verarbeitung sieht damit Fortschritt, auch
            // wenn Supadata lange an einem Auftrag rechnete.
            await background?.update(.mediaDownloaded)
            let built = ProcessingTrace.measure("Untertitel aufbereiten") {
                CaptionAnalysis.build(
                    captions: captions, episodeID: episode.id, sourceID: episode.sourceID,
                    watchURL: watchURL, fallbackLocale: fallbackLocale,
                    declaredDuration: episode.declaredDuration, origin: origin)
            }
            guard let result = built else {
                throw SupadataError.noTranscript
            }
            try Task.checkCancellation()
            return try await store.commit(captions: result, under: writeGuard).get().receipt
        }
        pipelineRun = run
        pipelineEpisodeID = episode.id
        defer {
            pipelineRun = nil
            pipelineEpisodeID = nil
        }
        do {
            // Wie bei Ton: Die losgelöste Aufgabe erbt keinen Abbruch. Hält
            // die Stufe an, etwa bei „Alle abbrechen“, bräche die Anfrage an
            // Supadata sonst erst nach ihrer Frist ab und schriebe danach.
            let receipt = try await withTaskCancellationHandler {
                try await run.value
            } onCancel: {
                run.cancel()
            }
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode, receipt: receipt)
                return .dropped
            }
            captionFailures[episode.id.rawValue] = nil
            supadataRestingUntil = nil
            analyzedEpisodes.insert(episode.id)
            stages[episode.id] = .evidenceExtracted
            stageDetails[episode.id] = origin.sourceLabel
            // Die Fassung des Videos kennt jetzt ihre Kennung; Stellen daraus
            // öffnen YouTube statt den Player.
            if let reloaded = try? await store.episodes(ids: [episode.id]) {
                RemoteMediaRegistry.shared.register(reloaded)
            }
            await refreshRelevantToday()
            return .transcribed(CaptionAnalysis.mediaVersionID(watchURL: watchURL))
        } catch {
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode)
                return .dropped
            }
            // Der Wächter im Store hat widersprochen. Kein Fehlversuch bei
            // Supadata: Die Untertitel waren da, nur die Folge nicht mehr.
            if let stale = error as? StaleWriteError {
                await settleStaleAnalysis(of: episode, reason: stale.reason, media: nil,
                                          origin: await job.currentOrigin())
                return .dropped
            }
            let failure = (error as? SupadataError) ?? (error is CancellationError ? .cancelled : .network)
            let wasAutomatic = await job.currentOrigin() != .user
            // Wie bei Ton: die Folge sagt, woran es lag. Hat das Video keine
            // Untertitel oder liegt es am Schlüssel, steht dort stattdessen der
            // ruhige Satz aus `youTubeTranscriptHint`, auch nach einem Neustart.
            if failure == .cancelled {
                stages[episode.id] = nil
                stageDetails[episode.id] = nil
            } else {
                stages[episode.id] = .failed
                stageDetails[episode.id] = failure.errorDescription
            }
            await noteCaptionFailure(failure, for: episode, wasAutomatic: wasAutomatic)
            // Abgebrochen: Die Folge geht still, wie bis 0.13.
            guard failure != .cancelled else { return .dropped }
            // Vorübergehend: ein zweiter Versuch nach kurzer Pause. Ein
            // offener Schutzschalter lässt ihn ohne Anfrage enden.
            let retry = failure.isTransient && !failure.affectsAccount && supadataRestingUntil == nil
            return .failed(Self.transcriptFailure(failure), retry: retry)
        }
    }

    /// Merkt sich, woran es lag, und nimmt den Rest der Reihenfolge.
    private func noteCaptionFailure(_ failure: SupadataError, for episode: Episode, wasAutomatic: Bool) async {
        if failure != .cancelled {
            captionFailures[episode.id.rawValue] = CaptionFailure(error: failure, at: Date())
        }
        await noteSupadataAccountError(failure)
        // Gibt es die Folge als Ton im abonnierten Audio-Podcast, entsteht das
        // Transkript dort. Nach denselben Regeln fürs Netz wie der Auftrag.
        let inputs = youTubeInputs(for: episode, byHand: !wasAutomatic)
        if case .counterpartEpisode(let id, _) = YouTubeTranscriptPlanner.fallback(after: failure, inputs: inputs),
           !analyzedEpisodes.contains(id),
           let audio = episodes.values.lazy.flatMap({ $0 }).first(where: { $0.id == id }) {
            enqueueAnalysis(audio, automatic: wasAutomatic)
        }
    }

    // MARK: - Stufe „Transkript“ (TranscriptStage im Paket)

    /// Legt die Stufe „Transkript“ an. Einmal, aus `AppBootstrap.start`,
    /// nach Host und Senke.
    func startTranscriptStage() {
        guard transcriptStage == nil, let pipeline, let pipelineSink else { return }
        let environment = TranscriptStage.Environment(
            runnable: { [weak self] items in
                await MainActor.run { self?.runnableTranscripts(items) ?? [] }
            },
            runStarted: { [weak self] title in
                await MainActor.run { self?.transcriptRunStarted(title: title) }
            },
            runEnded: { [weak self] cancelled in
                await self?.transcriptRunEnded(cancelled: cancelled)
            },
            transcribe: { [weak self] job in
                guard let self else { return .dropped }
                return await self.transcribeForStage(job)
            },
            settled: { [weak self] settlement in
                await self?.transcriptSettled(settlement)
            },
            restore: { [weak self] entries, episodes in
                await MainActor.run { self?.restorableTranscripts(entries, episodes: episodes) ?? [] }
            })
        let stage = TranscriptStage(store: store, gate: pipeline.gate, ledger: removals, host: pipeline,
                                    environment: environment)
        transcriptStage = stage
        pipelineSink.follow(stage)
        Task { await stage.start() }
    }

    /// Welche Folgen jetzt laufen dürfen, mit der Herkunft aus der Stufe,
    /// nicht aus dem Spiegel in `automaticallyQueued`: Der hinkt einen
    /// Augenblick nach, und eine von selbst eingereihte Folge liefe sonst im
    /// Mobilfunk los.
    private func runnableTranscripts(_ items: [TranscriptQueueItem]) -> Set<EpisodeID> {
        Set(items.filter { queueWait(for: $0.episode, automatic: $0.origin != .user) == nil }.map(\.episode.id))
    }

    /// Der Lauf beginnt: Die fortgesetzte Verarbeitung meldet sich an. Den
    /// Träger `.continued` hält die Stufe selbst.
    private func transcriptRunStarted(title: String) {
        transcriptContinuation?.end()
        transcriptContinuation = BackgroundContinuation.begin(
            title: title, onExpire: { [weak self] in self?.transcriptTimeExpired() })
    }

    /// Der Lauf ist zu Ende. Leer gelaufen: nach den Transkripten fragen,
    /// die im Mobilfunk warten. Die Automatik der Themen-Updates prüft die
    /// Stufe „Ausgaben“ auf `transcriptsIdle`.
    private func transcriptRunEnded(cancelled: Bool) async {
        transcriptContinuation?.end()
        transcriptContinuation = nil
        activity = nil
        guard !cancelled else { return }
        askAboutWaitingTranscripts()
    }

    /// Die Arbeit an einer Folge für die Stufe: Untertitel der
    /// Fortschrittsanzeige, Vorausladen, dann die Arbeit selbst.
    private func transcribeForStage(_ job: TranscriptJob) async -> TranscriptJobOutcome {
        transcriptContinuation?.setSubtitle(job.episode.title)
        // Den Ton der nächsten Folgen schon jetzt über die Sitzung des
        // Systems laden, solange die App vorn ist.
        requestLookahead()
        return await transcribe(job, background: transcriptContinuation)
    }

    /// Was nach einer Folge für Oberfläche und Vermerke dieses Geräts zu tun ist.
    private func transcriptSettled(_ settlement: TranscriptSettlement) async {
        switch settlement {
        case .retrying(let id):
            stageDetails[id] = String(localized: "wartet auf zweiten Versuch")
        case .gaveUpBacklog(let id):
            // Zweimal kurz gescheitert: in diesem Start nicht wieder als ältere Folge.
            backCatalogSkipped.insert(id)
        case .backlogFinished(let source, let announced):
            // Die Stufe „Vorbereiten“ lässt die nächste auf das Ereignis
            // nachrücken. Ohne Ereignis, etwa nach einer überholten Folge, hier.
            if !announced { refillBackCatalog(in: source) }
        case .preparationFailed(let ids):
            failedInPreparation.insert(contentsOf: ids)
            for id in ids { stageDetails[id] = nil }
        case .droppedAutomatic(let ids):
            for id in ids { stageDetails[id] = nil }
        case .alreadyTranscribed(let item):
            // Wie bis 0.13, als der Wächter im Store das Schreiben ablehnte,
            // weil die Fassung schon ein Transkript hatte: Der Zwischenstand
            // geht, von selbst geladener Ton auch, und nach einer älteren
            // Folge rückt die nächste nach. Nur die Arbeit dazwischen entfällt.
            let episode = item.episode
            knownTranscribed.insert(episode.id)
            stageDetails[episode.id] = nil
            if let media = CaptionAnalysis.feedMediaVersionID(of: episode) {
                Self.transcriptCheckpoints.remove([media])
            }
            if item.origin == .backlog { refillBackCatalog(in: episode.sourceID) }
            if item.origin != .user { await removeAudioAfterFailedPreparation(episode) }
        }
    }

    /// Was von der gemerkten Warteschlange zurückkommt, nach denselben
    /// Regeln wie bis 0.13: Von Hand Angefordertes immer, von selbst
    /// Eingereihtes nur, solange die App noch von selbst vorbereiten soll,
    /// ältere Folgen nur in der ersten Portion je Podcast. Neu kommen auch
    /// Videos mit Untertiteln zurück.
    private func restorableTranscripts(
        _ entries: [AnalysisQueueSnapshot.Entry], episodes found: [Episode]
    ) -> [TranscriptQueueItem] {
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let subscribed = Set(sources.map(\.id))
        let saved = AnalysisQueueSnapshot(entries: entries)
        let restorable = AutomaticWorkBudget.trimmed(
            saved.restorable(known: Set(byID.keys), finished: analyzedEpisodes,
                             automaticAllowed: preparationUnavailable == nil),
            isBacklog: { $0.automatic && $0.backlog },
            group: { byID[$0.episodeID]?.sourceID.rawValue ?? "" },
            batch: backCatalogBatch)
        var items: [TranscriptQueueItem] = []
        for entry in restorable {
            guard let episode = byID[entry.episodeID], episode.audioURL != nil || isCaptionVideo(episode),
                  subscribed.contains(episode.sourceID) else { continue }
            if entry.automatic {
                let wanted = entry.backlog ? backCatalog.contains(episode.sourceID) : automaticAnalysis
                guard wanted, !dismissedFromPreparation.contains(episode.id),
                      !failedInPreparation.contains(episode.id),
                      !restingPreparation.contains(episode.id) else { continue }
            }
            let origin: Origin = !entry.automatic ? .user : entry.backlog ? .backlog : .automatic
            items.append(TranscriptQueueItem(episode: episode, origin: origin))
            stageDetails[episode.id] = Self.waitingDetail
        }
        return items
    }
}

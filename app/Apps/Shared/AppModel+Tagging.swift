//
//  AppModel+Tagging.swift
//  PodcastAI
//
//  Tags je Kapitel. Die Einordnung läuft in derselben Arbeit wie die
//  Fakten: gleich nach den Fakten einer Folge und danach für die übrige
//  Bibliothek, neueste Folge zuerst, wenn keine Folge auf Fakten wartet.
//
//  Kandidaten und Ranking rechnet der Code (`ChapterTagCandidates`), das
//  Modell wählt nur Kennungen aus der Liste (`TagSelector`). Ein neuer
//  Oberbegriff kommt aus den Kandidaten und wird ein erkanntes, neutrales
//  Tag. Die Wolke zeigt es erst ab zwei Quellen.
//
//  Fortsetzen: Welche Kapitel fertig sind, merkt sich das Gerät je Folge
//  (`ChapterTaggingProgress` in `DeviceState`). Die Kapitel-Tags gehen erst
//  in die Datenbank, wenn die ganze Folge eingeordnet ist, in einem Schritt.
//  So schreibt der Abgleich nicht nach jedem Kapitel alle Zeilen der Folge neu.
//
//  Seit der Stufe „Wissen“ steht die Einordnung einer Folge in
//  `KnowledgeJobs` (Paket). Warteschlange und Rückstand hier gehören zum
//  alten Weg hinter dem Schalter.
//

import Foundation
import PodcastAIKit

extension AppModel {

    /// Darf die Einordnung jetzt arbeiten? Wie die Fakten, und zusätzlich
    /// in der leichten Hintergrundaufgabe `com.podcastai.tagging`.
    /// In der Pause arbeitet auch sie nicht.
    var tagsMayRun: Bool {
        pipeline?.gate.mayRun(.tags, origin: .automatic) ?? factsMayRun
    }

    /// Ist ein Modell für Tags da oder wird es gerade vorbereitet?
    var tagsModelExpected: Bool {
        switch modelStatus.resolve(.tag) {
        case .success: true
        case .failure(let reason): reason == .modelNotReady
        }
    }

    // MARK: - Eine Folge

    /// Ordnet die Kapitel einer Folge ein und speichert die Kapitel-Tags.
    /// Der Code steht seit der Stufe „Wissen“ in `KnowledgeJobs` (Paket).
    /// Hier ruft ihn der alte Weg hinter dem Schalter auf.
    ///
    /// `origin`: wer die Arbeit wollte. Nach den Fakten einer Folge erben die
    /// Tags die Herkunft des Faktenlaufs.
    ///
    /// Das Ergebnis sagt dem Besitzer der Warteschlange, ob die Kapitel-Tags
    /// jetzt zum aktuellen Transkript passen (`current`). Bei `.failed`
    /// merkt er sich die Folge für diesen Start.
    @discardableResult
    func prepareChapterTags(
        for episode: Episode, origin: Origin, removalTicket: RemovalLedger.Ticket? = nil
    ) async -> ChapterTagsRun {
        guard !taggingInProgress.contains(episode.id) else { return ChapterTagsRun(.nothingToDo) }
        taggingInProgress.insert(episode.id)
        defer { taggingInProgress.remove(episode.id) }
        let ticket = removalTicket ?? removals.ticket
        let fresh = (try? await store.episodes(ids: [episode.id]))?.first ?? episode
        return await knowledgeJobs.classifyChapters(of: fresh, origin: origin, since: ticket)
    }

    // MARK: - Bibliothek

    /// Reiht Folgen ein, deren Kapitel noch keine Tags aus dem aktuellen
    /// Transkript haben, neueste zuerst. Nur mit „Fakten automatisch
    /// sammeln“, denn es ist dieselbe Arbeit im Hintergrund.
    ///
    /// Die Tags kommen nach den Fakten: Eine Folge wartet, bis sie Fakten hat
    /// oder ein Lauf ohne Fakten endete. Kann dieses Gerät gar keine Fakten
    /// sammeln, etwa ohne Gerätemodell, aber mit Private Cloud Compute,
    /// wartet sie nicht darauf.
    func queueMissingChapterTags(withFacts: Set<EpisodeID>) async {
        guard automaticFacts, isLoaded, tagsModelExpected else { return }
        let settled = StoredEpisodeIDs(key: Self.tagsSettledKey)
        let factsSettled = StoredEpisodeIDs(key: Self.factsSettledKey)
        let factsHere = factsModelExpected
        var busy = Set(tagsQueue.map(\.id)).union(factsQueue.map(\.id)).union(taggingInProgress)
        if let gatheringFacts { busy.insert(gatheringFacts.id) }
        let pool = analyzedEpisodes.filter {
            (!factsHere || withFacts.contains($0) || factsSettled.contains($0))
                && !busy.contains($0) && !settled.contains($0) && !tagsFailed.contains($0)
                && !tagsCurrent.contains($0)
        }
        guard !pool.isEmpty,
              let backlog = try? await store.chapterTagBacklog(among: pool) else { return }
        // Was nicht offen ist, fragt dieser Start nicht noch einmal ab.
        tagsCurrent.formUnion(pool.subtracting(backlog))
        guard !backlog.isEmpty, let found = try? await store.episodes(ids: Array(backlog)) else { return }
        // In Portionen, neueste zuerst. `runTagsBacklog` holt die nächste.
        let newest = found
            .filter { episode in !tagsQueue.contains(where: { $0.id == episode.id }) }
            .sorted(by: { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) })
        let portion = AutomaticWorkBudget.refill(
            newest, alreadyWaiting: tagsQueue.count, batch: AutomaticWorkBudget.tagsBackfillBatch)
        tagsBackfillPending = portion.count < newest.count
        tagsQueue.append(contentsOf: portion)
        startFactsWorker()
    }

    /// Ordnet eingereihte Folgen ein, bis keine mehr wartet, eine Folge auf
    /// Fakten wartet, die Zeit endet oder das Modell fehlt. Mit
    /// `ignoringFacts` auch, wenn Folgen auf Fakten warten, etwa weil nur
    /// Private Cloud Compute bereitsteht und die Fakten ohnehin warten.
    func runTagsBacklog(ignoringFacts: Bool = false) async {
        while !Task.isCancelled, tagsMayRun, ignoringFacts || factsQueue.isEmpty || !factsMayRun {
            if tagsQueue.isEmpty {
                // Die Portion ist durch: die nächste, falls noch Folgen fehlen.
                guard tagsBackfillPending, let withFacts = try? await store.episodeIDsWithFacts() else { return }
                tagsBackfillPending = false
                await queueMissingChapterTags(withFacts: withFacts)
                if tagsQueue.isEmpty { return }
            }
            let next = tagsQueue.removeFirst()
            // Aus dem Rückstand der Bibliothek, nicht nach den Fakten einer Folge.
            let run = await ProcessingTrace.interval("Kapitel-Tags einer Folge") {
                await prepareChapterTags(for: next, origin: .backlog)
            }
            if run.current { tagsCurrent.insert(next.id) }
            emitTagsDone(next.id, run.outcome, origin: .backlog)
            switch run.outcome {
            case .stored:
                continue
            case .nothingToDo:
                // Sonst holte die nächste Portion dieselbe Folge wieder.
                tagsCurrent.insert(next.id)
                continue
            case .failed:
                // Ein zweiter Anlauf erst beim nächsten Start, ohne die Folge
                // dauerhaft aufzugeben: der gemerkte Stand bleibt. Meist ist
                // das Modell ausgelastet, also etwas Luft vor der nächsten.
                tagsFailed.insert(next.id)
                await pauseBetweenFactRuns()
                continue
            case .modelUnavailable, .waiting, .cancelled:
                tagsQueue.insert(next, at: 0)
                return
            }
        }
    }

    /// Nimmt eine gelöschte Folge aus der Einordnung, samt gemerktem Stand.
    func dropFromTagsQueue(_ id: EpisodeID) {
        tagsQueue.removeAll { $0.id == id }
        tagsCurrent.remove(id)
        Self.setTaggingProgress(nil, for: id)
    }

    /// Ein neues Transkript: Die Folge bekommt eine neue Gelegenheit, auch
    /// wenn die letzte Einordnung ohne Tag endete. Meist ordnet sie die
    /// Arbeit an den Fakten gleich danach ein. Scheitert das, holt es das
    /// Einreihen nach.
    func transcriptChangedForTags(_ id: EpisodeID) {
        tagsCurrent.remove(id)
        tagsFailed.remove(id)
        var settled = StoredEpisodeIDs(key: Self.tagsSettledKey)
        settled.remove(id)
    }

    /// Für die leichte Hintergrundaufgabe `com.podcastai.tagging`: nur Tags,
    /// keine Fakten. Endet die Zeit, bleibt der Stand der Folge gemerkt.
    ///
    /// Die Zeit vom System hält die Hintergrundaufgabe selbst am Tor
    /// (`holdCarrier(.taggingTask)` in `BackgroundWork`).
    public func processPendingTags() async {
        await refreshModelStatus()
        if let knowledgeStage {
            await knowledgeStage.reconcileTags()
            await knowledgeStage.untilIdle()
            return
        }
        if let withFacts = try? await store.episodeIDsWithFacts() {
            await queueMissingChapterTags(withFacts: withFacts)
        }
        if let stopping = factsTask, stopping.isCancelled {
            await stopping.value
            guard !Task.isCancelled else { return }
        }
        startFactsWorker()
        guard let task = factsTask else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Gemerkt auf diesem Gerät (`KnowledgeMarks` im Paket)

    static var tagsSettledKey: String { KnowledgeMarks.tagsSettledKey }
    static var taggingProgressKey: String { KnowledgeMarks.taggingProgressKey }
    static var taggingPaceKey: String { KnowledgeMarks.taggingPaceKey }

    static func taggingProgress(for id: EpisodeID) -> ChapterTaggingProgress? {
        KnowledgeMarks.taggingProgress(for: id)
    }

    /// Tags, die der gemerkte Stand der Einordnung anderer Folgen nennt.
    static func tagsInTaggingProgress(except excluded: Set<EpisodeID>) -> Set<InterestID> {
        KnowledgeMarks.tagsInTaggingProgress(except: excluded)
    }

    static func setTaggingProgress(_ progress: ChapterTaggingProgress?, for id: EpisodeID) {
        KnowledgeMarks.setTaggingProgress(progress, for: id)
    }
}

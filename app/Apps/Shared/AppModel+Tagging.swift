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
//  (`ChapterTaggingProgress` in den Benutzereinstellungen). Die Kapitel-Tags
//  gehen erst in die Datenbank, wenn die ganze Folge eingeordnet ist, in
//  einem Schritt. So schreibt der Abgleich nicht nach jedem Kapitel alle
//  Zeilen der Folge neu.
//

import Foundation
import Synchronization
import PodcastAIKit

/// Sammelt die Auswahlen eines Kapitels, auch aus einer anderen Aufgabe.
private final class TagSelectionLog: Sendable {
    let selections = Mutex<[TagSelection]>([])
    func add(_ selection: TagSelection) { selections.withLock { $0.append(selection) } }
    var all: [TagSelection] { selections.withLock { $0 } }
}

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
    ///
    /// Nur, wenn die Folge noch keine Kapitel-Tags aus der aktuellen
    /// Revision ihres Transkripts hat. Ein neues Transkript ordnet also neu
    /// ein. Ein früherer, abgebrochener Lauf setzt beim nächsten Kapitel fort.
    ///
    /// `origin`: wer die Arbeit wollte. Nach den Fakten einer Folge erben die
    /// Tags die Herkunft des Faktenlaufs. Den Vorrang je Aufruf bestimmt
    /// daraus ``AIPriorityPolicy``.
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

        // Nur die aktuelle Fassung, in ihrer neuesten Revision. Revisionen
        // zählen je Fassung, eine überholte kann die höhere tragen. Welche
        // Fassung aktuell ist, sagt die frisch gelesene Zeile der Folge, wie
        // beim Schreiben der Wächter im Store. Der Wert aus der Warteschlange
        // stammt oft von vor dem Transkript.
        let stored = (try? await store.evidence(forEpisode: episode.id)) ?? []
        let preferred = (try? await store.episodes(ids: [episode.id]))?.first?.currentMediaVersionID
            ?? episode.currentMediaVersionID
        guard let current = ChapterTagVersion.evidence(stored, preferred: preferred) else {
            return ChapterTagsRun(.nothingToDo)
        }
        let (mediaVersionID, revision, evidence) = current
        guard let backlog = try? await store.chapterTagBacklog(among: [episode.id]),
              backlog.contains(episode.id), !wasRemoved(episode.id, since: ticket) else {
            Self.setTaggingProgress(nil, for: episode.id)
            return ChapterTagsRun(.nothingToDo, current: !wasRemoved(episode.id, since: ticket))
        }

        await refreshModelStatus()
        let tier: ModelTier
        switch modelStatus.resolve(.tag) {
        case .success(let resolved): tier = resolved
        case .failure: return ChapterTagsRun(.modelUnavailable)
        }
        // Private Cloud Compute braucht Netz. Automatisch gilt dafür, was
        // fürs Vorbereiten gilt: Datensparmodus immer, Mobilfunk mit „Nur im WLAN“.
        let cloudPermitted = preparationWait == nil && !isOffline
        if tier == .privateCloudCompute, !cloudPermitted { return ChapterTagsRun(.waiting) }

        let sections = await Self.chapterSections(
            chapters: feedChapters(for: episode), duration: episode.declaredDuration, evidence: evidence)
        guard !sections.isEmpty else { return ChapterTagsRun(.nothingToDo) }
        var progress = Self.taggingProgress(for: episode.id).flatMap {
            $0.matches(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections) ? $0 : nil
        } ?? ChapterTaggingProgress(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections)

        let facts = ((try? await store.facts(forEpisode: episode.id)) ?? [])
            .filter { $0.mediaVersionID == mediaVersionID }
        let passages = ChapterSections.group(evidence, into: sections) { $0.range?.start }
        let statements = ChapterSections.group(facts, into: sections) { $0.range.start }
        let budget = TagSelectionRules.passageTokenBudget(contextSize: Self.onDeviceContextSize)
        let selector = TagSelector(useCase: .contentTagging, excerptLimit: Self.tagExcerptLimit)
        let priority = AIPriorityPolicy.priority(kind: .tags, origin: origin)
        // Jedes Schreiben dieser Einordnung geht durch den Wächter im Store.
        let writeGuard = commitGuard(for: episode, since: ticket)
        // Erkannte Tags, die diese Einordnung neu angelegt hat. Wird die Folge
        // gelöscht, gehen sie mit, sofern nichts anderes auf sie zeigt.
        var created = WriteReceipt(episodeID: episode.id)
        /// Merkt den Stand, außer die Folge wurde inzwischen gelöscht. Dann
        /// hat das Löschen ihn schon entfernt, und er bliebe sonst liegen.
        func keep(_ progress: ChapterTaggingProgress) {
            guard !wasRemoved(episode.id, since: ticket) else { return }
            Self.setTaggingProgress(progress, for: episode.id)
        }
        /// Die Folge ist weg: kein Stand, und die neuen Tags gehen mit.
        func abandon() async -> ChapterTagsRun {
            Self.setTaggingProgress(nil, for: episode.id)
            if !created.isEmpty {
                let elsewhere = Self.tagsInTaggingProgress(except: [episode.id])
                _ = try? await store.removeWrites(created, keepingTags: elsewhere)
            }
            return ChapterTagsRun(.nothingToDo)
        }

        for section in progress.remaining(sections) {
            if Task.isCancelled || !tagsMayRun {
                keep(progress)
                return ChapterTagsRun(.cancelled)
            }
            let material = ChapterMaterial(
                section: section, evidence: passages[section.index],
                statements: statements[section.index].map(\.statement))
            // Frisch je Kapitel: ein Oberbegriff aus dem vorigen Kapitel ist
            // jetzt ein bekanntes Tag.
            let tags = (try? await store.tags()) ?? []
            // Ohne Erlaubnis fürs Netz kennt die Auswahl Private Cloud
            // Compute gar nicht, auch nicht als Rückfall nach einem timeout.
            let status = cloudPermitted ? modelStatus : ModelStatus(
                onDevice: modelStatus.onDevice, privateCloudCompute: .unavailable(.offline))
            let preferCloud = Self.taggingPace.prefersCloud(status)
            let title = section.isDerived ? nil : section.title
            let log = TagSelectionLog()
            let picks: [ChapterTagPick]
            do {
                picks = try await Self.detached {
                    try await ChapterClassifier.classify(
                        material, tags: tags, budget: budget, cost: Self.tagTokenCost
                    ) { choices, part in
                        let selection = try await selector.select(
                            from: choices, passages: part, title: title,
                            availability: status, preferCloud: preferCloud, priority: priority)
                        log.add(selection)
                        return selection.chosenIDs
                    }
                }
            } catch let error as ExtractorError {
                Self.recordTaggingPace(log.all)
                switch error {
                case .generationRejected:
                    // Dieselbe Eingabe scheitert jedes Mal gleich: das Kapitel
                    // bleibt ohne Tags.
                    progress.finish(section, tags: [])
                    continue
                case .generationFailed:
                    keep(progress)
                    return ChapterTagsRun(.failed)
                case .modelUnavailable:
                    keep(progress)
                    await refreshModelStatus()
                    return ChapterTagsRun(.modelUnavailable)
                }
            } catch {
                keep(progress)
                return ChapterTagsRun(.cancelled)
            }
            Self.recordTaggingPace(log.all)
            guard !wasRemoved(episode.id, since: ticket) else { return await abandon() }

            var chapterTags: [ChapterTag] = []
            for pick in picks {
                // Ein neuer Oberbegriff wird ein erkanntes, neutrales Tag.
                // Gibt es den Schlüssel inzwischen, gilt das vorhandene Tag.
                var tagID = pick.tagID
                if tagID == nil, let added = try? await store.addDetectedTag(label: pick.label, under: writeGuard) {
                    if let receipt = added.receipt { created.merge(receipt) }
                    if case .written(_, let tag) = added { tagID = tag?.id }
                }
                guard let tagID else { continue }
                chapterTags.append(ChapterTag(
                    episodeID: episode.id, mediaVersionID: mediaVersionID,
                    chapterStartMs: Int(section.range.start.milliseconds),
                    chapterEndMs: Int(section.range.end.milliseconds),
                    interestID: tagID, normalizedKey: pick.normalizedKey,
                    confidence: pick.confidence, matchedKnown: pick.tagID != nil,
                    sourceID: episode.sourceID, publishedAt: episode.publishedAt,
                    transcriptRevision: Revision(revision)))
            }
            progress.finish(section, tags: chapterTags)
            keep(progress)
        }

        guard !wasRemoved(episode.id, since: ticket) else { return await abandon() }
        do {
            switch try await store.commit(
                chapterTags: progress.tags, media: mediaVersionID, transcriptRevision: Revision(revision),
                under: writeGuard) {
            case .written(let receipt, _):
                created.merge(receipt)
            case .stale(.superseded):
                // Eine Einordnung aus einer neueren Revision steht schon da.
                // Wie bisher gilt die Folge damit als eingeordnet.
                break
            case .stale:
                // Die Folge ist weg, oder ihr Transkript ist nicht mehr das,
                // aus dem die Tags entstanden. Der Stand passt nicht mehr.
                return await abandon()
            }
        } catch {
            keep(progress)
            return ChapterTagsRun(.failed)
        }
        Self.setTaggingProgress(nil, for: episode.id)
        // Gleich nach dem Speichern gelöscht: genau diese Kapitel-Tags wieder
        // weg, vor jedem Vermerk auf diesem Gerät.
        if wasRemoved(episode.id, since: ticket) { return await abandon() }
        // Kein Kapitel bekam ein Tag: es entsteht keine Zeile, und ohne
        // Merkzeichen reihte der nächste Start die Folge wieder ein.
        if progress.tags.isEmpty {
            var settled = StoredEpisodeIDs(key: Self.tagsSettledKey)
            settled.insert(episode.id)
        }
        return ChapterTagsRun(.stored, current: true)
    }

    /// Läuft außerhalb des Hauptthreads, denn Kandidaten und Satzvektoren
    /// kosten Rechenzeit. Ein Abbruch erreicht die Arbeit trotzdem.
    private nonisolated static func detached<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility) { try await work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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

    // MARK: - Gemerkt auf diesem Gerät

    /// So viele Zeichen je Beleg sieht das Modell.
    nonisolated static let tagExcerptLimit = 500

    /// Token eines Belegs, gerechnet wie bei den Fakten mit drei Zeichen je Token.
    nonisolated static func tagTokenCost(_ evidence: Evidence) -> Int {
        (min(evidence.quotedText.count, tagExcerptLimit) + 8) / 3
    }

    /// Folgen, die ohne ein einziges Tag eingeordnet sind. Je Systemversion,
    /// wie bei den Fakten: ein neues Modell bekommt eine neue Gelegenheit.
    static var tagsSettledKey: String { KnowledgeMarks.tagsSettledKey }

    static let taggingProgressKey = "chapterTaggingProgress"
    /// Je Systemversion: Ein neues Modell wird neu gemessen. Sonst bliebe
    /// ein einmal langsames Gerät bei Private Cloud Compute, denn dort
    /// entstehen keine neuen Messungen auf dem Gerät.
    static var taggingPaceKey: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "chapterTaggingPace-\(system.majorVersion).\(system.minorVersion)"
    }

    /// Der Stand aller angefangenen Folgen, als Datei in `DeviceState`. Er
    /// trägt die fertigen Kapitel-Tags und wächst mit jeder angefangenen Folge.
    private static var allTaggingProgress: [String: ChapterTaggingProgress] {
        DeviceState.shared.value([String: ChapterTaggingProgress].self, for: taggingProgressKey) {
            (UserDefaults.standard.dictionary(forKey: taggingProgressKey) as? [String: Data])?
                .compactMapValues { try? JSONDecoder().decode(ChapterTaggingProgress.self, from: $0) }
        } ?? [:]
    }

    static func taggingProgress(for id: EpisodeID) -> ChapterTaggingProgress? {
        allTaggingProgress[id.rawValue]
    }

    /// Tags, die der gemerkte Stand der Einordnung anderer Folgen nennt. Sie
    /// stehen noch in keinem Kapitel-Tag, gehören aber zu Folgen, die es
    /// noch gibt. Das Aufräumen nach einer Löschung lässt sie stehen, sonst
    /// fiele ihr Kapitel-Tag beim Speichern still weg.
    static func tagsInTaggingProgress(except excluded: Set<EpisodeID>) -> Set<InterestID> {
        var ids: Set<InterestID> = []
        for (key, progress) in allTaggingProgress where !excluded.contains(EpisodeID(rawValue: key)) {
            ids.formUnion(progress.tags.map(\.interestID))
        }
        return ids
    }

    static func setTaggingProgress(_ progress: ChapterTaggingProgress?, for id: EpisodeID) {
        var stored = allTaggingProgress
        if let progress, progress.isStarted {
            guard stored[id.rawValue] != progress else { return }
            stored[id.rawValue] = progress
        } else {
            guard stored[id.rawValue] != nil else { return }
            stored[id.rawValue] = nil
        }
        DeviceState.shared.set(stored, for: taggingProgressKey)
    }

    /// Wie schnell das Gerätemodell auf diesem Gerät Tags wählt.
    static var taggingPace: TaggingPace {
        guard let data = UserDefaults.standard.data(forKey: taggingPaceKey),
              let pace = try? JSONDecoder().decode(TaggingPace.self, from: data) else { return TaggingPace() }
        return pace
    }

    static func recordTaggingPace(_ selections: [TagSelection]) {
        // Auch ein Aufruf, der auf dem Gerät an der Zeit scheiterte und dann
        // von Private Cloud Compute kam, zählt als langsamer Aufruf.
        let local = selections.compactMap { $0.tier == .onDevice ? $0.seconds : $0.timedOutOnDeviceSeconds }
        guard !local.isEmpty else { return }
        var pace = taggingPace
        for seconds in local { pace.record(onDeviceSeconds: seconds) }
        if let data = try? JSONEncoder().encode(pace) {
            UserDefaults.standard.set(data, forKey: taggingPaceKey)
        }
    }
}

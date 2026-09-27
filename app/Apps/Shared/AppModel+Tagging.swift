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
import PodcastAIKit

/// Wie eine Einordnung ausging.
enum ChapterTagsOutcome: Equatable {
    /// Gespeichert, auch wenn kein Kapitel ein Tag bekam.
    case stored
    /// Nichts zu tun: schon eingeordnet, keine Belege oder gelöscht.
    case nothingToDo
    /// Kein Modell für Tags, etwa ohne Netz und ohne Gerätemodell. Die Folge wartet.
    case modelUnavailable
    /// Abgebrochen, etwa weil die Zeit im Hintergrund endete. Die fertigen
    /// Kapitel bleiben gemerkt.
    case cancelled
    /// Ein Aufruf ist an Last oder Zeit gescheitert. Ein späterer Lauf setzt fort.
    case failed
}

extension AppModel {

    /// Darf die Einordnung jetzt arbeiten? Wie die Fakten, und zusätzlich
    /// in der leichten Hintergrundaufgabe `com.podcastai.tagging`.
    /// In der Pause arbeitet auch sie nicht.
    var tagsMayRun: Bool { factsMayRun || (tagGrants > 0 && !queueHeld) }

    /// Ist ein Modell für Tags da oder fehlt es nur vorübergehend, etwa
    /// weil das Netz weg ist oder das Gerätemodell noch lädt?
    var tagsModelExpected: Bool {
        switch modelStatus.resolve(.tag) {
        case .success: true
        case .failure(let reason): reason.isTemporary
        }
    }

    // MARK: - Eine Folge

    /// Ordnet die Kapitel einer Folge ein und speichert die Kapitel-Tags.
    ///
    /// Nur, wenn die Folge noch keine Kapitel-Tags aus der aktuellen
    /// Revision ihres Transkripts hat. Ein neues Transkript ordnet also neu
    /// ein. Ein früherer, abgebrochener Lauf setzt beim nächsten Kapitel fort.
    @discardableResult
    func prepareChapterTags(for episode: Episode) async -> ChapterTagsOutcome {
        guard !taggingInProgress.contains(episode.id) else { return .nothingToDo }
        taggingInProgress.insert(episode.id)
        defer { taggingInProgress.remove(episode.id) }
        let ticket = removalCount

        // Nur die aktuelle Fassung, in ihrer neuesten Revision. Revisionen
        // zählen je Fassung, eine überholte kann die höhere tragen.
        let stored = (try? await store.evidence(forEpisode: episode.id)) ?? []
        guard let current = ChapterTagVersion.evidence(stored, preferred: episode.currentMediaVersionID) else {
            return .nothingToDo
        }
        let (mediaVersionID, revision, evidence) = current
        guard let backlog = try? await store.chapterTagBacklog(among: [episode.id]),
              backlog.contains(episode.id), !wasRemoved(episode.id, since: ticket) else {
            Self.setTaggingProgress(nil, for: episode.id)
            if !wasRemoved(episode.id, since: ticket) { tagsCurrent.insert(episode.id) }
            return .nothingToDo
        }

        // Private Cloud Compute zuerst, ohne Netz das Gerät. Fehlen beide,
        // wartet die Folge. `refreshModelStatus` kennt das Netz schon.
        await refreshModelStatus()
        guard case .success = modelStatus.resolve(.tag) else { return .modelUnavailable }

        let sections = await Self.chapterSections(
            chapters: feedChapters(for: episode), duration: episode.declaredDuration, evidence: evidence)
        guard !sections.isEmpty else { return .nothingToDo }
        var progress = Self.taggingProgress(for: episode.id).flatMap {
            $0.matches(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections) ? $0 : nil
        } ?? ChapterTaggingProgress(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections)

        let facts = ((try? await store.facts(forEpisode: episode.id)) ?? [])
            .filter { $0.mediaVersionID == mediaVersionID }
        let passages = ChapterSections.group(evidence, into: sections) { $0.range?.start }
        let statements = ChapterSections.group(facts, into: sections) { $0.range.start }
        let budget = TagSelectionRules.passageTokenBudget(contextSize: Self.onDeviceContextSize)
        let selector = TagSelector(useCase: .contentTagging, excerptLimit: Self.tagExcerptLimit)

        for section in progress.remaining(sections) {
            if Task.isCancelled || !tagsMayRun {
                Self.setTaggingProgress(progress, for: episode.id)
                return .cancelled
            }
            let material = ChapterMaterial(
                section: section, evidence: passages[section.index],
                statements: statements[section.index].map(\.statement))
            // Frisch je Kapitel: ein Oberbegriff aus dem vorigen Kapitel ist
            // jetzt ein bekanntes Tag.
            let tags = (try? await store.tags()) ?? []
            let status = modelStatus
            let title = section.isDerived ? nil : section.title
            let picks: [ChapterTagPick]
            do {
                picks = try await Self.detached {
                    try await ChapterClassifier.classify(
                        material, tags: tags, budget: budget, cost: Self.tagTokenCost
                    ) { choices, part in
                        try await selector.select(
                            from: choices, passages: part, title: title, availability: status
                        ).chosenIDs
                    }
                }
            } catch let error as ExtractorError {
                switch error {
                case .generationRejected:
                    // Dieselbe Eingabe scheitert jedes Mal gleich: das Kapitel
                    // bleibt ohne Tags.
                    progress.finish(section, tags: [])
                    continue
                case .generationFailed:
                    Self.setTaggingProgress(progress, for: episode.id)
                    tagsFailed.insert(episode.id)
                    return .failed
                case .modelUnavailable:
                    Self.setTaggingProgress(progress, for: episode.id)
                    await refreshModelStatus()
                    return .modelUnavailable
                }
            } catch {
                Self.setTaggingProgress(progress, for: episode.id)
                return .cancelled
            }
            guard !wasRemoved(episode.id, since: ticket) else {
                Self.setTaggingProgress(nil, for: episode.id)
                return .nothingToDo
            }

            var chapterTags: [ChapterTag] = []
            for pick in picks {
                // Ein neuer Oberbegriff wird ein erkanntes, neutrales Tag.
                // Gibt es den Schlüssel inzwischen, gilt das vorhandene Tag.
                var tagID = pick.tagID
                if tagID == nil { tagID = (try? await store.addDetectedTag(label: pick.label))?.id }
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
            Self.setTaggingProgress(progress, for: episode.id)
        }

        guard !wasRemoved(episode.id, since: ticket) else {
            Self.setTaggingProgress(nil, for: episode.id)
            return .nothingToDo
        }
        do {
            try await store.save(chapterTags: progress.tags, forEpisode: episode.id,
                                 transcriptRevision: Revision(revision))
        } catch {
            Self.setTaggingProgress(progress, for: episode.id)
            tagsFailed.insert(episode.id)
            return .failed
        }
        Self.setTaggingProgress(nil, for: episode.id)
        tagsCurrent.insert(episode.id)
        // Kein Kapitel bekam ein Tag: es entsteht keine Zeile, und ohne
        // Merkzeichen reihte der nächste Start die Folge wieder ein.
        if progress.tags.isEmpty {
            var settled = StoredEpisodeIDs(key: Self.tagsSettledKey)
            settled.insert(episode.id)
        }
        // Während des Speicherns gelöscht: die Kapitel-Tags gleich wieder weg.
        if wasRemoved(episode.id, since: ticket) {
            _ = try? await store.save(chapterTags: [], forEpisode: episode.id, transcriptRevision: Revision(revision))
            return .nothingToDo
        }
        return .stored
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
    /// sammeln, wartet sie nicht darauf. Fakten und Tags laufen über dieselbe
    /// Stufe, das kommt also nur vor, wenn für beide kein Modell da ist.
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
    /// Fakten wartet, die Zeit endet oder das Modell fehlt.
    func runTagsBacklog() async {
        while !Task.isCancelled, tagsMayRun, factsQueue.isEmpty || !factsMayRun {
            if tagsQueue.isEmpty {
                // Die Portion ist durch: die nächste, falls noch Folgen fehlen.
                guard tagsBackfillPending, let withFacts = try? await store.episodeIDsWithFacts() else { return }
                tagsBackfillPending = false
                await queueMissingChapterTags(withFacts: withFacts)
                if tagsQueue.isEmpty { return }
            }
            let next = tagsQueue.removeFirst()
            let outcome = await ProcessingTrace.interval("Kapitel-Tags einer Folge") {
                await prepareChapterTags(for: next)
            }
            switch outcome {
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
                await pauseBetweenFactRuns()
                continue
            case .modelUnavailable, .cancelled:
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
    public func processPendingTags() async {
        tagGrants += 1
        defer {
            tagGrants = max(0, tagGrants - 1)
            pauseFactsWithoutTime()
        }
        await refreshModelStatus()
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
    static var tagsSettledKey: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "tagsSettled-\(system.majorVersion).\(system.minorVersion)"
    }

    static let taggingProgressKey = "chapterTaggingProgress"

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
}

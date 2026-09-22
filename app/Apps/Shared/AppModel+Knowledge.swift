//
//  AppModel+Knowledge.swift
//  PodcastAI
//
//  Fragen stellen, Fakten ermitteln, exportieren und löschen.
//
//  Fragen gehen an eine Folge, an mehrere oder an alles, was erschlossen
//  ist. Gesucht wird auf dem Gerät, formuliert wird mit Apple Intelligence:
//  auf Private Cloud Compute, wenn es verfügbar und erlaubt ist, sonst mit
//  dem Gerätemodell. Jede Aussage der Antwort zeigt auf eine Stelle im
//  Originalton.
//

import Foundation
import CoreData
import PodcastAIKit

extension AppModel {

    // MARK: - Abgleich zwischen Geräten

    /// Lädt neu, wenn über iCloud Änderungen eines anderen Geräts ankommen.
    /// Mehrere Meldungen kurz hintereinander werden zu einem Neuladen.
    public func observeRemoteChanges() {
        Task { [weak self] in
            var pending: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                pending?.cancel()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.reloadAfterSync()
                }
            }
        }
    }

    public func reloadAfterSync() async {
        await load()
        for source in sources where episodes[source.id] != nil {
            if let list = try? await store.episodes(forSource: source.id) {
                episodes[source.id] = list
                RemoteMediaRegistry.shared.register(list)
            }
        }
        for id in Array(facts.keys) { await loadFacts(for: id) }
    }

    // MARK: - Modellzustand

    public func refreshModelStatus() async {
        modelStatus = ModelStatusProbe.current(allowPrivateCloud: allowPrivateCloudCompute)
    }

    /// Läuft die Antwort gerade über Private Cloud Compute?
    var answersUsePrivateCloud: Bool {
        if case .success(.privateCloudCompute) = modelStatus.resolve(.answer) { return true }
        return false
    }

    // MARK: - Fragen

    public func ask(_ question: String, scope: ChatScope) async -> ChatAnswer {
        activity = "Antwort wird gesucht …"
        defer { activity = nil }

        let pool: [Evidence]
        var libraryContext = ""
        var caveat: String?
        switch scope {
        case .episode(let id):
            pool = (try? await store.evidence(forEpisode: id)) ?? []
            libraryContext = await episodeContext(id)
            if pool.isEmpty {
                return ChatAnswer(
                    question: question, scope: scope,
                    text: "Diese Folge ist noch nicht erschlossen. Tippe in der Folge auf „Erschliessen“, "
                        + "danach kann ich mit Belegen aus dem Transkript antworten.",
                    citations: [])
            }
        case .episodes(let ids):
            var all: [Evidence] = []
            for id in ids { all += (try? await store.evidence(forEpisode: id)) ?? [] }
            pool = all
        case .smartFeed, .allAnalyzed:
            pool = (try? await store.evidenceForAnalyzedEpisodes(limit: 20_000)) ?? []
            libraryContext = await libraryOverview()
            let known = episodes.values.flatMap { $0 }.count
            let analyzed = analyzedEpisodes.count
            if known > analyzed {
                caveat = "Durchsucht wurden \(analyzed) erschlossene von \(known) bekannten Folgen."
            }
        }

        guard !pool.isEmpty || !libraryContext.isEmpty else {
            return ChatAnswer(
                question: question, scope: scope,
                text: "Dazu ist noch nichts erschlossen. Füge eine Quelle hinzu; die App bereitet "
                    + "die neuesten Folgen von selbst vor, danach antworte ich mit Belegen.",
                citations: [], coverageCaveat: caveat)
        }

        let wide = answersUsePrivateCloud
        let limit = wide ? 60 : 16
        let overview = Self.asksForOverview(question)
        var candidates = PassageRanker().rank(pool, for: question, limit: overview ? pool.count : limit,
                                              keepAll: overview)
        if overview {
            // Für „worum geht es“ zählt die ganze Folge, gleichmässig verteilt.
            let ordered = pool.sorted { ($0.range?.start.milliseconds ?? 0) < ($1.range?.start.milliseconds ?? 0) }
            candidates = Self.evenlySpaced(ordered, count: limit)
        }

        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: wide ? 900 : 420, maximumCandidates: limit)))
        do {
            let composed = try await extractor.answer(
                question: question, from: candidates, libraryContext: libraryContext,
                availability: modelStatus)
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var cited = composed.citations.sorted { $0.key < $1.key }.compactMap { byID[$0.value] }
            if cited.isEmpty { cited = composed.claims.flatMap(\.evidenceIDs).compactMap { byID[$0] } }
            var text = composed.text
            if text.isEmpty {
                text = composed.claims.map { "• \($0.statement)" }.joined(separator: "\n")
            }
            if text.isEmpty { text = "Dazu steht in den erschlossenen Folgen nichts Belegtes." }
            return ChatAnswer(
                question: question, scope: scope, text: text, citations: cited,
                coverageCaveat: caveat, modelLabel: composed.tier?.label,
                citationNumbers: composed.citations)
        } catch {
            // Ohne Modell wird nichts erfunden. Dann zeigt die Antwort die
            // passendsten Stellen im Wortlaut, mit Sprung in den Originalton.
            let top = Array(candidates.prefix(4))
            let reason = (error as? ExtractorError)?.errorDescription ?? error.localizedDescription
            let text = top.isEmpty
                ? "Dazu finde ich keine passende Stelle. \(reason)"
                : "Formulieren kann ich gerade nicht (\(reason)). Diese Stellen passen am besten:\n\n"
                    + top.enumerated().map { "[\($0.offset + 1)] \(String($0.element.quotedText.prefix(220)))…" }
                        .joined(separator: "\n\n")
            var numbers: [Int: EvidenceID] = [:]
            for (offset, item) in top.enumerated() { numbers[offset + 1] = item.id }
            return ChatAnswer(question: question, scope: scope, text: text, citations: top,
                              coverageCaveat: caveat, modelLabel: nil, citationNumbers: numbers)
        }
    }

    static func asksForOverview(_ question: String) -> Bool {
        let lower = question.lowercased()
        return ["zusammen", "worum", "überblick", "ueberblick", "kernaussage", "wichtigste",
                "summar", "overview", "tl;dr", "kurz gesagt"].contains { lower.contains($0) }
    }

    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }

    /// Was der Chat über eine Folge ausser dem Transkript wissen soll.
    func episodeContext(_ id: EpisodeID) async -> String {
        guard let episode = (try? await store.episodes(ids: [id]))?.first else { return "" }
        let source = sources.first { $0.id == episode.sourceID }?.title ?? ""
        var lines = ["Folge: \(episode.title)", "Podcast: \(source)"]
        if let date = episode.publishedAt { lines.append("Erschienen: \(date.formatted(date: .long, time: .omitted))") }
        if let duration = episode.declaredDuration { lines.append("Länge: \(duration.shortDescription)") }
        let chapters = episode.publisherChapters.isEmpty ? (chapterCache[id] ?? []) : episode.publisherChapters
        if !chapters.isEmpty {
            lines.append("Kapitel: " + chapters.map { "\($0.start.timecode) \($0.title)" }.joined(separator: "; "))
        }
        if let notes = ShownotesText.plain(episode.shownotesHTML ?? episode.summary) {
            lines.append("Shownotes: " + String(notes.prefix(1_500)))
        }
        var known = facts[id] ?? []
        if known.isEmpty { known = (try? await store.facts(forEpisode: id)) ?? [] }
        if !known.isEmpty {
            lines.append("Bereits ermittelte Fakten: " + known.prefix(15).map(\.statement).joined(separator: " | "))
        }
        lines.append("Gehört: \(Int(heardFraction(for: episode) * 100)) %")
        return lines.joined(separator: "\n")
    }

    /// Ein Überblick über die ganze Mediathek, damit auch Fragen wie „Welche
    /// Folgen habe ich zu KI?“ oder „Was habe ich diese Woche gehört?“
    /// eine Antwort finden.
    func libraryOverview() async -> String {
        var lines: [String] = []
        for source in sources {
            let list = episodes[source.id] ?? []
            lines.append("Podcast: \(source.title) (\(list.count) Folgen)")
            for episode in list.prefix(12) {
                var entry = "- \(episode.title)"
                if let date = episode.publishedAt { entry += ", \(date.formatted(date: .abbreviated, time: .omitted))" }
                entry += analyzedEpisodes.contains(episode.id) ? ", erschlossen" : ", nicht erschlossen"
                let heard = Int(heardFraction(for: episode) * 100)
                if heard > 0 { entry += ", \(heard) % gehört" }
                lines.append(entry)
            }
        }
        if !profile.confirmed.isEmpty {
            lines.append("Interessen: " + profile.confirmed.map(\.label).joined(separator: ", "))
        }
        let notes = highlights.compactMap(\.note).prefix(10)
        if !notes.isEmpty { lines.append("Eigene Notizen: " + notes.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    /// Spielt die Folge eines Belegs ab der Stelle.
    public func playEvidenceInEpisode(_ evidence: Evidence, at seconds: Double) async {
        guard let episode = (try? await store.episodes(ids: [evidence.episodeID]))?.first else { return }
        playEpisode(episode, at: seconds)
    }

    // MARK: - Fakten

    /// Ermittelt die Fakten einer Folge aus ihren Belegen und speichert sie.
    public func prepareFacts(for episode: Episode, force: Bool = false) async {
        guard !factsInProgress.contains(episode.id) else { return }
        if !force, let cached = try? await store.facts(forEpisode: episode.id), !cached.isEmpty {
            facts[episode.id] = cached
            return
        }
        let evidence = ((try? await store.evidence(forEpisode: episode.id)) ?? []).filter { $0.range != nil }
        guard !evidence.isEmpty else { return }
        factsInProgress.insert(episode.id)
        defer { factsInProgress.remove(episode.id) }

        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chunk = answersUsePrivateCloud ? 40 : 14
        var result: [EpisodeFact] = []
        var tier = ModelTier.onDevice.label
        for start in stride(from: 0, to: evidence.count, by: chunk) {
            let slice = Array(evidence[start..<min(start + chunk, evidence.count)])
            guard let claims = try? await KnowledgeExtractor(configuration: ExtractorConfiguration(
                candidateBuilder: CandidateListBuilder(excerptLimit: 600, maximumCandidates: chunk)))
                .extractClaims(from: slice, availability: modelStatus) else { break }
            if answersUsePrivateCloud { tier = ModelTier.privateCloudCompute.label }
            for claim in claims {
                guard let evidenceID = claim.evidenceIDs.first, let source = byID[evidenceID],
                      let range = source.range else { continue }
                result.append(EpisodeFact(
                    id: claim.id.rawValue, episodeID: episode.id, sourceID: source.sourceID,
                    evidenceID: evidenceID, mediaVersionID: source.mediaVersionID,
                    statement: claim.statement, range: range, modelTier: tier))
            }
            if result.count >= 40 { break }
        }
        guard !result.isEmpty else { return }
        let unique = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.range.start.milliseconds < $1.range.start.milliseconds }
        facts[episode.id] = unique
        try? await store.save(facts: unique, forEpisode: episode.id)
    }

    public func loadFacts(for episodeID: EpisodeID) async {
        if let stored = try? await store.facts(forEpisode: episodeID) { facts[episodeID] = stored }
    }

    public func transcript(for episode: Episode) async -> Transcript? {
        try? await store.transcript(forEpisode: episode.id)
    }

    // MARK: - Export

    /// Die ganze Folge als Markdown: Shownotes, Kapitel, Fakten, Transkript.
    public func exportEpisode(_ episode: Episode, includeTranscript: Bool = true) async -> String {
        let source = sources.first { $0.id == episode.sourceID }?.title ?? ""
        let chapters = episode.publisherChapters.isEmpty ? (chapterCache[episode.id] ?? []) : episode.publisherChapters
        var known = facts[episode.id] ?? []
        if known.isEmpty { known = (try? await store.facts(forEpisode: episode.id)) ?? [] }
        let dossier = EpisodeDossier(
            title: episode.title, sourceTitle: source, publishedAt: episode.publishedAt,
            duration: episode.declaredDuration, webPageURL: episode.webPageURL,
            shownotes: ShownotesText.plain(episode.shownotesHTML ?? episode.summary),
            chapters: chapters, facts: known,
            transcript: includeTranscript ? await transcript(for: episode) : nil)
        return EpisodeDossierExporter().markdown(dossier, includeTranscript: includeTranscript)
    }

    /// Eine Chat-Antwort mit ihren Belegen als Markdown.
    public func exportAnswer(_ answer: ChatAnswer) async -> String {
        let titles = (try? await store.titles(forEpisodes: answer.citations.map(\.episodeID))) ?? [:]
        let numberFor = Dictionary(answer.citationNumbers.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let citations = answer.citations.enumerated().map { offset, evidence in
            (number: numberFor[evidence.id] ?? offset + 1,
             episode: titles[evidence.episodeID]?.episode ?? "Folge",
             source: titles[evidence.episodeID]?.source ?? "Quelle",
             range: evidence.range, quote: evidence.quotedText)
        }
        return EpisodeDossierExporter().markdown(ExportedAnswer(
            question: answer.question, scopeLabel: answer.scope.label, text: answer.text,
            modelLabel: answer.modelLabel, citations: citations))
    }

    // MARK: - Entfernen

    /// Löscht nur die Audiodatei. Transkript, Fakten, Belege und Hörzustand
    /// bleiben, abspielen geht danach als Stream.
    public func removeAudio(for episode: Episode) async {
        if episodePlayer.episode?.id == episode.id { episodePlayer.stop() }
        guard let ids = try? await store.mediaVersionIDs(forEpisode: episode.id) else { return }
        LocalMediaLocator.removeFiles(for: ids)
        try? await store.markAudioRemoved(ids)
        mediaStorageChanged += 1
    }

    /// Löscht alle geladenen Audiodateien. Alle Daten bleiben.
    public func removeAllAudio() async {
        episodePlayer.stop()
        let removed = LocalMediaLocator.removeAllFiles()
        try? await store.markAudioRemoved(removed)
        mediaStorageChanged += 1
    }

    /// Löscht die Folge und alles, was aus ihr entstanden ist.
    public func removeEpisode(_ episode: Episode) async {
        if episodePlayer.episode?.id == episode.id { episodePlayer.stop() }
        removeFromUpNext(episode.id)
        removeFromAnalysisQueue(episode.id)
        do {
            let report = try await store.removeEpisode(episode.id)
            applyRemoval(report)
            episodes[episode.sourceID]?.removeAll { $0.id == episode.id }
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    /// Bestellt eine Quelle ab und löscht alle ihre Folgen samt Daten.
    public func removeSource(_ sourceID: SourceID) async {
        if episodePlayer.episode?.sourceID == sourceID { episodePlayer.stop() }
        for episode in episodes[sourceID] ?? [] {
            removeFromUpNext(episode.id)
            removeFromAnalysisQueue(episode.id)
        }
        do {
            let report = try await store.removeSource(sourceID)
            applyRemoval(report)
            episodes[sourceID] = nil
            sources.removeAll { $0.id == sourceID }
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    private func applyRemoval(_ report: LibraryStore.RemovalReport) {
        LocalMediaLocator.removeFiles(for: report.mediaVersionIDs)
        for id in report.episodeIDs {
            facts[id] = nil
            stages[id] = nil
            stageDetails[id] = nil
            analyzedEpisodes.remove(id)
        }
        let removedEvidence = Set(report.evidenceIDs)
        highlights.removeAll { removedEvidence.contains($0.evidenceID) }
        reindexSpotlight()
        mediaStorageChanged += 1
        Task {
            ledger = (try? await store.ledger()) ?? ledger
            await refreshRelevantToday()
        }
    }
}

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
#if canImport(FoundationModels)
// Nur dieser Typ: FoundationModels hat einen eigenen `Transcript`, der sonst
// mit dem aus PodcastAIKit kollidiert.
import class FoundationModels.SystemLanguageModel
#endif

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
        // `load()` räumt dabei auch weg, was ein anderes Gerät gelöscht hat.
        await load()
        for source in sources where episodes[source.id] != nil {
            if let list = try? await store.episodes(forSource: source.id) {
                episodes[source.id] = list
                RemoteMediaRegistry.shared.register(list)
            }
        }
        for id in Array(facts.keys) { await loadFacts(for: id) }
    }

    /// Wendet Löschungen an, die über iCloud von einem anderen Gerät kommen.
    ///
    /// Audiodateien werden nicht abgeglichen, jedes Gerät hat seine eigenen.
    /// Ebenso „Als Nächstes“, die Warteschlange der Erschliessung und die
    /// gemerkten Stellen im Player. Das alles räumt dieses Gerät hier selbst
    /// auf. Gelöschte Folgen erkennt es an ihrem Merkzeichen, abbestellte
    /// Quellen daran, dass es sie nicht mehr gibt.
    func forgetEpisodesRemovedElsewhere() async {
        let liveSources = Set(sources.map(\.id))
        var gone: [EpisodeID: Episode] = [:]
        // Eine abbestellte Quelle hinterlässt kein Merkzeichen. Ihre Folgen
        // kennt nur noch die Liste im Speicher.
        for (sourceID, list) in episodes where !liveSources.contains(sourceID) {
            for episode in list { gone[episode.id] = episode }
            episodes[sourceID] = nil
        }
        // Eine Folge ohne Quelle ist nicht abbestellt. Sie hat ihre Quellzeile
        // beim Abgleich verloren, und das Bereinigen hängt sie wieder an.
        // Gelöscht ist sie erst, wenn ein Merkzeichen das sagt.
        for episode in episodesInUse
        where !episode.sourceID.rawValue.isEmpty && !liveSources.contains(episode.sourceID) {
            gone[episode.id] = episode
        }
        if let tombstones = try? await store.removedEpisodes() {
            for episode in tombstones where isStillHeldLocally(episode) {
                gone[episode.id] = episode
            }
        }
        guard !gone.isEmpty else { return }

        let removed = Array(gone.values)
        prepareRemoval(removed)
        // Was dieses Gerät erschlossen hat, bevor die Löschung ankam, geht mit.
        for episode in removed
        where analyzedEpisodes.contains(episode.id) || !(facts[episode.id] ?? []).isEmpty {
            if let report = try? await store.removeEpisode(episode.id) { applyRemoval(report) }
        }
        LocalMediaLocator.removeFiles(for: Self.localMediaIDs(of: removed))
        for id in gone.keys {
            facts[id] = nil
            stages[id] = nil
            stageDetails[id] = nil
            analyzedEpisodes.remove(id)
        }
        pruneChatAnswers(removedEpisodes: Set(gone.keys))
        pruneEditions(removedEpisodes: Set(gone.keys))
        mediaStorageChanged += 1
    }

    /// Folgen, mit denen dieses Gerät gerade etwas vorhat.
    private var episodesInUse: [Episode] {
        var list = upNext + analysisQueue
        if let analyzing { list.append(analyzing) }
        if let playing = episodePlayer.episode { list.append(playing) }
        return list
    }

    /// Hält dieses Gerät noch etwas von einer gelöschten Folge? Alte
    /// Merkzeichen, zu denen nichts mehr da ist, kosten so keine Arbeit.
    private func isStillHeldLocally(_ episode: Episode) -> Bool {
        let id = episode.id
        if episodesInUse.contains(where: { $0.id == id }) { return true }
        if analyzedEpisodes.contains(id) || facts[id] != nil || stages[id] != nil { return true }
        if episodePlayer.savedPosition(for: id) != nil { return true }
        if chatAnswers.contains(where: { Self.answer($0, touches: [id]) }) { return true }
        let locator = LocalMediaLocator()
        return Self.localMediaIDs(of: [episode]).contains { locator.localFile(for: $0) != nil }
    }

    /// Unter diesen Kennungen kann die Audiodatei einer Folge liegen.
    private static func localMediaIDs(of episodes: [Episode]) -> [MediaVersionID] {
        var ids: [MediaVersionID] = []
        for episode in episodes {
            if let current = episode.currentMediaVersionID { ids.append(current) }
            if let audio = episode.audioURL { ids.append(MediaVersionID(stable: audio.absoluteString)) }
        }
        return ids
    }

    // MARK: - Modellzustand

    public func refreshModelStatus() async {
        modelStatus = ModelStatusProbe.current(allowPrivateCloud: allowPrivateCloudCompute)
    }

    /// Wie viele Token das Gerätemodell für Anweisungen, Prompt und Antwort
    /// zusammen fasst. Auf iOS 26 und macOS 26 sind es 4.096.
    static var onDeviceContextSize: Int {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.contextSize
        #else
        4_096
        #endif
    }

    /// Läuft die Antwort gerade über Private Cloud Compute?
    var answersUsePrivateCloud: Bool {
        if case .success(.privateCloudCompute) = modelStatus.resolve(.answer) { return true }
        return false
    }

    // MARK: - Fragen

    /// Stellt eine Frage und nimmt die Antwort in den Verlauf auf, neueste zuerst.
    ///
    /// Eine Antwort braucht einige Sekunden. Wird in dieser Zeit eine Folge
    /// gelöscht, hat das Aufräumen in `pruneChatAnswers` die Antwort noch
    /// nicht gesehen. Deshalb wird hier beim Einfügen noch einmal geprüft.
    /// Galt die Frage einer Folge, die inzwischen gelöscht ist, kommt keine
    /// Antwort. Stützt sich die Antwort nur auf eine gelöschte Folge, steht
    /// statt ihrer ein Hinweis da, ohne Zitat aus der Folge.
    @discardableResult
    public func ask(_ question: String, scope: ChatScope) async -> ChatAnswer? {
        let ticket = removalCount
        let composed = await composeAnswer(question, scope: scope)
        let removed = { (id: EpisodeID) in self.wasRemoved(id, since: ticket) }
        switch scope {
        case .episode(let id) where removed(id):
            return nil
        case .episodes(let ids) where ids.contains(where: removed):
            return nil
        default:
            break
        }
        var kept = composed
        if citesRemovedContent(composed, since: ticket) {
            kept = ChatAnswer(
                question: question, scope: scope,
                text: "Während der Suche wurde eine Folge gelöscht, auf die sich die Antwort gestützt hätte. "
                    + "Stell die Frage bitte noch einmal.",
                citations: [])
        }
        chatAnswers.insert(kept, at: 0)
        return kept
    }

    /// Zitiert die Antwort eine Folge, die seit `ticket` gelöscht wurde?
    /// Eine abbestellte Quelle zählt auch dann, wenn ihre Folge nicht in der
    /// geladenen Liste stand und deshalb kein Merkzeichen bekam.
    private func citesRemovedContent(_ answer: ChatAnswer, since ticket: Int) -> Bool {
        if answer.citations.contains(where: { wasRemoved($0.episodeID, since: ticket) }) { return true }
        guard removalCount > ticket else { return false }
        // Nur Quellen, die seit Beginn der Antwort tatsächlich abbestellt
        // wurden. Belege ohne Quellenkennung zählen nicht als gelöscht.
        return answer.citations.contains {
            !$0.sourceID.rawValue.isEmpty && (removedSourceTickets[$0.sourceID] ?? 0) > ticket
        }
    }

    private func composeAnswer(_ question: String, scope: ChatScope) async -> ChatAnswer {
        activity = "Antwort wird gesucht …"
        defer { activity = nil }
        // Seit dem Start kann das Modell bereit geworden oder das Kontingent
        // aufgebraucht sein. Die Abfrage ist billig.
        await refreshModelStatus()

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

        // Das Gerätebudget gilt immer: direkt auf dem Gerät und ebenso, wenn
        // eine Anfrage von Private Cloud Compute aufs Gerät zurückfällt.
        let device = Self.answerBudget(privateCloud: false,
                                       contextSize: Self.onDeviceContextSize,
                                       questionLength: question.count)
        let budget = answersUsePrivateCloud
            ? Self.answerBudget(privateCloud: true, contextSize: Self.onDeviceContextSize,
                                questionLength: question.count)
            : device
        let limit = budget.maximumCandidates
        let overview = Self.asksForOverview(question)
        let candidates: [Evidence]
        if overview {
            // Für „worum geht es“ zählt die ganze Folge, gleichmässig verteilt.
            // Eine Rangfolge braucht es dafür nicht. Vorn stehen so viele
            // Stellen, wie das Gerät fasst, damit auch ein Rückfall aufs
            // Gerät die ganze Folge sieht.
            let ordered = pool.sorted { ($0.range?.start.milliseconds ?? 0) < ($1.range?.start.milliseconds ?? 0) }
            candidates = Self.coverageFirst(Self.evenlySpaced(ordered, count: limit),
                                            leading: device.maximumCandidates)
        } else {
            // Einbettungen kosten je Stelle einige zehn Millisekunden. Deshalb
            // läuft die Suche nicht auf dem Hauptthread, und nur eine begrenzte
            // Auswahl aus den besten Stichworttreffern wird eingebettet.
            let embeddingLimit = Self.embeddingBudget
            candidates = await Task.detached(priority: .userInitiated) {
                PassageRanker().rank(pool, for: question, limit: limit, embeddingLimit: embeddingLimit)
            }.value
        }

        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: budget.excerptLimit, maximumCandidates: limit),
            // Ohne diese Angabe rechnete der Extraktor auf dem Gerät mit dem
            // festen Budget aus dem Paket und kürzte den Kontext unter das,
            // was hier für das Gerät bestimmt wurde.
            onDeviceBudget: device))
        do {
            let composed = try await extractor.answer(
                question: question, from: candidates,
                libraryContext: String(libraryContext.prefix(budget.libraryContextLimit)),
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
            // Ein Fehler kann heissen, dass das Kontingent aufgebraucht oder
            // das Modell nicht mehr bereit ist. Die nächste Frage soll das wissen.
            await refreshModelStatus()
            // Ohne Modell wird nichts erfunden. Dann zeigt die Antwort die
            // passendsten Stellen im Wortlaut, mit Sprung in den Originalton.
            // Beim Überblick verteilt über die ganze Folge.
            let top = overview
                ? Self.evenlySpaced(Array(candidates.prefix(device.maximumCandidates)), count: 4)
                : Array(candidates.prefix(4))
            let reason = Self.chatReason(error)
            let text = top.isEmpty
                ? "Dazu finde ich keine passende Stelle. \(reason)"
                : "Eine Antwort formulieren kann ich gerade nicht. \(reason)\n\nDiese Stellen passen am besten:\n\n"
                    + top.enumerated().map { "[\($0.offset + 1)] \(String($0.element.quotedText.prefix(220)))…" }
                        .joined(separator: "\n\n")
            var numbers: [Int: EvidenceID] = [:]
            for (offset, item) in top.enumerated() { numbers[offset + 1] = item.id }
            return ChatAnswer(question: question, scope: scope, text: text, citations: top,
                              coverageCaveat: caveat, modelLabel: nil, citationNumbers: numbers)
        }
    }

    /// Will die Frage einen Überblick über das Ganze? Es zählen nur ganze
    /// Wörter und Wendungen. „Zusammenarbeit“, „Zusammenhang“ oder „das
    /// wichtigste Argument gegen …“ fragen nach bestimmten Stellen und
    /// bekommen die passendsten, nicht eine gleichmässige Auswahl.
    static func asksForOverview(_ question: String) -> Bool {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let text = " " + words.joined(separator: " ") + " "
        if overviewPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        // „Fasse die Folge zusammen“: Verb und Partikel stehen getrennt.
        let vocabulary = Set(words)
        return !vocabulary.isDisjoint(with: ["fasse", "fass", "fasst"]) && vocabulary.contains("zusammen")
    }

    private static let overviewPhrases = [
        "worum geht", "worum gehts", "worum ging", "worum dreht", "worum handelt",
        "zusammenfassung", "zusammenfassen", "zusammengefasst",
        "überblick", "ueberblick",
        "kernaussage", "kernaussagen", "hauptaussage", "hauptaussagen", "kernpunkte", "kernthesen",
        "wichtigsten aussagen", "wichtigsten punkte", "wichtigsten themen", "wichtigsten thesen",
        "wichtigsten erkenntnisse", "wichtigste aussage", "wichtigste erkenntnis",
        "tl dr", "tldr", "summary", "summarize", "summarise", "overview",
        "main points", "key points", "key takeaways", "what is it about", "what s it about",
    ]

    /// Wie viele Stellen höchstens eine Satzeinbettung bekommen. Etwa drei
    /// Sekunden Rechenzeit, genug für eine ganze Folge von einer Stunde.
    static let embeddingBudget = 64

    /// Wie viel Kontext eine Antwort bekommt: Stellen, Zeichen je Stelle und
    /// Zeichen für den Kontext zur Folge oder zur Mediathek.
    ///
    /// Private Cloud Compute fasst viel und bekommt das Budget aus dem
    /// Paket. Auf dem Gerät teilen sich Anweisungen, Schema, Kontext, Stellen
    /// und Antwort das Fenster des Modells, auf iOS 26 und macOS 26 sind das
    /// 4.096 Token. Dort gilt das Gerätebudget aus dem Paket, in einem
    /// grösseren Fenster doppelt so viel Kontext. Gerechnet wird vorsichtig
    /// mit drei Zeichen je Token.
    ///
    /// Das Ergebnis für das Gerät geht als `onDeviceBudget` an den
    /// Extraktor. So rechnen App und Paket mit denselben Zahlen.
    static func answerBudget(privateCloud: Bool, contextSize: Int, questionLength: Int) -> ContextBudget {
        if privateCloud { return .privateCloudCompute }
        let base = ContextBudget.onDevice
        let excerpt = base.excerptLimit
        let context = contextSize <= 4_096 ? base.libraryContextLimit : base.libraryContextLimit * 2
        // Anweisungen und Schema etwa 350 Token, Rahmung etwa 100, Antwort etwa 700.
        let reserved = 1_150 + min(questionLength, 500) / 3 + context / 3
        let available = max(0, contextSize - reserved) * 3
        let candidates = min(base.maximumCandidates, max(4, available / (excerpt + 8)))
        return ContextBudget(maximumCandidates: candidates, excerptLimit: excerpt, libraryContextLimit: context)
    }

    /// Warum der Chat nicht formulieren konnte, ohne Fehlercode.
    static func chatReason(_ error: any Error) -> String {
        switch error as? ExtractorError {
        case .modelUnavailable(let reason)?: reason.message
        case .generationFailed(let detail)?, .generationRejected(let detail)?: detail
        case nil: "Das Modell hat keine Antwort geliefert."
        }
    }

    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }

    /// Ordnet eine gleichmässig verteilte, zeitlich sortierte Auswahl so um,
    /// dass schon ihre ersten `leading` Einträge die ganze Folge abdecken.
    ///
    /// Fällt eine Antwort von Private Cloud Compute aufs Gerät zurück, sieht
    /// das Gerät nur den Anfang der Liste. Stünden dort die ersten Minuten
    /// der Folge, fasste es nur diese zusammen. Vorn stehen deshalb so viele
    /// Stellen, wie das Gerät fasst, über die ganze Folge verteilt, dahinter
    /// die übrigen. Beide Teile bleiben in sich zeitlich geordnet.
    static func coverageFirst<T>(_ spread: [T], leading count: Int) -> [T] {
        guard spread.count > count, count > 0 else { return spread }
        let step = Double(spread.count) / Double(count)
        let picked = Set((0..<count).map { Int(Double($0) * step) })
        let front = spread.indices.filter { picked.contains($0) }.map { spread[$0] }
        let rest = spread.indices.filter { !picked.contains($0) }.map { spread[$0] }
        return front + rest
    }

    /// Was der Chat über eine Folge ausser dem Transkript wissen soll.
    func episodeContext(_ id: EpisodeID) async -> String {
        guard let episode = (try? await store.episodes(ids: [id]))?.first else { return "" }
        let source = sources.first { $0.id == episode.sourceID }?.title ?? ""
        // Das Knappe zuerst: auf dem Gerät wird der Kontext am Ende gekürzt,
        // und dann fallen zuerst die langen Shownotes weg.
        var lines = ["Folge: \(episode.title)", "Podcast: \(source)"]
        if let date = episode.publishedAt { lines.append("Erschienen: \(date.formatted(date: .long, time: .omitted))") }
        if let duration = episode.declaredDuration { lines.append("Länge: \(duration.shortDescription)") }
        lines.append("Gehört: \(Int(heardFraction(for: episode) * 100)) %")
        let chapters = episode.publisherChapters.isEmpty ? (chapterCache[id] ?? []) : episode.publisherChapters
        if !chapters.isEmpty {
            lines.append("Kapitel: " + chapters.map { "\($0.start.timecode) \($0.title)" }.joined(separator: "; "))
        }
        var known = facts[id] ?? []
        if known.isEmpty { known = (try? await store.facts(forEpisode: id)) ?? [] }
        if !known.isEmpty {
            lines.append("Bereits ermittelte Fakten: " + known.prefix(15).map(\.statement).joined(separator: " | "))
        }
        if let notes = ShownotesText.plain(episode.shownotesHTML ?? episode.summary) {
            lines.append("Shownotes: " + String(notes.prefix(1_500)))
        }
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

    // MARK: - Notizen an der Abspielposition

    /// Merkt einen Moment der laufenden Folge, mit optionalem Kommentar. Das
    /// Zitat kommt aus dem Transkript, wenn es eines gibt, und wird mit
    /// Folgen- und Quellentitel kopiert. So bleibt die Notiz auch nach dem
    /// Löschen der Folge lesbar.
    @discardableResult
    public func addNote(_ note: String?, at seconds: Double, in episode: Episode,
                        quote given: String? = nil) async -> Highlight? {
        guard let media = episode.streamMediaVersionID else { return nil }
        let position = MediaTime(milliseconds: Int64(max(0, seconds) * 1000))
        let range = HighlightCapture().range(around: position, limit: nil)
        var quote = given.map { String($0.prefix(700)) }
        if quote == nil, let transcript = await transcript(for: episode) {
            let text = transcript.segments
                .filter { $0.range.end.milliseconds > range.start.milliseconds
                    && $0.range.start.milliseconds < range.end.milliseconds }
                .map(\.text).joined(separator: " ")
            if !text.isEmpty { quote = String(text.prefix(700)) }
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlight = Highlight(
            evidenceID: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            capturedVia: .player, mediaVersionID: media, quote: quote, episodeID: episode.id,
            episodeTitle: episode.title,
            sourceTitle: sources.first { $0.id == episode.sourceID }?.title,
            positionMs: Int(position.milliseconds))
        highlights.insert(highlight, at: 0)
        saveHighlights()
        return highlight
    }

    /// Ein Zitat mit Herkunft, zum Kopieren oder Teilen.
    public func citation(_ text: String, at start: MediaTime, in episode: Episode) -> String {
        let source = sources.first { $0.id == episode.sourceID }?.title
        let origin = [episode.title, source, start.timecode].compactMap { $0 }.joined(separator: " · ")
        return "„\(text)“\n(\(origin))"
    }

    public func updateNote(_ id: HighlightID, text: String?) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        highlights[index].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveHighlights()
    }

    public func removeHighlight(_ id: HighlightID) {
        highlights.removeAll { $0.id == id }
        saveHighlights()
    }

    /// Spielt die Stelle einer Notiz, solange ihre Folge noch da ist.
    public func playHighlight(_ highlight: Highlight) async {
        guard let episodeID = highlight.episodeID,
              let episode = (try? await store.episodes(ids: [episodeID]))?.first else { return }
        let seconds = Double(highlight.positionMs ?? 0) / 1000
        playEpisode(episode, at: max(0, seconds - 5))
    }

    /// Notizen einer Folge, neueste zuerst.
    public func notes(for episodeID: EpisodeID) -> [Highlight] {
        highlights.filter { $0.episodeID == episodeID }
    }

    // MARK: - Fakten

    /// Ermittelt die Fakten einer Folge aus ihren Belegen und speichert sie.
    ///
    /// Die Folge wird in Abschnitten ausgewertet, und was gelingt, bleibt.
    /// Lehnt das Modell einen Abschnitt ab (Schutzregeln, Ablehnung, zu viel
    /// Text für sein Fenster), bringt ein zweiter Versuch nichts. Die App
    /// merkt sich den Abschnitt und schickt ihn auch beim nächsten Lauf nicht
    /// mehr. Scheitert ein Abschnitt aus anderem Grund, gibt es einen zweiten
    /// Versuch, danach geht es mit dem nächsten weiter. Fehlt das Modell ganz,
    /// endet der Lauf ohne zu speichern, und der nächste beginnt von vorn.
    /// Hat der Nutzer selbst gefragt (`force`), erfährt er, was gefehlt hat.
    ///
    /// `removalTicket` reicht die Erschliessung weiter, die die Fakten
    /// anstösst. So zählt auch eine Löschung, die zwischen dem Ende der
    /// Erschliessung und dem Start der Fakten kam.
    public func prepareFacts(for episode: Episode, force: Bool = false, removalTicket: Int? = nil) async {
        guard !factsInProgress.contains(episode.id) else { return }
        // Gleich vormerken, vor dem ersten `await`: sonst liefen zwei Aufrufe
        // für dieselbe Folge nebeneinander.
        factsInProgress.insert(episode.id)
        defer { factsInProgress.remove(episode.id) }
        let ticket = removalTicket ?? removalCount
        if !force, let cached = try? await store.facts(forEpisode: episode.id), !cached.isEmpty {
            facts[episode.id] = cached
            return
        }
        let evidence = ((try? await store.evidence(forEpisode: episode.id)) ?? []).filter { $0.range != nil }
        guard !evidence.isEmpty, !wasRemoved(episode.id, since: ticket) else { return }

        await refreshModelStatus()
        // Fakten laufen über das Profil `.extract`. Dafür wählt der Router nur
        // das Gerätemodell, nie Private Cloud Compute. Die hier aufgelöste
        // Stufe ist also die, die tatsächlich rechnet, und nur sie steht
        // später unter den Fakten.
        let tier: ModelTier
        switch modelStatus.resolve(.extract) {
        case .success(let resolved):
            tier = resolved
        case .failure(let reason):
            if force { lastError = "Fakten lassen sich gerade nicht ermitteln. \(reason.message)" }
            return
        }

        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chunk = Self.factChunkSize(contextSize: Self.onDeviceContextSize)
        // Lange Folgen: gleichmässig verteilte Stellen statt nur des Anfangs.
        let sample = Self.evenlySpaced(evidence, count: chunk * Self.factChunkLimit)
        let slices = stride(from: 0, to: sample.count, by: chunk).map {
            Array(sample[$0..<min($0 + chunk, sample.count)])
        }
        // Jeder Abschnitt der Folge bekommt seinen Anteil an den Fakten.
        let quota = max(3, Int((Double(Self.factLimit) / Double(max(1, slices.count))).rounded(.up)))
        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: Self.factExcerptLimit, maximumCandidates: chunk)))

        var result: [EpisodeFact] = []
        let knownRejections = Self.rejectedFactSlices
        var rejected = 0
        var failed = 0
        var reason: String?
        for slice in slices {
            let key = Self.factSliceKey(episode.id, slice)
            if knownRejections.contains(key) {
                rejected += 1
                continue
            }
            let claims: [Claim]
            do {
                claims = try await Self.extractClaims(from: slice, with: extractor, availability: modelStatus)
            } catch let error as ExtractorError {
                switch error {
                case .generationRejected:
                    Self.rememberRejectedFactSlice(key)
                    rejected += 1
                    reason = error.errorDescription
                    continue
                case .generationFailed:
                    failed += 1
                    reason = error.errorDescription
                    continue
                case .modelUnavailable:
                    await refreshModelStatus()
                    if force {
                        lastError = "Die Fakten konnten nicht ermittelt werden. \(error.errorDescription ?? "")"
                    }
                    return
                }
            } catch {
                // Abgebrochen: nichts speichern, nichts melden.
                if error is CancellationError || Task.isCancelled { return }
                failed += 1
                reason = error.localizedDescription
                continue
            }
            guard !wasRemoved(episode.id, since: ticket) else { return }
            for claim in Self.evenlySpaced(claims, count: quota) {
                guard let evidenceID = claim.evidenceIDs.first, let source = byID[evidenceID],
                      let range = source.range else { continue }
                result.append(EpisodeFact(
                    id: claim.id.rawValue, episodeID: episode.id, sourceID: source.sourceID,
                    evidenceID: evidenceID, mediaVersionID: source.mediaVersionID,
                    statement: claim.statement, range: range, modelTier: tier.label))
            }
        }
        guard !wasRemoved(episode.id, since: ticket) else { return }
        // Das Kontingent oder die Bereitschaft des Modells kann sich geändert haben.
        if failed > 0 { await refreshModelStatus() }
        if force, rejected + failed > 0 {
            lastError = Self.factGapMessage(
                rejected: rejected, failed: failed, total: slices.count, saved: !result.isEmpty, reason: reason)
        }
        guard !result.isEmpty else {
            if force, rejected + failed == 0 {
                lastError = "In dieser Folge hat das Modell keine überprüfbaren Aussagen gefunden."
            }
            return
        }
        let unique = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.range.start.milliseconds < $1.range.start.milliseconds }
        let kept = Self.evenlySpaced(unique, count: Self.factLimit)
        facts[episode.id] = kept
        do {
            try await store.save(facts: kept, forEpisode: episode.id)
        } catch {
            if force { lastError = UserFacingError.describe(error) }
        }
        // Während des Speicherns gelöscht: die Fakten gleich wieder entfernen.
        // Nur sie, ohne neues Merkzeichen. Wurde die Quelle inzwischen neu
        // abonniert, bliebe die Folge sonst für immer verborgen.
        if wasRemoved(episode.id, since: ticket) {
            facts[episode.id] = nil
            try? await store.save(facts: [], forEpisode: episode.id)
        }
    }

    /// Was der Nutzer erfährt, wenn Abschnitte einer Folge fehlen.
    private static func factGapMessage(
        rejected: Int, failed: Int, total: Int, saved: Bool, reason: String?
    ) -> String {
        let missing = rejected + failed
        var parts = [saved
            ? "Die Fakten sind unvollständig: \(missing) von \(total) Abschnitten der Folge fehlen."
            : "Aus dieser Folge liessen sich keine Fakten ermitteln: \(missing) von \(total) Abschnitten fehlen."]
        if rejected > 0 {
            parts.append("\(rejected) davon hat das Modell abgelehnt, etwa wegen seiner Schutzregeln. "
                + "Diese versucht die App nicht noch einmal.")
        }
        if failed > 0 {
            parts.append("\(failed) sind aus einem anderen Grund gescheitert. „Neu ermitteln“ versucht sie erneut.")
        }
        if let reason { parts.append(reason) }
        return parts.joined(separator: " ")
    }

    // MARK: Abgelehnte Abschnitte

    private static let rejectedFactSlicesKey = "com.podcastai.rejectedFactSlices"
    /// So viele Ablehnungen merkt sich die App höchstens. Die ältesten fallen heraus.
    private static let rejectedFactSliceLimit = 500

    /// Abschnitte, die das Gerätemodell abgelehnt hat. Nur auf diesem Gerät,
    /// ohne Eintrag in der Datenbank.
    private static var rejectedFactSlices: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: rejectedFactSlicesKey) ?? [])
    }

    private static func rememberRejectedFactSlice(_ key: String) {
        var list = UserDefaults.standard.stringArray(forKey: rejectedFactSlicesKey) ?? []
        guard !list.contains(key) else { return }
        list.append(key)
        UserDefaults.standard.set(Array(list.suffix(rejectedFactSliceLimit)), forKey: rejectedFactSlicesKey)
    }

    /// Kennung eines Abschnitts. Belege haben stabile Kennungen, erster und
    /// letzter Beleg und ihre Zahl bestimmen den Abschnitt. Die Version des
    /// Systems gehört dazu: ein neues Modell bekommt eine neue Gelegenheit.
    static func factSliceKey(_ episodeID: EpisodeID, _ slice: [Evidence]) -> String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return [
            episodeID.rawValue, slice.first?.id.rawValue ?? "", slice.last?.id.rawValue ?? "",
            String(slice.count), "\(system.majorVersion).\(system.minorVersion)",
        ].joined(separator: "|")
    }

    /// Höchstens so viele Fakten je Folge.
    static let factLimit = 40
    /// Höchstens so viele Modellaufrufe je Folge.
    static let factChunkLimit = 6
    static let factExcerptLimit = 600

    /// Wie viele Stellen in einen Aufruf des Gerätemodells passen. Fakten
    /// laufen immer auf dem Gerät, auch wenn Private Cloud Compute frei ist.
    /// Abgezogen werden Anweisungen, Schema und Antwort (zusammen etwa
    /// 1.400 Token), gerechnet mit drei Zeichen je Token.
    static func factChunkSize(contextSize: Int) -> Int {
        let perPassage = (factExcerptLimit + 8) / 3
        return min(16, max(6, (contextSize - 1_400) / perPassage))
    }

    /// Ein Aufruf mit einem zweiten Versuch, wenn die Erzeugung scheitert.
    /// Fehlt das Modell ganz oder lehnt es den Abschnitt ab
    /// (`generationRejected`), hilft kein zweiter Versuch.
    private static func extractClaims(
        from slice: [Evidence], with extractor: KnowledgeExtractor, availability: ModelStatus
    ) async throws -> [Claim] {
        do {
            return try await extractor.extractClaims(from: slice, availability: availability)
        } catch let error as ExtractorError {
            guard case .generationFailed = error else { throw error }
            return try await extractor.extractClaims(from: slice, availability: availability)
        }
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
        // Läuft die Folge gerade, geht es danach an derselben Stelle als Stream weiter.
        let isCurrent = episodePlayer.episode?.id == episode.id
        let wasPlaying = isCurrent && episodePlayer.isPlaying
        let position = episodePlayer.currentTime
        // `stop()` räumt den Schlaf-Timer ab. Der Stream soll ihn behalten.
        let sleepTimer = episodePlayer.sleepTimer
        let sleepRemaining = episodePlayer.sleepRemaining
        if isCurrent { episodePlayer.stop() }
        guard let ids = try? await store.mediaVersionIDs(forEpisode: episode.id) else { return }
        LocalMediaLocator.removeFiles(for: ids)
        try? await store.markAudioRemoved(ids)
        mediaStorageChanged += 1
        if wasPlaying {
            playEpisode(episode, at: position)
            if sleepTimer != nil, episodePlayer.episode?.id == episode.id {
                episodePlayer.restoreSleepTimer(sleepTimer, remaining: sleepRemaining)
            }
        }
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
        prepareRemoval([episode])
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
        var affected = episodes[sourceID] ?? []
        // Auch was ausserhalb der geladenen Liste spielt, wartet oder läuft.
        for episode in episodesInUse
        where episode.sourceID == sourceID && !affected.contains(where: { $0.id == episode.id }) {
            affected.append(episode)
        }
        prepareRemoval(affected)
        // Auch ohne geladene Folgen zählt die Abbestellung als neuer Stand.
        if affected.isEmpty { removalCount += 1 }
        removedSourceTickets[sourceID] = removalCount
        do {
            let report = try await store.removeSource(sourceID)
            applyRemoval(report)
            // Auch Stellen aus Folgen, die nicht mehr an der Quelle hingen.
            pruneEditions(removedEpisodes: [], removedSources: [sourceID])
            episodes[sourceID] = nil
            sources.removeAll { $0.id == sourceID }
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    /// Alles, was vor dem Löschen in der Datenbank geschehen muss, ohne
    /// Unterbrechung: Löschung vormerken, laufende Erschliessung abbrechen,
    /// die Wiedergabe ohne Hörzeit anhalten, aus den Listen nehmen.
    private func prepareRemoval(_ removed: [Episode]) {
        let ids = removed.map(\.id)
        guard !ids.isEmpty else { return }
        markRemoved(ids)
        if let playing = episodePlayer.episode, ids.contains(playing.id) { stopWithoutRecordingHeard() }
        // Erst nach dem Anhalten: `stop()` merkt sich die Stelle noch einmal.
        episodePlayer.forgetPositions(for: ids)
        for id in ids {
            removeFromUpNext(id)
            removeFromAnalysisQueue(id)
        }
    }

    /// Merkt die Löschung für laufende Arbeit vor. Arbeitet die
    /// Erschliessung gerade an einer dieser Folgen, wird sie abgebrochen.
    private func markRemoved(_ ids: [EpisodeID]) {
        removalCount += 1
        for id in ids { removalTickets[id] = removalCount }
        if let running = pipelineEpisodeID, ids.contains(running) { pipelineRun?.cancel() }
    }

    /// Wurde die Folge gelöscht, nachdem eine Arbeit mit diesem Stand begann?
    func wasRemoved(_ id: EpisodeID, since ticket: Int) -> Bool {
        guard let removedAt = removalTickets[id] else { return false }
        return removedAt > ticket
    }

    /// Hält die Folge an, ohne die zuletzt gehörte Zeit zu melden. Die Meldung
    /// käme sonst erst nach dem Löschen an und legte den Hörzustand neu an.
    private func stopWithoutRecordingHeard() {
        let onHeard = episodePlayer.onHeard
        episodePlayer.onHeard = nil
        episodePlayer.stop()
        episodePlayer.onHeard = onHeard
    }

    /// Räumt nach, wenn die Erschliessung nach dem Löschen noch geschrieben
    /// hat: Transkript, Belege, Medienfassung und die frisch geladene
    /// Audiodatei.
    ///
    /// Entfernt wird nur, was der späte Lauf geschrieben hat, und es entsteht
    /// kein Merkzeichen. Eine gelöschte Folge trägt ihres schon. Wurde ihre
    /// Quelle dagegen abbestellt und inzwischen neu abonniert, gehört die
    /// Zeile der Folge zum neuen Abo. `removeEpisode` machte sie zum
    /// Merkzeichen, und der Feed legte sie nie wieder an.
    func purgeLateWrites(of episode: Episode) async {
        if let audio = episode.audioURL,
           let report = try? await store.removeAnalysis(
               ofEpisode: episode.id, mediaVersionID: MediaVersionID(stable: audio.absoluteString)),
           !report.evidenceIDs.isEmpty {
            pruneChatAnswers(removedEpisodes: [], removedEvidence: Set(report.evidenceIDs))
            await refreshRelevantToday()
        }
        LocalMediaLocator.removeFiles(for: Self.localMediaIDs(of: [episode]))
        facts[episode.id] = nil
        stages[episode.id] = nil
        stageDetails[episode.id] = nil
        analyzedEpisodes.remove(episode.id)
        mediaStorageChanged += 1
    }

    private func applyRemoval(_ report: LibraryStore.RemovalReport) {
        LocalMediaLocator.removeFiles(for: report.mediaVersionIDs)
        for id in report.episodeIDs {
            facts[id] = nil
            stages[id] = nil
            stageDetails[id] = nil
            analyzedEpisodes.remove(id)
        }
        episodePlayer.forgetPositions(for: report.episodeIDs)
        let removedEvidence = Set(report.evidenceIDs)
        // Gemerkte Stellen bleiben als eigenes Wissen erhalten.
        pruneChatAnswers(removedEpisodes: Set(report.episodeIDs), removedEvidence: removedEvidence)
        pruneEditions(removedEpisodes: Set(report.episodeIDs))
        reindexSpotlight()
        mediaStorageChanged += 1
        Task {
            ledger = (try? await store.ledger()) ?? ledger
            await refreshRelevantToday()
        }
    }

    /// Nimmt Antworten heraus, die sich auf gelöschte Folgen stützen. Ganz,
    /// nicht nur den Beleg: ihr Text ist aus diesen Stellen formuliert und
    /// zitiert sie ohne Modell sogar wörtlich.
    private func pruneChatAnswers(removedEpisodes: Set<EpisodeID>, removedEvidence: Set<EvidenceID> = []) {
        guard !removedEpisodes.isEmpty || !removedEvidence.isEmpty else { return }
        chatAnswers.removeAll { answer in
            Self.answer(answer, touches: removedEpisodes)
                || answer.citations.contains { removedEvidence.contains($0.id) }
                || answer.citationNumbers.values.contains { removedEvidence.contains($0) }
        }
    }

    /// Stützt sich die Antwort auf eine dieser Folgen oder gilt ihr?
    private static func answer(_ answer: ChatAnswer, touches episodeIDs: Set<EpisodeID>) -> Bool {
        if answer.citations.contains(where: { episodeIDs.contains($0.episodeID) }) { return true }
        switch answer.scope {
        case .episode(let id): return episodeIDs.contains(id)
        case .episodes(let ids): return ids.contains { episodeIDs.contains($0) }
        case .smartFeed, .allAnalyzed: return false
        }
    }
}

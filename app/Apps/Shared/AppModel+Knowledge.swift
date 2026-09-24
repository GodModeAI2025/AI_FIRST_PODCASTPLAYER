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
#if os(iOS)
import UIKit
#endif
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
    /// Ebenso „Als Nächstes“, die Warteschlange der Erschließung und die
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
        TranslationCache.remove(episodes: Array(gone.keys))
        MentionCache.remove(episodes: Array(gone.keys))
        ChapterSummaryCache.remove(episodes: Array(gone.keys))
        for id in gone.keys {
            facts[id] = nil
            stages[id] = nil
            stageDetails[id] = nil
            analyzedEpisodes.remove(id)
        }
        pruneChatAnswers(removedEpisodes: Set(gone.keys))
        pruneTrails(removedEvidence: [], removedEpisodes: Set(gone.keys))
        pruneEditions(removedEpisodes: Set(gone.keys))
        mediaStorageChanged += 1
    }

    /// Folgen, mit denen dieses Gerät gerade etwas vorhat.
    private var episodesInUse: [Episode] {
        var list = upNext + analysisQueue + factsQueue
        if let analyzing { list.append(analyzing) }
        if let gatheringFacts { list.append(gatheringFacts) }
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
        if trails.contains(where: { $0.answerText != nil && ($0.referencedEpisodeIDs ?? []).contains(id) }) {
            return true
        }
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
        let wasReady = factsModelReady
        modelStatus = ModelStatusProbe.current(allowPrivateCloud: allowPrivateCloudCompute)
        guard isLoaded, factsModelReady else { return }
        // Das Modell ist bereit: was auf Fakten wartet, läuft weiter. Läuft
        // die Arbeit schon oder hat die App gerade keine Zeit dafür, tut der
        // Aufruf nichts.
        if factsTask == nil { factsWait = nil }
        startFactsWorker()
        // Eben erst bereit geworden: auch Zurückgestelltes und alles, was
        // bisher gar nicht eingereiht war, bekommt eine Gelegenheit.
        if !wasReady {
            factsDeferred.removeAll()
            factsBackfilled = false
            await queueMissingFacts()
        }
    }

    /// Wie viele Token das Gerätemodell für Anweisungen, Prompt und Antwort
    /// zusammen fasst. Unter iOS 27 und macOS 27 sind es 8.192.
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

    /// Stellt eine Frage und hängt die Antwort an den Verlauf an. Er liest
    /// sich von oben nach unten, die neueste Antwort steht unten.
    ///
    /// Eine Antwort braucht einige Sekunden. Wird in dieser Zeit eine Folge
    /// gelöscht, hat das Aufräumen in `pruneChatAnswers` die Antwort noch
    /// nicht gesehen. Deshalb wird hier beim Einfügen noch einmal geprüft.
    /// Galt die Frage einer Folge, die inzwischen gelöscht ist, kommt keine
    /// Antwort. Stützt sich die Antwort nur auf eine gelöschte Folge, steht
    /// statt ihrer ein Hinweis da, ohne Zitat aus der Folge.
    ///
    /// `position` ist die Stelle im Player beim Senden, nur bei einer Frage
    /// an die Folge, die dort gerade geladen ist. Dann kennt die Antwort
    /// die Stelle und die Passagen davor, und „Was wurde gerade gesagt?“
    /// findet sie. Wird die Frage abgebrochen, kommt keine Antwort und kein
    /// Hinweis.
    @discardableResult
    public func ask(_ question: String, scope: ChatScope, position: MediaTime? = nil) async -> ChatAnswer? {
        let number = questionTicket
        // Der Text im Entstehen geht in derselben Runde weg, in der die
        // fertige Antwort in den Verlauf kommt. So springt nichts.
        defer { if number == questionTicket { partialAnswer = "" } }
        let ticket = removalCount
        var moment: MediaTime?
        if case .episode(let id) = scope, episodePlayer.episode?.id == id { moment = position }
        guard let answered = await composeAnswer(question, scope: scope, position: moment, number: number),
              !Task.isCancelled else { return nil }
        let composed = answered.asked(at: moment)
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
                text: String(localized: """
                    Während der Suche wurde eine Folge gelöscht, auf die sich die Antwort gestützt hätte. \
                    Stell die Frage bitte noch einmal.
                    """),
                citations: [])
        }
        chatAnswers.append(kept)
        return kept
    }

    /// Nimmt eine Antwort aus dem Verlauf. Eine gesicherte Fassung unter
    /// „Gesicherte Antworten“ bleibt.
    public func removeChatAnswer(_ id: UUID) {
        chatAnswers.removeAll { $0.id == id }
    }

    /// Stellt eine Frage als eigene Aufgabe, die „Abbrechen“ anhalten kann.
    public func startQuestion(_ question: String, scope: ChatScope,
                              position: MediaTime? = nil) -> Task<ChatAnswer?, Never> {
        questionTask?.cancel()
        questionTicket += 1
        partialAnswer = ""
        let task = Task { await self.ask(question, scope: scope, position: position) }
        questionTask = task
        return task
    }

    /// Hält die laufende Frage an. Sie hinterlässt keine Antwort und keine
    /// Fehlermeldung, und ihr halber Text verschwindet sofort.
    public func cancelQuestion() {
        questionTask?.cancel()
        questionTask = nil
        questionTicket += 1
        partialAnswer = ""
    }

    /// Ein neuer Stand des Antworttexts, nur für die Frage, die noch gilt.
    func showPartialAnswer(_ text: String, number: Int) {
        guard number == questionTicket else { return }
        partialAnswer = text
    }

    /// Zitiert die Antwort eine Folge, die seit `ticket` gelöscht wurde?
    /// Eine abbestellte Quelle zählt auch dann, wenn ihre Folge nicht in der
    /// geladenen Liste stand und deshalb kein Merkzeichen bekam.
    private func citesRemovedContent(_ answer: ChatAnswer, since ticket: Int) -> Bool {
        if answer.citations.contains(where: { wasRemoved($0.episodeID, since: ticket) }) { return true }
        if answer.referencedEpisodeIDs.contains(where: { wasRemoved($0, since: ticket) }) { return true }
        guard removalCount > ticket else { return false }
        // Nur Quellen, die seit Beginn der Antwort tatsächlich abbestellt
        // wurden. Belege ohne Quellenkennung zählen nicht als gelöscht.
        return answer.citations.contains {
            !$0.sourceID.rawValue.isEmpty && (removedSourceTickets[$0.sourceID] ?? 0) > ticket
        }
    }

    private func composeAnswer(_ question: String, scope: ChatScope, position: MediaTime?,
                               number: Int) async -> ChatAnswer? {
        activity = String(localized: "Antwort wird gesucht …")
        defer { activity = nil }
        // Fragen nach Links, Terminen, Adressen oder Namen beantworten die
        // erkannten Nennungen, ohne Modell und auch ohne Apple Intelligence.
        let asked = MentionQuestion.kinds(in: question)
        if !asked.isEmpty {
            return await mentionAnswer(question, kinds: asked, scope: scope)
        }
        // Seit dem Start kann das Modell bereit geworden oder das Kontingent
        // aufgebraucht sein. Die Abfrage ist billig.
        await refreshModelStatus()

        // Das Gerätebudget gilt immer: direkt auf dem Gerät und ebenso, wenn
        // eine Anfrage von Private Cloud Compute aufs Gerät zurückfällt. Hier
        // stehen nur die Obergrenzen. Wie viele Stellen davon passen, wird
        // weiter unten in Token gezählt.
        let usesPrivateCloud = answersUsePrivateCloud
        let deviceCeiling = Self.answerCeiling(privateCloud: false, contextSize: Self.onDeviceContextSize)
        let ceiling = usesPrivateCloud
            ? Self.answerCeiling(privateCloud: true, contextSize: Self.onDeviceContextSize)
            : deviceCeiling
        // Die Nennungen stehen vorn und bekommen einen festen Anteil des
        // Gerätebudgets. Gekürzt wird am Ende, also am Überblick, auch wenn
        // eine Anfrage aufs Gerät zurückfällt.
        let mentionShare = deviceCeiling.libraryContextLimit * 2 / 5

        let pool: [Evidence]
        var libraryContext = ""
        var caveat: String?
        switch scope {
        case .episode(let id):
            pool = (try? await store.evidence(forEpisode: id)) ?? []
            libraryContext = await episodeContext(id, position: position, pool: pool)
            if pool.isEmpty {
                // Je nach Zustand: auswertbar, wartend, laufend, gescheitert
                // oder ohne Ton. Ein Verweis auf einen Knopf, den es nicht
                // gibt, hilft niemandem.
                let text = await unanalyzedEpisodeAnswer(id)
                return ChatAnswer(question: question, scope: scope, text: text, citations: [])
            }
        case .episodes(let ids):
            var all: [Evidence] = []
            for id in ids { all += (try? await store.evidence(forEpisode: id)) ?? [] }
            pool = all
        case .smartFeed, .allAnalyzed:
            pool = (try? await store.evidenceForAnalyzedEpisodes(limit: Self.evidencePoolLimit)) ?? []
            libraryContext = await libraryOverview()
            if let mentioned = await libraryMentionContext(filter: LibraryFilter(), limit: mentionShare) {
                libraryContext = mentioned + "\n" + libraryContext
            }
            let known = episodes.values.flatMap { $0 }.count
            let analyzed = analyzedEpisodes.count
            if known > analyzed {
                caveat = String(AttributedString(localized: """
                    \(analyzed) von ^[\(known) Folge](inflect: true) mit Transkript. Nur diese wurden durchsucht.
                    """).characters)
            }
        case .library(let filter):
            // Der Code grenzt ein, bevor gesucht wird. Das Modell bekommt nur
            // Stellen aus Folgen, die Podcast und Zeitraum erfüllen.
            let now = Date()
            let admitted = ((try? await store.episodes(ids: Array(analyzedEpisodes))) ?? [])
                .filter { filter.admits(sourceID: $0.sourceID, publishedAt: $0.publishedAt, now: now) }
            var all: [Evidence] = []
            for episode in admitted { all += (try? await store.evidence(forEpisode: episode.id)) ?? [] }
            // Wie bei allem Ausgewerteten nur Belege mit Zeitmarke.
            pool = all.filter { $0.range != nil }
            libraryContext = await libraryOverview(filter: filter)
            if let mentioned = await libraryMentionContext(filter: filter, limit: mentionShare) {
                libraryContext = mentioned + "\n" + libraryContext
            }
            let known = episodes.values.joined()
                .filter { filter.admits(sourceID: $0.sourceID, publishedAt: $0.publishedAt, now: now) }.count
            if admitted.isEmpty && known == 0 {
                return ChatAnswer(
                    question: question, scope: scope,
                    text: String(localized: """
                        Im gewählten Bereich gibt es keine Folge. Wähle oben einen anderen Podcast \
                        oder einen längeren Zeitraum.
                        """),
                    citations: [])
            }
            if admitted.isEmpty {
                caveat = String(localized: """
                    Im gewählten Bereich hat noch keine Folge ein Transkript. Die Antwort kennt nur die Folgenliste.
                    """)
            } else if known > admitted.count {
                caveat = String(AttributedString(localized: """
                    Im gewählten Bereich: \(admitted.count) von ^[\(known) Folge](inflect: true) mit Transkript. \
                    Nur diese wurden durchsucht.
                    """).characters)
            }
        }

        guard !pool.isEmpty || !libraryContext.isEmpty else {
            return ChatAnswer(
                question: question, scope: scope,
                text: String(localized: """
                    Dazu gibt es noch keine Folge mit Transkript. Füge einen Podcast hinzu. Die App lädt \
                    die neuesten Folgen und erstellt ihre Transkripte von selbst, danach antworte ich mit Belegen.
                    """),
                citations: [], coverageCaveat: caveat)
        }

        // Die Obergrenzen füllen, gezählt in Token an einer Probe aus dem
        // Bestand. Zählt der Tokenizer nicht, gilt die alte Schätzung.
        let sample = Self.evenlySpaced(pool, count: AnswerTokenPlan.sampleSize)
        let planner = KnowledgeExtractor()
        let device = await planner.fittedAnswerBudget(
            deviceCeiling, tier: .onDevice, question: question, sample: sample,
            libraryContext: String(libraryContext.prefix(deviceCeiling.libraryContextLimit)))
        let budget = usesPrivateCloud
            ? await planner.fittedAnswerBudget(
                ceiling, tier: .privateCloudCompute, question: question, sample: sample,
                libraryContext: String(libraryContext.prefix(ceiling.libraryContextLimit)))
            : device
        guard !Task.isCancelled else { return nil }

        let limit = budget.maximumCandidates
        let overview = Self.asksForOverview(question)
        let candidates: [Evidence]
        if let position, Self.asksAboutCurrentMoment(question) {
            // „Was wurde gerade gesagt?“ passt auf kein Stichwort. Es zählt
            // die Nähe zur Stelle im Player, und die bestimmt der Code.
            candidates = Self.nearest(pool, to: position, limit: limit)
        } else if overview {
            // Für „worum geht es“ zählt die ganze Folge, gleichmäßig verteilt.
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
        // Die Suche läuft losgelöst und hält bei „Abbrechen“ nicht an.
        guard !Task.isCancelled else { return nil }
        let status = modelStatus
        do {
            let composed = try await extractor.answer(
                question: question, from: candidates,
                libraryContext: String(libraryContext.prefix(budget.libraryContextLimit)),
                availability: status,
                onPartial: { [weak self] text in await self?.showPartialAnswer(text, number: number) })
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var cited = composed.citations.sorted { $0.key < $1.key }.compactMap { byID[$0.value] }
            if cited.isEmpty { cited = composed.claims.flatMap(\.evidenceIDs).compactMap { byID[$0] } }
            var text = composed.text
            if text.isEmpty {
                text = composed.claims.map { "• \($0.statement)" }.joined(separator: "\n")
            }
            if text.isEmpty { text = String(localized: "Dazu steht in den Transkripten nichts Belegtes.") }
            // Kommt die Antwort vom Gerät, weil die Apple-Server ausgeschöpft
            // oder ausgelastet sind, sagt eine Zeile das. Das Kontingent ist
            // meist schon vorher bekannt, dann fragt der Extraktor PCC gar nicht.
            let serverLimit = composed.privateCloudLimit
                ?? (composed.tier == .onDevice ? status.privateCloudLimit : nil)
            return ChatAnswer(
                question: question, scope: scope, text: text, citations: cited,
                coverageCaveat: caveat, modelLabel: composed.tier?.label,
                citationNumbers: composed.citations, modelNote: serverLimit?.note())
        } catch {
            // Abgebrochen: keine Antwort, kein Hinweis, kein neuer Modellzustand.
            if error is CancellationError || Task.isCancelled { return nil }
            // Ein Fehler kann heißen, dass das Kontingent aufgebraucht oder
            // das Modell nicht mehr bereit ist. Die nächste Frage soll das wissen.
            await refreshModelStatus()
            // Ohne Modell wird nichts erfunden. Dann zeigt die Antwort die
            // passendsten Stellen im Wortlaut, mit Sprung in den Originalton.
            // Beim Überblick verteilt über die ganze Folge.
            let top = overview
                ? Self.evenlySpaced(Array(candidates.prefix(device.maximumCandidates)), count: 4)
                : Array(candidates.prefix(4))
            let reason = Self.chatReason(error)
            // Der Satz ist übersetzbar, die Liste der Stellen ist Wortlaut und
            // kommt unverändert dahinter.
            let text = top.isEmpty
                ? String(localized: "Dazu finde ich keine passende Stelle. \(reason)")
                : String(localized: "Eine Antwort formulieren kann ich gerade nicht. \(reason)\n\nDiese Stellen passen am besten:")
                    + "\n\n"
                    + top.enumerated().map { "[\($0.offset + 1)] \(String($0.element.quotedText.prefix(220)))…" }
                        .joined(separator: "\n\n")
            var numbers: [Int: EvidenceID] = [:]
            for (offset, item) in top.enumerated() { numbers[offset + 1] = item.id }
            return ChatAnswer(question: question, scope: scope, text: text, citations: top,
                              coverageCaveat: caveat, modelLabel: nil, citationNumbers: numbers)
        }
    }

    /// Fragt die Frage nach der Stelle, die gerade läuft? Ganze Wörter und
    /// Wendungen wie bei ``asksForOverview(_:)``.
    static func asksAboutCurrentMoment(_ question: String) -> Bool {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let text = " " + words.joined(separator: " ") + " "
        return momentPhrases.contains { text.contains(" \($0) ") }
    }

    private static let momentPhrases = [
        "gerade", "grad", "eben", "soeben", "jetzt", "momentan", "an dieser stelle", "diese stelle",
        "hier gesagt", "just", "right now", "currently", "this part", "at this point", "just said",
    ]

    /// Die Stellen, die der Position am nächsten liegen. Was schon gelaufen
    /// ist, zählt vor dem, was erst kommt: gefragt wird nach Gehörtem.
    static func nearest(_ pool: [Evidence], to position: MediaTime, limit: Int) -> [Evidence] {
        let at = position.milliseconds
        func distance(_ evidence: Evidence) -> Int64 {
            guard let range = evidence.range else { return .max }
            if range.start.milliseconds <= at && at <= range.end.milliseconds { return 0 }
            if range.end.milliseconds < at { return at - range.end.milliseconds }
            return (range.start.milliseconds - at) * 3
        }
        return Array(pool.filter { $0.range != nil }.sorted { distance($0) < distance($1) }.prefix(limit))
    }

    /// Die Passagen bis zur Position, die jüngste zuletzt.
    static func passages(before position: MediaTime, in pool: [Evidence], count: Int) -> [Evidence] {
        let heard = pool.filter { ($0.range?.start.milliseconds ?? .max) <= position.milliseconds }
            .sorted { ($0.range?.start.milliseconds ?? 0) < ($1.range?.start.milliseconds ?? 0) }
        return Array(heard.suffix(count))
    }

    /// Will die Frage einen Überblick über das Ganze? Es zählen nur ganze
    /// Wörter und Wendungen. „Zusammenarbeit“, „Zusammenhang“ oder „das
    /// wichtigste Argument gegen …“ fragen nach bestimmten Stellen und
    /// bekommen die passendsten, nicht eine gleichmäßige Auswahl.
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

    /// Die Obergrenze für eine Antwort: Stellen, Zeichen je Stelle und
    /// Zeichen für den Kontext zur Folge oder zur Mediathek.
    ///
    /// Private Cloud Compute bekommt die Grenze aus dem Paket. Auf dem Gerät
    /// passen in ein Fenster über 4.096 Token bis zu 40 Stellen und doppelt
    /// so viel Kontext. Wie viele Stellen es wirklich werden, zählt
    /// `KnowledgeExtractor.fittedAnswerBudget` in Token, siehe
    /// `AnswerTokenPlan`. Das gezählte Budget für das Gerät geht als
    /// `onDeviceBudget` an den Extraktor. So rechnen App und Paket mit
    /// denselben Zahlen.
    static func answerCeiling(privateCloud: Bool, contextSize: Int) -> ContextBudget {
        if privateCloud { return .privateCloudCompute }
        let base = ContextBudget.onDevice
        guard contextSize > 4_096 else { return base }
        return ContextBudget(maximumCandidates: 40, excerptLimit: base.excerptLimit,
                             libraryContextLimit: base.libraryContextLimit * 2)
    }

    /// Die alte Schätzung mit drei Zeichen je Token, für die Einordnung der
    /// Gegenpositionen. Sie bleibt dort die Decke, damit keine Portion größer
    /// wird als bisher, und `fittedAnswerBudget` kürzt sie nach Token.
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
        case nil: String(localized: "Das Modell hat keine Antwort geliefert.")
        }
    }

    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }

    /// Ordnet eine gleichmäßig verteilte, zeitlich sortierte Auswahl so um,
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

    /// Was der Chat über eine Folge außer dem Transkript wissen soll.
    func episodeContext(_ id: EpisodeID, position: MediaTime? = nil, pool: [Evidence] = []) async -> String {
        guard let episode = (try? await store.episodes(ids: [id]))?.first else { return "" }
        let source = sources.first { $0.id == episode.sourceID }?.title ?? ""
        // Das Knappe zuerst: auf dem Gerät wird der Kontext am Ende gekürzt,
        // und dann fallen zuerst die langen Shownotes weg.
        var lines = ["Folge: \(episode.title)", "Podcast: \(source)"]
        if let date = episode.publishedAt { lines.append("Erschienen: \(date.formatted(date: .long, time: .omitted))") }
        if let duration = episode.declaredDuration { lines.append("Länge: \(duration.shortDescription)") }
        lines.append("Gehört: \(Int(heardFraction(for: episode) * 100)) %")
        if let position {
            // Kontext für das Modell, deshalb deutsch und nicht übersetzt.
            // Die Stelle kommt vom Player beim Senden der Frage.
            lines.append("Die Frage kam beim Hören an dieser Stelle: \(position.timecode)")
            let recent = Self.passages(before: position, in: pool, count: 2)
            if !recent.isEmpty {
                lines.append("Zuletzt gehört: " + recent.map {
                    "\($0.range?.start.timecode ?? "") \(String($0.quotedText.prefix(240)))"
                }.joined(separator: " | "))
            }
        }
        // Gleich nach dem Knappen: Kapitel und Fakten können lang werden,
        // und auf dem Gerät fiele der Block sonst beim Kürzen weg.
        if let mentioned = await mentionContext(for: episode) { lines.append(mentioned) }
        let chapters = episode.publisherChapters.isEmpty ? (chapterCache[id] ?? []) : episode.publisherChapters
        if !chapters.isEmpty {
            lines.append("Kapitel: " + chapters.map { "\($0.start.timecode) \($0.title)" }.joined(separator: "; "))
        }
        var known = facts[id] ?? []
        if known.isEmpty { known = ((try? await store.facts(forEpisode: id)) ?? []).compactMap(\.cleaned) }
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
    ///
    /// Mit Eingrenzung stehen nur der gewählte Podcast und die Folgen aus dem
    /// Zeitraum darin, sonst antwortete das Modell aus dem Überblick über
    /// alles andere.
    func libraryOverview(filter: LibraryFilter = LibraryFilter()) async -> String {
        var lines: [String] = []
        let now = Date()
        var admittedIDs: Set<EpisodeID> = []
        for source in sources where filter.sourceID == nil || filter.sourceID == source.id {
            let list = (episodes[source.id] ?? [])
                .filter { filter.admits(sourceID: source.id, publishedAt: $0.publishedAt, now: now) }
            admittedIDs.formUnion(list.map(\.id))
            lines.append("Podcast: \(source.title) (\(list.count) Folgen)")
            for episode in list.prefix(12) {
                var entry = "- \(episode.title)"
                if let date = episode.publishedAt { entry += ", \(date.formatted(date: .abbreviated, time: .omitted))" }
                // Kontext für das Modell, deshalb deutsch und nicht übersetzt.
                // Die Wörter sind die der Oberfläche, damit die Antwort sie aufgreift.
                entry += analyzedEpisodes.contains(episode.id) ? ", Transkript fertig" : ", ohne Transkript"
                let heard = Int(heardFraction(for: episode) * 100)
                if heard > 0 { entry += ", \(heard) % gehört" }
                lines.append(entry)
            }
        }
        if !profile.confirmed.isEmpty {
            lines.append("Interessen: " + profile.confirmed.map(\.label).joined(separator: ", "))
        }
        let ownNotes = filter.isUnrestricted
            ? highlights
            : highlights.filter { $0.episodeID.map(admittedIDs.contains) ?? false }
        let notes = ownNotes.compactMap(\.note).prefix(10)
        if !notes.isEmpty { lines.append("Eigene Notizen: " + notes.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    /// Wie der Bereich einer Antwort heißt, mit dem Namen des gewählten Podcasts.
    func scopeLabel(_ scope: ChatScope) -> String {
        guard case .library(let filter) = scope else { return scope.label }
        var parts: [String] = []
        if let id = filter.sourceID {
            parts.append(sources.first { $0.id == id }?.title ?? String(localized: "Ein Podcast"))
        } else {
            parts.append(String(localized: "Alle Podcasts"))
        }
        if filter.period != .all { parts.append(filter.period.label) }
        return parts.joined(separator: " · ")
    }

    /// Woher Belege stammen, je Folge: „Podcast · Folge · Datum“.
    public func citationOrigins(for evidence: [Evidence]) async -> [EpisodeID: String] {
        let ids = Array(Set(evidence.map(\.episodeID)))
        guard !ids.isEmpty, let titles = try? await store.titles(forEpisodes: ids) else { return [:] }
        return titles.mapValues { titles in
            var parts = [titles.source, titles.episode]
            if let date = titles.publishedAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Wissenslandkarten

    /// Die Belege einer Karte, die es noch gibt, in ihrer Reihenfolge.
    public func evidence(of trail: KnowledgeTrail) async -> [Evidence] {
        let found = (try? await store.evidence(ids: trail.evidenceIDs)) ?? [:]
        return trail.evidenceIDs.compactMap { found[$0] }
    }

    /// Die Notizen einer Karte, soweit sie nicht gelöscht wurden.
    public func notes(of trail: KnowledgeTrail) -> [Highlight] {
        let ids = Set(trail.highlightIDs)
        return highlights.filter { ids.contains($0.id) }
    }

    /// Spielt die Belege einer Karte nacheinander. Nur auf Tippen.
    public func playTrail(_ trail: KnowledgeTrail) {
        Task {
            let found = await evidence(of: trail)
            playAnswer(ChatAnswer(question: trail.question, scope: .allAnalyzed,
                                  text: trail.answerText ?? "", citations: found))
        }
    }

    /// Spielt die Folge eines Belegs ab der Stelle.
    public func playEvidenceInEpisode(_ evidence: Evidence, at seconds: Double) async {
        guard let episode = (try? await store.episodes(ids: [evidence.episodeID]))?.first else { return }
        playEpisode(episode, at: seconds)
    }

    // MARK: - Notizen an der Abspielposition

    /// Merkt eine Stelle einer Folge, mit optionalem Kommentar.
    ///
    /// Alle Wege zum Merken laufen hier durch: Player, Transkript, Fakten,
    /// Chat, Kurzbefehl und Fokus-Player. Zitat, Folgen- und Quellentitel
    /// und die Zeitmarke werden als Kopie gespeichert. So bleibt die Notiz
    /// auch nach dem Löschen der Folge lesbar. Ohne mitgegebenes Zitat kommt
    /// es aus dem Transkript: der Satz, der an der Stelle läuft, und die
    /// Zeitmarke rückt auf seinen Anfang (``notePassage(at:in:)``).
    /// `evidenceID` gibt, wer einen gespeicherten Beleg merkt, sonst entsteht
    /// eine Kennung aus dem Bereich.
    @discardableResult
    public func addNote(_ note: String?, at seconds: Double, in episode: Episode,
                        quote given: String? = nil, evidenceID givenEvidence: EvidenceID? = nil,
                        mediaVersionID givenMedia: MediaVersionID? = nil,
                        via route: Highlight.CaptureRoute = .player) async -> Highlight? {
        guard let media = givenMedia ?? episode.streamMediaVersionID else { return nil }
        var position = MediaTime(milliseconds: Int64(max(0, seconds) * 1000))
        var quote = given.map { String($0.prefix(700)) }
        if quote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let passage = await notePassage(at: seconds, in: episode) {
            quote = passage.text
            position = passage.start
        }
        let range = HighlightCapture().range(around: position, limit: nil)
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlight = Highlight(
            evidenceID: givenEvidence
                ?? Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            capturedVia: route, mediaVersionID: media, quote: quote, episodeID: episode.id,
            episodeTitle: episode.title,
            sourceTitle: sources.first { $0.id == episode.sourceID }?.title,
            positionMs: Int(position.milliseconds))
        highlights.insert(highlight, at: 0)
        saveHighlights()
        return highlight
    }

    /// Was „Moment merken“ an einer Position speichert: der Satz aus dem
    /// Transkript, der dort läuft, und sein Anfang als Zeitmarke.
    ///
    /// Früher kamen alle Segmente von 45 Sekunden davor bis 10 danach. Das
    /// Zitat begann dann mit dem Satz davor, und die Zeitmarke war der
    /// Moment des Tippens, der weder zum Anfang des Zitats passte noch zum
    /// gemeinten Satz. Ohne Transkript gibt es kein Zitat, und die Zeitmarke
    /// bleibt, wo getippt wurde.
    public func notePassage(at seconds: Double, in episode: Episode) async -> (start: MediaTime, text: String)? {
        guard let transcript = await transcript(for: episode) else { return nil }
        let position = MediaTime(milliseconds: Int64(max(0, seconds) * 1000))
        guard let segment = HighlightCapture().segment(at: position, in: transcript) else { return nil }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (segment.range.start, String(text.prefix(700)))
    }

    /// Merkt einen gespeicherten Beleg, etwa aus dem Chat oder zu einem
    /// Fakt. Zitat ist der Wortlaut des Belegs, die Zeitmarke sein Anfang.
    @discardableResult
    public func rememberEvidence(_ evidence: Evidence, via route: Highlight.CaptureRoute) async -> Highlight? {
        guard let range = evidence.range else { return nil }
        guard let episode = (try? await store.episodes(ids: [evidence.episodeID]))?.first else {
            lastError = String(localized: "Die Folge zu dieser Stelle ist gelöscht. Merken geht deshalb nicht mehr.")
            return nil
        }
        return await addNote(nil, at: range.start.seconds, in: episode, quote: evidence.quotedText,
                             evidenceID: evidence.id, mediaVersionID: evidence.mediaVersionID, via: route)
    }

    /// Den gespeicherten Beleg zu einer Kennung, etwa zum Wortlaut eines Fakts.
    public func evidence(_ id: EvidenceID) async -> Evidence? {
        (try? await store.evidence(ids: [id]))?[id]
    }

    /// Ein Zitat mit Herkunft, zum Kopieren oder Teilen: Folge, Podcast,
    /// Zeitmarke, Erscheinungsdatum und, wenn es sie gibt, die Seite der Folge.
    public func citation(_ text: String, at start: MediaTime, in episode: Episode) -> String {
        Citation.plainText(ExportedNote(
            quote: text, episodeTitle: episode.title,
            sourceTitle: sources.first { $0.id == episode.sourceID }?.title,
            position: start, publishedAt: episode.publishedAt, webPageURL: episode.webPageURL))
    }

    /// Was zu einem Fakt wörtlich gesagt wurde: der Satz aus seinem Beleg,
    /// an dem auch die Zeitmarke des Fakts steht. Derselbe Text, den
    /// „Wortlaut zeigen“ anzeigt (``factWording(_:passages:)``).
    ///
    /// Nicht der ganze Beleg. Der dauert ein, zwei Minuten und fängt weit
    /// vor der Zeitmarke an. Gemerkt, kopiert oder geteilt stand sonst ein
    /// Zitat da, das zu einer anderen Stelle gehört als seine Zeitmarke.
    public func factQuote(_ fact: EpisodeFact) async -> String? {
        guard let passage = await evidence(fact.evidenceID) else { return nil }
        return FactAnchor.wording(for: fact.statement, in: passage.quotedText)
    }

    /// Ein Fakt zum Kopieren oder Teilen. Wörtlich zitiert wird nur, was in
    /// der Folge gesagt wurde (``factQuote(_:)``). Die Aussage hat das
    /// Modell formuliert, sie steht deshalb als Zusammenfassung da und nie in
    /// Anführungszeichen.
    public func factCitation(_ fact: EpisodeFact, quote: String?, in episode: Episode) -> String {
        let summary = String(localized: "Zusammenfassung: \(fact.statement)")
        // Ohne Wortlaut steht nur die Herkunft da, ohne leere Anführungszeichen.
        let place = citation(quote ?? "", at: fact.range.start, in: episode)
        return "\(place)\n\n\(summary)"
    }

    /// Eine gemerkte Stelle zum Kopieren oder Teilen, als Klartext: Zitat,
    /// Folge, Podcast, Zeitmarke, Erscheinungsdatum, Link und der eigene
    /// Kommentar. Titel und Zitat kommen aus der Kopie in der Notiz, sie
    /// gelten also auch nach dem Löschen der Folge.
    public func noteCitation(_ highlight: Highlight) -> String {
        Citation.plainText(exportedNote(highlight, episode: loadedEpisode(highlight.episodeID)))
    }

    /// Eine gemerkte Stelle für Export und Zwischenablage. Erscheinungsdatum
    /// und Link kommen aus der Folge, solange es sie gibt.
    func exportedNote(_ highlight: Highlight, episode: Episode?) -> ExportedNote {
        ExportedNote(
            note: highlight.note, quote: highlight.quote,
            episodeTitle: highlight.episodeTitle ?? episode?.title,
            sourceTitle: highlight.sourceTitle ?? episode.flatMap { episode in
                sources.first { $0.id == episode.sourceID }?.title
            },
            position: highlight.positionMs.map { MediaTime(milliseconds: Int64($0)) },
            publishedAt: episode?.publishedAt, webPageURL: episode?.webPageURL,
            capturedAt: highlight.capturedAt)
    }

    /// Eine Folge, die schon geladen ist, ohne Umweg über den Speicher.
    func loadedEpisode(_ id: EpisodeID?) -> Episode? {
        guard let id else { return nil }
        for list in episodes.values {
            if let episode = list.first(where: { $0.id == id }) { return episode }
        }
        return nil
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
        // Neu melden ergänzt nur. Was gelöscht ist, muss auch aus der
        // Systemsuche verschwinden.
        Task { await spotlight.remove(id) }
    }

    /// Spielt die Stelle einer Notiz, solange ihre Folge noch da ist.
    /// Nur auf Antippen, nie von selbst. Genau ab der Zeitmarke der Notiz,
    /// denn die ist der Anfang des gemerkten Satzes und steht so auf dem Knopf.
    public func playHighlight(_ highlight: Highlight) async {
        guard let episodeID = highlight.episodeID, let ms = highlight.positionMs else { return }
        guard let episode = (try? await store.episodes(ids: [episodeID]))?.first else {
            lastError = String(localized: "Die Folge zu dieser Notiz ist gelöscht. Die Notiz selbst bleibt.")
            return
        }
        playEpisode(episode, at: max(0, Double(ms) / 1000))
    }

    /// Ältere Notizen aus Kurzbefehl und Fokus-Player kennen nur die
    /// Medienfassung. Ist deren Folge geladen, bekommen sie Folgen- und
    /// Quellentitel nachgetragen. Zitat und Zeitmarke lassen sich nicht
    /// mehr herleiten, die Notiz bleibt deshalb ohne Sprung in den Ton.
    public func fillMissingNoteTitles() {
        var changed = false
        for index in highlights.indices where highlights[index].episodeTitle == nil {
            guard let media = highlights[index].mediaVersionID,
                  let episode = episodes.values.joined().first(where: { $0.streamMediaVersionID == media })
            else { continue }
            highlights[index].episodeTitle = episode.title
            highlights[index].sourceTitle = sources.first { $0.id == episode.sourceID }?.title
            changed = true
        }
        if changed { saveHighlights() }
    }

    /// Welche Folgen dieser Notizen noch da sind. Notizen gelöschter Folgen
    /// bleiben lesbar, abspielen lassen sie sich nicht mehr.
    public func availableEpisodeIDs(for notes: [Highlight]) async -> Set<EpisodeID> {
        Set(await noteEpisodes(for: notes).keys)
    }

    /// Die Folgen dieser Notizen, soweit es sie noch gibt.
    public func noteEpisodes(for notes: [Highlight]) async -> [EpisodeID: Episode] {
        let ids = Array(Set(notes.compactMap(\.episodeID)))
        guard !ids.isEmpty else { return [:] }
        let found = (try? await store.episodes(ids: ids)) ?? []
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Notizen einer Folge, neueste zuerst.
    public func notes(for episodeID: EpisodeID) -> [Highlight] {
        highlights.filter { $0.episodeID == episodeID }
    }

    /// Gibt es an dieser Stelle schon eine Notiz? Dann trägt die Zeile im
    /// Transkript oder bei den Fakten ein Lesezeichen.
    public func hasNote(in episodeID: EpisodeID, at start: MediaTime) -> Bool {
        highlights.contains { $0.episodeID == episodeID && $0.positionMs.map(Int64.init) == start.milliseconds }
    }

    // MARK: - Fakten

    /// Ermittelt die Fakten einer Folge aus ihren Belegen und speichert sie.
    ///
    /// Die Folge wird in Abschnitten ausgewertet, und was gelingt, bleibt.
    /// Lehnt das Modell einen Abschnitt ab (Schutzregeln, Ablehnung, zu viel
    /// Text für sein Fenster), bringt ein zweiter Versuch nichts. Die App
    /// merkt sich den Abschnitt und schickt ihn auch beim nächsten Lauf nicht
    /// mehr. Scheitert ein Abschnitt aus anderem Grund, gibt es einen zweiten
    /// Versuch, danach geht es mit dem nächsten weiter. Solche Abschnitte
    /// merkt sich die App als Lücke: ein späterer Lauf holt nur sie nach und
    /// behält die Fakten, die schon da sind. Fehlt das Modell ganz, endet
    /// der Lauf ohne zu speichern, und der nächste beginnt von vorn. Hat der
    /// Nutzer selbst gefragt (`force`), rechnet der Lauf die ganze Folge neu
    /// und der Nutzer erfährt, was gefehlt hat.
    ///
    /// `removalTicket` gibt den Stand der Löschungen mit, ab dem eine
    /// Löschung zählt. Ohne Angabe gilt der Stand beim Aufruf.
    ///
    /// Das Ergebnis sagt der Warteschlange, ob sich ein späterer Versuch lohnt.
    @discardableResult
    func prepareFacts(for episode: Episode, force: Bool = false, removalTicket: Int? = nil) async -> FactsOutcome {
        guard !factsInProgress.contains(episode.id) else { return .nothingToDo }
        // Gleich vormerken, vor dem ersten `await`: sonst liefen zwei Aufrufe
        // für dieselbe Folge nebeneinander.
        factsInProgress.insert(episode.id)
        defer {
            factsInProgress.remove(episode.id)
            factsProgress[episode.id] = nil
        }
        let ticket = removalTicket ?? removalCount
        // Vorhandene Fakten gelten als fertig, außer ein früherer Lauf hat
        // Lücken hinterlassen.
        var stored: [EpisodeFact] = []
        var gaps: Set<String> = []
        // „Neu ermitteln“ rechnet alles neu, merkt sich aber die bisherigen
        // Fakten. Liefert der neue Lauf deutlich weniger, bleiben sie.
        var previous: [EpisodeFact] = []
        // Fakten mit Listenresten zählen nicht. Sind es alle, rechnet der
        // Lauf die Folge neu, und beim Speichern fallen sie weg. Eine Nummer
        // vorn oder ein Verweis am Ende fällt nur aus dem Text (`cleaned`).
        if !force {
            stored = ((try? await store.facts(forEpisode: episode.id)) ?? []).compactMap(\.cleaned)
            gaps = Self.factGaps(of: episode.id)
        } else {
            previous = ((try? await store.facts(forEpisode: episode.id)) ?? []).compactMap(\.cleaned)
        }
        if !stored.isEmpty, gaps.isEmpty {
            facts[episode.id] = await anchoredFacts(stored, episodeID: episode.id)
            return .stored
        }
        let evidence = ((try? await store.evidence(forEpisode: episode.id)) ?? []).filter { $0.range != nil }
        guard !evidence.isEmpty, !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }

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
            if force { lastError = String(localized: "Fakten lassen sich gerade nicht ermitteln. \(reason.message)") }
            return .modelUnavailable(reason)
        }

        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chunk = Self.factChunkSize(contextSize: Self.onDeviceContextSize)
        // Jedes Kapitel bekommt seinen Anteil, statt gleichmäßig verteilter
        // Stellen über die ganze Folge. Ohne Kapitel aus dem Feed gelten die
        // Abschnitte, die auch der Reiter „Kapitel“ zeigt.
        let sections = await Self.chapterSections(
            chapters: feedChapters(for: episode), duration: episode.declaredDuration, evidence: evidence)
        let plan = ChapterSections.factPlan(
            evidence: evidence, sections: sections, chunk: chunk,
            budget: ChapterSections.FactBudget(baseCalls: Self.factChunkLimit, baseLimit: Self.factLimit))
        let slices = plan.slices
        // Mit Lücken: nur die Abschnitte, die beim letzten Mal fehlten. Was
        // schon da ist, bleibt.
        var open = Set(slices.indices)
        if !stored.isEmpty {
            open = Set(slices.indices.filter { gaps.contains(Self.factSliceID(slices[$0])) })
            // Die Lücken passen nicht mehr zu den Abschnitten, etwa nach einem
            // neuen Transkript oder mit einem Modell, das mehr Text fasst. Dann
            // bleibt es bei den Fakten, die es gibt. „Neu ermitteln“ rechnet
            // die ganze Folge neu.
            guard !open.isEmpty else {
                recordFactGaps([], for: episode.id, since: ticket)
                let shown = await anchoredFacts(stored, episodeID: episode.id)
                guard !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }
                facts[episode.id] = shown
                return .stored
            }
        }
        // Jedes Kapitel der Folge bekommt seinen Anteil an den Fakten.
        let quota = plan.quota
        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: Self.factExcerptLimit, maximumCandidates: chunk)))
        // Für die Zeitmarken: das Modell wählt nur den Beleg, den Satz darin
        // findet der Code im Transkript.
        let timed = await transcript(for: episode)

        var result: [EpisodeFact] = []
        let knownRejections = Self.rejectedFactSlices
        var rejected = 0
        var failed = 0
        // Abschnitte, die ein späterer Lauf nachholt.
        var missing: Set<String> = []
        var reason: String?
        factsProgress[episode.id] = 0
        for (index, slice) in slices.enumerated() {
            // Keine Zeit mehr, etwa weil die App in den Hintergrund ging:
            // nichts speichern, die Folge bleibt vorn.
            if Task.isCancelled { return .cancelled }
            defer { factsProgress[episode.id] = Double(index + 1) / Double(slices.count) }
            let key = Self.factSliceKey(episode.id, slice)
            if knownRejections.contains(key) {
                rejected += 1
                continue
            }
            // Schon bei einem früheren Lauf gelungen.
            guard open.contains(index) else { continue }
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
                    missing.insert(Self.factSliceID(slice))
                    reason = error.errorDescription
                    continue
                case .modelUnavailable(let unavailable):
                    await refreshModelStatus()
                    if force {
                        let detail = error.errorDescription ?? ""
                        lastError = String(localized: "Die Fakten konnten nicht ermittelt werden. \(detail)")
                    }
                    return .modelUnavailable(unavailable)
                }
            } catch {
                // Abgebrochen: nichts speichern, nichts melden.
                if error is CancellationError || Task.isCancelled { return .cancelled }
                failed += 1
                missing.insert(Self.factSliceID(slice))
                reason = error.localizedDescription
                continue
            }
            guard !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }
            // Je Kapitel höchstens `quota`, damit ein Aufruf mit mehreren
            // Kapiteln nicht alles einem einzigen gibt.
            let perSection = ChapterSections.balanced(
                claims, across: sections, quota: quota, limit: claims.count
            ) { claim in
                claim.evidenceIDs.first.flatMap { byID[$0]?.range?.start } ?? .zero
            }
            for claim in perSection {
                guard let evidenceID = claim.evidenceIDs.first, let source = byID[evidenceID],
                      let range = source.range else { continue }
                let sentence = timed.flatMap { transcript in
                    transcript.mediaVersionID == source.mediaVersionID
                        ? FactAnchor.range(for: claim.statement, within: range, in: transcript.segments)
                        : nil
                }
                result.append(EpisodeFact(
                    id: claim.id.rawValue, episodeID: episode.id, sourceID: source.sourceID,
                    evidenceID: evidenceID, mediaVersionID: source.mediaVersionID,
                    // Die Kennung, nicht die Bezeichnung: die Ansicht übersetzt sie in
                    // die Sprache, in der jemand die Fakten liest.
                    statement: claim.statement, range: sentence ?? range, modelTier: tier.rawValue))
            }
        }
        guard !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }
        // Das Kontingent oder die Bereitschaft des Modells kann sich geändert haben.
        if failed > 0 { await refreshModelStatus() }
        let gap = rejected + failed > 0
            ? Self.factGapMessage(rejected: rejected, failed: failed, total: slices.count,
                                  saved: !result.isEmpty || !stored.isEmpty, reason: reason)
            : nil
        if force, let gap { lastError = gap }
        // Unvollständig: gespeichert wird, was da ist, und die Lücken holt ein
        // späterer Lauf nach.
        let outcome: FactsOutcome = missing.isEmpty ? .stored : .partial(gap)
        guard !result.isEmpty || !stored.isEmpty else {
            // Gespeichert wird nichts: bisherige Fakten bleiben stehen.
            let nothingFound = previous.isEmpty
                ? String(localized: "In dieser Folge hat das Modell keine überprüfbaren Aussagen gefunden.")
                : String(localized: "Der neue Lauf fand keine überprüfbaren Aussagen. Die bisherigen Fakten bleiben.")
            if force, gap == nil { lastError = nothingFound }
            // Ist etwas nur gescheitert, lohnt ein späterer Versuch. Hat das
            // Modell alles abgelehnt oder nichts gefunden, nicht.
            return failed > 0 ? .failed(gap) : .noFacts(gap ?? nothingFound)
        }
        // Aus den Lücken kam nichts Neues: die Fakten bleiben, wie sie sind.
        guard !result.isEmpty else {
            recordFactGaps(missing, for: episode.id, since: ticket)
            let shown = await anchoredFacts(stored, episodeID: episode.id)
            guard !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }
            facts[episode.id] = shown
            return outcome
        }
        // Deutlich weniger als vorher, etwa weil das Modell diesmal kaum
        // Brauchbares lieferte: nichts ersetzen. Die bisherigen Fakten
        // bleiben, und der Hinweis steht über „Neu ermitteln“.
        if Self.isClearlyWorse(result.count, than: previous.count) {
            let shown = await anchoredFacts(previous, episodeID: episode.id)
            guard !wasRemoved(episode.id, since: ticket) else { return .nothingToDo }
            facts[episode.id] = shown
            let found = String(AttributedString(localized: "^[\(result.count) Fakt](inflect: true)").characters)
            return .partial(String(localized: """
                Der neue Lauf fand nur \(found) statt \(previous.count). Die bisherigen Fakten bleiben.
                """))
        }
        let unique = Dictionary((stored + result).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.range.start.milliseconds < $1.range.start.milliseconds }
        // Beim Kürzen bleibt jedes Kapitel vertreten.
        let kept = ChapterSections.balanced(
            Array(unique), across: sections, quota: plan.quota, limit: plan.limit) { $0.range.start }
        facts[episode.id] = kept
        var saveFailure: String?
        do {
            try await store.save(facts: kept, forEpisode: episode.id)
        } catch {
            saveFailure = UserFacingError.describe(error)
            if force { lastError = saveFailure }
        }
        // Während des Speicherns gelöscht: die Fakten gleich wieder entfernen.
        // Nur sie, ohne neues Merkzeichen. Wurde die Quelle inzwischen neu
        // abonniert, bliebe die Folge sonst für immer verborgen.
        if wasRemoved(episode.id, since: ticket) {
            facts[episode.id] = nil
            try? await store.save(facts: [], forEpisode: episode.id)
            return .nothingToDo
        }
        // Nicht gespeichert: sichtbar sind sie jetzt, beim nächsten Start
        // fehlen sie. Die Lücken bleiben, wie sie waren.
        if let saveFailure { return .failed(saveFailure) }
        recordFactGaps(missing, for: episode.id, since: ticket)
        // Ältere Fakten zeigen auf den Anfang ihres Belegs. Für die Anzeige
        // bekommen sie ihren Satz, wie beim Laden.
        if !stored.isEmpty {
            let shown = await anchoredFacts(kept, episodeID: episode.id)
            if !wasRemoved(episode.id, since: ticket) { facts[episode.id] = shown }
        }
        return outcome
    }

    /// Wie ein Lauf von ``prepareFacts(for:force:removalTicket:)`` ausging.
    enum FactsOutcome: Equatable {
        /// Die Fakten liegen vor, frisch gespeichert oder schon vorhanden.
        case stored
        /// Nichts zu tun: keine Stellen mit Zeitmarke, die Folge ist gelöscht,
        /// oder für sie läuft schon ein Lauf.
        case nothingToDo
        /// Durchgelaufen, aber ohne Fakten: das Modell hat alles abgelehnt
        /// oder keine überprüfbare Aussage gefunden. Mit demselben Modell
        /// käme wieder dasselbe heraus.
        case noFacts(String)
        /// Gescheitert aus einem Grund, der vorbeigeht: Last,
        /// Zeitüberschreitung, Speichern.
        case failed(String?)
        /// Gespeichert, aber mit Lücken: einzelne Abschnitte sind aus einem
        /// Grund gescheitert, der vorbeigeht. Ein späterer Lauf holt nur sie nach.
        case partial(String?)
        /// Das Gerätemodell steht gerade nicht bereit.
        case modelUnavailable(ModelUnavailability)
        /// Abgebrochen, etwa weil die Hintergrundzeit endet.
        case cancelled
    }

    /// Was der Nutzer erfährt, wenn Abschnitte einer Folge fehlen.
    private static func factGapMessage(
        rejected: Int, failed: Int, total: Int, saved: Bool, reason: String?
    ) -> String {
        let missing = rejected + failed
        var parts = [saved
            ? String(localized: "Die Fakten sind unvollständig: \(missing) von \(total) Abschnitten der Folge fehlen.")
            : String(localized: "Aus dieser Folge ließen sich keine Fakten ermitteln: \(missing) von \(total) Abschnitten fehlen.")]
        if rejected > 0 {
            parts.append(String(localized: """
                \(rejected) davon hat das Modell abgelehnt, etwa wegen seiner Schutzregeln. \
                Diese versucht die App nicht noch einmal.
                """))
        }
        if failed > 0 {
            // Ohne Verb, das sich nach der Zahl richten müsste: „1 sind gescheitert“ wäre falsch.
            parts.append(String(localized: """
                Bei \(failed) davon ging aus einem anderen Grund etwas schief. Ein neuer Versuch kann sie nachholen.
                """))
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

    // MARK: Lücken

    /// Abschnitte, die beim letzten Lauf einer Folge aus einem Grund
    /// gescheitert sind, der vorbeigeht: Last, Zeitüberschreitung. Je Folge
    /// die Kennungen der Abschnitte. Nur auf diesem Gerät, ohne Eintrag in
    /// der Datenbank.
    private static let factGapsKey = "com.podcastai.factGaps"

    private static var allFactGaps: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: factGapsKey) as? [String: [String]] ?? [:]
    }

    static func factGaps(of id: EpisodeID) -> Set<String> {
        Set(allFactGaps[id.rawValue] ?? [])
    }

    /// Folgen, denen nach dem letzten Lauf Abschnitte fehlen.
    static var episodesWithFactGaps: Set<EpisodeID> {
        Set(allFactGaps.keys.map(EpisodeID.init(rawValue:)))
    }

    /// Merkt sich die Lücken einer Folge. Ohne Lücken fällt der Eintrag weg.
    static func setFactGaps(_ gaps: Set<String>, for id: EpisodeID) {
        var all = allFactGaps
        let previous = all[id.rawValue]
        all[id.rawValue] = gaps.isEmpty ? nil : gaps.sorted()
        guard all[id.rawValue] != previous else { return }
        UserDefaults.standard.set(all, forKey: factGapsKey)
    }

    /// Merkt sich die Lücken, außer die Folge wurde inzwischen gelöscht.
    /// Dann hat das Löschen den Eintrag schon entfernt.
    private func recordFactGaps(_ gaps: Set<String>, for id: EpisodeID, since ticket: Int) {
        guard !wasRemoved(id, since: ticket) else { return }
        Self.setFactGaps(gaps, for: id)
    }

    /// Kennung eines Abschnitts für die Lücken: erster und letzter Beleg und
    /// ihre Zahl. Ohne Systemversion, anders als bei den Ablehnungen: eine
    /// Lücke bleibt auch nach einem Update eine Lücke.
    static func factSliceID(_ slice: [Evidence]) -> String {
        [slice.first?.id.rawValue ?? "", slice.last?.id.rawValue ?? "", String(slice.count)]
            .joined(separator: "|")
    }

    /// Ist ein neuer Lauf deutlich schlechter als der vorige? Ja, wenn er
    /// weniger als halb so viele Fakten liefert wie vorher mindestens zwei.
    static func isClearlyWorse(_ fresh: Int, than previous: Int) -> Bool {
        previous >= 2 && fresh * 2 < previous
    }

    /// So viele Fakten behält jede Folge mindestens. Mit vielen Kapiteln
    /// wächst die Grenze, siehe ``ChapterSections/factPlan(evidence:sections:chunk:budget:)``.
    static let factLimit = 40
    /// So viele Modellaufrufe bekommt jede Folge. Mit vielen Kapiteln
    /// werden es mehr, höchstens ``ChapterSections/FactBudget/maximumCalls``.
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

    // MARK: Fakten im Hintergrund

    /// Wie lange eine Folge, deren Transkript per iCloud kam, auf ihre
    /// Fakten vom anderen Gerät wartet, bevor dieses Gerät sie selbst sammelt.
    static let factsSyncGrace: TimeInterval = 20 * 60

    /// Kann das Gerätemodell jetzt Fakten ziehen? Fakten laufen über das
    /// Profil `.extract`, und dafür wählt der Router nur das Gerät. Ein Netz
    /// braucht es deshalb nicht, und „Nur im WLAN“ gilt hier nicht.
    var factsModelReady: Bool {
        if case .success = modelStatus.resolve(.extract) { return true }
        return false
    }

    /// Lohnt es, Folgen einzureihen? Wird das Modell nur noch vorbereitet,
    /// warten sie darauf. Fehlt es ganz, etwa weil Apple Intelligence aus
    /// ist, reiht die App nichts ein und sagt im Reiter „Fakten“, warum.
    private var factsModelExpected: Bool {
        switch modelStatus.resolve(.extract) {
        case .success: true
        case .failure(let reason): reason == .modelNotReady
        }
    }

    /// Wie viele Folgen gerade Fakten bekommen oder gleich drankommen. Steht
    /// die Warteschlange, weil das Modell fehlt, zählt nur, was läuft.
    public var factsPendingCount: Int {
        (gatheringFacts == nil ? 0 : 1) + (factsWait == nil ? factsQueue.count : 0)
    }

    /// Der Platz einer Folge in der Warteschlange der Fakten, 0 ist vorn.
    public func factsQueuePosition(of id: EpisodeID) -> Int? {
        factsQueue.firstIndex { $0.id == id }
    }

    /// „Jetzt ermitteln“ und „Neu ermitteln“: die Folge kommt als Nächste
    /// dran, rechnet neu und meldet, was fehlt.
    public func requestFacts(for episode: Episode) {
        var settled = StoredEpisodeIDs(key: Self.factsSettledKey)
        settled.remove(episode.id)
        factsIssues[episode.id] = nil
        enqueueFacts(episode, requested: true)
    }

    /// Stellt eine Folge in die Warteschlange der Fakten. Angefordert kommt
    /// sie ganz nach vorn, sonst vor die älteren Folgen, hinter das
    /// Angeforderte.
    func enqueueFacts(_ episode: Episode, requested: Bool = false) {
        guard gatheringFacts?.id != episode.id, requested || factsModelExpected else { return }
        if let index = factsQueuePosition(of: episode.id) {
            guard requested else { return }
            factsQueue.remove(at: index)
        }
        if requested {
            factsRequested.insert(episode.id)
            factsDeferred.remove(episode.id)
            factsQueue.insert(episode, at: 0)
        } else {
            let date = episode.publishedAt ?? .distantPast
            let index = factsQueue.firstIndex {
                !factsRequested.contains($0.id) && ($0.publishedAt ?? .distantPast) < date
            } ?? factsQueue.count
            factsQueue.insert(episode, at: index)
        }
        startFactsWorker()
    }

    /// Reiht Folgen ein, die ein Transkript haben, aber keine Fakten, und
    /// Folgen, deren Fakten Lücken haben. Beim Start, nach einem Abgleich,
    /// nach dem Aktualisieren, wenn das Modell bereit wird und wenn die App
    /// wieder in den Vordergrund kommt. Neueste zuerst.
    ///
    /// Was ein anderes Gerät transkribiert hat, bekommt dort gleich seine
    /// Fakten, und die kommen per iCloud nach. Solche Folgen nimmt dieses
    /// Gerät erst, wenn nach `factsSyncGrace` noch immer keine da sind.
    /// Beim Start gilt das nicht: was dann fehlt, fehlt schon länger.
    func queueMissingFacts() async {
        guard automaticFacts, isLoaded, factsModelExpected,
              let withFacts = try? await store.episodeIDsWithFacts() else { return }
        let immediately = !factsBackfilled
        factsBackfilled = true
        let settled = StoredEpisodeIDs(key: Self.factsSettledKey)
        let gapped = Self.episodesWithFactGaps
        var busy = Set(factsQueue.map(\.id))
        if let gatheringFacts { busy.insert(gatheringFacts.id) }
        let now = Date()
        var missing: [EpisodeID] = []
        for id in analyzedEpisodes where !busy.contains(id) {
            guard !settled.contains(id), !factsDeferred.contains(id) else { continue }
            if withFacts.contains(id) {
                // Lücken aus einem Lauf auf diesem Gerät: ohne Wartezeit, kein
                // anderes Gerät holt sie nach.
                if gapped.contains(id) { missing.append(id) }
                continue
            }
            let since = factsMissingSince[id] ?? now
            factsMissingSince[id] = since
            if immediately || now.timeIntervalSince(since) >= Self.factsSyncGrace { missing.append(id) }
        }
        // Was inzwischen Fakten hat oder gelöscht ist, braucht keine Zeit mehr.
        factsMissingSince = factsMissingSince.filter {
            analyzedEpisodes.contains($0.key) && !withFacts.contains($0.key)
        }
        if !missing.isEmpty, let found = try? await store.episodes(ids: missing) {
            for episode in found.sorted(by: { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) })
            where automaticFacts && analyzedEpisodes.contains(episode.id) {
                enqueueFacts(episode)
            }
        }
        // Auch was schon wartete, etwa nach abgelaufener Hintergrundzeit.
        startFactsWorker()
    }

    /// „Fakten automatisch sammeln“ ist aus: was von selbst wartet, fällt
    /// heraus. Angefordertes und was gerade läuft, bleibt.
    func dropAutomaticFacts() {
        factsQueue.removeAll { !factsRequested.contains($0.id) }
    }

    /// Nimmt eine gelöschte Folge aus der Warteschlange der Fakten.
    func dropFromFactsQueue(_ id: EpisodeID) {
        factsQueue.removeAll { $0.id == id }
        factsRequested.remove(id)
        factsDeferred.remove(id)
        factsIssues[id] = nil
        factsMissingSince[id] = nil
        // Auch die gemerkten Lücken sind aus der Folge entstanden.
        Self.setFactGaps([], for: id)
    }

    /// Startet die Arbeit an den Fakten, wenn sie nicht schon läuft. Sie
    /// läuft neben den Transkripten, mit niedrigerer Priorität, und hält
    /// keines auf. Ohne Zeit dafür, also im Hintergrund ohne Zusage des
    /// Systems, wartet die Warteschlange, bis die App wieder vorn ist.
    func startFactsWorker() {
        guard factsMayRun, factsTask == nil, !factsQueue.isEmpty else { return }
        factsTask = Task(priority: .utility) { [weak self] in
            await self?.runFactsQueue()
            // Angehalten, weil die App in den Hintergrund ging. Kam sie
            // zurück, bevor die Folge aufgeräumt war, fand der Neustart noch
            // die alte Arbeit vor. Jetzt geht es weiter.
            guard Task.isCancelled, let self, self.appInForeground else { return }
            self.startFactsWorker()
        }
    }

    /// Für die Hintergrundaufgabe: fehlende Fakten suchen und die
    /// Warteschlange abarbeiten, bis sie leer ist, das Modell fehlt oder die
    /// Zeit endet. Endet die Zeit, bleibt die Folge vorn stehen und läuft
    /// beim nächsten Mal zuerst.
    public func processPendingFacts() async {
        // Die Aufgabe hat Zeit vom System. Solange sie läuft, dürfen die
        // Fakten auch im Hintergrund arbeiten.
        factsGrants += 1
        defer { releaseFactsGrant() }
        await refreshModelStatus()
        await queueMissingFacts()
        // Eine eben angehaltene Arbeit räumt vielleicht noch auf. Danach neu.
        if let stopping = factsTask, stopping.isCancelled {
            await stopping.value
            guard !Task.isCancelled else { return }
            startFactsWorker()
        }
        guard let task = factsTask else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Vorder- und Hintergrund

    /// Ist die App vorn? Auf dem iPhone und iPad heißt das: nicht im
    /// Hintergrund. Kurz inaktiv, etwa unter dem Kontrollzentrum, zählt als
    /// vorn. Auf dem Mac zählt die laufende App als vorn.
    var appInForeground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    /// Darf die Warteschlange der Fakten jetzt arbeiten? Vorn immer. Im
    /// Hintergrund nur mit Zeit vom System: in der Aufgabe
    /// `com.podcastai.analysis` oder solange Transkripte unter der
    /// fortgesetzten Verarbeitung entstehen. Der Ton im Hintergrund zählt
    /// nicht, er hält die App nur für die Wiedergabe wach.
    var factsMayRun: Bool {
        appInForeground || factsGrants > 0
    }

    /// Beobachtet, wann die App in den Hintergrund geht und wann sie wieder
    /// vorn ist. Einmal beim Start, aus `AppBootstrap.start(with:)`.
    ///
    /// Mit `addObserver` statt einer Folge von Meldungen: der Beobachter
    /// steht damit sofort, und die erste Rückkehr nach einem Start im
    /// Hintergrund geht nicht verloren.
    public func observeAppState() {
        #if os(iOS)
        guard appStateObservers.isEmpty else { return }
        let center = NotificationCenter.default
        appStateObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.returningFromBackground = true
                    self.pauseFactsWithoutTime()
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.resumeFactsInForeground() }
                }
            },
        ]
        #endif
    }

    /// Hat die App keine Zeit mehr für das Modell, hält die Fakten an. Die
    /// Folge, an der gerade gearbeitet wird, bleibt vorn in der
    /// Warteschlange und läuft weiter, sobald die App wieder vorn ist oder
    /// das System Hintergrundzeit gibt.
    func pauseFactsWithoutTime() {
        guard !factsMayRun else { return }
        factsTask?.cancel()
    }

    /// Eine Arbeit mit Hintergrundzeit ist zu Ende.
    func releaseFactsGrant() {
        factsGrants = max(0, factsGrants - 1)
        pauseFactsWithoutTime()
    }

    /// Wieder vorn: die Warteschlange läuft weiter. Kommt die App aus dem
    /// Hintergrund, kommt auch dazu, was dort gescheitert ist oder Lücken hat.
    func resumeFactsInForeground() async {
        startFactsWorker()
        guard returningFromBackground else { return }
        returningFromBackground = false
        await queueMissingFacts()
    }

    private func runFactsQueue() async {
        defer {
            factsTask = nil
            gatheringFacts = nil
        }
        // Ein zweiter Versuch je Folge und Lauf, danach erst beim nächsten Start.
        var retried: Set<EpisodeID> = []
        while !Task.isCancelled, !factsQueue.isEmpty {
            // Vor jeder Folge: das Modell kann bereit geworden oder weggefallen sein.
            await refreshModelStatus()
            if case .failure(let reason) = modelStatus.resolve(.extract) {
                factsWait = String(localized: "wartet: \(reason.message)")
                return
            }
            factsWait = nil
            // Während der Prüfung kann die Folge gelöscht worden sein.
            guard !Task.isCancelled, !factsQueue.isEmpty else { break }
            let next = factsQueue.removeFirst()
            let requested = factsRequested.remove(next.id) != nil
            gatheringFacts = next
            let outcome = await prepareFacts(for: next, force: requested)
            gatheringFacts = nil
            switch outcome {
            case .stored, .nothingToDo:
                factsIssues[next.id] = nil
                factsMissingSince[next.id] = nil
            case .noFacts(let note):
                factsIssues[next.id] = note
                var settled = StoredEpisodeIDs(key: Self.factsSettledKey)
                settled.insert(next.id)
            case .failed(let note), .partial(let note):
                factsIssues[next.id] = note ?? String(localized: "Die Fakten konnten nicht ermittelt werden.")
                // Wer selbst gefragt hat, hat den Grund gesehen und entscheidet
                // selbst. Gemerkte Lücken holt ein späterer Lauf trotzdem nach.
                guard !requested else { continue }
                // Im Hintergrund nicht zurückstellen: dort ist das Modell eher
                // ausgelastet. Ist die App wieder vorn, kommt die Folge wieder dran.
                if retried.insert(next.id).inserted {
                    factsQueue.append(next)
                } else if appInForeground {
                    factsDeferred.insert(next.id)
                } else {
                    // Ohne die Wartezeit für Fakten von anderen Geräten.
                    factsMissingSince[next.id] = .distantPast
                }
                // Meist ist das Modell ausgelastet. Etwas Luft lassen.
                await pauseBetweenFactRuns()
            case .modelUnavailable(let reason):
                factsQueue.insert(next, at: 0)
                if requested { factsRequested.insert(next.id) }
                factsWait = String(localized: "wartet: \(reason.message)")
                return
            case .cancelled:
                factsQueue.insert(next, at: 0)
                if requested { factsRequested.insert(next.id) }
                return
            }
        }
    }

    /// Eine Minute Pause nach einem Fehlschlag. Wer inzwischen selbst eine
    /// Folge anfordert, wartet nicht darauf.
    private func pauseBetweenFactRuns() async {
        for _ in 0..<12 {
            if Task.isCancelled { return }
            if let first = factsQueue.first, factsRequested.contains(first.id) { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Folgen, bei denen ein Lauf ohne Fakten endete: alles abgelehnt oder
    /// keine überprüfbare Aussage. Das Einreihen lässt sie aus, „Jetzt
    /// ermitteln“ nicht. Je Systemversion, wie die abgelehnten Abschnitte:
    /// ein neues Modell bekommt eine neue Gelegenheit. Nur auf diesem Gerät.
    static var factsSettledKey: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "factsSettled-\(system.majorVersion).\(system.minorVersion)"
    }

    public func loadFacts(for episodeID: EpisodeID) async {
        if let stored = try? await store.facts(forEpisode: episodeID) {
            let shown = await anchoredFacts(stored, episodeID: episodeID)
            facts[episodeID] = shown
            // Nur Fakten mit Listenresten aus einer älteren Version: neu
            // ermitteln, sofern das von selbst geschehen darf, und nur einmal.
            // Fand ein Lauf nichts, gilt die Folge als erledigt. Sonst steht
            // unter „Fakten“ der Knopf „Jetzt ermitteln“.
            if !stored.isEmpty, shown.isEmpty, automaticFacts, analyzedEpisodes.contains(episodeID),
               !StoredEpisodeIDs(key: Self.factsSettledKey).contains(episodeID),
               !factsDeferred.contains(episodeID),
               let episode = try? await store.episodes(ids: [episodeID]).first {
                enqueueFacts(episode)
            }
        }
    }

    /// Fakten aus älteren Läufen zeigen auf den Anfang ihres Belegs, eine
    /// Passage von ein, zwei Minuten. Für die Anzeige bekommen sie ihren
    /// Satz. Gespeichert wird dabei nichts, „Neu ermitteln“ schreibt die
    /// neuen Zeitmarken.
    ///
    /// Fakten aus Läufen vor Version 0.7, in denen mehrere Aussagen samt
    /// Nummern aneinanderhängen („… 2 | Ich habe …“), zeigt die App nicht.
    /// Steht nur vorn eine Nummer oder am Ende ein Verweis, zeigt sie den
    /// Fakt ohne sie.
    func anchoredFacts(_ list: [EpisodeFact], episodeID: EpisodeID) async -> [EpisodeFact] {
        let list = list.compactMap(\.cleaned)
        guard list.contains(where: { $0.range.duration.milliseconds >= 30_000 }),
              let transcript = try? await store.transcript(forEpisode: episodeID) else { return list }
        return FactAnchor.anchored(list, in: transcript)
    }

    /// Was in der Folge zu jedem Fakt wörtlich gesagt wurde: der passende
    /// Satz aus seinem Beleg.
    func factWording(_ list: [EpisodeFact], passages: [Evidence]) -> [String: String] {
        let byID = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for fact in list {
            guard let passage = byID[fact.evidenceID] else { continue }
            result[fact.id] = FactAnchor.wording(for: fact.statement, in: passage.quotedText)
        }
        return result
    }

    public func transcript(for episode: Episode) async -> Transcript? {
        try? await store.transcript(forEpisode: episode.id)
    }

    // MARK: - Export

    /// Die ganze Folge als Markdown: Shownotes, Kapitel, Fakten, Erwähntes, Transkript.
    public func exportEpisode(_ episode: Episode, includeTranscript: Bool = true) async -> String {
        let source = sources.first { $0.id == episode.sourceID }?.title ?? ""
        let chapters = episode.publisherChapters.isEmpty ? (chapterCache[episode.id] ?? []) : episode.publisherChapters
        var known = facts[episode.id] ?? []
        if known.isEmpty {
            known = await anchoredFacts((try? await store.facts(forEpisode: episode.id)) ?? [],
                                        episodeID: episode.id)
        }
        let passages = known.isEmpty ? [] : ((try? await store.evidence(forEpisode: episode.id)) ?? [])
        // Die eigenen Notizen in der Reihenfolge der Folge, nicht des Merkens.
        let episodeNotes = notes(for: episode.id)
            .sorted { ($0.positionMs ?? 0) < ($1.positionMs ?? 0) }
            .map { exportedNote($0, episode: episode) }
        let dossier = EpisodeDossier(
            title: episode.title, sourceTitle: source, publishedAt: episode.publishedAt,
            duration: episode.declaredDuration, webPageURL: episode.webPageURL,
            shownotes: ShownotesText.plain(episode.shownotesHTML ?? episode.summary),
            chapters: chapters, facts: known,
            transcript: includeTranscript ? await transcript(for: episode) : nil,
            factQuotes: factWording(known, passages: passages), notes: episodeNotes,
            mentions: await mentions(for: episode).mentions)
        return EpisodeDossierExporter().markdown(dossier, includeTranscript: includeTranscript)
    }

    /// Alle gemerkten Stellen als eine Markdown-Datei.
    ///
    /// Jede Stelle steht mit ihrer Kopie da: Kommentar, Zitat, Folge,
    /// Podcast und Zeitmarke. Die Quelle nennt das Erscheinungsdatum der
    /// Folge und ihre Seite, solange es die Folge gibt. Wann gemerkt wurde,
    /// steht getrennt und beschriftet. Früher stand an der Stelle der
    /// Quelle die Merkzeit, als wäre sie das Datum der Folge.
    public func exportKnowledge() async -> String {
        guard !highlights.isEmpty else { return "" }
        let episodes = await noteEpisodes(for: highlights)
        return NotesExporter().markdown(highlights.map { highlight in
            exportedNote(highlight, episode: highlight.episodeID.flatMap { episodes[$0] })
        })
    }

    /// Eine Chat-Antwort mit ihren Belegen als Markdown.
    public func exportAnswer(_ answer: ChatAnswer) async -> String {
        let titles = (try? await store.titles(forEpisodes: answer.citations.map(\.episodeID))) ?? [:]
        let numberFor = Dictionary(answer.citationNumbers.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let unknownEpisode = String(localized: "Unbekannte Folge")
        let unknownSource = String(localized: "Unbekannter Podcast")
        let citations = answer.citations.enumerated().map { offset, evidence in
            (number: numberFor[evidence.id] ?? offset + 1,
             episode: titles[evidence.episodeID]?.episode ?? unknownEpisode,
             source: titles[evidence.episodeID]?.source ?? unknownSource,
             range: evidence.range, quote: evidence.quotedText)
        }
        return EpisodeDossierExporter().markdown(ExportedAnswer(
            question: answer.question, scopeLabel: scopeLabel(answer.scope), text: answer.text,
            modelLabel: answer.modelLabel, citations: citations))
    }

    // MARK: - Entfernen

    /// Löscht nur die Audiodatei. Transkript, Fakten, Belege und Hörzustand
    /// bleiben, abspielen geht danach als Stream.
    public func removeAudio(for episode: Episode) async {
        // Spielt die Folge gerade aus der Datei, geht sie an derselben Stelle
        // als Stream weiter, laufend oder pausiert. Player, Kapitel und
        // Schlaf-Timer bleiben.
        if episodePlayer.episode?.id == episode.id { episodePlayer.switchToStream() }
        keptOffline.remove(episode.id)
        // Wer den Ton der neuesten Folge selbst entfernt, will ihn nicht beim
        // nächsten Aktualisieren wieder auf dem Gerät haben.
        prefetchDeclined.insert(episode.id)
        await deleteLocalAudio(of: episode)
        // Wartet ihr Transkript, braucht es jetzt wieder das Netz.
        queueConditionsChanged()
    }

    /// Löscht alle geladenen Audiodateien. Alle Daten bleiben.
    public func removeAllAudio() async {
        // Nur eine Folge, die aus der Datei spielt, wechselt auf den Stream.
        // Eine gestreamte läuft einfach weiter.
        episodePlayer.switchToStream()
        let removed = LocalMediaLocator.removeAllFiles()
        keptOffline.removeAll()
        prefetchedNewest.removeAll()
        prefetchedFiles.removeAll()
        // Alles weg heißt auch: die neuesten Folgen nicht gleich wieder laden.
        for list in episodes.values {
            if let newest = AudioRetention.newest(in: list) { prefetchDeclined.insert(newest.id) }
        }
        try? await store.markAudioRemoved(removed)
        mediaStorageChanged += 1
        queueConditionsChanged()
    }

    // MARK: - Audio auf dem Gerät

    /// Die geladene Audiodatei einer Folge, sofern sie auf dem Gerät liegt.
    public func localAudioFile(for episode: Episode) -> URL? {
        let locator = LocalMediaLocator()
        let ids = [episode.streamMediaVersionID].compactMap { $0 } + Self.localMediaIDs(of: [episode])
        return ids.lazy.compactMap { locator.localFile(for: $0) }.first
    }

    /// Liegt genau die Datei auf dem Gerät, die das Transkript liest? Die
    /// Erschließung nimmt die Fassung zur Audioadresse aus dem Feed. Eine
    /// Datei unter einer früheren Adresse lädt sie neu, deshalb zählt die
    /// hier nicht. Danach richten sich Warteschlange und Rückfrage.
    func hasAudioForTranscript(_ episode: Episode) -> Bool {
        guard let audioURL = episode.audioURL else { return false }
        return localMediaFileNames.contains(MediaVersionID(stable: audioURL.absoluteString).rawValue)
    }

    /// Die Namen der Audiodateien auf dem Gerät. Einmal gelesen je Stand von
    /// `mediaStorageChanged`; jedes Laden und Entfernen zählt ihn hoch.
    var localMediaFileNames: Set<String> {
        let generation = mediaStorageChanged
        if let cache = mediaFileCache, cache.generation == generation { return cache.names }
        let names = Set((try? FileManager.default.contentsOfDirectory(
            atPath: LocalMediaLocator.mediaDirectory.path)) ?? [])
        mediaFileCache = (generation, names)
        return names
    }

    /// Liegt irgendeine Fassung dieser Folge in `files`?
    private func hasFile(_ episode: Episode, in files: Set<String>) -> Bool {
        Self.localMediaIDs(of: [episode]).contains { files.contains($0.rawValue) }
    }

    /// Liegt das Audio auf dem Gerät? Liest den Speicherzähler und die Stufe
    /// mit, damit Ansichten nach Laden, Auswerten oder Entfernen neu prüfen.
    public func hasLocalAudio(_ episode: Episode) -> Bool {
        _ = mediaStorageChanged
        _ = stages[episode.id]
        return localAudioFile(for: episode) != nil
    }

    /// Lädt nur das Audio, damit die Folge auch ohne Netz spielt. Transkribiert
    /// wird dabei nichts. Von Hand angefordert, deshalb auch im Mobilfunk,
    /// außer er ist in den Einstellungen aus. Dann fragt die App vorher.
    public func downloadForOffline(_ episode: Episode) async {
        guard let audioURL = episode.audioURL else { return }
        prefetchDeclined.remove(episode.id)
        // Lädt die Folge schon, etwa als neueste ihres Podcasts: dann bleibt
        // sie ab jetzt liegen, ein zweiter Download wäre nur Wartezeit.
        if downloading.contains(episode.id) {
            keptOffline.insert(episode.id)
            mediaStorageChanged += 1
            return
        }
        // Liegt das Audio schon da, etwa für ein Transkript geladen, bleibt
        // es ab jetzt liegen. Ein zweiter Download wäre nur Wartezeit, und
        // über Mobilfunk käme nichts. Deshalb auch keine Rückfrage dazu.
        if localAudioFile(for: episode) != nil {
            keptOffline.insert(episode.id)
            mediaStorageChanged += 1
            return
        }
        if askBeforeMobileData(.download(episode)) { return }
        keptOffline.insert(episode.id)
        let ticket = removalCount
        switch await loadAudio(of: episode, from: audioURL) {
        case .loaded:
            // Während des Ladens gelöscht: die Datei gehört zu keiner Folge mehr.
            if wasRemoved(episode.id, since: ticket) {
                LocalMediaLocator.removeFiles(for: Self.localMediaIDs(of: [episode]))
                keptOffline.remove(episode.id)
            }
            mediaStorageChanged += 1
            // Ein Transkript, das aufs Netz wartete, kann jetzt laufen.
            queueConditionsChanged()
        case .cancelled:
            // Abgebrochen: keine Meldung, und nichts bleibt „für unterwegs“ vorgemerkt.
            keptOffline.remove(episode.id)
            mediaStorageChanged += 1
        case .failed(let error):
            // Hat das Auswerten dieselbe Datei gleichzeitig fertig geladen, ist sie da.
            if localAudioFile(for: episode) != nil {
                mediaStorageChanged += 1
                queueConditionsChanged()
                return
            }
            keptOffline.remove(episode.id)
            let reason = Self.downloadFailure(error)
            lastError = String(localized: "„\(episode.title)“ wurde nicht geladen: \(reason)")
        }
    }

    /// Wie ein Download für das Gerät ausging.
    enum AudioLoadOutcome {
        case loaded
        case cancelled
        case failed(any Error)
    }

    /// Lädt die Audiodatei einer Folge mit Fortschritt für „23 von 70 MB“.
    /// Als eigene Aufgabe, damit „Laden abbrechen“ genau diesen Download
    /// beendet. Eine halbe Datei bleibt nicht liegen.
    private func loadAudio(of episode: Episode, from audioURL: URL) async -> AudioLoadOutcome {
        let id = episode.id
        downloading.insert(id)
        downloadProgress[id] = DownloadProgress(received: 0, expected: nil)
        defer {
            downloading.remove(id)
            downloadProgress[id] = nil
            downloadTasks[id] = nil
        }
        let report: @Sendable (Int64, Int64?) -> Void = { [weak self] received, expected in
            Task { @MainActor in self?.noteDownloadProgress(id, received: received, expected: expected) }
        }
        let run = Task {
            // Derselbe Name wie beim Auswerten: die Wiedergabe findet die Datei.
            try await MediaDownloader(directory: LocalMediaLocator.mediaDirectory)
                .download(from: audioURL, mediaVersionID: MediaVersionID(stable: audioURL.absoluteString),
                          progress: report)
        }
        downloadTasks[id] = run
        do {
            _ = try await run.value
            return .loaded
        } catch {
            if run.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .cancelled
            }
            return .failed(error)
        }
    }

    // MARK: - Neueste Folge vorhalten

    /// Lädt die neueste Folge jedes Podcasts aufs Gerät, damit sie ohne Netz
    /// spielt. Eine nach der anderen und ohne Transkript; das entsteht wie
    /// bisher über die Warteschlange. Nur mit „Neueste Folge je Podcast
    /// behalten“ und nur, wenn das Netz das Vorbereiten erlaubt. Abgespielt
    /// wird dabei nichts.
    func prefetchNewestEpisodes() {
        guard prefetchTask == nil else { return }
        adoptMovedPrefetches()
        guard nextEpisodeToPrefetch() != nil else { return }
        prefetchTask = Task { [weak self] in
            while let self, let episode = self.nextEpisodeToPrefetch() {
                await self.prefetch(episode)
            }
            // Die bisherige neueste Folge bleibt, bis der Ton der neuen da
            // ist. Jetzt ist er da.
            await self?.tidyLocalAudio()
            self?.prefetchTask = nil
        }
    }

    /// Nur Podcasts haben eine neueste Folge, die für unterwegs bleibt.
    /// Einzelne Folgen, Dateien und YouTube-Kanäle nicht.
    func isPodcast(_ sourceID: SourceID) -> Bool {
        sources.first { $0.id == sourceID }?.kind == .podcastRSS
    }

    /// Hat ein Feed die Audioadresse einer vorgehaltenen Folge geändert,
    /// etwa mit einem neuen Zeitstempel bei jedem Abruf, zieht die Datei zur
    /// neuen Fassung um. Sonst sähe die Folge ohne Ton aus, die App lüde sie
    /// noch einmal, und die alte Datei gehörte zu keiner Folge mehr.
    func adoptMovedPrefetches() {
        guard !prefetchedFiles.isEmpty else { return }
        let directory = LocalMediaLocator.mediaDirectory
        let manager = FileManager.default
        var moved = false
        for episode in episodes.values.joined() {
            guard let old = prefetchedFiles[episode.id.rawValue] else { continue }
            // Mit Transkript zeigt die gespeicherte Fassung auf die Datei.
            guard prefetchedNewest.contains(episode.id), let audioURL = episode.audioURL else {
                prefetchedFiles[episode.id.rawValue] = nil
                continue
            }
            let current = MediaVersionID(stable: audioURL.absoluteString).rawValue
            guard old != current else { continue }
            let source = directory.appendingPathComponent(old)
            if manager.fileExists(atPath: source.path) {
                let target = directory.appendingPathComponent(current)
                if manager.fileExists(atPath: target.path) {
                    try? manager.removeItem(at: source)
                } else {
                    try? manager.moveItem(at: source, to: target)
                }
                moved = true
            }
            prefetchedFiles[episode.id.rawValue] = current
        }
        if moved { mediaStorageChanged += 1 }
    }

    /// Kommt diese Folge als neueste ihres Podcasts von selbst aufs Gerät?
    /// Für die Zeile „Audio nicht auf dem Gerät“ in der Folge.
    public func awaitsPrefetch(_ episode: Episode) -> Bool {
        _ = mediaStorageChanged
        _ = downloading
        guard keepNewestAudio, episode.audioURL != nil, isPodcast(episode.sourceID),
              AudioRetention.newest(in: episodes[episode.sourceID] ?? [])?.id == episode.id,
              !prefetchDeclined.contains(episode.id), !prefetchFailed.contains(episode.id),
              !isHeard(episode) else { return false }
        return localAudioFile(for: episode) == nil
    }

    /// Die nächste neueste Folge, die auf das Gerät gehört und noch fehlt.
    /// Was in der Warteschlange steht, lädt dort ohnehin für sein Transkript.
    private func nextEpisodeToPrefetch() -> Episode? {
        guard keepNewestAudio, preparationWait == nil else { return nil }
        var busy = Set(analysisQueue.map(\.id)).union(downloading)
        if let analyzing { busy.insert(analyzing.id) }
        for source in sources where source.kind == .podcastRSS {
            guard let episode = AudioRetention.newest(in: episodes[source.id] ?? []),
                  !busy.contains(episode.id), !prefetchFailed.contains(episode.id),
                  !prefetchDeclined.contains(episode.id), !isHeard(episode),
                  localAudioFile(for: episode) == nil else { continue }
            return episode
        }
        return nil
    }

    private func prefetch(_ episode: Episode) async {
        guard let audioURL = episode.audioURL else { return }
        // Vor dem Laden vermerkt: das Aufräumen weiß so, warum die Datei da ist.
        prefetchedNewest.insert(episode.id)
        prefetchedFiles[episode.id.rawValue] = MediaVersionID(stable: audioURL.absoluteString).rawValue
        let ticket = removalCount
        let outcome = await loadAudio(of: episode, from: audioURL)
        let loaded = localAudioFile(for: episode) != nil
        switch outcome {
        case .loaded:
            if wasRemoved(episode.id, since: ticket) {
                LocalMediaLocator.removeFiles(for: Self.localMediaIDs(of: [episode]))
                prefetchedNewest.remove(episode.id)
                prefetchedFiles[episode.id.rawValue] = nil
                keptOffline.remove(episode.id)
            }
        case .cancelled:
            // „Laden abbrechen“: die App holt diese Folge nicht von selbst wieder.
            prefetchDeclined.insert(episode.id)
            if !loaded {
                prefetchedNewest.remove(episode.id)
                prefetchedFiles[episode.id.rawValue] = nil
                keptOffline.remove(episode.id)
            }
        case .failed(let error):
            // Bis das Netz wieder von selbst laden darf, siehe `networkChanged`.
            prefetchFailed.insert(episode.id)
            if !loaded {
                prefetchedNewest.remove(episode.id)
                prefetchedFiles[episode.id.rawValue] = nil
                // Hat jemand währenddessen „Laden (offline)“ gewählt, erfährt
                // er, warum nichts kam. Sonst bleibt es still.
                if keptOffline.contains(episode.id) {
                    keptOffline.remove(episode.id)
                    lastError = String(localized: "„\(episode.title)“ wurde nicht geladen: \(Self.downloadFailure(error))")
                }
            }
        }
        mediaStorageChanged += 1
        queueConditionsChanged()
    }

    /// Nach dem Auswerten bleibt nur der Text, wenn so eingestellt. Was für
    /// unterwegs geladen ist und die neueste Folge bleiben liegen. Liegt die
    /// Folge gerade im Player, räumt `tidyLocalAudio()` sie später auf.
    func removeAudioAfterAnalysisIfWanted(_ episode: Episode) async {
        guard episodePlayer.episode?.id != episode.id,
              audioVerdict(for: episode, newest: newestEpisodeIDs(files: localMediaFileNames)) == .remove,
              !sharesAudioWithKeptEpisode(episode) else { return }
        await deleteLocalAudio(of: episode)
    }

    /// Ein von selbst eingereihtes Transkript ist gescheitert. Den Ton hatte
    /// die App nur dafür geladen; er geht wieder, außer jemand hat ihn selbst
    /// geladen oder es ist die neueste Folge. Sonst sammelten sich mit
    /// „Ältere Folgen auch vorbereiten“ Dateien an, die nie ein Transkript
    /// bekommen.
    func removeAudioAfterFailedPreparation(_ episode: Episode) async {
        guard localAudioFile(for: episode) != nil else { return }
        let verdict = audioVerdict(for: episode, newest: newestEpisodeIDs(files: localMediaFileNames))
        guard episodePlayer.episode?.id != episode.id, verdict != .keptByUser, verdict != .newest,
              !sharesAudioWithKeptEpisode(episode) else { return }
        await deleteLocalAudio(of: episode)
    }

    /// Wie lange eine gehörte Folge noch auf dem Gerät bleibt.
    static let heardAudioRetention: TimeInterval = 24 * 60 * 60

    /// Entfernt Audiodateien, die nach den Einstellungen nicht mehr auf das
    /// Gerät gehören: nach dem Transkript, einen Tag nach dem Hören und die
    /// vorgehaltene Folge, sobald der Ton einer neueren da ist. Was im
    /// Player liegt, gerade lädt oder ausgewertet wird, bleibt. Die Regel
    /// steht in `AudioRetention`.
    ///
    /// Was jemand mit „Laden (offline)“ geholt hat, bleibt immer, auch wenn
    /// er die Folge schon vor Tagen gehört hat. Wer eine gehörte Folge für
    /// den Flug noch einmal lädt, will sie dort hören. Solche Dateien
    /// entfernt nur „Audio entfernen“.
    public func tidyLocalAudio() async {
        let files = Set((try? FileManager.default.contentsOfDirectory(
            atPath: LocalMediaLocator.mediaDirectory.path)) ?? [])
        guard !files.isEmpty else { return }
        var busy = Set(analysisQueue.map(\.id)).union(downloading)
        if let analyzing { busy.insert(analyzing.id) }
        if let playing = episodePlayer.episode { busy.insert(playing.id) }
        let newest = newestEpisodeIDs(files: files)
        // Erst urteilen, dann löschen. Teilen sich zwei Folgen eine Datei,
        // entscheidet die, die sie behalten soll.
        var removable: [Episode] = []
        var kept: Set<MediaVersionID> = []
        for episode in episodes.values.joined() {
            let ids = Self.localMediaIDs(of: [episode])
            guard ids.contains(where: { files.contains($0.rawValue) }) else { continue }
            if !busy.contains(episode.id), audioVerdict(for: episode, newest: newest) == .remove {
                removable.append(episode)
            } else {
                kept.formUnion(ids)
            }
        }
        for episode in removable where !Self.localMediaIDs(of: [episode]).contains(where: kept.contains) {
            await deleteLocalAudio(of: episode)
        }
    }

    /// Was mit der Audiodatei einer Folge geschieht, nach den Einstellungen.
    /// Für die Zeile unter „Audio liegt auf diesem Gerät“ und das Menü.
    public func audioVerdict(for episode: Episode) -> AudioRetention.Verdict {
        // Nach Laden, Entfernen oder einem neuen Transkript neu lesen.
        _ = mediaStorageChanged
        _ = stages[episode.id]
        let newest = keptAsNewest(in: episode.sourceID, files: localMediaFileNames)
        return audioVerdict(for: episode, newest: Set(newest))
    }

    private func audioVerdict(for episode: Episode, newest: Set<EpisodeID>) -> AudioRetention.Verdict {
        AudioRetention.verdict(
            for: AudioRetention.Facts(
                keptByUser: keptOffline.contains(episode.id),
                isNewest: newest.contains(episode.id),
                hasTranscript: analyzedEpisodes.contains(episode.id),
                heardLongAgo: wasHeardLongAgo(episode),
                prefetched: prefetchedNewest.contains(episode.id)),
            rules: AudioRetention.Rules(
                removeAfterTranscript: removeAudioAfterAnalysis, removeHeard: removeHeardAudio,
                keepNewest: keepNewestAudio))
    }

    /// Die Folgen jedes Podcasts, die als neueste ihren Ton behalten.
    /// `files`: die Namen der Audiodateien auf dem Gerät.
    private func newestEpisodeIDs(files: Set<String>) -> Set<EpisodeID> {
        Set(sources.flatMap { keptAsNewest(in: $0.id, files: files) })
    }

    /// Die neueste Folge eines Podcasts und, solange ihr Ton noch kommt, die
    /// bisherige. Die Regel steht in `AudioRetention.keptAsNewest`.
    private func keptAsNewest(in sourceID: SourceID, files: Set<String>) -> [EpisodeID] {
        guard isPodcast(sourceID) else { return [] }
        return AudioRetention.keptAsNewest(
            in: episodes[sourceID] ?? [],
            hasFile: { hasFile($0, in: files) },
            // Holt die App den Ton noch von selbst? Nicht nach „Laden
            // abbrechen“ oder „Audio entfernen“ und nicht, wenn die Folge
            // schon gehört ist.
            isComing: { keepNewestAudio && !prefetchDeclined.contains($0.id) && !isHeard($0) })
    }

    /// Liegt dieselbe Datei auch unter einer Folge, die ihren Ton behalten
    /// soll? Selten, etwa bei zwei Einträgen mit derselben Audioadresse.
    private func sharesAudioWithKeptEpisode(_ episode: Episode) -> Bool {
        let ids = Set(Self.localMediaIDs(of: [episode]))
        let newest = newestEpisodeIDs(files: localMediaFileNames)
        return episodes.values.joined().contains { other in
            other.id != episode.id && Self.localMediaIDs(of: [other]).contains(where: ids.contains)
                && (episodePlayer.episode?.id == other.id || audioVerdict(for: other, newest: newest) != .remove)
        }
    }

    /// Zu Ende gehört: fast ganz, oder hier bis zum Schluss abgespielt.
    func isHeard(_ episode: Episode) -> Bool {
        // Hier zu Ende gehört steht die gemerkte Stelle auf 0.
        heardFraction(for: episode) >= 0.9 || episodePlayer.savedPosition(for: episode.id) == 0
    }

    /// Zu Ende gehört, und das letzte Hören liegt länger als einen Tag zurück.
    private func wasHeardLongAgo(_ episode: Episode) -> Bool {
        guard let id = episode.streamMediaVersionID,
              let last = ledger.state(for: id).lastEventAt,
              Date().timeIntervalSince(last) >= Self.heardAudioRetention else { return false }
        return isHeard(episode)
    }

    /// Löscht die Audiodatei einer Folge und vermerkt das. Der Player bleibt
    /// unberührt; das regeln die Aufrufer.
    private func deleteLocalAudio(of episode: Episode) async {
        var ids = Set(Self.localMediaIDs(of: [episode]))
        if let stored = try? await store.mediaVersionIDs(forEpisode: episode.id) { ids.formUnion(stored) }
        if let prefetched = prefetchedFiles[episode.id.rawValue] { ids.insert(MediaVersionID(rawValue: prefetched)) }
        let list = Array(ids)
        LocalMediaLocator.removeFiles(for: list)
        prefetchedNewest.remove(episode.id)
        prefetchedFiles[episode.id.rawValue] = nil
        try? await store.markAudioRemoved(list)
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
        // Auch was außerhalb der geladenen Liste spielt, wartet oder läuft.
        for episode in episodesInUse
        where episode.sourceID == sourceID && !affected.contains(where: { $0.id == episode.id }) {
            affected.append(episode)
        }
        prepareRemoval(affected)
        // Auch ohne geladene Folgen zählt die Abbestellung als neuer Stand.
        if affected.isEmpty { removalCount += 1 }
        removedSourceTickets[sourceID] = removalCount
        // Ein neues Abo desselben Podcasts beginnt wieder mit den neuesten Folgen.
        backCatalog.remove(sourceID)
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
    /// Unterbrechung: Löschung vormerken, laufende Erschließung abbrechen,
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
            // Nicht `removeFromAnalysisQueue`: das merkt sich ein „Entfernen“
            // des Nutzers, und ein neues Abo bereitete nie wieder etwas vor.
            dropFromAnalysisQueue(id)
            dropFromFactsQueue(id)
            // Die Datei geht mit der Folge. Bliebe der Vermerk, hielte das
            // Aufräumen sie nach einem neuen Abo für ausdrücklich geladen.
            keptOffline.remove(id)
            prefetchedNewest.remove(id)
            prefetchedFiles[id.rawValue] = nil
            prefetchDeclined.remove(id)
        }
    }

    /// Merkt die Löschung für laufende Arbeit vor. Arbeitet die
    /// Erschließung gerade an einer dieser Folgen, wird sie abgebrochen.
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

    /// Räumt nach, wenn die Erschließung nach dem Löschen noch geschrieben
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
            pruneTrails(removedEvidence: Set(report.evidenceIDs), removedEpisodes: [episode.id])
            await refreshRelevantToday()
        }
        LocalMediaLocator.removeFiles(for: Self.localMediaIDs(of: [episode]))
        MentionCache.remove(episodes: [episode.id])
        ChapterSummaryCache.remove(episodes: [episode.id])
        facts[episode.id] = nil
        stages[episode.id] = nil
        stageDetails[episode.id] = nil
        analyzedEpisodes.remove(episode.id)
        mediaStorageChanged += 1
    }

    private func applyRemoval(_ report: LibraryStore.RemovalReport) {
        LocalMediaLocator.removeFiles(for: report.mediaVersionIDs)
        // Übersetzte Transkripte, erkannte Nennungen und die Sätze je Kapitel
        // sind aus der Folge entstanden und gehen mit.
        TranslationCache.remove(episodes: report.episodeIDs)
        MentionCache.remove(episodes: report.episodeIDs)
        ChapterSummaryCache.remove(episodes: report.episodeIDs)
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
        pruneTrails(removedEvidence: removedEvidence, removedEpisodes: Set(report.episodeIDs))
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
        if answer.referencedEpisodeIDs.contains(where: { episodeIDs.contains($0) }) { return true }
        switch answer.scope {
        case .episode(let id): return episodeIDs.contains(id)
        case .episodes(let ids): return ids.contains { episodeIDs.contains($0) }
        case .smartFeed, .allAnalyzed, .library: return false
        }
    }
}

/// Eine gemerkte Liste von Folgen in den Benutzereinstellungen, etwa was
/// jemand aus der Warteschlange genommen oder für unterwegs geladen hat.
typealias StoredEpisodeIDs = StoredIDs<EpisodeSubject>

/// Eine gemerkte Liste von Kennungen in den Benutzereinstellungen, etwa
/// Folgen oder Podcasts. Nur auf diesem Gerät. Die ältesten Einträge fallen
/// ab einer Grenze weg.
struct StoredIDs<Subject> {
    let key: String
    let limit: Int
    private var ids: [TypedID<Subject>]
    /// Dieselben Kennungen zum Nachsehen. Das Vorbereiten fragt für jede
    /// Folge eines Archivs, ob sie hier steht.
    private var lookup: Set<TypedID<Subject>>

    init(key: String, limit: Int = 500) {
        self.key = key
        self.limit = limit
        ids = (UserDefaults.standard.stringArray(forKey: key) ?? []).map(TypedID<Subject>.init(rawValue:))
        lookup = Set(ids)
    }

    func contains(_ id: TypedID<Subject>) -> Bool { lookup.contains(id) }

    mutating func insert(_ id: TypedID<Subject>) {
        ids.removeAll { $0 == id }
        ids.append(id)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        lookup = Set(ids)
        save()
    }

    /// Mehrere auf einmal, mit einem Schreiben statt einem je Kennung.
    mutating func insert(contentsOf new: some Sequence<TypedID<Subject>>) {
        let added = new.filter { !lookup.contains($0) }
        guard !added.isEmpty else { return }
        ids.append(contentsOf: added)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        lookup = Set(ids)
        save()
    }

    mutating func remove(_ id: TypedID<Subject>) {
        guard lookup.contains(id) else { return }
        ids.removeAll { $0 == id }
        lookup.remove(id)
        save()
    }

    mutating func removeAll() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        lookup.removeAll()
        save()
    }

    mutating func removeAll(where shouldRemove: (TypedID<Subject>) -> Bool) {
        let kept = ids.filter { !shouldRemove($0) }
        guard kept.count != ids.count else { return }
        ids = kept
        lookup = Set(ids)
        save()
    }

    private func save() { UserDefaults.standard.set(ids.map(\.rawValue), forKey: key) }
}

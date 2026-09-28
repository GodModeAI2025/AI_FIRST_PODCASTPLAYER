//
//  KnowledgeJobs.swift
//  PodcastAIKit
//
//  Die Arbeit der Stufe „Wissen“ an einer Folge: Fakten sammeln und die
//  Kapitel einordnen (docs/plan-pipeline.md, Schritt 3b). Bis 0.13 lag der
//  Code als `prepareFacts` und `prepareChapterTags` im `AppModel` und lief
//  auf dem Hauptakteur. Jetzt läuft er abseits, und was die Oberfläche
//  zeigt (Fakten, Fortschritt, Fehlermeldung, nachgeladene Kapitel), geht
//  über einen Melder an die Senke.
//
//  Warteschlange, Reihenfolge und Tor führt die Stufe „Wissen“
//  (`KnowledgeStage`). Hier steht nur, wie eine Folge ausgewertet wird.
//
//  Regeln wie bis 0.13:
//  - Fakten entstehen in Abschnitten je Kapitel. Was gelingt, bleibt.
//    Lehnt das Modell einen Abschnitt ab, merkt sich das Gerät ihn und
//    schickt ihn nicht wieder. Scheitert er aus anderem Grund, gibt es
//    einen zweiten Versuch, danach gilt er als Lücke, die ein späterer Lauf
//    nachholt.
//  - Das Modell wählt nur Belege und Kennungen aus. Zeitmarken und den
//    Satz im Transkript findet der Code (Regel 3).
//  - Jedes Schreiben geht durch den Wächter im Store. Wird die Folge
//    gelöscht, bleibt nichts von ihr zurück, auch kein Vermerk auf diesem
//    Gerät (Regel 5).
//
//  Neu (Entscheidung 7): Verweist der Feed nur auf eine Kapiteldatei, lädt
//  die Arbeit sie vor Fakten und Tags, nach den Netzregeln fürs Vorbereiten.
//  Sonst schnitte der Code eigene Abschnitte, und der Reiter „Kapitel“
//  zeigte später andere Grenzen als die Fakten.
//

import Foundation
import Synchronization
import PodcastAICore
import PodcastAISources
import PodcastAIIntelligence
import PodcastAIKnowledge
import PodcastAIPersistence

/// Was die Arbeit an einer Folge der Oberfläche meldet. Die Senke auf dem
/// Hauptakteur setzt es um. Fakten einer Folge, die inzwischen gelöscht
/// ist, zeigt sie nicht mehr: geprüft wird dort, wo auch gelöscht wird.
public protocol KnowledgeReporting: Sendable {
    /// Die Fakten einer Folge entstehen gerade (`factsInProgress`).
    func factsStarted(_ id: EpisodeID) async
    /// Wie weit sie sind, von 0 bis 1.
    func factsProgress(_ id: EpisodeID, fraction: Double) async
    func factsFinished(_ id: EpisodeID) async
    /// Die Fakten, die die Folge zeigt. `nil` nimmt sie aus der Anzeige.
    /// Nicht mehr, wenn die Folge seit `ticket` gelöscht wurde.
    func showFacts(_ facts: [EpisodeFact]?, for id: EpisodeID,
                   unlessRemovedSince ticket: RemovalLedger.Ticket) async
    /// Ein Satz für den Dialog, nur bei „Jetzt ermitteln“.
    func reportError(_ message: String) async
    /// Kapitel aus der Kapiteldatei, eben geladen.
    func chaptersLoaded(_ chapters: [Chapter], for id: EpisodeID,
                        unlessRemovedSince ticket: RemovalLedger.Ticket) async
}

public struct KnowledgeJobs: KnowledgeWorking {

    /// Was die Arbeit beim Hauptakteur und in der App fragt.
    public struct Environment: Sendable {
        /// Fragt das System nach den Modellen und schreibt den Stand dorthin,
        /// wo die Oberfläche ihn liest.
        public var refreshModel: @Sendable () async -> ModelStatus
        /// Darf die App gerade von selbst ins Netz? Dieselbe Regel wie fürs
        /// Vorbereiten: Datensparmodus immer, Mobilfunk mit „Nur im WLAN“.
        public var networkAllowsPreparation: @Sendable () async -> Bool
        /// Darf die Einordnung weiterarbeiten? Das Tor, je Kapitel gefragt.
        public var tagsMayContinue: @Sendable () -> Bool
        /// Kapitel, die die App in dieser Sitzung schon kennt, etwa aus der
        /// geöffneten Folge.
        public var cachedChapters: @Sendable (EpisodeID) async -> [Chapter]?
        /// Lädt eine Kapiteldatei, mit den Grenzen der App für fremde Adressen.
        public var loadChapterFile: @Sendable (URL) async -> [Chapter]?
        /// Ein Fehler als Satz für den Dialog.
        public var describeError: @Sendable (any Error) -> String

        public init(
            refreshModel: @escaping @Sendable () async -> ModelStatus,
            networkAllowsPreparation: @escaping @Sendable () async -> Bool,
            tagsMayContinue: @escaping @Sendable () -> Bool,
            cachedChapters: @escaping @Sendable (EpisodeID) async -> [Chapter]?,
            loadChapterFile: @escaping @Sendable (URL) async -> [Chapter]?,
            describeError: @escaping @Sendable (any Error) -> String
        ) {
            self.refreshModel = refreshModel
            self.networkAllowsPreparation = networkAllowsPreparation
            self.tagsMayContinue = tagsMayContinue
            self.cachedChapters = cachedChapters
            self.loadChapterFile = loadChapterFile
            self.describeError = describeError
        }
    }

    /// So viele Fakten behält jede Folge mindestens. Mit vielen Kapiteln
    /// wächst die Grenze, siehe ``ChapterSections/factPlan(evidence:sections:chunk:budget:)``.
    public static let factLimit = 40
    /// So viele Modellaufrufe bekommt jede Folge. Mit vielen Kapiteln
    /// werden es mehr, höchstens ``ChapterSections/FactBudget/maximumCalls``.
    public static let factChunkLimit = 6
    public static let factExcerptLimit = 600
    /// So viele Zeichen je Beleg sieht das Modell bei den Tags.
    public static let tagExcerptLimit = 500

    private let store: LibraryStore
    private let ledger: RemovalLedger
    private let marks: DeviceState
    private let scheduler: any AIScheduling
    private let reporter: any KnowledgeReporting
    private let environment: Environment
    private let running: Running

    public init(
        store: LibraryStore, ledger: RemovalLedger = .shared, marks: DeviceState = .shared,
        scheduler: any AIScheduling = AIScheduler.shared, reporter: any KnowledgeReporting,
        environment: Environment
    ) {
        self.store = store
        self.ledger = ledger
        self.marks = marks
        self.scheduler = scheduler
        self.reporter = reporter
        self.environment = environment
        running = Running()
    }

    /// Dieselbe Arbeit für einen anderen Speicher.
    public func with(store: LibraryStore) -> KnowledgeJobs {
        KnowledgeJobs(store: store, ledger: ledger, marks: marks, scheduler: scheduler,
                      reporter: reporter, environment: environment)
    }

    /// Folgen, an denen gerade gearbeitet wird. Zwei Aufrufe für dieselbe
    /// Folge liefen sonst nebeneinander.
    private final class Running: Sendable {
        private let ids = Mutex<Set<String>>([])
        func claim(_ key: String) -> Bool { ids.withLock { $0.insert(key).inserted } }
        func release(_ key: String) { ids.withLock { _ = $0.remove(key) } }
    }

    // MARK: - Fakten

    /// Ermittelt die Fakten einer Folge aus ihren Belegen und speichert sie.
    ///
    /// Vorhandene Fakten gelten als fertig, außer ein früherer Lauf hat
    /// Lücken hinterlassen. Fehlt das Modell ganz, endet der Lauf ohne zu
    /// speichern, und der nächste beginnt von vorn. Hat jemand selbst gefragt
    /// (`force`), rechnet der Lauf die ganze Folge neu und meldet, was fehlte.
    ///
    /// Das Ergebnis sagt der Warteschlange, ob sich ein späterer Versuch lohnt.
    public func gatherFacts(for episode: Episode, force: Bool, origin: Origin,
                            since ticket: RemovalLedger.Ticket) async -> FactsOutcome {
        let key = "facts|\(episode.id.rawValue)"
        guard running.claim(key) else { return .nothingToDo }
        await reporter.factsStarted(episode.id)
        let outcome = await factsRun(episode, force: force, origin: origin, ticket: ticket)
        await reporter.factsFinished(episode.id)
        running.release(key)
        return outcome
    }

    private func factsRun(_ episode: Episode, force: Bool, origin: Origin,
                          ticket: RemovalLedger.Ticket) async -> FactsOutcome {
        let id = episode.id
        // Vorhandene Fakten gelten als fertig, außer ein früherer Lauf hat
        // Lücken hinterlassen. „Neu ermitteln“ rechnet alles neu, merkt sich
        // aber die bisherigen Fakten: Liefert der neue Lauf deutlich weniger,
        // bleiben sie. Fakten mit Listenresten zählen nicht; beim Speichern
        // fallen sie weg.
        var stored: [EpisodeFact] = []
        var gaps: Set<String> = []
        var previous: [EpisodeFact] = []
        if !force {
            stored = await Self.cleaned((try? await store.facts(forEpisode: id)) ?? [])
            gaps = KnowledgeMarks.factGaps(of: id, in: marks)
        } else {
            previous = await Self.cleaned((try? await store.facts(forEpisode: id)) ?? [])
        }
        if !stored.isEmpty, gaps.isEmpty {
            await reporter.showFacts(await Self.anchored(stored, episodeID: id, store: store),
                                     for: id, unlessRemovedSince: ticket)
            return .stored
        }
        let evidence = ((try? await store.evidence(forEpisode: id)) ?? []).filter { $0.range != nil }
        guard !evidence.isEmpty, !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }

        // Fakten laufen über das Profil `.extract`: Private Cloud Compute,
        // ohne PCC das Gerät. Scheitert PCC bei einem Abschnitt, rechnet das
        // Gerät ihn; unter den Fakten steht die Stufe, die ihn gerechnet hat.
        var status = await environment.refreshModel()
        let tier: ModelTier
        switch status.resolve(.extract) {
        case .success(let resolved):
            tier = resolved
        case .failure(let reason):
            if force {
                await reporter.reportError(String(
                    localized: "Fakten lassen sich gerade nicht ermitteln. \(reason.message)", bundle: .module))
            }
            return .modelUnavailable(reason)
        }

        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chunk = Self.factChunkSize(contextSize: ModelAvailabilityMonitor.onDeviceContextSize)
        // Jedes Kapitel bekommt seinen Anteil, statt gleichmäßig verteilter
        // Stellen über die ganze Folge. Ohne Kapitel aus dem Feed gelten die
        // Abschnitte, die auch der Reiter „Kapitel“ zeigt.
        let sections = await Self.sections(
            chapters: chapters(for: episode, ticket: ticket), duration: episode.declaredDuration, evidence: evidence)
        let plan = ChapterSections.factPlan(
            evidence: evidence, sections: sections, chunk: chunk,
            budget: ChapterSections.FactBudget(baseCalls: Self.factChunkLimit, baseLimit: Self.factLimit))
        var slices = plan.slices
        // Mit Lücken: nur die Abschnitte, die beim letzten Mal fehlten. Was
        // schon da ist, bleibt.
        var open = Set(slices.indices)
        if !stored.isEmpty {
            // Über die Zeitspanne der Lücke, nicht über die Kennung des
            // Aufrufs: Seit dem letzten Lauf können Kapitel aus dem Feed
            // dazugekommen sein, dann liegen die Aufrufe anders.
            let reopened = ChapterSections.reopened(slices, gaps: KnowledgeMarks.factGapSpans(gaps, in: byID))
            for (index, part) in reopened { slices[index] = part }
            open = Set(reopened.keys)
            // Die Lücken passen nicht mehr zu den Belegen, etwa nach einem
            // neuen Transkript. Dann bleibt es bei den Fakten, die es gibt.
            // „Neu ermitteln“ rechnet die ganze Folge neu.
            guard !open.isEmpty else {
                recordGaps([], for: id, since: ticket)
                let shown = await Self.anchored(stored, episodeID: id, store: store)
                guard !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }
                await reporter.showFacts(shown, for: id, unlessRemovedSince: ticket)
                return .stored
            }
        }
        // Jedes Kapitel der Folge bekommt seinen Anteil an den Fakten.
        let quota = plan.quota
        let extractor = KnowledgeExtractor(
            configuration: ExtractorConfiguration(
                candidateBuilder: CandidateListBuilder(excerptLimit: Self.factExcerptLimit, maximumCandidates: chunk)),
            // „Jetzt ermitteln“ hat jemand angetippt, das geht vor Arbeit im Hintergrund.
            priority: AIPriorityPolicy.priority(kind: .facts, origin: force ? .user : origin, force: force),
            scheduler: scheduler)
        // Für die Zeitmarken: Das Modell wählt nur den Beleg, den Satz darin
        // findet der Code im Transkript.
        let timed = try? await store.transcript(forEpisode: id)

        var result: [EpisodeFact] = []
        let knownRejections = KnowledgeMarks.rejectedFactSlices(in: marks)
        var rejected = 0
        var failed = 0
        // Abschnitte, die ein späterer Lauf nachholt.
        var missing: Set<String> = []
        var reason: String?
        let replacing = force && !previous.isEmpty
        await reporter.factsProgress(id, fraction: 0)
        for (index, slice) in slices.enumerated() {
            // Keine Zeit mehr, etwa weil die App in den Hintergrund ging:
            // sichern, was fertig ist, die Folge bleibt vorn.
            if Task.isCancelled {
                return await keepFinished(
                    result, stored: stored, of: episode, unfinished: Set(slices[index...].indices.filter(open.contains)),
                    slices: slices, missing: missing, replacing: replacing, ticket: ticket)
            }
            let sliceKey = KnowledgeMarks.factSliceKey(id, slice)
            if knownRejections.contains(sliceKey) {
                rejected += 1
                await reporter.factsProgress(id, fraction: Double(index + 1) / Double(slices.count))
                continue
            }
            // Schon bei einem früheren Lauf gelungen.
            guard open.contains(index) else {
                await reporter.factsProgress(id, fraction: Double(index + 1) / Double(slices.count))
                continue
            }
            let claims: [Claim]
            let sliceTier: ModelTier
            do {
                let availability = status
                let extracted = try await ProcessingTrace.interval("Fakten: Abschnitt") {
                    try await Self.extractClaims(from: slice, with: extractor, availability: availability)
                }
                claims = extracted.claims
                sliceTier = extracted.tier ?? tier
            } catch let error as ExtractorError {
                await reporter.factsProgress(id, fraction: Double(index + 1) / Double(slices.count))
                switch error {
                case .generationRejected:
                    // Ein Vermerk nur für eine Folge, die es noch gibt: Die
                    // Pflege hat die Ablehnungen einer gelöschten schon geräumt.
                    if !ledger.wasRemoved(id, since: ticket) {
                        KnowledgeMarks.rememberRejectedFactSlice(sliceKey, in: marks)
                    }
                    rejected += 1
                    reason = error.errorDescription
                    continue
                case .generationFailed:
                    failed += 1
                    missing.insert(KnowledgeMarks.factSliceID(slice))
                    reason = error.errorDescription
                    continue
                case .modelUnavailable(let unavailable):
                    status = await environment.refreshModel()
                    if force {
                        let detail = error.errorDescription ?? ""
                        await reporter.reportError(String(
                            localized: "Die Fakten konnten nicht ermittelt werden. \(detail)", bundle: .module))
                    }
                    // Mitten in der Folge weggefallen, meist das Netz für Private
                    // Cloud Compute: sichern, was fertig ist. Der nächste Lauf holt
                    // nur die offenen Abschnitte nach, statt das Kontingent für die
                    // ganze Folge noch einmal zu verbrauchen.
                    _ = await keepFinished(
                        result, stored: stored, of: episode,
                        unfinished: Set(slices[index...].indices.filter(open.contains)),
                        slices: slices, missing: missing, replacing: replacing, ticket: ticket)
                    return .modelUnavailable(unavailable)
                }
            } catch {
                // Abgebrochen: sichern, was fertig ist, nichts melden.
                if error is CancellationError || Task.isCancelled {
                    return await keepFinished(
                        result, stored: stored, of: episode,
                        unfinished: Set(slices[index...].indices.filter(open.contains)),
                        slices: slices, missing: missing, replacing: replacing, ticket: ticket)
                }
                await reporter.factsProgress(id, fraction: Double(index + 1) / Double(slices.count))
                failed += 1
                missing.insert(KnowledgeMarks.factSliceID(slice))
                reason = error.localizedDescription
                continue
            }
            guard !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }
            // Die Sätze im Transkript sucht der Code abseits, mit niedriger Priorität.
            result += await Task.detached(priority: .utility) {
                ProcessingTrace.measure("Fakten verankern") {
                    Self.placeFacts(claims, episodeID: id, byID: byID, sections: sections,
                                    quota: quota, transcript: timed, tier: sliceTier)
                }
            }.value
            await reporter.factsProgress(id, fraction: Double(index + 1) / Double(slices.count))
        }
        guard !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }
        // Das Kontingent oder die Bereitschaft des Modells kann sich geändert haben.
        if failed > 0 { status = await environment.refreshModel() }
        let gap = rejected + failed > 0
            ? Self.gapMessage(rejected: rejected, failed: failed, total: slices.count,
                              saved: !result.isEmpty || !stored.isEmpty, reason: reason)
            : nil
        if force, let gap { await reporter.reportError(gap) }
        // Unvollständig: Gespeichert wird, was da ist, und die Lücken holt
        // ein späterer Lauf nach.
        let outcome: FactsOutcome = missing.isEmpty ? .stored : .partial(gap)
        guard !result.isEmpty || !stored.isEmpty else {
            // Gespeichert wird nichts: Bisherige Fakten bleiben stehen.
            let nothingFound = previous.isEmpty
                ? String(localized: "In dieser Folge hat das Modell keine überprüfbaren Aussagen gefunden.",
                         bundle: .module)
                : String(localized: "Der neue Lauf fand keine überprüfbaren Aussagen. Die bisherigen Fakten bleiben.",
                         bundle: .module)
            if force, gap == nil { await reporter.reportError(nothingFound) }
            // Ist etwas nur gescheitert, lohnt ein späterer Versuch. Hat das
            // Modell alles abgelehnt oder nichts gefunden, nicht.
            return failed > 0 ? .failed(gap) : .noFacts(gap ?? nothingFound)
        }
        // Aus den Lücken kam nichts Neues: Die Fakten bleiben, wie sie sind.
        guard !result.isEmpty else {
            recordGaps(missing, for: id, since: ticket)
            let shown = await Self.anchored(stored, episodeID: id, store: store)
            guard !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }
            await reporter.showFacts(shown, for: id, unlessRemovedSince: ticket)
            return outcome
        }
        // Deutlich weniger als vorher, etwa weil das Modell diesmal kaum
        // Brauchbares lieferte: nichts ersetzen. Die bisherigen Fakten
        // bleiben, und der Hinweis steht über „Neu ermitteln“.
        if Self.isClearlyWorse(result.count, than: previous.count) {
            let shown = await Self.anchored(previous, episodeID: id, store: store)
            guard !ledger.wasRemoved(id, since: ticket) else { return .nothingToDo }
            await reporter.showFacts(shown, for: id, unlessRemovedSince: ticket)
            let found = String(AttributedString(
                localized: "^[\(result.count) Fakt](inflect: true)", bundle: .module).characters)
            return .partial(String(localized: """
                Der neue Lauf fand nur \(found) statt \(previous.count). Die bisherigen Fakten bleiben.
                """, bundle: .module))
        }
        let unique = Dictionary((stored + result).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.range.start.milliseconds < $1.range.start.milliseconds }
        // Beim Kürzen bleibt jedes Kapitel vertreten.
        let kept = ChapterSections.balanced(
            Array(unique), across: sections, quota: plan.quota, limit: plan.limit) { $0.range.start }
        var saveFailure: String?
        var receipt: WriteReceipt?
        do {
            switch try await store.commit(facts: kept, under: commitGuard(for: episode, since: ticket)) {
            case .written(let written, _):
                receipt = written
            case .stale(let reason):
                // Der Wächter im Store hat widersprochen: Die Folge ist weg,
                // oder ihre Belege sind nicht mehr die, aus denen die Fakten
                // entstanden. Ersetzt wurde nichts, also bleibt die Anzeige,
                // wie sie war, außer die Folge ist weg.
                if reason.meansRemoved { await reporter.showFacts(nil, for: id, unlessRemovedSince: ticket) }
                return .nothingToDo
            }
        } catch {
            saveFailure = environment.describeError(error)
            if force, let saveFailure { await reporter.reportError(saveFailure) }
        }
        // Gleich nach dem Speichern gelöscht: genau diese Fakten wieder
        // entfernen, ohne neues Merkzeichen. Wurde die Quelle inzwischen neu
        // abonniert, bliebe die Folge sonst für immer verborgen.
        if ledger.wasRemoved(id, since: ticket) {
            await reporter.showFacts(nil, for: id, unlessRemovedSince: ticket)
            if let receipt { _ = try? await store.removeWrites(receipt) }
            return .nothingToDo
        }
        // Ältere Fakten zeigen auf den Anfang ihres Belegs. Für die Anzeige
        // bekommen sie ihren Satz, wie beim Laden. Nicht gespeichert: sichtbar
        // sind sie jetzt, beim nächsten Start fehlen sie.
        let shown = stored.isEmpty ? kept : await Self.anchored(kept, episodeID: id, store: store)
        await reporter.showFacts(shown, for: id, unlessRemovedSince: ticket)
        // Nicht gespeichert: Die Lücken bleiben, wie sie waren.
        if let saveFailure { return .failed(saveFailure) }
        recordGaps(missing, for: id, since: ticket)
        return outcome
    }

    /// Ein Lauf wird abgebrochen, etwa weil die Zeit im Hintergrund endet.
    /// Die fertigen Abschnitte bleiben gespeichert, die übrigen merkt sich
    /// das Gerät als Lücken. Der nächste Lauf rechnet dann nur noch sie.
    ///
    /// Nicht bei „Neu ermitteln“ über vorhandene Fakten (`replacing`): Ein
    /// halber neuer Lauf ersetzte sonst die ganzen alten Fakten.
    private func keepFinished(
        _ result: [EpisodeFact], stored: [EpisodeFact], of episode: Episode, unfinished: Set<Int>,
        slices: [[Evidence]], missing: Set<String>, replacing: Bool, ticket: RemovalLedger.Ticket
    ) async -> FactsOutcome {
        let id = episode.id
        guard !result.isEmpty, !replacing, !ledger.wasRemoved(id, since: ticket) else { return .cancelled }
        let unique = Dictionary((stored + result).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.range.start.milliseconds < $1.range.start.milliseconds }
        let kept = Self.evenlySpaced(Array(unique), count: Self.factLimit)
        let receipt: WriteReceipt
        do {
            // Widerspricht der Wächter im Store, bleibt alles, wie es war.
            guard let written = try await store.commit(
                facts: kept, under: commitGuard(for: episode, since: ticket)).receipt else { return .cancelled }
            receipt = written
        } catch {
            return .cancelled
        }
        if ledger.wasRemoved(id, since: ticket) {
            _ = try? await store.removeWrites(receipt)
            return .cancelled
        }
        // Ältere Fakten bekommen für die Anzeige ihren Satz, wie beim Laden.
        let shown = stored.isEmpty ? kept : await Self.anchored(kept, episodeID: id, store: store)
        guard !ledger.wasRemoved(id, since: ticket) else { return .cancelled }
        await reporter.showFacts(shown, for: id, unlessRemovedSince: ticket)
        recordGaps(missing.union(unfinished.map { KnowledgeMarks.factSliceID(slices[$0]) }), for: id, since: ticket)
        return .cancelled
    }

    /// Merkt sich die Lücken, außer die Folge wurde inzwischen gelöscht.
    /// Dann hat das Löschen den Eintrag schon entfernt.
    private func recordGaps(_ gaps: Set<String>, for id: EpisodeID, since ticket: RemovalLedger.Ticket) {
        guard !ledger.wasRemoved(id, since: ticket) else { return }
        KnowledgeMarks.setFactGaps(gaps, for: id, in: marks)
    }

    /// Was der Nutzer erfährt, wenn Abschnitte einer Folge fehlen.
    static func gapMessage(rejected: Int, failed: Int, total: Int, saved: Bool, reason: String?) -> String {
        let missing = rejected + failed
        var parts = [saved
            ? String(localized: "Die Fakten sind unvollständig: \(missing) von \(total) Abschnitten der Folge fehlen.",
                     bundle: .module)
            : String(localized: "Aus dieser Folge ließen sich keine Fakten ermitteln: \(missing) von \(total) Abschnitten fehlen.",
                     bundle: .module)]
        if rejected > 0 {
            parts.append(String(localized: """
                \(rejected) davon hat das Modell abgelehnt, etwa wegen seiner Schutzregeln. \
                Diese versucht die App nicht noch einmal.
                """, bundle: .module))
        }
        if failed > 0 {
            // Ohne Verb, das sich nach der Zahl richten müsste: „1 sind gescheitert“ wäre falsch.
            parts.append(String(localized: """
                Bei \(failed) davon ging aus einem anderen Grund etwas schief. Ein neuer Versuch kann sie nachholen.
                """, bundle: .module))
        }
        if let reason { parts.append(reason) }
        return parts.joined(separator: " ")
    }

    /// Macht aus den Aussagen eines Abschnitts Fakten mit Zeitmarke.
    ///
    /// Je Kapitel höchstens `quota`, damit ein Aufruf mit mehreren Kapiteln
    /// nicht alles einem einzigen gibt. Aussagen ohne bekannten Beleg fallen
    /// vorher heraus, sonst zählten sie beim ersten Kapitel mit und
    /// verdrängten dort echte. Das Modell wählt nur den Beleg, den Satz
    /// darin findet der Code im Transkript.
    public static func placeFacts(
        _ claims: [Claim], episodeID: EpisodeID, byID: [EvidenceID: Evidence], sections: [ChapterSection],
        quota: Int, transcript timed: Transcript?, tier: ModelTier
    ) -> [EpisodeFact] {
        let placed = claims.filter { $0.evidenceIDs.first.flatMap { byID[$0]?.range } != nil }
        let perSection = ChapterSections.balanced(
            placed, across: sections, quota: quota, limit: placed.count
        ) { claim in
            claim.evidenceIDs.first.flatMap { byID[$0]?.range?.start } ?? .zero
        }
        var result: [EpisodeFact] = []
        for claim in perSection {
            guard let evidenceID = claim.evidenceIDs.first, let source = byID[evidenceID],
                  let range = source.range else { continue }
            let sentence = timed.flatMap { transcript in
                transcript.mediaVersionID == source.mediaVersionID
                    ? FactAnchor.range(for: claim.statement, within: range, in: transcript.segments)
                    : nil
            }
            result.append(EpisodeFact(
                id: claim.id.rawValue, episodeID: episodeID, sourceID: source.sourceID,
                evidenceID: evidenceID, mediaVersionID: source.mediaVersionID,
                // Die Kennung, nicht die Bezeichnung: Die Ansicht übersetzt sie in
                // die Sprache, in der jemand die Fakten liest.
                statement: claim.statement, range: sentence ?? range, modelTier: tier.rawValue))
        }
        return result
    }

    /// Ist ein neuer Lauf deutlich schlechter als der vorige? Ja, wenn er
    /// weniger als halb so viele Fakten liefert wie vorher mindestens zwei.
    public static func isClearlyWorse(_ fresh: Int, than previous: Int) -> Bool {
        previous >= 2 && fresh * 2 < previous
    }

    /// Wie viele Stellen in einen Aufruf des Gerätemodells passen. Fakten
    /// laufen immer auf dem Gerät, auch wenn Private Cloud Compute frei ist.
    /// Abgezogen werden Anweisungen, Schema und Antwort (zusammen etwa
    /// 1.400 Token), gerechnet mit drei Zeichen je Token.
    public static func factChunkSize(contextSize: Int) -> Int {
        let perPassage = (factExcerptLimit + 8) / 3
        return min(16, max(6, (contextSize - 1_400) / perPassage))
    }

    /// Ein Aufruf mit einem zweiten Versuch, wenn die Erzeugung scheitert.
    /// Fehlt das Modell ganz oder lehnt es den Abschnitt ab
    /// (`generationRejected`), hilft kein zweiter Versuch.
    private static func extractClaims(
        from slice: [Evidence], with extractor: KnowledgeExtractor, availability: ModelStatus
    ) async throws -> (claims: [Claim], tier: ModelTier?) {
        do {
            return try await extractor.extractClaimsWithTier(from: slice, availability: availability)
        } catch let error as ExtractorError {
            guard case .generationFailed = error else { throw error }
            return try await extractor.extractClaimsWithTier(from: slice, availability: availability)
        }
    }

    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int(Double($0) * step)] }
    }

    /// Fakten aus Läufen vor Version 0.7, in denen mehrere Aussagen samt
    /// Nummern aneinanderhängen, zeigt die App nicht. Steht nur vorn eine
    /// Nummer oder am Ende ein Verweis, zeigt sie den Fakt ohne sie.
    /// Aufräumen kostet Regex je Fakt: abseits, mit niedriger Priorität.
    public static func cleaned(_ list: [EpisodeFact]) async -> [EpisodeFact] {
        guard !list.isEmpty else { return [] }
        return await Task.detached(priority: .utility) { list.compactMap(\.cleaned) }.value
    }

    /// Fakten aus älteren Läufen zeigen auf den Anfang ihres Belegs, eine
    /// Passage von ein, zwei Minuten. Für die Anzeige bekommen sie ihren
    /// Satz. Gespeichert wird dabei nichts, „Neu ermitteln“ schreibt die
    /// neuen Zeitmarken.
    public static func anchored(_ list: [EpisodeFact], episodeID: EpisodeID, store: LibraryStore) async -> [EpisodeFact] {
        let list = await cleaned(list)
        guard list.contains(where: { $0.range.duration.milliseconds >= 30_000 }),
              let transcript = try? await store.transcript(forEpisode: episodeID) else { return list }
        return await Task.detached(priority: .utility) {
            ProcessingTrace.measure("Fakten verankern") { FactAnchor.anchored(list, in: transcript) }
        }.value
    }

    // MARK: - Kapitel

    /// Die Kapitel aus dem Feed. Verweist er nur auf eine Kapiteldatei, lädt
    /// die Arbeit sie, sofern das Netz das Vorbereiten erlaubt, und legt sie
    /// an der Folge ab wie beim Öffnen der Folge (Entscheidung 7). Sonst
    /// gelten Kapitel, die diese Sitzung schon kennt, zuletzt die Zeitmarken
    /// aus den Shownotes.
    func chapters(for episode: Episode, ticket: RemovalLedger.Ticket) async -> [Chapter] {
        if !episode.publisherChapters.isEmpty { return episode.publisherChapters }
        if let known = await environment.cachedChapters(episode.id), !known.isEmpty { return known }
        guard let url = episode.chaptersURL else { return [] }
        if await environment.networkAllowsPreparation(),
           let loaded = await environment.loadChapterFile(url), !loaded.isEmpty,
           !ledger.wasRemoved(episode.id, since: ticket) {
            // Eine gelöschte Folge trägt keine Kapitel: Der Store schreibt
            // nur in lebende Zeilen.
            try? await store.save(chapters: loaded, forEpisode: episode.id)
            await reporter.chaptersLoaded(loaded, for: episode.id, unlessRemovedSince: ticket)
            return loaded
        }
        let fallback = TimestampChapters.parse(episode.shownotesHTML, duration: episode.declaredDuration)
        return fallback.isEmpty ? TimestampChapters.parse(episode.summary, duration: episode.declaredDuration) : fallback
    }

    /// Die Kapitel mit Grenzen. Ohne Kapitel aus dem Feed schneidet der Code
    /// eigene Abschnitte aus den Belegen, abseits, denn dafür rechnet er
    /// Satzvektoren.
    static func sections(chapters: [Chapter], duration: MediaDuration?, evidence: [Evidence]) async -> [ChapterSection] {
        await Task.detached(priority: .userInitiated) {
            ChapterSections.sections(chapters: chapters, duration: duration, evidence: evidence)
        }.value
    }

    /// Der Wächter für das Schreiben: Folge, Quelle und Löschungen seit
    /// `ticket`, dazu die Fassung, auf die der Feed zeigt.
    private func commitGuard(for episode: Episode, since ticket: RemovalLedger.Ticket) -> CommitGuard {
        CommitGuard(episode: episode.id, source: episode.sourceID, since: ticket, ledger: ledger,
                    feedMedia: { CaptionAnalysis.feedMediaVersionID(of: $0) })
    }

    // MARK: - Kapitel-Tags

    /// Ordnet die Kapitel einer Folge ein und speichert die Kapitel-Tags.
    ///
    /// Nur, wenn die Folge noch keine Kapitel-Tags aus der aktuellen
    /// Revision ihres Transkripts hat. Ein neues Transkript ordnet also neu
    /// ein. Ein früherer, abgebrochener Lauf setzt beim nächsten Kapitel fort.
    ///
    /// `origin`: wer die Arbeit wollte. Nach den Fakten einer Folge erben die
    /// Tags die Herkunft des Faktenlaufs. Den Vorrang je Aufruf bestimmt
    /// daraus ``AIPriorityPolicy``.
    public func classifyChapters(of episode: Episode, origin: Origin,
                                 since ticket: RemovalLedger.Ticket) async -> ChapterTagsRun {
        let key = "tags|\(episode.id.rawValue)"
        guard running.claim(key) else { return ChapterTagsRun(.nothingToDo) }
        let run = await tagsRun(episode, origin: origin, ticket: ticket)
        running.release(key)
        return run
    }

    private func tagsRun(_ episode: Episode, origin: Origin, ticket: RemovalLedger.Ticket) async -> ChapterTagsRun {
        let id = episode.id
        // Nur die aktuelle Fassung, in ihrer neuesten Revision. Revisionen
        // zählen je Fassung, eine überholte kann die höhere tragen. Welche
        // Fassung aktuell ist, sagt die frisch gelesene Zeile der Folge, wie
        // beim Schreiben der Wächter im Store.
        let stored = (try? await store.evidence(forEpisode: id)) ?? []
        let preferred = (try? await store.episodes(ids: [id]))?.first?.currentMediaVersionID
            ?? episode.currentMediaVersionID
        guard let current = ChapterTagVersion.evidence(stored, preferred: preferred) else {
            return ChapterTagsRun(.nothingToDo)
        }
        let (mediaVersionID, revision, evidence) = current
        guard let backlog = try? await store.chapterTagBacklog(among: [id]),
              backlog.contains(id), !ledger.wasRemoved(id, since: ticket) else {
            KnowledgeMarks.setTaggingProgress(nil, for: id, in: marks)
            return ChapterTagsRun(.nothingToDo, current: !ledger.wasRemoved(id, since: ticket))
        }

        // Private Cloud Compute zuerst, ohne Netz das Gerät. Fehlen beide,
        // wartet die Folge. Der Stand der Modelle kennt das Netz schon
        // (`ModelStatus.assumingOffline`).
        let modelStatus = await environment.refreshModel()
        guard case .success = modelStatus.resolve(.tag) else { return ChapterTagsRun(.modelUnavailable) }

        let sections = await Self.sections(
            chapters: chapters(for: episode, ticket: ticket), duration: episode.declaredDuration, evidence: evidence)
        guard !sections.isEmpty else { return ChapterTagsRun(.nothingToDo) }
        var progress = KnowledgeMarks.taggingProgress(for: id, in: marks).flatMap {
            $0.matches(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections) ? $0 : nil
        } ?? ChapterTaggingProgress(mediaVersionID: mediaVersionID, transcriptRevision: revision, sections: sections)

        let facts = ((try? await store.facts(forEpisode: id)) ?? []).filter { $0.mediaVersionID == mediaVersionID }
        let passages = ChapterSections.group(evidence, into: sections) { $0.range?.start }
        let statements = ChapterSections.group(facts, into: sections) { $0.range.start }
        let budget = TagSelectionRules.passageTokenBudget(contextSize: ModelAvailabilityMonitor.onDeviceContextSize)
        let selector = TagSelector(useCase: .contentTagging, excerptLimit: Self.tagExcerptLimit, scheduler: scheduler)
        let priority = AIPriorityPolicy.priority(kind: .tags, origin: origin)
        // Jedes Schreiben dieser Einordnung geht durch den Wächter im Store.
        let writeGuard = commitGuard(for: episode, since: ticket)
        // Erkannte Tags, die diese Einordnung neu angelegt hat. Wird die Folge
        // gelöscht, gehen sie mit, sofern nichts anderes auf sie zeigt.
        var created = WriteReceipt(episodeID: id)
        let ledger = self.ledger
        let marks = self.marks
        let store = self.store
        /// Merkt den Stand, außer die Folge wurde inzwischen gelöscht. Dann
        /// hat das Löschen ihn schon entfernt, und er bliebe sonst liegen.
        func keep(_ progress: ChapterTaggingProgress) {
            guard !ledger.wasRemoved(id, since: ticket) else { return }
            KnowledgeMarks.setTaggingProgress(progress, for: id, in: marks)
        }
        /// Die Folge ist weg: kein Stand, und die neuen Tags gehen mit.
        func abandon() async -> ChapterTagsRun {
            KnowledgeMarks.setTaggingProgress(nil, for: id, in: marks)
            if !created.isEmpty {
                let elsewhere = KnowledgeMarks.tagsInTaggingProgress(except: [id], in: marks)
                _ = try? await store.removeWrites(created, keepingTags: elsewhere)
            }
            return ChapterTagsRun(.nothingToDo)
        }

        for section in progress.remaining(sections) {
            if Task.isCancelled || !environment.tagsMayContinue() {
                keep(progress)
                return ChapterTagsRun(.cancelled)
            }
            let material = ChapterMaterial(
                section: section, evidence: passages[section.index],
                statements: statements[section.index].map(\.statement))
            // Frisch je Kapitel: Ein Oberbegriff aus dem vorigen Kapitel ist
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
                            from: choices, passages: part, title: title,
                            availability: status, priority: priority
                        ).chosenIDs
                    }
                }
            } catch let error as ExtractorError {
                switch error {
                case .generationRejected:
                    // Dieselbe Eingabe scheitert jedes Mal gleich: Das Kapitel
                    // bleibt ohne Tags.
                    progress.finish(section, tags: [])
                    continue
                case .generationFailed:
                    keep(progress)
                    return ChapterTagsRun(.failed)
                case .modelUnavailable:
                    keep(progress)
                    _ = await environment.refreshModel()
                    return ChapterTagsRun(.modelUnavailable)
                }
            } catch {
                keep(progress)
                return ChapterTagsRun(.cancelled)
            }
            guard !ledger.wasRemoved(id, since: ticket) else { return await abandon() }

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
                    episodeID: id, mediaVersionID: mediaVersionID,
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

        guard !ledger.wasRemoved(id, since: ticket) else { return await abandon() }
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
        KnowledgeMarks.setTaggingProgress(nil, for: id, in: marks)
        // Gleich nach dem Speichern gelöscht: genau diese Kapitel-Tags wieder
        // weg, vor jedem Vermerk auf diesem Gerät.
        if ledger.wasRemoved(id, since: ticket) { return await abandon() }
        // Kein Kapitel bekam ein Tag: Es entsteht keine Zeile, und ohne
        // Merkzeichen reihte der nächste Start die Folge wieder ein.
        if progress.tags.isEmpty {
            var settled = KnowledgeMarks.tagsSettled(in: marks)
            settled.insert(id)
        }
        return ChapterTagsRun(.stored, current: true)
    }

    /// Token eines Belegs, gerechnet wie bei den Fakten mit drei Zeichen je Token.
    static func tagTokenCost(_ evidence: Evidence) -> Int {
        (min(evidence.quotedText.count, tagExcerptLimit) + 8) / 3
    }

    /// Läuft abseits, denn Kandidaten und Satzvektoren kosten Rechenzeit.
    /// Ein Abbruch erreicht die Arbeit trotzdem.
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try await work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

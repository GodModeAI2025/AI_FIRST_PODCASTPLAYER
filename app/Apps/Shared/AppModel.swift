//
//  AppModel.swift
//  PodcastAI
//
//  Der gemeinsame Zustand beider Apps. Ein Composition Root, kein
//  Singleton-Netz: die Dienste werden hier einmal gebaut und nach unten
//  gereicht.
//

import Foundation
import Observation
import SwiftUI
import PodcastAIKit

@MainActor
@Observable
public final class AppModel {

    // MARK: - Zustand für die Oberfläche

    public private(set) var sources: [Source] = []
    public private(set) var relevantToday: [RelevantItem] = []
    public internal(set) var smartFeeds: [SmartPodcastFeed] = []
    public internal(set) var editions: [SmartFeedID: [PersonalEpisode]] = [:]
    public private(set) var profile = InterestProfile()
    public private(set) var ledger = ListeningLedger()
    public private(set) var modelStatus = ModelStatus(
        onDevice: .unavailable(.modelNotReady),
        privateCloudCompute: .unavailable(.userConsentMissing)
    )

    /// Was gerade passiert. Eine Zeile, die der Nutzer lesen kann — keine
    /// unendliche Fortschrittsanzeige ohne Aussage.
    public internal(set) var highlights: [Highlight] = []
    public private(set) var activity: String?
    public private(set) var lastError: String?

    // MARK: - Dienste

    public let store: LibraryStore
    public let policy: PlaybackPolicy
    public let player: PlaybackCoordinator

    private let refresher: FeedRefresher
    private let deviceID: String

    public init(store: LibraryStore, deviceID: String = AppModel.currentDeviceID()) {
        self.store = store
        self.deviceID = deviceID
        self.policy = PlaybackPolicy(deviceID: deviceID)
        let locator = LocalMediaLocator()
        self.player = PlaybackCoordinator(locator: locator)
        self.refresher = FeedRefresher(store: store)
    }

    // MARK: - Laden

    public func load() async {
        do {
            sources = try await store.sources()
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
            ledger = try await store.ledger()
            modelStatus = await ModelStatusProbe.current()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Quellen

    /// Nimmt einen eingefügten Link auf.
    ///
    /// Abonnieren heißt hier ausdrücklich nicht herunterladen: die Folgen
    /// werden erfasst, nicht geladen und nicht analysiert. Was tatsächlich
    /// verarbeitet wird, entscheidet der Nutzer danach.
    public func addSource(from input: String) async {
        activity = "Link wird geprüft …"
        defer { activity = nil }
        do {
            let added = try await refresher.addSource(from: input)
            sources = try await store.sources()
            activity = "„\(added.title)“ aufgenommen · \(added.episodeCount) Folgen gefunden"
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshAll() async {
        activity = "Feeds werden aktualisiert …"
        defer { activity = nil }
        do {
            let result = try await refresher.refreshAll()
            sources = try await store.sources()
            activity = result.newEpisodes > 0
                ? "\(result.newEpisodes) neue Folgen"
                : "Keine neuen Folgen"
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Folgen erschliessen

    public private(set) var episodes: [SourceID: [Episode]] = [:]
    /// Welche Folge gerade in welcher Stufe steckt. Die Oberfläche zeigt
    /// damit an, wo die Arbeit steht — statt einer Anzeige ohne Aussage.
    public private(set) var stages: [EpisodeID: ProcessingStage] = [:]
    public private(set) var stageDetails: [EpisodeID: String] = [:]

    public func loadEpisodes(for sourceID: SourceID) async {
        do {
            episodes[sourceID] = try await store.episodes(forSource: sourceID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Erschliesst eine Folge: laden, transkribieren, Belege bilden.
    ///
    /// Ausdrücklich eine Nutzeraktion. Abonnieren allein lädt und analysiert
    /// nichts — das kostet Daten, Akku und Zeit, und die Entscheidung
    /// darüber gehört dem Nutzer.
    public func analyze(_ episode: Episode, audioURL: URL, locale: Locale = .current) async {
        stages[episode.id] = .discovered
        activity = "„\(episode.title)“ wird erschlossen …"
        defer { activity = nil }

        let pipeline = ContentPipeline(
            store: store,
            mediaDirectory: LocalMediaLocator.mediaDirectory,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.stages[progress.episodeID] = progress.stage
                    if let detail = progress.detail {
                        self?.stageDetails[progress.episodeID] = detail
                    }
                }
            }
        )
        do {
            _ = try await pipeline.process(
                episode: episode, audioURL: audioURL,
                sourceID: episode.sourceID, locale: locale
            )
        } catch {
            stages[episode.id] = .failed
            stageDetails[episode.id] = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    // MARK: - Interessen

    public func addInterest(_ label: String, kind: InterestKind) async {
        let interest = Interest(label: label, kind: kind, origin: .confirmedByUser)
        do {
            try await store.upsert(interest: interest)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func removeInterest(_ id: InterestID) async {
        do {
            try await store.removeInterest(id)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Wiedergabe

    /// Startet einen Hörplan. Der einzige Weg von der Oberfläche zum Ton.
    public func play(_ plan: ValidatedPlaybackPlan, from trigger: PlayTrigger) {
        let grant: PlaybackGrant = switch trigger {
        case .tap: policy.grantForUserTap(on: plan)
        case .chat: policy.grantForConfirmedChatPlayback(on: plan)
        case .intent: policy.grantForUserIntent(on: plan)
        }
        do {
            try player.start(plan: plan, grant: grant, deviceID: deviceID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public enum PlayTrigger { case tap, chat, intent }

    /// Nimmt Gehörtes in den gemeinsamen Hörzustand auf.
    public func recordHeard(_ range: MediaTimeRange, in mediaVersionID: MediaVersionID, via route: PlaybackRoute) async {
        let event = LedgerEvent(mediaVersionID: mediaVersionID, range: range,
                                kind: .played, via: route, deviceID: deviceID)
        do {
            try await store.record([event])
            ledger.apply(event)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Themenfeeds

    public func createSmartFeed(title: String, topicIDs: [InterestID], minutes: Int) {
        let feed = SmartPodcastFeed(
            title: title, topicIDs: topicIDs,
            editionMode: .budgeted(MediaDuration(minutes: minutes))
        )
        smartFeeds.append(feed)
    }

    /// Stellt eine neue Ausgabe zusammen. Startet ausdrücklich keinen Ton.
    @discardableResult
    public func buildEdition(feedID: SmartFeedID, budget: MediaDuration? = nil) async -> String {
        guard var feed = smartFeeds.first(where: { $0.id == feedID }) else {
            return "Diesen Themenfeed gibt es nicht."
        }
        if let budget { feed.editionMode = .budgeted(budget) }

        activity = "Ausgabe wird zusammengestellt …"
        defer { activity = nil }

        do {
            let pipeline = ContentPipeline(
                store: store, mediaDirectory: LocalMediaLocator.mediaDirectory
            )
            let candidates = try await pipeline.candidates(
                for: feed, profile: profile, availability: modelStatus
            )
            let existing = Set((editions[feedID] ?? []).map(\.batchKey))
            let outcome = PersonalEpisodePublisher().makeEdition(
                feed: feed, candidates: candidates, ledger: ledger,
                existingBatchKeys: existing
            )

            switch outcome {
            case .published(let episode):
                editions[feedID, default: []].insert(episode, at: 0)
                return "\(episode.title): \(episode.segments.count) Stellen aus "
                    + "\(episode.distinctSourceCount) Quellen."
            case .noNewMaterial(let count):
                return count == 0
                    ? "Zu diesen Themen ist noch nichts erschlossen."
                    : "Nichts Neues — alle passenden Stellen hast du schon gehört."
            case .belowThreshold(let available, let required):
                return "Erst \(available.shortDescription) neues Material, "
                    + "nötig sind \(required.shortDescription)."
            case .alreadyPublished:
                return "Diese Ausgabe gibt es bereits."
            }
        } catch {
            lastError = error.localizedDescription
            return "Die Ausgabe konnte nicht erstellt werden."
        }
    }

    // MARK: - Wissen

    /// Merkt sich die gerade laufende Stelle.
    ///
    /// Der Bereich entsteht rückwärts ab der aktuellen Position: wer
    /// „merken“ drückt, hat das Interessante gerade gehört.
    @discardableResult
    public func rememberPassage(
        at position: MediaTime, in mediaVersionID: MediaVersionID,
        note: String?, via route: Highlight.CaptureRoute
    ) async -> String {
        let capture = HighlightCapture()
        let range = capture.range(around: position, limit: nil)
        let highlight = Highlight(
            evidenceID: Evidence.stableID(
                mediaVersionID: mediaVersionID, transcriptRevision: .initial, range: range
            ),
            note: note, capturedVia: route
        )
        highlights.insert(highlight, at: 0)
        return "Gemerkt: \(range.start.timecode)–\(range.end.timecode)"
    }

    // MARK: - Chat

    /// Beantwortet eine Frage im gewählten Bereich.
    ///
    /// Der Schnappschuss wird **vor** der Antwort gebildet und danach nicht
    /// mehr angefasst: läuft parallel ein Refresh, ändert das nichts an der
    /// laufenden Antwort. Sonst könnte eine Antwort Belege zitieren, die
    /// beim Lesen schon andere sind.
    public func ask(_ question: String, scope: ChatScope) async -> ChatAnswer {
        activity = "Antwort wird gesucht …"
        defer { activity = nil }

        let evidence = (try? await store.evidenceForAnalyzedEpisodes()) ?? []
        let snapshot = ChatScopeSnapshot(
            scope: scope,
            evidence: evidence,
            coverage: evidence.isEmpty ? .none : .partial(fraction: 0.5, analyzed: IntervalSet())
        )
        let caveat = CoverageAdvisor.caveat(
            for: snapshot,
            questionSuggestsExhaustive: CoverageAdvisor.suggestsExhaustive(question)
        )

        guard !evidence.isEmpty else {
            return ChatAnswer(
                question: question, scope: scope,
                text: "Dazu ist noch nichts erschlossen. Nimm eine Quelle auf und lass "
                    + "eine Folge analysieren — danach kann ich mit Belegen antworten.",
                citations: [], coverageCaveat: caveat
            )
        }

        // Vorauswahl über die Stichworte der Frage, damit das Modell eine
        // überschaubare Kandidatenliste bekommt.
        let asInterest = Interest(label: question, kind: .openQuestion)
        var probe = InterestProfile(interests: [asInterest], learningEnabled: false)
        _ = probe
        let matches = RelevanceScorer(threshold: 0.15, maximumPerInterest: 12)
            .score(evidence: evidence, profile: InterestProfile(interests: [asInterest]))

        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        let citations = matches.compactMap { byID[$0.evidenceID] }

        guard !citations.isEmpty else {
            return ChatAnswer(
                question: question, scope: scope,
                text: "Dazu finde ich im gewählten Bereich keine belegte Stelle.",
                citations: [], coverageCaveat: caveat
            )
        }

        let text = citations.count == 1
            ? "Dazu gibt es eine belegte Stelle."
            : "Dazu gibt es \(citations.count) belegte Stellen."

        return ChatAnswer(
            question: question, scope: scope, text: text,
            citations: citations, coverageCaveat: caveat
        )
    }

    /// Macht aus einer Antwort eine Hörsession.
    public func playAnswer(_ answer: ChatAnswer) {
        let context = SnapshotPlanningContext(evidence: answer.citations)
        let plan = FocusPlanner(context: context).plan(
            from: answer.playbackProposal(),
            route: .chatFocus,
            options: FocusPlannerOptions(skipAlreadyHeard: false, ledger: ledger)
        )
        guard !plan.isEmpty else {
            lastError = "Zu dieser Antwort lässt sich nichts abspielen."
            return
        }
        play(plan, from: .chat)
    }

    /// Baut den Markdown-Export über alle gemerkten Stellen.
    public func exportKnowledge() -> String {
        guard !highlights.isEmpty else { return "" }
        let exporter = MarkdownExporter()
        return highlights.map { highlight in
            let claim = Claim(
                id: ClaimID(stable: highlight.id.rawValue),
                statement: highlight.note ?? "Gemerkte Stelle",
                evidenceIDs: [highlight.evidenceID],
                provenance: highlight.note == nil ? .original : .user
            )
            return exporter.export(ExportableInsight(
                title: highlight.note ?? "Gemerkte Stelle",
                claim: claim, evidence: [],
                userNote: highlight.note,
                sourceTitles: [:], episodeTitles: [:]
            ))
        }
        .joined(separator: "\n\n")
    }

    /// Prüft alle automatischen Themenfeeds auf neues Material.
    ///
    /// Veröffentlicht höchstens eine Ausgabe je Feed und Lauf: fünf auf
    /// einmal wären keine Neuigkeit mehr, sondern eine Flut.
    public func processPendingEditions() async {
        for feed in smartFeeds where feed.publicationPolicy.isAutomatic {
            _ = await buildEdition(feedID: feed.id)
        }
    }

    // MARK: - Gegenpositionen und Wissenspfade

    public internal(set) var trails: [KnowledgeTrail] = []

    /// Sucht belegte Positionen zu einer These.
    ///
    /// Die Zuordnung ist zunächst eine Vermutung aus Stichworten und wird
    /// auch so gekennzeichnet. Ein Modell kann sie bestätigen; ohne Modell
    /// bleibt sie sichtbar ungeprüft.
    public func findCounterpoints(for thesis: String) async -> [CounterpointCandidate] {
        guard let evidence = try? await store.evidenceForAnalyzedEpisodes(), !evidence.isEmpty else {
            return []
        }
        let asQuestion = Interest(label: thesis, kind: .openQuestion)
        let matches = RelevanceScorer(threshold: 0.15, maximumPerInterest: 20)
            .score(evidence: evidence, profile: InterestProfile(interests: [asQuestion]))

        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        return matches.compactMap { match in
            guard let item = byID[match.evidenceID] else { return nil }
            return CounterpointCandidate(
                evidenceID: item.id,
                // Ohne Modellprüfung wird keine Richtung behauptet: die
                // Stelle gehört zum Thema, mehr ist damit nicht gesagt.
                relation: .differentPremise,
                isModelConfirmed: false,
                sourceTitle: sources.first { $0.id == item.sourceID }?.title ?? "Quelle",
                excerpt: item.quotedText
            )
        }
    }

    public func playCounterpoints(_ candidates: [CounterpointCandidate], thesis: String) {
        Task {
            guard let all = try? await store.evidence(ids: candidates.map(\.evidenceID)) else { return }
            let context = SnapshotPlanningContext(evidence: Array(all.values))
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(
                    evidenceIDs: candidates.map(\.evidenceID),
                    requestSummary: "Gegenpositionen zu: \(thesis)"
                ),
                route: .counterpoint,
                options: FocusPlannerOptions(skipAlreadyHeard: false, ledger: ledger)
            )
            guard !plan.isEmpty else {
                lastError = "Zu dieser These lässt sich nichts abspielen."
                return
            }
            play(plan, from: .tap)
        }
    }

    /// Parken: sichert Frage, Belege und Notizen. Ohne Zustimmung zu irgendetwas.
    public func park(_ closure: SessionClosure) {
        trails.insert(KnowledgeTrail(
            question: closure.question,
            evidenceIDs: closure.supportingEvidenceIDs,
            highlightIDs: highlights.map(\.id)
        ), at: 0)
    }

    /// Vertiefen: erzeugt eine neue, begrenzte Hörsession zur Anschlussfrage.
    public func deepen(_ closure: SessionClosure) {
        Task {
            guard let all = try? await store.evidence(ids: closure.supportingEvidenceIDs) else { return }
            let context = SnapshotPlanningContext(evidence: Array(all.values))
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(
                    evidenceIDs: closure.supportingEvidenceIDs,
                    requestSummary: closure.question
                ),
                route: .interestFocus,
                options: FocusPlannerOptions(
                    // Begrenztes Budget: Vertiefen ist kein endloser Loop.
                    budget: closure.suggestedBudget, ledger: ledger
                )
            )
            guard !plan.isEmpty else {
                lastError = "Dazu ist nichts weiter erschlossen."
                return
            }
            play(plan, from: .tap)
        }
    }

    public func clearError() { lastError = nil }

    static func currentDeviceID() -> String {
        // Stabil je Installation, ohne Gerätekennung zu erheben.
        let key = "com.podcastai.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}

/// Ein für den Nutzer relevanter Abschnitt, wie er auf „Für dich“ erscheint.
public struct RelevantItem: Identifiable, Sendable {
    public let id: EvidenceID
    public let sourceTitle: String
    public let episodeTitle: String
    public let range: MediaTimeRange
    public let excerpt: String
    public let relevance: PersonalRelevance?

    public init(id: EvidenceID, sourceTitle: String, episodeTitle: String,
                range: MediaTimeRange, excerpt: String, relevance: PersonalRelevance?) {
        self.id = id; self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.range = range; self.excerpt = excerpt; self.relevance = relevance
    }
}

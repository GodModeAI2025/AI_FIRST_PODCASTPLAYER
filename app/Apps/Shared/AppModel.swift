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

    /// Liegt überhaupt erschlossenes Material vor?
    ///
    /// Nicht dasselbe wie „es gibt Quellen“: Abonnieren lädt und analysiert
    /// ausdrücklich nichts. Ohne diese Unterscheidung kann die Oberfläche
    /// den ersten leeren Zustand nicht vom zweiten trennen und schickt den
    /// Nutzer an die falsche Stelle.
    public private(set) var hasAnalyzedMaterial = false

    /// Der sichtbare Bereich. Liegt hier und nicht in der Ansicht, weil ein
    /// leerer Zustand auf den nächsten Schritt zeigen können muss — und der
    /// liegt in einem anderen Tab.
    public var area: AppArea = .forYou

    /// Offen, wenn der Nutzer eine Quelle hinzufügen will. Steht hier und
    /// nicht in einer Ansicht, weil auf dem Mac das Menü es öffnet und das
    /// Fenster es zeigt — zwei verschiedene Stellen.
    public var isAddingSource = false

    // MARK: - Dienste

    public let store: LibraryStore
    public let policy: PlaybackPolicy
    public let player: PlaybackCoordinator
    /// Eine Instanz für die ganze App. Der Einwilligungsschalter und der
    /// Indexlauf müssen denselben Zustand sehen.
    public let spotlight = SpotlightIndex()

    private let refresher: FeedRefresher
    private let deviceID: String

    public init(store: LibraryStore, deviceID: String = AppModel.currentDeviceID()) {
        self.store = store
        self.deviceID = deviceID
        self.policy = PlaybackPolicy(deviceID: deviceID)
        let locator = LocalMediaLocator()
        self.player = PlaybackCoordinator(locator: locator)
        self.refresher = FeedRefresher(store: store)
        // Erst diese Zeile macht aus dem Player einen, der den Hörzustand
        // fortschreibt. Ohne sie läuft die Wiedergabe, und nichts davon
        // kommt je im Ledger an.
        self.player.setObserver(self)
    }

    /// Der Zustand des Players, gespiegelt für die Oberfläche.
    ///
    /// `PlaybackCoordinator.state` ist keine beobachtbare Eigenschaft — eine
    /// SwiftUI-Ansicht, die sie liest, aktualisiert sich nicht. Deshalb hier.
    public private(set) var playerState: PlaybackState = .idle
    /// Position innerhalb des laufenden Abschnitts, für die Fortschrittsanzeige.
    public private(set) var playerPosition: MediaTime = .zero
    /// Der laufende Plan, gespiegelt. Ansichten lesen ihn hier, nicht am
    /// Koordinator — sonst zeigen sie beim Start nichts und beim Ende noch
    /// immer den alten Plan.
    public private(set) var playerPlan: ValidatedPlaybackPlan?
    /// Die Abschlusskarte, sofern eine ansteht.
    ///
    /// `SessionClosureSheet` und `SessionBoundaryPolicy` waren beide
    /// geschrieben und beide unerreichbar: nichts baute je einen
    /// `SessionClosure`. Das Kapitel „Breadcrumb Trail“ gab es damit im
    /// Quelltext, aber nicht in der App.
    public internal(set) var pendingClosure: SessionClosure?

    private let boundaryPolicy = SessionBoundaryPolicy()
    /// Wie viel in dieser Sitzung tatsächlich erklungen ist.
    private var sessionListened: MediaDuration = .zero
    /// Einmal je Sitzung. Eine wiederkehrende Frage ist eine Belästigung.
    private var closureOfferedThisSession = false

    /// Der Abschnitt, bei dem die Wiedergabe gerade steht.
    public var playingSegmentIndex: Int? {
        if case .playing(let index) = playerState { return index }
        return nil
    }
    public var isPlaying: Bool { playingSegmentIndex != nil }

    // MARK: - Laden

    public func load() async {
        do {
            sources = try await store.sources()
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
            ledger = try await store.ledger()
            // Was der Nutzer selbst angelegt hat. Bis eben lag das alles
            // nur im Speicher und war beim nächsten Start verschwunden.
            smartFeeds = try await store.smartFeeds()
            editions = try await store.editions()
            highlights = try await store.highlights()
            trails = try await store.trails()
            modelStatus = await ModelStatusProbe.current()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshRelevantToday()
    }

    /// Lässt eine Meldung stehen und räumt sie danach weg.
    ///
    /// Mit Marke, nicht blind: läuft inzwischen ein anderer Vorgang und hat
    /// eine neue Meldung gesetzt, darf dieser Aufruf sie nicht löschen. Das
    /// war Befund 7 — eine einzige Zeichenkette für die ganze App, und wer
    /// zuerst fertig wird, räumt dem anderen die Anzeige ab.
    func clearActivity(after delay: Duration) {
        activityToken &+= 1
        let mine = activityToken
        Task {
            try? await Task.sleep(for: delay)
            guard activityToken == mine else { return }
            activity = nil
        }
    }

    /// Zählt hoch, sobald jemand die Meldung ändert.
    private var activityToken = 0

    /// Stellt „Für dich“ zusammen.
    ///
    /// Diese Methode fehlte. `relevantToday` war deklariert, wurde gelesen
    /// und nie geschrieben — die Ansicht zeigte deshalb immer „Nichts
    /// Neues“, ganz gleich wie viel analysiert war. Der Bewerter, der
    /// Hörzustand und die Belege waren alle da; verbunden war nichts.
    ///
    /// Drei Regeln, die hier zusammenkommen:
    ///
    /// - Nur **bestätigte** Interessen führen zu Vorschlägen. Das setzt
    ///   `RelevanceScorer` durch; hier wird es nicht umgangen.
    /// - Was gehört ist, bleibt gehört: Belege, deren Stelle der Hörzustand
    ///   bereits abdeckt, fallen heraus. Sonst böte die App dieselbe Stelle
    ///   jeden Tag erneut an.
    /// - Ohne Timecode kein Vorschlag. Ein Beleg, den man nicht nachhören
    ///   kann, gehört nicht auf eine Liste, deren Versprechen das Nachhören ist.
    public func refreshRelevantToday() async {
        do {
            let evidence = try await store.evidenceForAnalyzedEpisodes()
            hasAnalyzedMaterial = !evidence.isEmpty
            let matches = RelevanceScorer().score(evidence: evidence, profile: profile)
            guard !matches.isEmpty else {
                relevantToday = []
                return
            }

            let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let titles = try await store.titles(
                forEpisodes: Array(Set(evidence.map(\.episodeID))))

            var seen: Set<EvidenceID> = []
            var items: [RelevantItem] = []
            // Der beste Treffer je Beleg gewinnt: ein Beleg, der zu drei
            // Themen passt, erscheint einmal, nicht dreimal.
            for match in matches.sorted(by: { $0.score > $1.score }) {
                guard !seen.contains(match.evidenceID) else { continue }
                guard let item = byID[match.evidenceID], let range = item.range else { continue }
                // `unheardPortion` statt eines nackten Abdeckungsvergleichs:
                // es berücksichtigt auch ausdrücklich Übersprungenes und
                // verwirft Reststücke, die zu kurz für Inhalt sind.
                guard !ledger.unheardPortion(of: range, in: item.mediaVersionID).isEmpty
                else { continue }
                seen.insert(match.evidenceID)
                let title = titles[item.episodeID]
                items.append(RelevantItem(
                    id: item.id,
                    sourceTitle: title?.source ?? "Unbekannte Quelle",
                    episodeTitle: title?.episode ?? "Unbekannte Folge",
                    range: range,
                    excerpt: item.quotedText,
                    relevance: match.personalRelevance()
                ))
            }
            relevantToday = items
            refreshSuggestions(from: evidence)
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
        // Kein `defer { activity = nil }`: es liefe beim Verlassen der
        // Funktion und damit **nach** der Erfolgsmeldung. Die wurde gesetzt
        // und sofort wieder gelöscht — der Nutzer sah den Spinner und
        // danach nichts. Jeder Ausgang setzt die Meldung jetzt selbst.
        do {
            let added = try await refresher.addSource(from: input)
            sources = try await store.sources()
            activity = "„\(added.title)“ aufgenommen · \(added.episodeCount) Folgen gefunden"
            clearActivity(after: .seconds(4))
        } catch {
            lastError = error.localizedDescription
            activity = nil
        }
    }

    public func refreshAll() async {
        activity = "Feeds werden aktualisiert …"
        do {
            let result = try await refresher.refreshAll()
            sources = try await store.sources()
            activity = result.newEpisodes > 0
                ? "\(result.newEpisodes) neue Folgen"
                : "Keine neuen Folgen"
            clearActivity(after: .seconds(4))
        } catch {
            lastError = error.localizedDescription
            activity = nil
        }
        await refreshRelevantToday()
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
    /// Startet die Analyse und **behält den Vorgang**.
    ///
    /// Bisher warf die Oberfläche einen losgelösten `Task` an und vergaß
    /// ihn. Damit gab es keinen Abbruch: wer die falsche Folge erwischt
    /// hatte, konnte nur die App beenden — und wusste nicht, was dann mit
    /// dem halben Ergebnis passiert. Die Pipeline war längst darauf
    /// vorbereitet (`Task.checkCancellation` im Transkriptionslauf), es
    /// fehlte nur der Griff daran.
    public func startAnalysis(_ episode: Episode, audioURL: URL, locale: Locale = .current) {
        guard analyses[episode.id] == nil else { return }
        let task = Task { [weak self] in
            await self?.analyze(episode, audioURL: audioURL, locale: locale)
        }
        analyses[episode.id] = task
    }

    /// Bricht eine laufende Analyse ab.
    public func cancelAnalysis(_ episodeID: EpisodeID) {
        analyses[episodeID]?.cancel()
    }

    public func isAnalyzing(_ episodeID: EpisodeID) -> Bool {
        analyses[episodeID] != nil
    }

    /// Die laufenden Analysen. Je Folge höchstens eine.
    private var analyses: [EpisodeID: Task<Void, Never>] = [:]

    func analyze(_ episode: Episode, audioURL: URL, locale: Locale = .current) async {
        stages[episode.id] = .discovered
        activity = "„\(episode.title)“ wird erschlossen …"
        defer {
            analyses[episode.id] = nil
            activity = nil
        }

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
        } catch is CancellationError {
            // Kein Fehler und keine Meldung: der Nutzer hat es so gewollt.
            // Die angefangene Datei hat `SafeHTTP.save` bereits entfernt.
            stages[episode.id] = .cancelled
            stageDetails[episode.id] = nil
        } catch {
            // Ein Abbruch kann auch als `URLError.cancelled` ankommen, wenn
            // er die Netzschicht zuerst erwischt. Für den Nutzer ist das
            // derselbe Vorgang.
            if Task.isCancelled {
                stages[episode.id] = .cancelled
                stageDetails[episode.id] = nil
            } else {
                stages[episode.id] = .failed
                stageDetails[episode.id] = error.localizedDescription
                lastError = error.localizedDescription
            }
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
            playerPlan = plan
            sessionListened = .zero
            closureOfferedThisSession = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    public enum PlayTrigger { case tap, chat, intent }

    // Die Oberfläche steuert den Ton ausschließlich über diese vier Wege.
    // `PlaybackCoordinator` ist nicht beobachtbar; ein direkter Aufruf aus
    // einer Ansicht änderte den Zustand, ohne dass die Ansicht davon erfährt.
    public func pausePlayback() { player.pause() }
    public func resumePlayback() { player.resume() }
    public func skipSegment() { player.skipSegment() }

    public func stopPlayback() {
        let plan = playerPlan
        player.stop()
        playerPlan = nil
        playerPosition = .zero
        // `player.stop()` meldet selbst `.finished`, und der Beobachter
        // bietet die Abschlusskarte dann schon an. Der Aufruf hier ist die
        // Sicherung für den Fall, dass er das einmal nicht tut —
        // `closureOfferedThisSession` macht den zweiten Aufruf wirkungslos.
        offerClosure(ending: .userStopped, for: plan)
    }

    /// Bietet die Abschlusskarte an — oder eben nicht.
    ///
    /// Die Entscheidung trifft `SessionBoundaryPolicy`: nur bei einem
    /// bewussten Ende, erst ab einer Mindesthördauer, und einmal. Wer nach
    /// zwanzig Sekunden stoppt, hat nichts abgeschlossen.
    func offerClosure(ending: SessionEnding, for plan: ValidatedPlaybackPlan?) {
        guard let plan, !plan.isEmpty else { return }
        guard boundaryPolicy.shouldOfferClosure(
            ending: ending,
            listened: sessionListened,
            alreadyOfferedForSession: closureOfferedThisSession
        ) else { return }

        closureOfferedThisSession = true

        // Weiterführend ist, was zu denselben Interessen erschlossen ist und
        // in dieser Sitzung nicht vorkam. Eine echte Zahl, keine Andeutung:
        // „drei weitere Quellen“ muss drei Quellen bedeuten.
        let heardEvidence = Set(plan.segments.map(\.evidenceID))
        let followUps = relevantToday.filter { !heardEvidence.contains($0.id) }

        pendingClosure = SessionClosure(
            question: plan.requestSummary,
            supportingEvidenceIDs: Array(heardEvidence),
            availableFollowUpCount: followUps.count
        )
    }

    public func dismissClosure() { pendingClosure = nil }

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

    /// Legt einen Themenfeed an und gibt seine Kennung zurück.
    ///
    /// Die Rückgabe ist der Grund, warum der Aufrufer gleich danach eine
    /// erste Ausgabe bauen kann — ein Feed, der direkt nach dem Anlegen leer
    /// ist, sieht aus wie ein Fehler.
    @discardableResult
    public func createSmartFeed(
        title: String, topicIDs: [InterestID], minutes: Int
    ) -> SmartFeedID {
        let feed = SmartPodcastFeed(
            title: title, topicIDs: topicIDs,
            editionMode: .budgeted(MediaDuration(minutes: minutes))
        )
        smartFeeds.append(feed)
        persistSmartFeeds()
        return feed.id
    }

    /// Sichert die selbst angelegten Bestände.
    ///
    /// Bewusst als eigene, kurze Methoden und nicht als eine große: jede
    /// Änderung sichert genau das, was sie geändert hat. Ein gemerkter
    /// Gedanke schreibt keine Themenfeeds neu.
    private func persistSmartFeeds() {
        let feeds = smartFeeds
        Task { await persist { try await $0.save(smartFeeds: feeds) } }
    }

    private func persistEditions(for feedID: SmartFeedID) {
        let list = editions[feedID] ?? []
        Task { await persist { try await $0.save(editions: list, forFeed: feedID) } }
    }

    private func persistHighlights() {
        let list = highlights
        Task { await persist { try await $0.save(highlights: list) } }
        reindexSpotlight()
    }

    /// Meldet die gemerkten Stellen an den Systemindex.
    ///
    /// `SpotlightIndex.index(highlights:evidence:)` hatte keine einzige
    /// Aufrufstelle. Ohne diesen Aufruf findet die Systemsuche nichts, was
    /// in dieser App gemerkt wurde — der Schalter in den Einstellungen war
    /// ein Schalter ohne Wirkung. Der Index selbst prüft die Einwilligung.
    public func reindexSpotlight() {
        let list = highlights
        Task {
            let evidence = (try? await store.evidence(ids: list.map(\.evidenceID))) ?? [:]
            await spotlight.index(highlights: list, evidence: evidence)
        }
    }

    private func persistTrails() {
        let list = trails
        Task { await persist { try await $0.save(trails: list) } }
    }

    /// Ein fehlgeschlagenes Sichern wird gemeldet, nicht verschluckt.
    /// Sonst sieht der Nutzer seinen Eintrag, und beim nächsten Start ist er weg.
    private func persist(_ work: (LibraryStore) async throws -> Void) async {
        do {
            try await work(store)
        } catch {
            lastError = "Konnte nicht gesichert werden: \(error.localizedDescription)"
        }
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
            // Titel mitgeben, statt sie in der Ausgabe durch „Quelle“ und
            // „Folge“ zu ersetzen. Eine Ausgabe, die ihre eigenen
            // Bestandteile nicht benennen kann, ist kein Podcast — und die
            // Shownotes sind die Stelle, an der das auffällt.
            let known = try await store.evidenceForAnalyzedEpisodes()
            let titles = try await store.titles(
                forEpisodes: Array(Set(known.map(\.episodeID))))
            let candidates = try await pipeline.candidates(
                for: feed, profile: profile, availability: modelStatus,
                titles: titles.mapValues {
                    (source: $0.source, episode: $0.episode, published: $0.publishedAt)
                }
            )
            let existing = Set((editions[feedID] ?? []).map(\.batchKey))
            let outcome = PersonalEpisodePublisher().makeEdition(
                feed: feed, candidates: candidates, ledger: ledger,
                existingBatchKeys: existing
            )

            switch outcome {
            case .published(let episode):
                editions[feedID, default: []].insert(episode, at: 0)
                persistEditions(for: feedID)
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
        persistHighlights()
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

        // **Hier wird das Modell tatsächlich gefragt.**
        //
        // Bis hierher endete die Antwort bei einer Zählung („Dazu gibt es
        // vier belegte Stellen“). Der Kommentar oben sprach vom Modell, das
        // Modell kam nie vor.
        //
        // `extractClaims` gibt Aussagen zurück, die **jeweils die Kennung
        // des Belegs tragen**, aus dem sie stammen — eine Aussage ohne
        // Beleg fällt schon dort heraus (`isWellFormed`). Damit gibt es
        // keinen Weg, dass Modelltext ohne Herkunft in die Antwort gerät:
        // die Antwort besteht aus Aussagen, nicht aus freiem Text.
        let text = await answerText(from: citations, fallbackCount: citations.count)

        return ChatAnswer(
            question: question, scope: scope, text: text,
            citations: citations, coverageCaveat: caveat
        )
    }

    /// Baut einen Planungskontext, der Folgen und Quellen kennt.
    ///
    /// Ohne die Folgen liefe der Planer auf Platzhaltertiteln („Folge“,
    /// „Quelle“) und könnte eine überholte Medienfassung nicht erkennen.
    func planningContext(for evidence: [Evidence]) async -> SnapshotPlanningContext {
        let episodes = (try? await store.episodes(
            ids: Array(Set(evidence.map(\.episodeID))))) ?? []
        return SnapshotPlanningContext(
            evidence: evidence, episodes: episodes, sources: sources)
    }

    /// Formuliert die Antwort — mit Modell, wenn eines verfügbar ist.
    ///
    /// Ohne Modell wird nicht so getan, als gäbe es eines: dann steht dort
    /// die Zählung und der Grund. Eine erfundene Zusammenfassung wäre genau
    /// das, wogegen die ganze Belegkette gebaut ist.
    private func answerText(from citations: [Evidence], fallbackCount: Int) async -> String {
        let counted = fallbackCount == 1
            ? "Dazu gibt es eine belegte Stelle."
            : "Dazu gibt es \(fallbackCount) belegte Stellen."

        do {
            let claims = try await KnowledgeExtractor()
                .extractClaims(from: citations, availability: modelStatus)
            guard !claims.isEmpty else { return counted }

            // Jede Zeile ist eine Aussage mit Beleg. Die offene Frage wird
            // als solche ausgewiesen, nicht als Erkenntnis verkauft.
            var lines = claims.prefix(5).map { "• \($0.statement)" }
            if let question = claims.compactMap(\.openQuestion).first {
                lines.append("\nOffen dabei: \(question)")
            }
            return lines.joined(separator: "\n")
        } catch let error as ExtractorError {
            // Warum es keine Formulierung gibt, steht in der Antwort — nicht
            // im Log. Der Nutzer soll den Unterschied sehen zwischen „nichts
            // gefunden“ und „kein Modell verfügbar“.
            return counted + "\n\n" + (error.errorDescription ?? "Kein Modell verfügbar.")
        } catch {
            return counted
        }
    }

    /// Macht aus einer Antwort eine Hörsession.
    public func playAnswer(_ answer: ChatAnswer) {
        Task { await playAnswerAsync(answer) }
    }

    private func playAnswerAsync(_ answer: ChatAnswer) async {
        let context = await planningContext(for: answer.citations)
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

    /// Leitet vermutete Interessen aus dem tatsächlich Gehörten ab.
    ///
    /// `profile.suggested` war immer leer: die Oberfläche hatte einen
    /// Abschnitt dafür, erzeugt hat die Vorschläge nie jemand. Damit war die
    /// Hälfte des Kapitels „Interessenmodell“ eine leere Überschrift.
    ///
    /// Nur aus Gehörtem, nicht aus allem Abonnierten — sonst schlägt die App
    /// vor, was der Nutzer nie angehört hat. Und nie automatisch wirksam:
    /// `RelevanceScorer` lässt weiterhin nur bestätigte Interessen wirken.
    func refreshSuggestions(from evidence: [Evidence]) {
        guard profile.learningEnabled else { return }
        let heard = evidence.filter { item in
            guard let range = item.range else { return false }
            return ledger.heard(in: item.mediaVersionID).covers(range, threshold: 0.6)
        }
        guard !heard.isEmpty else { return }

        let rejected = rejectedSuggestions
        let fresh = InterestSuggester()
            .suggestions(fromHeard: heard, existing: profile)
            .filter { !rejected.contains($0.id.rawValue) }
        guard !fresh.isEmpty else { return }
        for interest in fresh { profile.add(interest) }
    }

    /// Schaltet das Ableiten von Interessen ein oder aus.
    ///
    /// Ausschalten entfernt die bestehenden Vorschläge gleich mit. Sie
    /// stehen zu lassen wäre der unangenehmere Zustand: ein Abschnitt
    /// „Vorschläge von PodcastAI“ unter einem Schalter, der sagt, dass
    /// nichts vorgeschlagen wird.
    public func setLearningEnabled(_ enabled: Bool) {
        profile.learningEnabled = enabled
        if !enabled {
            for interest in profile.suggested { profile.remove(interest.id) }
        }
    }

    /// Verwirft alle Vorschläge und vergisst die Ablehnungen.
    ///
    /// Zwei Dinge in einem, und das ist Absicht: wer zurücksetzt, will nicht
    /// dieselbe Liste ohne die abgelehnten Einträge, sondern einen neuen
    /// Anlauf.
    public func resetSuggestions() {
        for interest in profile.suggested { profile.remove(interest.id) }
        rejectedSuggestions = []
    }

    /// Übernimmt einen Vorschlag. Ab hier wirkt er.
    public func confirmSuggestion(_ id: InterestID) {
        profile.confirm(id)
        Task {
            if let interest = profile.interests.first(where: { $0.id == id }) {
                await persist { try await $0.upsert(interest: interest) }
            }
            await refreshRelevantToday()
        }
    }

    /// Lehnt einen Vorschlag ab. Er kommt nicht wieder: die Kennung ist
    /// stabil aus dem Begriff gebildet, und abgelehnte Begriffe bleiben
    /// gemerkt.
    public func rejectSuggestion(_ id: InterestID) {
        rejectedSuggestions.insert(id.rawValue)
        profile.remove(id)
    }

    /// Abgelehnte Vorschläge, damit derselbe Begriff nicht jede Woche
    /// erneut auftaucht.
    private var rejectedSuggestions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "com.podcastai.rejectedSuggestions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "com.podcastai.rejectedSuggestions") }
    }

    /// Das Cover einer Ausgabe.
    ///
    /// Eine reine Funktion aus Ausgabe und Feedtitel — deshalb berechnet
    /// statt gespeichert. `NativeCoverRenderer` hatte bis hierher keine
    /// einzige Aufrufstelle.
    public func cover(for episode: PersonalEpisode) -> CoverAsset? {
        guard let feed = smartFeeds.first(where: { $0.id == episode.feedID }) else { return nil }
        return NativeCoverRenderer().makeCover(for: episode, feedTitle: feed.title)
    }

    /// Baut den Markdown-Export über alle gemerkten Stellen.
    ///
    /// Bisher übergab diese Methode `evidence: []` und leere Titelkarten —
    /// der Export hatte eine Überschrift „Quellen“ und nichts darunter.
    /// Genau das, wogegen die ganze Belegkette gebaut ist: ein Zitat ohne
    /// Herkunft. Die Belege werden jetzt geholt, und wenn einer fehlt,
    /// erscheint die Stelle nicht mit halber Herkunft, sondern gar nicht.
    public func exportKnowledge() async -> String {
        guard !highlights.isEmpty else { return "" }

        let found = (try? await store.evidence(
            ids: highlights.map(\.evidenceID))) ?? [:]
        let episodes = (try? await store.episodes(
            ids: Array(Set(found.values.map(\.episodeID))))) ?? []

        let episodeTitles = Dictionary(
            episodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let sourceTitles = Dictionary(
            sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        let exporter = MarkdownExporter()
        return highlights.compactMap { highlight -> String? in
            guard let evidence = found[highlight.evidenceID] else { return nil }
            let claim = Claim(
                id: ClaimID(stable: highlight.id.rawValue),
                statement: highlight.note ?? "Gemerkte Stelle",
                evidenceIDs: [highlight.evidenceID],
                provenance: highlight.note == nil ? .original : .user
            )
            return exporter.export(ExportableInsight(
                title: highlight.note ?? "Gemerkte Stelle",
                claim: claim, evidence: [evidence],
                userNote: highlight.note,
                sourceTitles: sourceTitles, episodeTitles: episodeTitles
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
        let shortlist = matches.compactMap { byID[$0.evidenceID] }

        // Das Modell ordnet ein — in vorgegebene Bezeichnungen, und was es
        // sonst zurückgibt, wird verworfen. Ohne Modell bleibt es bei der
        // Vermutung, und `isModelConfirmed: false` sagt das in der
        // Oberfläche auch: die Stelle gehört zum Thema, mehr nicht.
        let labels = CounterpointRelation.allCases.map(\.rawValue)
        let classified = (try? await KnowledgeExtractor().classify(
            shortlist, against: thesis, labels: labels, availability: modelStatus)) ?? [:]

        return shortlist.map { item in
            let assigned = classified[item.id].flatMap(CounterpointRelation.init(rawValue:))
            return CounterpointCandidate(
                evidenceID: item.id,
                relation: assigned ?? .differentPremise,
                isModelConfirmed: assigned != nil,
                sourceTitle: sources.first { $0.id == item.sourceID }?.title
                    ?? "Unbekannte Quelle",
                excerpt: item.quotedText
            )
        }
    }

    public func playCounterpoints(_ candidates: [CounterpointCandidate], thesis: String) {
        Task {
            guard let all = try? await store.evidence(ids: candidates.map(\.evidenceID)) else { return }
            let context = await planningContext(for: Array(all.values))
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
        pendingClosure = nil
        trails.insert(KnowledgeTrail(
            question: closure.question,
            evidenceIDs: closure.supportingEvidenceIDs,
            highlightIDs: highlights.map(\.id)
        ), at: 0)
        persistTrails()
    }

    /// Vertiefen: erzeugt eine neue, begrenzte Hörsession zur Anschlussfrage.
    public func deepen(_ closure: SessionClosure) {
        Task {
            guard let all = try? await store.evidence(ids: closure.supportingEvidenceIDs) else { return }
            let context = await planningContext(for: Array(all.values))
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

    /// Spielt eine einzelne relevante Stelle.
    ///
    /// Das war die Lücke, die „Für dich" wirkungslos machte: der Bildschirm
    /// versprach „das kannst du nachhören" und bot keinen Weg dorthin.
    public func playRelevantItem(_ item: RelevantItem) {
        Task {
            guard let found = try? await store.evidence(ids: [item.id]),
                  let evidence = found[item.id] else {
                lastError = "Diese Stelle ist nicht mehr verfügbar."
                return
            }
            let context = await planningContext(for: [evidence])
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(evidenceIDs: [item.id],
                                       requestSummary: item.episodeTitle),
                route: .interestFocus,
                // Ausdrücklich gewählt heisst: auch dann abspielen, wenn es
                // schon gehört wurde.
                options: FocusPlannerOptions(skipAlreadyHeard: false, ledger: ledger)
            )
            guard !plan.isEmpty else {
                lastError = plan.excluded.first?.reason ?? "Diese Stelle lässt sich nicht abspielen."
                return
            }
            play(plan, from: .tap)
        }
    }

    /// Hebt einen Vorschlag zu einem bestätigten Interesse.
    public func confirmInterest(_ id: InterestID) async {
        profile.confirm(id)
        guard let interest = profile.interests.first(where: { $0.id == id }) else { return }
        do {
            try await store.upsert(interest: interest)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func clearError() { lastError = nil }
}

// MARK: - Hörzustand aus der Wiedergabe

extension AppModel: PlaybackObserver {

    public func playbackStateChanged(_ state: PlaybackState) {
        playerState = state
        switch state {
        case .failed(let reason):
            lastError = reason
            playerPlan = nil
        case .finished:
            offerClosure(ending: .completedPlan, for: playerPlan)
            playerPlan = nil
            playerPosition = .zero
        case .idle:
            playerPlan = nil
            playerPosition = .zero
        default:
            break
        }
    }

    public func playbackProgressed(segmentIndex: Int, position: MediaTime) {
        playerPosition = position
    }

    /// **Hier schliesst sich der Kreis.**
    ///
    /// Der Player meldet, was tatsächlich erklungen ist; der Store macht
    /// daraus die Wahrheit über den Hörzustand. Ohne diese Methode wäre die
    /// gesamte Intervalllogik korrekt und tot: sie würde nie aufgerufen, und
    /// jede persönliche Ausgabe böte dieselben Stellen wieder an.
    public func segmentCompleted(
        segmentIndex: Int, heard: MediaTimeRange, mediaVersionID: MediaVersionID
    ) {
        let route = player.activePlan?.route ?? .originalEpisode
        sessionListened = sessionListened + heard.duration
        Task { await recordHeard(heard, in: mediaVersionID, via: route) }
    }

    /// Der Quellenwechsel wird angesagt.
    ///
    /// Wer nur hört, merkt sonst nur, dass Stimme und Aufnahmequalität
    /// wechseln — ohne zu erfahren, woher das Neue stammt. Genau das wollte
    /// die App vermeiden.
    public func willChangeSource(to segment: PlanSegment) {
        AccessibilityNotification.Announcement(
            "Nächste Stelle: \(segment.episodeTitle), aus \(segment.sourceTitle)"
        ).post()
    }

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

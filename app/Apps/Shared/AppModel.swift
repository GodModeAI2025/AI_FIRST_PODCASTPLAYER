//
//  AppModel.swift
//  PodcastAI
//
//  Der gemeinsame Zustand beider Apps. Ein Composition Root, kein
//  Singleton-Netz: die Dienste werden hier einmal gebaut und nach unten
//  gereicht.
//

import Foundation
import Security
import Observation
import SwiftUI
import PodcastAIKit

@MainActor
@Observable
public final class AppModel {

    // MARK: - Zustand für die Oberfläche

    public internal(set) var sources: [Source] = []
    public internal(set) var relevantToday: [RelevantItem] = []
    public internal(set) var smartFeeds: [SmartPodcastFeed] = []
    public internal(set) var editions: [SmartFeedID: [PersonalEpisode]] = [:]
    public internal(set) var profile = InterestProfile()
    public internal(set) var ledger = ListeningLedger()
    public internal(set) var modelStatus = ModelStatus(
        onDevice: .unavailable(.modelNotReady),
        privateCloudCompute: .unavailable(.userConsentMissing)
    )

    /// Was gerade passiert. Eine Zeile, die der Nutzer lesen kann — keine
    /// unendliche Fortschrittsanzeige ohne Aussage.
    public internal(set) var highlights: [Highlight] = []
    public internal(set) var activity: String?
    public internal(set) var lastError: String?

    /// Offen, wenn der Nutzer eine Quelle hinzufügen will. Steht hier und
    /// nicht in einer Ansicht, weil auf dem Mac das Menü es öffnet und das
    /// Fenster es zeigt — zwei verschiedene Stellen.
    public var isAddingSource = false
    /// Audio-Podcasts, die zu einem YouTube-Kanal passen, je Quelle.
    public var podcastCounterparts: [SourceID: [PodcastCounterpart]] = [:]

    /// Spielt ganze Folgen mit Kapiteln.
    public let episodePlayer = EpisodePlayer()
    /// Was als Nächstes gehört wird. Am Ende einer Folge startet die nächste.
    public internal(set) var upNext: [Episode] = [] {
        didSet { UserDefaults.standard.set(upNext.map(\.id.rawValue), forKey: "upNextEpisodeIDs") }
    }
    /// Was als Nächstes erschlossen wird. Die Spracherkennung verträgt nur
    /// eine Analyse zur Zeit, deshalb läuft alles über diese Warteschlange.
    public internal(set) var analysisQueue: [Episode] = []
    public internal(set) var analyzing: Episode?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    public internal(set) var lastRefresh: Date?

    /// Neue Folgen von selbst erschliessen, damit Wissen, „Für dich“ und
    /// die Themen-Updates gefüllt sind, bevor man danach sucht. Abschaltbar,
    /// weil es Daten, Akku und Zeit kostet.
    public var automaticAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(automaticAnalysis, forKey: Self.automaticAnalysisKey)
            if automaticAnalysis { Task { await prepareNewEpisodes() } }
        }
    }
    /// Wie viele Folgen je Quelle die App von sich aus vorbereitet.
    public static let automaticAnalysisPerSource = 3
    static let automaticAnalysisKey = "automaticAnalysis"
    @ObservationIgnored var analyzedEpisodes: Set<EpisodeID> = []
    /// Von der App selbst eingereihte Folgen. Ihre Fehler unterbrechen
    /// niemanden: wer nicht darum gebeten hat, will dafür keinen Dialog.
    @ObservationIgnored private var automaticallyQueued: Set<EpisodeID> = []
    /// Kann dieses Gerät gar nicht transkribieren, hört die App von selbst
    /// auf, es zu versuchen, statt Folge um Folge zu laden.
    public internal(set) var preparationUnavailable: String?

    /// Apples Server-Modell auf Private Cloud Compute für Antworten und
    /// Vergleiche nutzen, wenn das Gerät und die App es dürfen. Die Daten
    /// verlassen dabei das Gerät, werden aber nicht gespeichert.
    public var allowPrivateCloudCompute: Bool {
        didSet {
            UserDefaults.standard.set(allowPrivateCloudCompute, forKey: Self.privateCloudKey)
            Task { await refreshModelStatus() }
        }
    }
    static let privateCloudKey = "allowPrivateCloudCompute"

    /// Fakten je Folge, wie sie die Folgenansicht, der Chat und der Export zeigen.
    public internal(set) var facts: [EpisodeID: [EpisodeFact]] = [:]
    public internal(set) var factsInProgress: Set<EpisodeID> = []
    /// Zählt hoch, wenn sich der belegte Speicher ändert; Ansichten lesen
    /// danach die Grösse neu.
    public internal(set) var mediaStorageChanged = 0
    /// Bisherige Antworten, neueste zuerst. Bleiben beim Wechsel zwischen
    /// Ansichten erhalten.
    public var chatAnswers: [ChatAnswer] = []
    /// Wie die Datenbank abgeglichen wird, für die Einstellungen.
    public var syncDescription = "Nur auf diesem Gerät"

    // MARK: - Löschen während laufender Arbeit (genutzt in AppModel+Knowledge.swift)

    /// Zählt Löschvorgänge. Eine Arbeit merkt sich beim Start den Stand und
    /// erkennt daran, ob ihre Folge gelöscht wurde, während sie lief. Eine
    /// Arbeit, die erst nach dem Löschen beginnt (etwa nach erneutem
    /// Abonnieren), ist davon nicht betroffen.
    @ObservationIgnored var removalCount = 0
    /// Wann eine Quelle abbestellt wurde, als Stand von `removalCount`.
    @ObservationIgnored var removedSourceTickets: [SourceID: Int] = [:]
    /// Gelöschte Folge und Stand des Zählers bei ihrer Löschung.
    @ObservationIgnored var removalTickets: [EpisodeID: Int] = [:]
    /// Die laufende Erschliessung einer einzelnen Folge. Löschen bricht nur
    /// sie ab, die übrige Warteschlange läuft weiter.
    @ObservationIgnored var pipelineRun: Task<Void, Error>?
    @ObservationIgnored var pipelineEpisodeID: EpisodeID?

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
        // Voreingestellt an: ohne vorbereitete Folgen bleibt „Für dich“ leer,
        // und die App wirkt, als könne sie nichts.
        self.automaticAnalysis = UserDefaults.standard.object(forKey: Self.automaticAnalysisKey) as? Bool ?? true
        self.allowPrivateCloudCompute = UserDefaults.standard.object(forKey: Self.privateCloudKey) as? Bool ?? true
        self.deviceID = deviceID
        self.policy = PlaybackPolicy(deviceID: deviceID)
        let locator = LocalMediaLocator()
        self.player = PlaybackCoordinator(locator: locator)
        self.refresher = FeedRefresher(store: store)
        // Erst diese Zeile macht aus dem Player einen, der den Hörzustand
        // fortschreibt. Ohne sie läuft die Wiedergabe, und nichts davon
        // kommt je im Ledger an.
        self.player.setObserver(self)
        episodePlayer.onHeard = { [weak self] range, mediaID in
            Task { await self?.recordHeard(range, in: mediaID, via: .originalEpisode) }
        }
        episodePlayer.onFinished = { [weak self] episode in
            self?.playNextInQueue(after: episode)
        }
        // Eine Folge und ein Fokus-Plan klingen nie gleichzeitig. Startet die
        // Folge über irgendeinen Weg (Knopf, Menü, Sperrbildschirm), endet
        // der Plan.
        episodePlayer.onWillResume = { [weak self] in
            guard let self, self.playerPlan != nil else { return }
            self.stopPlayback()
        }
        // Solange ein Plan besteht, gehören ihm Sperrbildschirm und Tasten.
        episodePlayer.focusRemote = EpisodePlayer.FocusRemote(
            current: { [weak self] in self?.focusNowPlaying },
            pause: { [weak self] in self?.pausePlayback() },
            resume: { [weak self] in self?.resumePlayback() }
        )
    }

    /// Der Zustand des Players, gespiegelt für die Oberfläche.
    ///
    /// `PlaybackCoordinator.state` ist keine beobachtbare Eigenschaft — eine
    /// SwiftUI-Ansicht, die sie liest, aktualisiert sich nicht. Deshalb hier.
    public internal(set) var playerState: PlaybackState = .idle
    /// Position innerhalb des laufenden Abschnitts, für die Fortschrittsanzeige.
    public internal(set) var playerPosition: MediaTime = .zero
    /// Der laufende Plan, gespiegelt. Ansichten lesen ihn hier, nicht am
    /// Koordinator — sonst zeigen sie beim Start nichts und beim Ende noch
    /// immer den alten Plan.
    public internal(set) var playerPlan: ValidatedPlaybackPlan?
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
        if DemoContent.isRequested { await DemoContent.seed(into: store) }
        // Nach einem iCloud-Abgleich können Datensätze doppelt vorliegen.
        // Wurde dabei eine gelöschte Folge endgültig bereinigt, geht auch
        // ihre Audiodatei.
        if let report = try? await store.removeDuplicatesWithReport(), !report.mediaVersionIDs.isEmpty {
            LocalMediaLocator.removeFiles(for: report.mediaVersionIDs)
            mediaStorageChanged += 1
        }
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
            modelStatus = ModelStatusProbe.current(allowPrivateCloud: allowPrivateCloudCompute)
            // Was schon erschlossen ist, steht in der Datenbank. Ohne diesen
            // Abgleich sah nach jedem Start alles unbearbeitet aus.
            analyzedEpisodes = try await store.analyzedEpisodeIDs()
            if upNext.isEmpty, let saved = UserDefaults.standard.stringArray(forKey: "upNextEpisodeIDs"),
               !saved.isEmpty {
                let found = try await store.episodes(ids: saved.map(EpisodeID.init(rawValue:)))
                let byID = Dictionary(found.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
                upNext = saved.compactMap { byID[$0] }
            }
            // Alle Folgen im Speicher halten: Chat, Warteschlange und das
            // Vorbereiten brauchen sie, nicht nur die gerade geöffnete Liste.
            for source in sources {
                let list = try await store.episodes(forSource: source.id)
                episodes[source.id] = list
                RemoteMediaRegistry.shared.register(list)
            }
            for id in analyzedEpisodes where stages[id] == nil {
                stages[id] = .evidenceExtracted
            }
        } catch {
            lastError = UserFacingError.describe(error)
        }
        // Auf einem anderen Gerät Gelöschtes auch hier entfernen: Audiodateien,
        // „Als Nächstes“, Warteschlange und gemerkte Stellen.
        await forgetEpisodesRemovedElsewhere()
        await refreshRelevantToday()
    }

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
                    relevance: match.personalRelevance(),
                    episodeID: item.episodeID,
                    mediaVersionID: item.mediaVersionID
                ))
            }
            relevantToday = items
            refreshSuggestions(from: evidence)
        } catch {
            lastError = UserFacingError.describe(error)
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
            for source in sources where source.kind == .youTubeChannel && podcastCounterparts[source.id] == nil {
                await findPodcastCounterparts(for: source)
            }
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    /// Sucht zu einem YouTube-Kanal den Audio-Podcast desselben Anbieters.
    public func findPodcastCounterparts(for source: Source) async {
        guard source.kind == .youTubeChannel else { return }
        let name = source.author?.isEmpty == false ? source.author! : source.title
        let found = await PodcastDirectory.counterparts(forChannel: name)
        // Bereits abonnierte Feeds nicht noch einmal anbieten.
        let subscribed = Set(sources.compactMap(\.feedURL))
        podcastCounterparts[source.id] = found.filter { !subscribed.contains($0.feedURL) }
    }

    public func refreshAll() async {
        activity = "Feeds werden aktualisiert …"
        defer { activity = nil }
        lastRefresh = Date()
        defer { Task { await prepareNewEpisodes() } }
        do {
            let result = try await refresher.refreshAll()
            sources = try await store.sources()
            activity = result.newEpisodes > 0
                ? "\(result.newEpisodes) neue Folgen"
                : "Keine neuen Folgen"
        } catch {
            lastError = UserFacingError.describe(error)
        }
        await refreshRelevantToday()
    }

    // MARK: - Folgen erschliessen

    public internal(set) var episodes: [SourceID: [Episode]] = [:]
    /// Welche Folge gerade in welcher Stufe steckt. Die Oberfläche zeigt
    /// damit an, wo die Arbeit steht — statt einer Anzeige ohne Aussage.
    public internal(set) var stages: [EpisodeID: ProcessingStage] = [:]
    public internal(set) var stageDetails: [EpisodeID: String] = [:]

    public func loadEpisodes(for sourceID: SourceID) async {
        do {
            episodes[sourceID] = try await store.episodes(forSource: sourceID)
            RemoteMediaRegistry.shared.register(episodes[sourceID] ?? [])
            await prepareNewEpisodes(in: sourceID)
        } catch {
            lastError = UserFacingError.describe(error)
        }
        if let source = sources.first(where: { $0.id == sourceID }),
           source.kind == .youTubeChannel, podcastCounterparts[sourceID] == nil {
            await findPodcastCounterparts(for: source)
        }
    }

    /// Bereitet neue Folgen von selbst vor.
    ///
    /// Die App transkribiert die jüngsten Folgen jeder Quelle mit Zeitmarken,
    /// damit „Für dich“, die Suche und die Themen-Updates etwas zu arbeiten
    /// haben, sobald man sie öffnet. Ältere Folgen bleiben liegen, bis
    /// jemand sie anfordert.
    public func prepareNewEpisodes(in sourceID: SourceID? = nil) async {
        guard automaticAnalysis, preparationUnavailable == nil else { return }
        let ids = sourceID.map { [$0] } ?? sources.map(\.id)
        for id in ids {
            let list = episodes[id] ?? []
            let candidates = list
                .filter { $0.audioURL != nil && $0.canBeAnalyzed }
                .filter { !analyzedEpisodes.contains($0.id) }
                .filter { stages[$0.id] == nil }
                .prefix(Self.automaticAnalysisPerSource)
            for episode in candidates { enqueueAnalysis(episode, automatic: true) }
        }
    }

    /// Erschliesst eine Folge: laden, transkribieren, Belege bilden.
    public func analyze(_ episode: Episode, audioURL: URL, locale explicitLocale: Locale? = nil) async {
        enqueueAnalysis(episode)
    }

    /// Stellt eine Folge in die Warteschlange der Erschliessung.
    public func enqueueAnalysis(_ episode: Episode, automatic: Bool = false) {
        if automatic {
            guard preparationUnavailable == nil else { return }
            automaticallyQueued.insert(episode.id)
        } else {
            automaticallyQueued.remove(episode.id)
            // Von Hand angefordert heisst: auch auf einem Gerät ohne
            // Spracherkennung darf man es erneut versuchen.
            preparationUnavailable = nil
        }
        guard episode.audioURL != nil,
              analyzing?.id != episode.id,
              !analysisQueue.contains(where: { $0.id == episode.id }) else { return }
        analysisQueue.append(episode)
        stages[episode.id] = nil
        stageDetails[episode.id] = "wartet"
        startAnalysisWorker()
    }

    public func removeFromAnalysisQueue(_ episodeID: EpisodeID) {
        analysisQueue.removeAll { $0.id == episodeID }
        stageDetails[episodeID] = nil
    }

    public func moveAnalysisQueue(from offsets: IndexSet, to destination: Int) {
        analysisQueue.move(fromOffsets: offsets, toOffset: destination)
    }

    private func startAnalysisWorker() {
        guard analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let background = BackgroundContinuation.begin(title: self.analysisQueue.first?.title ?? "")
            var retried: Set<EpisodeID> = []
            while let next = self.analysisQueue.first {
                self.analysisQueue.removeFirst()
                // Ohne Lücke: was nicht mehr wartet, läuft schon.
                self.analyzing = next
                background.setSubtitle(next.title)
                let transientFailure = await self.runAnalysis(next, background: background)
                if transientFailure, !retried.contains(next.id) {
                    retried.insert(next.id)
                    self.analysisQueue.append(next)
                    self.stageDetails[next.id] = "wartet auf zweiten Versuch"
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            background.end()
            self.analysisTask = nil
            self.analyzing = nil
            self.activity = nil
        }
    }

    /// Erschliesst eine Folge. Gibt `true` zurück, wenn der Fehler
    /// vorübergehend war und ein zweiter Versuch lohnt.
    private func runAnalysis(_ episode: Episode, background: BackgroundContinuation) async -> Bool {
        guard let audioURL = episode.audioURL else { return false }
        // Gleich als laufend vormerken, vor dem ersten `await`. Der Worker hat
        // die Folge schon aus der Warteschlange genommen. Ohne diese Zeile
        // stünde sie während der Prüfung unten nirgends, `enqueueAnalysis`
        // reihte sie ein zweites Mal ein, und das Abbestellen ihrer Quelle
        // fände sie nicht.
        analyzing = episode
        // Stand der Löschungen beim Start. Wird die Folge währenddessen
        // gelöscht, darf nichts von ihr zurückkommen.
        let ticket = removalCount
        // Inzwischen gelöscht, hier oder auf einem anderen Gerät: überspringen.
        let live = try? await store.episodes(ids: [episode.id])
        if live?.isEmpty == true || wasRemoved(episode.id, since: ticket) {
            analyzing = nil
            stages[episode.id] = nil
            stageDetails[episode.id] = nil
            return false
        }
        // Die Folge wird in ihrer eigenen Sprache transkribiert, nicht in der
        // des Geräts. Ohne Angabe im Feed bleibt es bei der Gerätesprache.
        let feedLanguage = sources.first(where: { $0.id == episode.sourceID })?.language
        let locale = feedLanguage.map { Locale(identifier: $0) } ?? .current
        stages[episode.id] = .discovered
        stageDetails[episode.id] = nil
        background.update(.discovered)
        let remaining = analysisQueue.count
        activity = remaining > 0
            ? "„\(episode.title)“ wird erschlossen, danach noch \(remaining) …"
            : "„\(episode.title)“ wird erschlossen …"

        let pipeline = ContentPipeline(
            store: store,
            mediaDirectory: LocalMediaLocator.mediaDirectory,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    // Eine gelöschte Folge taucht nicht wieder unter „Erschliessen“ auf.
                    guard let self, !self.wasRemoved(progress.episodeID, since: ticket) else { return }
                    self.stages[progress.episodeID] = progress.stage
                    // Nach dem Download ändert sich der belegte Speicher.
                    if progress.stage == .mediaDownloaded { self.mediaStorageChanged += 1 }
                    if let detail = progress.detail {
                        self.stageDetails[progress.episodeID] = detail
                    }
                    background.update(progress.stage)
                }
            }
        )
        // Als eigene Aufgabe, damit Löschen genau diese Folge abbrechen kann.
        let run = Task {
            _ = try await pipeline.process(
                episode: episode, audioURL: audioURL,
                sourceID: episode.sourceID, locale: locale
            )
        }
        pipelineRun = run
        pipelineEpisodeID = episode.id
        defer {
            pipelineRun = nil
            pipelineEpisodeID = nil
        }
        do {
            try await run.value
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode)
                return false
            }
            analyzedEpisodes.insert(episode.id)
            automaticallyQueued.remove(episode.id)
            await refreshRelevantToday()
            // Fakten gleich mit ermitteln, solange die Folge frisch ist.
            await prepareFacts(for: episode, removalTicket: ticket)
            return false
        } catch {
            // Abgebrochen, weil gelöscht: kein zweiter Versuch, nur aufräumen.
            if wasRemoved(episode.id, since: ticket) {
                await purgeLateWrites(of: episode)
                return false
            }
            if UserFacingError.isTransient(error) {
                stages[episode.id] = nil
                return true
            }
            stages[episode.id] = .failed
            let message = UserFacingError.describe(error)
            stageDetails[episode.id] = message
            let wasAutomatic = automaticallyQueued.remove(episode.id) != nil
            // Kann das Gerät überhaupt nicht transkribieren, hat es keinen
            // Sinn, die nächsten Folgen trotzdem zu laden.
            if case TranscriptionError.speechUnavailableOnDevice = error {
                preparationUnavailable = message
                for waiting in analysisQueue where automaticallyQueued.contains(waiting.id) {
                    stageDetails[waiting.id] = nil
                }
                analysisQueue.removeAll { automaticallyQueued.contains($0.id) }
                automaticallyQueued.removeAll()
            }
            // Nur selbst angeforderte Arbeit meldet sich mit einem Dialog.
            if !wasAutomatic { lastError = "„\(episode.title)“: \(message)" }
            return false
        }
    }

    // MARK: - Interessen

    @discardableResult
    public func addInterest(_ label: String, kind: InterestKind) async -> InterestID? {
        let interest = Interest(label: label, kind: kind, origin: .confirmedByUser)
        do {
            try await store.upsert(interest: interest)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
            return interest.id
        } catch {
            lastError = UserFacingError.describe(error)
            return nil
        }
    }

    public func removeInterest(_ id: InterestID) async {
        do {
            try await store.removeInterest(id)
            profile = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    // MARK: - Wiedergabe

    /// Startet einen Hörplan. Der einzige Weg von der Oberfläche zum Ton.
    public func play(_ plan: ValidatedPlaybackPlan, from trigger: PlayTrigger) {
        episodePlayer.pause()
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
            episodePlayer.refreshNowPlaying()
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    public enum PlayTrigger { case tap, chat, intent }

    // Die Oberfläche steuert den Ton ausschließlich über diese vier Wege.
    // `PlaybackCoordinator` ist nicht beobachtbar; ein direkter Aufruf aus
    // einer Ansicht änderte den Zustand, ohne dass die Ansicht davon erfährt.
    public func pausePlayback() { player.pause() }
    public func resumePlayback() {
        // Eine laufende Folge hält an, bevor der Plan weiterspielt.
        if episodePlayer.isPlaying { episodePlayer.pause() }
        player.resume()
    }

    /// Was ein Fokus-Plan am Sperrbildschirm zeigt, solange er besteht.
    var focusNowPlaying: EpisodePlayer.FocusNowPlaying? {
        guard let plan = playerPlan else { return nil }
        let index: Int
        let playing: Bool
        switch playerState {
        case .playing(let value), .preparing(let value):
            index = value
            playing = true
        case .paused(let value):
            index = value
            playing = false
        default:
            return nil
        }
        guard index < plan.segments.count else { return nil }
        let segment = plan.segments[index]
        return EpisodePlayer.FocusNowPlaying(
            title: segment.episodeTitle, artist: segment.sourceTitle,
            album: plan.requestSummary, isPlaying: playing
        )
    }
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
            lastError = UserFacingError.describe(error)
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

    func saveHighlights() { persistHighlights() }

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
            lastError = UserFacingError.describe(error)
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
            note: note, capturedVia: route, mediaVersionID: mediaVersionID
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

        let titleByEpisode = Dictionary(
            episodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let titleBySource = Dictionary(
            sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        // Der Exporter schlägt Titel je Beleg nach, nicht je Quelle.
        var episodeTitles: [EvidenceID: String] = [:]
        var sourceTitles: [EvidenceID: String] = [:]
        for evidence in found.values {
            episodeTitles[evidence.id] = titleByEpisode[evidence.episodeID]
            sourceTitles[evidence.id] = titleBySource[evidence.sourceID]
        }

        let exporter = MarkdownExporter()
        return highlights.compactMap { highlight -> String? in
            guard let evidence = found[highlight.evidenceID] else {
                // Notiz aus dem Player oder Folge gelöscht: Kopie statt Beleg.
                return Self.snapshotMarkdown(highlight)
            }
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
            lastError = UserFacingError.describe(error)
        }
    }

    public func clearError() { lastError = nil }

    // MARK: - Ganze Folgen

    /// Spielt eine ganze Folge ab einer Stelle. Liegt sie schon geladen vor,
    /// kommt der Ton aus der Datei, sonst aus dem Stream.
    public func playEpisode(_ episode: Episode, at seconds: Double? = nil) {
        if playerPlan != nil { stopPlayback() }
        let start = seconds ?? resumePosition(for: episode)
        let local = episode.streamMediaVersionID.flatMap { LocalMediaLocator().localFile(for: $0) }
        episodePlayer.play(episode, at: start, localFile: local)
        upNext.removeAll { $0.id == episode.id }
        Task { await loadChapters(for: episode) }
    }

    /// Springt aus „Für dich“ an die Stelle in der ganzen Folge.
    public func playRelevantItemInEpisode(_ item: RelevantItem) {
        Task {
            let episodeID: EpisodeID?
            if let known = item.episodeID {
                episodeID = known
            } else {
                episodeID = (try? await store.evidence(ids: [item.id]))?[item.id]?.episodeID
            }
            guard let episodeID,
                  let episode = (try? await store.episodes(ids: [episodeID]))?.first else {
                playRelevantItem(item)
                return
            }
            playEpisode(episode, at: item.range.start.seconds)
        }
    }

    /// Wo eine Folge weitergeht: an der zuletzt gehörten Stelle. Wurde die
    /// Folge hier noch nie gespielt, hilft der Hörzustand weiter, sofern er
    /// am Anfang ansetzt.
    public func resumePosition(for episode: Episode) -> Double {
        // Die echte Länge, sobald die Folge geladen ist. Die Angabe im Feed
        // fehlt manchmal oder ist zu lang.
        let loaded = episodePlayer.episode?.id == episode.id ? episodePlayer.duration : 0
        let total = loaded > 0 ? loaded : (episode.declaredDuration?.seconds ?? 0)
        let saved = episodePlayer.savedPosition(for: episode.id)
        // Zuerst der Hörzustand: er kommt über iCloud auch von den anderen Geräten.
        if let id = episode.streamMediaVersionID, let resume = ledger.state(for: id).resumePosition {
            let seconds = resume.seconds
            if total > 0 && seconds > total - 15 { return 0 }
            // Hier zu Ende gehört (die gemerkte Stelle steht dann auf 0), und
            // das Letzte, was lief, war das Ende des Gehörten: wieder von vorn.
            // Das greift auch ohne bekannte Länge. Hat ein anderes Gerät die
            // Folge danach neu begonnen, liegt die Stelle weiter vorn und gilt.
            if saved == 0, let frontier = ledger.heard(in: id).ranges.last?.end.seconds,
               seconds >= frontier - 15 {
                return 0
            }
            return seconds
        }
        if let saved { return saved }
        guard let id = episode.streamMediaVersionID else { return 0 }
        let heard = ledger.heard(in: id)
        guard let first = heard.ranges.first, first.start.milliseconds < 5_000 else { return 0 }
        let end = first.end.seconds
        return total > 0 && end > total - 15 ? 0 : end
    }

    /// Anteil der Folge, der schon gehört ist, zwischen 0 und 1.
    public func heardFraction(for episode: Episode) -> Double {
        guard let id = episode.streamMediaVersionID,
              let total = episode.declaredDuration?.seconds, total > 0 else { return 0 }
        return min(1, ledger.heard(in: id).totalDuration.seconds / total)
    }

    /// Ist diese Stelle schon gehört?
    public func hasHeard(_ range: MediaTimeRange, in mediaVersionID: MediaVersionID) -> Bool {
        ledger.heard(in: mediaVersionID).covers(range, threshold: 0.8)
    }

    public func addToUpNext(_ episode: Episode) {
        guard !upNext.contains(where: { $0.id == episode.id }) else { return }
        upNext.append(episode)
    }

    public func removeFromUpNext(_ episodeID: EpisodeID) {
        upNext.removeAll { $0.id == episodeID }
    }

    public func moveUpNext(from offsets: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: offsets, toOffset: destination)
    }

    private func playNextInQueue(after episode: Episode) {
        guard let next = upNext.first else { return }
        playEpisode(next, at: 0)
    }

    /// Kapitel aus einer eigenen Datei nachladen, wenn der Feed nur darauf verweist.
    public func loadChapters(for episode: Episode) async {
        if !episode.publisherChapters.isEmpty {
            // Die Detailansicht ruft das für jede Folge auf. Kapitel einer
            // anderen Folge gehören nicht in den Player.
            if episodePlayer.episode?.id == episode.id { episodePlayer.setChapters(episode.publisherChapters) }
            return
        }
        guard let url = episode.chaptersURL,
              let chapters = await refresher.loadChapters(from: url), !chapters.isEmpty else { return }
        chapterCache[episode.id] = chapters
        if episodePlayer.episode?.id == episode.id { episodePlayer.setChapters(chapters) }
    }

    public internal(set) var chapterCache: [EpisodeID: [Chapter]] = [:]

    public func evidence(forEpisode episodeID: EpisodeID) async -> [Evidence] {
        (try? await store.evidence(forEpisode: episodeID)) ?? []
    }

    // MARK: - Automatisch aktualisieren

    /// Aktualisiert die Feeds, wenn der letzte Lauf länger als eine
    /// Viertelstunde her ist. Läuft beim Start, beim Wechsel in den
    /// Vordergrund und alle 30 Minuten, solange die App offen ist.
    public func refreshIfStale(olderThan interval: TimeInterval = 15 * 60) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval { return }
        guard !sources.isEmpty else { return }
        await refreshAll()
    }
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
        // Sperrbildschirm und Tasten folgen dem Plan, und nach seinem Ende
        // wieder der Folge.
        episodePlayer.refreshNowPlaying()
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

    /// Eine zufällige Kennung je Gerät, ohne Hardwarekennung zu erheben.
    ///
    /// Sie liegt im Schlüsselbund mit „nur dieses Gerät“. Ein Backup nimmt
    /// sie deshalb nicht auf ein anderes Gerät mit. In den Einstellungen
    /// würde sie mitreisen, und zwei Geräte schrieben dann in dieselbe
    /// Hörstand-Zeile, von der CloudKit nur die letzte Änderung behält.
    /// Eine Notiz ohne gespeicherten Beleg als Markdown, aus ihrer Kopie.
    static func snapshotMarkdown(_ highlight: Highlight) -> String {
        var lines = ["## " + (highlight.note ?? "Gemerkte Stelle")]
        var meta: [String] = []
        if let episode = highlight.episodeTitle { meta.append(episode) }
        if let source = highlight.sourceTitle { meta.append(source) }
        if let ms = highlight.positionMs { meta.append(MediaTime(milliseconds: Int64(ms)).timecode) }
        meta.append(highlight.capturedAt.formatted(date: .abbreviated, time: .shortened))
        lines.append("*" + meta.joined(separator: " · ") + "*")
        if let quote = highlight.quote { lines.append("> " + quote) }
        return lines.joined(separator: "\n\n")
    }

    public static func currentDeviceID() -> String {
        let service = "com.godmodeai.podcastai.device"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let existing = String(data: data, encoding: .utf8) {
            return existing
        }
        let generated = UUID().uuidString
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(generated.utf8),
        ]
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return generated }
        // Ohne Schlüsselbund (etwa in einer ungewöhnlichen Umgebung) bleibt die
        // Kennung für diesen Start stabil, gilt aber nicht dauerhaft.
        return fallbackDeviceID
    }

    private static let fallbackDeviceID = UUID().uuidString
}

/// Ein für den Nutzer relevanter Abschnitt, wie er auf „Für dich“ erscheint.
public struct RelevantItem: Identifiable, Sendable {
    public let id: EvidenceID
    public let sourceTitle: String
    public let episodeTitle: String
    public let range: MediaTimeRange
    public let excerpt: String
    public let relevance: PersonalRelevance?
    public let episodeID: EpisodeID?
    public let mediaVersionID: MediaVersionID?

    public init(id: EvidenceID, sourceTitle: String, episodeTitle: String,
                range: MediaTimeRange, excerpt: String, relevance: PersonalRelevance?,
                episodeID: EpisodeID? = nil, mediaVersionID: MediaVersionID? = nil) {
        self.id = id; self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.range = range; self.excerpt = excerpt; self.relevance = relevance
        self.episodeID = episodeID; self.mediaVersionID = mediaVersionID
    }
}

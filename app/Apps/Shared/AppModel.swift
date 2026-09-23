//
//  AppModel.swift
//  PodcastAI
//
//  Der gemeinsame Zustand beider Apps. Ein Composition Root, kein
//  Singleton-Netz: die Dienste werden hier einmal gebaut und nach unten
//  gereicht.
//

import Foundation
import NaturalLanguage
import Network
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
    /// Steht, sobald `load()` einmal durch ist. Vorher heisst „nicht
    /// gefunden“ nur „noch nicht gelesen“.
    public internal(set) var isLoaded = false

    /// Neue Folgen von selbst erschliessen, damit Wissen, „Für dich“ und
    /// die Themen-Updates gefüllt sind, bevor man danach sucht. Abschaltbar,
    /// weil es Daten, Akku und Zeit kostet.
    public var automaticAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(automaticAnalysis, forKey: Self.automaticAnalysisKey)
            if automaticAnalysis {
                Task { await prepareNewEpisodes() }
            } else {
                // Ausgeschaltet heisst auch: was schon von selbst wartet, lädt
                // nicht mehr. Was gerade läuft, läuft zu Ende.
                dropAutomaticallyQueued { _ in true }
            }
        }
    }
    /// Wie viele der jüngsten Folgen je Quelle die App von sich aus vorbereitet.
    public var episodesPerSource: Int {
        didSet {
            UserDefaults.standard.set(episodesPerSource, forKey: Self.episodesPerSourceKey)
            if episodesPerSource < oldValue {
                // Weniger gewählt: was nicht mehr zu den jüngsten zählt, fällt heraus.
                let keep = Set(episodes.values.flatMap { newestCandidates(in: $0).map(\.id) })
                dropAutomaticallyQueued { !keep.contains($0.id) }
            }
            Task { await prepareNewEpisodes() }
        }
    }
    public static let episodesPerSourceChoices = [1, 3, 5, 10]
    static let automaticAnalysisKey = "automaticAnalysis"
    static let episodesPerSourceKey = "episodesPerSource"
    static let wifiOnlyKey = "preparationOnWiFiOnly"
    /// Von selbst nur im WLAN laden. Was man selbst anfordert, lädt immer.
    public var preparationOnWiFiOnly: Bool {
        didSet {
            UserDefaults.standard.set(preparationOnWiFiOnly, forKey: Self.wifiOnlyKey)
            networkChanged(networkLimit)
        }
    }
    /// Was das Netz gerade einschränkt: kein Netz, Datensparmodus, Hotspot
    /// oder Mobilfunk. `nil` heisst WLAN ohne Datenlimit.
    public private(set) var networkLimit: NetworkLimit?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Kein Netz. Dann spielt nur, was auf dem Gerät liegt.
    public var isOffline: Bool { networkLimit == .offline }
    /// Warum automatisch Eingereihtes gerade wartet, oder `nil`, wenn es
    /// laufen darf. Den Datensparmodus achtet die App immer, Mobilfunk und
    /// Hotspot nur mit „Nur im WLAN“.
    public var preparationWait: NetworkLimit? {
        switch networkLimit {
        case .offline, .lowDataMode: networkLimit
        case .hotspot, .cellular: preparationOnWiFiOnly ? networkLimit : nil
        case nil: nil
        }
    }

    /// Die Einschränkungen des Netzes, die das Vorbereiten anhalten.
    public enum NetworkLimit: Equatable, Sendable {
        case offline, lowDataMode, hotspot, cellular

        /// Kurz, für die Warteschlange und die Folge.
        public var queueDetail: String {
            switch self {
            case .offline: String(localized: "wartet auf Netz")
            case .lowDataMode: String(localized: "wartet, Datensparmodus ist an")
            case .hotspot: String(localized: "Hotspot erkannt, wartet auf WLAN ohne Datenlimit")
            case .cellular: String(localized: "wartet auf WLAN")
            }
        }

        /// Für die Einstellungen und das Aktivitätssymbol.
        public var settingsLabel: String {
            switch self {
            case .offline: String(localized: "Kein Netz, Laden und Transkripte warten")
            case .lowDataMode: String(localized: "Datensparmodus ist an, Laden und Transkripte warten")
            case .hotspot: String(localized: "Hotspot erkannt, wartet auf WLAN ohne Datenlimit")
            case .cellular: String(localized: "Wartet auf WLAN")
            }
        }

        public var symbol: String { self == .offline ? "wifi.slash" : "wifi.exclamationmark" }

        /// Liest den Pfad des Systems. Ein teures WLAN ist fast immer der
        /// Hotspot eines Telefons.
        nonisolated static func of(_ path: NWPath) -> NetworkLimit? {
            // `requiresConnection` gilt nicht als offline: ein Verbindungsaufbau
            // kann das Netz erst wecken.
            if path.status == .unsatisfied { return .offline }
            if path.isConstrained { return .lowDataMode }
            guard path.isExpensive else { return nil }
            return path.usesInterfaceType(.wifi) ? .hotspot : .cellular
        }
    }
    @ObservationIgnored var analyzedEpisodes: Set<EpisodeID> = []
    /// Von der App selbst eingereihte Folgen. Ihre Fehler unterbrechen
    /// niemanden: wer nicht darum gebeten hat, will dafür keinen Dialog.
    @ObservationIgnored private var automaticallyQueued: Set<EpisodeID> = []
    /// Aus der Warteschlange genommen. Das Vorbereiten reiht sie nicht wieder
    /// ein, erst ein ausdrückliches Anfordern.
    @ObservationIgnored private var dismissedFromPreparation = StoredEpisodeIDs(key: "dismissedFromPreparation")

    /// Nach dem Auswerten nur Transkript, Fakten und Notizen behalten.
    /// Abgespielt wird danach aus dem Netz.
    public var removeAudioAfterAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(removeAudioAfterAnalysis, forKey: Self.removeAfterAnalysisKey)
            if removeAudioAfterAnalysis { Task { await tidyLocalAudio() } }
        }
    }
    /// Gehörte Folgen einen Tag nach dem letzten Hören vom Gerät nehmen.
    public var removeHeardAudio: Bool {
        didSet {
            UserDefaults.standard.set(removeHeardAudio, forKey: Self.removeHeardKey)
            if removeHeardAudio { Task { await tidyLocalAudio() } }
        }
    }
    static let removeAfterAnalysisKey = "removeAudioAfterAnalysis"
    static let removeHeardKey = "removeHeardAudioAfterDay"
    /// Folgen, deren Audio gerade für unterwegs geladen wird.
    public internal(set) var downloading: Set<EpisodeID> = []
    /// Ausdrücklich für unterwegs geladen. Das Aufräumen lässt diese Dateien
    /// liegen, nach dem Auswerten genauso wie nach dem Hören.
    @ObservationIgnored var keptOffline = StoredEpisodeIDs(key: "keptOfflineEpisodes")
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
    static let learningEnabledKey = "suggestInterests"
    static let rejectedSuggestionsKey = "com.podcastai.rejectedSuggestions"
    static let dismissedRelevantKey = "com.podcastai.dismissedRelevant"
    /// Gibt es abgelehnte Vorschläge, die „Vorschläge zurücksetzen“
    /// vergessen kann? Gespiegelt, damit der Knopf sich aktualisiert.
    public private(set) var hasRejectedSuggestions =
        !(UserDefaults.standard.stringArray(forKey: AppModel.rejectedSuggestionsKey) ?? []).isEmpty

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
    public var syncDescription = String(localized: "Nur auf diesem Gerät")

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

    /// Tauscht nur `replaceStore(_:)`, wenn der Speicher beim Start nicht
    /// aufging und ein zweiter Versuch gelingt.
    @ObservationIgnored public private(set) var store: LibraryStore
    public let policy: PlaybackPolicy
    public let player: PlaybackCoordinator
    /// Eine Instanz für die ganze App. Der Einwilligungsschalter und der
    /// Indexlauf müssen denselben Zustand sehen.
    public let spotlight = SpotlightIndex()

    @ObservationIgnored var refresher: FeedRefresher
    private let deviceID: String

    public init(store: LibraryStore, deviceID: String = AppModel.currentDeviceID()) {
        self.store = store
        // Voreingestellt an: ohne vorbereitete Folgen bleibt „Für dich“ leer,
        // und die App wirkt, als könne sie nichts.
        self.automaticAnalysis = UserDefaults.standard.object(forKey: Self.automaticAnalysisKey) as? Bool ?? true
        self.allowPrivateCloudCompute = UserDefaults.standard.object(forKey: Self.privateCloudKey) as? Bool ?? true
        let perSource = UserDefaults.standard.integer(forKey: Self.episodesPerSourceKey)
        self.episodesPerSource = perSource > 0 ? perSource : 3
        self.preparationOnWiFiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true
        // Beide an: der Text bleibt, der Ton kommt bei Bedarf aus dem Netz.
        self.removeAudioAfterAnalysis = UserDefaults.standard.object(forKey: Self.removeAfterAnalysisKey) as? Bool ?? true
        self.removeHeardAudio = UserDefaults.standard.object(forKey: Self.removeHeardKey) as? Bool ?? true
        // Der Schalter „Interessen vorschlagen“ gilt über den Neustart hinaus.
        // Jedes Neuladen des Profils reicht den Wert von hier weiter.
        self.profile = InterestProfile(learningEnabled: UserDefaults.standard.bool(forKey: Self.learningEnabledKey))
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
        episodePlayer.onFinished = { [weak self] _ in
            self?.playNextInQueue()
        }
        // Kopfhörer und Lenkrad: „Nächster Titel“ nimmt die nächste Folge
        // aus „Als Nächstes“. Das ist ein Tastendruck, keine Empfehlung.
        episodePlayer.onNextTrack = { [weak self] in
            self?.playNextInQueue() ?? false
        }
        episodePlayer.nowPlayingDetails = { [weak self] episode in
            let source = self?.sources.first { $0.id == episode.sourceID }
            return (source?.title, episode.artworkURL ?? source?.artworkURL)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let limit = NetworkLimit.of(path)
            Task { @MainActor in self?.networkChanged(limit) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "PodcastAI.network"))
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

    /// Der erste Ladevorgang, einmal je Prozess.
    @ObservationIgnored private var initialLoad: Task<Void, Never>?

    /// Lädt den Bestand, falls das noch niemand getan hat, und wartet darauf.
    ///
    /// Startet Siri oder ein Kurzbefehl die beendete App im Hintergrund,
    /// verbindet sich keine Szene, und das `.task` des Fensters läuft nie.
    /// Ohne diesen Aufruf fänden die Intents keinen einzigen Themenfeed.
    /// Fenster und Intents teilen sich denselben Vorgang, statt doppelt zu
    /// laden. Das Neuladen nach einem Abgleich ruft weiter `load()` direkt.
    public func ensureLoaded() async {
        if let initialLoad {
            await initialLoad.value
            return
        }
        let task = Task { await self.load() }
        initialLoad = task
        await task.value
    }

    public func load() async {
        if DemoContent.isRequested { await DemoContent.seed(into: store) }
        // Nach einem iCloud-Abgleich können Datensätze doppelt vorliegen.
        // Wurde dabei eine gelöschte Folge endgültig bereinigt, geht auch
        // ihre Audiodatei.
        if let report = try? await store.removeDuplicatesWithReport(), !report.mediaVersionIDs.isEmpty {
            LocalMediaLocator.removeFiles(for: report.mediaVersionIDs)
            mediaStorageChanged += 1
        }
        let knownHighlights = highlights
        do {
            sources = try await store.sources()
            try await reloadProfile()
            ledger = try await store.ledger()
            // Was der Nutzer selbst angelegt hat. Bis eben lag das alles
            // nur im Speicher und war beim nächsten Start verschwunden.
            smartFeeds = try await store.smartFeeds()
            editions = try await store.editions()
            highlights = try await store.highlights()
            // Die Systemsuche zeigt den Stand der Datenbank, auch für Notizen,
            // die ein anderes Gerät angelegt, geändert oder gelöscht hat. Beim
            // Start immer: was sich getan hat, während die App zu war, weiss
            // sonst niemand.
            if !isLoaded || highlights != knownHighlights { reindexSpotlight() }
            trails = try await store.trails()
            modelStatus = ModelStatusProbe.current(allowPrivateCloud: allowPrivateCloudCompute)
            // Was schon erschlossen ist, steht in der Datenbank. Ohne diesen
            // Abgleich sah nach jedem Start alles unbearbeitet aus.
            analyzedEpisodes = try await store.analyzedEpisodeIDs()
            if upNext.isEmpty, let saved = UserDefaults.standard.stringArray(forKey: "upNextEpisodeIDs"),
               !saved.isEmpty {
                let found = try await store.episodes(ids: saved.map(EpisodeID.init(rawValue:)))
                let byID = Dictionary(found.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
                // Folgen ohne Ton (YouTube) hielten die Warteschlange nur auf.
                upNext = saved.compactMap { byID[$0] }.filter(canPlay)
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
        restoreLastEpisode()
        await refreshRelevantToday()
        await tidyLocalAudio()
        isLoaded = true
    }

    /// Wechselt auf einen Speicher, der sich erst im zweiten Versuch öffnen
    /// liess, und liest alles neu. Was bis dahin im flüchtigen Speicher lag,
    /// war nie gesichert und geht dabei verloren.
    public func replaceStore(_ newStore: LibraryStore) async {
        store = newStore
        refresher = FeedRefresher(store: newStore)
        episodes = [:]
        // Ein neuer Speicher ist ein neuer Start.
        restoreAttempted = false
        await load()
    }

    /// Hat der Start die letzte Folge schon einmal bereitgelegt? `load()`
    /// läuft auch nach jedem iCloud-Abgleich. Ohne diese Sperre käme eine
    /// Folge, die jemand gerade gestoppt hat, von selbst zurück in den
    /// Mini-Player und an den Sperrbildschirm.
    @ObservationIgnored private var restoreAttempted = false

    /// Legt nach dem Start die zuletzt gehörte Folge pausiert in den
    /// Mini-Player und an den Sperrbildschirm. Es klingt nichts (Regel 1):
    /// weiter geht es erst, wenn jemand auf Abspielen tippt oder die Taste
    /// am Kopfhörer drückt. Einmal je Start, nicht nach jedem Abgleich.
    private func restoreLastEpisode() {
        guard !restoreAttempted else { return }
        restoreAttempted = true
        // Ein UI-Test mit leerem Speicher beginnt ohne Reste vom letzten Lauf.
        guard !ProcessInfo.processInfo.arguments.contains("-uitest-fresh"),
              episodePlayer.episode == nil, playerPlan == nil,
              let episode = continueListening.first?.episode, canPlay(episode) else { return }
        episodePlayer.restore(episode, at: resumePosition(for: episode), localFile: localAudioFile(for: episode))
        Task { await loadChapters(for: episode) }
    }

    /// Angefangene Folgen, zuletzt gestartete zuerst, mit der Stelle zum Weiterhören.
    public var continueListening: [(episode: Episode, position: Double)] {
        let byID = Dictionary(episodes.values.joined().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entries: [(episode: Episode, position: Double)] = episodePlayer.recentEpisodeIDs.compactMap { id in
            guard let episode = byID[id], let position = episodePlayer.savedPosition(for: id),
                  position > 5 else { return nil }
            return (episode, position)
        }
        return Array(entries.prefix(3))
    }

    /// Neue Folgen der letzten sieben Tage über alle Abos, noch nicht angefangen.
    public var freshEpisodes: [Episode] {
        let since = Date().addingTimeInterval(-7 * 86_400)
        let started = Set(episodePlayer.recentEpisodeIDs)
        return episodes.values.joined()
            .filter { ($0.publishedAt ?? .distantPast) > since && !started.contains($0.id) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    /// So viele Stellen mit Zeitmarke lesen „Für dich“, die Vorschläge, der
    /// Chat und die Gegenpositionen. Die Voreinstellung des Speichers liefert
    /// nur 500, und zwar die ältesten. Nach gut einem Dutzend Folgen mit
    /// Transkript fiele alles Neue heraus.
    static let evidencePoolLimit = 20_000

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
            let evidence = try await store.evidenceForAnalyzedEpisodes(limit: Self.evidencePoolLimit)
            // Vorschläge entstehen aus dem Gehörten, auch wenn noch kein
            // eigenes Thema trifft. Gerade dann helfen sie am meisten.
            refreshSuggestions(from: evidence)
            let matches = RelevanceScorer().score(evidence: evidence, profile: profile)
            guard !matches.isEmpty else {
                relevantToday = []
                return
            }

            let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let titles = try await store.titles(
                forEpisodes: Array(Set(evidence.map(\.episodeID))))

            // Was der Nutzer als „Nicht relevant“ aussortiert hat, bleibt weg.
            var seen = dismissedRelevant
            var items: [RelevantItem] = []
            // Der beste Treffer je Beleg gewinnt: ein Beleg, der zu drei
            // Themen passt, erscheint einmal, nicht dreimal.
            for match in matches.sorted(by: { $0.score > $1.score }) {
                guard !seen.contains(match.evidenceID.rawValue) else { continue }
                guard let item = byID[match.evidenceID], let range = item.range else { continue }
                // `unheardPortion` statt eines nackten Abdeckungsvergleichs:
                // es berücksichtigt auch ausdrücklich Übersprungenes und
                // verwirft Reststücke, die zu kurz für Inhalt sind.
                guard !ledger.unheardPortion(of: range, in: item.mediaVersionID).isEmpty
                else { continue }
                seen.insert(match.evidenceID.rawValue)
                let title = titles[item.episodeID]
                items.append(RelevantItem(
                    id: item.id,
                    sourceTitle: title?.source ?? String(localized: "Unbekannter Podcast"),
                    episodeTitle: title?.episode ?? String(localized: "Unbekannte Folge"),
                    range: range,
                    excerpt: item.quotedText,
                    relevance: match.personalRelevance(),
                    episodeID: item.episodeID,
                    mediaVersionID: item.mediaVersionID,
                    publishedAt: title?.publishedAt,
                    mentioned: match.matchedTerms
                ))
            }
            relevantToday = items
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
        activity = String(localized: "Link wird geprüft …")
        defer { activity = nil }
        do {
            let added = try await subscribe(to: input)
            // Die Zahl mit passendem Wort für sich, der Titel ausserhalb:
            // `AttributedString(localized:)` liest Markdown und schluckte
            // sonst Zeichen wie * oder _ aus dem Namen des Podcasts.
            let found = String(AttributedString(localized: "^[\(added.episodeCount) Folge](inflect: true) gefunden").characters)
            activity = String(localized: "„\(added.title)“ abonniert · \(found)")
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    /// Abonniert und meldet Fehler an den Aufrufer, damit das Blatt offen
    /// bleiben und den Grund zeigen kann.
    ///
    /// Danach stehen die Folgen der neuen Quelle gleich im Speicher. Sonst
    /// sähen „Neu in deinen Abos“ und das automatische Vorbereiten sie erst,
    /// wenn jemand die Quelle öffnet oder die App neu startet.
    @discardableResult
    public func subscribe(to input: String) async throws -> AddedSource {
        let known = Set(sources.map(\.id))
        let added = try await refresher.addSource(from: input)
        sources = try await store.sources()
        pruneSubscribedCounterparts(input: input)
        AccessibilityNotification.Announcement(String(localized: "Podcast abonniert: \(added.title)")).post()
        for source in sources where source.kind == .youTubeChannel && podcastCounterparts[source.id] == nil {
            await findPodcastCounterparts(for: source)
        }
        // Neue Quellen und die, in die eine einzelne Folge gelegt wurde.
        for source in sources where !known.contains(source.id) || source.title == added.title {
            await loadEpisodes(for: source.id)
        }
        return added
    }

    /// Ist dieser Feed schon abonniert?
    public func isSubscribed(_ feed: URL) -> Bool {
        sources.contains { $0.feedURL == feed }
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
        activity = String(localized: "Podcasts werden aktualisiert …")
        defer { activity = nil }
        lastRefresh = Date()
        do {
            let result = try await refresher.refreshAll()
            sources = try await store.sources()
            // Die neuen Folgen stehen jetzt in der Datenbank. Erst mit den
            // frischen Listen sehen „Neu in deinen Abos“, die offene
            // Folgenliste und das Vorbereiten sie.
            await reloadEpisodeLists()
            activity = result.newEpisodes > 0
                ? String(AttributedString(localized: "^[\(result.newEpisodes) neue Folge](inflect: true)").characters)
                : String(localized: "Keine neuen Folgen")
        } catch {
            lastError = UserFacingError.describe(error)
        }
        await prepareNewEpisodes()
        await refreshRelevantToday()
        await tidyLocalAudio()
        // Neue Folgen können ein Themen-Update füllen. Ohne zu warten: das
        // Ziehen zum Aktualisieren soll nicht auf das Zusammenstellen warten.
        Task { await processPendingEditions() }
    }

    /// Liest die Folgenlisten aller Quellen neu aus der Datenbank.
    func reloadEpisodeLists() async {
        for id in sources.map(\.id) {
            guard let list = try? await store.episodes(forSource: id),
                  // Während des Lesens abbestellt: nicht wieder eintragen.
                  sources.contains(where: { $0.id == id }) else { continue }
            episodes[id] = list
            RemoteMediaRegistry.shared.register(list)
        }
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
            // Erst die jüngsten N, dann filtern. Umgekehrt rückte nach jeder
            // fertigen Folge die nächstältere nach, bis durchs ganze Archiv.
            let candidates = newestCandidates(in: episodes[id] ?? [])
                .filter { !analyzedEpisodes.contains($0.id) }
                .filter { stages[$0.id] == nil }
                .filter { !dismissedFromPreparation.contains($0.id) }
            for episode in candidates { enqueueAnalysis(episode, automatic: true) }
        }
    }

    /// Die jüngsten Folgen einer Quelle, die das Vorbereiten von selbst nimmt.
    private func newestCandidates(in list: [Episode]) -> ArraySlice<Episode> {
        list.filter { $0.audioURL != nil && $0.canBeAnalyzed }.prefix(episodesPerSource)
    }

    /// Nimmt von selbst Eingereihtes wieder aus der Warteschlange.
    private func dropAutomaticallyQueued(where shouldDrop: (Episode) -> Bool) {
        let dropped = Set(analysisQueue.filter { automaticallyQueued.contains($0.id) && shouldDrop($0) }.map(\.id))
        guard !dropped.isEmpty else { return }
        analysisQueue.removeAll { dropped.contains($0.id) }
        for id in dropped {
            automaticallyQueued.remove(id)
            stageDetails[id] = nil
        }
    }

    /// Netz gewechselt. Im WLAN ohne Datenlimit läuft Wartendes weiter,
    /// sonst bleibt automatisch Eingereihtes stehen und sagt, warum.
    func networkChanged(_ limit: NetworkLimit?) {
        networkLimit = limit
        let detail = preparationWait?.queueDetail ?? Self.waitingDetail
        for episode in analysisQueue where automaticallyQueued.contains(episode.id) {
            stageDetails[episode.id] = detail
        }
        if preparationWait == nil, !analysisQueue.isEmpty { startAnalysisWorker() }
    }

    /// Darf diese Folge jetzt laufen? Automatisch Eingereihtes wartet, solange
    /// das Netz es nicht erlaubt. Von Hand Angefordertes läuft immer.
    func mayRunNow(_ episode: Episode) -> Bool {
        !(preparationWait != nil && automaticallyQueued.contains(episode.id))
    }

    /// Wie viele Folgen der Warteschlange jetzt laufen dürfen.
    public var runnableQueueCount: Int { analysisQueue.filter(mayRunNow).count }

    /// Erschliesst eine Folge: laden, transkribieren, Belege bilden.
    public func analyze(_ episode: Episode, audioURL: URL, locale explicitLocale: Locale? = nil) async {
        enqueueAnalysis(episode)
    }

    /// Stellt eine Folge in die Warteschlange der Erschliessung.
    public func enqueueAnalysis(_ episode: Episode, automatic: Bool = false) {
        let queued = analysisQueue.firstIndex { $0.id == episode.id }
        if automatic {
            // Schon eingereiht oder in Arbeit: so bleibt es. Sonst würde aus
            // einer Folge, die jemand angefordert hat, eine, die aufs WLAN wartet.
            guard preparationUnavailable == nil, queued == nil, analyzing?.id != episode.id else { return }
            automaticallyQueued.insert(episode.id)
        } else {
            automaticallyQueued.remove(episode.id)
            dismissedFromPreparation.remove(episode.id)
            // Von Hand angefordert heisst: auch auf einem Gerät ohne
            // Spracherkennung darf man es erneut versuchen.
            preparationUnavailable = nil
            // Wartet die Folge schon, etwa von selbst eingereiht aufs WLAN,
            // läuft sie jetzt als Nächste.
            if let queued {
                analysisQueue.insert(analysisQueue.remove(at: queued), at: 0)
                stageDetails[episode.id] = Self.waitingDetail
                startAnalysisWorker()
                return
            }
        }
        guard episode.audioURL != nil,
              analyzing?.id != episode.id,
              !analysisQueue.contains(where: { $0.id == episode.id }) else { return }
        analysisQueue.append(episode)
        stages[episode.id] = nil
        stageDetails[episode.id] = automatic ? preparationWait?.queueDetail ?? Self.waitingDetail : Self.waitingDetail
        startAnalysisWorker()
    }

    /// „wartet“ in der Warteschlange. Der Schlüssel bleibt genau „wartet“:
    /// Ansichten vergleichen die Angabe damit.
    static var waitingDetail: String { String(localized: "wartet", comment: "Zustand einer Folge in der Warteschlange") }

    /// „Entfernen“ in der Warteschlange, also eine Entscheidung des Nutzers.
    public func removeFromAnalysisQueue(_ episodeID: EpisodeID) {
        // Wer eine Folge herausnimmt, will sie nicht beim nächsten
        // Aktualisieren wieder in der Warteschlange sehen.
        let wasQueued = analysisQueue.contains { $0.id == episodeID }
        dropFromAnalysisQueue(episodeID)
        if wasQueued { dismissedFromPreparation.insert(episodeID) }
    }

    /// Nimmt eine Folge aus der Warteschlange, ohne sich das als Wunsch zu
    /// merken. Für Löschen und Abbestellen: die Folge ist weg, und wer die
    /// Quelle später wieder abonniert, bekommt ihre neuesten Folgen wieder
    /// vorbereitet. Darum fällt auch ein früheres „Entfernen“ weg.
    func dropFromAnalysisQueue(_ episodeID: EpisodeID) {
        dismissedFromPreparation.remove(episodeID)
        automaticallyQueued.remove(episodeID)
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
            while let index = self.analysisQueue.firstIndex(where: { self.mayRunNow($0) }) {
                let next = self.analysisQueue.remove(at: index)
                // Ohne Lücke: was nicht mehr wartet, läuft schon.
                self.analyzing = next
                background.setSubtitle(next.title)
                let transientFailure = await self.runAnalysis(next, background: background)
                if transientFailure, !retried.contains(next.id) {
                    retried.insert(next.id)
                    self.analysisQueue.append(next)
                    self.stageDetails[next.id] = String(localized: "wartet auf zweiten Versuch")
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            background.end()
            self.analysisTask = nil
            self.analyzing = nil
            self.activity = nil
            // Frisch ausgewertetes Material ist genau das, worauf die
            // automatischen Themen-Updates warten.
            await self.processPendingEditions()
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
        if remaining > 0 {
            // Zahl und Wort für sich, der Titel ausserhalb des Markdowns.
            let more = String(AttributedString(localized: "^[\(remaining) Folge](inflect: true)").characters)
            activity = String(localized: "Transkript für „\(episode.title)“ wird erstellt, danach noch \(more) …")
        } else {
            activity = String(localized: "Transkript für „\(episode.title)“ wird erstellt …")
        }

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
            // Nur was jemand selbst angefordert hat, wird angesagt. Das
            // automatische Vorbereiten spräche sonst Folge um Folge dazwischen.
            if automaticallyQueued.remove(episode.id) == nil {
                AccessibilityNotification.Announcement(String(localized: "Transkript fertig: \(episode.title)")).post()
            }
            await removeAudioAfterAnalysisIfWanted(episode)
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
            if !wasAutomatic { lastError = String(localized: "„\(episode.title)“: \(message)") }
            return false
        }
    }

    // MARK: - Interessen

    /// Lädt das Profil aus der Datenbank und behält die Vorschläge.
    ///
    /// Vorschläge liegen nur im Speicher. Ohne diesen Schritt verschwänden
    /// sie, sobald jemand ein Thema anlegt, ändert oder löscht. Ein
    /// Vorschlag, den inzwischen ein bestätigtes Interesse gleichen Namens
    /// abdeckt, fällt weg.
    func reloadProfile() async throws {
        let suggested = profile.suggested
        var reloaded = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        let confirmedLabels = Set(reloaded.confirmed.map { $0.label.lowercased() })
        for interest in suggested where !confirmedLabels.contains(interest.label.lowercased()) {
            reloaded.add(interest)
        }
        profile = reloaded
    }

    /// Legt ein Interesse an. „Für dich“ rechnet danach gleich neu, damit
    /// ein neues Thema sofort seine Stellen zeigt.
    @discardableResult
    public func addInterest(_ label: String, kind: InterestKind) async -> InterestID? {
        let interest = Interest(label: label, kind: kind, origin: .confirmedByUser)
        do {
            try await store.upsert(interest: interest)
            try await reloadProfile()
        } catch {
            lastError = UserFacingError.describe(error)
            return nil
        }
        await refreshRelevantToday()
        return interest.id
    }

    /// Bezeichnung und Stichworte ändern. „Für dich“ rechnet danach neu.
    public func updateInterest(_ interest: Interest) async {
        do {
            try await store.upsert(interest: interest)
            try await reloadProfile()
        } catch {
            lastError = UserFacingError.describe(error)
            return
        }
        await refreshRelevantToday()
    }

    /// Verwandte Wörter aus der Wort-Einbettung des Systems, deutsch und
    /// englisch. Läuft auf dem Gerät und ist nur ein Vorschlag.
    public static func keywordSuggestions(for label: String, existing: [String]) -> [String] {
        let taken = Set(([label] + existing).map { $0.lowercased() })
        let words = label.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        var result: [String] = []
        for language in [NLLanguage.german, .english] {
            guard let embedding = NLEmbedding.wordEmbedding(for: language) else { continue }
            for word in words where embedding.contains(word) {
                for (neighbor, distance) in embedding.neighbors(for: word, maximumCount: 8) where distance < 1.0 {
                    let candidate = neighbor.lowercased()
                    guard candidate.count >= 3, !taken.contains(candidate), !result.contains(candidate),
                          !words.contains(candidate) else { continue }
                    result.append(candidate)
                }
            }
        }
        return Array(result.prefix(10))
    }

    public func removeInterest(_ id: InterestID) async {
        do {
            try await store.removeInterest(id)
            try await reloadProfile()
        } catch {
            lastError = UserFacingError.describe(error)
        }
        await refreshRelevantToday()
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

        // Weiterführend ist, was zu denselben Interessen ausgewertet ist und
        // in dieser Sitzung nicht vorkam. Stand Gehörtes unter „Für dich“,
        // zählen nur dessen Interessen, sonst alle. Die Karte bekommt die
        // Kennungen selbst: „Vertiefen“ spielt genau diese Stellen, und
        // „drei weitere Stellen“ heisst drei Stellen.
        let heardEvidence = Set(plan.segments.map(\.evidenceID))
        let sessionInterests = Set(relevantToday
            .filter { heardEvidence.contains($0.id) }
            .compactMap { $0.relevance?.interestID })
        let followUps = relevantToday.filter { item in
            guard !heardEvidence.contains(item.id) else { return false }
            guard !sessionInterests.isEmpty else { return true }
            return item.relevance.map { sessionInterests.contains($0.interestID) } ?? false
        }

        pendingClosure = SessionClosure(
            question: plan.requestSummary,
            supportingEvidenceIDs: Array(heardEvidence),
            followUpEvidenceIDs: Array(followUps.prefix(Self.followUpLimit).map(\.id)),
            startedAt: plan.createdAt
        )
    }

    /// Höchstens so viele Stellen plant „Vertiefen“. Das Zeitbudget der
    /// Karte kürzt ohnehin, mehr Kandidaten machen die Zahl nur grösser.
    static let followUpLimit = 12

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
        title: String, topicIDs: [InterestID], minutes: Int, sourceIDs: [SourceID] = []
    ) -> SmartFeedID {
        let feed = SmartPodcastFeed(
            title: title, topicIDs: topicIDs, restrictedToSourceIDs: sourceIDs,
            editionMode: .budgeted(MediaDuration(minutes: minutes))
        )
        smartFeeds.append(feed)
        persistSmartFeeds()
        return feed.id
    }

    /// Übernimmt Name, Themen, Länge und Quellen eines Themenfeeds.
    ///
    /// Bereits erschienene Ausgaben bleiben, wie sie sind. Die Änderung
    /// gilt ab der nächsten.
    public func updateSmartFeed(_ feed: SmartPodcastFeed) {
        guard let index = smartFeeds.firstIndex(where: { $0.id == feed.id }) else { return }
        var updated = feed
        updated.policyRevision = smartFeeds[index].policyRevision.next()
        smartFeeds[index] = updated
        // Die letzte Rückmeldung galt für die alten Themen.
        editionNotes[feed.id] = nil
        persistSmartFeeds()
    }

    /// Löscht einen Themenfeed mit allen seinen Ausgaben. Die Folgen, aus
    /// denen sie bestanden, und der Hörstand bleiben unberührt.
    public func removeSmartFeed(_ feedID: SmartFeedID) {
        smartFeeds.removeAll { $0.id == feedID }
        editions[feedID] = nil
        editionNotes[feedID] = nil
        persistSmartFeeds()
        Task { await persist { try await $0.save(editions: [], forFeed: feedID) } }
    }

    /// Löscht eine einzelne Ausgabe.
    public func removeEdition(_ episode: PersonalEpisode) {
        editions[episode.feedID]?.removeAll { $0.id == episode.id }
        persistEditions(for: episode.feedID)
    }

    /// Nimmt aus allen Ausgaben, was aus gelöschten Folgen oder
    /// abbestellten Quellen stammt (Regel 5: „Folge löschen“ entfernt
    /// alles, was aus ihr entstanden ist). Eine Ausgabe ohne übrige Stelle
    /// verschwindet ganz.
    func pruneEditions(removedEpisodes: Set<EpisodeID>, removedSources: Set<SourceID> = []) {
        guard !removedEpisodes.isEmpty || !removedSources.isEmpty else { return }
        let publisher = PersonalEpisodePublisher()
        for (feedID, list) in editions {
            var changed = false
            let kept = list.compactMap { episode -> PersonalEpisode? in
                let result = publisher.removingSegments(from: episode) { segment in
                    removedEpisodes.contains(segment.episodeID)
                        || removedSources.contains(segment.sourceID)
                }
                if result?.segments.count != episode.segments.count { changed = true }
                return result
            }
            guard changed else { continue }
            editions[feedID] = kept
            persistEditions(for: feedID)
        }
        // Eine abbestellte Quelle grenzt kein Themen-Update mehr ein. War sie
        // die letzte gewählte, bleibt die Auswahl aber stehen: leer hiesse
        // „alle Podcasts“, und das Update holte sich still Stellen von
        // überall. So entsteht keine Ausgabe, bis jemand andere Podcasts
        // wählt oder die alten wieder abonniert.
        guard !removedSources.isEmpty else { return }
        var feedsChanged = false
        for index in smartFeeds.indices
        where smartFeeds[index].restrictedToSourceIDs.contains(where: removedSources.contains) {
            let remaining = smartFeeds[index].restrictedToSourceIDs.filter { !removedSources.contains($0) }
            guard !remaining.isEmpty else {
                editionNotes[smartFeeds[index].id] = Self.unsubscribedScopeNote
                continue
            }
            smartFeeds[index].restrictedToSourceIDs = remaining
            feedsChanged = true
        }
        if feedsChanged { persistSmartFeeds() }
    }

    /// Ist das Themen-Update auf Podcasts beschränkt, von denen keiner mehr
    /// abonniert ist?
    private func hasOnlyUnsubscribedSources(_ feed: SmartPodcastFeed) -> Bool {
        let live = Set(sources.map(\.id))
        return !feed.restrictedToSourceIDs.isEmpty && !feed.restrictedToSourceIDs.contains(where: live.contains)
    }

    static var unsubscribedScopeNote: String {
        String(localized: """
            Die Podcasts, auf die dieses Themen-Update beschränkt ist, sind abbestellt. \
            Wähle beim Bearbeiten andere aus oder abonniere sie wieder.
            """)
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
        // Ohne Einwilligung gibt es nichts zu melden und nichts zu lesen.
        guard spotlight.isEnabled else { return }
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
            lastError = String(localized: "Konnte nicht gesichert werden: \(error.localizedDescription)")
        }
    }

    /// Themenfeeds, für die gerade eine Ausgabe entsteht. Die Oberfläche
    /// zeigt daran „wird zusammengestellt“, statt fertig und leer zu wirken.
    public internal(set) var buildingFeeds: Set<SmartFeedID> = []
    /// Die letzte Rückmeldung je Themenfeed, als Satz für die Oberfläche.
    public internal(set) var editionNotes: [SmartFeedID: String] = [:]

    /// Stellt eine neue Ausgabe zusammen. Startet ausdrücklich keinen Ton.
    ///
    /// `requestedByUser` ist der Normalfall: jemand hat getippt oder Siri
    /// gefragt. Dann gilt die Mindestmenge der Automatik nicht, und die
    /// Aktivitätszeile zeigt, dass gearbeitet wird. Der automatische Lauf
    /// arbeitet still.
    @discardableResult
    public func buildEdition(
        feedID: SmartFeedID, budget: MediaDuration? = nil, requestedByUser: Bool = true
    ) async -> String {
        guard var feed = smartFeeds.first(where: { $0.id == feedID }) else {
            return String(localized: "Dieses Themen-Update gibt es nicht.")
        }
        // Zweimal gleichzeitig ergäbe zwei fast gleiche Ausgaben.
        guard !buildingFeeds.contains(feedID) else {
            return String(localized: "Die Ausgabe wird gerade zusammengestellt.")
        }
        // Sonst stünde hier „noch keine Folge mit Transkript“, und niemand
        // wüsste, dass nur die Auswahl der Podcasts fehlt. Auch beim
        // automatischen Lauf: nach einem Neustart oder auf einem anderen
        // Gerät ist das der einzige Weg, auf dem der Hinweis erscheint.
        guard !hasOnlyUnsubscribedSources(feed) else {
            let note = Self.unsubscribedScopeNote
            editionNotes[feedID] = note
            return note
        }
        if let budget { feed.editionMode = .budgeted(budget) }

        buildingFeeds.insert(feedID)
        if requestedByUser { activity = String(localized: "Ausgabe wird zusammengestellt …") }
        defer {
            buildingFeeds.remove(feedID)
            if requestedByUser { activity = nil }
        }
        let note = await composeEdition(for: feed, requestedByUser: requestedByUser)
        // Die Automatik überschreibt keine Rückmeldung, um die jemand gebeten
        // hat, ausser sie hat tatsächlich etwas veröffentlicht.
        if requestedByUser || note.published { editionNotes[feedID] = note.text }
        return note.text
    }

    private func composeEdition(
        for feed: SmartPodcastFeed, requestedByUser: Bool
    ) async -> (text: String, published: Bool) {
        let feedID = feed.id
        do {
            let pipeline = ContentPipeline(
                store: store, mediaDirectory: LocalMediaLocator.mediaDirectory
            )
            // Titel mitgeben, statt sie in der Ausgabe durch „Quelle“ und
            // „Folge“ zu ersetzen. Eine Ausgabe, die ihre eigenen
            // Bestandteile nicht benennen kann, ist kein Podcast — und die
            // Shownotes sind die Stelle, an der das auffällt.
            let known = try await store.evidenceForAnalyzedEpisodes(limit: Self.evidencePoolLimit)
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
                existingBatchKeys: existing, requestedByUser: requestedByUser
            )

            switch outcome {
            case .published(let episode):
                // Während des Zusammenstellens gelöscht: nichts anlegen.
                guard smartFeeds.contains(where: { $0.id == feedID }) else {
                    return (String(localized: "Dieses Themen-Update gibt es nicht mehr."), false)
                }
                editions[feedID, default: []].insert(episode, at: 0)
                persistEditions(for: feedID)
                // Die Zählung für sich, der Titel ausserhalb des Markdowns.
                let content = String(AttributedString(localized: """
                    ^[\(episode.segments.count) Stelle](inflect: true) aus \
                    ^[\(episode.distinctSourceCount) Podcast](inflect: true)
                    """).characters)
                return (String(localized: "\(episode.title): \(content)."), true)
            case .noNewMaterial(let count):
                return (count == 0
                    ? String(localized: "Zu diesen Themen gibt es noch keine Folge mit Transkript.")
                    : String(localized: "Nichts Neues. Alle passenden Stellen hast du schon gehört."), false)
            case .belowThreshold(let available, let required):
                // Von Hand angefordert gilt keine Mindestmenge. Dann passt
                // nur keine einzelne Stelle in die gewählte Länge.
                if requestedByUser {
                    return (String(localized: "Keine passende Stelle ist kurz genug für \(feed.editionMode.label)."), false)
                }
                return (String(localized: """
                    Erst \(available.shortDescription) neues Material, \
                    nötig sind \(required.shortDescription).
                    """), false)
            case .alreadyPublished:
                return (String(localized: "Seit der letzten Ausgabe ist nichts dazugekommen."), false)
            }
        } catch {
            // Die Automatik meldet sich nicht mit einem Dialog. Wer nicht
            // gefragt hat, will dafür keinen.
            if requestedByUser { lastError = UserFacingError.describe(error) }
            return (String(localized: "Die Ausgabe konnte nicht erstellt werden."), false)
        }
    }

    // MARK: - Wissen

    /// Merkt sich die gerade laufende Stelle, für Kurzbefehl und Fokus-Player.
    ///
    /// Derselbe Weg wie „Moment merken“ im Player: die Folge wird aus der
    /// Medienfassung aufgelöst, und die Notiz trägt Zitat, Folge, Quelle und
    /// Zeitmarke selbst. Wer die Folge schon kennt, etwa aus dem laufenden
    /// Plan-Abschnitt, gibt `episodeID` mit.
    @discardableResult
    public func rememberPassage(
        at position: MediaTime, in mediaVersionID: MediaVersionID,
        episodeID: EpisodeID? = nil, note: String?, via route: Highlight.CaptureRoute
    ) async -> String {
        let segment = playerPlan?.segments.first { $0.mediaVersionID == mediaVersionID && $0.range.contains(position) }
            ?? playerPlan?.segments.first { $0.mediaVersionID == mediaVersionID }
        if let episode = await episode(playing: mediaVersionID, id: episodeID ?? segment?.episodeID),
           let highlight = await addNote(note, at: position.seconds, in: episode,
                                         mediaVersionID: mediaVersionID, via: route) {
            let time = MediaTime(milliseconds: Int64(highlight.positionMs ?? 0)).timecode
            return String(localized: "Gemerkt: \(time) in „\(episode.title)“.")
        }
        // Die Folge ist nicht mehr da. Was der Plan über sie weiss, bleibt
        // als Kopie, damit die Notiz nicht leer ist.
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = HighlightCapture().range(around: position, limit: nil)
        let highlight = Highlight(
            evidenceID: Evidence.stableID(
                mediaVersionID: mediaVersionID, transcriptRevision: .initial, range: range
            ),
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed, capturedVia: route,
            mediaVersionID: mediaVersionID, episodeID: episodeID ?? segment?.episodeID,
            episodeTitle: segment?.episodeTitle, sourceTitle: segment?.sourceTitle,
            positionMs: Int(max(0, position.milliseconds))
        )
        highlights.insert(highlight, at: 0)
        persistHighlights()
        return String(localized: "Gemerkt: \(position.timecode).")
    }

    /// Die Folge zu einer Medienfassung, die gerade klingt: über die
    /// bekannte Kennung, den Folgen-Player oder die geladenen Folgen.
    private func episode(playing mediaVersionID: MediaVersionID, id: EpisodeID?) async -> Episode? {
        if let playing = episodePlayer.episode,
           playing.id == id || (id == nil && playing.streamMediaVersionID == mediaVersionID) {
            return playing
        }
        let known = id ?? episodes.values.joined().first { $0.streamMediaVersionID == mediaVersionID }?.id
        guard let known else { return nil }
        return (try? await store.episodes(ids: [known]))?.first
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
            lastError = String(localized: "Zu dieser Antwort lässt sich nichts abspielen.")
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
    ///
    /// Der Schalter wird gespeichert. Eingeschaltet leitet die App gleich
    /// aus dem bisher Gehörten ab, statt auf die nächste Folge zu warten.
    public func setLearningEnabled(_ enabled: Bool) {
        profile.learningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.learningEnabledKey)
        if enabled {
            Task { await refreshRelevantToday() }
        } else {
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
        if profile.learningEnabled { Task { await refreshRelevantToday() } }
    }

    /// Gibt es etwas, das „Vorschläge zurücksetzen“ verwerfen kann?
    public var canResetSuggestions: Bool {
        !profile.suggested.isEmpty || hasRejectedSuggestions
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
        get { Set(UserDefaults.standard.stringArray(forKey: Self.rejectedSuggestionsKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.rejectedSuggestionsKey)
            hasRejectedSuggestions = !newValue.isEmpty
        }
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
                statement: highlight.note ?? Self.rememberedPassageTitle,
                evidenceIDs: [highlight.evidenceID],
                provenance: highlight.note == nil ? .original : .user
            )
            return exporter.export(ExportableInsight(
                title: highlight.note ?? Self.rememberedPassageTitle,
                claim: claim, evidence: [evidence],
                userNote: highlight.note,
                sourceTitles: sourceTitles, episodeTitles: episodeTitles
            ))
        }
        .joined(separator: "\n\n")
    }

    /// Überschrift einer gemerkten Stelle ohne eigene Notiz, im Export.
    nonisolated static var rememberedPassageTitle: String {
        String(localized: "Gemerkte Stelle")
    }

    /// Prüft alle automatischen Themenfeeds auf neues Material.
    ///
    /// Veröffentlicht höchstens eine Ausgabe je Feed und Lauf: fünf auf
    /// einmal wären keine Neuigkeit mehr, sondern eine Flut.
    ///
    /// Eine neue Ausgabe entsteht von selbst erst, wenn die letzte
    /// weitgehend gehört oder älter als zwölf Stunden ist. Sonst läge nach
    /// jedem Aktualisieren eine fast gleiche Ausgabe über der vorigen.
    /// Startet nie Ton.
    public func processPendingEditions() async {
        for feed in smartFeeds where feed.publicationPolicy.isAutomatic {
            guard !buildingFeeds.contains(feed.id) else { continue }
            if let latest = editions[feed.id]?.first,
               Date().timeIntervalSince(latest.publishedAt) < 12 * 60 * 60,
               latest.heardFraction(in: ledger) < 0.8 {
                continue
            }
            _ = await buildEdition(feedID: feed.id, requestedByUser: false)
        }
    }

    // MARK: - Gegenpositionen und Wissenspfade

    public internal(set) var trails: [KnowledgeTrail] = []

    /// Die zuletzt geprüfte These und ihr Ergebnis. Im Modell statt in der
    /// Ansicht, damit es nach dem Zurückgehen noch da ist.
    public internal(set) var counterpointCheck: CounterpointCheck?
    private var counterpointTask: Task<Void, Never>?

    /// Prüft eine These: sucht passende Stellen und lässt sie einordnen.
    ///
    /// Eine neue Prüfung bricht die laufende ab und leert das alte Ergebnis
    /// sofort. So stehen nie Stellen zu einer anderen These da.
    public func checkThesis(_ thesis: String) {
        let text = thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        counterpointTask?.cancel()
        let check = CounterpointCheck(thesis: text)
        counterpointCheck = check
        counterpointTask = Task { [weak self] in
            guard let self else { return }
            let search = await self.findCounterpoints(for: text)
            guard !Task.isCancelled, self.counterpointCheck?.id == check.id else { return }
            self.counterpointCheck = CounterpointCheck(
                id: check.id, thesis: text, isRunning: false,
                candidates: CounterpointMixer().balance(search.candidates),
                classificationProblem: search.classificationProblem)
        }
    }

    /// Sucht belegte Positionen zu einer These.
    ///
    /// Gesucht wird in allen ausgewerteten Stellen, sortiert nach Relevanz,
    /// wie im Chat. Das Modell ordnet die besten ein, in Portionen, die auch
    /// in das Fenster des Gerätemodells passen. Was es nicht einordnen
    /// konnte, bleibt sichtbar „nicht eingeordnet“, und der Grund steht
    /// dabei. Ohne Einordnung sagt die App nichts über Gegenpositionen.
    public func findCounterpoints(for thesis: String) async -> CounterpointSearch {
        let pool = (try? await store.evidenceForAnalyzedEpisodes(limit: Self.evidencePoolLimit)) ?? []
        guard !pool.isEmpty else {
            return CounterpointSearch(candidates: [], classificationProblem: String(localized:
                "Noch hat keine Folge ein Transkript. Sobald das erste fertig ist, sucht die App darin."))
        }

        let embeddingLimit = Self.embeddingBudget
        let limit = Self.counterpointLimit
        let shortlist = await Task.detached(priority: .userInitiated) {
            PassageRanker().rank(pool, for: thesis, limit: limit, embeddingLimit: embeddingLimit)
        }.value
        guard !shortlist.isEmpty, !Task.isCancelled else { return CounterpointSearch(candidates: []) }

        // Das Modell ordnet ein, in vorgegebene Bezeichnungen, und was es
        // sonst zurückgibt, wird verworfen. Jede Portion ist so gross, wie
        // das Gerätemodell sie fasst. Fällt Private Cloud Compute aufs
        // Gerät zurück, sieht das Gerät trotzdem jede Stelle.
        await refreshModelStatus()
        let device = Self.answerBudget(privateCloud: false, contextSize: Self.onDeviceContextSize,
                                       questionLength: thesis.count)
        let portions = Int((Double(shortlist.count) / Double(max(1, device.maximumCandidates))).rounded(.up))
        let size = Int((Double(shortlist.count) / Double(max(1, portions))).rounded(.up))
        let extractor = KnowledgeExtractor(configuration: ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(
                excerptLimit: ContextBudget.privateCloudCompute.excerptLimit, maximumCandidates: size),
            onDeviceBudget: device))
        let labels = CounterpointRelation.classifiable.map(\.rawValue)

        var classified: [EvidenceID: CounterpointRelation] = [:]
        var processed = 0
        var failed = 0
        var reason: String?
        for start in stride(from: 0, to: shortlist.count, by: size) {
            let portion = Array(shortlist[start..<min(start + size, shortlist.count)])
            do {
                let result = try await extractor.classify(
                    portion, against: thesis, labels: labels, availability: modelStatus)
                for (id, label) in result {
                    if let relation = CounterpointRelation(rawValue: label) { classified[id] = relation }
                }
                processed += portion.count
            } catch {
                if error is CancellationError || Task.isCancelled { return CounterpointSearch(candidates: []) }
                reason = Self.classificationReason(error)
                // Fehlt das Modell, scheitert jede weitere Portion genauso.
                if let extractorError = error as? ExtractorError, case .modelUnavailable = extractorError {
                    failed = shortlist.count - processed
                    break
                }
                failed += portion.count
            }
        }

        let titles = (try? await store.titles(forEpisodes: Array(Set(shortlist.map(\.episodeID))))) ?? [:]
        let candidates = shortlist.map { item in
            let assigned = classified[item.id]
            return CounterpointCandidate(
                evidenceID: item.id,
                relation: assigned ?? .unclassified,
                isModelConfirmed: assigned != nil,
                sourceTitle: titles[item.episodeID]?.source
                    ?? sources.first { $0.id == item.sourceID }?.title ?? String(localized: "Unbekannter Podcast"),
                excerpt: item.quotedText,
                episodeID: item.episodeID,
                episodeTitle: titles[item.episodeID]?.episode,
                range: item.range)
        }

        let problem: String?
        if failed >= shortlist.count {
            problem = [String(localized: "Die Stellen sind nicht eingeordnet."), reason,
                       String(localized: """
                           Sie passen zum Thema der These. Ob sie dafür oder dagegen sprechen, \
                           lässt sich so nicht sagen.
                           """)].compactMap { $0 }.joined(separator: " ")
        } else if failed > 0 {
            // Hier ist `failed` kleiner als die Zahl der Stellen, also sind es mindestens zwei.
            problem = [String(localized: "\(failed) von \(shortlist.count) Stellen liessen sich nicht einordnen."), reason]
                .compactMap { $0 }.joined(separator: " ")
        } else if classified.isEmpty {
            problem = String(localized: """
                Das Modell hat keine der Stellen dieser These zugeordnet. \
                Sie passen nur dem Wortlaut nach.
                """)
        } else {
            problem = nil
        }
        return CounterpointSearch(candidates: candidates, classificationProblem: problem)
    }

    /// So viele Stellen sucht eine Prüfung höchstens heraus.
    static let counterpointLimit = 20

    /// Ein Satz dazu, warum die Einordnung fehlt, ohne Fehlercode.
    private static func classificationReason(_ error: any Error) -> String {
        guard let error = error as? ExtractorError else { return error.localizedDescription }
        switch error {
        case .modelUnavailable(let reason): return reason.message
        case .generationFailed(let detail), .generationRejected(let detail): return detail
        }
    }

    /// Sichert die geprüfte These als Wissenslandkarte. Aufbewahren heisst
    /// nicht zustimmen, die Landkarte sagt das auch.
    public func saveCounterpointCheck() {
        guard var check = counterpointCheck, !check.isRunning, !check.isSaved,
              !check.candidates.isEmpty else { return }
        trails.insert(KnowledgeTrail(
            question: String(localized: "These: \(check.thesis)"),
            evidenceIDs: check.candidates.map(\.evidenceID),
            counterpointEvidenceIDs: check.candidates.filter { $0.relation == .contradicts }.map(\.evidenceID)
        ), at: 0)
        persistTrails()
        check.isSaved = true
        counterpointCheck = check
    }

    /// Spielt die Folge einer Gegenposition ab ihrer Stelle. Nur auf Tipp.
    public func playCounterpoint(_ candidate: CounterpointCandidate) {
        Task {
            guard let episodeID = candidate.episodeID, let range = candidate.range,
                  let episode = (try? await store.episodes(ids: [episodeID]))?.first else {
                lastError = String(localized: "Diese Stelle ist nicht mehr verfügbar.")
                return
            }
            playEpisode(episode, at: range.start.seconds)
        }
    }

    /// Merkt eine Gegenposition wie jede andere Stelle, mit Zitat, Folge,
    /// Quelle und Zeitmarke.
    public func rememberCounterpoint(_ candidate: CounterpointCandidate) {
        Task {
            guard let episodeID = candidate.episodeID, let range = candidate.range,
                  let episode = (try? await store.episodes(ids: [episodeID]))?.first else {
                lastError = String(localized: "Diese Stelle ist nicht mehr verfügbar.")
                return
            }
            await addNote(nil, at: range.start.seconds, in: episode, quote: candidate.excerpt)
        }
    }

    public func playCounterpoints(_ candidates: [CounterpointCandidate], thesis: String) {
        Task {
            guard let all = try? await store.evidence(ids: candidates.map(\.evidenceID)) else { return }
            let context = await planningContext(for: Array(all.values))
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(
                    evidenceIDs: candidates.map(\.evidenceID),
                    requestSummary: String(localized: "Gegenpositionen zu: \(thesis)")
                ),
                route: .counterpoint,
                options: FocusPlannerOptions(skipAlreadyHeard: false, ledger: ledger)
            )
            guard !plan.isEmpty else {
                lastError = String(localized: "Zu dieser These lässt sich nichts abspielen.")
                return
            }
            play(plan, from: .tap)
        }
    }

    /// Parken: sichert Frage, Belege und die Notizen dieser Session. Ohne
    /// Zustimmung zu irgendetwas. Notizen aus anderen Sessions gehören nicht
    /// dazu, sonst trüge jede Karte die ganze Mediathek mit sich.
    public func park(_ closure: SessionClosure) {
        pendingClosure = nil
        trails.insert(KnowledgeTrail(
            question: closure.question,
            evidenceIDs: closure.supportingEvidenceIDs,
            highlightIDs: closure.noteIDs(in: highlights)
        ), at: 0)
        persistTrails()
    }

    /// Sichert eine Chat-Antwort als Wissenslandkarte: Frage, Antworttext,
    /// ihre Belege in der Reihenfolge der Verweisnummern und die Notizen zu
    /// genau diesen Stellen. Zweimal sichern legt keine zweite Karte an.
    public func park(_ answer: ChatAnswer) {
        let id = Self.trailID(for: answer)
        guard !trails.contains(where: { $0.id == id }) else { return }
        let cited = Set(answer.citations.map(\.id))
        let numbers = answer.citationNumbers.filter { cited.contains($0.value) }
        trails.insert(KnowledgeTrail(
            id: id,
            question: answer.question,
            evidenceIDs: answer.citations.map(\.id),
            highlightIDs: KnowledgeTrail.noteIDs(in: highlights, matching: answer.citations),
            parkedAt: Date(),
            answerText: answer.text,
            citationNumbers: numbers.isEmpty ? nil : numbers
        ), at: 0)
        persistTrails()
    }

    /// Die Karte einer Antwort trägt deren Kennung. So sieht die Antwort,
    /// ob sie schon gesichert ist.
    static func trailID(for answer: ChatAnswer) -> KnowledgeNodeID {
        KnowledgeNodeID(rawValue: "answer-\(answer.id.uuidString)")
    }

    public func isParked(_ answer: ChatAnswer) -> Bool {
        let id = Self.trailID(for: answer)
        return trails.contains { $0.id == id }
    }

    /// Löscht eine Wissenslandkarte. Belege und Notizen bleiben.
    public func removeTrail(_ id: KnowledgeNodeID) {
        trails.removeAll { $0.id == id }
        persistTrails()
    }

    /// Nimmt gelöschte Belege aus den Karten. Was aus ihnen formuliert war,
    /// geht mit, leere Karten verschwinden (`KnowledgeTrail.removing`).
    func pruneTrails(removedEvidence: Set<EvidenceID>) {
        guard !removedEvidence.isEmpty else { return }
        let pruned = trails.compactMap { $0.removing(evidence: removedEvidence) }
        let changed = pruned.count != trails.count || zip(pruned, trails).contains {
            $0.evidenceIDs != $1.evidenceIDs || $0.counterpointEvidenceIDs != $1.counterpointEvidenceIDs
                || $0.answerText != $1.answerText
        }
        guard changed else { return }
        trails = pruned
        persistTrails()
    }

    /// Vertiefen: erzeugt eine neue, begrenzte Hörsession aus den Stellen,
    /// die die Abschlusskarte angekündigt hat. Nicht aus dem eben Gehörten:
    /// das verwarf der Planer als schon gehört, und die Session blieb leer.
    public func deepen(_ closure: SessionClosure) {
        Task {
            guard let all = try? await store.evidence(ids: closure.followUpEvidenceIDs) else { return }
            let context = await planningContext(for: Array(all.values))
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(
                    evidenceIDs: closure.followUpEvidenceIDs,
                    requestSummary: closure.question
                ),
                route: .interestFocus,
                options: FocusPlannerOptions(
                    // Begrenztes Budget: Vertiefen ist kein endloser Loop.
                    budget: closure.suggestedBudget, ledger: ledger
                )
            )
            guard !plan.isEmpty else {
                lastError = String(localized: "Die weiteren Stellen sind inzwischen gehört oder nicht mehr da.")
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
        playRelevantItems([item])
    }

    /// Spielt mehrere Stellen einer Karte nacheinander.
    public func playRelevantItems(_ items: [RelevantItem]) {
        guard let first = items.first else { return }
        Task {
            let ids = items.map(\.id)
            guard let found = try? await store.evidence(ids: ids) else {
                lastError = String(localized: "Diese Stelle ist nicht mehr verfügbar.")
                return
            }
            let evidence = ids.compactMap { found[$0] }
            guard !evidence.isEmpty else {
                lastError = String(localized: "Diese Stelle ist nicht mehr verfügbar.")
                return
            }
            let context = await planningContext(for: evidence)
            let plan = FocusPlanner(context: context).plan(
                from: PlaylistProposal(evidenceIDs: evidence.map(\.id),
                                       requestSummary: first.episodeTitle),
                route: .interestFocus,
                // Ausdrücklich gewählt heisst: auch dann abspielen, wenn es
                // schon gehört wurde.
                options: FocusPlannerOptions(skipAlreadyHeard: false, ledger: ledger)
            )
            guard !plan.isEmpty else {
                lastError = plan.excluded.first?.reason ?? String(localized: "Diese Stelle lässt sich nicht abspielen.")
                return
            }
            play(plan, from: .tap)
        }
    }

    /// Merkt eine Stelle aus „Für dich“ unter Wissen, mit Zitat und Herkunft.
    public func rememberRelevantItem(_ item: RelevantItem) {
        Task {
            var episodeID = item.episodeID
            if episodeID == nil {
                episodeID = (try? await store.evidence(ids: [item.id]))?[item.id]?.episodeID
            }
            guard let episodeID,
                  let episode = (try? await store.episodes(ids: [episodeID]))?.first,
                  await addNote(nil, at: item.range.start.seconds, in: episode, quote: item.excerpt) != nil
            else {
                lastError = String(localized: "Diese Stelle lässt sich nicht mehr merken.")
                return
            }
        }
    }

    /// Ist diese Stelle aus „Für dich“ schon gemerkt?
    public func isRemembered(_ item: RelevantItem) -> Bool {
        highlights.contains { $0.episodeID == item.episodeID && $0.quote == String(item.excerpt.prefix(700)) }
    }

    /// Sortiert Stellen aus „Für dich“ aus. Sie kommen nicht wieder, auch
    /// nicht nach einem Neustart.
    public func dismissRelevantItems(_ items: [RelevantItem]) {
        let ids = Set(items.map(\.id))
        relevantToday.removeAll { ids.contains($0.id) }
        // Die jüngsten zuletzt; bei sehr vielen fallen die ältesten heraus.
        var stored = UserDefaults.standard.stringArray(forKey: Self.dismissedRelevantKey) ?? []
        stored.removeAll { ids.contains(EvidenceID(rawValue: $0)) }
        stored.append(contentsOf: ids.map(\.rawValue).sorted())
        UserDefaults.standard.set(Array(stored.suffix(2_000)), forKey: Self.dismissedRelevantKey)
    }

    /// Stellen, die der Nutzer als „Nicht relevant“ aussortiert hat.
    var dismissedRelevant: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.dismissedRelevantKey) ?? [])
    }

    /// Hebt einen Vorschlag zu einem bestätigten Interesse.
    public func confirmInterest(_ id: InterestID) async {
        profile.confirm(id)
        guard let interest = profile.interests.first(where: { $0.id == id }) else { return }
        do {
            try await store.upsert(interest: interest)
            try await reloadProfile()
        } catch {
            lastError = UserFacingError.describe(error)
        }
    }

    public func clearError() { lastError = nil }

    // MARK: - Ganze Folgen

    /// Spielt eine ganze Folge ab einer Stelle. Liegt sie schon geladen vor,
    /// kommt der Ton aus der Datei, sonst aus dem Stream.
    public func playEpisode(_ episode: Episode, at seconds: Double? = nil) {
        let local = localAudioFile(for: episode)
        // Erst prüfen, dann anhalten. Sonst endete ein laufender Fokus-Plan
        // für eine Folge, die gar nicht klingen kann.
        guard local != nil || episode.audioURL != nil else {
            lastError = episode.opensInYouTube
                ? String(localized: "„\(episode.title)“ hat keine Audiodatei, nur ein Video bei YouTube.")
                : String(localized: "„\(episode.title)“ hat keine Audiodatei.")
            return
        }
        // Ohne Netz und ohne Datei gleich sagen, woran es liegt, statt einen
        // Player zu öffnen, der nur lädt.
        if local == nil, isOffline {
            lastError = String(localized: "„\(episode.title)“ ist nicht auf diesem Gerät geladen. Ohne Netz lässt sich die Folge nicht abspielen.")
            return
        }
        if playerPlan != nil { stopPlayback() }
        let start = seconds ?? resumePosition(for: episode)
        episodePlayer.play(episode, at: start, localFile: local)
        upNext.removeAll { $0.id == episode.id }
        Task { await loadChapters(for: episode) }
        // Die vorige Folge liegt jetzt nicht mehr im Player und darf aufgeräumt werden.
        Task { await tidyLocalAudio() }
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

    /// Kann die App diese Folge abspielen? YouTube-Folgen haben nur eine
    /// Webseite und keine Audiodatei.
    public func canPlay(_ episode: Episode) -> Bool {
        episode.audioURL != nil
            || episode.streamMediaVersionID.flatMap { LocalMediaLocator().localFile(for: $0) } != nil
    }

    /// „Als Nächstes“ reiht eine Folge direkt hinter der laufenden ein,
    /// „Ans Ende“ hinter alles, was schon wartet.
    public enum UpNextPlacement { case next, last }

    public func addToUpNext(_ episode: Episode, placement: UpNextPlacement = .next) {
        guard canPlay(episode), episodePlayer.episode?.id != episode.id else { return }
        var queue = upNext
        queue.removeAll { $0.id == episode.id }
        switch placement {
        case .next: queue.insert(episode, at: 0)
        case .last: queue.append(episode)
        }
        upNext = queue
    }

    public func removeFromUpNext(_ episodeID: EpisodeID) {
        upNext.removeAll { $0.id == episodeID }
    }

    public func removeFromUpNext(at offsets: IndexSet) {
        upNext.remove(atOffsets: offsets)
    }

    public func moveUpNext(from offsets: IndexSet, to destination: Int) {
        upNext.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Wie lange „Als Nächstes“ noch dauert, ab der gemerkten Stelle jeder
    /// Folge. Folgen ohne Längenangabe zählen nicht mit.
    public var upNextRemaining: TimeInterval {
        upNext.reduce(0) { total, episode in
            guard let length = episode.declaredDuration?.seconds, length > 0 else { return total }
            return total + max(0, length - resumePosition(for: episode))
        }
    }

    /// Startet die erste Folge aus „Als Nächstes“ an ihrer gemerkten Stelle.
    /// Eine halb gehörte Folge geht dort weiter, wo sie aufgehört hat.
    ///
    /// Ohne Netz kommt die erste Folge dran, die auf dem Gerät liegt. Die
    /// anderen bleiben in der Liste, bis wieder Netz da ist. `false` heisst:
    /// es startet nichts. Die Kopfhörertaste springt dann 30 s vor.
    @discardableResult
    public func playNextInQueue() -> Bool {
        // Folgen ohne Ton (YouTube) hielten die Liste nur auf.
        if upNext.contains(where: { !canPlay($0) }) { upNext.removeAll { !canPlay($0) } }
        guard let next = upNext.first(where: canStartNow) else {
            if !upNext.isEmpty {
                lastError = String(localized: """
                    Ohne Netz spielt nur, was auf diesem Gerät geladen ist. \
                    Keine Folge in „Als Nächstes“ ist geladen.
                    """)
            }
            return false
        }
        playEpisode(next)
        return true
    }

    /// Würde `playEpisode` diese Folge jetzt starten? Dieselben Bedingungen:
    /// eine geladene Datei, oder ein Stream und Netz.
    private func canStartNow(_ episode: Episode) -> Bool {
        localAudioFile(for: episode) != nil || (episode.audioURL != nil && !isOffline)
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
            String(localized: "Nächste Stelle: \(segment.episodeTitle), aus \(segment.sourceTitle)")
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
        var lines = ["## " + (highlight.note ?? rememberedPassageTitle)]
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
    /// Wann die Folge erschienen ist.
    public let publishedAt: Date?
    /// Welche Begriffe der Stelle getroffen haben, in der Schreibweise des Nutzers.
    public let mentioned: [String]

    public init(id: EvidenceID, sourceTitle: String, episodeTitle: String,
                range: MediaTimeRange, excerpt: String, relevance: PersonalRelevance?,
                episodeID: EpisodeID? = nil, mediaVersionID: MediaVersionID? = nil,
                publishedAt: Date? = nil, mentioned: [String] = []) {
        self.id = id; self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.range = range; self.excerpt = excerpt; self.relevance = relevance
        self.episodeID = episodeID; self.mediaVersionID = mediaVersionID
        self.publishedAt = publishedAt; self.mentioned = mentioned
    }
}

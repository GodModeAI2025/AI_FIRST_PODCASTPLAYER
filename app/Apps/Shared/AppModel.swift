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
    /// Die Bildcover der Themen-Updates.
    let coverArt = TopicCoverArt()
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
    /// Steht, sobald `load()` einmal durch ist. Vorher heißt „nicht
    /// gefunden“ nur „noch nicht gelesen“.
    public internal(set) var isLoaded = false

    /// Neue Folgen von selbst erschließen, damit Wissen, „Für dich“ und
    /// die Themen-Updates gefüllt sind, bevor man danach sucht. Abschaltbar,
    /// weil es Daten, Akku und Zeit kostet.
    public var automaticAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(automaticAnalysis, forKey: Self.automaticAnalysisKey)
            if automaticAnalysis {
                Task { await prepareNewEpisodes() }
            } else {
                // Ausgeschaltet heißt auch: was schon von selbst wartet, lädt
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
    /// Von selbst nur im WLAN laden. Was man selbst anfordert, regelt
    /// `allowsCellularLoading`.
    public var preparationOnWiFiOnly: Bool {
        didSet {
            UserDefaults.standard.set(preparationOnWiFiOnly, forKey: Self.wifiOnlyKey)
            networkChanged(networkLimit)
        }
    }

    // MARK: Mobilfunk (Rückfrage in `MobileDataQuestion`, SettingsView.swift)

    static let cellularLoadingKey = "allowCellularLoading"
    /// Was jemand selbst abspielt, für unterwegs lädt oder als Transkript
    /// anfordert, darf über Mobilfunk laden. Aus heißt: die App fragt
    /// vorher, statt still Daten zu verbrauchen. Transkripte für neue Folgen
    /// regelt davon getrennt „Nur im WLAN“.
    public var allowsCellularLoading: Bool {
        didSet {
            UserDefaults.standard.set(allowsCellularLoading, forKey: Self.cellularLoadingKey)
            // Angeforderte Transkripte warten oder laufen weiter.
            queueConditionsChanged()
        }
    }
    /// Mobilfunk oder Hotspot. Eigens gemerkt, weil `networkLimit` im
    /// Datensparmodus nur diesen nennt und den Mobilfunk verdeckt.
    @ObservationIgnored var onMobileData = false
    /// Einmal „Laden“ gesagt: bis das Gerät wieder im WLAN ist, fragt die
    /// App nicht noch einmal.
    @ObservationIgnored var mobileDataApproved = false
    /// Schon nach den Transkripten gefragt, die im Mobilfunk warten. Bis zum
    /// nächsten WLAN kommt die Frage dazu nicht noch einmal von selbst.
    @ObservationIgnored private var askedAboutWaitingTranscripts = false
    /// Wartet auf die Antwort auf „Über Mobilfunk laden?“.
    public internal(set) var pendingMobileData: MobileDataRequest?
    /// Muss die App fragen, bevor sie etwas über das Netz holt?
    var mobileDataNeedsConsent: Bool { !allowsCellularLoading && onMobileData && !mobileDataApproved }

    /// Was nach einem Ja zur Rückfrage geladen wird.
    public enum MobileDataRequest {
        case play(Episode, at: Double?)
        case plan(ValidatedPlaybackPlan, PlayTrigger)
        case download(Episode)
        case transcripts([Episode])

        /// Was geladen würde, als Satz für die Rückfrage.
        public var detail: String {
            switch self {
            case .play(let episode, _):
                String(localized: "„\(episode.title)“ liegt nicht auf diesem Gerät. Zum Abspielen kommt der Ton über Mobilfunk.")
            case .plan:
                String(localized: "Diese Stellen liegen nicht auf diesem Gerät. Zum Abspielen kommt der Ton über Mobilfunk.")
            case .download(let episode):
                String(localized: "„\(episode.title)“ wird über Mobilfunk auf das Gerät geladen.")
            case .transcripts(let episodes):
                episodes.count == 1
                    ? String(localized: "Für das Transkript lädt die App die Folge über Mobilfunk.")
                    : String(localized: "Für die Transkripte lädt die App \(episodes.count) Folgen über Mobilfunk.")
            }
        }
    }

    /// Stellt die Rückfrage, wenn Mobilfunk in den Einstellungen aus ist.
    /// `true` heißt: gefragt, der Aufrufer lädt jetzt nichts.
    func askBeforeMobileData(_ request: MobileDataRequest) -> Bool {
        guard mobileDataNeedsConsent else { return false }
        // Mehrere Folgen auf einmal angefordert: eine Frage für alle.
        if case .transcripts(let waiting)? = pendingMobileData, case .transcripts(let more) = request {
            let known = Set(waiting.map(\.id))
            pendingMobileData = .transcripts(waiting + more.filter { !known.contains($0.id) })
        } else {
            pendingMobileData = request
        }
        return true
    }

    /// Die Antwort auf die Rückfrage. Ein Ja gilt, bis das Gerät wieder im
    /// WLAN ist; „immer“ schaltet Mobilfunk in den Einstellungen ein.
    public func answerMobileData(_ request: MobileDataRequest, load: Bool, always: Bool = false) {
        pendingMobileData = nil
        guard load else { return }
        // Erst im WLAN beantwortet: das Ja gilt für diese Anfrage, nicht für
        // den nächsten Mobilfunk.
        if always { allowsCellularLoading = true } else if onMobileData { mobileDataApproved = true }
        switch request {
        case .play(let episode, let seconds): playEpisode(episode, at: seconds)
        case .plan(let plan, let trigger): play(plan, from: trigger)
        case .download(let episode): Task { await downloadForOffline(episode) }
        case .transcripts(let episodes):
            // Was schon von Hand eingereiht ist, behält seinen Platz. Neues
            // kommt dazu.
            for episode in episodes where !isQueuedByHand(episode.id) { enqueueAnalysis(episode) }
        }
        // Nach einem Ja laufen auch Transkripte weiter, die im Mobilfunk warten.
        queueConditionsChanged()
    }

    public func dismissMobileDataQuestion() { pendingMobileData = nil }

    /// Neuer Netzpfad. Zurück im WLAN gilt ein früheres Ja nicht mehr.
    func mobileDataChanged(_ mobile: Bool) {
        onMobileData = mobile
        guard !mobile else { return }
        mobileDataApproved = false
        askedAboutWaitingTranscripts = false
        // Die Frage nach wartenden Transkripten erledigt sich im WLAN: sie
        // laufen jetzt ohnehin.
        if case .transcripts(let episodes)? = pendingMobileData, episodes.allSatisfy({ isQueuedByHand($0.id) }) {
            pendingMobileData = nil
        }
    }
    /// Was das Netz gerade einschränkt: kein Netz, Datensparmodus, Hotspot
    /// oder Mobilfunk. `nil` heißt WLAN ohne Datenlimit.
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
    public enum NetworkLimit: Equatable, Sendable, CaseIterable {
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
    /// Wie weit ein Download für unterwegs ist, für „23 von 70 MB“.
    public internal(set) var downloadProgress: [EpisodeID: DownloadProgress] = [:]
    /// Die laufenden Downloads, damit „Laden abbrechen“ sie beenden kann.
    @ObservationIgnored var downloadTasks: [EpisodeID: Task<DownloadResult, Error>] = [:]
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

    // MARK: Fakten im Hintergrund (Ablauf in AppModel+Knowledge.swift)

    /// Folgen, deren Fakten noch gesammelt werden, eine nach der anderen.
    /// Eine eigene Warteschlange neben der für Transkripte: das Modell
    /// braucht je Folge eine Minute oder mehr, und das nächste Transkript
    /// wartet nicht darauf.
    public internal(set) var factsQueue: [Episode] = []
    /// Die Folge, deren Fakten gerade entstehen.
    public internal(set) var gatheringFacts: Episode?
    /// Wie weit die laufende Folge ist, von 0 bis 1.
    public internal(set) var factsProgress: [EpisodeID: Double] = [:]
    /// Warum die Warteschlange der Fakten steht, oder `nil`, wenn sie läuft.
    public internal(set) var factsWait: String?
    /// Was beim letzten Lauf einer Folge fehlte, für den Reiter „Fakten“.
    public internal(set) var factsIssues: [EpisodeID: String] = [:]
    @ObservationIgnored var factsTask: Task<Void, Never>?
    /// Von Hand angefordert. Läuft vorn, rechnet neu und meldet Fehler.
    @ObservationIgnored var factsRequested: Set<EpisodeID> = []
    /// Nach zwei vergeblichen Versuchen im Vordergrund. Erst der nächste
    /// Start oder ein wieder bereites Modell versucht es erneut.
    @ObservationIgnored var factsDeferred: Set<EpisodeID> = []
    /// Wie viele Arbeiten gerade Hintergrundzeit vom System haben und die
    /// Fakten mitnehmen: die Aufgabe `com.podcastai.analysis` und die
    /// fortgesetzte Verarbeitung der Transkripte. Ohne sie arbeitet die
    /// Warteschlange der Fakten nur, solange die App vorn ist.
    @ObservationIgnored var factsGrants = 0
    /// Beobachter für Vorder- und Hintergrund, siehe `observeAppState()`.
    @ObservationIgnored var appStateObservers: [any NSObjectProtocol] = []
    /// War die App seit dem letzten Aktivwerden im Hintergrund, oder ist
    /// sie eben erst gestartet? Dann sucht sie beim Aktivwerden nach
    /// fehlenden Fakten, sonst nicht, etwa nach dem Kontrollzentrum.
    @ObservationIgnored var returningFromBackground = true
    /// Seit wann eine Folge mit Transkript ohne Fakten bekannt ist. Kommt
    /// das Transkript per iCloud, sammelt meist das andere Gerät gerade.
    @ObservationIgnored var factsMissingSince: [EpisodeID: Date] = [:]
    /// Hat die App schon nach fehlenden Fakten gesucht? Bis dahin, und
    /// wieder nach dem Einschalten oder wenn das Modell bereit wird, reiht
    /// sie ohne Wartezeit ein.
    @ObservationIgnored var factsBackfilled = false

    /// Fakten nach dem Transkript von selbst sammeln, auch für ältere
    /// Folgen, denen sie noch fehlen.
    public var automaticFacts: Bool {
        didSet {
            UserDefaults.standard.set(automaticFacts, forKey: Self.automaticFactsKey)
            if automaticFacts {
                // Eben eingeschaltet: alles, was fehlt, gleich einreihen.
                factsBackfilled = false
                Task { await queueMissingFacts() }
            } else {
                dropAutomaticFacts()
            }
        }
    }
    static let automaticFactsKey = "automaticFacts"

    /// Zählt hoch, wenn sich der belegte Speicher ändert; Ansichten lesen
    /// danach die Größe neu.
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
    /// Die laufende Erschließung einer einzelnen Folge. Löschen bricht nur
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

    /// Ein gespeicherter Schalter. `bool(forKey:)` versteht auch Werte aus
    /// Startargumenten wie `-automaticAnalysis NO`, die als Text ankommen.
    static func storedFlag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    public init(store: LibraryStore, deviceID: String = AppModel.currentDeviceID()) {
        self.store = store
        // Voreingestellt an: ohne vorbereitete Folgen bleibt „Für dich“ leer,
        // und die App wirkt, als könne sie nichts.
        self.automaticAnalysis = Self.storedFlag(Self.automaticAnalysisKey, default: true)
        self.automaticFacts = Self.storedFlag(Self.automaticFactsKey, default: true)
        // Aus, solange dem Build die Berechtigung für Private Cloud Compute
        // fehlt. Ohne sie ginge keine Anfrage an Apples Server, der Schalter
        // stünde aber an.
        self.allowPrivateCloudCompute = Self.storedFlag(
            Self.privateCloudKey, default: KnowledgeExtractor.privateCloudEntitled)
        let perSource = UserDefaults.standard.integer(forKey: Self.episodesPerSourceKey)
        self.episodesPerSource = perSource > 0 ? perSource : 3
        self.preparationOnWiFiOnly = Self.storedFlag(Self.wifiOnlyKey, default: true)
        self.allowsCellularLoading = Self.storedFlag(Self.cellularLoadingKey, default: true)
        // Beide an: der Text bleibt, der Ton kommt bei Bedarf aus dem Netz.
        self.removeAudioAfterAnalysis = Self.storedFlag(Self.removeAfterAnalysisKey, default: true)
        self.removeHeardAudio = Self.storedFlag(Self.removeHeardKey, default: true)
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
            let mobile = path.status == .satisfied && path.isExpensive
            Task { @MainActor in
                self?.mobileDataChanged(mobile)
                self?.networkChanged(limit)
            }
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
        // Ein neues Cover erscheint auch am Sperrbildschirm, nicht erst bei der nächsten Stelle.
        coverArt.onChange = { [weak self] in self?.episodePlayer.refreshNowPlaying() }
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
            // Start immer: was sich getan hat, während die App zu war, weiß
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
        // Beim Start und nach jedem Abgleich: Folgen mit Transkript, denen
        // die Fakten fehlen, etwa weil die App beim letzten Mal beendet wurde.
        await queueMissingFacts()
    }

    /// Wechselt auf einen Speicher, der sich erst im zweiten Versuch öffnen
    /// ließ, und liest alles neu. Was bis dahin im flüchtigen Speicher lag,
    /// war nie gesichert und geht dabei verloren.
    public func replaceStore(_ newStore: LibraryStore) async {
        store = newStore
        refresher = FeedRefresher(store: newStore)
        episodes = [:]
        // Ein neuer Speicher ist ein neuer Start. Auch für die Fakten: was
        // wartete, gehörte zum alten Speicher, und gesucht wird ohne Wartezeit.
        restoreAttempted = false
        factsQueue = []
        factsBackfilled = false
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
            // Die Zahl mit passendem Wort für sich, der Titel außerhalb:
            // `AttributedString(localized:)` liest Markdown und schluckte
            // sonst Zeichen wie * oder _ aus dem Namen des Podcasts.
            let found = String(AttributedString(localized: "^[\(added.episodeCount) Folge](inflect: true) gefunden").characters)
            activity = String(localized: "„\(added.title)“ abonniert · \(found)")
        } catch is CancellationError {
            // Abgebrochen ist kein Fehler, den jemand lesen muss.
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

    /// Liest einen Podcast für die Vorschau vor dem Abonnieren, ohne ihn anzulegen.
    public func previewPodcast(_ feed: URL) async throws -> PodcastPreview {
        try await refresher.preview(of: feed)
    }

    /// Gibt den für die Vorschau gelesenen Feed frei.
    public func forgetPodcastPreview() async {
        await refresher.discardPreview()
    }

    // MARK: - Laden für unterwegs

    /// Stand eines Downloads für unterwegs. `expected` fehlt, wenn der
    /// Server keine Größe nennt.
    public struct DownloadProgress: Equatable, Sendable {
        public var received: Int64
        public var expected: Int64?
        public var fraction: Double? {
            guard let expected, expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        }
    }

    /// Bricht einen Download für unterwegs ab. Eine halbe Datei bleibt nicht liegen.
    public func cancelDownload(_ episode: Episode) {
        downloadTasks[episode.id]?.cancel()
    }

    func noteDownloadProgress(_ id: EpisodeID, received: Int64, expected: Int64?) {
        // Späte Meldungen eines beendeten Downloads tragen nichts mehr ein.
        guard downloading.contains(id) else { return }
        downloadProgress[id] = DownloadProgress(received: received, expected: expected)
    }

    /// Ausdrücklich für unterwegs geladen? Dann nimmt das Aufräumen das
    /// Audio nicht vom Gerät. Liest den Speicherzähler mit, damit Ansichten
    /// nach „Laden (offline)“ neu prüfen.
    public func isKeptOffline(_ episode: Episode) -> Bool {
        _ = mediaStorageChanged
        _ = downloading
        return keptOffline.contains(episode.id)
    }

    /// Warum ein Download für unterwegs gescheitert ist, in Worten, die zum
    /// Laden passen. Die allgemeinen Sätze sprechen vom Transkript.
    static func downloadFailure(_ error: Error) -> String {
        if case .tooLarge(let limit)? = error as? HTTPTransferError {
            let size = limit.formatted(.byteCount(style: .file))
            return String(localized: "Die Audiodatei ist größer als \(size). So große Dateien lädt die App nicht.")
        }
        guard let urlError = error as? URLError else { return UserFacingError.describe(error) }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return String(localized: """
                Den Server dieser Folge gibt es nicht mehr. Den Podcast aktualisieren und noch einmal laden.
                """)
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return String(localized: "Der Server dieser Folge antwortet gerade nicht. Später noch einmal laden.")
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return String(localized: "Keine Internetverbindung. Sobald wieder Netz da ist, noch einmal laden.")
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return String(localized: """
                Der Server dieser Folge bietet keine sichere Verbindung an. Die App lädt nur über sichere Verbindungen.
                """)
        default:
            return String(localized: "Die Folge ließ sich gerade nicht laden. Später noch einmal versuchen.")
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
        await queueMissingFacts()
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

    // MARK: - Folgen erschließen

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
        queueConditionsChanged()
    }

    /// Netz, Einstellung oder Zustimmung haben sich geändert: jede wartende
    /// Folge sagt, worauf sie wartet, und was laufen darf, läuft.
    func queueConditionsChanged() {
        let automaticDetail = preparationWait?.queueDetail ?? Self.waitingDetail
        let networkDetails = Set(NetworkLimit.allCases.map(\.queueDetail))
        for episode in analysisQueue {
            if automaticallyQueued.contains(episode.id) {
                stageDetails[episode.id] = automaticDetail
            } else if let wait = queueWait(for: episode) {
                stageDetails[episode.id] = wait.queueDetail
            } else if let detail = stageDetails[episode.id], networkDetails.contains(detail) {
                // Wartete aufs WLAN und darf jetzt. Ein anderer Grund, etwa
                // der zweite Versuch, bleibt stehen.
                stageDetails[episode.id] = Self.waitingDetail
            }
        }
        if analysisQueue.contains(where: mayRunNow) { startAnalysisWorker() }
    }

    /// Worauf eine Folge in der Warteschlange wartet, oder `nil`, wenn sie
    /// jetzt laufen darf. Automatisch Eingereihtes wartet, solange das Netz
    /// es nicht erlaubt. Von Hand Angefordertes wartet nur, wenn es über
    /// Mobilfunk laden müsste und der in den Einstellungen aus ist.
    func queueWait(for episode: Episode) -> NetworkLimit? {
        if automaticallyQueued.contains(episode.id) { return preparationWait }
        return waitsForMobileData(episode) ? networkLimit ?? .cellular : nil
    }

    /// Darf diese Folge jetzt laufen?
    func mayRunNow(_ episode: Episode) -> Bool { queueWait(for: episode) == nil }

    /// Von Hand angefordert, der Ton käme aus dem Netz, und ohne Zustimmung
    /// ginge das nur über Mobilfunk. Die Datei wird zuletzt geprüft, also
    /// nur im Mobilfunk bei ausgeschalteter Einstellung.
    private func waitsForMobileData(_ episode: Episode) -> Bool {
        mobileDataNeedsConsent && !automaticallyQueued.contains(episode.id) && localAudioFile(for: episode) == nil
    }

    /// Transkripte, die jemand angefordert hat und die auf Mobilfunk-Zustimmung warten.
    private var transcriptsWaitingForMobileData: [Episode] { analysisQueue.filter(waitsForMobileData) }

    /// Steht die Folge von Hand eingereiht in der Warteschlange?
    private func isQueuedByHand(_ id: EpisodeID) -> Bool {
        !automaticallyQueued.contains(id) && analysisQueue.contains { $0.id == id }
    }

    /// Wie viele Folgen der Warteschlange jetzt laufen dürfen.
    public var runnableQueueCount: Int { analysisQueue.filter(mayRunNow).count }

    /// Erschließt eine Folge: laden, transkribieren, Belege bilden.
    public func analyze(_ episode: Episode, audioURL: URL, locale explicitLocale: Locale? = nil) async {
        enqueueAnalysis(episode)
    }

    /// Stellt eine Folge in die Warteschlange der Erschließung.
    public func enqueueAnalysis(_ episode: Episode, automatic: Bool = false) {
        let queued = analysisQueue.firstIndex { $0.id == episode.id }
        if automatic {
            // Schon eingereiht oder in Arbeit: so bleibt es. Sonst würde aus
            // einer Folge, die jemand angefordert hat, eine, die aufs WLAN wartet.
            guard preparationUnavailable == nil, queued == nil, analyzing?.id != episode.id else { return }
            automaticallyQueued.insert(episode.id)
        } else {
            // Von Hand angefordert und Mobilfunk aus: erst fragen, falls
            // der Ton dafür aus dem Netz käme. Ein Ja gilt auch für die
            // Transkripte, die schon im Mobilfunk warten, also zählen sie mit.
            if episode.audioURL != nil, analyzing?.id != episode.id, mobileDataNeedsConsent,
               localAudioFile(for: episode) == nil {
                // Wartet sie schon von Hand eingereiht, rückt sie gleich nach
                // vorn. Nach einem Ja läuft sie dann als Nächste.
                if let queued, !automaticallyQueued.contains(episode.id) {
                    analysisQueue.insert(analysisQueue.remove(at: queued), at: 0)
                }
                _ = askBeforeMobileData(.transcripts(
                    transcriptsWaitingForMobileData.filter { $0.id != episode.id } + [episode]))
                return
            }
            automaticallyQueued.remove(episode.id)
            dismissedFromPreparation.remove(episode.id)
            // Von Hand angefordert heißt: auch auf einem Gerät ohne
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
            // Solange Transkripte entstehen, dürfen die Fakten mitlaufen,
            // auch im Hintergrund. Endet die Phase, hält `releaseFactsGrant`
            // sie an, wenn die App nicht vorn ist.
            self.factsGrants += 1
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
            self.releaseFactsGrant()
            self.analysisTask = nil
            self.analyzing = nil
            self.activity = nil
            self.askAboutWaitingTranscripts()
            // Frisch ausgewertetes Material ist genau das, worauf die
            // automatischen Themen-Updates warten.
            await self.processPendingEditions()
        }
    }

    /// Die Warteschlange ist bis auf Transkripte durch, die über Mobilfunk
    /// laden müssten, etwa weil sie im WLAN angefordert wurden und das Gerät
    /// es inzwischen verlassen hat. Eine Frage für alle, einmal bis zum
    /// nächsten WLAN. Nach „Abbrechen“ warten sie, und „Transkript jetzt
    /// erstellen“ an der Folge fragt erneut.
    private func askAboutWaitingTranscripts() {
        queueConditionsChanged()
        let waiting = transcriptsWaitingForMobileData
        guard !waiting.isEmpty, !askedAboutWaitingTranscripts else { return }
        // Eine offene Frage zu etwas anderem bleibt stehen.
        switch pendingMobileData {
        case nil, .transcripts?: break
        default: return
        }
        askedAboutWaitingTranscripts = true
        _ = askBeforeMobileData(.transcripts(waiting))
    }

    /// Erschließt eine Folge. Gibt `true` zurück, wenn der Fehler
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
            // Zahl und Wort für sich, der Titel außerhalb des Markdowns.
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
                    // Eine gelöschte Folge taucht nicht wieder unter „Erschließen“ auf.
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
            // Die Fakten kommen in ihre eigene Warteschlange, vor dem ersten
            // `await`: eine Löschung danach nimmt sie dort wieder heraus. Das
            // nächste Transkript wartet nicht auf sie.
            if automaticFacts { enqueueFacts(episode) }
            // Nur was jemand selbst angefordert hat, wird angesagt. Das
            // automatische Vorbereiten spräche sonst Folge um Folge dazwischen.
            if automaticallyQueued.remove(episode.id) == nil {
                AccessibilityNotification.Announcement(String(localized: "Transkript fertig: \(episode.title)")).post()
            }
            await removeAudioAfterAnalysisIfWanted(episode)
            await refreshRelevantToday()
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
        // Es gibt nur noch Themen. Aktuelle Vorhaben und offene Fragen aus
        // früheren Versionen oder von einem anderen Gerät werden einmal zu
        // Themen, mit Bezeichnung und Stichworten. Ein Ablaufdatum hatten
        // nur Vorhaben; bliebe es stehen, träfe das Thema nach Ablauf still
        // nichts mehr.
        let legacy = reloaded.interests.filter { $0.kind != .topic }
        if !legacy.isEmpty {
            for var interest in legacy {
                interest.kind = .topic
                interest.expiresAt = nil
                try await store.upsert(interest: interest)
            }
            reloaded = try await store.interestProfile(learningEnabled: profile.learningEnabled)
        }
        let confirmedLabels = Set(reloaded.confirmed.map { $0.label.lowercased() })
        for interest in suggested where !confirmedLabels.contains(interest.label.lowercased()) {
            reloaded.add(interest)
        }
        profile = reloaded
    }

    /// Legt ein Interesse an. „Für dich“ rechnet danach gleich neu, damit
    /// ein neues Thema sofort seine Stellen zeigt. Die Oberfläche legt nur
    /// Themen an.
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
        // Mobilfunk aus und Stellen kämen aus dem Netz: erst fragen. Siri
        // kann die Frage nicht zeigen und sagt stattdessen, woran es liegt.
        let locator = LocalMediaLocator()
        if mobileDataNeedsConsent, plan.segments.contains(where: { locator.localFile(for: $0.mediaVersionID) == nil }) {
            if trigger == .intent {
                lastError = String(localized: """
                    Laden über Mobilfunk ist in den Einstellungen aus. Im WLAN oder mit \
                    eingeschaltetem Mobilfunk spielt die App die Stellen ab.
                    """)
                return
            }
            if askBeforeMobileData(.plan(plan, trigger)) { return }
        }
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
            album: plan.requestSummary, isPlaying: playing,
            artwork: focusArtwork(for: plan, segment: segment)
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
        // „drei weitere Stellen“ heißt drei Stellen.
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
    /// Karte kürzt ohnehin, mehr Kandidaten machen die Zahl nur größer.
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
        editionChecks[feed.id] = nil
        persistSmartFeeds()
    }

    /// Löscht einen Themenfeed mit allen seinen Ausgaben. Die Folgen, aus
    /// denen sie bestanden, und der Hörstand bleiben unberührt.
    public func removeSmartFeed(_ feedID: SmartFeedID) {
        smartFeeds.removeAll { $0.id == feedID }
        editions[feedID] = nil
        editionNotes[feedID] = nil
        editionChecks[feedID] = nil
        coverArt.remove(feedID)
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
    /// Was die letzte Prüfung je Themenfeed ergeben hat, auch die stille
    /// der Automatik. Nur im Speicher.
    public internal(set) var editionChecks: [SmartFeedID: EditionCheck] = [:]

    /// Das Ergebnis einer Prüfung auf neues Material.
    public struct EditionCheck: Equatable, Sendable {
        public var date = Date()
        /// Ungehörtes Material, das noch unter der Mindestmenge der
        /// Automatik liegt.
        public var waiting: MediaDuration?
        /// Themen des Updates, zu denen in den Folgen mit Transkript keine
        /// Stelle passt. Leer, solange es gar kein Transkript gibt.
        public var topicsWithoutHits: [InterestID] = []
    }

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
        // hat, außer sie hat tatsächlich etwas veröffentlicht.
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
            // Liegt eine Stelle in einem Kapitel des Originals, schneidet die
            // Ausgabe an dessen Grenzen.
            let scope = Set(feed.restrictedToSourceIDs)
            let chapters = await chapterMarks(for: candidates.filter {
                scope.isEmpty || scope.contains($0.sourceID)
            })
            let outcome = PersonalEpisodePublisher().makeEdition(
                feed: feed, candidates: candidates, ledger: ledger, chapters: chapters,
                existingBatchKeys: existing, requestedByUser: requestedByUser
            )
            // Themen ohne einen einzigen Treffer in den gewählten Podcasts.
            // Ohne jedes Transkript liegt es nicht am Thema.
            let allowed = Set(feed.restrictedToSourceIDs)
            let hitTopics = Set(candidates
                .filter { allowed.isEmpty || allowed.contains($0.sourceID) }
                .flatMap(\.topicIDs))
            var check = EditionCheck(
                topicsWithoutHits: known.isEmpty ? [] : feed.topicIDs.filter { !hitTopics.contains($0) })
            if case .belowThreshold(let available, _) = outcome, !requestedByUser { check.waiting = available }
            if smartFeeds.contains(where: { $0.id == feedID }) { editionChecks[feedID] = check }

            switch outcome {
            case .published(let episode):
                // Während des Zusammenstellens gelöscht: nichts anlegen.
                guard smartFeeds.contains(where: { $0.id == feedID }) else {
                    return (String(localized: "Dieses Themen-Update gibt es nicht mehr."), false)
                }
                editions[feedID, default: []].insert(episode, at: 0)
                persistEditions(for: feedID)
                // Die Zählung für sich, der Titel außerhalb des Markdowns.
                let content = String(AttributedString(localized: """
                    ^[\(episode.segments.count) Stelle](inflect: true) aus \
                    ^[\(episode.distinctSourceCount) Podcast](inflect: true)
                    """).characters)
                return (String(localized: "\(episode.title): \(content)."), true)
            case .noNewMaterial(let count):
                if known.isEmpty {
                    return (String(localized: """
                        Noch hat keine Folge ein Transkript. Sobald Transkripte fertig sind, sucht das Update darin.
                        """), false)
                }
                guard count == 0 else {
                    return (String(localized: "Nichts Neues. Alle passenden Stellen hast du schon gehört."), false)
                }
                // Welche Themen nichts treffen, steht mit Namen da.
                let labels = profile.interests
                    .filter { check.topicsWithoutHits.contains($0.id) }
                    .map(\.label)
                guard !labels.isEmpty else {
                    return (String(localized: "Zu diesen Themen passt noch keine Stelle in deinen Folgen mit Transkript."),
                            false)
                }
                let named = labels.formatted(.list(type: .and))
                return (String(localized: "Zu \(named) passt noch keine Stelle in deinen Folgen mit Transkript."),
                        false)
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

    /// Höchstens so viele Kapiteldateien lädt eine Ausgabe nach.
    static let chapterFileLimit = 12

    /// Die Kapitelmarken der Originalfolgen, aus denen eine Ausgabe
    /// schneiden kann. Kapitel aus dem Feed sind schon da. Verweist der Feed
    /// nur auf eine Kapiteldatei, lädt die App sie für die relevantesten
    /// Folgen einmal nach und behält sie wie beim Öffnen einer Folge.
    private func chapterMarks(for candidates: [SegmentCandidate]) async -> [EpisodeID: EpisodeChapters] {
        var ranked: [EpisodeID] = []
        for candidate in candidates.sorted(by: { $0.relevanceScore > $1.relevanceScore })
        where !ranked.contains(candidate.episodeID) {
            ranked.append(candidate.episodeID)
        }
        guard !ranked.isEmpty,
              let episodes = try? await store.episodes(ids: ranked) else { return [:] }
        let byID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var missing: [(EpisodeID, URL)] = []
        for id in ranked {
            guard let episode = byID[id], episode.publisherChapters.isEmpty,
                  chapterCache[id] == nil, let url = episode.chaptersURL else { continue }
            missing.append((id, url))
        }
        if !isOffline, !missing.isEmpty {
            let refresher = refresher
            let loaded = await withTaskGroup(of: (EpisodeID, [Chapter]?).self) { group in
                for (id, url) in missing.prefix(Self.chapterFileLimit) {
                    group.addTask { (id, await refresher.loadChapters(from: url)) }
                }
                var result: [EpisodeID: [Chapter]] = [:]
                for await (id, chapters) in group {
                    if let chapters, !chapters.isEmpty { result[id] = chapters }
                }
                return result
            }
            for (id, chapters) in loaded { chapterCache[id] = chapters }
        }

        var marks: [EpisodeID: EpisodeChapters] = [:]
        for (id, episode) in byID {
            let chapters = episode.publisherChapters.isEmpty ? (chapterCache[id] ?? []) : episode.publisherChapters
            guard !chapters.isEmpty else { continue }
            marks[id] = EpisodeChapters(chapters: chapters, duration: episode.declaredDuration)
        }
        return marks
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
        // Die Folge ist nicht mehr da. Was der Plan über sie weiß, bleibt
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
            if earliestAutomaticEdition(for: feed) != nil { continue }
            _ = await buildEdition(feedID: feed.id, requestedByUser: false)
        }
    }

    /// So lange ruht die Automatik nach einer Ausgabe, die noch nicht gehört ist.
    static let editionRestInterval: TimeInterval = 12 * 60 * 60
    /// Ab diesem Anteil gilt eine Ausgabe als gehört.
    static let editionHeardThreshold = 0.8

    /// Ruht die Automatik für dieses Update, bis wann? `nil`, wenn die
    /// nächste Prüfung eine Ausgabe veröffentlichen darf: es gibt noch
    /// keine, die letzte ist gehört oder älter als ``editionRestInterval``.
    func earliestAutomaticEdition(for feed: SmartPodcastFeed, now: Date = Date()) -> Date? {
        guard let latest = editions[feed.id]?.first,
              latest.heardFraction(in: ledger) < Self.editionHeardThreshold else { return nil }
        let earliest = latest.publishedAt.addingTimeInterval(Self.editionRestInterval)
        return earliest > now ? earliest : nil
    }

    /// Die Regel, nach der Ausgaben entstehen, in wenigen Sätzen.
    static func editionRule(for policy: PublicationPolicy) -> String {
        guard policy.isAutomatic else {
            return String(localized: "Neue Ausgaben entstehen nur, wenn du „Neue Ausgabe zusammenstellen“ antippst.")
        }
        let minimum = policy.minimumMaterial.shortDescription
        let hours = Int(editionRestInterval / 3_600)
        return String(localized: """
            Eine neue Ausgabe entsteht von selbst, sobald mindestens \(minimum) neues Material zu den Themen da ist \
            und du die letzte Ausgabe gehört hast oder sie älter als \(hours) Stunden ist. Das prüft die App, \
            wenn sie Podcasts aktualisiert oder Transkripte fertig werden. „Neue Ausgabe zusammenstellen“ \
            geht jederzeit, auch mit weniger Material.
            """)
    }

    /// Wann die nächste Ausgabe von selbst kommen kann, in einem Satz.
    func nextEditionHint(for feed: SmartPodcastFeed) -> String {
        let policy = feed.publicationPolicy
        guard policy.isAutomatic else {
            return String(localized: "Die nächste Ausgabe entsteht, wenn du sie zusammenstellst.")
        }
        let minimum = policy.minimumMaterial.shortDescription
        if let earliest = earliestAutomaticEdition(for: feed) {
            return String(localized: """
                Die nächste Ausgabe kommt frühestens \(Self.editionMoment(earliest)) oder sobald du diese gehört hast, \
                wenn dann mindestens \(minimum) neues Material da ist.
                """)
        }
        if let waiting = editionChecks[feed.id]?.waiting {
            return String(localized: """
                Die nächste Ausgabe kommt, sobald \(minimum) neues Material da ist. Zurzeit sind es \
                \(waiting.shortDescription).
                """)
        }
        return String(localized: "Die nächste Ausgabe kommt, sobald \(minimum) neues Material da ist.")
    }

    /// „heute um 18:40“, „morgen um 6:40“ oder „am 25. Sept. um 6:40“.
    static func editionMoment(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return String(localized: "heute um \(time)") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "morgen um \(time)") }
        return String(localized: "am \(date.formatted(.dateTime.day().month())) um \(time)")
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
        // sonst zurückgibt, wird verworfen. Jede Portion ist so groß, wie
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
            problem = [String(localized: "\(failed) von \(shortlist.count) Stellen ließen sich nicht einordnen."), reason]
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

    /// Sichert die geprüfte These als gesicherte Antwort. Aufbewahren heißt
    /// nicht zustimmen, die Karte sagt das auch. Ob sie gesichert ist, zeigen
    /// die Karten selbst: nach dem Löschen lässt sie sich wieder sichern.
    public func saveCounterpointCheck() {
        guard let check = counterpointCheck, !check.isRunning, !check.isSaved(in: trails),
              !check.candidates.isEmpty else { return }
        trails.insert(check.trail(question: String(localized: "These: \(check.thesis)")), at: 0)
        persistTrails()
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
                // Ausdrücklich gewählt heißt: auch dann abspielen, wenn es
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
        // Mobilfunk in den Einstellungen aus: fragen statt still streamen.
        // Ein Sprung in der Folge, die schon im Player liegt, fragt nicht
        // noch einmal. Sie läuft bereits aus dem Netz.
        if local == nil, episodePlayer.episode?.id != episode.id,
           askBeforeMobileData(.play(episode, at: seconds)) { return }
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
    /// anderen bleiben in der Liste, bis wieder Netz da ist. `false` heißt:
    /// es startet nichts. Die Kopfhörertaste springt dann 30 s vor.
    @discardableResult
    public func playNextInQueue() -> Bool {
        // Folgen ohne Ton (YouTube) hielten die Liste nur auf.
        if upNext.contains(where: { !canPlay($0) }) { upNext.removeAll { !canPlay($0) } }
        guard let next = upNext.first(where: canStartNow) else {
            if !upNext.isEmpty, isOffline {
                lastError = String(localized: """
                    Ohne Netz spielt nur, was auf diesem Gerät geladen ist. \
                    Keine Folge in „Als Nächstes“ ist geladen.
                    """)
            } else if !upNext.isEmpty {
                lastError = String(localized: """
                    Laden über Mobilfunk ist in den Einstellungen aus. \
                    Keine Folge in „Als Nächstes“ ist auf diesem Gerät geladen.
                    """)
            }
            return false
        }
        playEpisode(next)
        return true
    }

    /// Würde `playEpisode` diese Folge jetzt starten? Dieselben Bedingungen:
    /// eine geladene Datei, oder ein Stream und Netz. Ist Mobilfunk in den
    /// Einstellungen aus, zählt der Stream dort nicht. Das nächste Stück der
    /// Liste fragt dann nicht aus der Hosentasche, sondern die nächste
    /// geladene Folge läuft.
    private func canStartNow(_ episode: Episode) -> Bool {
        localAudioFile(for: episode) != nil || (episode.audioURL != nil && !isOffline && !mobileDataNeedsConsent)
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

    /// **Hier schließt sich der Kreis.**
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

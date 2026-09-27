//
//  MCPAccess.swift
//  PodcastAIKit
//
//  Kontrollierter Agentenzugang auf dem Mac.
//
//  Ein Agent wie Claude Desktop oder Claude Code soll fragen können
//  „Welche Aussagen habe ich zu lokaler KI gespeichert?“ und strukturierte
//  Quellen bekommen. Das ist etwas grundsätzlich anderes, als ihn machen zu
//  lassen, was er will. Die Grenzen stehen deshalb im Typsystem:
//
//  - Es gibt nur lesende Werkzeuge. Kein Werkzeug schreibt, löscht, ändert
//    Tags oder startet Wiedergabe. Diese Methoden gibt es hier nicht.
//  - Standardmäßig aus, und nur lokal über die Standardeingabe. Kein
//    Netzwerk-Port.
//  - Jede Freigabe nennt ihre Podcasts und läuft ab.
//  - Jede Anfrage landet im Protokoll, auch eine abgelehnte.
//
//  Schalter, Freigabe und Protokoll liegen in den Benutzereinstellungen.
//  Die App vergibt die Freigabe, der Prozess, den ein Agent mit `--mcp`
//  startet, liest sie bei jeder Anfrage und schreibt ins Protokoll. Beide
//  laufen im selben App-Container und sehen dieselben Einstellungen.
//
//  Der Code liegt im Paket und nicht in der Mac-App, damit `swift test`
//  ihn gegen einen echten Speicher prüfen kann. Gebaut wird er nur für
//  macOS, iPhone und iPad haben keinen Agentenzugang.
//

#if os(macOS)
import Foundation
import PodcastAICore
import PodcastAIKnowledge
import PodcastAIPersistence

/// Die Werkzeuge, die ein Agent bekommen kann. Vollständige Liste.
public enum MCPTool: String, CaseIterable, Codable, Sendable {
    case listPodcasts
    case listInterests
    case searchEvidence
    case getEvidence
    case listHighlights
    case listTrails

    /// Die Beschreibung im Werkzeugschema. Sie richtet sich an das Modell
    /// des Agenten. Claude Desktop und Claude Code zeigen sie aber auch dem
    /// Menschen, deshalb steht sie in der Sprache des Macs.
    public var summary: String {
        switch self {
        case .listPodcasts:
            String(localized: """
                Listet die Podcasts, die der Nutzer freigegeben hat: Kennung, Titel, Sprache und wie viele \
                Folgen ein Transkript haben. Ein guter erster Aufruf.
                """, bundle: .module)
        case .listInterests:
            String(localized: """
                Listet die Tags, denen der Nutzer in PodcastAI folgt, also seine Themen. Gilt für die ganze \
                Mediathek, nicht nur für die freigegebenen Podcasts.
                """, bundle: .module)
        case .searchEvidence:
            String(localized: """
                Sucht Stellen in den Transkripten der freigegebenen Podcasts, so wie der Chat der App: \
                Stichworte, gewichtet nach Seltenheit, und Sätze mit ähnlicher Bedeutung. Eine Stelle ist \
                etwa eine Minute Text mit Podcast, Folge, Datum und Zeitmarke. Am besten eine kurze Frage \
                oder zwei bis fünf Stichworte in der Sprache des Podcasts. Ein Begriff in einer anderen \
                Sprache findet meist nichts. Mit podcastID nur in einem Podcast aus listPodcasts.
                """, bundle: .module)
        case .getEvidence:
            String(localized: """
                Holt eine Stelle über ihre Kennung aus searchEvidence, listHighlights oder listTrails: Zitat, \
                Podcast, Folge, Datum und Zeitmarke.
                """, bundle: .module)
        case .listHighlights:
            String(localized: """
                Listet Stellen, die sich der Nutzer gemerkt hat, mit seiner Notiz, dem Zitat, Podcast, Folge \
                und Zeitmarke. Nur wenn der Nutzer Notizen freigegeben hat.
                """, bundle: .module)
        case .listTrails:
            String(localized: """
                Listet Antworten, die der Nutzer im Chat der App gesichert hat: Frage, Antwort, seine Notiz \
                und die Kennungen der Stellen dahinter. Nur wenn der Nutzer Notizen freigegeben hat.
                """, bundle: .module)
        }
    }

    /// Wie Protokoll und Agent das Werkzeug nennen. In der Sprache des Macs.
    public var title: String {
        switch self {
        case .listPodcasts: String(localized: "Freigegebene Podcasts auflisten", bundle: .module)
        case .listInterests: String(localized: "Gefolgte Tags lesen", bundle: .module)
        case .searchEvidence: String(localized: "In Folgen mit Transkript suchen", bundle: .module)
        case .getEvidence: String(localized: "Eine Fundstelle mit Quelle und Zeitmarke abrufen", bundle: .module)
        case .listHighlights: String(localized: "Gemerkte Stellen lesen", bundle: .module)
        case .listTrails: String(localized: "Gesicherte Antworten lesen", bundle: .module)
        }
    }

    /// Alle Werkzeuge sind lesend. Das ist keine Konvention, sondern der
    /// Grund, warum es keine anderen Fälle gibt.
    public var isReadOnly: Bool { true }
}

/// Eine zeitlich begrenzte Freigabe.
///
/// Sie gilt für alle Werkzeuge. Welche Podcasts der Agent sieht, steht in
/// `allowedSourceIDs`, ob er Notizen sieht, in `includesHighlights`.
public struct MCPGrant: Codable, Equatable, Sendable {

    /// Der Name, mit dem sich der Agent beim Verbinden meldet, etwa
    /// „claude-code“. `nil` heißt: jeder Agent, der PodcastAI auf diesem
    /// Mac startet. Den Namen meldet der Agent selbst. Er trennt Agenten,
    /// die sich ehrlich melden, und ist keine Sicherheitsgrenze.
    public let clientName: String?
    /// Worauf zugegriffen werden darf. Leer heißt: nichts.
    public let allowedSourceIDs: Set<SourceID>
    /// Gemerkte Stellen und gesicherte Antworten brauchen eine eigene
    /// Freigabe. Sie tragen eigene Notizen und sind damit privater als ein
    /// Transkriptausschnitt.
    public let includesHighlights: Bool
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        clientName: String? = nil, allowedSourceIDs: Set<SourceID>,
        includesHighlights: Bool = false, issuedAt: Date = Date(),
        validFor: TimeInterval = 60 * 60
    ) {
        self.clientName = clientName
        self.allowedSourceIDs = allowedSourceIDs
        self.includesHighlights = includesHighlights
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(validFor)
    }

    /// Wie lange die Freigabe ab ihrer Vergabe gilt.
    public var validity: TimeInterval { expiresAt.timeIntervalSince(issuedAt) }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }

    /// Dieselben Podcasts, derselbe Agent, dieselbe Dauer, ab jetzt.
    public func renewed(at now: Date = Date()) -> MCPGrant {
        MCPGrant(clientName: clientName, allowedSourceIDs: allowedSourceIDs,
                 includesHighlights: includesHighlights, issuedAt: now, validFor: validity)
    }

    /// Ob ein Agent mit diesem Namen die Freigabe nutzen darf.
    public func admits(client: String?) -> Bool {
        guard let clientName else { return true }
        return client == clientName
    }

    private enum CodingKeys: String, CodingKey {
        case clientName, allowedSourceIDs, includesHighlights, issuedAt, expiresAt
    }

    /// Freigaben bis 0.13 trugen einen freien Namen und eine Werkzeugliste.
    /// Beides wurde nie geprüft. Sie lesen sich als Freigabe für jeden
    /// Agenten, so wie sie schon immer wirkten.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientName = try container.decodeIfPresent(String.self, forKey: .clientName)
        allowedSourceIDs = try container.decode(Set<SourceID>.self, forKey: .allowedSourceIDs)
        includesHighlights = try container.decodeIfPresent(Bool.self, forKey: .includesHighlights) ?? false
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

/// Warum eine Anfrage nichts bekommt. Der Text geht an den Agenten, der
/// ihn meist wörtlich weitergibt. Er sagt deshalb, was der Mensch tun kann.
public enum MCPRefusal: Error, Equatable, Sendable {
    case switchedOff
    case noGrant
    case expired(at: Date)
    case otherClient(allowed: String, actual: String?)
    case notesExcluded
    case notFound

    /// Für das Protokoll: nur die Art, ohne Einzelheiten. Dazu zwei Arten,
    /// die keine Absage der Freigabe sind, aber ebenso ohne Ergebnis enden:
    /// ein unbrauchbares Argument und eine Mediathek, die sich nicht lesen ließ.
    public enum Kind: String, Codable, Sendable {
        case switchedOff, noGrant, expired, otherClient, notesExcluded, notFound
        case invalidArguments, failed

        /// Was das Protokoll in den Einstellungen anzeigt.
        public var label: String {
            switch self {
            case .switchedOff: String(localized: "Abgelehnt: Zugang aus", bundle: .module)
            case .noGrant: String(localized: "Abgelehnt: nichts freigegeben", bundle: .module)
            case .expired: String(localized: "Abgelehnt: Freigabe abgelaufen", bundle: .module)
            case .otherClient: String(localized: "Abgelehnt: anderer Agent", bundle: .module)
            case .notesExcluded: String(localized: "Abgelehnt: Notizen nicht freigegeben", bundle: .module)
            case .notFound: String(localized: "Nichts Freigegebenes gefunden", bundle: .module)
            case .invalidArguments: String(localized: "Abgelehnt: Angaben unbrauchbar", bundle: .module)
            case .failed: String(localized: "Fehler: Mediathek nicht lesbar", bundle: .module)
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .switchedOff: .switchedOff
        case .noGrant: .noGrant
        case .expired: .expired
        case .otherClient: .otherClient
        case .notesExcluded: .notesExcluded
        case .notFound: .notFound
        }
    }

    public var message: String {
        switch self {
        case .switchedOff:
            return String(localized: """
                Der Agentenzugang ist in PodcastAI ausgeschaltet. Einschalten lässt er sich in PodcastAI \
                unter Einstellungen › Agenten.
                """, bundle: .module)
        case .noGrant:
            return String(localized: """
                In PodcastAI ist nichts freigegeben. Freigeben lässt es sich in PodcastAI unter \
                Einstellungen › Agenten: Podcasts wählen, dann „Freigeben“.
                """, bundle: .module)
        case .expired(let date):
            let day = date.formatted(date: .abbreviated, time: .omitted)
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: """
                Die Freigabe in PodcastAI ist am \(day) um \(time) abgelaufen. Erneuern lässt sie sich in \
                PodcastAI unter Einstellungen › Agenten.
                """, bundle: .module)
        case .otherClient(let allowed, let actual):
            guard let actual else {
                return String(localized: """
                    Die Freigabe in PodcastAI gilt nur für den Agenten „\(allowed)“. Dieser Agent hat \
                    keinen Namen gemeldet. Unter Einstellungen › Agenten lässt sich die Freigabe für jeden \
                    Agenten erteilen.
                    """, bundle: .module)
            }
            return String(localized: """
                Die Freigabe in PodcastAI gilt nur für den Agenten „\(allowed)“, dieser meldet sich als \
                „\(actual)“. Unter Einstellungen › Agenten lässt sich die Freigabe für ihn erteilen.
                """, bundle: .module)
        case .notesExcluded:
            return String(localized: """
                Gemerkte Stellen und gesicherte Antworten sind in PodcastAI nicht freigegeben. Das lässt \
                sich unter Einstellungen › Agenten ändern.
                """, bundle: .module)
        case .notFound:
            return String(localized: "Zu dieser Kennung liegt nichts Freigegebenes vor.", bundle: .module)
        }
    }
}

/// Eine Werkzeuganfrage mit geprüften Argumenten.
public enum MCPToolRequest: Equatable, Sendable {
    case listPodcasts
    case listInterests
    /// `podcastID` grenzt auf einen Podcast ein. Liegt er außerhalb der
    /// Freigabe, bleibt die Suche leer.
    case searchEvidence(query: String, limit: Int, podcastID: String? = nil)
    case getEvidence(id: String)
    case listHighlights(limit: Int)
    case listTrails(limit: Int)

    public var tool: MCPTool {
        switch self {
        case .listPodcasts: .listPodcasts
        case .listInterests: .listInterests
        case .searchEvidence: .searchEvidence
        case .getEvidence: .getEvidence
        case .listHighlights: .listHighlights
        case .listTrails: .listTrails
        }
    }

    /// Was im Protokoll neben dem Werkzeug steht. Gekürzt, denn den Text
    /// wählt der Agent, und 200 Einträge mit je einer langen Zeile machten
    /// die Einstellungen der App groß und langsam.
    var loggedQuery: String? {
        let text: String? = switch self {
        case .searchEvidence(let query, _, _): query
        case .getEvidence(let id): id
        default: nil
        }
        return text.map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
    }
}

/// Was ein Werkzeug liefert.
public enum MCPToolResult: Sendable {
    /// Immer ein JSON-Objekt, nie eine Liste. MCP verlangt für
    /// `structuredContent` ein Objekt, und Claude Desktop, Claude Code und
    /// das offizielle SDK lehnen eine Liste als ungültige Antwort ab.
    case success(any Encodable & Sendable)
    case refused(MCPRefusal)
    /// Die Mediathek ließ sich nicht lesen.
    case failed(String)
}

/// Der lokale Zugang. Standardmäßig aus.
@MainActor
public final class MCPAccess {

    private static let enabledKey = "com.podcastai.mcp.enabled"
    private static let grantKey = "com.podcastai.mcp.grant"
    private static let auditKey = "com.podcastai.mcp.audit"
    private static let clientsKey = "com.podcastai.mcp.clients"
    private static let auditLimit = 200
    private static let clientLimit = 10
    /// So viele Stellen bekommen je Suche eine Satzeinbettung. Der Chat der
    /// App nimmt weniger, er muss schneller antworten als ein Werkzeug.
    private static let embeddingLimit = 48

    private let store: LibraryStore
    private let defaults: UserDefaults
    /// Ein eigener Index statt des gemeinsamen der App. Er lebt so lange
    /// wie der Prozess des Agenten.
    private let passageIndex = PassageIndex()

    /// Ein Eintrag im Protokoll.
    public struct AuditEntry: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let tool: MCPTool
        public let query: String?
        public let resultCount: Int
        public let at: Date
        /// Mit welchem Namen sich der Agent gemeldet hat.
        public let client: String?
        /// Gesetzt, wenn die Anfrage nichts bekam.
        public let refusal: MCPRefusal.Kind?

        init(tool: MCPTool, query: String?, resultCount: Int, at: Date,
             client: String?, refusal: MCPRefusal.Kind?) {
            self.id = UUID()
            self.tool = tool
            self.query = query
            self.resultCount = resultCount
            self.at = at
            self.client = client
            self.refusal = refusal
        }

        private enum CodingKeys: String, CodingKey {
            case id, tool, query, resultCount, at, client, refusal
        }

        /// Einträge bis 0.13 kennen weder Agent noch Ablehnung.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            tool = try container.decode(MCPTool.self, forKey: .tool)
            query = try container.decodeIfPresent(String.self, forKey: .query)
            resultCount = try container.decode(Int.self, forKey: .resultCount)
            at = try container.decode(Date.self, forKey: .at)
            client = try container.decodeIfPresent(String.self, forKey: .client)
            refusal = try container.decodeIfPresent(MCPRefusal.Kind.self, forKey: .refusal)
        }
    }

    /// Ein Agent, der sich schon einmal gemeldet hat.
    public struct ClientRecord: Identifiable, Codable, Equatable, Sendable {
        public let name: String
        public let version: String?
        public let lastSeen: Date
        public var id: String { name }
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { revoke() }
        }
    }

    /// Die geltende Freigabe, bei jedem Zugriff frisch gelesen. Ein Widerruf
    /// in der App gilt damit auch für einen Agenten, der gerade verbunden ist.
    public var grant: MCPGrant? {
        guard let data = defaults.data(forKey: Self.grantKey) else { return nil }
        return try? JSONDecoder().decode(MCPGrant.self, from: data)
    }

    /// Was zuletzt abgefragt wurde, neueste zuerst, auch Abgelehntes.
    public var auditLog: [AuditEntry] {
        guard let data = defaults.data(forKey: Self.auditKey),
              let entries = try? JSONDecoder().decode([Lossy<AuditEntry>].self, from: data) else { return [] }
        return entries.compactMap(\.value)
    }

    /// Agenten, die sich schon einmal verbunden haben, zuletzt gesehene zuerst.
    public var knownClients: [ClientRecord] {
        guard let data = defaults.data(forKey: Self.clientsKey),
              let records = try? JSONDecoder().decode([Lossy<ClientRecord>].self, from: data) else { return [] }
        return records.compactMap(\.value)
    }

    public init(store: LibraryStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// Vergibt eine Freigabe. Nur bei eingeschaltetem Zugang, und sie
    /// ersetzt die vorige.
    public func authorize(_ grant: MCPGrant) {
        guard isEnabled, let data = try? JSONEncoder().encode(grant) else { return }
        defaults.set(data, forKey: Self.grantKey)
    }

    public func revoke() {
        defaults.removeObject(forKey: Self.grantKey)
    }

    /// Merkt sich einen Agenten, der sich gemeldet hat. Die Einstellungen
    /// bieten seinen Namen zur Wahl an, so muss ihn niemand abtippen.
    public func noteClient(name: String, version: String?, at now: Date = Date()) {
        var records = knownClients.filter { $0.name != name }
        records.insert(ClientRecord(name: name, version: version, lastSeen: now), at: 0)
        if records.count > Self.clientLimit { records.removeLast(records.count - Self.clientLimit) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.clientsKey)
    }

    /// Ob eine Anfrage dieses Agenten jetzt etwas bekommt.
    public func permission(client: String?, at now: Date = Date()) -> Result<MCPGrant, MCPRefusal> {
        guard isEnabled else { return .failure(.switchedOff) }
        guard let grant else { return .failure(.noGrant) }
        guard !grant.isExpired(at: now) else { return .failure(.expired(at: grant.expiresAt)) }
        guard grant.admits(client: client) else {
            return .failure(.otherClient(allowed: grant.clientName ?? "", actual: client))
        }
        return .success(grant)
    }

    /// Führt ein Werkzeug aus. Schalter und Freigabe werden bei jeder
    /// Anfrage frisch gelesen, und jede Anfrage landet im Protokoll.
    public func run(_ request: MCPToolRequest, client: String?, at now: Date = Date()) async -> MCPToolResult {
        let grant: MCPGrant
        switch permission(client: client, at: now) {
        case .failure(let refusal):
            log(request.tool, query: request.loggedQuery, count: 0, client: client, refusal: refusal.kind)
            return .refused(refusal)
        case .success(let granted):
            grant = granted
        }

        do {
            let (result, count) = try await perform(request, grant: grant)
            if case .refused(let refusal) = result {
                log(request.tool, query: request.loggedQuery, count: 0, client: client, refusal: refusal.kind)
            } else {
                log(request.tool, query: request.loggedQuery, count: count, client: client, refusal: nil)
            }
            return result
        } catch {
            log(request.tool, query: request.loggedQuery, count: 0, client: client, refusal: .failed)
            return .failed(String(localized: """
                PodcastAI konnte die Mediathek nicht lesen. \(error.localizedDescription)
                """, bundle: .module))
        }
    }

    // MARK: - Werkzeuge

    private func perform(_ request: MCPToolRequest, grant: MCPGrant) async throws -> (MCPToolResult, Int) {
        switch request {
        case .listPodcasts:
            let podcasts = try await listPodcasts(grant: grant)
            return (.success(MCPPodcastList(podcasts: podcasts)), podcasts.count)

        case .listInterests:
            let profile = try await store.interestProfile(learningEnabled: false)
            // Nur Tags, denen jemand folgt. Was PodcastAI bloß vermutet oder
            // im Inhalt erkannt hat, und Tags mit Minus gehen keinen Agenten an.
            let labels = profile.followed.map(\.label)
            return (.success(MCPInterestList(interests: labels)), labels.count)

        case .searchEvidence(let query, let limit, let podcastID):
            let result = try await searchEvidence(query, limit: limit, podcastID: podcastID, grant: grant)
            return (.success(result), result.results.count)

        case .getEvidence(let id):
            let evidenceID = EvidenceID(rawValue: id)
            guard let item = try await store.evidence(ids: [evidenceID])[evidenceID],
                  grant.allowedSourceIDs.contains(item.sourceID) else {
                // Nicht gefunden und nicht freigegeben sehen von außen gleich
                // aus. Sonst verriete die Antwort, welche Kennungen es gibt.
                return (.refused(.notFound), 0)
            }
            let summary = try await summaries(for: [item]).first ?? EvidenceSummary(item)
            return (.success(summary), 1)

        case .listHighlights(let limit):
            guard grant.includesHighlights else { return (.refused(.notesExcluded), 0) }
            let highlights = try await listHighlights(limit: limit, grant: grant)
            return (.success(MCPHighlightList(highlights: highlights)), highlights.count)

        case .listTrails(let limit):
            guard grant.includesHighlights else { return (.refused(.notesExcluded), 0) }
            let trails = try await listTrails(limit: limit, grant: grant)
            return (.success(MCPTrailList(trails: trails)), trails.count)
        }
    }

    private func listPodcasts(grant: MCPGrant) async throws -> [PodcastSummary] {
        let sources = try await store.sources().filter { grant.allowedSourceIDs.contains($0.id) }
        await store.forgetCachedEvidence()
        var episodes: [SourceID: Set<EpisodeID>] = [:]
        for item in try await store.evidenceForAnalyzedEpisodes() where grant.allowedSourceIDs.contains(item.sourceID) {
            episodes[item.sourceID, default: []].insert(item.episodeID)
        }
        return sources.map { source in
            PodcastSummary(id: source.id.rawValue, title: source.title, author: source.author,
                           language: source.language, episodesWithTranscript: episodes[source.id]?.count ?? 0)
        }
    }

    /// Sucht wie der Chat der App: Stichworte gewichtet nach Seltenheit und
    /// Sätze mit ähnlicher Bedeutung über Apples NaturalLanguage, beides auf
    /// dem Gerät und ohne Sprachmodell.
    private func searchEvidence(_ query: String, limit: Int, podcastID: String?,
                                grant: MCPGrant) async throws -> MCPSearchResult {
        // Der Prozess eines Agenten läuft oft eine ganze Sitzung lang. Was
        // die App inzwischen transkribiert hat, fände die Suche sonst nie,
        // denn der Speicher merkt sich die Belege bis zur nächsten eigenen
        // Änderung.
        await store.forgetCachedEvidence()
        let all = try await store.evidenceForAnalyzedEpisodes()

        // Scope zuerst: was nicht freigegeben ist, wird gar nicht erst durchsucht.
        // Ein Podcast außerhalb der Freigabe ergibt dieselbe leere Menge
        // wie einer ohne Transkript. Die Antwort verrät nicht, ob es ihn gibt.
        let wanted = podcastID.map { SourceID(rawValue: $0) }
        let inScope = all.filter { item in
            grant.allowedSourceIDs.contains(item.sourceID) && (wanted == nil || item.sourceID == wanted)
        }
        guard !inScope.isEmpty else {
            return MCPSearchResult(results: [], hint: wanted == nil
                ? MCPSearchResult.nothingTranscribed : MCPSearchResult.podcastEmpty)
        }
        let ranker = PassageRanker(index: passageIndex)
        let embeddingLimit = Self.embeddingLimit
        let found = await Task.detached(priority: .userInitiated) {
            ranker.rank(inScope, for: query, limit: limit, embeddingLimit: embeddingLimit)
        }.value
        let results = try await summaries(for: found)
        return MCPSearchResult(results: results, hint: results.isEmpty ? MCPSearchResult.noMatch : nil)
    }

    /// Gemerkte Stellen im freigegebenen Bereich.
    private func listHighlights(limit: Int, grant: MCPGrant) async throws -> [HighlightSummary] {
        let all = try await store.highlights()
        let evidenceByID = try await store.evidence(ids: all.map(\.evidenceID))
        // Aus dem Player Gemerktes hat meist keinen gespeicherten Beleg. Der
        // Scope gilt dann über die Folge und ihre Quelle.
        let withoutEvidence = all.filter { evidenceByID[$0.evidenceID] == nil }.compactMap(\.episodeID)
        let sourceOfEpisode = withoutEvidence.isEmpty ? [:] : Dictionary(
            try await store.episodes(ids: withoutEvidence).map { ($0.id, $0.sourceID) },
            uniquingKeysWith: { first, _ in first })
        let titles = try await store.titles(forEpisodes: all.compactMap { highlight in
            highlight.episodeID ?? evidenceByID[highlight.evidenceID]?.episodeID
        })
        let podcasts = try await podcastTitles()

        var results: [HighlightSummary] = []
        for highlight in all {
            guard results.count < limit else { break }
            // Ohne Stelle keine Ausgabe: eine Notiz ohne die Stelle, auf die
            // sie sich bezieht, ist für einen Agenten wertlos und für den
            // Nutzer eine Preisgabe ohne Gegenwert.
            if let evidence = evidenceByID[highlight.evidenceID] {
                guard grant.allowedSourceIDs.contains(evidence.sourceID) else { continue }
                let episode = titles[evidence.episodeID]
                results.append(HighlightSummary(
                    id: highlight.id.rawValue, note: highlight.note, capturedAt: highlight.capturedAt,
                    podcast: podcasts[evidence.sourceID] ?? highlight.sourceTitle,
                    episode: episode?.episode ?? highlight.episodeTitle,
                    quotedText: evidence.quotedText, startSeconds: evidence.range?.start.seconds,
                    evidenceID: evidence.id.rawValue))
                continue
            }
            // Die Kopie von Zitat und Zeitmarke, die beim Merken mitgesichert
            // wurde. Eine Kennung für getEvidence gibt es dazu nicht.
            guard let episodeID = highlight.episodeID,
                  let sourceID = sourceOfEpisode[episodeID],
                  grant.allowedSourceIDs.contains(sourceID),
                  let quote = highlight.quote else { continue }
            results.append(HighlightSummary(
                id: highlight.id.rawValue, note: highlight.note, capturedAt: highlight.capturedAt,
                podcast: podcasts[sourceID] ?? highlight.sourceTitle,
                episode: titles[episodeID]?.episode ?? highlight.episodeTitle,
                quotedText: quote, startSeconds: highlight.positionMs.map { Double($0) / 1000 },
                evidenceID: nil))
        }
        return results
    }

    /// Gesicherte Antworten im freigegebenen Bereich.
    ///
    /// Eine Antwort zeigt auf Stellen. Liegt eine davon außerhalb der
    /// Freigabe, fehlt die ganze Antwort; sonst stünde ein Zitat aus einem
    /// nicht freigegebenen Podcast im Antworttext. Den Antworttext gibt es
    /// nur, wenn jede zitierte Stelle noch da ist und im Bereich liegt.
    ///
    /// Zeigt eine Antwort auf Stellen oder Folgen, von denen keine mehr zu
    /// finden ist, lässt sich nicht prüfen, aus welchem Podcast sie stammt.
    /// Sie fehlt dann ebenfalls. Nur eine Frage ganz ohne Stellen, die der
    /// Nutzer selbst gesichert hat, gehört keinem Podcast und bleibt.
    private func listTrails(limit: Int, grant: MCPGrant) async throws -> [TrailSummary] {
        let trails = try await store.trails()
        let cited = trails.flatMap(Self.citedEvidence)
        let evidenceByID = try await store.evidence(ids: cited)
        let referenced = Array(Set(trails.flatMap { $0.referencedEpisodeIDs ?? [] }))
        let sourceOfEpisode = referenced.isEmpty ? [:] : Dictionary(
            try await store.episodes(ids: referenced).map { ($0.id, $0.sourceID) },
            uniquingKeysWith: { first, _ in first })

        var results: [TrailSummary] = []
        for trail in trails {
            guard results.count < limit else { break }
            let citations = Self.citedEvidence(of: trail)
            let found = citations.compactMap { evidenceByID[$0] }
            let episodes = trail.referencedEpisodeIDs ?? []
            let sources = found.map(\.sourceID) + episodes.compactMap { sourceOfEpisode[$0] }
            let pointsSomewhere = !citations.isEmpty || !episodes.isEmpty
            guard !(pointsSomewhere && sources.isEmpty),
                  sources.allSatisfy(grant.allowedSourceIDs.contains) else { continue }
            let complete = !citations.isEmpty && found.count == citations.count
            results.append(TrailSummary(
                id: trail.id.rawValue, question: trail.question,
                answer: complete ? trail.answerText : nil,
                note: trail.userNote, parkedAt: trail.parkedAt,
                evidenceIDs: found.map(\.id.rawValue)))
        }
        return results
    }

    /// Jede Stelle, auf die eine gesicherte Antwort zeigt, ohne Doppelte.
    private static func citedEvidence(of trail: KnowledgeTrail) -> [EvidenceID] {
        var seen = Set<EvidenceID>()
        let all = trail.evidenceIDs + trail.counterpointEvidenceIDs
            + (trail.citationNumbers ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        return all.filter { seen.insert($0).inserted }
    }

    /// Belege mit Podcast, Folge und Datum.
    private func summaries(for evidence: [Evidence]) async throws -> [EvidenceSummary] {
        guard !evidence.isEmpty else { return [] }
        let titles = try await store.titles(forEpisodes: evidence.map(\.episodeID))
        let podcasts = try await podcastTitles()
        return evidence.map { item in
            let episode = titles[item.episodeID]
            return EvidenceSummary(item, podcast: podcasts[item.sourceID] ?? episode?.source,
                                   episode: episode?.episode, publishedAt: episode?.publishedAt)
        }
    }

    private func podcastTitles() async throws -> [SourceID: String] {
        Dictionary(try await store.sources().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Protokoll

    /// Ein Aufruf, dessen Argumente nicht passten. Er kommt nie bis zur
    /// Freigabe, steht aber im Protokoll wie jede andere Anfrage.
    public func noteInvalidArguments(for tool: MCPTool, client: String?) {
        log(tool, query: nil, count: 0, client: client, refusal: .invalidArguments)
    }

    private func log(_ tool: MCPTool, query: String?, count: Int, client: String?, refusal: MCPRefusal.Kind?) {
        var entries = auditLog
        entries.insert(AuditEntry(tool: tool, query: query, resultCount: count,
                                  at: Date(), client: client, refusal: refusal), at: 0)
        if entries.count > Self.auditLimit { entries.removeLast(entries.count - Self.auditLimit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.auditKey)
    }
}

/// Liest eine Liste weiter, auch wenn ein einzelner Eintrag nicht passt.
/// Ein Eintrag aus einer anderen Fassung der App leerte sonst das ganze
/// Protokoll.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
#endif

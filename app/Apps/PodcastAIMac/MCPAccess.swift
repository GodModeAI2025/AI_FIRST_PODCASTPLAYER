//
//  MCPAccess.swift
//  PodcastAI (macOS)
//
//  Kontrollierter Agentenzugang auf dem Mac.
//
//  Ein anderer Agent soll fragen können „Welche Aussagen habe ich zu
//  lokaler KI gespeichert?“ und strukturierte Quellen bekommen. Das ist
//  etwas grundsätzlich anderes, als ihn machen zu lassen, was er will.
//
//  Die Grenzen sind deshalb im Typsystem gezogen, nicht in einer
//  Dokumentationszeile:
//
//  - Es gibt **nur lesende Werkzeuge.** Kein Werkzeug schreibt, löscht,
//    ändert Interessen oder startet Wiedergabe. Diese Methoden existieren
//    hier schlicht nicht.
//  - Standardmäßig **aus**, und nur lokal über stdio. Kein Netzwerk-Port,
//    kein Lauschen im LAN.
//  - Jede Freigabe hat einen **Scope** und läuft ab.
//
//  Schalter, Freigabe und Protokoll liegen in den Einstellungen der App,
//  nicht nur im Speicher eines Objekts. Die App vergibt die Freigabe; der
//  Prozess, den ein Agent mit `--mcp` startet, liest sie bei jeder Anfrage
//  und schreibt ins Protokoll. Beide laufen im selben App-Container und
//  sehen deshalb dieselben Einstellungen.
//

import Foundation
import PodcastAIKit

/// Die Werkzeuge, die ein Agent bekommen kann. Vollständige Liste.
public enum MCPTool: String, CaseIterable, Codable, Sendable {
    case listInterests
    case searchEvidence
    case getEvidence
    case listHighlights
    case listTrails

    /// Die Beschreibung im Werkzeugschema für den Agenten. Bleibt deutsch
    /// und wird nicht übersetzt.
    public var summary: String {
        switch self {
        case .listInterests: "Bestätigte Interessen lesen"
        case .searchEvidence: "In den Transkripten suchen"
        case .getEvidence: "Eine Fundstelle mit Quelle und Timecode abrufen"
        case .listHighlights: "Gemerkte Stellen lesen"
        case .listTrails: "Gesicherte Antworten lesen"
        }
    }

    /// Wie das Protokoll in den Einstellungen das Werkzeug nennt. In der
    /// Sprache des Geräts und mit den Begriffen der App.
    public var title: String {
        switch self {
        case .listInterests: String(localized: "Bestätigte Interessen lesen")
        case .searchEvidence: String(localized: "In Folgen mit Transkript suchen")
        case .getEvidence: String(localized: "Eine Fundstelle mit Quelle und Zeitmarke abrufen")
        case .listHighlights: String(localized: "Gemerkte Stellen lesen")
        case .listTrails: String(localized: "Gesicherte Antworten lesen")
        }
    }

    /// Alle Werkzeuge sind lesend. Diese Eigenschaft ist keine Konvention,
    /// sondern der Grund, warum es keine anderen Fälle gibt.
    public var isReadOnly: Bool { true }
}

/// Eine zeitlich begrenzte Freigabe für einen Agenten.
public struct MCPGrant: Codable, Equatable, Sendable {

    public let agentName: String
    public let tools: Set<MCPTool>
    /// Worauf zugegriffen werden darf. Leer heißt: nichts.
    public let allowedSourceIDs: Set<SourceID>
    /// Auch gemerkte Stellen brauchen eine eigene Freigabe — sie enthalten
    /// eigene Notizen und sind damit privater als ein Transkriptausschnitt.
    public let includesHighlights: Bool
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        agentName: String, tools: Set<MCPTool>, allowedSourceIDs: Set<SourceID>,
        includesHighlights: Bool = false, issuedAt: Date = Date(),
        validFor: TimeInterval = 60 * 60
    ) {
        self.agentName = agentName; self.tools = tools
        self.allowedSourceIDs = allowedSourceIDs
        self.includesHighlights = includesHighlights
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(validFor)
    }

    public func permits(_ tool: MCPTool, at now: Date = Date()) -> Bool {
        tools.contains(tool) && now < expiresAt
    }
}

/// Der lokale Zugang. Standardmäßig aus.
@MainActor
public final class MCPAccess {

    private static let enabledKey = "com.podcastai.mcp.enabled"
    private static let grantKey = "com.podcastai.mcp.grant"
    private static let auditKey = "com.podcastai.mcp.audit"
    private static let auditLimit = 200

    private let store: LibraryStore
    private let defaults: UserDefaults

    public struct AuditEntry: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let tool: MCPTool
        public let query: String?
        public let resultCount: Int
        public let at: Date

        init(tool: MCPTool, query: String?, resultCount: Int, at: Date) {
            self.id = UUID()
            self.tool = tool
            self.query = query
            self.resultCount = resultCount
            self.at = at
        }
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

    /// Was zuletzt abgefragt wurde, neueste zuerst. Der Nutzer soll sehen
    /// können, was ein Agent tatsächlich gelesen hat. Ein Zugang ohne
    /// Protokoll ist kein kontrollierter Zugang.
    public var auditLog: [AuditEntry] {
        guard let data = defaults.data(forKey: Self.auditKey) else { return [] }
        return (try? JSONDecoder().decode([AuditEntry].self, from: data)) ?? []
    }

    public init(store: LibraryStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public func authorize(_ grant: MCPGrant) {
        guard isEnabled, let data = try? JSONEncoder().encode(grant) else { return }
        defaults.set(data, forKey: Self.grantKey)
    }

    public func revoke() {
        defaults.removeObject(forKey: Self.grantKey)
    }

    // MARK: - Werkzeuge

    public func listInterests() async -> [String] {
        guard let grant, grant.permits(.listInterests) else { return [] }
        let profile = (try? await store.interestProfile(learningEnabled: false))
            ?? InterestProfile()
        // Nur Tags, denen jemand folgt. Was PodcastAI bloß vermutet oder im
        // Inhalt erkannt hat, und Tags nach Minus gehen keinen Agenten an.
        let labels = profile.followed.map(\.label)
        log(.listInterests, query: nil, count: labels.count)
        return labels
    }

    /// Sucht im ausgewerteten Bestand, begrenzt auf freigegebene Quellen.
    public func searchEvidence(_ query: String, limit: Int = 20) async -> [EvidenceSummary] {
        guard let grant, grant.permits(.searchEvidence) else { return [] }
        guard let all = try? await store.evidenceForAnalyzedEpisodes() else { return [] }

        // Scope zuerst: was nicht freigegeben ist, wird gar nicht erst durchsucht.
        let inScope = all.filter { grant.allowedSourceIDs.contains($0.sourceID) }
        let asQuestion = Interest(label: query, kind: .openQuestion)
        let matches = RelevanceScorer(threshold: 0.15, maximumPerInterest: limit)
            .score(evidence: inScope, profile: InterestProfile(interests: [asQuestion]))

        let byID = Dictionary(uniqueKeysWithValues: inScope.map { ($0.id, $0) })
        let results = matches.prefix(limit).compactMap { match -> EvidenceSummary? in
            guard let item = byID[match.evidenceID] else { return nil }
            return EvidenceSummary(item)
        }
        log(.searchEvidence, query: query, count: results.count)
        return Array(results)
    }

    public func getEvidence(_ id: String) async -> EvidenceSummary? {
        guard let grant, grant.permits(.getEvidence) else { return nil }
        let evidenceID = EvidenceID(rawValue: id)
        guard let found = try? await store.evidence(ids: [evidenceID]),
              let item = found[evidenceID],
              grant.allowedSourceIDs.contains(item.sourceID) else { return nil }
        log(.getEvidence, query: id, count: 1)
        return EvidenceSummary(item)
    }

    /// Gemerkte Stellen.
    ///
    /// Eigene Freigabe, nicht in `allowedSourceIDs` enthalten: eine gemerkte
    /// Stelle trägt die Notiz des Nutzers und ist damit privater als ein
    /// Transkriptausschnitt. Wer Quellen freigibt, gibt nicht Notizen frei.
    public func listHighlights(limit: Int = 50) async -> [HighlightSummary] {
        guard let grant, grant.permits(.listHighlights), grant.includesHighlights else {
            return []
        }
        guard let all = try? await store.highlights() else { return [] }

        let evidenceByID = (try? await store.evidence(ids: all.map(\.evidenceID))) ?? [:]
        // Aus dem Player Gemerktes hat meist keinen gespeicherten Beleg. Der
        // Scope gilt dann über die Folge und ihre Quelle.
        let withoutEvidence = all.filter { evidenceByID[$0.evidenceID] == nil }.compactMap(\.episodeID)
        let sourceOfEpisode = withoutEvidence.isEmpty ? [:] : Dictionary(
            ((try? await store.episodes(ids: withoutEvidence)) ?? []).map { ($0.id, $0.sourceID) },
            uniquingKeysWith: { first, _ in first })
        let results = all.prefix(limit).compactMap { highlight -> HighlightSummary? in
            // Ohne Stelle keine Ausgabe: eine Notiz ohne die Stelle, auf die
            // sie sich bezieht, ist für einen Agenten wertlos und für den
            // Nutzer eine Preisgabe ohne Gegenwert.
            if let evidence = evidenceByID[highlight.evidenceID] {
                guard grant.allowedSourceIDs.contains(evidence.sourceID) else { return nil }
                return HighlightSummary(
                    id: highlight.id.rawValue,
                    note: highlight.note,
                    capturedAt: highlight.capturedAt,
                    evidence: EvidenceSummary(evidence))
            }
            // Die Kopie von Zitat und Zeitmarke, die beim Merken mitgesichert wurde.
            guard let episodeID = highlight.episodeID,
                  let sourceID = sourceOfEpisode[episodeID],
                  grant.allowedSourceIDs.contains(sourceID),
                  let quote = highlight.quote else { return nil }
            return HighlightSummary(
                id: highlight.id.rawValue,
                note: highlight.note,
                capturedAt: highlight.capturedAt,
                evidence: EvidenceSummary(
                    id: highlight.evidenceID.rawValue, quotedText: quote,
                    startSeconds: highlight.positionMs.map { Double($0) / 1000 }))
        }
        log(.listHighlights, query: nil, count: results.count)
        return Array(results)
    }

    /// Geparkte Wissenslandkarten.
    ///
    /// Nur Frage und Notiz, keine Belegkennungen: welche Stellen dahinter
    /// stehen, kann der Agent über `searchEvidence` im freigegebenen Bereich
    /// erfragen — über diesen Weg soll er den Scope nicht umgehen.
    public func listTrails(limit: Int = 50) async -> [TrailSummary] {
        guard let grant, grant.permits(.listTrails), grant.includesHighlights else {
            return []
        }
        guard let all = try? await store.trails() else { return [] }
        let results = all.prefix(limit).map {
            TrailSummary(id: $0.id.rawValue, question: $0.question,
                         note: $0.userNote, parkedAt: $0.parkedAt)
        }
        log(.listTrails, query: nil, count: results.count)
        return Array(results)
    }

    private func log(_ tool: MCPTool, query: String?, count: Int) {
        var entries = auditLog
        entries.insert(AuditEntry(tool: tool, query: query, resultCount: count, at: Date()), at: 0)
        if entries.count > Self.auditLimit { entries.removeLast(entries.count - Self.auditLimit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.auditKey)
    }
}

/// Was ein Agent zu sehen bekommt.
///
/// Bewusst eine eigene Form statt des Domänentyps: hier wird entschieden,
/// was nach draußen geht. Interne Kennungen von Medienfassung und
/// Transkriptrevision gehören nicht dazu — der Agent braucht Quelle, Zeit
/// und Text.
public struct EvidenceSummary: Codable, Sendable {

    public let id: String
    public let quotedText: String
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let speaker: String?

    init(_ evidence: Evidence) {
        self.id = evidence.id.rawValue
        self.quotedText = evidence.quotedText
        self.startSeconds = evidence.range?.start.seconds
        self.endSeconds = evidence.range?.end.seconds
        self.speaker = evidence.attributedSpeaker
    }

    /// Für eine gemerkte Stelle ohne gespeicherten Beleg.
    init(id: String, quotedText: String, startSeconds: Double?) {
        self.id = id
        self.quotedText = quotedText
        self.startSeconds = startSeconds
        self.endSeconds = nil
        self.speaker = nil
    }
}

/// Eine gemerkte Stelle, wie ein Agent sie sieht.
public struct HighlightSummary: Codable, Sendable {
    public let id: String
    public let note: String?
    public let capturedAt: Date
    public let evidence: EvidenceSummary
}

/// Eine geparkte Frage, wie ein Agent sie sieht.
public struct TrailSummary: Codable, Sendable {
    public let id: String
    public let question: String
    public let note: String?
    public let parkedAt: Date
}

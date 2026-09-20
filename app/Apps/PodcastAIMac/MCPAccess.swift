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
//  - Standardmässig **aus**, und nur lokal über stdio. Kein Netzwerk-Port,
//    kein Lauschen im LAN.
//  - Jede Freigabe hat einen **Scope** und läuft ab.
//

import Foundation
import PodcastAIKit

/// Die Werkzeuge, die ein Agent bekommen kann. Vollständige Liste.
public enum MCPTool: String, CaseIterable, Sendable {
    case listInterests
    case searchEvidence
    case getEvidence
    case listHighlights
    case listTrails

    public var summary: String {
        switch self {
        case .listInterests: "Bestätigte Interessen lesen"
        case .searchEvidence: "Im erschlossenen Bestand suchen"
        case .getEvidence: "Eine Fundstelle mit Quelle und Timecode abrufen"
        case .listHighlights: "Gemerkte Stellen lesen"
        case .listTrails: "Geparkte Wissenslandkarten lesen"
        }
    }

    /// Alle Werkzeuge sind lesend. Diese Eigenschaft ist keine Konvention,
    /// sondern der Grund, warum es keine anderen Fälle gibt.
    public var isReadOnly: Bool { true }
}

/// Eine zeitlich begrenzte Freigabe für einen Agenten.
public struct MCPGrant: Sendable {

    public let agentName: String
    public let tools: Set<MCPTool>
    /// Worauf zugegriffen werden darf. Leer heisst: nichts.
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

/// Der lokale Zugang. Standardmässig aus.
@MainActor
public final class MCPAccess {

    private let enabledKey = "com.podcastai.mcp.enabled"

    public private(set) var grant: MCPGrant?
    private let store: LibraryStore

    /// Was zuletzt abgefragt wurde — der Nutzer soll sehen können, was ein
    /// Agent tatsächlich gelesen hat. Ein Zugang ohne Protokoll ist kein
    /// kontrollierter Zugang.
    public private(set) var auditLog: [AuditEntry] = []

    public struct AuditEntry: Identifiable, Sendable {
        public let id = UUID()
        public let tool: MCPTool
        public let query: String?
        public let resultCount: Int
        public let at: Date
    }

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { grant = nil }
        }
    }

    public init(store: LibraryStore) {
        self.store = store
    }

    public func authorize(_ grant: MCPGrant) {
        guard isEnabled else { return }
        self.grant = grant
    }

    public func revoke() {
        grant = nil
    }

    // MARK: - Werkzeuge

    public func listInterests() async -> [String] {
        guard let grant, grant.permits(.listInterests) else { return [] }
        let profile = (try? await store.interestProfile(learningEnabled: false))
            ?? InterestProfile()
        // Nur bestätigte. Was PodcastAI bloss vermutet, geht keinen Agenten an.
        let labels = profile.confirmed.map(\.label)
        log(.listInterests, query: nil, count: labels.count)
        return labels
    }

    /// Sucht im erschlossenen Bestand, begrenzt auf freigegebene Quellen.
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

    private func log(_ tool: MCPTool, query: String?, count: Int) {
        auditLog.insert(
            AuditEntry(tool: tool, query: query, resultCount: count, at: Date()),
            at: 0
        )
        if auditLog.count > 200 { auditLog.removeLast() }
    }
}

/// Was ein Agent zu sehen bekommt.
///
/// Bewusst eine eigene Form statt des Domänentyps: hier wird entschieden,
/// was nach draussen geht. Interne Kennungen von Medienfassung und
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
}

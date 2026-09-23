//
//  ChatScope.swift
//  PodcastAIKnowledge
//
//  Worüber gerade gesprochen wird — und zwar sichtbar.
//
//  Der Scope ist kein technisches Detail: „Was sagt der Gast über iOS 27?“
//  bedeutet etwas anderes, wenn es sich auf eine Folge bezieht, als wenn es
//  den gesamten Bestand meint. Deshalb steht er in der Oberfläche und ist
//  Teil des unveränderlichen Schnappschusses, mit dem gearbeitet wird —
//  er kann sich während einer Antwort nicht ändern.
//

import Foundation
import PodcastAICore

public enum ChatScope: Sendable, Hashable {
    case episode(EpisodeID)
    case episodes([EpisodeID])
    case smartFeed(SmartFeedID)
    /// Alles, was erschlossen ist. Ausdrücklich nicht „alles, was existiert“.
    case allAnalyzed
    /// Das Ausgewertete, eingegrenzt auf einen Podcast, einen Zeitraum oder beides.
    case library(LibraryFilter)

    public var label: String {
        switch self {
        case .episode: "Diese Folge"
        case .episodes(let ids): "\(ids.count) ausgewählte Folgen"
        case .smartFeed: "Dieser Themenfeed"
        case .allAnalyzed: "Alle ausgewerteten Inhalte"
        case .library(let filter):
            [filter.sourceID == nil ? "Alle Podcasts" : "Ein Podcast",
             filter.period == .all ? nil : filter.period.label].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Eingrenzung einer Frage an die Mediathek.
///
/// Der Code wählt damit die Folgen aus, bevor gesucht wird. Das Modell
/// sieht nur die Stellen, die übrig bleiben, und wählt unter ihnen aus.
/// Der Zeitraum ist eine Wahl und kein Datum: sonst hätte jede Frage einen
/// eigenen Bereich, und frühere Antworten fänden nicht mehr zusammen.
public struct LibraryFilter: Sendable, Hashable {

    public var sourceID: SourceID?
    public var period: Period

    public enum Period: String, Sendable, Hashable, CaseIterable {
        case all, lastWeek, lastMonth

        public var label: String {
            switch self {
            case .all: "Alles"
            case .lastWeek: "Letzte 7 Tage"
            case .lastMonth: "Letzte 30 Tage"
            }
        }

        var days: Int? {
            switch self {
            case .all: nil
            case .lastWeek: 7
            case .lastMonth: 30
            }
        }
    }

    public init(sourceID: SourceID? = nil, period: Period = .all) {
        self.sourceID = sourceID
        self.period = period
    }

    /// Ohne Podcast und ohne Zeitraum ist nichts eingegrenzt.
    public var isUnrestricted: Bool { sourceID == nil && period == .all }

    /// Das früheste Erscheinungsdatum, das noch zählt.
    public func earliest(now: Date = Date()) -> Date? {
        period.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    /// Gehört eine Folge in den Bereich? Ohne Erscheinungsdatum lässt sich
    /// ein Zeitraum nicht prüfen. Dann zählt die Folge nur, wenn keiner
    /// gewählt ist.
    public func admits(sourceID: SourceID, publishedAt: Date?, now: Date = Date()) -> Bool {
        if let wanted = self.sourceID, wanted != sourceID { return false }
        guard let earliest = earliest(now: now) else { return true }
        guard let publishedAt else { return false }
        return publishedAt >= earliest
    }
}

/// Der unveränderliche Arbeitsstand einer Frage.
///
/// Wird einmal gebildet und danach nicht mehr angefasst. Läuft parallel ein
/// Refresh, ändert das nichts an der laufenden Antwort — sonst könnte eine
/// Antwort Belege zitieren, die beim Lesen schon wieder andere sind.
public struct ChatScopeSnapshot: Sendable {
    public let scope: ChatScope
    public let evidence: [Evidence]
    public let coverage: AnalysisCoverage
    /// Quellen im Scope, die nicht vollständig analysiert sind.
    public let incompleteSourceIDs: [SourceID]
    public let takenAt: Date

    public init(scope: ChatScope, evidence: [Evidence], coverage: AnalysisCoverage,
                incompleteSourceIDs: [SourceID] = [], takenAt: Date = Date()) {
        self.scope = scope; self.evidence = evidence; self.coverage = coverage
        self.incompleteSourceIDs = incompleteSourceIDs; self.takenAt = takenAt
    }

    /// Darf auf dieser Grundlage „alle“ beantwortet werden?
    public var supportsExhaustiveAnswer: Bool {
        coverage.supportsExhaustiveClaims && incompleteSourceIDs.isEmpty
    }
}

/// Eine Antwort mit Belegen.
///
/// Es gibt keinen Konstruktor ohne `citations` — eine Antwort ohne Beleg
/// ist in diesem Produkt kein gültiger Wert.
public struct ChatAnswer: Sendable, Identifiable {

    public let id: UUID
    public let question: String
    public let scope: ChatScope
    /// Der Antworttext. Modellformulierung, als solche gekennzeichnet.
    public let text: String
    /// Die Belege, auf die sich die Antwort stützt — in der Reihenfolge,
    /// in der sie im Text vorkommen.
    public let citations: [Evidence]
    /// Wenn der Scope keine Vollständigkeitsaussage trägt, steht hier, warum.
    public let coverageCaveat: String?
    public let answeredAt: Date
    /// Wo die Antwort formuliert wurde, etwa „Private Cloud Compute“.
    public let modelLabel: String?
    /// Verweisnummern im Text wie [3] → Beleg.
    public let citationNumbers: [Int: EvidenceID]

    public init(
        id: UUID = UUID(), question: String, scope: ChatScope, text: String,
        citations: [Evidence], coverageCaveat: String? = nil, answeredAt: Date = Date(),
        modelLabel: String? = nil, citationNumbers: [Int: EvidenceID] = [:]
    ) {
        self.id = id; self.question = question; self.scope = scope; self.text = text
        self.citations = citations; self.coverageCaveat = coverageCaveat
        self.answeredAt = answeredAt; self.modelLabel = modelLabel
        self.citationNumbers = citationNumbers
    }

    /// Die belegten Stellen, die abgespielt werden können.
    public var playableCitations: [Evidence] { citations.filter(\.isPlayable) }

    /// Macht aus der Antwort einen Wiedergabevorschlag.
    ///
    /// Das ist der Übergang, der den Chat vom Suchfeld unterscheidet: die
    /// Antwort kann selbst zur Hörsession werden. Der Vorschlag geht
    /// trotzdem durch den `FocusPlanner` und braucht eine Freigabe — hier
    /// entsteht kein Ton, nur ein Vorschlag.
    public func playbackProposal() -> PlaylistProposal {
        PlaylistProposal(
            evidenceIDs: playableCitations.map(\.id),
            rationales: [:],
            requestSummary: question
        )
    }
}

/// Baut die Hinweise, die einer Antwort beigestellt werden.
public enum CoverageAdvisor {

    /// Der Satz, der unter einer Antwort steht, wenn der Bestand keine
    /// Vollständigkeitsaussage trägt.
    ///
    /// Ohne diesen Hinweis liest sich „drei Stellen“ wie „es gibt genau
    /// drei“ — und das wäre eine Behauptung, die der Bestand nicht deckt.
    public static func caveat(
        for snapshot: ChatScopeSnapshot,
        questionSuggestsExhaustive: Bool
    ) -> String? {

        if !snapshot.incompleteSourceIDs.isEmpty {
            let count = snapshot.incompleteSourceIDs.count
            return count == 1
                ? "Eine Quelle im gewählten Bereich ist nur teilweise erschlossen. Es kann mehr geben."
                : "\(count) Quellen im gewählten Bereich sind nur teilweise erschlossen. Es kann mehr geben."
        }
        if questionSuggestsExhaustive, !snapshot.coverage.isComplete {
            return "Der gewählte Bereich ist \(snapshot.coverage.label). "
                + "Diese Antwort deckt nur den erschlossenen Teil ab."
        }
        if snapshot.evidence.isEmpty {
            return "Im gewählten Bereich ist nichts erschlossen, worauf sich eine Antwort stützen könnte."
        }
        return nil
    }

    /// Erkennt Fragen, die eine Vollständigkeitsaussage verlangen.
    ///
    /// „Was sagt er über X?“ und „Welche **alle** Aussagen gibt es zu X?“
    /// sind verschiedene Fragen. Die zweite braucht einen vollständig
    /// erschlossenen Bestand — sonst wird aus einer Stichprobe versehentlich
    /// eine Bilanz.
    public static func suggestsExhaustive(_ question: String) -> Bool {
        let normalized = question.lowercased()
        let markers = [
            "alle", "sämtliche", "saemtliche", "jede", "jeden", "jedes",
            "vollständig", "vollstaendig", "insgesamt", "überall", "ueberall",
            "wie oft", "wie viele", "all ", "every", "complete",
        ]
        return markers.contains { normalized.contains($0) }
    }
}

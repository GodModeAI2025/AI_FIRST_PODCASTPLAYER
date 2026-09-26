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
    /// Das Ausgewertete, eingegrenzt auf Podcasts, einen Zeitraum, Tags oder Folgen.
    case library(LibraryFilter)

    public var label: String {
        switch self {
        case .episode: String(localized: "Diese Folge", bundle: .module)
        case .episodes(let ids):
            String(AttributedString(
                localized: "^[\(ids.count) ausgewählte Folge](inflect: true)", bundle: .module).characters)
        case .smartFeed: String(localized: "Dieses Themen-Update", bundle: .module)
        case .allAnalyzed: String(localized: "Alle Folgen mit Transkript", bundle: .module)
        case .library(let filter): filter.parts(sourceNames: []).joined(separator: " · ")
        }
    }
}

/// Eingrenzung einer Frage an die Mediathek.
///
/// Der Code wählt damit die Folgen aus, bevor gesucht wird. Das Modell
/// sieht nur die Stellen, die übrig bleiben, und wählt unter ihnen aus.
/// Der Zeitraum aus dem Menü ist eine Wahl und kein Datum: sonst hätte jede
/// Frage einen eigenen Bereich, und frühere Antworten fänden nicht mehr
/// zusammen. „seit 1. Juni“ aus dem Eingabefeld ist dagegen ein fester Tag
/// und bleibt es auch morgen.
///
/// Seit 0.12 kommen Tokens aus dem Eingabefeld dazu (``ChatToken``): mehrere
/// Podcasts, ein Tag als Anfang oder Ende, Tags und einzelne Folgen. Jede
/// Art grenzt ein, innerhalb einer Art reicht ein Treffer. Alle Felder sind
/// Mengen oder feste Werte, damit derselbe Bereich gleich bleibt, egal in
/// welcher Reihenfolge jemand die Tokens gesetzt hat.
public struct LibraryFilter: Sendable, Hashable {

    /// Podcasts, aus denen Folgen zählen. Leer heißt: alle.
    public var sourceIDs: Set<SourceID>
    public var period: Period
    /// Das früheste Erscheinungsdatum, Beginn eines Tages. Aus „seit 1. Juni“.
    public var since: Date?
    /// Das erste Erscheinungsdatum, das nicht mehr zählt: Beginn des Tages
    /// nach „bis 30. Juni“.
    public var before: Date?
    /// Tags, von denen ein Kapitel eines tragen muss. Leer heißt: egal.
    /// Welche Kapitel das sind, weiß erst ``ChatNarrowing``.
    public var tagIDs: Set<InterestID>
    /// Einzelne Folgen. Leer heißt: alle.
    public var episodeIDs: Set<EpisodeID>

    public enum Period: String, Sendable, Hashable, CaseIterable {
        case all, lastWeek, lastMonth

        public var label: String {
            switch self {
            case .all: String(localized: "Alles", bundle: .module)
            case .lastWeek: String(localized: "Letzte 7 Tage", bundle: .module)
            case .lastMonth: String(localized: "Letzte 30 Tage", bundle: .module)
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
        self.init(sourceIDs: sourceID.map { [$0] } ?? [], period: period)
    }

    public init(
        sourceIDs: Set<SourceID>, period: Period = .all, since: Date? = nil, before: Date? = nil,
        tagIDs: Set<InterestID> = [], episodeIDs: Set<EpisodeID> = []
    ) {
        self.sourceIDs = sourceIDs
        self.period = period
        self.since = since
        self.before = before
        self.tagIDs = tagIDs
        self.episodeIDs = episodeIDs
    }

    /// Der eine gewählte Podcast, wie ihn das Menü zeigt. Bei mehreren `nil`.
    /// Setzen ersetzt alle Podcasts.
    public var sourceID: SourceID? {
        get { sourceIDs.count == 1 ? sourceIDs.first : nil }
        set { sourceIDs = newValue.map { [$0] } ?? [] }
    }

    /// Ohne Podcast, Zeitraum, Tag und Folge ist nichts eingegrenzt.
    public var isUnrestricted: Bool {
        sourceIDs.isEmpty && period == .all && since == nil && before == nil
            && tagIDs.isEmpty && episodeIDs.isEmpty
    }

    /// Das früheste Erscheinungsdatum, das noch zählt: das spätere aus
    /// Zeitraum und „seit“.
    public func earliest(now: Date = Date()) -> Date? {
        let relative = period.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        switch (relative, since) {
        case let (relative?, since?): return max(relative, since)
        case let (relative, since): return relative ?? since
        }
    }

    /// Passen Podcast und Erscheinungsdatum? Ohne Erscheinungsdatum lässt
    /// sich ein Zeitraum nicht prüfen. Dann zählt die Folge nur, wenn keiner
    /// gewählt ist. Folgen und Tags prüft ``ChatNarrowing``.
    public func admits(sourceID: SourceID, publishedAt: Date?, now: Date = Date()) -> Bool {
        if !sourceIDs.isEmpty, !sourceIDs.contains(sourceID) { return false }
        let lower = earliest(now: now)
        guard lower != nil || before != nil else { return true }
        guard let publishedAt else { return false }
        if let lower, publishedAt < lower { return false }
        if let before, publishedAt >= before { return false }
        return true
    }

    /// Die Teile der Beschriftung, etwa „Lage der Nation · seit 1. Juni 2026“.
    /// Mit `sourceNames` stehen die Namen der Podcasts da, sonst ihre Zahl.
    public func parts(sourceNames: [String], tagNames: [String] = [], episodeNames: [String] = []) -> [String] {
        var parts: [String] = []
        if !sourceNames.isEmpty {
            parts.append(sourceNames.joined(separator: ", "))
        } else if sourceIDs.isEmpty {
            parts.append(String(localized: "Alle Podcasts", bundle: .module))
        } else if sourceIDs.count == 1 {
            parts.append(String(localized: "Ein Podcast", bundle: .module))
        } else {
            parts.append(String(AttributedString(
                localized: "^[\(sourceIDs.count) Podcast](inflect: true)", bundle: .module).characters))
        }
        if period != .all { parts.append(period.label) }
        if let since { parts.append(ChatToken.since(since).dateLabel ?? "") }
        if let before { parts.append(ChatToken.before(before).dateLabel ?? "") }
        if !tagNames.isEmpty {
            parts.append(tagNames.joined(separator: ", "))
        } else if !tagIDs.isEmpty {
            parts.append(String(AttributedString(
                localized: "^[\(tagIDs.count) Tag](inflect: true)", bundle: .module).characters))
        }
        if !episodeNames.isEmpty {
            parts.append(episodeNames.joined(separator: ", "))
        } else if !episodeIDs.isEmpty {
            parts.append(ChatScope.episodes(Array(episodeIDs)).label)
        }
        return parts
    }
}

/// Wovon der Hinweis unter einer Antwort spricht.
public enum CaveatKind: Sendable, Hashable {
    /// Durchsucht wurden nur Folgen mit Transkript.
    case transcriptCoverage
    /// Wie weit eine Frage nach Links, Terminen oder Namen gesucht hat. Dort
    /// zählen auch die Shownotes, mit oder ohne Transkript.
    case mentionScope
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
    /// Wovon der Hinweis spricht. Die Erklärung „Warum nur Folgen mit
    /// Transkript?“ passt nur zur Suche im Transkript.
    public let caveatKind: CaveatKind
    public let answeredAt: Date
    /// Wo die Antwort formuliert wurde, etwa „Private Cloud Compute“.
    public let modelLabel: String?
    /// Verweisnummern im Text wie [3] → Beleg.
    public let citationNumbers: [Int: EvidenceID]
    /// Folgen, aus denen der Text etwas nennt, auch ohne Beleg, etwa einen
    /// Link aus den Shownotes. Wird eine davon gelöscht, geht die Antwort mit.
    public let referencedEpisodeIDs: [EpisodeID]
    /// Wo die Folge im Player stand, als die Frage gestellt wurde. Nur bei
    /// Fragen an eine Folge, die gerade geladen war. Die Zeit kommt vom
    /// Player, nie vom Modell.
    public let askedAtPosition: MediaTime?
    /// Warum die Antwort vom Gerät kommt, obwohl die Apple-Server erlaubt
    /// sind, etwa „Apple-Server heute ausgeschöpft, wieder ab 18:00“. Nur
    /// für die Anzeige, gesichert und exportiert wird die Zeile nicht.
    public let modelNote: String?

    public init(
        id: UUID = UUID(), question: String, scope: ChatScope, text: String,
        citations: [Evidence], coverageCaveat: String? = nil,
        caveatKind: CaveatKind = .transcriptCoverage, answeredAt: Date = Date(),
        modelLabel: String? = nil, citationNumbers: [Int: EvidenceID] = [:],
        referencedEpisodeIDs: [EpisodeID] = [], askedAtPosition: MediaTime? = nil,
        modelNote: String? = nil
    ) {
        self.id = id; self.question = question; self.scope = scope; self.text = text
        self.citations = citations; self.coverageCaveat = coverageCaveat
        self.caveatKind = caveatKind
        self.answeredAt = answeredAt; self.modelLabel = modelLabel
        self.citationNumbers = citationNumbers
        self.referencedEpisodeIDs = referencedEpisodeIDs
        self.askedAtPosition = askedAtPosition
        self.modelNote = modelNote
    }

    /// Dieselbe Antwort mit der Stelle, an der gefragt wurde.
    public func asked(at position: MediaTime?) -> ChatAnswer {
        ChatAnswer(
            id: id, question: question, scope: scope, text: text, citations: citations,
            coverageCaveat: coverageCaveat, caveatKind: caveatKind, answeredAt: answeredAt,
            modelLabel: modelLabel, citationNumbers: citationNumbers,
            referencedEpisodeIDs: referencedEpisodeIDs, askedAtPosition: position,
            modelNote: modelNote)
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

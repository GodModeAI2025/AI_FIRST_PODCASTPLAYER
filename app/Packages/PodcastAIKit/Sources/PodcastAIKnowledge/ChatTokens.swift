//
//  ChatTokens.swift
//  PodcastAIKnowledge
//
//  Eingrenzung im Eingabefeld des Chats: „Podcast: Lage der Nation“ oder
//  „seit 1. Juni“ als Token über dem Feld.
//
//  Ein Token ist eine Kennung oder ein fester Tag, nie ein Text für das
//  Modell. Welche Folgen und Stellen übrig bleiben, rechnet der Code vor
//  der Frage aus (``ChatNarrowing``). Das Modell sieht nur, was bleibt, und
//  wählt keinen Bereich (Regel 3).
//

import Foundation
import PodcastAICore

/// Eine Eingrenzung im Eingabefeld.
public enum ChatToken: Sendable, Hashable, Identifiable {
    case source(SourceID)
    /// Ein Zeitraum aus dem Menü, „letzte Woche“ oder „letzter Monat“.
    case period(LibraryFilter.Period)
    /// Beginn des Tages, ab dem Folgen zählen.
    case since(Date)
    /// Beginn des Tages, ab dem Folgen nicht mehr zählen. „bis 30. Juni“
    /// steht hier als 1. Juli, 0 Uhr.
    case before(Date)
    case tag(InterestID)
    case episode(EpisodeID)

    public var id: String {
        switch self {
        case .source(let id): "source|" + id.rawValue
        case .period(let period): "period|" + period.rawValue
        case .since(let date): "since|\(date.timeIntervalSinceReferenceDate)"
        case .before(let date): "before|\(date.timeIntervalSinceReferenceDate)"
        case .tag(let id): "tag|" + id.rawValue
        case .episode(let id): "episode|" + id.rawValue
        }
    }

    /// Die Art, nach der Tokens über dem Feld geordnet stehen.
    public enum Kind: Int, Sendable, Comparable {
        case source, date, tag, episode
        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind {
        switch self {
        case .source: .source
        case .period, .since, .before: .date
        case .tag: .tag
        case .episode: .episode
        }
    }

    /// Die Beschriftung eines Zeit-Tokens, etwa „seit 1. Juni 2026“. Der Tag
    /// steht ausgeschrieben da, so sieht man, welchen Tag der Code verstanden
    /// hat. Podcasts, Tags und Folgen brauchen ihren Namen und bekommen ihn
    /// in der App.
    public var dateLabel: String? {
        switch self {
        case .period(let period): return period.label
        case .since(let date):
            return String(localized: "seit \(Self.dayText(date))", bundle: .module)
        case .before(let date):
            // Gespeichert ist der Beginn des Folgetags, gemeint der Tag davor.
            return String(localized: "bis \(Self.dayText(date.addingTimeInterval(-1)))", bundle: .module)
        case .source, .tag, .episode: return nil
        }
    }

    static func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year())
    }
}

extension LibraryFilter {

    /// Die Tokens dieses Bereichs, geordnet nach Art. Innerhalb einer Art
    /// ordnet die App nach Namen.
    public var tokens: [ChatToken] {
        var tokens: [ChatToken] = sourceIDs.sorted { $0.rawValue < $1.rawValue }.map { .source($0) }
        if period != .all { tokens.append(.period(period)) }
        if let since { tokens.append(.since(since)) }
        if let before { tokens.append(.before(before)) }
        tokens += tagIDs.sorted { $0.rawValue < $1.rawValue }.map { .tag($0) }
        tokens += episodeIDs.sorted { $0.rawValue < $1.rawValue }.map { .episode($0) }
        return tokens
    }

    public func contains(_ token: ChatToken) -> Bool {
        switch token {
        case .source(let id): sourceIDs.contains(id)
        case .period(let value): period == value && value != .all
        case .since(let date): since == date
        case .before(let date): before == date
        case .tag(let id): tagIDs.contains(id)
        case .episode(let id): episodeIDs.contains(id)
        }
    }

    /// Derselbe Bereich mit einem Token mehr. Ein Zeitraum aus dem Menü und
    /// „seit“ sind beide ein Anfang, deshalb ersetzt das eine das andere.
    /// Ein zweites „seit“ oder „bis“ ersetzt das erste.
    public func adding(_ token: ChatToken) -> LibraryFilter {
        var copy = self
        switch token {
        case .source(let id): copy.sourceIDs.insert(id)
        case .period(let value):
            copy.period = value
            if value != .all { copy.since = nil }
        case .since(let date):
            copy.since = date
            copy.period = .all
        case .before(let date): copy.before = date
        case .tag(let id): copy.tagIDs.insert(id)
        case .episode(let id): copy.episodeIDs.insert(id)
        }
        return copy
    }

    /// Derselbe Bereich ohne dieses Token.
    public func removing(_ token: ChatToken) -> LibraryFilter {
        var copy = self
        switch token {
        case .source(let id): copy.sourceIDs.remove(id)
        case .period: copy.period = .all
        case .since: copy.since = nil
        case .before: copy.before = nil
        case .tag(let id): copy.tagIDs.remove(id)
        case .episode(let id): copy.episodeIDs.remove(id)
        }
        return copy
    }
}

/// Ein Bereich, fertig zum Suchen: Tags sind zu Kapiteln aufgelöst, und die
/// Uhrzeit steht fest.
///
/// Kein Teil des Bereichs selbst. Kapitel-Tags ändern sich mit jeder
/// Einordnung. Stünden sie im Bereich, fänden Antworten auf dieselbe
/// Eingrenzung nicht mehr zusammen.
public struct ChatNarrowing: Sendable {

    public let filter: LibraryFilter
    public let now: Date
    /// Kapitel der gewählten Tags je Folge. `nil`, wenn kein Tag gewählt ist.
    /// Verglichen wird über die Folge, nicht über die Medienfassung: Ein Tag
    /// aus einer älteren Fassung leerte sonst den ganzen Bereich.
    let taggedChapters: [EpisodeID: [MediaTimeRange]]?

    /// `chapterTags` sind die Kapitel-Tags der gewählten Tags. Andere
    /// Kapitel-Tags in der Liste zählen nicht.
    public init(filter: LibraryFilter, chapterTags: [ChapterTag] = [], now: Date = Date()) {
        self.filter = filter
        self.now = now
        if filter.tagIDs.isEmpty {
            taggedChapters = nil
        } else {
            var chapters: [EpisodeID: [MediaTimeRange]] = [:]
            for tag in chapterTags where filter.tagIDs.contains(tag.interestID) {
                chapters[tag.episodeID, default: []].append(tag.chapterRange)
            }
            taggedChapters = chapters
        }
    }

    /// Ohne jede Eingrenzung.
    public static var unrestricted: ChatNarrowing { ChatNarrowing(filter: LibraryFilter()) }

    public var isUnrestricted: Bool { filter.isUnrestricted }

    /// Bleiben nur einzelne Folgen übrig, gewählt oder über ein Tag? Dann
    /// zählen Podcasts ohne passende Folge nicht mehr zum Überblick.
    public var narrowsEpisodes: Bool { !filter.episodeIDs.isEmpty || !filter.tagIDs.isEmpty }

    /// Zählt dieser Podcast überhaupt?
    public func admits(source id: SourceID) -> Bool {
        filter.sourceIDs.isEmpty || filter.sourceIDs.contains(id)
    }

    /// Gehört die Folge in den Bereich? Podcast, Tage, gewählte Folgen und,
    /// mit Tags, ein Kapitel mit einem davon.
    public func admits(episodeID: EpisodeID, sourceID: SourceID, publishedAt: Date?) -> Bool {
        if !filter.episodeIDs.isEmpty, !filter.episodeIDs.contains(episodeID) { return false }
        if let taggedChapters, taggedChapters[episodeID] == nil { return false }
        return filter.admits(sourceID: sourceID, publishedAt: publishedAt, now: now)
    }

    public func admits(_ episode: Episode) -> Bool {
        admits(episodeID: episode.id, sourceID: episode.sourceID, publishedAt: episode.publishedAt)
    }

    /// Die Stellen, die das Modell sehen darf. Mit Tags nur Stellen, die in
    /// einem Kapitel mit einem der Tags beginnen, wie bei „Für dich“; ohne
    /// Zeitmarke passt eine Stelle dann in kein Kapitel. Podcast und
    /// gewählte Folgen gelten auch hier, das Datum prüft die Folge.
    public func passages(_ pool: [Evidence]) -> [Evidence] {
        pool.filter { evidence in
            if !filter.episodeIDs.isEmpty, !filter.episodeIDs.contains(evidence.episodeID) { return false }
            if !filter.sourceIDs.isEmpty, !evidence.sourceID.rawValue.isEmpty,
               !filter.sourceIDs.contains(evidence.sourceID) { return false }
            guard let taggedChapters else { return true }
            guard let start = evidence.range?.start, let chapters = taggedChapters[evidence.episodeID] else {
                return false
            }
            return chapters.contains { chapter in
                // Ein Kapitel ohne bekanntes Ende reicht bis zum Schluss.
                chapter.isEmpty ? start >= chapter.start : chapter.contains(start)
            }
        }
    }
}

/// Die letzten Fragen auf diesem Gerät, neueste zuerst. Gespeichert wird in
/// der App (`DeviceState`), hier steht nur die Regel.
public enum RecentQuestions {

    public static let limit = 10

    /// Setzt eine gestellte Frage an den Anfang. Dieselbe Frage in anderer
    /// Schreibweise steht danach nur einmal da, in der neuen.
    public static func inserting(_ question: String, into list: [String], limit: Int = limit) -> [String] {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0 else { return Array(list.prefix(max(limit, 0))) }
        let others = list.filter {
            $0.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        return Array(([text] + others).prefix(limit))
    }
}

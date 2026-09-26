//
//  AppModel+ChatNarrowing.swift
//  PodcastAI
//
//  Eingrenzung im Eingabefeld des Chats, seit 0.12: Tokens für Podcasts,
//  Zeiträume, Tags und Folgen, dazu die letzten Fragen dieses Geräts.
//
//  Die Regeln stehen in `ChatTokens` und `ChatTokenParser`
//  (PodcastAIKnowledge). Hier holt das Modell Namen und Kapitel-Tags und
//  merkt sich die Fragen in `DeviceState`. Nichts hier fragt ein
//  Sprachmodell oder startet Ton.
//

import Foundation
import PodcastAIKit

extension AppModel {

    // MARK: - Eingrenzung auflösen

    /// Der Bereich, fertig zum Suchen. Die Kapitel der gewählten Tags kommen
    /// aus dem Store, ohne Tags fragt es ihn nicht.
    func chatNarrowing(for filter: LibraryFilter, now: Date = Date()) async -> ChatNarrowing {
        guard !filter.tagIDs.isEmpty else { return ChatNarrowing(filter: filter, now: now) }
        let store = self.store
        var chapterTags: [ChapterTag] = []
        for id in filter.tagIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            chapterTags += (try? await store.chapterTags(forTag: id)) ?? []
        }
        return ChatNarrowing(filter: filter, chapterTags: chapterTags, now: now)
    }

    // MARK: - Vorschläge

    /// Was das Eingabefeld vorschlagen kann: die Abos, Tags mit Kapiteln
    /// (gefolgte zuerst, dann nach Zahl der Kapitel) und Folgen mit
    /// Transkript, neueste zuerst. Ein Tag ohne Kapitel ließe nichts übrig,
    /// eine Folge ohne Transkript hätte keine Stellen.
    var chatTokenCatalog: ChatTokenCatalog {
        let counts = chapterTagCounts
        let tags = profile.tags
            .filter { (counts[$0.id] ?? 0) > 0 }
            .sorted { first, second in
                if first.isFollowed != second.isFollowed { return first.isFollowed }
                let (a, b) = (counts[first.id] ?? 0, counts[second.id] ?? 0)
                return a != b ? a > b : first.label.localizedStandardCompare(second.label) == .orderedAscending
            }
            .map { ChatTokenCatalog.Entry(token: .tag($0.id), name: $0.label, aliases: $0.aliases) }
        let analyzed = analyzedEpisodes
        let transcribed = episodes.values.joined()
            .filter { analyzed.contains($0.id) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .map { ChatTokenCatalog.Entry(token: .episode($0.id), name: $0.title) }
        return ChatTokenCatalog(
            sources: sources.map { ChatTokenCatalog.Entry(token: .source($0.id), name: $0.title) },
            tags: tags, episodes: transcribed)
    }

    // MARK: - Beschriftungen

    /// Die Beschriftung eines Tokens, etwa „Podcast: Lage der Nation“ oder
    /// „seit 1. Juni 2026“.
    func chatTokenLabel(_ token: ChatToken) -> String {
        switch token {
        case .source(let id):
            return String(localized: "Podcast: \(sourceTitle(id) ?? String(localized: "Ein Podcast"))")
        case .tag(let id):
            // Ohne Namen nur kurz, bis das Token wegfällt (`staleChatTokens`).
            return String(localized: "Tag: \(tagLabel(id) ?? "…")")
        case .episode(let id):
            return String(localized: "Folge: \(episodeTitle(id) ?? String(localized: "Eine Folge"))")
        case .period, .since, .before:
            return token.dateLabel ?? ""
        }
    }

    /// Wie ein eingegrenzter Bereich heißt, mit Namen statt Zahlen. Bei mehr
    /// als zwei Folgen steht ihre Zahl da, die Titel wären zu lang.
    func libraryScopeLabel(_ filter: LibraryFilter) -> String {
        let sourceNames = filter.sourceIDs.compactMap(sourceTitle).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tagNames = filter.tagIDs.compactMap(tagLabel).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let episodeNames = filter.episodeIDs.count > 2
            ? [] : filter.episodeIDs.compactMap(episodeTitle).sorted()
        return filter.parts(sourceNames: sourceNames, tagNames: tagNames, episodeNames: episodeNames)
            .joined(separator: " · ")
    }

    private func sourceTitle(_ id: SourceID) -> String? {
        sources.first { $0.id == id }?.title
    }

    private func tagLabel(_ id: InterestID) -> String? {
        profile.tags.first { $0.id == id }?.label
    }

    /// Titel einer geladenen Folge, gekürzt wie in der Leiste über dem Chat.
    func episodeTitle(_ id: EpisodeID) -> String? {
        episodes.values.lazy.compactMap { $0.first { $0.id == id } }.first.map { String($0.title.prefix(40)) }
    }

    /// Tokens, deren Podcast, Tag oder Folge es nicht mehr gibt.
    func staleChatTokens(in filter: LibraryFilter) -> [ChatToken] {
        filter.tokens.filter(isStaleChatToken)
    }

    /// Gibt es Podcast, Tag oder Folge des Tokens nicht mehr: abbestellt,
    /// gelöscht oder mit einem anderen Tag zusammengelegt? Gilt für gesetzte
    /// Tokens und für Vorschläge, die noch aus dem Katalog von vorhin kommen.
    func isStaleChatToken(_ token: ChatToken) -> Bool {
        switch token {
        case .source(let id): sourceTitle(id) == nil
        case .tag(let id): tagLabel(id) == nil
        case .episode(let id): !episodes.values.contains { $0.contains { $0.id == id } }
        case .period, .since, .before: false
        }
    }

    // MARK: - Letzte Fragen

    /// Nur auf diesem Gerät, als Datei in `DeviceState`.
    nonisolated static let recentQuestionsKey = "recentChatQuestions"

    /// Die letzten Fragen auf diesem Gerät, neueste zuerst.
    static func recentQuestions() -> [String] {
        DeviceState.shared.value([String].self, for: recentQuestionsKey) ?? []
    }

    /// Merkt sich eine gestellte Frage und gibt die neue Liste zurück.
    @discardableResult
    static func rememberQuestion(_ question: String) -> [String] {
        let list = RecentQuestions.inserting(question, into: recentQuestions())
        DeviceState.shared.set(list, for: recentQuestionsKey)
        return list
    }

    /// Vergisst die letzten Fragen dieses Geräts.
    static func forgetRecentQuestions() {
        DeviceState.shared.set([String]?.none, for: recentQuestionsKey)
    }
}

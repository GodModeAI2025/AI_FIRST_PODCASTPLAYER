//
//  EditionChapterBuilder.swift
//  PodcastAISmartFeeds
//
//  Macht aus Belegen, Kapitel-Tags, Folgen und Fakten die Kapitel, aus
//  denen ein Themen-Update wählt. Ohne Store, damit prüfbar.
//
//  Zwei Wege:
//  - Die Bibliothek hat Kapitel-Tags: Ein Kapitel ist, was die Einordnung
//    gesehen hat, mit Anfang und Ende aus dem Kapitel-Tag.
//  - Die Bibliothek hat noch kein einziges Kapitel-Tag, etwa ohne Apple
//    Intelligence: Die Kapitel kommen aus dem Feed oder werden abgeleitet,
//    und ein Kapitel trägt die Tags, deren Stichworte `RelevanceScorer`
//    darin gefunden hat.
//

import Foundation
import PodcastAICore
import PodcastAIKnowledge

public enum EditionChapterBuilder {

    public typealias Titles = (source: String, episode: String, published: Date?)

    public static func build(
        evidence: [Evidence],
        chapterTags: [ChapterTag],
        episodes: [EpisodeID: Episode],
        facts: [EpisodeFact],
        titles: [EpisodeID: Titles],
        tags: Set<InterestID>,
        terms: [InterestID: [String]],
        keywordMatches: [RelevanceMatch] = [],
        jumps: @escaping ChapterSections.JumpMeasure = ChapterSections.embeddingJumps
    ) -> [EditionChapter] {
        guard !tags.isEmpty else { return [] }
        var byMedia: [MediaVersionID: [Evidence]] = [:]
        for item in evidence where item.range.map({ !$0.isEmpty }) ?? false {
            byMedia[item.mediaVersionID, default: []].append(item)
        }
        for key in byMedia.keys {
            byMedia[key]?.sort { ($0.range?.start ?? .zero, $0.id.rawValue) < ($1.range?.start ?? .zero, $1.id.rawValue) }
        }
        var factsByMedia: [MediaVersionID: [MediaTimeRange]] = [:]
        for fact in facts { factsByMedia[fact.mediaVersionID, default: []].append(fact.range) }

        // Kapitel einer Folge, nur für die Folgen, die es brauchen.
        var sectionCache: [MediaVersionID: [ChapterSection]] = [:]
        func sections(_ media: MediaVersionID, _ episodeID: EpisodeID) -> [ChapterSection] {
            if let known = sectionCache[media] { return known }
            let episode = episodes[episodeID]
            let result = ChapterSections.sections(
                chapters: episode?.publisherChapters ?? [], duration: episode?.declaredDuration,
                evidence: byMedia[media] ?? [], jumps: jumps)
            sectionCache[media] = result
            return result
        }

        func chapter(
            media: MediaVersionID, episodeID: EpisodeID, sourceID: SourceID, revision: Revision,
            range: MediaTimeRange, title: String?, tagIDs: Set<InterestID>,
            hits: [EvidenceID: Set<InterestID>]?
        ) -> EditionChapter {
            let passages = (byMedia[media] ?? []).filter {
                guard let start = $0.range?.start else { return false }
                return range.contains(start)
            }
            let known = titles[episodeID]
            let chapterTerms = terms.filter { tagIDs.contains($0.key) }
            return EditionChapter(
                episodeID: episodeID, mediaVersionID: media, sourceID: sourceID,
                sourceTitle: known?.source ?? String(localized: "Unbekannte Quelle", bundle: .module),
                episodeTitle: known?.episode ?? episodes[episodeID]?.title
                    ?? String(localized: "Unbekannte Folge", bundle: .module),
                originalPublishedAt: known?.published ?? episodes[episodeID]?.publishedAt,
                transcriptRevision: revision, range: range, title: title, tagIDs: tagIDs,
                passages: passages,
                passageHits: hits ?? EditionChapter.textHits(in: passages, terms: chapterTerms),
                statements: (factsByMedia[media] ?? []).filter { range.contains($0.start) })
        }

        // Titel und Ende eines Kapitels aus den Kapiteln der Folge.
        func section(_ media: MediaVersionID, _ episodeID: EpisodeID, at start: MediaTime) -> ChapterSection? {
            sections(media, episodeID).first { $0.range.start == start }
                ?? sections(media, episodeID).first { $0.range.contains(start) }
        }

        guard chapterTags.isEmpty else {
            struct Group {
                var tag: ChapterTag
                var tagIDs: Set<InterestID>
                var end: Int
            }
            var groups: [String: Group] = [:]
            for tag in chapterTags where byMedia[tag.mediaVersionID] != nil {
                let key = "\(tag.mediaVersionID.rawValue)|\(tag.chapterStartMs)"
                if var group = groups[key] {
                    group.tagIDs.insert(tag.interestID)
                    group.end = max(group.end, tag.chapterEndMs)
                    groups[key] = group
                } else {
                    groups[key] = Group(tag: tag, tagIDs: [tag.interestID], end: tag.chapterEndMs)
                }
            }
            return groups.keys.sorted().compactMap { key -> EditionChapter? in
                guard let group = groups[key], !group.tagIDs.isDisjoint(with: tags) else { return nil }
                let tag = group.tag
                let start = MediaTime(milliseconds: Int64(tag.chapterStartMs))
                let known = section(tag.mediaVersionID, tag.episodeID, at: start)
                var end = MediaTime(milliseconds: Int64(group.end))
                if end <= start {
                    end = known.map(\.range.end)
                        ?? (byMedia[tag.mediaVersionID] ?? []).compactMap(\.range?.end).max() ?? start
                }
                guard end > start else { return nil }
                return chapter(
                    media: tag.mediaVersionID, episodeID: tag.episodeID, sourceID: tag.sourceID,
                    revision: tag.transcriptRevision, range: MediaTimeRange(start: start, end: end),
                    title: known?.range.start == start ? known?.title : nil,
                    tagIDs: group.tagIDs, hits: nil)
            }
        }

        // Rückfall: Stichworttreffer auf Kapitel verteilen.
        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hitsByMedia: [MediaVersionID: [(Evidence, InterestID)]] = [:]
        for match in keywordMatches where tags.contains(match.interestID) {
            guard let item = byID[match.evidenceID], item.range != nil else { continue }
            hitsByMedia[item.mediaVersionID, default: []].append((item, match.interestID))
        }
        var result: [EditionChapter] = []
        for media in hitsByMedia.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let hits = hitsByMedia[media] ?? []
            guard let first = hits.first?.0 else { continue }
            for section in sections(media, first.episodeID) {
                let inside = hits.filter { section.range.contains($0.0.range?.start ?? .zero) }
                guard !inside.isEmpty else { continue }
                var passageHits: [EvidenceID: Set<InterestID>] = [:]
                for (item, tag) in inside { passageHits[item.id, default: []].insert(tag) }
                result.append(chapter(
                    media: media, episodeID: first.episodeID, sourceID: first.sourceID,
                    revision: first.transcriptRevision, range: section.range, title: section.title,
                    tagIDs: Set(inside.map(\.1)), hits: passageHits))
            }
        }
        return result
    }

    /// Bezeichnung und Aliasse je Tag, für die wörtlichen Treffer.
    public static func terms(for interests: [Interest], tags: Set<InterestID>) -> [InterestID: [String]] {
        var result: [InterestID: [String]] = [:]
        for interest in interests where tags.contains(interest.id) {
            let variants = ([interest.label] + interest.keywords)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            result[interest.id] = variants
        }
        return result
    }
}

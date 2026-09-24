//
//  ChapterTagRelevance.swift
//  PodcastAIKnowledge
//
//  Seit 0.10 wählen „Für dich“ und die Themen-Updates über Kapitel-Tags aus:
//  Eine Stelle passt, wenn ihr Kapitel ein Tag trägt, dem jemand folgt.
//  `RelevanceScorer` bleibt der Rückfall für Folgen, die noch kein Kapitel-Tag
//  haben, etwa weil die Einordnung noch nicht gelaufen ist oder das Gerät
//  kein Apple Intelligence hat.
//
//  Ohne Apple-Frameworks und damit prüfbar.
//

import Foundation
import PodcastAICore

public enum ChapterTagRelevance {

    /// Treffer für Belege.
    ///
    /// - Belege aus Folgen mit mindestens einem Kapitel-Tag passen nur über
    ///   die Kapitel-Tags. Ein Beleg gehört zu einem Kapitel, wenn sein
    ///   Anfang im Kapitel liegt und er aus derselben Medienfassung stammt.
    /// - Belege aus Folgen ohne Kapitel-Tag bewertet `scorer` wie bisher
    ///   über Bezeichnung und Aliasse.
    ///
    /// Es zählen nur Tags, denen jemand folgt (`publicationDrivers`). Je Tag
    /// kommen höchstens `scorer.maximumPerInterest` Treffer aus Kapitel-Tags.
    public static func matches(
        evidence: [Evidence],
        chapterTags: [ChapterTag],
        profile: InterestProfile,
        scorer: RelevanceScorer = RelevanceScorer(),
        now: Date = Date()
    ) -> [RelevanceMatch] {
        let taggedEpisodes = Set(chapterTags.map(\.episodeID))
        let untagged = evidence.filter { !taggedEpisodes.contains($0.episodeID) }
        var result = untagged.isEmpty ? [] : scorer.score(evidence: untagged, profile: profile, now: now)

        let drivers = Dictionary(
            profile.publicationDrivers(at: now).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !drivers.isEmpty, !taggedEpisodes.isEmpty else { return result }

        var tagsByMedia: [MediaVersionID: [ChapterTag]] = [:]
        for tag in chapterTags where drivers[tag.interestID] != nil {
            tagsByMedia[tag.mediaVersionID, default: []].append(tag)
        }

        var byInterest: [InterestID: [RelevanceMatch]] = [:]
        var seen: Set<String> = []
        for item in evidence where taggedEpisodes.contains(item.episodeID) {
            guard let range = item.range, let tags = tagsByMedia[item.mediaVersionID] else { continue }
            let start = range.start.milliseconds
            for tag in tags where contains(tag, start) {
                guard let interest = drivers[tag.interestID],
                      seen.insert(item.id.rawValue + "|" + interest.id.rawValue).inserted else { continue }
                byInterest[interest.id, default: []].append(RelevanceMatch(
                    evidenceID: item.id, interestID: interest.id, interestLabel: interest.label,
                    kind: interest.kind, score: tag.confidence, matchedTerms: [],
                    isModelConfirmed: true))
            }
        }
        // Sortierte Schlüssel: `Dictionary` ist je Prozessstart anders geordnet.
        for key in byInterest.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            result += (byInterest[key] ?? []).sorted(by: RelevanceScorer.ranking)
                .prefix(scorer.maximumPerInterest)
        }
        return result.sorted(by: RelevanceScorer.ranking)
    }

    /// Liegt `start` im Kapitel? Ohne bekanntes Ende gilt das Kapitel bis
    /// zum Ende der Folge.
    static func contains(_ tag: ChapterTag, _ start: Int64) -> Bool {
        let from = Int64(tag.chapterStartMs), to = Int64(tag.chapterEndMs)
        guard start >= from else { return false }
        return to <= from || start < to
    }

    /// Die Kapitel-Tags, die in einem Kapitel liegen: Ihr Anfang fällt in
    /// den Bereich. Abgeleitete Abschnitte beginnen nicht immer genau dort,
    /// wo die Einordnung sie gesehen hat.
    public static func tags(_ tags: [ChapterTag], in range: MediaTimeRange) -> [ChapterTag] {
        let from = range.start.milliseconds, to = range.end.milliseconds
        return tags.filter {
            let start = Int64($0.chapterStartMs)
            return start >= from && (to <= from || start < to)
        }
    }
}

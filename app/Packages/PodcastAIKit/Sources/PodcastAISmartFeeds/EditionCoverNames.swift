//
//  EditionCoverNames.swift
//  PodcastAISmartFeeds
//
//  Die zwei Namen, die in einer Ausgabe am häufigsten fallen, für ihr Cover.
//
//  Gezählt wird ohne Modell aus den Nennungen der Originalfolgen
//  (`Mention`: Personen, Organisationen und Orte). Es zählen nur Stellen im
//  Transkript, die in einem gespielten Abschnitt liegen. Was nur in den
//  Shownotes steht, hört man in der Ausgabe nicht.
//

import Foundation
import PodcastAICore
import PodcastAIKnowledge

public enum EditionCoverNames {

    /// Die häufigsten Namen der Ausgabe, höchstens `limit`. Namen, die
    /// schon als Tag dastehen, fallen weg. Bei Gleichstand entscheidet das
    /// Alphabet, damit dasselbe Cover herauskommt.
    public static func mostFrequent(
        in edition: PersonalEpisode, mentions: [EpisodeID: [Mention]], excluding tags: [String] = [],
        limit: Int = TopicCoverRecipe.maximumNames
    ) -> [String] {
        let taken = Set(tags.map(fold))
        var counts: [String: (display: String, count: Int)] = [:]
        for (episodeID, list) in mentions {
            let ranges = edition.segments.filter { $0.episodeID == episodeID }.map(\.playbackRange)
            guard !ranges.isEmpty else { continue }
            for mention in list where mention.kind.isName {
                let hits = mention.occurrences.filter { occurrence in
                    guard occurrence.origin == .transcript, let time = occurrence.time else { return false }
                    return ranges.contains { $0.contains(time) }
                }.count
                guard hits > 0 else { continue }
                let key = fold(mention.display)
                guard !taken.contains(key) else { continue }
                let known = counts[key]
                counts[key] = (known?.display ?? mention.display, (known?.count ?? 0) + hits)
            }
        }
        return counts.values
            .sorted { lhs, rhs in
                lhs.count != rhs.count
                    ? lhs.count > rhs.count
                    : lhs.display.localizedStandardCompare(rhs.display) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map(\.display)
    }

    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

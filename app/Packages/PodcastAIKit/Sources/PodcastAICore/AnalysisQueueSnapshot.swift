//
//  AnalysisQueueSnapshot.swift
//  PodcastAICore
//
//  Die Warteschlange der Transkripte, so gemerkt, dass sie einen Neustart
//  übersteht. Sonst wäre nach dem Beenden der App alles weg, was jemand
//  angefordert hat, und nur das Vorbereiten reihte von selbst wieder ein.
//

import Foundation

/// Reihenfolge und Herkunft der wartenden Transkripte.
///
/// Liegt in den Benutzereinstellungen dieses Geräts, nicht in der Datenbank:
/// jedes Gerät hat seine eigene Warteschlange.
public struct AnalysisQueueSnapshot: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public let episodeID: EpisodeID
        /// Von der App selbst eingereiht, nicht von Hand angefordert.
        public let automatic: Bool
        /// Eine ältere Folge aus „Ältere Folgen auch vorbereiten“.
        public let backlog: Bool

        public init(episodeID: EpisodeID, automatic: Bool, backlog: Bool) {
            self.episodeID = episodeID
            self.automatic = automatic
            // Nur von selbst Eingereihtes kann ins Archiv gehören.
            self.backlog = automatic && backlog
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Hält die Reihenfolge fest. Die laufende Folge gehört vorn dazu: der
    /// Worker hat sie schon aus der Warteschlange genommen, und ohne sie
    /// ginge genau die Arbeit verloren, die gerade lief. Jede Folge einmal.
    public init(running: EpisodeID?, queue: [EpisodeID], automatic: Set<EpisodeID>, backlog: Set<EpisodeID>) {
        var seen: Set<EpisodeID> = []
        entries = ([running].compactMap { $0 } + queue)
            .filter { seen.insert($0).inserted }
            .map { Entry(episodeID: $0, automatic: automatic.contains($0), backlog: backlog.contains($0)) }
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data?) -> AnalysisQueueSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AnalysisQueueSnapshot.self, from: data)
    }

    /// Was nach dem Neustart wieder in die Warteschlange kommt, in der
    /// gemerkten Reihenfolge. Es fällt heraus, was inzwischen ein Transkript
    /// hat, was es nicht mehr gibt und, wenn die App nicht mehr von selbst
    /// vorbereiten soll, was sie von selbst eingereiht hatte.
    public func restorable(
        known: Set<EpisodeID>, finished: Set<EpisodeID>, automaticAllowed: Bool
    ) -> [Entry] {
        entries.filter { entry in
            known.contains(entry.episodeID) && !finished.contains(entry.episodeID)
                && (automaticAllowed || !entry.automatic)
        }
    }
}

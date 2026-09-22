//
//  EpisodeFact.swift
//  PodcastAICore
//
//  Eine überprüfbare Aussage aus einer Folge. Jede Aussage zeigt auf den
//  Beleg, aus dem sie stammt, und damit auf eine Stelle im Originalton.
//

import Foundation

public struct EpisodeFact: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let episodeID: EpisodeID
    public let sourceID: SourceID
    public let evidenceID: EvidenceID
    public let mediaVersionID: MediaVersionID
    public let statement: String
    public let range: MediaTimeRange
    /// Welches Modell die Aussage formuliert hat.
    public let modelTier: String

    public init(id: String, episodeID: EpisodeID, sourceID: SourceID, evidenceID: EvidenceID,
                mediaVersionID: MediaVersionID, statement: String, range: MediaTimeRange,
                modelTier: String) {
        self.id = id; self.episodeID = episodeID; self.sourceID = sourceID
        self.evidenceID = evidenceID; self.mediaVersionID = mediaVersionID
        self.statement = statement; self.range = range; self.modelTier = modelTier
    }
}

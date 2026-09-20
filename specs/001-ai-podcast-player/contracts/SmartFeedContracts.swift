// Specification-only value contracts, version 1.3.
// No Apple SDK integration or successful app build is implied.
import Foundation

public enum SmartFeedFilter: String, Codable, Sendable {
    case unheardSegments, neverStartedEpisodes
}
public enum SmartFeedEditionMode: String, Codable, Sendable {
    case allUnheard, budgeted
}
public enum SmartCoverOrigin: String, Codable, Sendable {
    case nativeTemplate, userConfirmedImagePlayground
    case userSelectedImage, reusedFeedArtwork
}
public enum SmartFeedContractError: Error, Sendable {
    case invalidRange, invalidTimeline, missingEvidence
}
public struct SmartSourceRange: Codable, Hashable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public func validate() throws {
        guard startMs >= 0, endMs > startMs, endMs <= 9_007_199_254_740_991
        else { throw SmartFeedContractError.invalidRange }
    }
}
public struct SmartFeedConfiguration: Codable, Sendable {
    public let id: String
    public let title: String
    public let topicIDs: [String]
    public let sourceEpisodeIDs: [String]
    public let profileRevision: Int64
    public let policyRevision: Int64
    public let learningEnabled: Bool
    public let unheardFilter: SmartFeedFilter
    public let editionMode: SmartFeedEditionMode
    public let activeListeningBudgetMs: Int64
}
public struct SmartOriginalSegment: Codable, Sendable {
    public let id: String
    public let episodeID: String
    public let mediaVersionID: String
    public let transcriptRevisionID: String
    public let evidenceIDs: [String]
    public let coreRange: SmartSourceRange
    public let playbackRange: SmartSourceRange
    public let virtualRange: SmartSourceRange
    public let contextReplay: Bool

    public func validate() throws {
        try coreRange.validate()
        try playbackRange.validate()
        try virtualRange.validate()
        guard !evidenceIDs.isEmpty else { throw SmartFeedContractError.missingEvidence }
        guard playbackRange.startMs <= coreRange.startMs,
              playbackRange.endMs >= coreRange.endMs,
              virtualRange.endMs - virtualRange.startMs == playbackRange.endMs - playbackRange.startMs
        else { throw SmartFeedContractError.invalidTimeline }
    }
}
// Persist via the existing actor-isolated store. IDs/snapshots cross isolation boundaries;
// ModelContext, AVPlayer and SwiftUI views do not. JSON schemas remain the full wire contracts.

// Original domain contract example. Not a built app; no SDK-specific adapters included.
import Foundation

public enum ContractError: Error, Sendable { case invalidRange, invalidBudget, unavailable }
public struct OriginalRange: Codable, Hashable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public init(startMs: Int64, endMs: Int64) throws {
        guard startMs >= 0, endMs > startMs, endMs <= 9_007_199_254_740_991 else {
            throw ContractError.invalidRange
        }
        self.startMs = startMs
        self.endMs = endMs
    }
    private enum CodingKeys: String, CodingKey { case startMs, endMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startMs: c.decode(Int64.self, forKey: .startMs),
                      endMs: c.decode(Int64.self, forKey: .endMs))
    }
}
public struct EvidenceReference: Codable, Hashable, Sendable {
    public let id: String
    public let episodeID: String
    public let mediaVersionID: String?
    public let transcriptRevisionID: String
    public let range: OriginalRange?
}
public struct SearchScope: Codable, Hashable, Sendable {
    public let selectedEpisodeIDs: Set<String>
    public let accessRevision: UInt64
}
public struct SourceResolution: Sendable {
    public let sourceID: String
    public let verifiedChannelID: String?
    public let canonicalFeedURL: URL?
    public let actions: [Action]
    public enum Action: String, Sendable { case singleEpisode, subscribe, backfill }
}
public protocol SourceResolving: Sendable {
    func resolve(_ url: URL) async throws -> SourceResolution
}
public protocol EvidenceSearching: Sendable {
    func search(_ text: String, in scope: SearchScope) async throws -> [EvidenceReference]
}
public protocol HistoricalCatalog: Sendable {
    func nextPage(sourceID: String, cursor: String?) async throws -> CatalogPage
}
public struct CatalogPage: Sendable {
    public let episodeIDs: [String]
    public let nextCursor: String?
}
// Concrete Apple adapters implement these contracts after baseline audit and SDK probes.
// A playback grant MUST be constructed only by the local policy owner, never decoded
// directly from an LLM response or accepted from a shared/synchronized record.

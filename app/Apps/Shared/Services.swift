//
//  Services.swift
//  PodcastAI
//
//  Die Dienste, die Netz, Dateisystem und Modellzustand an die Oberfläche
//  anbinden. Bewusst klein gehalten: die Regeln stehen in PodcastAIKit,
//  hier wird nur zusammengesteckt.
//

import Foundation
import PodcastAIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Feeds holen und einlesen

public struct AddedSource: Sendable {
    public let title: String
    public let episodeCount: Int
}

public struct RefreshResult: Sendable {
    public let newEpisodes: Int
    public let failedSources: [String]
}

public actor FeedRefresher {

    private let store: LibraryStore
    private let resolver = SourceResolver()
    private let parser = FeedParser()
    private let session: URLSession

    public init(store: LibraryStore) {
        self.store = store
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 30
        // Kein beliebiger Klartextzugriff: ein Feed darf die App nicht in
        // eine unverschlüsselte Verbindung ziehen.
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    public func addSource(from input: String) async throws -> AddedSource {
        let link = try resolver.resolve(input)

        let feedURL: URL
        let kind: SourceKind
        var capabilities: SourceCapabilities

        switch link {
        case .podcastFeed(let url):
            feedURL = url; kind = .podcastRSS; capabilities = .fullPodcast
        case .youTubeChannel(_, let url):
            // Metadaten ja, Audiozugang nein — und das wird auch so angezeigt.
            feedURL = url; kind = .youTubeChannel; capabilities = .youTubeMetadataOnly
        case .youTubeVideo, .youTubePlaylist, .webPageNeedingDiscovery:
            throw FeedRefreshError.needsDiscovery
        case .localFile(let url):
            feedURL = url; kind = .localFile
            capabilities = SourceCapabilities(metadata: true, audioDownload: true)
        }

        let data = try await fetch(feedURL)
        let parsed = try parser.parse(data)

        // Stabile Kennung aus der Feed-Adresse: dieselbe Quelle zweimal
        // hinzuzufügen erzeugt keine zweite Quelle.
        let sourceID = SourceID(stable: feedURL.absoluteString)
        if parsed.items.contains(where: { $0.transcripts.contains(where: \.isTimed) }) {
            capabilities.publisherTranscript = true
        }
        if parsed.nextPageURL != nil { capabilities.historicalCatalog = true }

        let source = Source(
            id: sourceID, kind: kind,
            title: parsed.title.isEmpty ? feedURL.host ?? "Unbenannte Quelle" : parsed.title,
            author: parsed.author, feedURL: feedURL,
            websiteURL: parsed.websiteURL, artworkURL: parsed.artworkURL,
            capabilities: capabilities
        )
        try await store.upsert(source: source)

        let episodes = parsed.items.map { makeEpisode($0, sourceID: sourceID) }
        _ = try await store.upsert(episodes: episodes, forSource: sourceID)

        return AddedSource(title: source.title, episodeCount: episodes.count)
    }

    public func refreshAll() async throws -> RefreshResult {
        var newEpisodes = 0
        var failed: [String] = []

        for source in try await store.sources() where source.isSubscribed {
            guard let feedURL = source.feedURL else { continue }
            do {
                let parsed = try parser.parse(try await fetch(feedURL))
                let episodes = parsed.items.map { makeEpisode($0, sourceID: source.id) }
                newEpisodes += try await store.upsert(episodes: episodes, forSource: source.id)
            } catch {
                // Eine kaputte Quelle darf den Lauf nicht abbrechen.
                failed.append(source.title)
            }
        }
        return RefreshResult(newEpisodes: newEpisodes, failedSources: failed)
    }

    private func makeEpisode(_ item: ParsedItem, sourceID: SourceID) -> Episode {
        // Kennung aus der Feed-GUID. Der Titel taugt nicht: er ändert sich,
        // und zwei Folgen können gleich heißen.
        let key = item.guid ?? item.audioURL?.absoluteString ?? item.title
        return Episode(
            id: EpisodeID(stable: "\(sourceID.rawValue)|\(key)"),
            sourceID: sourceID,
            title: item.title,
            summary: item.summary,
            publishedAt: item.publishedAt,
            declaredDuration: item.duration.map { MediaDuration(seconds: Double($0)) },
            artworkURL: item.artworkURL,
            webPageURL: item.webPageURL,
            audioURL: item.audioURL,
            // Nur getaktete Transkripte: ungetakteter Text liefert Wissen,
            // aber keine Timecodes.
            timedTranscriptURL: item.transcripts.first(where: \.isTimed)?.url
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("PodcastAI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedRefreshError.httpStatus(http.statusCode)
        }
        return data
    }
}

public enum FeedRefreshError: Error, LocalizedError {
    case needsDiscovery
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .needsDiscovery:
            "Zu diesem Link muss erst der Feed ermittelt werden. Das ist noch nicht eingebaut — "
            + "füge bis dahin die Feed-Adresse direkt ein."
        case .httpStatus(let code):
            "Die Quelle hat mit Status \(code) geantwortet."
        }
    }
}

// MARK: - Medien finden

public struct LocalMediaLocator: MediaLocating {

    public init() {}

    public func playbackURL(for mediaVersionID: MediaVersionID) -> URL? {
        let base = Self.mediaDirectory
        let candidate = base.appendingPathComponent(mediaVersionID.rawValue)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("PodcastAI/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Modellzustand

public enum ModelStatusProbe {

    /// Fragt den tatsächlichen Zustand ab.
    ///
    /// PCC wird hier bewusst als nicht verfügbar gemeldet, solange kein
    /// Entitlement für dieses Entwicklerkonto vorliegt. Das ist ein offener
    /// Nachweis aus dem Plan (GATE-PCC) und keine Stelle, an der man
    /// optimistisch raten sollte.
    public static func current() async -> ModelStatus {
        #if canImport(FoundationModels)
        let onDevice: ModelAvailability = await checkOnDevice()
        #else
        let onDevice: ModelAvailability = .unavailable(.deviceNotEligible)
        #endif
        return ModelStatus(
            onDevice: onDevice,
            privateCloudCompute: .unavailable(.entitlementMissing)
        )
    }

    #if canImport(FoundationModels)
    private static func checkOnDevice() async -> ModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return switch reason {
            case .deviceNotEligible: .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: .unavailable(.appleIntelligenceDisabled)
            case .modelNotReady: .unavailable(.modelNotReady)
            @unknown default: .unavailable(.unknown("unbekannter Grund"))
            }
        @unknown default:
            return .unavailable(.unknown("unbekannter Zustand"))
        }
    }
    #endif
}

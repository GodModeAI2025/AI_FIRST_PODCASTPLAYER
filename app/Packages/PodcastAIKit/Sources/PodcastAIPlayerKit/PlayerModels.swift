//
//  PlayerModels.swift
//  PodcastAIPlayerKit
//
//  Der schmale Satz SwiftData-Modelle für Uhr und Fernseher.
//
//  Die Namen der Entitäten und aller Eigenschaften, ihre Typen und Standard-
//  werte sind dieselben wie in `PodcastAIPersistence/Models.swift`. Das
//  CloudKit-Schema ändert sich dadurch nicht, die Player lesen dieselben
//  Datensätze im selben Container. Es fehlen nur Entitäten und Beziehungen,
//  die ein Player nicht braucht: Medienfassungen, Transkripte, Segmente,
//  Interessen, Tags, Fakten, Belege, Themenfeeds und Unterhaltungen. Ein
//  Test (`PlayerSchemaParityTests`) vergleicht jede Eigenschaft mit dem
//  Hauptschema, damit die beiden Fassungen nicht auseinanderlaufen.
//
//  Warum nicht die echten Modelle: `PodcastAIPersistence` hängt an
//  FoundationModels und baut auf watchOS und tvOS nicht. Außerdem zögen die
//  Beziehungen der echten Modelle Transkripte und Segmente in jeden
//  Container, und die gehören nicht auf eine Uhr.
//
//  CloudKit-tauglich wie das Original: jede Eigenschaft optional oder mit
//  Standardwert, Beziehungen optional, keine eindeutigen Schlüssel.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore

@Model
final class StoredSource {
    #Index<StoredSource>([\.identifier])
    var identifier: String = ""
    var kindRaw: String = SourceKind.podcastRSS.rawValue
    var title: String = ""
    var author: String?
    var feedURLString: String?
    var websiteURLString: String?
    var artworkURLString: String?
    var languageCode: String?
    var isSubscribed: Bool = true
    var addedAt: Date = Date()
    var revisionValue: Int = 0

    var canDownloadAudio: Bool = false
    var hasPublisherTranscript: Bool = false
    var embeddedPlayerOnly: Bool = false
    var hasHistoricalCatalog: Bool = false
    var limitationReason: String?

    var summary: String?
    var categories: [String] = []
    var isExplicit: Bool?

    @Relationship(deleteRule: .nullify, inverse: \StoredEpisode.source)
    var episodes: [StoredEpisode]? = []

    init(identifier: String, kind: SourceKind, title: String) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.title = title
    }

    var snapshot: Source {
        Source(
            id: SourceID(rawValue: identifier),
            kind: SourceKind(rawValue: kindRaw) ?? .podcastRSS,
            title: title, author: author,
            feedURL: feedURLString.flatMap(URL.init(string:)),
            websiteURL: websiteURLString.flatMap(URL.init(string:)),
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            capabilities: SourceCapabilities(
                metadata: true, audioDownload: canDownloadAudio,
                publisherTranscript: hasPublisherTranscript,
                embeddedPlayerOnly: embeddedPlayerOnly,
                historicalCatalog: hasHistoricalCatalog,
                limitationReason: limitationReason
            ),
            language: languageCode, summary: summary,
            categories: categories.isEmpty ? nil : categories,
            isExplicit: isExplicit, isSubscribed: isSubscribed,
            addedAt: addedAt, revision: Revision(revisionValue)
        )
    }
}

@Model
final class StoredEpisode {
    #Index<StoredEpisode>([\.identifier], [\.publishedAt])
    var identifier: String = ""
    var title: String = ""
    var summary: String?
    var publishedAt: Date?
    var declaredDurationMs: Int = 0
    var webPageURLString: String?
    var audioURLString: String?
    var timedTranscriptURLString: String?
    var artworkURLString: String?
    var currentMediaVersionIdentifier: String?
    var revisionValue: Int = 0
    var chaptersData: Data?
    var chaptersURLString: String?
    var shownotesHTML: String?
    var removedAt: Date?

    var author: String?
    var episodeNumber: Int?
    var season: Int?
    var episodeType: String?
    var keywords: [String] = []

    var source: StoredSource?

    init(identifier: String, title: String) {
        self.identifier = identifier
        self.title = title
    }

    /// Die Folge als Wert. Transkriptadresse und Stichworte bleiben leer: ein
    /// Player braucht sie nicht, und so kommen sie nicht in seine Ansichten.
    var snapshot: Episode {
        Episode(
            id: EpisodeID(rawValue: identifier),
            sourceID: SourceID(rawValue: source?.identifier ?? ""),
            title: title, summary: summary, publishedAt: publishedAt,
            declaredDuration: declaredDurationMs > 0
                ? MediaDuration(milliseconds: Int64(declaredDurationMs)) : nil,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            webPageURL: webPageURLString.flatMap(URL.init(string:)),
            audioURL: audioURLString.flatMap(URL.init(string:)),
            publisherChapters: chaptersData.flatMap { try? JSONDecoder().decode([Chapter].self, from: $0) } ?? [],
            chaptersURL: chaptersURLString.flatMap(URL.init(string:)),
            shownotesHTML: shownotesHTML,
            currentMediaVersionID: currentMediaVersionIdentifier.map(MediaVersionID.init(rawValue:)),
            revision: Revision(revisionValue),
            author: author, episodeNumber: episodeNumber, season: season,
            episodeType: episodeType
        )
    }
}

/// Der Hörzustand einer Fassung auf einem Gerät. Siehe das Original in
/// `PodcastAIPersistence`: je Gerät eine Zeile, der Schlüssel
/// `"<Fassung>#<Gerät>"` steht in `mediaVersionIdentifier`. Der Player
/// schreibt nur seine eigene Zeile und liest alle.
@Model
final class StoredListeningState {
    var mediaVersionIdentifier: String = ""
    var heardFlat: [Int] = []
    var skippedFlat: [Int] = []
    var historyQualityRaw: String = HistoryQuality.exact.rawValue
    var resumePositionMs: Int = 0
    var lastEventAt: Date?

    init(mediaVersionIdentifier: String) {
        self.mediaVersionIdentifier = mediaVersionIdentifier
    }

    static let deviceSeparator: Character = "#"

    static func rowKey(media: String, deviceID: String) -> String {
        deviceID.isEmpty ? media : media + String(deviceSeparator) + deviceID
    }

    var mediaKey: String {
        String(mediaVersionIdentifier.prefix { $0 != Self.deviceSeparator })
    }

    var snapshot: MediaListeningState {
        MediaListeningState(
            mediaVersionID: MediaVersionID(rawValue: mediaKey),
            heard: IntervalSet(Self.ranges(from: heardFlat)),
            skipped: IntervalSet(Self.ranges(from: skippedFlat)),
            quality: HistoryQuality(rawValue: historyQualityRaw) ?? .exact,
            lastEventAt: lastEventAt,
            resumePosition: resumePositionMs > 0
                ? MediaTime(milliseconds: Int64(resumePositionMs)) : nil
        )
    }

    func apply(_ state: MediaListeningState) {
        heardFlat = Self.flat(from: state.heard)
        skippedFlat = Self.flat(from: state.skipped)
        historyQualityRaw = state.quality.rawValue
        resumePositionMs = Int(state.resumePosition?.milliseconds ?? 0)
        lastEventAt = state.lastEventAt
    }

    static func ranges(from flat: [Int]) -> [MediaTimeRange] {
        stride(from: 0, to: flat.count - 1, by: 2).map { index in
            MediaTimeRange(start: MediaTime(milliseconds: Int64(flat[index])),
                           end: MediaTime(milliseconds: Int64(flat[index + 1])))
        }
    }

    static func flat(from set: IntervalSet) -> [Int] {
        set.ranges.flatMap { [Int($0.start.milliseconds), Int($0.end.milliseconds)] }
    }
}
#endif

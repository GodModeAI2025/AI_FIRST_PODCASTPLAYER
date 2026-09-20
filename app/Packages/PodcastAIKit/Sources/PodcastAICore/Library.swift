//
//  Library.swift
//  PodcastAICore
//
//  Quelle, Folge und Medienfassung sind drei verschiedene Dinge. Ein Feed
//  kann eine Folge neu ausliefern, eine Folge kann mehrere Fassungen haben,
//  und ein Timecode gilt immer nur für genau eine Fassung.
//

import Foundation

/// Wie eine Quelle technisch erschlossen wird.
public enum SourceKind: String, Codable, Sendable {
    case podcastRSS
    case youTubeChannel
    case singleEpisodeLink
    case localFile
}

/// Was mit dieser Quelle erlaubt ist. Unabhängige Flags, keine Rangfolge —
/// ein YouTube-Atom-Feed liefert Metadaten, aber keinen Audiozugang.
public struct SourceCapabilities: Hashable, Codable, Sendable {

    /// Metadaten (Titel, Beschreibung, Veröffentlichungsdatum) sind abrufbar.
    public var metadata: Bool
    /// Eine Audiodatei ist über eine reguläre, autorisierte URL abrufbar.
    public var audioDownload: Bool
    /// Ein vom Anbieter bereitgestelltes Transkript liegt vor.
    public var publisherTranscript: Bool
    /// Wiedergabe ist nur über den offiziellen sichtbaren Player zulässig.
    public var embeddedPlayerOnly: Bool
    /// Das vollständige Archiv ist erschließbar, nicht nur das Feedfenster.
    public var historicalCatalog: Bool

    /// Begründung, die dem Nutzer angezeigt wird, wenn etwas nicht geht.
    public var limitationReason: String?

    public init(
        metadata: Bool = true,
        audioDownload: Bool = false,
        publisherTranscript: Bool = false,
        embeddedPlayerOnly: Bool = false,
        historicalCatalog: Bool = false,
        limitationReason: String? = nil
    ) {
        self.metadata = metadata
        self.audioDownload = audioDownload
        self.publisherTranscript = publisherTranscript
        self.embeddedPlayerOnly = embeddedPlayerOnly
        self.historicalCatalog = historicalCatalog
        self.limitationReason = limitationReason
    }

    /// Kann aus dieser Quelle überhaupt Wissen mit Timecodes entstehen?
    /// Ohne Audio oder getaktetes Transkript gibt es keine Fokuswiedergabe.
    public var supportsTimedKnowledge: Bool { audioDownload || publisherTranscript }

    public static let fullPodcast = SourceCapabilities(
        metadata: true, audioDownload: true, historicalCatalog: true
    )

    /// YouTube über den Kanal-Atom-Feed: Metadaten ja, Audiozugriff nein.
    public static let youTubeMetadataOnly = SourceCapabilities(
        metadata: true,
        audioDownload: false,
        embeddedPlayerOnly: true,
        historicalCatalog: true,
        limitationReason: "Für diesen Kanal sind nur Metadaten und die Wiedergabe im offiziellen Player zugänglich. Ohne Audiozugang entstehen keine Timecodes."
    )
}

public struct Source: Hashable, Codable, Sendable, Identifiable {

    public let id: SourceID
    public let kind: SourceKind
    public var title: String
    public var author: String?
    public var feedURL: URL?
    public var websiteURL: URL?
    public var artworkURL: URL?
    public var capabilities: SourceCapabilities

    /// Abonniert heißt: neue Folgen werden erfasst. Es heißt **nicht**, dass
    /// alles heruntergeladen oder analysiert wird.
    public var isSubscribed: Bool
    /// Was beim Abonnieren rückwirkend erschlossen werden soll.
    public var backfillPolicy: BackfillPolicy
    public var addedAt: Date
    public var revision: Revision

    public init(
        id: SourceID, kind: SourceKind, title: String, author: String? = nil,
        feedURL: URL? = nil, websiteURL: URL? = nil, artworkURL: URL? = nil,
        capabilities: SourceCapabilities = .fullPodcast,
        isSubscribed: Bool = true, backfillPolicy: BackfillPolicy = .newEpisodesOnly,
        addedAt: Date = Date(), revision: Revision = .initial
    ) {
        self.id = id; self.kind = kind; self.title = title; self.author = author
        self.feedURL = feedURL; self.websiteURL = websiteURL; self.artworkURL = artworkURL
        self.capabilities = capabilities; self.isSubscribed = isSubscribed
        self.backfillPolicy = backfillPolicy; self.addedAt = addedAt; self.revision = revision
    }
}

/// Wie weit zurück beim Abonnieren erschlossen wird — eine ausdrückliche
/// Nutzerentscheidung, keine stille Voreinstellung mit großen Folgen.
public enum BackfillPolicy: Hashable, Codable, Sendable {
    case newEpisodesOnly
    case since(Date)
    case lastN(Int)
    case selectedEpisodes([EpisodeID])
    case entireAvailableArchive

    public var label: String {
        switch self {
        case .newEpisodesOnly: "Nur neue Folgen"
        case .since(let d): "Ab \(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none))"
        case .lastN(let n): "Letzte \(n) Folgen"
        case .selectedEpisodes(let ids): "\(ids.count) ausgewählte Folgen"
        case .entireAvailableArchive: "Gesamtes verfügbares Archiv"
        }
    }
}

public struct Episode: Hashable, Codable, Sendable, Identifiable {

    public let id: EpisodeID
    public let sourceID: SourceID
    public var title: String
    public var summary: String?
    /// Wann die Folge im Original erschienen ist — nicht zu verwechseln mit
    /// dem Zeitpunkt, an dem sie in der Mediathek auftaucht oder in einer
    /// persönlichen Ausgabe erscheint.
    public var publishedAt: Date?
    public var declaredDuration: MediaDuration?
    public var artworkURL: URL?
    public var webPageURL: URL?
    /// Vom Anbieter vergebene Kapitel, sofern vorhanden.
    public var publisherChapters: [Chapter]
    /// Die aktuell maßgebliche Medienfassung.
    public var currentMediaVersionID: MediaVersionID?
    public var revision: Revision

    public init(
        id: EpisodeID, sourceID: SourceID, title: String, summary: String? = nil,
        publishedAt: Date? = nil, declaredDuration: MediaDuration? = nil,
        artworkURL: URL? = nil, webPageURL: URL? = nil,
        publisherChapters: [Chapter] = [], currentMediaVersionID: MediaVersionID? = nil,
        revision: Revision = .initial
    ) {
        self.id = id; self.sourceID = sourceID; self.title = title; self.summary = summary
        self.publishedAt = publishedAt; self.declaredDuration = declaredDuration
        self.artworkURL = artworkURL; self.webPageURL = webPageURL
        self.publisherChapters = publisherChapters
        self.currentMediaVersionID = currentMediaVersionID; self.revision = revision
    }
}

public struct Chapter: Hashable, Codable, Sendable {
    public let start: MediaTime
    public let title: String
    /// Vom Anbieter oder aus der Analyse abgeleitet — bleibt unterscheidbar.
    public let provenance: Provenance

    public init(start: MediaTime, title: String, provenance: Provenance) {
        self.start = start; self.title = title; self.provenance = provenance
    }
}

/// Eine konkrete Datei bzw. ein konkreter Stream. Alle Timecodes beziehen
/// sich auf genau eine Fassung.
public struct MediaVersion: Hashable, Codable, Sendable, Identifiable {

    public let id: MediaVersionID
    public let episodeID: EpisodeID
    public let remoteURL: URL?
    public var localRelativePath: String?
    public var byteCount: Int64?

    /// SHA-256 der vollständigen Datei. Erst nach vollständigem Download
    /// verfügbar; vorher ist die Identität vorläufig.
    public var contentHash: String?
    public var duration: MediaDuration?
    public var mimeType: String?
    public var acquiredAt: Date

    /// Solange kein Hash vorliegt, ist die Identität nicht bewiesen.
    /// Analyseergebnisse dürfen daran hängen, aber nicht als endgültig gelten.
    public var isIdentityProvisional: Bool { contentHash == nil }

    /// Exakte Sprünge setzen voraus, dass die Fassung zuverlässig suchbar ist.
    public var supportsExactSeeking: Bool

    public init(
        id: MediaVersionID, episodeID: EpisodeID, remoteURL: URL? = nil,
        localRelativePath: String? = nil, byteCount: Int64? = nil, contentHash: String? = nil,
        duration: MediaDuration? = nil, mimeType: String? = nil,
        acquiredAt: Date = Date(), supportsExactSeeking: Bool = true
    ) {
        self.id = id; self.episodeID = episodeID; self.remoteURL = remoteURL
        self.localRelativePath = localRelativePath; self.byteCount = byteCount
        self.contentHash = contentHash; self.duration = duration; self.mimeType = mimeType
        self.acquiredAt = acquiredAt; self.supportsExactSeeking = supportsExactSeeking
    }
}

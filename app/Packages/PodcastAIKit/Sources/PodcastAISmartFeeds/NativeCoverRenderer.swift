//
//  NativeCoverRenderer.swift
//  PodcastAISmartFeeds
//
//  Das Cover eines Themen-Updates.
//
//  Zwei Wege, die bewusst getrennt bleiben:
//
//  1. **Natives Layoutcover**: entsteht sofort aus Titel, Datum und Farbe.
//     Kein Modell, keine Wartezeit, keine Berechtigung. Es steht überall,
//     solange kein Bild da ist, und auf Geräten ohne Image Playground immer.
//
//  2. **Image Playground**: ein abstraktes Bild aus den Themen des Updates,
//     einmal je Update erzeugt und als Datei abgelegt
//     (`TopicCoverArtwork.swift`). Nur Apple-Stile, kein externer Anbieter.
//
//  Jedes Cover trägt seine Herkunft. Ein Layout ist kein generiertes Bild
//  und wird auch nicht so ausgegeben.
//

import Foundation
import PodcastAICore

/// Woher ein Cover stammt.
public enum CoverOrigin: String, Codable, Sendable {
    /// Automatisch gesetztes Layout aus Titel und Themen.
    case nativeLayout
    /// Vom Nutzer im Systemdialog bestätigtes Bild.
    case imagePlaygroundConfirmed
    /// Von der App mit Image Playground aus den Themen erzeugtes Bild.
    case imagePlaygroundGenerated
    /// Vom Feed übernommenes, vom Nutzer bestätigtes Motiv.
    case reusedFeedArtwork

    public var label: String {
        switch self {
        case .nativeLayout: String(localized: "Automatisch gestaltet", bundle: .module)
        case .imagePlaygroundConfirmed: String(localized: "Mit Image Playground erstellt", bundle: .module)
        case .imagePlaygroundGenerated: String(localized: "Mit Image Playground erzeugt", bundle: .module)
        case .reusedFeedArtwork: String(localized: "Motiv des Podcasts", bundle: .module)
        }
    }

    /// Ist das ein generiertes Bild? Nur bei Image Playground.
    public var isGeneratedImage: Bool {
        self == .imagePlaygroundConfirmed || self == .imagePlaygroundGenerated
    }
}

public struct CoverAsset: Sendable, Hashable, Codable, Identifiable {

    public let id: String
    public let origin: CoverOrigin
    public let revision: Revision
    /// Beim Layoutcover die Bausteine, aus denen es entsteht.
    public let title: String
    public let subtitle: String?
    /// Farbwahl als Index in die Palette — deterministisch aus dem Titel,
    /// damit derselbe Feed nicht bei jeder Ausgabe die Farbe wechselt.
    public let paletteIndex: Int
    /// Pflicht, nicht optional: ein Cover ohne Beschreibung ist für
    /// VoiceOver ein leeres Bild.
    public let altText: String
    /// Nur bei bestätigtem Bild gefüllt.
    public let assetRelativePath: String?
    public let userConfirmed: Bool

    public init(
        id: String, origin: CoverOrigin, revision: Revision = .initial,
        title: String, subtitle: String? = nil, paletteIndex: Int,
        altText: String, assetRelativePath: String? = nil, userConfirmed: Bool = false
    ) {
        self.id = id; self.origin = origin; self.revision = revision
        self.title = title; self.subtitle = subtitle; self.paletteIndex = paletteIndex
        self.altText = altText; self.assetRelativePath = assetRelativePath
        self.userConfirmed = userConfirmed
    }
}

public struct NativeCoverRenderer: Sendable {

    /// Anzahl der Farbvarianten. Der Index wird deterministisch aus dem
    /// Titel abgeleitet, damit ein Feed sein Aussehen behält.
    public static let paletteCount = 8

    public init() {}

    /// Erzeugt sofort ein Cover. Ohne Modell, ohne Netz, ohne Berechtigung.
    public func makeCover(for episode: PersonalEpisode, feedTitle: String) -> CoverAsset {
        let topics = Set(episode.segments.flatMap(\.topicIDs)).count
        let sources = episode.distinctSourceCount

        return CoverAsset(
            id: "cover-\(episode.batchKey)",
            origin: .nativeLayout,
            title: feedTitle,
            subtitle: episode.publishedAt.formatted(date: .abbreviated, time: .omitted),
            paletteIndex: Self.paletteIndex(for: feedTitle),
            altText: Self.altText(feedTitle: feedTitle, segments: episode.segments.count,
                                  sources: sources, topics: topics)
        )
    }

    /// Das Cover eines Updates ohne Ausgabe: Titel und Farbe, kein Datum.
    /// So hat ein neues Update schon in der Liste ein Gesicht.
    public func makeCover(for feed: SmartPodcastFeed) -> CoverAsset {
        CoverAsset(
            id: "cover-feed-\(feed.id.rawValue)",
            origin: .nativeLayout,
            title: feed.title,
            paletteIndex: Self.paletteIndex(for: feed.title),
            altText: String(localized: "Cover für \(feed.title).", bundle: .module)
        )
    }

    /// Deterministisch aus dem Titel — gleicher Feed, gleiche Farbe.
    public static func paletteIndex(for title: String) -> Int {
        let digest = StableDigest.hex(of: title)
        let prefix = digest.prefix(8)
        let value = UInt32(prefix, radix: 16) ?? 0
        return Int(value % UInt32(paletteCount))
    }

    /// Die Bildbeschreibung. Beschreibt, was die Ausgabe **ist**, nicht wie
    /// sie aussieht — „blauer Farbverlauf“ hilft niemandem weiter.
    static func altText(feedTitle: String, segments: Int, sources: Int, topics: Int) -> String {
        // Die Zahlen werden für sich gebeugt, der Titel bleibt außerhalb:
        // er ist fremder Text und darf nicht als Markdown gelesen werden.
        let stellen = String(AttributedString(
            localized: "^[\(segments) Stelle](inflect: true)", bundle: .module).characters)
        let quellen = String(AttributedString(
            localized: "^[\(sources) Quelle](inflect: true)", bundle: .module).characters)
        return String(localized: "Cover für \(feedTitle): \(stellen) aus \(quellen).", bundle: .module)
    }
}

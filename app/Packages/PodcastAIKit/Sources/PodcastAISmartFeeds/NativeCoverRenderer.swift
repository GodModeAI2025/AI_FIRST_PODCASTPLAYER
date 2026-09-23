//
//  NativeCoverRenderer.swift
//  PodcastAISmartFeeds
//
//  Das Cover einer persönlichen Ausgabe.
//
//  Zwei Wege, die bewusst getrennt bleiben:
//
//  1. **Natives Layoutcover** — entsteht sofort und automatisch aus Titel
//     und Themen. Kein Modell, keine Wartezeit, keine Berechtigung. Eine
//     neue Ausgabe ist damit vom ersten Moment an vollständig benutzbar.
//
//  2. **Image Playground** — nur über den nutzergeführten Systemdialog, nur
//     auf ausdrückliche Aktion, nur mit Apple-Stilen.
//
//  Der Unterschied ist keine Feinheit: ein automatisch erzeugtes Layout ist
//  kein generiertes Bild. Es als solches auszugeben wäre eine Zusage, die
//  die App nicht halten kann — deshalb trägt jedes Cover seine Herkunft.
//

import Foundation
import PodcastAICore

/// Woher ein Cover stammt.
public enum CoverOrigin: String, Codable, Sendable {
    /// Automatisch gesetztes Layout aus Titel und Themen.
    case nativeLayout
    /// Vom Nutzer im Systemdialog bestätigtes Bild.
    case imagePlaygroundConfirmed
    /// Vom Feed übernommenes, vom Nutzer bestätigtes Motiv.
    case reusedFeedArtwork

    public var label: String {
        switch self {
        case .nativeLayout: String(localized: "Automatisch gestaltet", bundle: .module)
        case .imagePlaygroundConfirmed: String(localized: "Mit Image Playground erstellt", bundle: .module)
        case .reusedFeedArtwork: String(localized: "Motiv des Podcasts", bundle: .module)
        }
    }

    /// Ist das ein generiertes Bild? Nur bei Image Playground.
    public var isGeneratedImage: Bool { self == .imagePlaygroundConfirmed }
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

    /// Deterministisch aus dem Titel — gleicher Feed, gleiche Farbe.
    static func paletteIndex(for title: String) -> Int {
        let digest = StableDigest.hex(of: title)
        let prefix = digest.prefix(8)
        let value = UInt32(prefix, radix: 16) ?? 0
        return Int(value % UInt32(paletteCount))
    }

    /// Die Bildbeschreibung. Beschreibt, was die Ausgabe **ist**, nicht wie
    /// sie aussieht — „blauer Farbverlauf“ hilft niemandem weiter.
    static func altText(feedTitle: String, segments: Int, sources: Int, topics: Int) -> String {
        // Die Zahlen werden für sich gebeugt, der Titel bleibt ausserhalb:
        // er ist fremder Text und darf nicht als Markdown gelesen werden.
        let stellen = String(AttributedString(
            localized: "^[\(segments) Stelle](inflect: true)", bundle: .module).characters)
        let quellen = String(AttributedString(
            localized: "^[\(sources) Quelle](inflect: true)", bundle: .module).characters)
        return String(localized: "Cover für \(feedTitle): \(stellen) aus \(quellen).", bundle: .module)
    }
}

/// Führt den Image-Playground-Dialog.
///
/// Es gibt hier bewusst **keine** Methode, die im Hintergrund ein Bild
/// erzeugt. Apple unterstützt `ImageCreator` ab Version 27 nicht mehr, und
/// ein Produktwunsch macht aus einer nicht vorgesehenen API keine
/// vorgesehene. Was bleibt, ist der Systemdialog auf Nutzeraktion.
public struct CoverArtworkCoordinator: Sendable {

    public init() {}

    /// Kann der Systemdialog auf diesem Gerät angeboten werden?
    public let isAvailable: Bool = {
        #if canImport(ImagePlayground)
        true
        #else
        false
        #endif
    }()

    /// Die Stilvorgaben, die dem Dialog mitgegeben werden.
    ///
    /// Nur Apple-Stile, kein externer Anbieter, keine Personalisierung mit
    /// Gesichtern — für ein Themencover braucht es sie nicht, und was nicht
    /// gebraucht wird, wird nicht angefordert.
    public struct DialogOptions: Sendable {
        public let concepts: [String]
        public let allowsExternalProvider = false
        public let allowsPersonalization = false

        public init(concepts: [String]) {
            self.concepts = concepts
        }
    }

    public func dialogOptions(for feed: SmartPodcastFeed, topics: [String]) -> DialogOptions {
        DialogOptions(concepts: [feed.title] + topics.prefix(3))
    }

    /// Übernimmt ein bestätigtes Ergebnis.
    ///
    /// Die temporäre Ergebnisdatei des Dialogs ist kurzlebig. Sie wird
    /// sofort kopiert und geprüft — wer sie erst später liest, liest
    /// womöglich nichts mehr.
    public func adopt(
        temporaryURL: URL, into directory: URL, for feed: SmartPodcastFeed
    ) throws -> CoverAsset {
        let filename = "cover-\(feed.id.rawValue)-\(UUID().uuidString).png"
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: temporaryURL, to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw CoverError.emptyResult
        }

        return CoverAsset(
            id: filename, origin: .imagePlaygroundConfirmed,
            title: feed.title, paletteIndex: NativeCoverRenderer.paletteIndex(for: feed.title),
            altText: String(localized: "Vom Nutzer bestätigtes Cover für \(feed.title).", bundle: .module),
            assetRelativePath: filename, userConfirmed: true
        )
    }

    public enum CoverError: Error, LocalizedError {
        case emptyResult

        public var errorDescription: String? {
            String(localized: "Das Bild konnte nicht übernommen werden.", bundle: .module)
        }
    }
}

//
//  TopicCoverArtwork.swift
//  PodcastAISmartFeeds
//
//  Die Bildcover der Themen-Updates, erzeugt mit Image Playground.
//
//  Zwei Arten. Das Update selbst hat ein Bild aus seinen Tags, wie ein
//  Podcast sein Cover. Seit 0.11 bekommt jede Ausgabe ein eigenes, wie eine
//  Folge: aus ihren Tags und den zwei Namen, die in ihren Stellen am
//  häufigsten fallen. Beide sind abstrakt, ohne Schrift und immer im
//  selben Stil. Abgelegt werden sie als Dateien unter Application Support,
//  benannt nach Update, gegebenenfalls Ausgabe und einem Fingerabdruck der
//  Begriffe. Ändern sich die Tags eines Updates, passt der Name nicht mehr,
//  und das Cover gilt als veraltet. Eine Ausgabe ändert sich nicht, ihr
//  Bild bleibt, solange es sie gibt. In der Datenbank ändert sich nichts.
//
//  Seit 0.13 trägt der Name einer Ausgabe auch einen Fingerabdruck der
//  Menge ihrer Stellen (Entscheidung 10 in docs/plan-pipeline.md). Verliert
//  eine Ausgabe Stellen, weil eine Folge gelöscht wurde, passt ihr altes
//  Bild nicht mehr, auch wenn die Änderung von einem anderen Gerät kam und
//  hier niemand das Bild verworfen hat. Seine Namen könnten aus der
//  gelöschten Folge stammen (Regel 5). Bilder aus der Zeit davor werden
//  beim ersten Lesen übernommen.
//
//  Erzeugt wird über die eine Stelle für Apple Intelligence (`AIScheduling`,
//  Art `.cover`): Image Playground rechnet auf derselben GPU und Neural
//  Engine wie die Sprachmodelle.
//
//  `ImageCreator` ist seit Version 27 als veraltet markiert, Apple verweist
//  auf den Systemdialog. Er bleibt hier der Weg für das automatische Cover,
//  solange das System ihn anbietet. Meldet er sich als nicht verfügbar,
//  bleibt der Dialog (`TopicCoverGenerator.isDialogAvailable`), und ohne
//  beides das Layoutcover. Alles, was `ImageCreator` betrifft, steht in
//  `TopicCoverGenerator`, damit ein Wechsel nur diese eine Stelle trifft.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PodcastAICore
import PodcastAIIntelligence
#if canImport(ImagePlayground)
import ImagePlayground
#endif

// MARK: - Rezept

/// Wem ein Bildcover gehört: dem Update oder einer seiner Ausgaben, bei
/// einer Ausgabe zu einer bestimmten Menge von Stellen.
public struct TopicCoverKey: Sendable, Hashable {
    public let feedID: SmartFeedID
    /// `nil` beim Cover des Updates.
    public let editionID: PersonalEpisodeID?
    /// Fingerabdruck der Menge der Stellen einer Ausgabe. `nil` beim Update
    /// und bei einem Schlüssel, der nur den Besitzer meint, etwa zum Löschen.
    public let segments: String?

    public init(feedID: SmartFeedID, editionID: PersonalEpisodeID? = nil, segments: String? = nil) {
        self.feedID = feedID; self.editionID = editionID
        self.segments = editionID == nil ? nil : segments
    }

    /// Das Bild einer Ausgabe zu ihrer jetzigen Menge von Stellen.
    public init(edition: PersonalEpisode) {
        self.init(feedID: edition.feedID, editionID: edition.id, segments: Self.segmentDigest(of: edition))
    }

    /// Update oder Ausgabe, ohne die Menge der Stellen.
    public var owner: TopicCoverKey { TopicCoverKey(feedID: feedID, editionID: editionID) }

    /// Der Fingerabdruck der Menge der Stellen, unabhängig von ihrer
    /// Reihenfolge. Rücken die Stellen nach dem Löschen einer Folge
    /// zusammen, behalten sie ihre Kennung; es zählt nur, welche bleiben.
    public static func segmentDigest(of edition: PersonalEpisode) -> String {
        String(StableDigest.hex(ofUnordered: edition.segments.map(\.id.rawValue)).prefix(12))
    }
}

/// Woraus das Bild eines Updates oder einer Ausgabe entsteht.
///
/// Die Begriffe sind Tags und Namen, keine Sätze. Sie stammen aus dem
/// Inhalt und gehen als einzelne Begriffe an Image Playground, nie als
/// Anweisung.
public struct TopicCoverRecipe: Sendable, Hashable {

    public let feedID: SmartFeedID
    /// Gesetzt beim Cover einer Ausgabe.
    public let editionID: PersonalEpisodeID?
    /// Fingerabdruck der Stellen der Ausgabe, aus der das Rezept entstand.
    public let segments: String?
    /// Die Tags, bereinigt und gekürzt.
    public let concepts: [String]
    /// Die häufigsten Namen der Ausgabe. Beim Update leer.
    public let names: [String]
    /// Fingerabdruck der Begriffe, unabhängig von ihrer Reihenfolge.
    public let digest: String
    /// Der Zusatz für ein abstraktes Bild, in der Sprache des Geräts.
    public let abstractConcept: String

    /// Mehr Begriffe machen das Bild nicht besser, nur beliebiger.
    public static let maximumConcepts = 4
    /// Bei einer Ausgabe kommen Namen dazu, dafür weniger Tags.
    public static let maximumEditionTags = 3
    /// Höchstens so viele Namen je Ausgabe.
    public static let maximumNames = 2
    /// Ein Begriff. Was länger ist, wird abgeschnitten.
    public static let maximumConceptLength = 60
    /// Der Zusatz für den letzten Versuch. Englisch versteht Image
    /// Playground überall, auch wenn die Tags in einer Sprache sind, die
    /// es nicht unterstützt.
    public static let neutralConcept = "abstract shapes and soft color fields"

    /// Das Cover eines Updates aus seinen Tags.
    public init(feed: SmartPodcastFeed, topics: [String], languageCode: String? = nil) {
        var concepts = Self.cleaned(topics)
        // Ein Update ohne benannte Tags bekommt sein Bild aus dem Titel.
        if concepts.isEmpty { concepts = Self.cleaned([feed.title]) }
        self.init(feedID: feed.id, editionID: nil, segments: nil,
                  concepts: Array(concepts.prefix(Self.maximumConcepts)), names: [],
                  languageCode: languageCode)
    }

    /// Das Cover einer Ausgabe aus ihren Tags und den häufigsten Namen.
    /// Ein Name, der schon als Tag dasteht, zählt nicht doppelt.
    public init(edition: PersonalEpisode, feed: SmartPodcastFeed, topics: [String], names: [String],
                languageCode: String? = nil) {
        var concepts = Self.cleaned(topics)
        if concepts.isEmpty { concepts = Self.cleaned([feed.title]) }
        concepts = Array(concepts.prefix(Self.maximumEditionTags))
        let taken = Set(concepts.map(Self.fold))
        let names = Self.cleaned(names).filter { !taken.contains(Self.fold($0)) }
        self.init(feedID: edition.feedID, editionID: edition.id,
                  segments: TopicCoverKey.segmentDigest(of: edition), concepts: concepts,
                  names: Array(names.prefix(Self.maximumNames)), languageCode: languageCode)
    }

    private init(feedID: SmartFeedID, editionID: PersonalEpisodeID?, segments: String?, concepts: [String],
                 names: [String], languageCode: String?) {
        self.feedID = feedID
        self.editionID = editionID
        self.segments = segments
        self.concepts = concepts
        self.names = names
        let normalized = (concepts + names).map(Self.fold).sorted().joined(separator: "\n")
        digest = String(StableDigest.hex(of: normalized).prefix(12))
        let language = languageCode ?? Locale.current.language.languageCode?.identifier
        abstractConcept = language == "de" ? "abstrakte Formen und weiche Farbflächen" : Self.neutralConcept
    }

    public var key: TopicCoverKey { TopicCoverKey(feedID: feedID, editionID: editionID, segments: segments) }

    /// Die Versuche der Reihe nach: erst alle Begriffe mit dem Zusatz für
    /// ein abstraktes Bild, bei einer Ausgabe dann ohne die Namen, zuletzt
    /// nur der neutrale Zusatz. Die späteren Versuche greifen, wenn Image
    /// Playground mit den Begriffen nichts anfangen kann, etwa bei einem
    /// Namen oder einer nicht unterstützten Sprache.
    public var attempts: [[String]] {
        guard !names.isEmpty else { return [concepts + [abstractConcept], [Self.neutralConcept]] }
        return [concepts + names + [abstractConcept], concepts + [abstractConcept], [Self.neutralConcept]]
    }

    private static func cleaned(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let label = String(value.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumConceptLength))
            guard !label.isEmpty, seen.insert(fold(label)).inserted else { continue }
            result.append(label)
        }
        return result
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - Ablage

/// Ein abgelegtes Bildcover.
public struct StoredTopicCover: Sendable, Hashable {
    public let feedID: SmartFeedID
    /// Gesetzt beim Cover einer Ausgabe.
    public let editionID: PersonalEpisodeID?
    /// Fingerabdruck der Stellen, zu denen das Bild einer Ausgabe entstand.
    public let segments: String?
    public let digest: String
    public let url: URL
    public let createdAt: Date

    public init(feedID: SmartFeedID, editionID: PersonalEpisodeID? = nil, segments: String? = nil,
                digest: String, url: URL, createdAt: Date) {
        self.feedID = feedID; self.editionID = editionID; self.segments = segments; self.digest = digest
        self.url = url; self.createdAt = createdAt
    }

    /// Passt das Bild noch? Beim Update müssen die Tags gleich sein. Eine
    /// Ausgabe ändert sich nicht, ihr Bild passt, solange es ihr gehört und
    /// sie dieselben Stellen hat.
    public func matches(_ recipe: TopicCoverRecipe) -> Bool {
        guard feedID == recipe.feedID, editionID == recipe.editionID else { return false }
        return editionID == nil ? digest == recipe.digest : segments == recipe.segments
    }
}

/// Die Bildcover als Dateien: eins je Update und eins je Ausgabe.
///
/// Namen: `cover-<Update>-<Fingerabdruck>.png` für das Update,
/// `cover-<Update>-edition_<Ausgabe>_<Stellen>_<Fingerabdruck>.png` für eine
/// Ausgabe, vor 0.13 ohne `<Stellen>_`. Die Kennung des Updates ist so
/// kodiert, dass sie keinen Bindestrich enthält; alles bis zum zweiten
/// Bindestrich gehört also eindeutig zu einem Update, und Löschen je Update
/// trifft beide Arten.
public struct TopicCoverStore: Sendable {

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `Application Support/PodcastAI/Covers`.
    public static var standard: TopicCoverStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return TopicCoverStore(directory: base.appendingPathComponent("PodcastAI/Covers", isDirectory: true))
    }

    public enum StoreError: Error, LocalizedError {
        case unreadable
        case encodingFailed

        public var errorDescription: String? {
            String(localized: "Das Bild konnte nicht übernommen werden.", bundle: .module)
        }
    }

    /// Das abgelegte Cover eines Updates, auch ein veraltetes.
    public func stored(for feedID: SmartFeedID) -> StoredTopicCover? {
        stored(for: TopicCoverKey(feedID: feedID))
    }

    /// Das abgelegte Cover eines Updates oder einer Ausgabe. Bei einer
    /// Ausgabe nur das Bild zu genau dieser Menge von Stellen. Ein Bild aus
    /// der Zeit vor 0.13, ohne Fingerabdruck der Stellen, wird übernommen:
    /// Bis dahin verwarf dieses Gerät das Bild selbst, wenn die Ausgabe
    /// Stellen verlor.
    public func stored(for key: TopicCoverKey) -> StoredTopicCover? {
        if let found = Self.newest(in: files(for: key), key: key) { return found }
        guard key.editionID != nil, key.segments != nil,
              let legacy = Self.newest(in: files(for: key.owner), key: key.owner) else { return nil }
        return adopt(legacy, as: key)
    }

    /// Das jüngste Bild genau dieses Schlüssels unter den Dateien. Bei einem
    /// Schlüssel ohne Stellen fallen Bilder mit Stellen heraus, denn in ihrem
    /// Rest steckt noch ein `_`.
    private static func newest(in urls: [URL], key: TopicCoverKey) -> StoredTopicCover? {
        let prefix = Self.prefix(for: key)
        return urls.compactMap { url -> StoredTopicCover? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let digest = String(name.dropFirst(prefix.count))
            guard !digest.isEmpty, !digest.contains("-"), !digest.contains("_") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return StoredTopicCover(feedID: key.feedID, editionID: key.editionID, segments: key.segments,
                                    digest: digest, url: url, createdAt: date)
        }
        .max { $0.createdAt < $1.createdAt }
    }

    /// Benennt ein Bild aus der Zeit vor 0.13 für die jetzige Menge der
    /// Stellen um. Geht das nicht, gilt es als nicht vorhanden.
    private func adopt(_ legacy: StoredTopicCover, as key: TopicCoverKey) -> StoredTopicCover? {
        let url = directory.appendingPathComponent(Self.prefix(for: key) + legacy.digest + ".png")
        guard (try? FileManager.default.moveItem(at: legacy.url, to: url)) != nil else { return nil }
        return StoredTopicCover(feedID: key.feedID, editionID: key.editionID, segments: key.segments,
                                digest: legacy.digest, url: url, createdAt: legacy.createdAt)
    }

    /// Legt ein Bild ab, quadratisch zugeschnitten, und entfernt ältere
    /// Bilder desselben Besitzers. Die Cover der Ausgaben bleiben, wenn
    /// das Update ein neues bekommt, und umgekehrt.
    @discardableResult
    public func write(_ image: CGImage, for recipe: TopicCoverRecipe) throws -> StoredTopicCover {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let square = Self.squared(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { throw StoreError.encodingFailed }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.encodingFailed }

        let key = recipe.key
        let url = directory.appendingPathComponent(Self.prefix(for: key) + recipe.digest + ".png")
        try (data as Data).write(to: url, options: .atomic)
        // Alle älteren Bilder desselben Besitzers, bei einer Ausgabe auch die
        // zu einer früheren Menge von Stellen.
        for other in files(for: key.owner) where other.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
        return StoredTopicCover(feedID: recipe.feedID, editionID: recipe.editionID, segments: recipe.segments,
                                digest: recipe.digest, url: url, createdAt: Date())
    }

    /// Übernimmt das Ergebnis des Systemdialogs. Die Datei dort ist
    /// kurzlebig und wird deshalb sofort gelesen.
    @discardableResult
    public func adopt(fileAt url: URL, for recipe: TopicCoverRecipe) throws -> TopicCover {
        guard let image = Self.loadImage(at: url) else { throw StoreError.unreadable }
        let stored = try write(image, for: recipe)
        return TopicCover(stored: stored, image: Self.squared(image))
    }

    /// Entfernt alle Bilder eines Updates, auch die seiner Ausgaben.
    public func remove(_ feedID: SmartFeedID) {
        let prefix = Self.prefix(for: TopicCoverKey(feedID: feedID))
        for url in pngFiles() where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Entfernt das Bild einer Ausgabe, zu jeder Menge von Stellen.
    public func remove(_ key: TopicCoverKey) {
        guard key.editionID != nil else { return remove(key.feedID) }
        for url in files(for: key.owner) { try? FileManager.default.removeItem(at: url) }
    }

    /// Entfernt die Bilder aller Updates außer den genannten. Ein Update,
    /// das auf einem anderen Gerät gelöscht wurde, fehlt hier nur in der
    /// Liste, und ohne diesen Abgleich bliebe sein Bild für immer liegen.
    /// Die Bilder seiner Ausgaben gehen mit.
    public func removeAll(except kept: Set<SmartFeedID>) {
        let prefixes = kept.map { Self.prefix(for: TopicCoverKey(feedID: $0)) }
        for url in pngFiles() where url.lastPathComponent.hasPrefix("cover-") {
            let name = url.lastPathComponent
            guard !prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Entfernt die Bilder aller Ausgaben außer den genannten. Eine
    /// Ausgabe verschwindet auch, wenn ihre Folgen gelöscht werden oder ein
    /// anderes Gerät sie löscht. Die Cover der Updates bleiben unberührt.
    ///
    /// Mit Stellen genannt, bleibt nur das Bild zu genau diesen Stellen. Das
    /// Bild zu einer früheren Menge geht, etwa wenn ein anderes Gerät Stellen
    /// aus der Ausgabe genommen hat. Ein Bild aus der Zeit vor 0.13 wird
    /// vorher übernommen, sonst ginge beim ersten Start jedes verloren.
    public func removeEditionCovers(except kept: Set<TopicCoverKey>) {
        let keptEditions = kept.filter { $0.editionID != nil }
        adoptLegacyEditionCovers(for: keptEditions)
        let names = Set(keptEditions.map { Self.prefix(for: $0) })
        for url in pngFiles() where url.lastPathComponent.contains(Self.editionMarker) {
            let name = url.lastPathComponent
            guard !names.contains(where: { name.hasPrefix($0) }) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Übernimmt die Bilder aus der Zeit vor 0.13 für die genannten
    /// Ausgaben, mit einem Blick ins Verzeichnis.
    private func adoptLegacyEditionCovers(for keys: Set<TopicCoverKey>) {
        let files = pngFiles().filter { $0.lastPathComponent.contains(Self.editionMarker) }
        guard !files.isEmpty else { return }
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        for key in keys where key.segments != nil {
            let current = Self.prefix(for: key)
            guard !names.contains(where: { $0.hasPrefix(current) }) else { continue }
            let ownerPrefix = Self.prefix(for: key.owner)
            let owned = files.filter { $0.lastPathComponent.hasPrefix(ownerPrefix) }
            guard let legacy = Self.newest(in: owned, key: key.owner) else { continue }
            _ = adopt(legacy, as: key)
        }
    }

    /// Erzeugt ein Bild mit Image Playground und legt es ab.
    ///
    /// Mit `scheduler` wartet das Bild auf die eine Stelle für Apple
    /// Intelligence, als Art `.cover` mit `priority`. Wird es dort für eine
    /// Anfrage eines Menschen verdrängt, beginnt es danach von vorn. Ohne
    /// läuft es sofort, etwa in Tests oder bevor die App ihre Stufe
    /// „Ausgaben“ angelegt hat.
    public func generate(
        for recipe: TopicCoverRecipe, scheduler: (any AIScheduling)? = nil, priority: AIWorkPriority = .background
    ) async throws -> TopicCover {
        let image: CGImage
        if let scheduler {
            image = try await scheduler.run(.cover, priority: priority) {
                try await TopicCoverGenerator.makeImage(for: recipe)
            }
        } else {
            image = try await TopicCoverGenerator.makeImage(for: recipe)
        }
        let stored = try write(image, for: recipe)
        return TopicCover(stored: stored, image: Self.squared(image))
    }

    /// Liest ein Bild und dekodiert es gleich, damit das nicht erst beim
    /// Zeichnen auf dem Hauptthread passiert.
    public static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Schneidet die Mitte quadratisch aus. Ein Cover ist quadratisch,
    /// auch am Sperrbildschirm.
    static func squared(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        guard image.width != image.height, side > 0 else { return image }
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                          width: side, height: side)
        return image.cropping(to: rect) ?? image
    }

    static let editionMarker = "-edition_"

    /// Der Anfang des Dateinamens. Beim Update folgt direkt der
    /// Fingerabdruck, bei einer Ausgabe erst ihre Kennung und, falls
    /// bekannt, der Fingerabdruck ihrer Stellen. Der Anfang ohne Stellen ist
    /// damit auch der Anfang jeder Fassung mit Stellen.
    static func prefix(for key: TopicCoverKey) -> String {
        let safe = key.feedID.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? StableDigest.hex(of: key.feedID.rawValue)
        guard let edition = key.editionID else { return "cover-\(safe)-" }
        let editionPart = String(StableDigest.hex(of: edition.rawValue).prefix(20))
        guard let segments = key.segments else { return "cover-\(safe)\(editionMarker)\(editionPart)_" }
        return "cover-\(safe)\(editionMarker)\(editionPart)_\(segments)_"
    }

    static func prefix(for feedID: SmartFeedID) -> String { prefix(for: TopicCoverKey(feedID: feedID)) }

    /// Die Bilder zu diesem Schlüssel. Beim Update nicht die seiner
    /// Ausgaben, bei einer Ausgabe ohne Stellen alle ihre Fassungen.
    private func files(for key: TopicCoverKey) -> [URL] {
        let prefix = Self.prefix(for: key)
        return pngFiles().filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { return false }
            return key.editionID != nil || !name.contains(Self.editionMarker)
        }
    }

    private func pngFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.pathExtension == "png" }
    }
}

/// Ein Bildcover mit seinem dekodierten Bild.
public struct TopicCover: Sendable {
    public let stored: StoredTopicCover
    public let image: CGImage

    public init(stored: StoredTopicCover, image: CGImage) {
        self.stored = stored; self.image = image
    }
}

// MARK: - Erzeugung

/// Die einzige Stelle, die `ImageCreator` kennt.
public enum TopicCoverGenerator {

    /// Wie ein Bild entstehen kann.
    public enum Availability: Sendable, Equatable {
        /// Noch nicht geprüft.
        case unknown
        /// Die App erzeugt Bilder selbst.
        case available
        /// Nur über den Systemdialog von Image Playground.
        case dialogOnly
        /// Gar nicht: Gerät, Region oder Apple Intelligence aus.
        case unavailable
    }

    public enum Failure: Error, Sendable, Equatable {
        /// Image Playground steht nicht bereit.
        case unavailable
        /// Die App war nicht im Vordergrund. Später erneut versuchen.
        case notInForeground
        /// Abgebrochen, etwa vom System.
        case cancelled
        /// Kein Bild entstanden, auch nicht im zweiten Versuch.
        case failed
    }

    /// Kann der Systemdialog von Image Playground erscheinen?
    @MainActor public static var isDialogAvailable: Bool {
        #if canImport(ImagePlayground)
        ImagePlaygroundViewController.isAvailable
        #else
        false
        #endif
    }

    /// Erzeugt ein Bild. Wirft `Failure`, nie einen fremden Fehler.
    public static func makeImage(for recipe: TopicCoverRecipe) async throws -> CGImage {
        #if canImport(ImagePlayground)
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            throw failure(from: error)
        }
        guard let style = preferredStyle(in: creator.availableStyles) else { throw Failure.unavailable }
        for concepts in recipe.attempts {
            do {
                if let image = try await firstImage(from: creator, concepts: concepts, style: style) {
                    return image
                }
            } catch {
                let failure = failure(from: error)
                // Nur ein inhaltliches Scheitern lohnt den zweiten Versuch.
                guard failure == .failed else { throw failure }
            }
        }
        throw Failure.failed
        #else
        throw Failure.unavailable
        #endif
    }

    #if canImport(ImagePlayground)
    /// Ein Stil für alle Updates, damit die Liste wie aus einem Guss
    /// aussieht. Nie `externalProvider`: nur Apple Intelligence.
    static func preferredStyle(in available: [ImagePlaygroundStyle]) -> ImagePlaygroundStyle? {
        [ImagePlaygroundStyle.illustration, .animation, .sketch].first { available.contains($0) }
    }

    private static func firstImage(
        from creator: ImageCreator, concepts: [String], style: ImagePlaygroundStyle
    ) async throws -> CGImage? {
        let concepts = concepts.map { ImagePlaygroundConcept.text($0) }
        var options = ImagePlaygroundOptions()
        // Keine Gesichter aus der Fotomediathek: ein Themencover braucht sie nicht.
        options.personalization = .disabled
        for try await created in creator.images(for: concepts, style: style, options: options, limit: 1) {
            return created.cgImage
        }
        return nil
    }

    private static func failure(from error: any Error) -> Failure {
        if error is CancellationError { return .cancelled }
        guard let error = error as? ImageCreator.Error else { return .failed }
        switch error {
        case .notSupported, .unavailable: return .unavailable
        case .backgroundCreationForbidden: return .notInForeground
        case .creationCancelled: return .cancelled
        default: return .failed
        }
    }
    #endif
}

//
//  WidgetSnapshot.swift
//  PodcastAIWidgetData
//
//  Was das Widget „Was ist neu“ zeigen darf: Zahlen und Titel, sonst
//  nichts. Kein Satz aus einem Transkript, keine Aussage, kein Zitat. Die
//  Datei liegt im Ordner der App Group, den auch eine Erweiterung lesen
//  kann, und ein Widget steht auf dem Sperrbildschirm.
//
//  Ältere und neuere Fassungen der App lesen dieselbe Datei. Fehlt ein
//  Feld, gilt es als leer. `trendingTags` füllt die App, sobald sie
//  „Angesagt“ gerechnet hat; bis dahin zeigt das Widget nichts dafür.
//

import Foundation

public struct WidgetSnapshot: Codable, Sendable, Hashable {

    /// Fassung des Formats. Steigt nur, wenn sich die Bedeutung eines
    /// Feldes ändert; ein neues Feld braucht keine neue Fassung.
    public static let currentFormat = 1

    /// So viele Tags zeigt das Widget höchstens.
    public static let maximumTags = 3

    /// Ein Tag mit einer Zahl.
    public struct TagCount: Codable, Sendable, Hashable, Identifiable {
        /// Die Kennung des Tags, für den Link auf seine Seite.
        public let tagID: String
        public let label: String
        public let count: Int

        public init(tagID: String, label: String, count: Int) {
            self.tagID = tagID; self.label = label; self.count = count
        }

        public var id: String { tagID }
    }

    /// Die neueste Ausgabe eines Themen-Updates.
    public struct Edition: Codable, Sendable, Hashable {
        public let id: String
        public let title: String
        /// Der Name des Themen-Updates.
        public let feedTitle: String
        public let publishedAt: Date

        public init(id: String, title: String, feedTitle: String, publishedAt: Date) {
            self.id = id; self.title = title; self.feedTitle = feedTitle; self.publishedAt = publishedAt
        }
    }

    public var format: Int
    public var generatedAt: Date
    /// Neue Aussagen je gefolgtem Tag, die meisten zuerst, höchstens drei.
    public var newStatements: [TagCount]
    public var latestEdition: Edition?
    /// Angesagte Tags. Leer, solange die App keine Trends zählt.
    public var trendingTags: [TagCount]

    public init(
        format: Int = WidgetSnapshot.currentFormat, generatedAt: Date,
        newStatements: [TagCount] = [], latestEdition: Edition? = nil, trendingTags: [TagCount] = []
    ) {
        self.format = format; self.generatedAt = generatedAt
        self.newStatements = newStatements; self.latestEdition = latestEdition
        self.trendingTags = trendingTags
    }

    /// Nichts zu zeigen.
    public var isEmpty: Bool { newStatements.isEmpty && latestEdition == nil && trendingTags.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case format, generatedAt, newStatements, latestEdition, trendingTags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 1
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        // Mehr als drei zeigt das Widget nie; was darüber hinausgeht, bleibt draußen.
        newStatements = Array((try container.decodeIfPresent([TagCount].self, forKey: .newStatements) ?? [])
            .prefix(Self.maximumTags))
        latestEdition = try container.decodeIfPresent(Edition.self, forKey: .latestEdition)
        trendingTags = Array((try container.decodeIfPresent([TagCount].self, forKey: .trendingTags) ?? [])
            .prefix(Self.maximumTags))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(newStatements, forKey: .newStatements)
        try container.encodeIfPresent(latestEdition, forKey: .latestEdition)
        try container.encode(trendingTags, forKey: .trendingTags)
    }
}

// MARK: - Zusammenstellen

extension WidgetSnapshot {

    /// Stellt den Schnappschuss aus dem zusammen, was die App schon weiß.
    ///
    /// - Parameters:
    ///   - newStatements: neue Aussagen je Tag, wie sie der Kopf des Tabs
    ///     „Themen-Updates“ zeigt.
    ///   - followedTagIDs: Tags, denen jemand folgt. Nur sie zählen.
    ///   - editions: alle Ausgaben; die neueste bleibt.
    ///   - trendingTags: angesagte Tags in ihrer Reihenfolge, leer ohne Trends.
    public static func whatsNew(
        newStatements: [TagCount], followedTagIDs: Set<String>, editions: [Edition],
        trendingTags: [TagCount] = [], generatedAt: Date = Date()
    ) -> WidgetSnapshot {
        let tags = newStatements
            .filter { $0.count > 0 && followedTagIDs.contains($0.tagID) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        let latest = editions.max {
            $0.publishedAt != $1.publishedAt ? $0.publishedAt < $1.publishedAt : $0.id < $1.id
        }
        return WidgetSnapshot(
            generatedAt: generatedAt,
            newStatements: Array(tags.prefix(maximumTags)),
            latestEdition: latest,
            trendingTags: Array(trendingTags.prefix(maximumTags)))
    }
}

// MARK: - Vergleichen

extension WidgetSnapshot {

    /// Derselbe Inhalt, unabhängig davon, wann er entstanden ist.
    public func hasSameContent(as other: WidgetSnapshot) -> Bool {
        format == other.format && newStatements == other.newStatements
            && latestEdition == other.latestEdition && trendingTags == other.trendingTags
    }

    /// Nimmt dieser Schnappschuss etwas zurück, was `previous` gezeigt hat?
    ///
    /// Ja, wenn die gezeigte Ausgabe nicht mehr genau so dasteht, ein Tag
    /// herausfällt, anders heißt oder eine kleinere Zahl trägt. So etwas
    /// folgt aus „Folge löschen“, „Abbestellen“ oder dem Löschen eines
    /// Updates und kommt sofort ins Widget (Regel 5). Was nur dazukommt,
    /// darf warten.
    ///
    /// Die Ausgabe zählt bei jeder Änderung, auch wenn eine neuere die
    /// gezeigte ablöst. Der Schnappschuss kennt nur die neueste Ausgabe und
    /// kann nicht sagen, ob die gezeigte noch existiert: Wartete eine neue
    /// Ausgabe und wird die gezeigte gelöscht, stünde deren Titel sonst
    /// weiter in der Datei. Eine neue Ausgabe kommt höchstens alle paar
    /// Stunden, sofort zu schreiben kostet also nichts.
    public func withdraws(from previous: WidgetSnapshot) -> Bool {
        if let old = previous.latestEdition, latestEdition != old { return true }
        return Self.withdraws(previous.newStatements, in: newStatements)
            || Self.withdraws(previous.trendingTags, in: trendingTags)
    }

    private static func withdraws(_ old: [TagCount], in new: [TagCount]) -> Bool {
        let current = Dictionary(new.map { ($0.tagID, $0) }, uniquingKeysWith: { first, _ in first })
        return old.contains { entry in
            guard let now = current[entry.tagID] else { return true }
            return now.label != entry.label || now.count < entry.count
        }
    }
}

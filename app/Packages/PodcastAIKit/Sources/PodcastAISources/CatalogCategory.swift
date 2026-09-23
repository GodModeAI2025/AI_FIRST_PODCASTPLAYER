//
//  CatalogCategory.swift
//  PodcastAISources
//
//  Die Kategorien des Katalogs: die 19 obersten Podcast-Rubriken von
//  Apple Podcasts, mit Apples Kennungen und Apples Namen auf Deutsch und
//  Englisch. Jede Kategorie öffnet die Charts ihrer Rubrik.
//
//  Kennungen und Namen stammen aus Apples Rubrikenbaum
//  (`itunes.apple.com/WebObjects/MZStoreServices.woa/ws/genres?id=26`),
//  einmal beim Entwickeln abgefragt, für die Namen auch mit `cc=de`. Die
//  App fragt den Baum nicht selbst ab: er ändert sich kaum, und so steht
//  die Liste ohne Netz da.
//

import Foundation

public enum CatalogCategory: String, CaseIterable, Sendable, Identifiable, Hashable {
    // Reihenfolge der Kacheln im Katalog: was oft gesucht wird, zuerst.
    case news, comedy, society, trueCrime, sports, business, health, education, science
    case technology, history, arts, kidsFamily, religion, leisure, music, tvFilm, fiction, politics

    public var id: String { rawValue }

    /// Die Rubrik „Podcasts“ selbst. Sie steht in jeder Liste von
    /// Kennungen und sagt nichts über den Inhalt.
    public static let podcastsGenreID = 26

    /// Farben aus dem System, damit die Kacheln im hellen und dunklen
    /// Modus stimmen. Die App übersetzt sie in `Color`.
    public enum Tint: String, Sendable {
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
    }

    /// Apples Kennung der Rubrik, für die Charts einer Kategorie.
    public var genreID: Int {
        switch self {
        case .arts: 1301
        case .business: 1321
        case .comedy: 1303
        case .education: 1304
        case .fiction: 1483
        case .politics: 1511
        case .health: 1512
        case .history: 1487
        case .kidsFamily: 1305
        case .leisure: 1502
        case .music: 1310
        case .news: 1489
        case .religion: 1314
        case .science: 1533
        case .society: 1324
        case .sports: 1545
        case .tvFilm: 1309
        case .technology: 1318
        case .trueCrime: 1488
        }
    }

    /// Apples Unterrubriken, etwa 1527 „Politik“ unter den Nachrichten.
    /// Ein Podcast trägt oft nur sie als erste Kennung.
    public var subgenreIDs: [Int] {
        switch self {
        case .arts: [1306, 1402, 1405, 1406, 1459, 1482]
        case .business: [1410, 1412, 1491, 1492, 1493, 1494]
        case .comedy: [1495, 1496, 1497]
        case .education: [1498, 1499, 1500, 1501]
        case .fiction: [1484, 1485, 1486]
        case .politics: []
        case .health: [1513, 1514, 1515, 1516, 1517, 1518]
        case .history: []
        case .kidsFamily: [1519, 1520, 1521, 1522]
        case .leisure: [1503, 1504, 1505, 1506, 1507, 1508, 1509, 1510]
        case .music: [1523, 1524, 1525]
        case .news: [1490, 1526, 1527, 1528, 1529, 1530, 1531]
        case .religion: [1438, 1439, 1440, 1441, 1444, 1463, 1532]
        case .science: [1534, 1535, 1536, 1537, 1538, 1539, 1540, 1541, 1542]
        case .society: [1302, 1320, 1443, 1543, 1544]
        case .sports: [1546, 1547, 1548, 1549, 1550, 1551, 1552, 1553, 1554, 1555, 1556, 1557, 1558, 1559, 1560]
        case .tvFilm: [1561, 1562, 1563, 1564, 1565]
        case .technology: []
        case .trueCrime: []
        }
    }

    /// Apples Namen der Rubriken, in der Sprache der App.
    public var title: String {
        switch self {
        case .news: String(localized: "Nachrichten", bundle: .module)
        case .comedy: String(localized: "Comedy", bundle: .module)
        case .society: String(localized: "Gesellschaft und Kultur", bundle: .module)
        case .trueCrime: String(localized: "Wahre Kriminalfälle", bundle: .module)
        case .sports: String(localized: "Sport", bundle: .module)
        case .business: String(localized: "Wirtschaft", bundle: .module)
        case .health: String(localized: "Gesundheit und Fitness", bundle: .module)
        case .education: String(localized: "Bildung", bundle: .module)
        case .science: String(localized: "Wissenschaft", bundle: .module)
        case .technology: String(localized: "Technologie", bundle: .module)
        case .history: String(localized: "Geschichte", bundle: .module)
        case .arts: String(localized: "Kunst", bundle: .module)
        case .kidsFamily: String(localized: "Kinder und Familie", bundle: .module)
        case .religion: String(localized: "Religion und Spiritualität", bundle: .module)
        case .leisure: String(localized: "Freizeit", bundle: .module)
        case .music: String(localized: "Musik", bundle: .module)
        case .tvFilm: String(localized: "TV und Film", bundle: .module)
        case .fiction: String(localized: "Fiktion", bundle: .module)
        case .politics: String(localized: "Regierung", bundle: .module)
        }
    }

    /// SF Symbol, geprüft gegen die Symbolliste von iOS 27 und macOS 27
    /// (`name_availability.plist` im Simulator und im System) und im Test
    /// gegen `NSImage(systemSymbolName:)`.
    public var symbol: String {
        switch self {
        case .news: "newspaper"
        case .comedy: "theatermasks"
        case .society: "person.2"
        case .trueCrime: "touchid"
        case .sports: "sportscourt"
        case .business: "briefcase"
        case .health: "heart"
        case .education: "graduationcap"
        case .science: "atom"
        case .technology: "cpu"
        case .history: "scroll"
        case .arts: "paintpalette"
        case .kidsFamily: "figure.2.and.child.holdinghands"
        case .religion: "moon.stars"
        case .leisure: "gamecontroller"
        case .music: "music.note"
        case .tvFilm: "popcorn"
        case .fiction: "book.closed"
        case .politics: "building.columns"
        }
    }

    public var tint: Tint {
        switch self {
        case .news: .red
        case .comedy: .orange
        case .society: .teal
        case .trueCrime: .gray
        case .sports: .green
        case .business: .blue
        case .health: .pink
        case .education: .cyan
        case .science: .indigo
        case .technology: .blue
        case .history: .brown
        case .arts: .pink
        case .kidsFamily: .yellow
        case .religion: .purple
        case .leisure: .mint
        case .music: .red
        case .tvFilm: .indigo
        case .fiction: .purple
        case .politics: .gray
        }
    }

    /// Die Kategorie zu einer Kennung Apples, egal ob Rubrik oder
    /// Unterrubrik. `nil` für „Podcasts“ und Unbekanntes.
    public init?(genreID: Int) {
        guard let category = Self.byGenreID[genreID] else { return nil }
        self = category
    }

    private static let byGenreID: [Int: CatalogCategory] = {
        var map: [Int: CatalogCategory] = [:]
        for category in allCases {
            map[category.genreID] = category
            for id in category.subgenreIDs { map[id] = category }
        }
        return map
    }()

    /// Die Kategorien eines Podcasts in der Reihenfolge seiner Kennungen.
    /// Apple nennt die wichtigste zuerst.
    public static func categories(for genreIDs: [Int]) -> [CatalogCategory] {
        var seen = Set<CatalogCategory>()
        return genreIDs.compactMap(CatalogCategory.init(genreID:)).filter { seen.insert($0).inserted }
    }
}

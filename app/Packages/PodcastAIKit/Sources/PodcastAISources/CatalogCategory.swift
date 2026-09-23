//
//  CatalogCategory.swift
//  PodcastAISources
//
//  Die Rubriken des Katalogs.
//
//  Podcast Index kennt 112 Kategorien als flache Liste einzelner Wörter,
//  nur auf Englisch. Apples zusammengesetzte Kategorien sind darin zerlegt:
//  „TV & Film > TV Reviews“ wird zu 104 TV, 105 Film und 107 Reviews, und
//  ein Feed trägt Ober- und Unterbegriff zugleich. Die App fasst das zu 19
//  Rubriken nach Apples Vorbild zusammen, mit eigenen Namen auf Deutsch und
//  Englisch.
//
//  Zugeordnet wird über die Kennungen, nicht über die Namen: die Liste
//  schreibt „TV“, manche Antworten „Tv“.
//

import Foundation

public enum CatalogCategory: String, CaseIterable, Sendable, Identifiable, Hashable {
    // Reihenfolge der Kacheln im Katalog: was oft gesucht wird, zuerst.
    case news, comedy, society, trueCrime, sports, business, health, education, science
    case technology, history, arts, kidsFamily, religion, leisure, music, tvFilm, fiction, politics

    public var id: String { rawValue }

    /// Farben aus dem System, damit die Kacheln im hellen und dunklen
    /// Modus stimmen. Die App übersetzt sie in `Color`.
    public enum Tint: String, Sendable {
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
    }

    public var title: String {
        switch self {
        case .news: String(localized: "Nachrichten", bundle: .module)
        case .comedy: String(localized: "Comedy", bundle: .module)
        case .society: String(localized: "Gesellschaft & Kultur", bundle: .module)
        case .trueCrime: String(localized: "True Crime", bundle: .module)
        case .sports: String(localized: "Sport", bundle: .module)
        case .business: String(localized: "Wirtschaft", bundle: .module)
        case .health: String(localized: "Gesundheit & Fitness", bundle: .module)
        case .education: String(localized: "Bildung", bundle: .module)
        case .science: String(localized: "Wissenschaft", bundle: .module)
        case .technology: String(localized: "Technik", bundle: .module)
        case .history: String(localized: "Geschichte", bundle: .module)
        case .arts: String(localized: "Kunst", bundle: .module)
        case .kidsFamily: String(localized: "Kinder & Familie", bundle: .module)
        case .religion: String(localized: "Religion & Spiritualität", bundle: .module)
        case .leisure: String(localized: "Freizeit", bundle: .module)
        case .music: String(localized: "Musik", bundle: .module)
        case .tvFilm: String(localized: "TV & Film", bundle: .module)
        case .fiction: String(localized: "Fiktion", bundle: .module)
        case .politics: String(localized: "Politik & Staat", bundle: .module)
        }
    }

    /// SF Symbol, geprüft gegen die Symbolliste von iOS 26 und macOS 26.
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

    /// Die Oberbegriffe. Sie entscheiden, wohin ein Feed gehört.
    public var primaryIDs: [Int] {
        switch self {
        case .arts: [1]
        case .business: [9]
        case .comedy: [16]
        case .education: [20]
        case .fiction: [26]
        case .history: [28]
        case .health: [29, 30]
        case .kidsFamily: [36, 37]
        case .leisure: [42]
        case .music: [53]
        case .news: [55]
        case .politics: [58, 59]
        case .religion: [65, 66]
        case .science: [67]
        case .society: [77, 78]
        case .sports: [86]
        case .technology: [102]
        case .trueCrime: [103]
        case .tvFilm: [104, 105]
        }
    }

    /// Unterbegriffe. Sie zählen nur, wenn kein Oberbegriff passt: Wörter
    /// wie „Interviews“ oder „Commentary“ kommen unter mehreren Rubriken vor.
    public var secondaryIDs: [Int] {
        switch self {
        case .arts: [2, 3, 4, 5, 6, 7, 8]
        case .business: [10, 11, 12, 13, 14, 15, 112]
        case .comedy: [17, 18, 19]
        case .education: [21, 22, 23, 24, 25]
        case .fiction: [27]
        case .history: []
        case .health: [31, 32, 33, 34, 35]
        case .kidsFamily: [38, 39, 40, 41]
        case .leisure: [43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 110, 111]
        case .music: []
        case .news: [54, 56, 57]
        case .politics: []
        case .religion: [60, 61, 62, 63, 64]
        case .science: [68, 69, 70, 71, 72, 73, 74, 75, 76, 108, 109]
        case .society: [79, 80, 81, 82, 83, 84, 85]
        case .sports: [87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101]
        case .technology: []
        case .trueCrime: []
        case .tvFilm: [106, 107]
        }
    }

    /// Alle Kennungen der Rubrik, für `cat=` bei den Trends.
    public var podcastIndexIDs: [Int] { primaryIDs + secondaryIDs }

    /// Vorrang, wenn ein Feed zu mehreren Rubriken passt und nur ein Symbol
    /// zeigen soll: das Genauere vor dem Allgemeinen.
    static let precedence: [CatalogCategory] = [
        .trueCrime, .comedy, .fiction, .kidsFamily, .religion, .sports, .tvFilm, .music,
        .history, .news, .politics, .business, .technology, .science, .health, .education,
        .arts, .leisure, .society,
    ]

    /// Die eine Rubrik, unter der ein Feed erscheint, oder `nil`.
    public static func primary(for ids: [Int]) -> CatalogCategory? {
        categories(for: ids).first
    }

    /// Alle Rubriken eines Feeds, die wichtigste zuerst. Oberbegriffe
    /// entscheiden; nur wenn keiner passt, zählen die Unterbegriffe.
    public static func categories(for ids: [Int]) -> [CatalogCategory] {
        let set = Set(ids)
        let byPrimary = precedence.filter { !set.isDisjoint(with: $0.primaryIDs) }
        if !byPrimary.isEmpty { return byPrimary }
        return precedence.filter { !set.isDisjoint(with: $0.secondaryIDs) }
    }
}

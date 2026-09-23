//
//  Mention.swift
//  PodcastAIKnowledge
//
//  Was in einer Folge genannt wird: Links, Termine, Adressen,
//  Telefonnummern, E-Mail-Adressen, Personen, Organisationen und Orte.
//
//  Eine Nennung ist kein Beleg im Sinne des Chats und keine Aussage. Sie
//  sagt nur: dieser Wert kommt vor, hier und hier. Erkannt wird sie ohne
//  Sprachmodell (``MentionExtractor``), und jede Fundstelle nennt, woher
//  sie stammt: aus den Shownotes oder aus dem Transkript mit Zeitmarke.
//

import Foundation
import PodcastAICore

public struct Mention: Hashable, Codable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable, CaseIterable, Comparable {
        case link, date, address, phone, email, person, organization, place

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.order < rhs.order }

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// Personen, Organisationen und Orte. Sie kommen aus der
        /// Namenserkennung und tragen keine Aktion wie Öffnen oder Anrufen.
        public var isName: Bool { self == .person || self == .organization || self == .place }

        /// Überschrift der Gruppe.
        public var label: String {
            switch self {
            case .link: String(localized: "Links", bundle: .module)
            case .date: String(localized: "Termine", bundle: .module)
            case .address: String(localized: "Adressen", bundle: .module)
            case .phone: String(localized: "Telefonnummern", bundle: .module)
            case .email: String(localized: "E-Mail", bundle: .module)
            case .person: String(localized: "Personen", bundle: .module)
            case .organization: String(localized: "Organisationen", bundle: .module)
            case .place: String(localized: "Orte", bundle: .module)
            }
        }

        /// „1 Link“, „3 Termine“. Einzahl und Mehrzahl kommen aus dem Katalog.
        public func counted(_ count: Int) -> String {
            switch self {
            case .link: String(localized: "\(count) Links", bundle: .module)
            case .date: String(localized: "\(count) Termine", bundle: .module)
            case .address: String(localized: "\(count) Adressen", bundle: .module)
            case .phone: String(localized: "\(count) Telefonnummern", bundle: .module)
            case .email: String(localized: "\(count) E-Mail-Adressen", bundle: .module)
            case .person: String(localized: "\(count) Personen", bundle: .module)
            case .organization: String(localized: "\(count) Organisationen", bundle: .module)
            case .place: String(localized: "\(count) Orte", bundle: .module)
            }
        }

        public var symbol: String {
            switch self {
            case .link: "link"
            case .date: "calendar"
            case .address: "mappin.and.ellipse"
            case .phone: "phone"
            case .email: "envelope"
            case .person: "person"
            case .organization: "building.2"
            case .place: "map"
            }
        }
    }

    /// Eine Stelle, an der der Wert vorkommt.
    public struct Occurrence: Hashable, Codable, Sendable {
        public enum Origin: String, Codable, Sendable {
            case shownotes, transcript
        }

        public let origin: Origin
        /// Nur im Transkript: der Anfang des Satzes, in dem der Wert fällt.
        public let time: MediaTime?
        /// Der Satz oder die Zeile drumherum, gekürzt. Originaltext.
        public let context: String

        public init(origin: Origin, time: MediaTime?, context: String) {
            self.origin = origin
            self.time = time
            self.context = context
        }
    }

    public let kind: Kind
    /// Schlüssel zum Zusammenführen: bei Links Host ohne „www.“ und Pfad,
    /// bei Terminen der Tag, bei Namen die Kleinschreibung.
    public let normalized: String
    /// So, wie der Wert zuerst vorkam.
    public let display: String
    /// Link, `mailto:`, `tel:` oder die Suche in Karten.
    public let url: URL?
    /// Nur bei Terminen: der aufgelöste Zeitpunkt. Ohne Uhrzeit der Tagesbeginn.
    public internal(set) var date: Date?
    public internal(set) var hasTime: Bool
    /// Ein Termin ohne Jahr oder ohne Tag. Das Jahr kommt dann aus dem
    /// Erscheinungsdatum der Folge, der Tag ist der Monatserste.
    public internal(set) var isVague: Bool
    public internal(set) var occurrences: [Occurrence]

    public init(kind: Kind, normalized: String, display: String, url: URL? = nil,
                date: Date? = nil, hasTime: Bool = false, isVague: Bool = false,
                occurrences: [Occurrence]) {
        self.kind = kind; self.normalized = normalized; self.display = display
        self.url = url; self.date = date; self.hasTime = hasTime; self.isVague = isVague
        self.occurrences = occurrences
    }

    public var id: String { "\(kind.rawValue)|\(normalized)" }

    /// Die früheste Stelle im Transkript.
    public var firstTime: MediaTime? { occurrences.compactMap(\.time).min() }

    public var inShownotes: Bool { occurrences.contains { $0.origin == .shownotes } }
    public var inTranscript: Bool { occurrences.contains { $0.origin == .transcript } }

    /// Was in der Liste steht. Ein Termin als Datum in der Sprache der App,
    /// alles andere so, wie es genannt wurde.
    public var title: String {
        guard kind == .date, let date else { return display }
        return date.formatted(date: .long, time: hasTime ? .shortened : .omitted)
    }
}

// MARK: - Zusammenfassung

public enum MentionSummary {

    /// Wie viele Werte je Art, in der festen Reihenfolge der Arten.
    public static func counts(_ mentions: [Mention]) -> [(kind: Mention.Kind, count: Int)] {
        Mention.Kind.allCases.compactMap { kind in
            let count = mentions.count { $0.kind == kind }
            return count > 0 ? (kind, count) : nil
        }
    }

    /// „3 Links, 2 Termine, 1 Adresse“. `nil`, wenn nichts davon vorkommt.
    public static func text(_ mentions: [Mention], kinds: Set<Mention.Kind> = Set(Mention.Kind.allCases)) -> String? {
        let parts = counts(mentions).filter { kinds.contains($0.kind) }.map { $0.kind.counted($0.count) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Kurzer Block für das Sprachmodell, damit es auch bei anderen Fragen
    /// weiß, was genannt wird. Deutsch wie der übrige Kontext für das
    /// Modell, und bewusst knapp: auf dem Gerät ist der Platz klein.
    public static func modelContext(_ mentions: [Mention], limit: Int = 700,
                                    calendar: Calendar = .current) -> String? {
        guard !mentions.isEmpty else { return nil }
        var groups: [String] = []
        for kind in Mention.Kind.allCases {
            let items = mentions.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            let values = items.prefix(6).map { mention -> String in
                var value = kind == .date ? modelDate(mention, calendar: calendar) : mention.display
                if let time = mention.firstTime {
                    value += " (\(time.timecode))"
                } else if mention.inShownotes {
                    value += " (Shownotes)"
                }
                return value
            }
            groups.append("\(modelLabels[kind] ?? kind.rawValue): " + values.joined(separator: ", "))
        }
        let line = "Erwähnt: " + groups.joined(separator: "; ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static let modelLabels: [Mention.Kind: String] = [
        .link: "Links", .date: "Termine", .address: "Adressen", .phone: "Telefonnummern",
        .email: "E-Mail", .person: "Personen", .organization: "Organisationen", .place: "Orte",
    ]

    /// Ein Termin für das Modell, ohne Formatierung der Gerätesprache.
    static func modelDate(_ mention: Mention, calendar: Calendar) -> String {
        guard let date = mention.date else { return mention.display }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var text = String(format: "%02ld.%02ld.%04ld", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
        if mention.hasTime { text += String(format: " %02ld:%02ld", parts.hour ?? 0, parts.minute ?? 0) }
        if mention.isVague { text += " ungefähr, gesagt: „\(mention.display)“" }
        return text
    }
}

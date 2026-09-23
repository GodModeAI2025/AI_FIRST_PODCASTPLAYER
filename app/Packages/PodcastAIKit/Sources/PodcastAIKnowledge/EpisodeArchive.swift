//
//  EpisodeArchive.swift
//  PodcastAIKnowledge
//
//  Ältere Folgen einer Quelle finden und zum Auswerten auswählen.
//
//  Von selbst wertet die App nur die neuesten Folgen aus. Das eigene Thema
//  steckt aber oft in einer alten. Die Folgenliste braucht deshalb eine
//  Suche über Titel und Shownotes, einen Filter auf das noch nicht
//  Ausgewertete und die Reihenfolge „älteste zuerst“. Die Logik dafür liegt
//  hier, ohne Oberfläche und ohne Modell, damit sie sich prüfen lässt.
//

import Foundation
import PodcastAICore

public enum EpisodeArchive {

    // MARK: - Suche

    /// Der durchsuchbare Text einer Folge: Titel, Beschreibung und Shownotes
    /// ohne HTML, schon vereinheitlicht.
    ///
    /// Das Entfernen der Tags kostet bei langen Shownotes spürbar Zeit. Die
    /// Liste berechnet den Text deshalb einmal je Folge im Hintergrund und
    /// vergleicht danach nur noch.
    public static func searchableText(of episode: Episode) -> String {
        var parts = [episode.title]
        if let summary = episode.summary, !summary.isEmpty { parts.append(summary) }
        if let notes = episode.shownotesHTML, !notes.isEmpty, notes != episode.summary { parts.append(notes) }
        return normalized(plainText(parts.joined(separator: "\n")))
    }

    /// Der durchsuchbare Text für viele Folgen auf einmal.
    public static func searchIndex(for episodes: [Episode]) -> [EpisodeID: String] {
        var index: [EpisodeID: String] = [:]
        index.reserveCapacity(episodes.count)
        for episode in episodes { index[episode.id] = searchableText(of: episode) }
        return index
    }

    /// Die Suchwörter einer Eingabe. Leer, wenn nichts gesucht wird.
    public static func terms(of query: String) -> [String] {
        normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Enthält der Text jedes Suchwort? Die Reihenfolge der Wörter ist egal,
    /// ein Wortteil genügt: „klima“ findet auch „Klimapolitik“.
    public static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.contains($0) }
    }

    /// Die Folgen, deren Text alle Suchwörter enthält, oder `nil`, wenn
    /// nichts gesucht wird.
    public static func matchingIDs(
        for terms: [String], in index: [(id: EpisodeID, text: String)]
    ) -> Set<EpisodeID>? {
        guard !terms.isEmpty else { return nil }
        return Set(index.lazy.filter { matches($0.text, terms: terms) }.map(\.id))
    }

    /// Klein geschrieben, ohne Akzente und Umlautpunkte. So findet „uber“
    /// auch „Über“, und die Suche hängt nicht an der Schreibweise.
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Text ohne HTML-Tags und mit den gängigen Entitäten aufgelöst.
    static func plainText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var scalars = String.UnicodeScalarView()
        var insideTag = false
        for scalar in html.unicodeScalars {
            if insideTag {
                if scalar == ">" {
                    insideTag = false
                    scalars.append(" ")
                }
            } else if scalar == "<" {
                insideTag = true
            } else {
                scalars.append(scalar)
            }
        }
        var text = String(scalars)
        guard text.contains("&") else { return text }
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return decodeNumericEntities(text)
    }

    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ("&apos;", "'"), ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"),
        ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß"), ("&ndash;", "–"), ("&hellip;", "…"),
        // Zuletzt, damit „&amp;lt;“ nicht zu „<“ wird.
        ("&amp;", "&"),
    ]

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            result += rest[..<start.lowerBound]
            let tail = rest[start.upperBound...]
            guard let end = tail.prefix(8).firstIndex(of: ";") else {
                result += "&#"
                rest = tail
                continue
            }
            let code = tail[..<end]
            let value = code.first == "x" || code.first == "X"
                ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += "&#" + code + ";"
            }
            rest = tail[tail.index(after: end)...]
        }
        return result + rest
    }

    // MARK: - Filter und Reihenfolge

    public struct Options: Equatable, Sendable {
        /// Nur Folgen zeigen, die noch nicht ausgewertet sind.
        public var onlyUnanalyzed: Bool
        /// Älteste zuerst statt neueste zuerst.
        public var oldestFirst: Bool

        public init(onlyUnanalyzed: Bool = false, oldestFirst: Bool = false) {
            self.onlyUnanalyzed = onlyUnanalyzed
            self.oldestFirst = oldestFirst
        }
    }

    /// Die Folgen, wie die Liste sie zeigt.
    ///
    /// - Parameters:
    ///   - episodes: alle Folgen der Quelle, neueste zuerst.
    ///   - analyzed: die schon ausgewerteten.
    ///   - matches: Treffer der Suche, `nil` ohne Suche.
    public static func arrange(
        _ episodes: [Episode], options: Options,
        analyzed: Set<EpisodeID>, matches: Set<EpisodeID>?
    ) -> [Episode] {
        var list = episodes
        if let matches { list = list.filter { matches.contains($0.id) } }
        if options.onlyUnanalyzed { list = list.filter { !analyzed.contains($0.id) } }
        return options.oldestFirst ? oldestFirst(list) : list
    }

    /// Nach Erscheinungsdatum aufsteigend. Folgen ohne Datum stehen am Ende,
    /// wie in der Liste „neueste zuerst“ auch.
    public static func oldestFirst(_ episodes: [Episode]) -> [Episode] {
        episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case let (left?, right?) where left != right: left < right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Kopfzeile

    /// Wofür die App von selbst ein Transkript erstellt.
    public enum Automatic: Equatable, Sendable {
        /// Die neuesten Folgen je Quelle, so viele.
        case newest(Int)
        /// In den Einstellungen abgeschaltet.
        case off
        /// Eingeschaltet, aber das Gerät kann gerade nicht transkribieren.
        case paused
    }

    /// Die Kopfzeile der Folgenliste, etwa „3 von 412 Folgen mit Transkript,
    /// automatisch die 3 neuesten“.
    ///
    /// Gefunden und mit Transkript sind getrennte Zahlen. Nur eine davon zu
    /// nennen würde behaupten, alles sei durchsuchbar.
    ///
    /// Jede Zeile ist ein ganzer Satz im String-Katalog und wird nicht aus
    /// Teilen zusammengesetzt, damit eine Übersetzung die Wortstellung
    /// selbst bestimmen kann.
    public static func coverage(total: Int, analyzed: Int, analyzable: Bool, automatic: Automatic) -> String {
        guard analyzable else {
            return String(AttributedString(
                localized: "^[\(total) Folge](inflect: true), kein Transkript möglich", bundle: .module).characters)
        }
        switch automatic {
        case .newest(let count) where count == 1:
            return String(AttributedString(localized: """
                \(analyzed) von ^[\(total) Folge](inflect: true) mit Transkript, automatisch die neueste
                """, bundle: .module).characters)
        case .newest(let count) where count > 1:
            return String(AttributedString(localized: """
                \(analyzed) von ^[\(total) Folge](inflect: true) mit Transkript, automatisch die \(count) neuesten
                """, bundle: .module).characters)
        case .newest, .off:
            return String(AttributedString(localized: """
                \(analyzed) von ^[\(total) Folge](inflect: true) mit Transkript, keine automatischen Transkripte
                """, bundle: .module).characters)
        case .paused:
            return String(AttributedString(localized: """
                \(analyzed) von ^[\(total) Folge](inflect: true) mit Transkript, automatisch gerade keine
                """, bundle: .module).characters)
        }
    }

    /// Die Zeile über „Transkripte erstellen“: wie viele Folgen und wie viel Ton.
    public static func selectionSummary(_ selected: [Episode]) -> String {
        guard !selected.isEmpty else {
            return String(localized: "Tippe die Folgen an, für die ein Transkript erstellt werden soll.",
                          bundle: .module)
        }
        let count = selected.count
        let durations = selected.compactMap(\.declaredDuration)
        guard !durations.isEmpty else {
            return String(AttributedString(
                localized: "^[\(count) Folge](inflect: true) ausgewählt", bundle: .module).characters)
        }
        let total = durations.reduce(MediaDuration.zero, +).shortDescription
        // Fehlt bei einer Folge die Länge, ist die Summe eine Untergrenze.
        if durations.count == selected.count {
            return String(AttributedString(localized: """
                ^[\(count) Folge](inflect: true) ausgewählt, zusammen \(total) Ton
                """, bundle: .module).characters)
        }
        return String(AttributedString(localized: """
            ^[\(count) Folge](inflect: true) ausgewählt, zusammen mindestens \(total) Ton
            """, bundle: .module).characters)
    }
}

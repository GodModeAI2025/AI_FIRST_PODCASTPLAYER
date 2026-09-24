//
//  TimestampChapters.swift
//  PodcastAISources
//
//  Kapitel aus Zeitmarken in Shownotes und YouTube-Beschreibungen:
//
//      00:00 Intro
//      (12:34) Thema
//      1:02:03 - Titel
//
//  Die Zeiten liest allein dieser Code aus dem Text. Kein Modell schlägt
//  hier etwas vor. Der Text bleibt fremde Daten: er wird nur nach dem
//  Muster „Zeitmarke am Zeilenanfang, danach ein Titel“ durchsucht.
//

import Foundation
import PodcastAICore

public enum TimestampChapters {

    /// Höchstens so viele Kapitel aus einem Text.
    public static let maximumChapters = 200
    /// Längere Titel werden gekürzt.
    static let maximumTitleLength = 120

    /// Liest Kapitel aus Shownotes (HTML oder Text).
    ///
    /// Es zählen nur Zeilen, die mit einer Zeitmarke beginnen. Das erste
    /// Kapitel muss in der ersten Minute liegen, und es braucht mindestens
    /// zwei. Sonst ist es eher eine Liste von Verweisen als eine
    /// Kapitelübersicht. Zeiten jenseits der angegebenen Länge fallen weg.
    public static func parse(_ text: String?, duration: MediaDuration? = nil) -> [Chapter] {
        guard let text, text.contains(":") else { return [] }
        var found: [Chapter] = []
        for line in lines(of: text) {
            guard let chapter = chapter(in: line) else { continue }
            if let duration, chapter.start.milliseconds >= duration.milliseconds { continue }
            found.append(chapter)
            if found.count >= maximumChapters { break }
        }
        // Nach Zeit ordnen, gleiche Startzeiten nur einmal.
        var seen: Set<Int64> = []
        let chapters = found
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.start.milliseconds).inserted }
        guard chapters.count >= 2, let first = chapters.first,
              first.start.milliseconds <= 60_000 else { return [] }
        return chapters
    }

    /// Eine Zeile: optional Aufzählungszeichen oder Klammer, dann die
    /// Zeitmarke, dann ein Trenner und der Titel.
    static func chapter(in rawLine: String) -> Chapter? {
        var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
        // Aufzählungszeichen und öffnende Klammer vor der Zeitmarke.
        while let first = line.first, "-–•*·▶►[(".contains(first) {
            line = line.dropFirst().drop(while: { $0 == " " })
        }
        let stamp = line.prefix { $0.isNumber || $0 == ":" }
        guard stamp.contains(":"), let start = time(String(stamp)) else { return nil }
        var rest = line.dropFirst(stamp.count)
        // Schließende Klammer und Trenner nach der Zeitmarke.
        rest = rest.drop { " )]-–—:|.".contains($0) }
        let title = String(rest).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        // „12:30 Uhr“ ist eine Uhrzeit, kein Kapitel.
        let firstWord = title.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if ["uhr", "h", "am", "pm", "a.m.", "p.m."].contains(firstWord) { return nil }
        let clipped = title.count > maximumTitleLength
            ? String(title.prefix(maximumTitleLength - 1)) + "…" : title
        return Chapter(start: start, title: clipped, provenance: .original)
    }

    /// `M:SS`, `MM:SS`, `H:MM:SS` und `HH:MM:SS`. Minuten und Sekunden
    /// hinter dem ersten Teil sind zweistellig und kleiner als 60.
    static func time(_ raw: String) -> MediaTime? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let head = parts.first, (1...2).contains(head.count),
              parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let numbers = parts.compactMap(Int.init)
        guard numbers.count == parts.count,
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        if parts.count == 2, numbers[0] > 59 { return nil }
        return MediaTime(milliseconds: Int64(seconds) * 1000)
    }

    /// Zerlegt HTML oder Text in Zeilen. Absätze, Zeilenumbrüche und
    /// Listenpunkte werden zu Zeilen, übrige Tags fallen weg.
    static func lines(of text: String) -> [String] {
        var plain = text
        if plain.contains("<") {
            plain = plain.replacingOccurrences(
                of: "<\\s*(br|/p|p|/li|li|/div|div|/h[1-6]|h[1-6])\\b[^>]*>",
                with: "\n", options: [.regularExpression, .caseInsensitive])
            plain = plain.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        }
        plain = decodeEntities(plain)
        return plain.components(separatedBy: .newlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let table = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&#8211;": "–", "&ndash;": "–", "&mdash;": "—",
        ]
        var result = text
        for (entity, value) in table { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}

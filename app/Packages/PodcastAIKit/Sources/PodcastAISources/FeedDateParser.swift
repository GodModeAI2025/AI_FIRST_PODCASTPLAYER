//
//  FeedDateParser.swift
//  PodcastAISources
//
//  Feeds halten sich nicht an eine Datumsnorm. RFC 822 mit und ohne
//  Sekunden, mit Zonenkürzel oder Offset, dazu ISO 8601 aus Atom. Ein
//  falsch gelesenes Datum sortiert eine Folge an die falsche Stelle und
//  lässt alte Inhalte als neu erscheinen — deshalb lieber `nil` als raten.
//

import Foundation

public enum FeedDateParser {

    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm zzz",
        "EEE, dd MMM yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ]

    /// `DateFormatter` ist teuer zu erzeugen; ein Archivlauf liest tausende
    /// Einträge. Die Formatter werden deshalb einmal gebaut.
    private static let formatters: [DateFormatter] = rfc822Formats.map { format in
        let formatter = DateFormatter()
        // Feste Locale: sonst scheitert „Wed“ auf einem deutschen Gerät.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    // ISO8601DateFormatter ist laut Apple threadsicher, aber nicht als
    // Sendable markiert. Die Instanzen werden nach dem Aufbau nur gelesen.
    nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Zonenkürzel, die `DateFormatter` mit fester Locale nicht liest; die
    /// amerikanischen aus RFC 822 kennt er. Feste Offsets, weil CEST immer
    /// +0200 ist: `TimeZone(abbreviation:)` lieferte eine Region, deren
    /// Offset vom Datum abhängt.
    private static let zoneOffsets = [
        "WET": "+0000", "WEST": "+0100", "BST": "+0100",
        "CET": "+0100", "MEZ": "+0100", "CEST": "+0200", "MESZ": "+0200",
        "EET": "+0200", "EEST": "+0300",
    ]

    /// Das Jahr eines RFC-822-Datums, wenn es nur zwei oder drei Ziffern hat:
    /// „Wed, 01 Jan 25 10:00:00 GMT“. Einmal gebaut wie die Formatter; als
    /// Literal im Aufruf übersetzte Swift das Muster für jeden Eintrag neu.
    /// `Regex` ist nicht als Sendable markiert, die Instanz wird nur gelesen.
    nonisolated(unsafe) private static let shortYear = #/^(?:[A-Za-z]+,\s*)?\d{1,2}\s+[A-Za-z]+\s+(\d{2,3})\s/#

    /// Der 1. Januar 100. Davor liegt kein Feed-Datum, nur ein falsch
    /// gelesenes Jahr wie „0025“.
    private static let earliest = iso8601.date(from: "0100-01-01T00:00:00Z") ?? .distantPast

    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let date = iso8601WithFractional.date(from: trimmed) ?? iso8601.date(from: trimmed)
                ?? rfc822Date(from: trimmed) else { return nil }
        return date < earliest ? nil : date
    }

    /// RFC 822 mit dem, was Feeds daraus machen: ein Kommentar hinter der
    /// Zone, europäische Zonenkürzel und Jahre mit zwei oder drei Ziffern.
    private static func rfc822Date(from string: String) -> Date? {
        var text = string
        // „+0100 (CET)“: der Kommentar in Klammern hinter der Zone gehört
        // nicht zum Datum. Steht die Zone nur im Kommentar, bleibt er
        // stehen: lieber kein Datum als eines in der falschen Zone.
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let zoned = text[..<open].trimmingCharacters(in: .whitespaces)
            if zoned.split(separator: " ").last?.first?.isNumber == false { text = zoned }
        }
        if let space = text.lastIndex(of: " "),
           let offset = zoneOffsets[text[text.index(after: space)...].uppercased()] {
            text = text[...space] + offset
        }
        // RFC 2822, Abschnitt 4.3: zweistellige Jahre bis 49 liegen in den
        // 2000ern, ab 50 in den 1900ern, dreistellige zählen ab 1900. Ohne
        // das läse `yyyy` aus „25“ das Jahr 25.
        if let year = text.firstMatch(of: shortYear)?.1, let value = Int(year) {
            text.replaceSubrange(year.startIndex..<year.endIndex,
                                 with: String(value + (year.count == 2 && value < 50 ? 2000 : 1900)))
        }
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// `<itunes:duration>` erlaubt `3600`, `60:00` und `01:00:00`.
    ///
    /// Das Ergebnis ist eine **Angabe des Anbieters**, keine gemessene Länge.
    /// Für Timecodes zählt allein die tatsächliche Medienfassung.
    public static func durationSeconds(from string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count <= 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

        let numbers = parts.compactMap(Int64.init)
        // Absurde Teile fallen weg, bevor gerechnet wird. Mit
        // „999999999999999999:00“ liefe die Multiplikation über, und ein
        // Überlauf beendet die App.
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 <= longestDuration }) else { return nil }

        let seconds: Int64
        switch numbers.count {
        case 1: seconds = numbers[0]
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
        return seconds <= longestDuration ? Int(seconds) : nil
    }

    /// Eine Million Sekunden, gut elf Tage: länger ist keine Folge. Gerechnet
    /// wird in 64 Bit, und erst das Ergebnis wird ein `Int`: die Uhr-App
    /// läuft auch als arm64_32, dort hat `Int` 32 Bit. Die Grenze hält die
    /// Dauer auch in Millisekunden darunter, so legt die Uhr sie ab.
    private static let longestDuration: Int64 = 1_000_000
}

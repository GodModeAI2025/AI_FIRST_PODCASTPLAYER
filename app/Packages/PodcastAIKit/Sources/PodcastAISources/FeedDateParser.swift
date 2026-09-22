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

    public static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = iso8601WithFractional.date(from: trimmed) { return date }
        if let date = iso8601.date(from: trimmed) { return date }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
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

        let numbers = parts.compactMap(Int.init)
        guard numbers.count == parts.count else { return nil }

        switch numbers.count {
        case 1: return numbers[0]
        case 2: return numbers[0] * 60 + numbers[1]
        case 3: return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
    }
}

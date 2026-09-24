//
//  PrivateCloudLimit.swift
//  PodcastAIIntelligence
//
//  Warum eine Antwort vom Gerät kommt, obwohl Private Cloud Compute
//  erlaubt ist. Ist das Kontingent aufgebraucht oder bremst der Dienst,
//  fällt die Frage aufs Gerät zurück. Das geschah bisher stumm, und die
//  Antwort war kürzer, ohne dass jemand wusste, warum. Jetzt steht es in
//  einer ruhigen Zeile unter der Antwort.
//
//  In der Oberfläche heißt PCC „Apple-Server“, siehe docs/architektur.md.
//

import Foundation

/// Eine Grenze von Private Cloud Compute, die eine Antwort aufs Gerät
/// geschickt hat.
public enum PrivateCloudLimit: Sendable, Equatable {
    /// Das Kontingent ist aufgebraucht, vorher gemeldet oder beim Antworten.
    case quotaExhausted(resetDate: Date?)
    /// Der Dienst hat die Anfrage wegen zu vieler Anfragen abgelehnt.
    case rateLimited(resetDate: Date?)

    public var resetDate: Date? {
        switch self {
        case .quotaExhausted(let date), .rateLimited(let date): date
        }
    }

    /// Die Zeile unter der Antwort, etwa „Apple-Server heute ausgeschöpft,
    /// wieder ab 18:00. Diese Antwort kommt vom Gerät.“
    ///
    /// Liegt der Zeitpunkt am selben Tag, steht nur die Uhrzeit da, sonst
    /// Datum und Uhrzeit. Ein Zeitpunkt in der Vergangenheit sagt nichts
    /// mehr und fällt weg.
    public func note(now: Date = Date(), calendar: Calendar = .current) -> String {
        let upcoming = resetDate.flatMap { $0 > now ? $0 : nil }
        switch self {
        case .quotaExhausted:
            guard let upcoming else {
                return String(localized: "Apple-Server gerade ausgeschöpft. Diese Antwort kommt vom Gerät.",
                              bundle: .module)
            }
            if calendar.isDate(upcoming, inSameDayAs: now) {
                let time = Self.time(upcoming, calendar: calendar)
                return String(
                    localized: "Apple-Server heute ausgeschöpft, wieder ab \(time). Diese Antwort kommt vom Gerät.",
                    bundle: .module)
            }
            let moment = Self.dayAndTime(upcoming, calendar: calendar)
            return String(
                localized: "Apple-Server ausgeschöpft, wieder ab \(moment). Diese Antwort kommt vom Gerät.",
                bundle: .module)
        case .rateLimited:
            guard let upcoming else {
                return String(localized: "Apple-Server gerade ausgelastet. Diese Antwort kommt vom Gerät.",
                              bundle: .module)
            }
            let moment = calendar.isDate(upcoming, inSameDayAs: now)
                ? Self.time(upcoming, calendar: calendar)
                : Self.dayAndTime(upcoming, calendar: calendar)
            return String(
                localized: "Apple-Server gerade ausgelastet, wieder ab \(moment). Diese Antwort kommt vom Gerät.",
                bundle: .module)
        }
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func dayAndTime(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

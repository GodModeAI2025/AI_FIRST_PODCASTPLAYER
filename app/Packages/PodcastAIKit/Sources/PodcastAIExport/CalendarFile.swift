//
//  CalendarFile.swift
//  PodcastAIExport
//
//  Ein Termin als iCalendar-Datei. Auf dem Mac öffnet der Kalender sie und
//  fragt, wohin er den Termin legen soll. So braucht die App keinen Zugriff
//  auf den Kalender.
//

import Foundation
import PodcastAICore

public enum CalendarFile {

    /// Ein einzelnes Ereignis. Ohne Uhrzeit ganztägig, sonst eine Stunde lang.
    public static func event(title: String, start: Date, allDay: Bool, notes: String? = nil,
                             url: URL? = nil, location: String? = nil,
                             calendar: Calendar = .current, now: Date = Date()) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//PodcastAI//Erwähnt//DE",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            // Zweimal derselbe Termin ergibt dieselbe Kennung, der Kalender legt ihn
            // dann nicht doppelt an.
            "UID:\(StableDigest.hex(of: "\(title)|\(Int(start.timeIntervalSince1970))"))@podcastai",
            "DTSTAMP:\(utc(now))",
        ]
        if allDay {
            let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            lines.append("DTSTART;VALUE=DATE:\(day(start, calendar: calendar))")
            lines.append("DTEND;VALUE=DATE:\(day(next, calendar: calendar))")
        } else {
            lines.append("DTSTART:\(utc(start))")
            lines.append("DTEND:\(utc(start.addingTimeInterval(3_600)))")
        }
        lines.append("SUMMARY:\(escape(title))")
        if let location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
        if let notes, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            lines.append("URL:\(url.absoluteString)")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Text nach RFC 5545: Backslash, Semikolon, Komma und Umbruch maskiert.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Zeilen über 75 Byte werden umbrochen, die Fortsetzung beginnt mit einem Leerzeichen.
    static func fold(_ line: String) -> String {
        var result = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            if bytes + size > 75 {
                result += "\r\n "
                bytes = 1
            }
            result.append(character)
            bytes += size
        }
        return result
    }

    private static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04ld%02ld%02ldT%02ld%02ld%02ldZ",
                      p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld%02ld%02ld", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}

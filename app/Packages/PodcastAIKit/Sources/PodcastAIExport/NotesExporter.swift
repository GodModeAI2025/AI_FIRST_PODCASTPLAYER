//
//  NotesExporter.swift
//  PodcastAIExport
//
//  Gemerkte Stellen als Zitat mit Quelle: einzeln als Klartext zum Kopieren
//  und Teilen, alle zusammen als Markdown-Datei. Die Quellenangabe nennt das
//  Erscheinungsdatum der Folge. Wann gemerkt wurde, steht getrennt und
//  beschriftet daneben, denn zitiert wird die Folge, nicht der Merkzeitpunkt.
//

import Foundation
import PodcastAICore

/// Eine gemerkte Stelle, wie sie die App verlässt. Titel, Zitat und
/// Zeitmarke kommen aus der Kopie in der Notiz, Erscheinungsdatum und Link
/// aus der Folge, solange es sie gibt.
public struct ExportedNote: Sendable {
    public var note: String?
    public var quote: String?
    public var episodeTitle: String?
    public var sourceTitle: String?
    public var position: MediaTime?
    public var publishedAt: Date?
    /// Die Seite der Folge. Verlinkt wird nur, was ``SafeSourceLink`` besteht.
    public var webPageURL: URL?
    public var capturedAt: Date?

    public init(note: String? = nil, quote: String? = nil, episodeTitle: String? = nil,
                sourceTitle: String? = nil, position: MediaTime? = nil, publishedAt: Date? = nil,
                webPageURL: URL? = nil, capturedAt: Date? = nil) {
        self.note = note; self.quote = quote; self.episodeTitle = episodeTitle
        self.sourceTitle = sourceTitle; self.position = position; self.publishedAt = publishedAt
        self.webPageURL = webPageURL; self.capturedAt = capturedAt
    }

    /// Die Herkunft in einer Zeile: Folge, Podcast, Zeitmarke, Erscheinungsdatum.
    public var origin: String {
        Citation.origin(episode: episodeTitle, podcast: sourceTitle, at: position, published: publishedAt)
    }

    /// Ein Link, der geteilt werden darf, oder `nil`.
    public var link: URL? { SafeSourceLink(publicURL: webPageURL)?.url }

    fileprivate var trimmedNote: String? {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    fileprivate var trimmedQuote: String? {
        let text = quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}

/// Zitat und Herkunft als Klartext, ohne Markdown-Zeichen. So landet es
/// lesbar in einer Nachricht, einer Mail oder einem Manuskript.
public enum Citation {

    /// „Folge · Podcast · 4:00 · erschienen am 22. September 2026“.
    public static func origin(episode: String?, podcast: String?, at position: MediaTime?,
                              published: Date?) -> String {
        var parts = [episode, podcast, position?.timecode].compactMap { part -> String? in
            guard let part, !part.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return part
        }
        if let published {
            let date = published.formatted(date: .long, time: .omitted)
            parts.append(String(localized: "erschienen am \(date)", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    /// Eine gemerkte Stelle zum Kopieren oder Teilen: Zitat, Herkunft, Link
    /// und der eigene Kommentar, jeweils nur, wenn es ihn gibt.
    public static func plainText(_ note: ExportedNote) -> String {
        var lines: [String] = []
        if let quote = note.trimmedQuote { lines.append("„\(quote)“") }
        let origin = note.origin
        if !origin.isEmpty { lines.append(lines.isEmpty ? origin : "(\(origin))") }
        if let link = note.link { lines.append(link.absoluteString) }
        if let comment = note.trimmedNote {
            if !lines.isEmpty { lines.append("") }
            lines.append(String(localized: "Meine Notiz: \(comment)", bundle: .module))
        }
        return lines.joined(separator: "\n")
    }
}

public struct NotesExporter: Sendable {

    public init() {}

    /// Alle gemerkten Stellen als eine Markdown-Datei, mit Kopfdaten für
    /// Notizprogramme wie Obsidian.
    public func markdown(_ notes: [ExportedNote], exportedAt: Date = Date()) -> String {
        let title = String(localized: "Gemerkte Stellen", bundle: .module)
        var lines = FrontMatter.lines([
            ("title", FrontMatter.quoted(title)),
            ("exported", FrontMatter.day(exportedAt)),
        ])
        lines += ["# " + MarkdownExporter.escapeInline(title), ""]
        for note in notes {
            lines += section(note)
        }
        lines += ["---", "",
                  "_" + String(
                    localized: "Exportiert aus PodcastAI. Originalton und Originalrechte liegen bei den jeweiligen Anbietern.",
                    bundle: .module) + "_"]
        return lines.joined(separator: "\n")
    }

    /// Eine Stelle: Kommentar als Überschrift, das Zitat als Blockzitat,
    /// darunter die Quelle mit Erscheinungsdatum und Link und getrennt
    /// davon, wann gemerkt wurde.
    func section(_ note: ExportedNote) -> [String] {
        let heading = note.trimmedNote ?? String(localized: "Gemerkte Stelle", bundle: .module)
        var lines = ["## " + MarkdownExporter.escapeInline(heading), ""]
        if let quote = note.trimmedQuote {
            for line in MarkdownExporter.escapeBlock(quote).split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
            lines.append("")
        }
        var source: [String] = []
        let origin = note.origin
        if !origin.isEmpty {
            let escaped = MarkdownExporter.escapeInline(origin)
            source.append(String(localized: "Quelle: \(escaped)", bundle: .module))
        }
        if let link = note.link {
            // Autolink-Form: kein Zeichen der Adresse verlässt die Linkstruktur.
            source.append("<\(link.absoluteString)>")
        }
        if let captured = note.capturedAt {
            let date = captured.formatted(date: .long, time: .shortened)
            source.append(String(localized: "Gemerkt am \(date)", bundle: .module))
        }
        if !source.isEmpty {
            // Zwei Leerzeichen am Zeilenende: ein Umbruch im selben Absatz.
            lines.append(source.joined(separator: "  \n"))
            lines.append("")
        }
        return lines
    }
}

/// YAML-Kopfdaten am Anfang einer Markdown-Datei. Die Schlüssel bleiben
/// englisch, weil Notizprogramme sie so erwarten. Werte ohne Inhalt fehlen.
enum FrontMatter {

    static func lines(_ fields: [(key: String, value: String?)]) -> [String] {
        let present = fields.compactMap { field in field.value.map { "\(field.key): \($0)" } }
        guard !present.isEmpty else { return [] }
        return ["---"] + present + ["---", ""]
    }

    /// Ein Wert in doppelten Anführungszeichen. Ohne sie wäre etwa „10:00“
    /// für YAML eine Zahl zur Basis 60 und ein Titel mit Doppelpunkt ein
    /// Fehler.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n", "\r", "\r\n", "\t", "\u{2028}", "\u{2029}": result += " "
            default:
                if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                   CharacterSet.controlCharacters.contains(scalar) {
                    result += " "
                } else {
                    result.append(character)
                }
            }
        }
        return result + "\""
    }

    /// Ein Tag wie 2026-09-22, in der Zeitzone des Geräts. Ohne
    /// Anführungszeichen, damit Notizprogramme ihn als Datum erkennen.
    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}

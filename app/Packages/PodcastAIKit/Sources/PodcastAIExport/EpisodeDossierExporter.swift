//
//  EpisodeDossierExporter.swift
//  PodcastAIExport
//
//  Alles zu einer Folge in einer Markdown-Datei: Kopfdaten, Shownotes,
//  Kapitel, Fakten mit Zeitmarke, eigene Notizen, Transkript mit
//  Zeitmarken. Dazu der Export einer Chat-Antwort mit ihren Belegen. Beides
//  ist für Menschen lesbar und lässt sich in Notizprogramme wie Obsidian
//  oder Notion übernehmen.
//

import Foundation
import PodcastAICore

public struct EpisodeDossier: Sendable {
    public var title: String
    public var sourceTitle: String
    public var publishedAt: Date?
    public var duration: MediaDuration?
    public var webPageURL: URL?
    public var shownotes: String?
    public var chapters: [Chapter]
    public var facts: [EpisodeFact]
    public var transcript: Transcript?
    /// Fakt-Kennung → was in der Folge dazu wörtlich gesagt wurde.
    public var factQuotes: [String: String]
    /// Die eigenen Notizen zu dieser Folge.
    public var notes: [ExportedNote]

    public init(title: String, sourceTitle: String, publishedAt: Date? = nil,
                duration: MediaDuration? = nil, webPageURL: URL? = nil, shownotes: String? = nil,
                chapters: [Chapter] = [], facts: [EpisodeFact] = [], transcript: Transcript? = nil,
                factQuotes: [String: String] = [:], notes: [ExportedNote] = []) {
        self.title = title; self.sourceTitle = sourceTitle; self.publishedAt = publishedAt
        self.duration = duration; self.webPageURL = webPageURL; self.shownotes = shownotes
        self.chapters = chapters; self.facts = facts; self.transcript = transcript
        self.factQuotes = factQuotes; self.notes = notes
    }
}

public struct ExportedAnswer: Sendable {
    public var question: String
    public var scopeLabel: String
    public var text: String
    public var modelLabel: String?
    /// Nummer → (Folgentitel, Quelle, Zeitbereich, Zitat)
    public var citations: [(number: Int, episode: String, source: String, range: MediaTimeRange?, quote: String)]

    public init(question: String, scopeLabel: String, text: String, modelLabel: String?,
                citations: [(number: Int, episode: String, source: String, range: MediaTimeRange?, quote: String)]) {
        self.question = question; self.scopeLabel = scopeLabel; self.text = text
        self.modelLabel = modelLabel; self.citations = citations
    }
}

public struct EpisodeDossierExporter: Sendable {

    public init() {}

    public func markdown(_ dossier: EpisodeDossier, includeTranscript: Bool = true) -> String {
        let link = SafeSourceLink(publicURL: dossier.webPageURL)
        // Kopfdaten für Notizprogramme wie Obsidian. Die Länge in
        // Anführungszeichen: „10:00“ wäre für YAML sonst eine Zahl.
        var lines = FrontMatter.lines([
            ("title", FrontMatter.quoted(dossier.title)),
            ("podcast", dossier.sourceTitle.isEmpty ? nil : FrontMatter.quoted(dossier.sourceTitle)),
            ("published", dossier.publishedAt.map(FrontMatter.day)),
            ("duration", dossier.duration.map { FrontMatter.quoted(MediaTime(milliseconds: $0.milliseconds).timecode) }),
            ("link", link.map { FrontMatter.quoted($0.url.absoluteString) }),
        ])
        lines.append("# " + MarkdownExporter.escapeInline(dossier.title))
        lines.append("")
        var meta = [Self.field(String(localized: "Quelle:", bundle: .module),
                               MarkdownExporter.escapeInline(dossier.sourceTitle))]
        if let date = dossier.publishedAt {
            meta.append(Self.field(String(localized: "Erschienen:", bundle: .module),
                                   date.formatted(date: .long, time: .omitted)))
        }
        if let duration = dossier.duration {
            meta.append(Self.field(String(localized: "Länge:", bundle: .module), duration.shortDescription))
        }
        if let link {
            meta.append(Self.field(String(localized: "Link:", bundle: .module), "<\(link.url.absoluteString)>"))
        }
        lines.append(meta.joined(separator: "  \n"))

        if let notes = dossier.shownotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines += ["", "## " + String(localized: "Shownotes", bundle: .module), "",
                      Self.shownotesMarkdown(notes)]
        }
        if !dossier.chapters.isEmpty {
            lines += ["", "## " + String(localized: "Kapitel", bundle: .module), ""]
            for chapter in dossier.chapters {
                lines.append("- `\(chapter.start.timecode)` " + MarkdownExporter.escapeInline(chapter.title))
            }
        }
        if !dossier.facts.isEmpty {
            lines += ["", "## " + String(localized: "Fakten", bundle: .module), "",
                      String(localized: "Aussagen aus der Folge, gesagt, nicht geprüft.", bundle: .module), ""]
            for fact in dossier.facts {
                lines.append("- " + MarkdownExporter.escapeInline(fact.statement)
                             + " (`\(fact.range.start.timecode)–\(fact.range.end.timecode)`)")
                if let quote = dossier.factQuotes[fact.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !quote.isEmpty {
                    lines.append("  > " + MarkdownExporter.escapeInline(quote))
                }
            }
        }
        if !dossier.notes.isEmpty {
            lines += ["", "## " + String(localized: "Meine Notizen", bundle: .module), ""]
            for note in dossier.notes {
                let comment = note.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let heading = comment.isEmpty ? String(localized: "Gemerkte Stelle", bundle: .module) : comment
                let time = note.position.map { "`\($0.timecode)` " } ?? ""
                lines.append("- " + time + MarkdownExporter.escapeInline(heading))
                if let quote = note.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                    lines.append("  > " + MarkdownExporter.escapeInline(quote))
                }
            }
        }
        if includeTranscript, let transcript = dossier.transcript, !transcript.segments.isEmpty {
            lines += ["", "## " + String(localized: "Transkript", bundle: .module), ""]
            // Jeder Satz mit seiner eigenen Zeitmarke, wie in der App. Ein
            // Absatz über eine Minute hätte spätere Sätze unter einer früheren
            // Zeit versteckt, und genau zitieren ginge nicht mehr.
            for segment in transcript.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("`\(segment.range.start.timecode)` " + MarkdownExporter.escapeInline(text))
                lines.append("")
            }
        }
        let exported = Date().formatted(date: .long, time: .shortened)
        lines += ["", "---", String(localized: "Exportiert aus PodcastAI am \(exported).", bundle: .module)]
        return lines.joined(separator: "\n")
    }

    public func markdown(_ answer: ExportedAnswer) -> String {
        var lines = ["# " + MarkdownExporter.escapeInline(answer.question), ""]
        var meta = Self.field(String(localized: "Bereich:", bundle: .module),
                              MarkdownExporter.escapeInline(answer.scopeLabel))
        if let model = answer.modelLabel {
            meta += "  \n" + Self.field(String(localized: "Formuliert von:", bundle: .module),
                                        MarkdownExporter.escapeInline(model))
        }
        lines += [meta, "", MarkdownExporter.escapeBlock(answer.text)]
        if !answer.citations.isEmpty {
            lines += ["", "## " + String(localized: "Belege", bundle: .module), ""]
            for citation in answer.citations {
                let time = citation.range.map { " `\($0.start.timecode)–\($0.end.timecode)`" } ?? ""
                lines.append("\(citation.number). " + MarkdownExporter.escapeInline(citation.episode)
                             + " · " + MarkdownExporter.escapeInline(citation.source) + time)
                lines.append("   > " + MarkdownExporter.escapeInline(String(citation.quote.prefix(400))))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Shownotes als Markdown. Aufzählungspunkte aus dem HTML („• “) werden
    /// zu „- “, sonst erkennt kein Markdown-Programm die Liste.
    static func shownotesMarkdown(_ text: String) -> String {
        let bullets: Set<Character> = ["•", "◦", "▪", "‣"]
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let first = trimmed.first, bullets.contains(first) {
                    return "- " + MarkdownExporter.escapeInline(String(trimmed.dropFirst()))
                }
                return MarkdownExporter.escapeBlock(String(line))
            }
            .joined(separator: "\n")
    }

    /// Eine Kopfzeile wie „**Quelle:** Titel“. Die Bezeichnung kommt
    /// übersetzt aus dem Katalog, der Doppelpunkt gehört zu ihr, weil
    /// manche Sprachen davor ein Leerzeichen setzen.
    private static func field(_ name: String, _ value: String) -> String {
        "**\(name)** \(value)"
    }

    /// Fasst Segmente zu Absätzen von etwa einer Minute zusammen. Ein Absatz
    /// je Satz wäre beim Lesen zu kleinteilig, ein Block ohne Zeitmarken
    /// nicht mehr nachhörbar.
    public static func paragraphs(_ segments: [TranscriptSegment],
                                  seconds: Double = 60) -> [(start: MediaTime, text: String)] {
        var result: [(start: MediaTime, text: String)] = []
        var start: MediaTime?
        var buffer: [String] = []
        for segment in segments.sorted(by: { $0.range.start.milliseconds < $1.range.start.milliseconds }) {
            if start == nil { start = segment.range.start }
            buffer.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let begin = start, segment.range.end.seconds - begin.seconds >= seconds {
                result.append((begin, buffer.joined(separator: " ")))
                start = nil; buffer = []
            }
        }
        if let begin = start, !buffer.isEmpty { result.append((begin, buffer.joined(separator: " "))) }
        return result
    }
}

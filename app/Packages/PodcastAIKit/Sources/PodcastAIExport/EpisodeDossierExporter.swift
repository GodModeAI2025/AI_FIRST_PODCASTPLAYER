//
//  EpisodeDossierExporter.swift
//  PodcastAIExport
//
//  Alles zu einer Folge in einer Markdown-Datei: Kopf, Shownotes, Kapitel,
//  Fakten mit Zeitmarke, Transkript mit Zeitmarken. Dazu der Export einer
//  Chat-Antwort mit ihren Belegen. Beides ist für Menschen lesbar und lässt
//  sich in Notizprogramme wie Obsidian oder Notion übernehmen.
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

    public init(title: String, sourceTitle: String, publishedAt: Date? = nil,
                duration: MediaDuration? = nil, webPageURL: URL? = nil, shownotes: String? = nil,
                chapters: [Chapter] = [], facts: [EpisodeFact] = [], transcript: Transcript? = nil,
                factQuotes: [String: String] = [:]) {
        self.title = title; self.sourceTitle = sourceTitle; self.publishedAt = publishedAt
        self.duration = duration; self.webPageURL = webPageURL; self.shownotes = shownotes
        self.chapters = chapters; self.facts = facts; self.transcript = transcript
        self.factQuotes = factQuotes
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
        var lines: [String] = []
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
        if let link = SafeSourceLink(publicURL: dossier.webPageURL) {
            meta.append(Self.field(String(localized: "Link:", bundle: .module), "<\(link.url.absoluteString)>"))
        }
        lines.append(meta.joined(separator: "  \n"))

        if let notes = dossier.shownotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines += ["", "## " + String(localized: "Shownotes", bundle: .module), "",
                      MarkdownExporter.escapeBlock(notes)]
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
        if includeTranscript, let transcript = dossier.transcript, !transcript.segments.isEmpty {
            lines += ["", "## " + String(localized: "Transkript", bundle: .module), ""]
            for paragraph in Self.paragraphs(transcript.segments) {
                lines.append("`\(paragraph.start.timecode)` " + MarkdownExporter.escapeInline(paragraph.text))
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

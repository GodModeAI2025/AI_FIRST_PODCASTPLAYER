//
//  MarkdownExporter.swift
//  PodcastAIExport
//
//  Wissen verlässt die App wieder — als Markdown, das in einem beliebigen
//  Wissensordner weiterlebt.
//
//  Zwei Dinge, die hier leicht schiefgehen und deshalb ausdrücklich gelöst
//  sind:
//
//  1. **Private Feedtoken.** Ein Podcast-Feed mit Zugangstoken im Pfad darf
//     nicht in einem Export landen, der später geteilt wird. Ein
//     kosmetisches Entfernen von Querystrings genügt nicht — der Token kann
//     im Pfad stehen. Deshalb entsteht ein externer Link nur aus einer
//     ausdrücklich als öffentlich markierten Adresse.
//
//  2. **Escaping.** Ein Foldentitel mit `[`, `]`, `|` oder einem Zeilenumbruch
//     zerlegt sonst die Tabellen- oder Linkstruktur des Exports.
//

import Foundation
import PodcastAICore

/// Eine Adresse, die geteilt werden darf.
public struct SafeSourceLink: Sendable, Equatable {
    public let url: URL

    /// Erzeugt einen Link nur aus einer als öffentlich bekannten Adresse.
    ///
    /// Die Prüfung ist absichtlich streng: keine Zugangsdaten, keine
    /// Query-Parameter, kein Fragment, nur http(s). Alles andere ergibt
    /// `nil` — und dann nennt der Export Titel, Anbieter und Originalzeit
    /// statt einer Adresse.
    public init?(publicURL: URL?) {
        guard let url = publicURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty else { return nil }
        self.url = url
    }
}

public struct ExportScope: Sendable {
    public var includeQuotes: Bool
    public var includeUserNotes: Bool
    public var includeModelDerivations: Bool
    /// Adressen nur, wenn sie die Prüfung von ``SafeSourceLink`` bestehen.
    public var includeExternalLinks: Bool

    public init(includeQuotes: Bool = true, includeUserNotes: Bool = true,
                includeModelDerivations: Bool = true, includeExternalLinks: Bool = true) {
        self.includeQuotes = includeQuotes
        self.includeUserNotes = includeUserNotes
        self.includeModelDerivations = includeModelDerivations
        self.includeExternalLinks = includeExternalLinks
    }
}

/// Ein Wissenseintrag, wie er exportiert wird.
public struct ExportableInsight: Sendable {
    public let title: String
    public let claim: Claim
    public let evidence: [Evidence]
    public let userNote: String?
    public let sourceTitles: [EvidenceID: String]
    public let episodeTitles: [EvidenceID: String]
    public let publicURLs: [EvidenceID: URL]

    public init(
        title: String, claim: Claim, evidence: [Evidence], userNote: String? = nil,
        sourceTitles: [EvidenceID: String], episodeTitles: [EvidenceID: String],
        publicURLs: [EvidenceID: URL] = [:]
    ) {
        self.title = title; self.claim = claim; self.evidence = evidence
        self.userNote = userNote; self.sourceTitles = sourceTitles
        self.episodeTitles = episodeTitles; self.publicURLs = publicURLs
    }
}

public struct MarkdownExporter: Sendable {

    public init() {}

    public func export(_ insight: ExportableInsight, scope: ExportScope = ExportScope()) -> String {
        var lines: [String] = []

        lines.append("# \(Self.escapeInline(insight.title))")
        lines.append("")

        if scope.includeModelDerivations {
            lines.append("## Erkenntnis")
            lines.append(Self.escapeBlock(insight.claim.statement))
            lines.append("")
            if let relevance = insight.claim.personalRelevance {
                lines.append("_Relevant für: \(Self.escapeInline(relevance.interestLabel)) — "
                             + "\(Self.escapeInline(relevance.explanation))_")
                lines.append("")
            }
        }

        lines.append("## Quellen")
        lines.append("")
        for item in insight.evidence {
            lines.append(contentsOf: quoteBlock(for: item, in: insight, scope: scope))
        }

        if let note = insight.userNote, scope.includeUserNotes,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Meine Notiz")
            lines.append(Self.escapeBlock(note))
            lines.append("")
        }

        if let question = insight.claim.openQuestion {
            lines.append("## Offene Frage")
            lines.append(Self.escapeBlock(question))
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("_Exportiert aus PodcastAI. Originalton und Originalrechte liegen "
                     + "bei den jeweiligen Anbietern._")

        return lines.joined(separator: "\n")
    }

    private func quoteBlock(
        for evidence: Evidence, in insight: ExportableInsight, scope: ExportScope
    ) -> [String] {
        var lines: [String] = []

        let source = insight.sourceTitles[evidence.id] ?? "Unbekannte Quelle"
        let episode = insight.episodeTitles[evidence.id] ?? "Unbekannte Folge"
        lines.append("### \(Self.escapeInline(source))")

        var reference = Self.escapeInline(episode)
        if let range = evidence.range {
            reference += " · \(range.start.preciseTimecode)–\(range.end.preciseTimecode)"
        } else {
            // Ehrlich benennen, statt eine Zeit zu erfinden.
            reference += " · ohne Zeitbezug"
        }
        lines.append(reference)

        if scope.includeExternalLinks,
           let link = SafeSourceLink(publicURL: insight.publicURLs[evidence.id]) {
            lines.append("")
            lines.append("[Originalquelle](\(link.url.absoluteString))")
        }

        if scope.includeQuotes {
            lines.append("")
            // Blockzitat: der Originaltext bleibt als Original erkennbar.
            for line in Self.escapeBlock(evidence.quotedText).split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
        }

        if let speaker = evidence.attributedSpeaker {
            lines.append("")
            lines.append("— \(Self.escapeInline(speaker))")
        }
        lines.append("")
        return lines
    }

    // MARK: - Escaping

    /// Für Text, der in einer Überschrift oder Zeile steht: Zeilenumbrüche
    /// und Markdown-Sonderzeichen entschärfen.
    static func escapeInline(_ text: String) -> String {
        let singleLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return escapeSpecials(singleLine)
    }

    /// Für mehrzeiligen Text: Umbrüche bleiben, Sonderzeichen werden entschärft.
    static func escapeBlock(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { escapeSpecials($0) }
            .joined(separator: "\n")
    }

    /// Maskiert Markdown-Sonderzeichen und entfernt Steuerzeichen.
    ///
    /// Steuerzeichen sind nicht bloß Kosmetik: ein vertikaler Tabulator oder
    /// ein Formfeed mitten in einem Transkript wird von manchen Editoren als
    /// Zeilenumbruch gewertet, von anderen nicht. Was in einem Export
    /// unterschiedlich aussieht, je nachdem womit man es öffnet, hat darin
    /// nichts verloren. Der Zeilenumbruch selbst bleibt erhalten — er wird
    /// eine Ebene höher behandelt.
    private static func escapeSpecials(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if let scalar = character.unicodeScalars.first,
               character.unicodeScalars.count == 1,
               CharacterSet.controlCharacters.contains(scalar), character != "\n" {
                result.append(" ")
                continue
            }
            switch character {
            case "\\", "`", "*", "_", "[", "]", "(", ")", "#", "|", "<", ">":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }
        }
        return result
    }
}

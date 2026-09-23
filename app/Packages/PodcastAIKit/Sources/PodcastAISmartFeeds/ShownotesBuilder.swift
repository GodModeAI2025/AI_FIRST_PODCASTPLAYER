//
//  ShownotesBuilder.swift
//  PodcastAISmartFeeds
//
//  Titel und Shownotes entstehen **ausschließlich aus dem fertigen
//  Manifest** (FR-125). Nicht aus den Kandidaten, nicht aus dem Profil und
//  nicht aus dem, was hätte enthalten sein können. Sonst verspricht die
//  Ausgabe Inhalte, die nicht darin sind.
//
//  Diese Bausteine kommen ohne Modell aus. Ein Apple-Modell darf die Texte
//  später verfeinern — aber eine Ausgabe ist auch ohne Apple Intelligence
//  sofort vollständig benutzbar.
//

import Foundation
import PodcastAICore

public struct ShownotesBuilder: Sendable {

    public init() {}

    /// Ein Kapiteleintrag je Abschnitt, mit Rückverweis auf die Originalstelle.
    public func build(from segments: [PersonalEpisodeSegment]) -> [ShownotesEntry] {
        segments.map { segment in
            ShownotesEntry(
                virtualStart: segment.virtualRange.start,
                title: chapterTitle(for: segment),
                sourceTitle: segment.sourceTitle,
                episodeTitle: segment.episodeTitle,
                originalRange: segment.coreRange,
                evidenceIDs: segment.evidenceIDs
            )
        }
    }

    /// Kurzer Kapiteltitel aus dem Relevanzgrund. Der Grund ist bereits ein
    /// vollständiger Satz; hier wird daraus eine Überschrift.
    private func chapterTitle(for segment: PersonalEpisodeSegment) -> String {
        let reason = segment.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return segment.episodeTitle }

        // Erster Satz, auf eine Überschriftenlänge gekürzt.
        let firstSentence = reason.split(
            whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" }
        ).first.map(String.init) ?? reason

        return Self.truncated(firstSentence.trimmingCharacters(in: .whitespaces), to: 70)
    }

    /// Markdown-Shownotes für Anzeige und Export.
    public func markdown(for episode: PersonalEpisode) -> String {
        var lines: [String] = []
        lines.append("## \(episode.title)")
        if let subtitle = episode.subtitle { lines.append(contentsOf: ["", subtitle]) }

        lines.append("")
        lines.append(episode.coverage.label)
        lines.append("")
        lines.append("### " + String(localized: "Kapitel", bundle: .module))

        for entry in episode.shownotes {
            let original = String(
                localized: "Original \(entry.originalRange.start.timecode)–\(entry.originalRange.end.timecode)",
                bundle: .module)
            lines.append(
                "- **\(entry.virtualStart.timecode)** \(entry.title)  \n"
                + "  \(entry.sourceTitle) · \(entry.episodeTitle) · \(original)"
            )
        }

        // Kontextwiederholung ausdrücklich benennen, damit niemand sie für
        // neuen Inhalt hält.
        if episode.segments.contains(where: \.contextReplay) {
            lines.append("")
            let note = String(
                localized: "Einzelne Abschnitte beginnen mit ein paar Sekunden Kontext, die du eventuell schon gehört hast.",
                bundle: .module)
            lines.append("_\(note)_")
        }
        return lines.joined(separator: "\n")
    }

    static func truncated(_ string: String, to limit: Int) -> String {
        guard string.count > limit else { return string }
        let cut = string.prefix(limit)
        // Möglichst an einer Wortgrenze abschneiden.
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > limit / 2 {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}

public struct EditionTitleBuilder: Sendable {

    public init() {}

    /// Titel aus Feedname und Ausgabendatum. Bewusst nüchtern und
    /// vorhersagbar — der Feed heißt schon, wie er heißt.
    public func title(for feed: SmartPodcastFeed, segments: [PersonalEpisodeSegment], at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("ddMM")
        return "\(feed.title) · \(formatter.string(from: date))"
    }

    /// Untertitel aus dem, was tatsächlich drin ist.
    ///
    /// Wichtig: alte Originalinhalte werden als **neu für dich** ausgewiesen,
    /// nicht als neu veröffentlicht (FR-125). Ein Beitrag von 2024, den du
    /// noch nicht kanntest, ist keine aktuelle Meldung.
    public func subtitle(for segments: [PersonalEpisodeSegment], coverage: EditionCoverage) -> String? {
        guard !segments.isEmpty else { return nil }

        let sourceCount = Set(segments.map(\.sourceID)).count
        var parts = [String(AttributedString(localized: """
            ^[\(segments.count) Stelle](inflect: true) aus ^[\(sourceCount) Quelle](inflect: true)
            """, bundle: .module).characters)]

        // Enthält die Ausgabe älteres Material? Dann sagen wir das.
        let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        let hasOlderMaterial = segments.contains {
            guard let published = $0.originalPublishedAt else { return false }
            return published < cutoff
        }
        if hasOlderMaterial {
            parts.append(String(localized: "neu für dich, nicht neu veröffentlicht", bundle: .module))
        }

        return parts.joined(separator: " · ")
    }
}

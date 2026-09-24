//
//  ChapterViews.swift
//  PodcastAI
//
//  Der Reiter „Kapitel“ einer Folge: je Kapitel Titel, ein Satz, worum es
//  geht, die Fakten daraus und ein Stück Transkript. Liefert der Podcast
//  keine Kapitel, zeigt er die Abschnitte, die die App aus dem Transkript
//  gebildet hat. Dazu „Original öffnen“ für Stellen aus anderen Folgen.
//

import SwiftUI
import PodcastAIKit

struct EpisodeChapterList: View {

    let episode: Episode
    /// Die Kapitel aus dem Feed. Leer, wenn der Podcast keine liefert.
    let chapters: [Chapter]
    let passages: [Evidence]
    let facts: [EpisodeFact]
    @Environment(AppModel.self) private var model
    @State private var sections: [ChapterSection] = []
    @State private var summaries: [Int64: ChapterSummaryCache.Entry] = [:]
    @State private var computed = false

    /// Was die Kapitel bestimmt. Ändert sich eines davon, entstehen sie neu.
    private struct Input: Equatable {
        let chapters: [Chapter]
        let passages: [EvidenceID]
        let duration: MediaDuration?
    }

    private var isDerived: Bool { sections.contains(where: \.isDerived) }

    var body: some View {
        let factGroups = ChapterSections.group(facts, into: sections) { $0.range.start }
        let passageGroups = ChapterSections.group(passages, into: sections) { $0.range?.start }
        List {
            if computed, sections.isEmpty {
                ContentUnavailableView(
                    "Keine Kapitel", systemImage: "list.bullet",
                    description: Text("""
                        Der Podcast liefert für diese Folge keine Kapitelmarken. Sobald das Transkript \
                        fertig ist, teilt die App die Folge in Abschnitte.
                        """))
            }
            ForEach(sections) { section in
                SwiftUI.Section {
                    ChapterRow(chapter: section.chapter, episode: episode, chapters: sections.map(\.chapter))
                    if let text = summaries[section.id]?.text {
                        ChapterSummaryLine(text: text, modelTier: summaries[section.id]?.modelTier)
                    }
                    ForEach(factGroups[section.index]) { fact in
                        FactRow(fact: fact, episode: episode)
                            .buttonStyle(.borderless)
                    }
                    if let excerpt = Self.excerpt(passageGroups[section.index]) {
                        ChapterExcerpt(text: excerpt)
                    }
                } footer: {
                    if section.isDerived, section.index == sections.count - 1 {
                        Text("""
                            Der Podcast liefert für diese Folge keine Kapitel. Die Abschnitte hat die App \
                            aus dem Transkript gebildet, dort, wo das Thema wechselt.
                            """)
                    }
                }
            }
        }
        .accessibilityIdentifier(isDerived ? "chapters.derived" : "chapters.list")
        .task(id: Input(chapters: chapters, passages: passages.map(\.id), duration: episode.declaredDuration)) {
            let found = await AppModel.chapterSections(
                chapters: chapters, duration: episode.declaredDuration, evidence: passages)
            sections = found
            computed = true
            summaries = await model.storedChapterSummaries(for: episode, sections: found, evidence: passages)
            // Fehlende Sätze entstehen jetzt, einer nach dem anderen. Verlässt
            // jemand den Reiter, endet das, und der Rest kommt beim nächsten Mal.
            await model.prepareChapterSummaries(for: episode, sections: found, evidence: passages) { start, entry in
                summaries[start] = entry
            }
        }
    }

    /// Der Anfang des Transkripts im Kapitel, höchstens ``excerptLimit`` Zeichen.
    static func excerpt(_ passages: [Evidence]) -> String? {
        let text = passages.prefix(3).map(\.quotedText).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > excerptLimit else { return text }
        let cut = text.prefix(excerptLimit)
        // Nicht mitten im Wort enden.
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]) + " …"
    }

    static let excerptLimit = 280
}

/// Der Satz, worum es im Kapitel geht, als Zusammenfassung gekennzeichnet.
struct ChapterSummaryLine: View {
    let text: String
    let modelTier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text("Zusammenfassung · \(EpisodeDetailView.factAuthor(modelTier))")
            } icon: {
                Image(systemName: "sparkles").accessibilityHidden(true)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chapter.summary")
    }
}

/// Ein Stück Transkript aus dem Kapitel, im Wortlaut.
struct ChapterExcerpt: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Label {
                Text("Aus dem Transkript")
            } icon: {
                Image(systemName: "text.alignleft").accessibilityHidden(true)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("„\(text)“")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chapter.excerpt")
    }
}

/// „Original öffnen“: spielt die Originalfolge ab der Stelle, aus der eine
/// Passage oder ein Kapitel stammt. Nur auf Tippen.
struct OpenOriginalButton: View {
    let episodeID: EpisodeID
    let position: MediaTime
    /// Läuft nach dem Tipp, etwa um ein Blatt zu schließen.
    var onOpen: (() -> Void)? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.openOriginal(episodeID: episodeID, at: position) }
            onOpen?()
        } label: {
            Label("Original öffnen", systemImage: "arrow.up.forward.square")
        }
        .accessibilityHint("Spielt die Originalfolge ab \(TimecodeLabel.spokenSingle(position.timecode))")
        .accessibilityIdentifier("openOriginal")
    }
}

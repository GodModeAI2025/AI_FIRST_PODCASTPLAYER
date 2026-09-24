//
//  MetadataViews.swift
//  PodcastAI
//
//  Die Angaben aus dem Feed: je Folge ein kompakter Block, je Podcast ein
//  Abschnitt oben auf seiner Seite. Alles hier ist fremder Text aus dem
//  Feed und wird nur angezeigt.
//

import SwiftUI
import PodcastAIKit

// MARK: - Folge

/// Podcast, Autor, Datum, Dauer, Staffel und Folge, Rubriken und Link einer
/// Folge. Zeilen ohne Angabe fallen weg.
struct EpisodeMetadataBlock: View {

    let episode: Episode
    let source: Source?

    private var author: String? {
        let value = episode.author ?? source?.author
        return value?.isEmpty == false ? value : nil
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Design.Spacing.control,
             verticalSpacing: Design.Spacing.micro) {
            if let source {
                row("Podcast") { Text(source.title) }
            }
            if let author {
                row("Von") { Text(author) }
            }
            if let published = episode.publishedAt {
                row("Erschienen") { Text(published, format: .dateTime.day().month(.wide).year()) }
            }
            if let duration = episode.declaredDuration {
                row("Dauer") { Text(duration.shortDescription) }
            }
            if let numbering = EpisodeNumbering(episode: episode).text {
                row("Folge") { Text(numbering) }
            }
            if let categories = source?.categories, !categories.isEmpty {
                row("Rubriken") { Text(categories.joined(separator: " · ")) }
            }
            if let url = episode.webPageURL {
                row("Link") {
                    Link(destination: url) {
                        Text(url.host() ?? url.absoluteString)
                            .lineLimit(1)
                    }
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episode.metadata")
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// „Staffel 2 · Folge 14 · Trailer“ aus den Feedangaben.
struct EpisodeNumbering {

    let episode: Episode

    var text: String? {
        var parts: [String] = []
        if let season = episode.season { parts.append(String(localized: "Staffel \(season)")) }
        if let number = episode.episodeNumber { parts.append(String(localized: "Folge \(number)")) }
        switch episode.episodeType {
        case "trailer": parts.append(String(localized: "Trailer", comment: "Art einer Folge im Feed"))
        case "bonus": parts.append(String(localized: "Bonus", comment: "Art einer Folge im Feed"))
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Podcast

/// Beschreibung, Herausgeber, Rubriken, Sprache und Webseite eines Podcasts,
/// oben auf seiner Seite. Die Beschreibung ist zuerst gekürzt.
struct SourceMetadataSection: View {

    let source: Source
    @State private var expanded = false

    private var hasContent: Bool {
        source.summary != nil || source.author != nil || !(source.categories ?? []).isEmpty
            || source.websiteURL != nil
    }

    var body: some View {
        if hasContent {
            Section {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    if let author = source.author, !author.isEmpty {
                        Text(author)
                            .font(.subheadline.weight(.semibold))
                    }
                    if let summary = source.summary {
                        Text(summary)
                            .font(.callout)
                            .lineLimit(expanded ? nil : 4)
                            .textSelection(.enabled)
                        if summary.count > 200 {
                            Button(expanded ? "Weniger" : "Mehr") { expanded.toggle() }
                                .font(.callout)
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("source.metadata.more")
                        }
                    }
                    SourceFacts(source: source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = source.websiteURL {
                        Link(destination: url) {
                            Label(url.host() ?? url.absoluteString, systemImage: "safari")
                                .lineLimit(1)
                        }
                        .font(.callout)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, Design.Spacing.micro)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("source.metadata")
            }
        }
    }
}

/// Rubriken, Sprache und der Hinweis auf explizite Inhalte in einer Zeile.
struct SourceFacts: View {

    let source: Source

    var body: some View {
        let parts = SourceFacts.parts(for: source)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
        }
    }

    static func parts(for source: Source) -> [String] {
        var parts: [String] = source.categories ?? []
        if let name = languageName(source.language) { parts.append(name) }
        if source.isExplicit == true {
            parts.append(String(localized: "Explizit"))
        }
        return parts
    }

    /// „Deutsch“ statt „de-DE“, in der Sprache der App.
    static func languageName(_ code: String?) -> String? {
        guard let base = code?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              !base.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: base.lowercased())
    }
}

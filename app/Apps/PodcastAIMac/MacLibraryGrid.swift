//
//  MacLibraryGrid.swift
//  PodcastAI (macOS)
//
//  „Meine Podcasts“ als Raster aus Covern. Ein Klick wählt den Podcast in
//  der Seitenleiste, so steht er dort, wo auch alle anderen Abos stehen.
//

import SwiftUI
import PodcastAIKit

struct MacLibraryGrid: View {

    /// Die Rückfrage vor dem Abbestellen stellt `LibraryView`.
    @Binding var pendingRemoval: Source?
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router: MacRouter?

    var body: some View {
        MacPage {
            MacSection(header: MacSectionHeader(
                title: Text("Deine Podcasts"), count: model.sources.count,
                note: Text("Ein Klick öffnet die Folgen eines Podcasts.")
            )) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: Design.Spacing.section)],
                          alignment: .leading, spacing: Design.Spacing.large) {
                    ForEach(model.sources) { source in
                        Button { router?.show(.podcast(source.id)) } label: {
                            MacPodcastCover(source: source)
                        }
                        .buttonStyle(.plain)
                        .help(source.title)
                        .contextMenu { menu(for: source) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for source: Source) -> some View {
        if !source.isSubscribed, source.feedURL != nil {
            Button { Task { await model.subscribeToSource(source) } } label: {
                Label("Abonnieren", systemImage: "plus.circle")
            }
        }
        SourceReloadButton(source: source)
        Button {
            router?.show(.podcast(source.id))
            router?.inspectorMode = .info
            router?.isInspectorPresented = true
        } label: {
            Label("Informationen", systemImage: "info.circle")
        }
        Divider()
        Button(role: .destructive) { pendingRemoval = source } label: {
            if source.isSubscribed {
                Label("Abbestellen und Daten löschen …", systemImage: "minus.circle")
            } else {
                Label("Entfernen und Daten löschen …", systemImage: "minus.circle")
            }
        }
    }
}

/// Cover, Titel und Herausgeber. Beim Überfahren hebt sich die Kachel mit
/// einer ruhigen Fläche ab, ohne Größenänderung.
private struct MacPodcastCover: View {

    let source: Source
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            GeometryReader { proxy in
                EpisodeArtwork(url: source.artworkURL, size: proxy.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 8 : 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let author = source.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !source.isSubscribed {
                    Label("Nicht abonniert", systemImage: "circle.dashed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Design.Spacing.small)
        .background(.quaternary.opacity(hovering ? 0.6 : 0),
                    in: .rect(cornerRadius: Design.Radius.card, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

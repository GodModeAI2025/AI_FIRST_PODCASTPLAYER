//
//  TVLibraryViews.swift
//  PodcastAI (Apple TV)
//
//  Abos als Cover-Raster, Folgenlisten, Neu und Warteschlange.
//
//  Ein Klick auf eine Folge spielt sie: das ist die Handlung, die Regel 1
//  verlangt. Das Kontextmenü (lange drücken) reiht ein, spielt aber nichts.
//

import SwiftUI
import PodcastAIPlayerKit

struct TVShowsView: View {
    let open: () -> Void
    @Environment(PlayerSession.self) private var session

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 48, alignment: .top)]

    var body: some View {
        let shows = session.library.shows
        Group {
            if shows.isEmpty {
                ContentUnavailableView {
                    Label("Keine Abos", systemImage: "square.stack")
                } description: {
                    Text("Abonniere Podcasts auf iPhone, iPad oder Mac. Sie erscheinen hier über iCloud.")
                } actions: {
                    Button("Beispiel ansehen") {
                        Task { await session.startExampleMode() }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 60) {
                        ForEach(shows) { show in
                            NavigationLink(value: show) {
                                VStack(alignment: .leading, spacing: 14) {
                                    PlayerArtwork(url: show.artworkURL, cornerRadius: 12)
                                    Text(show.title)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(show.title))
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 40)
                }
            }
        }
        .navigationDestination(for: Source.self) { show in
            TVEpisodesView(show: show, open: open)
        }
        .task { await session.library.refreshAll() }
    }
}

struct TVEpisodesView: View {
    let show: Source
    let open: () -> Void
    @Environment(PlayerSession.self) private var session
    @State private var items: [PlayerItem] = []
    @State private var refreshing = false

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 20) {
                PlayerArtwork(url: show.artworkURL, cornerRadius: 16)
                    .frame(width: 360, height: 360)
                Text(show.title)
                    .font(.title3.weight(.bold))
                if let summary = show.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                Button {
                    Task { await reload() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
            }
            .frame(width: 400, alignment: .leading)

            List(items) { item in
                TVEpisodeRow(item: item, open: open)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Keine Folgen", systemImage: "waveform")
                }
            }
        }
        .padding(.horizontal, 60)
        // Die Liste bei jeder Änderung durch iCloud, der Feed nur einmal beim
        // Öffnen und auf Wunsch (siehe Uhr).
        .task(id: session.library.changeCount) {
            items = session.library.episodes(for: show)
        }
        .task { await reload() }
    }

    private func reload() async {
        refreshing = true
        _ = try? await session.library.refresh(show)
        items = session.library.episodes(for: show)
        refreshing = false
    }
}

struct TVLatestView: View {
    let open: () -> Void
    @Environment(PlayerSession.self) private var session

    var body: some View {
        List(session.library.latest) { item in
            TVEpisodeRow(item: item, open: open, showsPodcast: true)
        }
        .overlay {
            if session.library.latest.isEmpty {
                ContentUnavailableView("Keine neuen Folgen", systemImage: "sparkles")
            }
        }
        .navigationTitle("Neu")
    }
}

struct TVQueueView: View {
    let open: () -> Void
    @Environment(PlayerSession.self) private var session

    var body: some View {
        let items = session.engine.upNext.items
        List(items) { item in
            Button {
                session.engine.playFromUpNext(item.id)
                open()
            } label: {
                TVEpisodeLabel(item: item, showsPodcast: true)
            }
            .accessibilityHint(Text("Spielt die Folge"))
            .contextMenu {
                Button("Entfernen", systemImage: "minus.circle", role: .destructive) {
                    session.engine.removeFromUpNext(item.id)
                }
                if item.id != items.first?.id {
                    Button("Nach oben", systemImage: "arrow.up") {
                        session.engine.enqueueNext(item)
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nichts in der Warteschlange", systemImage: "list.bullet")
                } description: {
                    Text("Drücke bei einer Folge lange und wähle „Als Nächstes“ oder „Zuletzt“.")
                }
            }
        }
        .navigationTitle("Warteschlange")
    }
}

struct TVEpisodeRow: View {
    let item: PlayerItem
    let open: () -> Void
    var showsPodcast = false
    @Environment(PlayerSession.self) private var session

    var body: some View {
        Button {
            session.play(session.fresh(item))
            open()
        } label: {
            TVEpisodeLabel(item: item, showsPodcast: showsPodcast)
        }
        .disabled(!item.isPlayable)
        .accessibilityHint(Text("Spielt die Folge"))
        .contextMenu {
            Button("Als Nächstes", systemImage: "text.insert") { session.engine.enqueueNext(item) }
            Button("Zuletzt", systemImage: "text.append") { session.engine.enqueue(item) }
        }
    }
}

struct TVEpisodeLabel: View {
    let item: PlayerItem
    var showsPodcast = false

    var body: some View {
        HStack(spacing: 24) {
            PlayerArtwork(url: item.artworkURL, cornerRadius: 8)
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                if showsPodcast {
                    Text(item.showTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    if let date = PlayerFormat.date(item.episode.publishedAt) { Text(date) }
                    if item.declaredSeconds > 0 { Text(PlayerFormat.short(item.declaredSeconds)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    private var progress: Double? {
        guard let resume = item.resume, item.declaredSeconds > 0, resume.seconds > 0 else { return nil }
        let value = resume.seconds / item.declaredSeconds
        return value < 0.98 ? value : nil
    }

    private var spoken: String {
        var parts = [item.title]
        if showsPodcast { parts.insert(item.showTitle, at: 0) }
        if item.declaredSeconds > 0 { parts.append(PlayerFormat.spoken(item.declaredSeconds)) }
        return parts.joined(separator: ", ")
    }
}

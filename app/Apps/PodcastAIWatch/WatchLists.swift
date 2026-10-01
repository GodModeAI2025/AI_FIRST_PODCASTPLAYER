//
//  WatchLists.swift
//  PodcastAI (Apple Watch)
//
//  Abos, Folgenlisten und „Als Nächstes“.
//
//  Ein Tipp auf eine Folge spielt sie: das ist die Handlung, die Regel 1
//  verlangt. Wischen nach links reiht ein oder lädt, spielt aber nichts.
//

import SwiftUI
import PodcastAIPlayerKit

struct WatchShowsView: View {
    @Environment(PlayerSession.self) private var session

    var body: some View {
        let shows = session.library.shows
        Group {
            if shows.isEmpty {
                ContentUnavailableView {
                    Label("Keine Abos", systemImage: "square.stack")
                } description: {
                    Text("Abonniere Podcasts auf iPhone, iPad oder Mac. Sie erscheinen hier über iCloud.")
                }
            } else {
                List(shows) { show in
                    NavigationLink(value: WatchRoute.show(show)) {
                        HStack(spacing: 8) {
                            PlayerArtwork(url: show.artworkURL, cornerRadius: 6)
                                .frame(width: 36, height: 36)
                            Text(show.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Abos")
        .task { await session.library.refreshAll() }
    }
}

struct WatchEpisodesView: View {
    let show: Source
    let open: () -> Void
    @Environment(PlayerSession.self) private var session
    @State private var items: [PlayerItem] = []

    var body: some View {
        List(items) { item in
            WatchEpisodeRow(item: item, open: open)
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Keine Folgen", systemImage: "waveform")
            }
        }
        .navigationTitle(show.title)
        .task(id: session.library.changeCount) {
            items = session.library.episodes(for: show)
            _ = try? await session.library.refresh(show)
            items = session.library.episodes(for: show)
        }
    }
}

struct WatchLatestView: View {
    let open: () -> Void
    @Environment(PlayerSession.self) private var session

    var body: some View {
        List(session.library.latest) { item in
            WatchEpisodeRow(item: item, open: open, showsPodcast: true)
        }
        .overlay {
            if session.library.latest.isEmpty {
                ContentUnavailableView("Keine neuen Folgen", systemImage: "sparkles")
            }
        }
        .navigationTitle("Neu")
    }
}

struct WatchEpisodeRow: View {
    let item: PlayerItem
    let open: () -> Void
    var showsPodcast = false
    @Environment(PlayerSession.self) private var session

    var body: some View {
        Button {
            session.play(session.fresh(item))
            open()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if showsPodcast {
                    Text(item.showTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(3)
                HStack(spacing: 4) {
                    if let date = PlayerFormat.date(item.episode.publishedAt) {
                        Text(date)
                    }
                    if item.declaredSeconds > 0 {
                        Text(PlayerFormat.short(item.declaredSeconds))
                    }
                    Spacer(minLength: 0)
                    statusSymbol
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let progress = progress {
                    ProgressView(value: progress)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!item.isPlayable)
        .swipeActions(edge: .trailing) {
            Button {
                session.engine.enqueueNext(item)
            } label: {
                Label("Als Nächstes", systemImage: "text.insert")
            }
            Button {
                session.engine.enqueue(item)
            } label: {
                Label("Zuletzt", systemImage: "text.append")
            }
            if let downloads = session.downloads {
                switch downloads.status(for: item) {
                case .downloaded:
                    Button(role: .destructive) {
                        downloads.remove(item)
                    } label: {
                        Label("Geladene Datei löschen", systemImage: "trash")
                    }
                case .downloading:
                    EmptyView()
                case .notDownloaded, .failed:
                    Button {
                        downloads.download(item)
                    } label: {
                        Label("Laden", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Text("Spielt die Folge"))
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if let downloads = session.downloads {
            switch downloads.status(for: item) {
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
            case .downloading(let fraction):
                if let fraction { ProgressView(value: fraction).frame(width: 24) } else { ProgressView() }
            case .failed:
                Image(systemName: "exclamationmark.triangle")
            case .notDownloaded:
                EmptyView()
            }
        }
    }

    private var progress: Double? {
        guard let resume = item.resume, item.declaredSeconds > 0, resume.seconds > 0 else { return nil }
        let value = resume.seconds / item.declaredSeconds
        return value < 0.98 ? value : nil
    }

    private var accessibilityText: Text {
        var parts = [item.title]
        if showsPodcast { parts.insert(item.showTitle, at: 0) }
        if item.declaredSeconds > 0 { parts.append(PlayerFormat.spoken(item.declaredSeconds)) }
        if let downloads = session.downloads, downloads.status(for: item) == .downloaded {
            parts.append(String(localized: "geladen"))
        }
        return Text(parts.joined(separator: ", "))
    }
}

struct WatchUpNextView: View {
    let open: () -> Void
    @Environment(PlayerSession.self) private var session

    var body: some View {
        let items = session.engine.upNext.items
        List {
            ForEach(items) { item in
                Button {
                    session.engine.playFromUpNext(item.id)
                    open()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.showTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(item.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(3)
                    }
                }
                .accessibilityHint(Text("Spielt die Folge"))
            }
            .onDelete { offsets in
                for index in offsets { session.engine.removeFromUpNext(items[index].id) }
            }
            .onMove { source, destination in
                session.engine.moveUpNext(from: source, to: destination)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nichts in der Warteschlange", systemImage: "list.bullet")
                } description: {
                    Text("Wische bei einer Folge nach links und wähle „Als Nächstes“.")
                }
            }
        }
        .navigationTitle("Als Nächstes")
    }
}

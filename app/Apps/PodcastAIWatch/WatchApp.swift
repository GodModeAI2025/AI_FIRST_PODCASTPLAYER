//
//  WatchApp.swift
//  PodcastAI (Apple Watch)
//
//  Ein reiner Podcast-Player: Abos, Folgen, Wiedergabe, Als Nächstes,
//  Schlaf-Timer, Tempo, Kapitel, Laden für unterwegs. Keine KI. Die
//  Bibliothek kommt über iCloud vom iPhone, der Ton läuft auch ohne iPhone.
//
//  Regel 1: Nichts spielt von selbst. Die App füllt beim Start nur Listen;
//  Ton beginnt mit einem Tipp auf eine Folge oder auf „Wiedergabe“.
//

import SwiftUI
import PodcastAIPlayerKit

@main
struct PodcastAIWatchApp: App {

    @State private var session: PlayerSession

    init() {
        let media = URL.applicationSupportDirectory
            .appending(path: "PodcastAIPlayer/Media", directoryHint: .isDirectory)
        _session = State(initialValue: PlayerSession(platform: "watch", mediaDirectory: media))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(session)
                .task { await session.start() }
        }
    }
}

/// Wohin die Navigation führen kann.
enum WatchRoute: Hashable {
    case latest
    case shows
    case show(Source)
    case upNext
    case nowPlaying
    case chapters
    case sleepTimer
}

struct WatchRootView: View {

    @Environment(PlayerSession.self) private var session
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let current = session.engine.current {
                    Section {
                        NavigationLink(value: WatchRoute.nowPlaying) {
                            WatchNowPlayingRow(item: current)
                        }
                    }
                }
                Section {
                    NavigationLink(value: WatchRoute.latest) {
                        Label("Neu", systemImage: "sparkles")
                    }
                    NavigationLink(value: WatchRoute.shows) {
                        Label("Abos", systemImage: "square.stack")
                    }
                    NavigationLink(value: WatchRoute.upNext) {
                        HStack {
                            Label("Als Nächstes", systemImage: "list.bullet")
                            Spacer(minLength: 4)
                            if !session.engine.upNext.isEmpty {
                                Text(session.engine.upNext.items.count.formatted())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if session.library.storage != .synced {
                    Section {
                        Text("Ohne iCloud zeigt die Uhr, was sie zuletzt kannte.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("PodcastAI")
            #if DEBUG
            .task { await openDebugRoute() }
            #endif
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .latest: WatchLatestView(open: openNowPlaying)
                case .shows: WatchShowsView()
                case .show(let show): WatchEpisodesView(show: show, open: openNowPlaying)
                case .upNext: WatchUpNextView(open: openNowPlaying)
                case .nowPlaying: WatchNowPlayingView()
                case .chapters: WatchChaptersView()
                case .sleepTimer: WatchSleepTimerView()
                }
            }
        }
    }

    #if DEBUG
    /// Nur Debug, für Bilder im Simulator: `-player-demo -watch-route latest`
    /// öffnet die Ansicht. „nowPlaying“ wählt die erste Beispielfolge an. Die
    /// Adresse der Beispielfolgen gibt es nicht, es erklingt nichts.
    private func openDebugRoute() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-watch-route"), flag + 1 < arguments.count else { return }
        try? await Task.sleep(for: .seconds(1))
        switch arguments[flag + 1] {
        case "latest": path = [.latest]
        case "shows": path = [.shows]
        case "show":
            if let show = session.library.shows.first { path = [.shows, .show(show)] }
        case "upNext":
            if let item = session.library.latest.first { session.engine.enqueue(item) }
            path = [.upNext]
        case "sleepTimer": path = [.nowPlaying, .sleepTimer]
        case "nowPlaying":
            if let item = session.library.latest.first { session.play(item) }
            path = [.nowPlaying]
        default: break
        }
    }
    #endif

    private func openNowPlaying() {
        if path.last != .nowPlaying { path.append(.nowPlaying) }
    }
}

/// Die Zeile „läuft gerade“ oben in der Liste.
struct WatchNowPlayingRow: View {
    let item: PlayerItem
    @Environment(PlayerSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            PlayerArtwork(url: item.artworkURL, cornerRadius: 6)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.engine.isPlaying ? "Läuft" : "Wiedergabe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

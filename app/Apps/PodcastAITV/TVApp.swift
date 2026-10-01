//
//  TVApp.swift
//  PodcastAI (Apple TV)
//
//  Ein reiner Podcast-Player: Abos, Neu, Warteschlange, Wiedergabe. Keine KI.
//  Die Bibliothek kommt über iCloud von iPhone, iPad und Mac, der Ton wird
//  gestreamt.
//
//  Regel 1: Nichts spielt von selbst. Die App füllt beim Start nur Listen;
//  Ton beginnt mit einem Klick auf eine Folge, auf „Wiedergabe“ oder mit der
//  Wiedergabetaste der Fernbedienung bei einer geladenen Folge.
//
//  Oberfläche: Tabs mit `.sidebarAdaptable` (oben, einklappbar zur
//  Seitenleiste), Cover als fokussierbare Karten, alles mit Systemfarben, damit
//  es im dunklen Modus wie im hellen trägt.
//

import SwiftUI
import PodcastAIPlayerKit

@main
struct PodcastAITVApp: App {

    @State private var session: PlayerSession

    init() {
        // Apple TV streamt nur: keine Downloads, kein Medienordner.
        _session = State(initialValue: PlayerSession(platform: "tv", mediaDirectory: nil))
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(session)
                .task { await session.start() }
        }
    }
}

struct TVRootView: View {

    @Environment(PlayerSession.self) private var session
    @State private var selection: Area = Self.initialArea

    /// Nicht `Tab` genannt: das verdeckte `SwiftUI.Tab`.
    enum Area: Hashable {
        case shows, latest, queue, nowPlaying
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Abos", systemImage: "square.stack", value: Area.shows) {
                NavigationStack { TVShowsView(open: openNowPlaying) }
            }
            Tab("Neu", systemImage: "sparkles", value: Area.latest) {
                NavigationStack { TVLatestView(open: openNowPlaying) }
            }
            Tab("Warteschlange", systemImage: "list.bullet", value: Area.queue) {
                NavigationStack { TVQueueView(open: openNowPlaying) }
            }
            Tab("Wiedergabe", systemImage: "play.circle", value: Area.nowPlaying) {
                TVNowPlayingView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private static var initialArea: Area {
        #if DEBUG
        // Nur für Bildschirmfotos im Simulator.
        if let value = UserDefaults.standard.string(forKey: "tv-area") {
            switch value {
            case "latest": return .latest
            case "queue": return .queue
            case "nowPlaying": return .nowPlaying
            default: break
            }
        }
        #endif
        return .shows
    }

    private func openNowPlaying() {
        selection = .nowPlaying
    }
}

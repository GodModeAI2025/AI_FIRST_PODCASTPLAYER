//
//  PodcastAIMacApp.swift
//  PodcastAI (macOS)
//
//  Der Mac ist kein großes iPhone. Hier liegt der Schwerpunkt auf großen
//  Beständen, mehreren Quellen nebeneinander, Recherche und Export —
//  Seitenleiste, Inhalt, Inspektor, echte Menübefehle.
//

import SwiftUI
import PodcastAIKit

@main
struct PodcastAIMacApp: App {

    @State private var model: AppModel

    init() {
        let container = (try? LibraryStore.makeContainer())
            ?? (try! LibraryStore.makeContainer(inMemory: true))
        _model = State(initialValue: AppModel(store: LibraryStore(modelContainer: container)))
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(model)
                .task { await model.load() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quelle hinzufügen …") { }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Alle Feeds aktualisieren") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Wiedergabe stoppen") { model.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        // Fenster schließen und App beenden sind verschiedene Zustände:
        // eine laufende Analyse überlebt das geschlossene Fenster.
        Settings { MacSettingsView().environment(model) }
    }
}

struct MacRootView: View {

    @Environment(AppModel.self) private var model
    @State private var section: Section? = .forYou

    enum Section: Hashable, CaseIterable, Identifiable {
        case forYou, feeds, chat, library, knowledge, interests, perspective, trails, player
        var id: Self { self }

        var label: String {
            switch self {
            case .forYou: "Für dich"
            case .feeds: "Meine Feeds"
            case .chat: "Fragen"
            case .library: "Mediathek"
            case .knowledge: "Wissen"
            case .interests: "Interessen"
            case .perspective: "Gegenpositionen"
            case .trails: "Wissenslandkarten"
            case .player: "Wiedergabe"
            }
        }

        var symbol: String {
            switch self {
            case .forYou: "sparkles"
            case .feeds: "waveform.circle"
            case .chat: "text.bubble"
            case .library: "books.vertical"
            case .knowledge: "brain"
            case .interests: "target"
            case .perspective: "arrow.left.arrow.right"
            case .trails: "map"
            case .player: "play.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.label, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            NavigationStack {
                switch section {
                case .forYou: ForYouView()
                case .feeds: SmartFeedListView()
                case .chat: ChatView()
                case .library: LibraryView()
                case .knowledge: KnowledgeView()
                case .interests: InterestsView()
                case .perspective: CounterpointView()
                case .trails: TrailListView()
                case .player, .none: FocusPlayerView()
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshAll() } } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let activity = model.activity {
                Text(activity)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }
}

struct MacSettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Form {
                LabeledContent("Auf diesem Gerät") {
                    Text(statusText(model.modelStatus.onDevice))
                }
                LabeledContent("Private Cloud Compute") {
                    Text(statusText(model.modelStatus.privateCloudCompute))
                }
                Text("PodcastAI nutzt ausschließlich Apple-Modelle. Ist eine Stufe nicht "
                     + "verfügbar, fehlt die Funktion — es wird kein anderer Anbieter "
                     + "eingesetzt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Intelligenz", systemImage: "sparkles") }
            .frame(width: 420)

            Form {
                SpotlightSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Datenschutz", systemImage: "hand.raised") }
            .frame(width: 420)
        }
        .frame(minHeight: 220)
    }

    private func statusText(_ availability: ModelAvailability) -> String {
        switch availability {
        case .available: "Verfügbar"
        case .unavailable(let reason): reason.message
        }
    }
}

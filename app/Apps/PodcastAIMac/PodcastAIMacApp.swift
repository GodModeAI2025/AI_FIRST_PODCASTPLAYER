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
        let opened = AppBootstrap.openStore()
        let model = AppModel(store: LibraryStore.make(container: opened.container))
        model.syncDescription = opened.description
        _model = State(initialValue: model)
        // Auf dem Mac gibt es keinen BGTaskScheduler, aber die
        // Intent-Abhängigkeit muss auch hier stehen: Kurzbefehle laufen auf
        // beiden Plattformen.
        AppBootstrap.start(with: model)
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(model)
                .task {
                    await model.ensureLoaded()
                    model.observeRemoteChanges()
                }
                .frame(minWidth: 900, minHeight: 560)
                .sheet(isPresented: Binding(
                    get: { model.isAddingSource },
                    set: { model.isAddingSource = $0 }
                )) {
                    AddSourceSheet()
                        .environment(model)
                }
                .appFeedback()
                .opensSpotlightResults()
                // Zuletzt, damit auch appFeedback das Modell sieht.
                .environment(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                // War ein leerer Block: ein Menüpunkt, der nichts tut, ist
                // schlechter als keiner.
                Button("Quelle hinzufügen …") { model.isAddingSource = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Alle Feeds aktualisieren") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Wiedergabe stoppen") {
                    model.stopPlayback()
                    model.episodePlayer.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                // Derselbe Weg wie die Medientasten: läuft ein Fokus-Plan,
                // hält er an, statt der Folge Platz zu machen.
                Button("Abspielen/Pause") { model.episodePlayer.toggleActivePlayback() }
                    .disabled(model.episodePlayer.episode == nil && model.playerPlan == nil)
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
    @State private var showingOnboarding = OnboardingView.shouldShow

    enum Section: Hashable, CaseIterable, Identifiable {
        case forYou, feeds, chat, library, queue, knowledge, interests, perspective, trails, player, help
        var id: Self { self }

        var label: String {
            switch self {
            case .forYou: "Für dich"
            case .feeds: "Themen"
            case .chat: "Suchen und fragen"
            case .library: "Mediathek"
            case .queue: "Warteschlange"
            case .knowledge: "Wissen"
            case .interests: "Interessen"
            case .perspective: "Gegenpositionen"
            case .trails: "Wissenslandkarten"
            case .player: "Wiedergabe"
            case .help: "So funktioniert's"
            }
        }

        var symbol: String {
            switch self {
            case .forYou: "sparkles"
            case .feeds: "waveform.circle"
            case .chat: "text.bubble"
            case .library: "books.vertical"
            case .queue: "list.bullet"
            case .knowledge: "brain"
            case .interests: "target"
            case .perspective: "arrow.left.arrow.right"
            case .trails: "map"
            case .player: "play.circle"
            case .help: "questionmark.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                // Gruppiert statt einer langen Liste: Hören, Sammeln,
                // Profil. Eine Seitenleiste verträgt mehr Einträge als eine
                // Tab Bar, aber nicht beliebig viele ohne Ordnung.
                SwiftUI.Section("Hören") {
                    ForEach([Section.forYou, .feeds, .library, .queue, .player]) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                SwiftUI.Section("Wissen") {
                    ForEach([Section.chat, .knowledge, .trails, .perspective]) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                SwiftUI.Section("Profil") {
                    ForEach([Section.interests, .help]) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack {
                switch section {
                case .forYou: ForYouView()
                case .feeds: SmartFeedListView()
                case .chat: ChatView()
                case .library: LibraryView()
                case .queue: QueueView()
                case .help: HelpView()
                case .knowledge: KnowledgeView()
                case .interests: InterestsView()
                case .perspective: CounterpointView()
                case .trails: TrailListView()
                case .player, .none: FocusPlayerView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    // Über dem Mini-Player statt als Overlay darauf, sonst
                    // liegt die Zeile auf „Player öffnen“.
                    if let activity = model.activity {
                        Button { section = .queue } label: {
                            Text(activity)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, Design.Spacing.control).padding(.vertical, Design.Spacing.small)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.horizontal, Design.Spacing.standard)
                        .padding(.bottom, Design.Spacing.small)
                        .accessibilityHint("Öffnet die Warteschlange")
                    }
                    if model.episodePlayer.episode != nil {
                        EpisodeMiniBar()
                            .padding(.vertical, Design.Spacing.small)
                            .background(.bar)
                    }
                }
            }
        }
        .autoRefresh()
        .environment(\.openQueue, { section = .queue })
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView().environment(model).frame(minWidth: 480, minHeight: 620)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshAll() } } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Alle Feeds aktualisieren")
            }
        }
    }
}

struct MacSettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            // Dieselben Abschnitte wie auf iOS. Zwei Fassungen desselben
            // Schalters driften — und gedriftet wäre er genau dort, wo es
            // um Einwilligung geht.
            Form {
                IntelligenceSettingsSection()
                AutomaticAnalysisSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Intelligenz", systemImage: "sparkles") }
            .frame(width: 420)

            Form {
                SyncSettingsSection()
                StorageSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Daten", systemImage: "icloud") }
            .frame(width: 420)

            Form {
                LearningSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Lernen", systemImage: "target") }
            .frame(width: 420)

            NavigationStack {
                Form {
                    LegalSettingsSection()
                }
                .formStyle(.grouped)
            }
            .tabItem { Label("Rechtliches", systemImage: "building.2") }
            .frame(width: 420, height: 420)

            Form {
                SpotlightSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Datenschutz", systemImage: "hand.raised") }
            .frame(width: 420)

            // Der Agentenzugang hatte keinen Schalter — und damit keine
            // Möglichkeit, ihn einzuschalten oder nachzulesen.
            MCPSettingsView()
                .tabItem { Label("Agenten", systemImage: "terminal") }
                .frame(width: 480)
        }
        .frame(minHeight: 220)
    }
}


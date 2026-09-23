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

/// Gestartet von `MacMain`, nicht mit `@main`: mit `--mcp` startet statt
/// der App der Agentenzugang.
struct PodcastAIMacApp: App {

    @State private var model: AppModel
    @State private var startupIssue: StartupIssue?
    @State private var windows = MacWindows()
    /// Ein Zugang für die ganze App. Die Einstellungen vergeben die
    /// Freigabe, der Prozess, den ein Agent startet, liest sie.
    private let mcpAccess: MCPAccess

    init() {
        let opened = AppBootstrap.openStore()
        let model = AppModel(store: LibraryStore.make(container: opened.container))
        model.syncDescription = opened.description
        _model = State(initialValue: model)
        _startupIssue = State(initialValue: StartupIssue(opened))
        mcpAccess = MCPAccess(store: model.store)
        // Auf dem Mac gibt es keinen BGTaskScheduler, aber die
        // Intent-Abhängigkeit muss auch hier stehen: Kurzbefehle laufen auf
        // beiden Plattformen.
        AppBootstrap.start(with: model)
        // Laden und Takt gehören der App, nicht einem Fenster. Jedes neue
        // Fenster lud sonst alles noch einmal, und mit dem letzten Fenster
        // endete die automatische Aktualisierung, obwohl die App weiterlief.
        Task {
            await model.ensureLoaded()
            model.observeRemoteChanges()
            await AutoRefresh.run(for: model)
        }
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(startupIssue: $startupIssue)
                .frame(minWidth: 900, minHeight: 560)
                .environment(windows)
                .environment(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                // War ein leerer Block: ein Menüpunkt, der nichts tut, ist
                // schlechter als keiner.
                AddSourceMenuItem()
                Button("Alle Podcasts aktualisieren") {
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
        Settings { MacSettingsView(mcpAccess: mcpAccess).environment(model) }
    }
}

/// „Podcast hinzufügen …“ öffnet das Blatt im Fenster, das vorn ist, nicht
/// in allen Fenstern zugleich.
private struct AddSourceMenuItem: View {

    @FocusedBinding(\.isAddingSource) private var isAddingSource

    var body: some View {
        Button("Podcast hinzufügen …") { isAddingSource = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(isAddingSource == nil)
    }
}

extension FocusedValues {
    /// „Podcast hinzufügen“ im vorderen Fenster.
    @Entry var isAddingSource: Binding<Bool>?
}

/// Welche Fenster offen sind.
///
/// Was die ganze App betrifft, zeigt nur eines davon: Fehlermeldung,
/// Abschlusskarte, Hinweis vom Start. Hing das an jedem Fenster, erschien
/// es in jedem, und wer es in einem schloss, schloss es in allen.
@MainActor
@Observable
final class MacWindows {

    private(set) var open: [UUID] = []

    /// Das älteste Fenster, das noch offen ist.
    var presenter: UUID? { open.first }

    func opened(_ id: UUID) {
        if !open.contains(id) { open.append(id) }
    }

    func closed(_ id: UUID) {
        open.removeAll { $0 == id }
    }
}

struct MacRootView: View {

    @Binding var startupIssue: StartupIssue?
    @Environment(AppModel.self) private var model
    @Environment(MacWindows.self) private var windows
    @State private var section: Section? = .forYou
    @State private var showingOnboarding = OnboardingView.shouldShow
    @State private var isAddingSource = false
    @State private var windowID = UUID()
    /// „Zeig es mir“ aus der Hilfe: steigt die Zahl, baut der Inhalt seinen
    /// Stapel neu auf. Sonst läge die Seite aus der Hilfe über dem Ziel.
    @State private var helpJumps = 0

    /// Zeigt dieses Fenster, was die ganze App betrifft?
    private var isPresenter: Bool { windows.presenter == windowID }

    /// Unter „Wiedergabe“ die laufende Folge, wenn kein Fokus-Plan läuft.
    /// Der Plan hat Vorrang, wie in der Leiste auf iOS.
    private var showsEpisodePlayer: Bool {
        (model.playerPlan?.isEmpty ?? true) && model.episodePlayer.episode != nil
    }

    enum Section: Hashable, CaseIterable, Identifiable {
        case forYou, feeds, chat, library, queue, knowledge, interests, perspective, trails, player, help
        var id: Self { self }

        /// Dieselben Namen wie die Tabs auf iOS, damit Hinweise wie
        /// „Meine Podcasts › Plus“ auf beiden Geräten stimmen.
        var label: String {
            switch self {
            case .forYou: String(localized: "Für dich")
            case .feeds: String(localized: "Themen-Updates")
            case .chat: String(localized: "Chat")
            case .library: String(localized: "Meine Podcasts")
            case .queue: String(localized: "Warteschlange")
            case .knowledge: String(localized: "Gemerkte Stellen")
            case .interests: String(localized: "Interessen")
            case .perspective: String(localized: "Gegenpositionen")
            case .trails: String(localized: "Gesicherte Antworten")
            case .player: String(localized: "Wiedergabe")
            case .help: String(localized: "So funktioniert's")
            }
        }

        var symbol: String {
            switch self {
            case .forYou: "sparkles"
            case .feeds: "waveform.circle"
            case .chat: "bubble.left.and.bubble.right"
            case .library: "books.vertical"
            case .queue: "list.bullet"
            case .knowledge: "bookmark"
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
                // Gruppiert statt einer langen Liste: Hören, Wissen, Hilfe.
                // Eine Seitenleiste verträgt mehr Einträge als eine Tab Bar,
                // aber nicht beliebig viele ohne Ordnung. „Wissen“ enthält
                // dieselben Einträge wie der Reiter auf iOS, damit Hinweise
                // wie „Wissen › Interessen“ auf beiden Geräten stimmen.
                SwiftUI.Section("Hören") {
                    ForEach([Section.forYou, .feeds, .library, .queue, .player]) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                SwiftUI.Section("Wissen") {
                    ForEach([Section.chat, .knowledge, .trails, .perspective, .interests]) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                SwiftUI.Section("Hilfe") {
                    ForEach([Section.help]) { item in
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
                case .player, .none:
                    // Auch eine ganze Folge ist Wiedergabe. Sonst stand hier
                    // „Nichts wird abgespielt“, während der Ton lief.
                    if showsEpisodePlayer {
                        EpisodePlayerView(isEmbedded: true)
                    } else {
                        FocusPlayerView()
                    }
                }
            }
            .id(helpJumps)
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
                    if model.episodePlayer.episode != nil
                        && !(showsEpisodePlayer && (section == .player || section == nil)) {
                        EpisodeMiniBar()
                            .padding(.vertical, Design.Spacing.small)
                            .background(.bar)
                    }
                }
            }
        }
        .autoRefresh()
        .spotlightPassages()
        .environment(\.openQueue, { section = .queue })
        .environment(\.showInApp, ShowInAppAction { jump in show(jump) })
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView().sheetFeedback().environment(model).frame(minWidth: 480, minHeight: 620)
        }
        .sheet(isPresented: $isAddingSource) {
            AddSourceSheet()
                .sheetFeedback()
                .environment(model)
        }
        .focusedSceneValue(\.isAddingSource, $isAddingSource)
        // Nur ein Fenster meldet, was die ganze App betrifft. Die Meldungen
        // hängen an einer leeren Ansicht im Hintergrund, damit ein Wechsel
        // des meldenden Fensters den Inhalt nicht neu aufbaut.
        .background {
            if isPresenter {
                Color.clear
                    .startupIssueAlert($startupIssue)
                    .appFeedback()
            }
        }
        .onAppear { windows.opened(windowID) }
        .onDisappear { windows.closed(windowID) }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshAll() } } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Alle Podcasts aktualisieren")
            }
        }
    }

    // MARK: „Zeig es mir“ aus der Hilfe

    /// Wählt den Eintrag in der Seitenleiste, den die Hilfe zeigen will.
    /// Blatt, Einstellungsfenster und Datenschutz öffnet die Hilfe selbst.
    private func show(_ jump: HelpJump) {
        let target: Section
        switch jump {
        case .library: target = .library
        case .queue: target = .queue
        case .chat: target = .chat
        case .topicUpdates: target = .feeds
        case .highlights: target = .knowledge
        case .trails: target = .trails
        case .counterpoints: target = .perspective
        case .interests: target = .interests
        case .addPodcast, .settings, .privacy: return
        }
        helpJumps += 1
        section = target
    }
}

struct MacSettingsView: View {

    let mcpAccess: MCPAccess
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
            MCPSettingsView(access: mcpAccess)
                .tabItem { Label("Agenten", systemImage: "terminal") }
                .frame(width: 480)
        }
        .frame(minHeight: 220)
    }
}


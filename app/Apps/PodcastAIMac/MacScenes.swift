//
//  MacScenes.swift
//  PodcastAI (macOS)
//
//  Der Mac ist kein großes iPhone. Hier liegt der Schwerpunkt auf großen
//  Beständen, mehreren Quellen nebeneinander, Recherche und Export:
//  Seitenleiste, Inhalt, Inspektor, echte Menübefehle.
//

import SwiftUI
import PodcastAIKit

/// Kennungen der Fenster, die `openWindow` öffnet.
enum MacSceneID {
    static let nowPlaying = "nowPlaying"
    static let processing = "processing"
}

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
                .frame(minWidth: 1000, minHeight: 640)
                .environment(windows)
                .environment(model)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { MacCommands(model: model) }

        // Der große Player. Öffnen und Wiederherstellen starten nichts.
        Window("Wiedergabe", id: MacSceneID.nowPlaying) {
            MacNowPlayingWindow()
                .environment(model)
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentMinSize)

        // Transkripte, Fakten und Apple Intelligence, hinter dem
        // Aktivitätssymbol unter „Alle anzeigen …“.
        Window("Verarbeitung", id: MacSceneID.processing) {
            MacProcessingWindow()
                .environment(model)
        }
        .defaultSize(width: 560, height: 640)

        // Fenster schließen und App beenden sind verschiedene Zustände:
        // eine laufende Analyse überlebt das geschlossene Fenster.
        Settings { MacSettingsView(mcpAccess: mcpAccess).environment(model) }
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
/// es in jedem, und wer es in einem schloss, schloss es in allen. Die
/// Fenster „Wiedergabe“ und „Verarbeitung“ melden sich hier nicht an.
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

//
//  MacCommands.swift
//  PodcastAI (macOS)
//
//  Die Menüleiste. Jeder Befehl wirkt auf das vordere Fenster, über
//  `FocusedValues`. Abspielen gibt es nur hier unter „Steuerung“, nie als
//  Folge einer Auswahl.
//

import SwiftUI
import AppKit
import PodcastAIKit

/// „Exportieren …“ der Seite, die vorn ist.
struct ExportAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

extension FocusedValues {
    /// Der Reiter der Folge, die vorn ist.
    @Entry var episodeSection: Binding<EpisodeDetailView.Section>?
    @Entry var exportAction: ExportAction?
}

struct MacCommands: Commands {

    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()
        TextEditingCommands()

        CommandGroup(after: .newItem) {
            FileMenuItems(model: model)
        }
        CommandGroup(before: .sidebar) {
            ViewMenuItems()
        }
        CommandMenu("Steuerung") {
            PlaybackMenuItems(model: model)
        }
        CommandMenu("Folge") {
            EpisodeMenuItems()
        }
        CommandGroup(replacing: .help) {
            HelpMenuItem()
        }
    }
}

// MARK: - Ablage

private struct FileMenuItems: View {

    let model: AppModel
    @FocusedBinding(\.isAddingSource) private var isAddingSource
    @FocusedValue(\.exportAction) private var exportAction

    var body: some View {
        Button("Podcast hinzufügen …") { isAddingSource = true }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(isAddingSource == nil)
        Divider()
        Button("Exportieren …") { exportAction?() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportAction == nil)
        Divider()
        Button("Alle Podcasts aktualisieren") {
            Task { await model.refreshAll(byUser: true) }
        }
        .keyboardShortcut("r", modifiers: .command)
    }
}

// MARK: - Darstellung

private struct ViewMenuItems: View {

    @FocusedValue(\.router) private var router
    @FocusedBinding(\.episodeSection) private var episodeSection

    var body: some View {
        ForEach(Array(SidebarItem.numbered.enumerated()), id: \.offset) { index, item in
            Button(item.label) { router?.show(item) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(router == nil)
        }
        Divider()
        ForEach(Array(EpisodeDetailView.Section.allCases.enumerated()), id: \.offset) { index, section in
            Button(section.title) { episodeSection = section }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(episodeSection == nil)
        }
        Divider()
        Button("Informationen") { router?.toggleInspector(.info) }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(router == nil)
        Button("Als Nächstes") { router?.toggleInspector(.upNext) }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(router == nil)
        Divider()
    }
}

// MARK: - Steuerung

private struct PlaybackMenuItems: View {

    let model: AppModel
    @FocusedValue(\.router) private var router
    @FocusedValue(\.playSelection) private var playSelection
    @FocusedValue(\.momentNote) private var momentNote
    @Environment(\.openWindow) private var openWindow

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        let state = NowPlayingState(model: model)
        // Derselbe Weg wie die Medientasten: läuft ein Fokus-Plan, hält er
        // an, statt der Folge Platz zu machen.
        Button(player.isPlayingOrStarting || (state.isPlan && !isPlanPaused) ? "Pause" : "Abspielen") {
            // Steht der Cursor in einem Textfeld, gehört die Leertaste dem Text.
            if MacTextInput.insertSpaceIfEditing() { return }
            player.toggleActivePlayback()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(state.isIdle)
        Button("Auswahl abspielen") { playSelection?() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(playSelection == nil)
        Divider()
        if state.isPlan {
            Button("Nächste Stelle") { model.skipSegment() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        } else {
            Button("\(player.skipBackward) s zurück") { player.skipBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(state.isIdle)
            Button("\(player.skipForward) s vor") { player.skipAhead() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(state.isIdle)
            Button("Vorheriges Kapitel") {
                if MacTextInput.forward(#selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))) { return }
                player.previousChapter()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(player.chapters.isEmpty)
            Button("Nächstes Kapitel") {
                if MacTextInput.forward(#selector(NSResponder.moveToEndOfLineAndModifySelection(_:))) { return }
                player.nextChapter()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(player.nextChapterStart == nil)
        }
        Divider()
        Menu("Geschwindigkeit") { MacRatePicker(player: player) }
            .disabled(player.episode == nil)
        Menu("Schlaf-Timer") { MacSleepTimerPicker(player: player) }
            .disabled(player.episode == nil)
        Divider()
        Button("Moment merken") { momentNote?() }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(momentNote == nil)
        Button("Aktuelle Folge anzeigen") {
            if let episode = player.episode { router?.push(.episode(episode)) }
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(player.episode == nil || router == nil)
        Button("Wiedergabe-Fenster") { openWindow(id: MacSceneID.nowPlaying) }
            .keyboardShortcut("p", modifiers: [.command, .option])
        Divider()
        Button("Wiedergabe stoppen") {
            model.stopPlayback()
            model.episodePlayer.stop()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(state.isIdle)
        Divider()
        Menu("Verarbeitung") {
            // Die Menüleiste hat kein AppModel in der Umgebung, deshalb
            // nicht `QueuePauseButton`.
            if model.queuePaused {
                Button("Fortsetzen") { model.resumeQueue() }
            } else {
                Button("Pausieren") { model.pauseQueue() }
            }
            Button("Alle anzeigen …") { openWindow(id: MacSceneID.processing) }
        }
    }

    private var isPlanPaused: Bool {
        if case .paused = model.playerState { true } else { false }
    }
}

// MARK: - Folge

/// Wirkt auf die Folgen, die in der Tabelle des vorderen Fensters
/// ausgewählt sind. „Audio entfernen“ lässt die Daten stehen, „Folge
/// löschen …“ fragt vorher.
private struct EpisodeMenuItems: View {

    @FocusedValue(\.episodeActions) private var actions

    var body: some View {
        Button("Öffnen") { actions?.open?() }
            .disabled(actions?.open == nil)
        Divider()
        Button("Als Nächstes hören") { actions?.playNext?() }
            .disabled(actions?.playNext == nil)
        Button("Transkript erstellen") { actions?.analyze?() }
            .disabled(actions?.analyze == nil)
        Button("Laden (offline)") { actions?.download?() }
            .disabled(actions?.download == nil)
        Button("Audio entfernen, Daten behalten") { actions?.removeAudio?() }
            .disabled(actions?.removeAudio == nil)
        Divider()
        Button("Folge löschen …") {
            if MacTextInput.forward(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
            actions?.delete()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(actions == nil)
    }
}

// MARK: - Hilfe

private struct HelpMenuItem: View {

    @FocusedValue(\.router) private var router

    var body: some View {
        Button("PodcastAI-Hilfe") { router?.show(.help) }
            .keyboardShortcut("?", modifiers: .command)
            .disabled(router == nil)
    }
}

// MARK: - Textfelder

/// Leertaste und ⇧⌘←/→ sind im Menü Steuerung belegt. Steht der Cursor in
/// einem Textfeld, bekommt das Feld die Taste, wie in Musik.
@MainActor
enum MacTextInput {

    static var focusedTextView: NSTextView? {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else { return nil }
        return view
    }

    /// Gibt die Leertaste an das Textfeld, das den Cursor hat. Der Tastendruck
    /// selbst geht weiter, nicht nur ein Leerzeichen: so wählt eine
    /// Eingabemethode für Japanisch oder Chinesisch damit weiter Zeichen aus.
    static func insertSpaceIfEditing() -> Bool {
        guard let view = focusedTextView else { return false }
        if let event = NSApp.currentEvent, event.type == .keyDown {
            view.keyDown(with: event)
        } else {
            view.insertText(" ", replacementRange: view.selectedRange())
        }
        return true
    }

    /// Gibt einen Befehl an das Textfeld weiter, das den Cursor hat.
    static func forward(_ selector: Selector) -> Bool {
        guard let view = focusedTextView else { return false }
        view.doCommand(by: selector)
        return true
    }
}

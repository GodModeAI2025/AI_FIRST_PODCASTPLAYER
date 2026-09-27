//
//  MacInspector.swift
//  PodcastAI (macOS)
//
//  Der Inspektor rechts neben jeder Seite: „Als Nächstes“ oder die
//  Informationen zu Podcast und Folge. Dazu das Popover hinter dem
//  Aktivitätssymbol und das Fenster „Verarbeitung“.
//
//  Die Warteschlange war auf dem Mac ein Eintrag der Seitenleiste und
//  mischte zwei Dinge: was man hören will und was die App erschließt.
//  Hören steht jetzt neben dem Inhalt, die Arbeit der App hinter dem Symbol.
//

import SwiftUI
import PodcastAIKit

struct MacInspector: View {

    @Environment(MacRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            Picker("Inspektor", selection: $router.inspectorMode) {
                Text("Als Nächstes").tag(InspectorMode.upNext)
                Text("Informationen").tag(InspectorMode.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Spacing.control)
            .padding(.vertical, Design.Spacing.small)
            switch router.inspectorMode {
            case .upNext: MacUpNextList()
            case .info: MacInfoPane(subject: router.infoSubject)
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }
}

// MARK: - Als Nächstes

/// Was läuft und was danach kommt. Eine Auswahl spielt nichts; Abspielen
/// geht über den Knopf beim Überfahren, über das Kontextmenü oder ⌘⏎.
struct MacUpNextList: View {

    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @State private var selection: Set<EpisodeID> = []
    @State private var hovered: EpisodeID?

    var body: some View {
        List(selection: $selection) {
            if let episode = model.episodePlayer.episode {
                Section("Jetzt läuft") {
                    MacQueueRow(episode: episode, detail: model.episodePlayer.currentChapter?.title)
                        .tag(episode.id)
                }
            }
            Section {
                ForEach(model.upNext) { episode in
                    HStack {
                        MacQueueRow(episode: episode, detail: remaining(for: episode))
                        Spacer(minLength: 0)
                        // Nur sichtbar, wenn der Zeiger darüber ist oder die Zeile
                        // ausgewählt ist. Unsichtbar gibt es den Knopf gar nicht,
                        // damit ihn auch die Tastatur nicht unbemerkt drückt.
                        if hovered == episode.id || selection.contains(episode.id) {
                            Button { model.playEpisode(episode) } label: {
                                Label("Abspielen", systemImage: "play.fill")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Abspielen")
                        }
                    }
                    .onHover { inside in
                        if inside { hovered = episode.id } else if hovered == episode.id { hovered = nil }
                    }
                    .tag(episode.id)
                }
                .onMove { model.moveUpNext(from: $0, to: $1) }
            } header: {
                Text("Als Nächstes")
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.upNext.isEmpty && model.episodePlayer.episode == nil {
                ContentUnavailableView {
                    Label("Nichts als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward")
                } description: {
                    Text("Wähle bei einer Folge „Als Nächstes“.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.upNext.isEmpty {
                HStack {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Abspielen") { model.playNextInQueue() }
                        .help("Spielt die erste Folge aus „Als Nächstes“")
                        .accessibilityIdentifier("queue.play")
                }
                .padding(Design.Spacing.control)
            }
        }
        .contextMenu(forSelectionType: EpisodeID.self) { ids in
            if let episode = single(ids) {
                Button("Abspielen") { model.playEpisode(episode) }
                Button("Öffnen") { router.push(.episode(episode)) }
            }
            let queued = ids.filter { id in model.upNext.contains { $0.id == id } }
            if !queued.isEmpty {
                Divider()
                Button("Aus „Als Nächstes“ entfernen") { queued.forEach(model.removeFromUpNext) }
            }
        } primaryAction: { ids in
            if let episode = single(ids) { router.push(.episode(episode)) }
        }
        .onDeleteCommand {
            selection.forEach(model.removeFromUpNext)
            selection = []
        }
        .focusedSceneValue(\.playSelection, playSelectionAction)
    }

    private func single(_ ids: Set<EpisodeID>) -> Episode? {
        guard ids.count == 1, let id = ids.first else { return nil }
        if model.episodePlayer.episode?.id == id { return model.episodePlayer.episode }
        return model.upNext.first { $0.id == id }
    }

    private var playSelectionAction: PlaySelectionAction? {
        guard let episode = single(selection), model.episodePlayer.episode?.id != episode.id else { return nil }
        return PlaySelectionAction { model.playEpisode(episode) }
    }

    private func remaining(for episode: Episode) -> String? {
        guard let length = episode.declaredDuration?.seconds, length > 0 else { return nil }
        let left = max(0, length - model.resumePosition(for: episode))
        return String(localized: "noch \(MediaDuration(seconds: left).shortDescription)")
    }

    /// „3 Folgen · noch 2 Std 5 Min“.
    private var summary: String {
        let count = model.upNext.count
        let episodes = String(AttributedString(localized: "^[\(count) Folge](inflect: true)").characters)
        let remaining = model.upNextRemaining
        guard remaining >= 60 else { return episodes }
        return String(localized: "\(episodes) · noch \(MediaDuration(seconds: remaining).shortDescription)")
    }
}

struct MacQueueRow: View {
    let episode: Episode
    let detail: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            EpisodeArtwork(url: episode.artworkURL,
                           fallback: model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(2)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Informationen

struct MacInfoPane: View {

    let subject: InfoSubject?
    @Environment(AppModel.self) private var model

    var body: some View {
        switch subject {
        case .source(let id):
            SourceDetailView(sourceID: id)
        case .episode(let episode):
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.control) {
                    Text(episode.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    EpisodeMetadataBlock(episode: episode,
                                         source: model.sources.first { $0.id == episode.sourceID })
                }
                .padding(Design.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case nil:
            ContentUnavailableView("Keine Informationen", systemImage: "info.circle",
                                   description: Text("Öffne einen Podcast oder eine Folge."))
        }
    }
}

// MARK: - Aktivität

/// Hinter dem Aktivitätssymbol: was gerade entsteht, die nächsten Folgen
/// und der Weg ins Fenster „Verarbeitung“. Das Popover navigiert nie weg.
struct MacActivityPopover: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            Text("Verarbeitung").font(.headline)
            if model.queuePaused {
                Label(model.queuePausedSummary, systemImage: "pause.circle.fill")
                    .foregroundStyle(.secondary)
            }
            if let current = model.analyzing {
                MacQueueRow(episode: current, detail: stageText(current))
            } else if let activity = model.activity {
                Text(activity).lineLimit(2)
            }
            let next = Array(model.analysisQueue.prefix(5))
            if !next.isEmpty {
                Divider()
                Text("Danach").font(.subheadline).foregroundStyle(.secondary)
                ForEach(next) { episode in
                    Text(episode.title).lineLimit(1)
                }
                if model.analysisQueue.count > next.count {
                    Text("und \(model.analysisQueue.count - next.count) weitere")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                QueuePauseButton()
                Button("Alle abbrechen …", role: .destructive) { confirmingCancel = true }
                    .disabled(model.queueWaitingCount == 0)
                Spacer()
                Button("Alle anzeigen …") {
                    openWindow(id: MacSceneID.processing)
                    dismiss()
                }
            }
        }
        .padding(Design.Spacing.standard)
        .frame(width: 340)
        .queueCancelConfirmation(isPresented: $confirmingCancel)
    }

    private func stageText(_ episode: Episode) -> String {
        guard let stage = model.stages[episode.id] else { return String(localized: "startet") }
        return model.stageDetails[episode.id].map { String(localized: "\(stage.label) · \($0)") } ?? stage.label
    }
}

/// Das Fenster „Verarbeitung“: Transkripte, Fakten und Apple Intelligence.
struct MacProcessingWindow: View {
    var body: some View {
        NavigationStack {
            QueueView(parts: .processing)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

// MARK: - Auswahl abspielen

/// „Auswahl abspielen“ (⌘⏎) im vorderen Fenster. Die einzige Taste, die
/// eine ausgewählte Folge startet.
struct PlaySelectionAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

extension FocusedValues {
    @Entry var playSelection: PlaySelectionAction?
}

//
//  MacEpisodeTable.swift
//  PodcastAI (macOS)
//
//  Die Seite eines Podcasts auf dem Mac: ein Kopf mit Cover und Aktionen,
//  darunter die Folgen als Tabelle mit Mehrfachauswahl. Eine Auswahl spielt
//  nichts. Return oder Doppelklick öffnen die Folge, abgespielt wird über
//  den Knopf beim Überfahren, das Kontextmenü oder ⌘⏎.
//

import SwiftUI
import PodcastAIKit

// MARK: - Kopf

struct MacPodcastHeader<Notices: View, Archive: View>: View {

    let sourceID: SourceID
    /// Die neueste Folge, die sich abspielen lässt.
    let newest: Episode?
    @ViewBuilder let notices: Notices
    @ViewBuilder let archive: Archive
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router: MacRouter?
    @State private var showingSummary = false

    private var source: Source? { model.sources.first { $0.id == sourceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            HStack(alignment: .top, spacing: Design.Spacing.section) {
                EpisodeArtwork(url: source?.artworkURL, size: 140)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text(source?.title ?? "")
                        .font(.title.bold())
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let author = source?.author, !author.isEmpty {
                        Text(author)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if let source {
                        SourceFacts(source: source)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let summary = source?.summary {
                        Text(summary)
                            .lineLimit(3)
                            .frame(maxWidth: Design.Layout.textWidth, alignment: .leading)
                            .textSelection(.enabled)
                        if summary.count > 200 {
                            Button("Mehr") { showingSummary = true }
                                .buttonStyle(.link)
                                .popover(isPresented: $showingSummary, arrowEdge: .bottom) {
                                    ScrollView {
                                        Text(summary)
                                            .textSelection(.enabled)
                                            .padding(Design.Spacing.standard)
                                    }
                                    .frame(width: 420, height: 320)
                                }
                        }
                    }
                    actions
                        .padding(.top, Design.Spacing.micro)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                archive
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                notices
            }
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.vertical, Design.Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Design.Spacing.small) {
            if let newest {
                Button {
                    model.playEpisode(newest)
                } label: {
                    Label("Neueste Folge abspielen", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .help(newest.title)
            }
            if let source, !source.isSubscribed, source.feedURL != nil {
                Button {
                    Task { await model.subscribeToSource(source) }
                } label: {
                    Label("Abonnieren", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            if let source, model.canReload(source) {
                SourceReloadButton(source: source)
                    .buttonStyle(.glass)
            }
            Button {
                router?.inspectorMode = .info
                router?.isInspectorPresented = true
            } label: {
                Label("Informationen", systemImage: "info.circle")
            }
            .buttonStyle(.glass)
            .help("Informationen zu diesem Podcast (⌘I)")
        }
        .controlSize(.large)
    }
}

// MARK: - Tabelle

struct MacEpisodeTable: View {

    let episodes: [Episode]
    @Binding var selection: Set<EpisodeID>
    let open: (Episode) -> Void
    let delete: ([Episode]) -> Void
    let analyze: (Set<EpisodeID>) -> Void
    let canAnalyze: (Episode) -> Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(episodes, selection: $selection) {
            TableColumn(Text(verbatim: "")) { episode in
                MacEpisodeStatusCell(episode: episode)
            }
            .width(28)
            TableColumn("Titel") { episode in
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .fontWeight(model.heardFraction(for: episode) > 0.95 ? .regular : .medium)
                        .lineLimit(2)
                    if let line = descriptionLine(episode) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            TableColumn("Datum") { episode in
                if let published = episode.publishedAt {
                    Text(published, format: .dateTime.day().month(.abbreviated).year())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110, max: 140)
            TableColumn("Dauer") { episode in
                if let duration = episode.declaredDuration {
                    Text(duration.shortDescription)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 60, ideal: 80, max: 100)
            TableColumn("Vorbereitung") { episode in
                MacPreparationCell(episode: episode)
            }
            .width(min: 90, ideal: 120, max: 180)
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: EpisodeID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let episode = single(ids) { open(episode) }
        }
        .onDeleteCommand {
            let chosen = episodes.filter { selection.contains($0.id) }
            if !chosen.isEmpty { delete(chosen) }
        }
        .focusedSceneValue(\.playSelection, playSelection)
        .focusedSceneValue(\.episodeActions, actions)
    }

    private func single(_ ids: Set<EpisodeID>) -> Episode? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return episodes.first { $0.id == id }
    }

    private func descriptionLine(_ episode: Episode) -> String? {
        guard let text = episode.summary ?? ShownotesText.plain(episode.shownotesHTML) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }

    private var playSelection: PlaySelectionAction? {
        guard let episode = single(selection), model.canPlay(episode) else { return nil }
        return PlaySelectionAction { model.playEpisode(episode) }
    }

    /// Die Befehle im Menü „Folge“, für die Auswahl dieser Tabelle.
    private var actions: EpisodeActions? {
        let chosen = episodes.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        let model = model
        let playable = chosen.filter { model.canPlay($0) }
        let analyzable = chosen.filter(canAnalyze)
        let downloadable = chosen.filter(canDownload)
        let local = chosen.filter { model.hasLocalAudio($0) }
        let open = open, analyze = analyze, delete = delete

        var result = EpisodeActions(delete: { delete(chosen) })
        if let episode = single(selection) {
            result.open = { open(episode) }
        }
        if !playable.isEmpty {
            result.playNext = {
                for episode in playable.reversed() { model.addToUpNext(episode) }
            }
        }
        if !analyzable.isEmpty {
            let ids = Set(analyzable.map(\.id))
            result.analyze = { analyze(ids) }
        }
        if !downloadable.isEmpty {
            result.download = {
                for episode in downloadable { Task { await model.downloadForOffline(episode) } }
            }
        }
        if !local.isEmpty {
            result.removeAudio = {
                for episode in local { Task { await model.removeAudio(for: episode) } }
            }
        }
        return result
    }

    private func canDownload(_ episode: Episode) -> Bool {
        episode.audioURL != nil && !model.downloading.contains(episode.id) && !model.hasLocalAudio(episode)
    }

    @ViewBuilder
    private func menu(for ids: Set<EpisodeID>) -> some View {
        let chosen = episodes.filter { ids.contains($0.id) }
        if let episode = single(ids) {
            if model.canPlay(episode) {
                Button { model.playEpisode(episode) } label: { Label("Abspielen", systemImage: "play.fill") }
            } else {
                OpenEpisodeWebButton(episode: episode)
            }
            Button { open(episode) } label: { Label("Öffnen", systemImage: "arrow.forward.circle") }
            Divider()
        }
        if chosen.contains(where: model.canPlay) {
            Button {
                for episode in chosen.reversed() where model.canPlay(episode) { model.addToUpNext(episode) }
            } label: {
                Label("Als Nächstes hören", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                for episode in chosen where model.canPlay(episode) { model.addToUpNext(episode, placement: .last) }
            } label: {
                Label("Ans Ende der Warteschlange", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        if chosen.contains(where: canAnalyze) {
            Button { analyze(ids) } label: {
                Label(chosen.count == 1 ? "Transkript erstellen" : "Transkripte erstellen",
                      systemImage: "waveform.badge.magnifyingglass")
            }
        }
        if !chosen.isEmpty {
            Divider()
        }
        if chosen.contains(where: canDownload) {
            Button {
                for episode in chosen where canDownload(episode) {
                    Task { await model.downloadForOffline(episode) }
                }
            } label: { Label("Laden (offline)", systemImage: "arrow.down.circle") }
        }
        // Nur bei geladener Datei. „Audio entfernen“ lässt alle Daten stehen.
        if chosen.contains(where: model.hasLocalAudio) {
            Button {
                for episode in chosen where model.hasLocalAudio(episode) {
                    Task { await model.removeAudio(for: episode) }
                }
            } label: { Label("Audio entfernen, Daten behalten", systemImage: "arrow.down.circle.dotted") }
        }
        if !chosen.isEmpty {
            Button(role: .destructive) { delete(chosen) } label: {
                Label(chosen.count == 1 ? "Folge löschen …" : "Folgen löschen …", systemImage: "trash")
            }
        }
    }
}

/// Zustand der Folge als Zeichen, nie als Farbpunkt allein. Beim Überfahren
/// steht hier der Abspielknopf.
private struct MacEpisodeStatusCell: View {

    let episode: Episode
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Group {
            if hovering, model.canPlay(episode) {
                Button { model.playEpisode(episode) } label: {
                    Label("Abspielen", systemImage: "play.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Abspielen")
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(label)
                    .accessibilityLabel(label)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var isCurrent: Bool { model.episodePlayer.episode?.id == episode.id }

    private var symbol: String {
        if isCurrent { return model.episodePlayer.isPlaying ? "speaker.wave.2.fill" : "speaker.fill" }
        let heard = model.heardFraction(for: episode)
        if heard > 0.95 { return "checkmark.circle" }
        if heard > 0.02 { return "circle.lefthalf.filled" }
        return "circle"
    }

    private var label: String {
        if isCurrent {
            return model.episodePlayer.isPlaying ? String(localized: "läuft gerade") : String(localized: "pausiert")
        }
        let heard = model.heardFraction(for: episode)
        if heard > 0.95 { return String(localized: "Gehört") }
        if heard > 0.02 { return String(localized: "Angefangen") }
        return String(localized: "Ungehört")
    }
}

/// Transkript und Ton als Zeichen mit Erklärung beim Überfahren.
private struct MacPreparationCell: View {

    let episode: Episode
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            if let stage = model.stages[episode.id] {
                Image(systemName: stage.symbol)
                    .symbolEffect(.pulse, isActive: stage.isRunning)
                    .foregroundStyle(stage == .failed ? Design.Notice.failure.tint : Color.secondary)
                    .help(model.stageDetails[episode.id].map { String(localized: "\(stage.label) · \($0)") }
                          ?? stage.label)
                    .accessibilityLabel(stage.label)
            } else if let waiting = model.stageDetails[episode.id] {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .help(waiting)
                    .accessibilityLabel(waiting)
            }
            if model.downloading.contains(episode.id) {
                Image(systemName: "arrow.down.circle")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.secondary)
                    .help("lädt …")
            } else if model.hasLocalAudio(episode) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Auf dem Gerät, spielt auch ohne Netz")
                    .accessibilityLabel("Auf dem Gerät")
            }
        }
    }
}

// MARK: - Menü „Folge“

/// Was das Menü „Folge“ mit der Auswahl im vorderen Fenster tun kann. Ein
/// fehlender Befehl ist im Menü gesperrt.
struct EpisodeActions {
    var open: (@MainActor () -> Void)?
    var playNext: (@MainActor () -> Void)?
    var analyze: (@MainActor () -> Void)?
    var download: (@MainActor () -> Void)?
    var removeAudio: (@MainActor () -> Void)?
    var delete: @MainActor () -> Void

    init(delete: @escaping @MainActor () -> Void) {
        self.delete = delete
    }
}

extension FocusedValues {
    @Entry var episodeActions: EpisodeActions?
}

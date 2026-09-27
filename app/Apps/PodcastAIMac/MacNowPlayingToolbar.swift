//
//  MacNowPlayingToolbar.swift
//  PodcastAI (macOS)
//
//  Der Player in der Symbolleiste, wie in Musik und Podcasts von Apple:
//  links die Transportknöpfe, in der Mitte die Anzeige mit Titel und
//  Position. Er ersetzt die schmale Leiste am unteren Fensterrand und den
//  Eintrag „Wiedergabe“ in der Seitenleiste.
//
//  Ein Fokus-Plan hat Vorrang vor der Folge, wie auf iOS. Nichts hier
//  startet Ton von selbst: Abspielen gibt es nur über einen Knopf, ein Menü
//  oder eine Taste, und ohne geladene Folge sind die Knöpfe gesperrt.
//

import SwiftUI
import PodcastAIKit

/// Was der Player gerade zeigt.
@MainActor
enum NowPlayingState {
    case idle
    case episode(Episode)
    case plan(ValidatedPlaybackPlan, index: Int, isPaused: Bool)

    init(model: AppModel) {
        if let plan = model.playerPlan, !plan.isEmpty {
            switch model.playerState {
            case .playing(let index), .preparing(let index):
                if index < plan.segments.count {
                    self = .plan(plan, index: index, isPaused: false)
                    return
                }
            case .paused(let index):
                if index < plan.segments.count {
                    self = .plan(plan, index: index, isPaused: true)
                    return
                }
            default:
                break
            }
        }
        if let episode = model.episodePlayer.episode {
            self = .episode(episode)
        } else {
            self = .idle
        }
    }

    var isIdle: Bool {
        if case .idle = self { true } else { false }
    }

    var isPlan: Bool {
        if case .plan = self { true } else { false }
    }
}

// MARK: - Symbolleiste

struct MacNowPlayingToolbar: ToolbarContent {

    /// „Moment merken“ gehört dem Fenster, damit auch ⌘D es öffnet.
    let note: MomentNoteDraft
    @Binding var showingNote: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            MacTransportButtons()
        }
        ToolbarItem(placement: .principal) {
            MacNowPlayingDisplay(note: note, showingNote: $showingNote)
        }
    }
}

/// Zurück, Abspielen/Pause, Vor. Im Fokus-Plan: Abspielen/Pause,
/// „Nächste Stelle“ und Stopp.
struct MacTransportButtons: View {

    @Environment(AppModel.self) private var model

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        let state = NowPlayingState(model: model)
        switch state {
        case .plan(_, _, let isPaused):
            Button { player.toggleActivePlayback() } label: {
                Label(isPaused ? "Fortsetzen" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? "Fortsetzen (Leertaste)" : "Pause (Leertaste)")
            .accessibilityIdentifier("toolbar.playPause")
            Button { model.skipSegment() } label: {
                Label("Nächste Stelle", systemImage: "forward.end.fill")
            }
            .help("Nächste Stelle")
            Button { model.stopPlayback() } label: {
                Label("Wiedergabe stoppen", systemImage: "stop.fill")
            }
            .help("Wiedergabe stoppen (⌘.)")
        case .episode, .idle:
            Button { player.skipBack() } label: {
                Label("\(player.skipBackward) Sekunden zurück", systemImage: "gobackward.\(player.skipBackward)")
            }
            .help("\(player.skipBackward) Sekunden zurück")
            .disabled(state.isIdle)
            Button { player.toggleActivePlayback() } label: {
                Label(player.isPlayingOrStarting ? "Pause" : "Abspielen",
                      systemImage: player.isPlayingOrStarting ? "pause.fill" : "play.fill")
            }
            .help(player.isPlayingOrStarting ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            .disabled(state.isIdle)
            .accessibilityIdentifier("toolbar.playPause")
            Button { player.skipAhead() } label: {
                Label("\(player.skipForward) Sekunden vor", systemImage: "goforward.\(player.skipForward)")
            }
            .help("\(player.skipForward) Sekunden vor")
            .disabled(state.isIdle)
        }
    }
}

/// Die Anzeige in der Mitte der Symbolleiste.
struct MacNowPlayingDisplay: View {

    let note: MomentNoteDraft
    @Binding var showingNote: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        let state = NowPlayingState(model: model)
        HStack(spacing: Design.Spacing.small) {
            display(state)
                .frame(minWidth: 280, idealWidth: 380, maxWidth: 560)
            if case .episode(let episode) = state {
                MacRateMenu(player: player)
                Button {
                    note.begin(in: episode, at: player.currentTime)
                    showingNote = true
                } label: {
                    Label("Moment merken", systemImage: "bookmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Moment merken (⌘D)")
                .popover(isPresented: $showingNote, arrowEdge: .bottom) {
                    MacMomentNotePopover(draft: note, model: model)
                }
            }
        }
    }

    /// „Moment merken“ für das Menü Steuerung, gesetzt vom Fenster. Nur
    /// solange eine Folge geladen ist; ein Fokus-Plan hat seinen eigenen Weg.
    static func momentNoteAction(model: AppModel, note: MomentNoteDraft,
                                 showingNote: Binding<Bool>) -> MomentNoteAction? {
        guard case .episode(let episode) = NowPlayingState(model: model) else { return nil }
        let player = model.episodePlayer
        return MomentNoteAction {
            note.begin(in: episode, at: player.currentTime)
            showingNote.wrappedValue = true
        }
    }

    @ViewBuilder
    private func display(_ state: NowPlayingState) -> some View {
        switch state {
        case .idle:
            Text("Nichts wird abgespielt")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("nowPlaying.idle")
        case .episode(let episode):
            episodeDisplay(episode)
        case .plan(let plan, let index, _):
            planDisplay(plan, index: index)
        }
    }

    private func episodeDisplay(_ episode: Episode) -> some View {
        let source = model.sources.first { $0.id == episode.sourceID }
        return HStack(spacing: Design.Spacing.small) {
            artworkButton(EpisodeArtwork(url: episode.artworkURL, fallback: source?.artworkURL, size: 32))
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine(episode.title, detail: player.currentChapter?.title ?? source?.title)
                    PlaybackScrubber(player: player, layout: .inline)
                }
                .frame(minWidth: 380)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(compactStatus)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Vorheriges Kapitel") { player.previousChapter() }
                .disabled(player.chapters.isEmpty)
            Button("Nächstes Kapitel") { player.nextChapter() }
                .disabled(player.nextChapterStart == nil)
            Divider()
            Button("Wiedergabe-Fenster öffnen") { openWindow(id: MacSceneID.nowPlaying) }
        }
    }

    private func planDisplay(_ plan: ValidatedPlaybackPlan, index: Int) -> some View {
        let segment = plan.segments[index]
        return HStack(spacing: Design.Spacing.small) {
            artworkButton(EpisodeArtwork(url: model.podcastArtworkURL(for: segment), size: 32))
            VStack(alignment: .leading, spacing: 2) {
                titleLine(segment.episodeTitle,
                          detail: String(localized: "\(segment.sourceTitle) · Stelle \(index + 1) von \(plan.segments.count)"))
                ProgressView(value: segmentProgress(segment.range))
                    .controlSize(.mini)
                    .accessibilityLabel("Fortschritt der Stelle")
            }
        }
        .contextMenu {
            Button("Original öffnen") {
                let position = segment.range.contains(model.playerPosition) ? model.playerPosition : segment.range.start
                Task { await model.openOriginal(episodeID: segment.episodeID, at: position) }
            }
            Divider()
            Button("Wiedergabe-Fenster öffnen") { openWindow(id: MacSceneID.nowPlaying) }
        }
    }

    private func titleLine(_ title: String, detail: String?) -> some View {
        HStack(spacing: Design.Spacing.small) {
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func artworkButton(_ artwork: EpisodeArtwork) -> some View {
        Button { openWindow(id: MacSceneID.nowPlaying) } label: { artwork }
            .buttonStyle(.plain)
            .help("Wiedergabe-Fenster öffnen (⌥⌘P)")
            .accessibilityLabel("Wiedergabe-Fenster öffnen")
    }

    /// „Kapitel · 12:03 / 45:10“ für die schmale Anzeige.
    private var compactStatus: String {
        if player.playbackError != nil { return String(localized: "Nicht abspielbar") }
        if player.isBuffering { return String(localized: "lädt …") }
        let time = "\(EpisodePlayerView.format(player.currentTime)) / \(EpisodePlayerView.format(player.duration))"
        guard let chapter = player.currentChapter?.title else { return time }
        return "\(chapter) · \(time)"
    }

    private func segmentProgress(_ range: MediaTimeRange) -> Double {
        let length = Double(range.end.milliseconds - range.start.milliseconds)
        guard length > 0 else { return 0 }
        let done = Double(model.playerPosition.milliseconds - range.start.milliseconds)
        return min(1, max(0, done / length))
    }
}

/// Geschwindigkeit als Menü mit Häkchen.
struct MacRateMenu: View {

    let player: EpisodePlayer

    var body: some View {
        Menu {
            MacRatePicker(player: player)
        } label: {
            Text("\(Double(player.rate).formatted(.number.precision(.fractionLength(1))))×")
                .monospacedDigit()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Geschwindigkeit")
        .accessibilityLabel("Geschwindigkeit")
    }
}

struct MacRatePicker: View {
    let player: EpisodePlayer

    var body: some View {
        Picker("Geschwindigkeit", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
            ForEach(EpisodePlayerView.rates, id: \.self) { rate in
                Text("\(Double(rate).formatted(.number.precision(.fractionLength(1))))×").tag(rate)
            }
        }
        .pickerStyle(.inline)
    }
}

struct MacSleepTimerPicker: View {
    let player: EpisodePlayer

    var body: some View {
        Picker("Schlaf-Timer", selection: Binding(get: { player.sleepTimer },
                                                  set: { player.setSleepTimer($0) })) {
            Text("Aus").tag(EpisodePlayer.SleepTimer?.none)
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Text(Duration.seconds(minutes * 60), format: .units(allowed: [.minutes], width: .wide))
                    .tag(EpisodePlayer.SleepTimer?.some(.minutes(minutes)))
            }
            if !player.chapters.isEmpty {
                Text("Ende des Kapitels").tag(EpisodePlayer.SleepTimer?.some(.endOfChapter))
            }
            Text("Ende der Folge").tag(EpisodePlayer.SleepTimer?.some(.endOfEpisode))
        }
        .pickerStyle(.inline)
    }
}

/// „Moment merken“ als Popover. Schließt es ohne „Abbrechen“, etwa durch
/// einen Klick daneben, wird der Moment mit dem Text gemerkt, der dasteht,
/// wie beim Blatt auf iOS.
struct MacMomentNotePopover: View {

    @Bindable var draft: MomentNoteDraft
    let model: AppModel
    @Environment(\.confirm) private var confirm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            Text("Moment bei \(MediaTime(milliseconds: Int64(draft.position * 1000)).timecode)")
                .font(.headline)
            if let quote = draft.quote {
                Text("„\(quote)“")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            TextField("Was ist dir hier wichtig? (freiwillig)", text: $draft.text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Notiz")
                .accessibilityIdentifier("note.text")
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    draft.discard()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Merken") {
                    draft.save(with: model, confirm: confirm)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("note.save")
            }
        }
        .padding(Design.Spacing.standard)
        .frame(width: 360)
        .task { await draft.locate(with: model) }
        .onDisappear { draft.save(with: model, confirm: confirm) }
    }
}

/// „Moment merken“ aus dem Menü Steuerung, im vorderen Fenster.
struct MomentNoteAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

extension FocusedValues {
    @Entry var momentNote: MomentNoteAction?
}

// MARK: - Fenster „Wiedergabe“

/// Der große Player in einem eigenen Fenster, geöffnet über die Anzeige in
/// der Symbolleiste oder ⌥⌘P. Das Öffnen startet nichts.
struct MacNowPlayingWindow: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            if model.playerPlan?.isEmpty ?? true, model.episodePlayer.episode != nil {
                EpisodePlayerView(isEmbedded: true)
            } else {
                FocusPlayerView()
            }
        }
        .frame(minWidth: 360, minHeight: 520)
    }
}

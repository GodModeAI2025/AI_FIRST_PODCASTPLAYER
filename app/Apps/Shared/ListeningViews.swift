//
//  ListeningViews.swift
//  PodcastAI
//
//  Ganze Folgen hören: Detailansicht mit Cover, Kapiteln und Shownotes,
//  der Player dazu und die Warteschlange, an der man sieht, was als
//  Nächstes gehört und was als Nächstes erschlossen wird.
//

import SwiftUI
import PodcastAIKit

// MARK: - Folge

struct EpisodeDetailView: View {

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Überblick"
        case chapters = "Kapitel"
        case transcript = "Transkript"
        case facts = "Fakten"
        case ask = "Fragen"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .overview: "info.circle"
            case .chapters: "list.bullet"
            case .transcript: "text.alignleft"
            case .facts: "checkmark.seal"
            case .ask: "text.bubble"
            }
        }
    }

    let episode: Episode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .overview
    @State private var passages: [Evidence] = []
    @State private var exported: String?
    @State private var confirmDelete = false
    @State private var hasLocalAudio = false

    private var player: EpisodePlayer { model.episodePlayer }
    private var isCurrent: Bool { player.episode?.id == episode.id }
    /// Der Zustand lebt im Speicher. Nach einem Neustart zeigen die
    /// gespeicherten Stellen, dass die Folge schon erschlossen ist.
    private var stage: ProcessingStage? {
        model.stages[episode.id] ?? (passages.isEmpty ? nil : .evidenceExtracted)
    }
    private var chapters: [Chapter] {
        if isCurrent, !player.chapters.isEmpty { return player.chapters }
        if !episode.publisherChapters.isEmpty { return episode.publisherChapters }
        return model.chapterCache[episode.id] ?? []
    }
    private var facts: [EpisodeFact] { model.facts[episode.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Design.Spacing.standard)
            .padding(.vertical, Design.Spacing.small)
            .accessibilityIdentifier("episode.sections")

            switch section {
            case .overview: overview
            case .chapters: chapterList
            case .transcript: TranscriptSection(episode: episode)
            case .facts: factList
            case .ask:
                VStack(spacing: 0) {
                    askScopeHeader
                    ChatView(scope: .episode(episode.id), fixed: true)
                }
            }
        }
        .navigationTitle(episode.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { actionsMenu } }
        .task(id: model.stages[episode.id]) {
            passages = await model.evidence(forEpisode: episode.id)
            await model.loadFacts(for: episode.id)
        }
        // Neu prüfen, wenn Audio entfernt wurde und wenn sich die Stufe
        // ändert: die Erschliessung lädt die Datei, ohne `mediaStorageChanged`
        // zu erhöhen.
        .task(id: LocalAudioCheck(storage: model.mediaStorageChanged, stage: model.stages[episode.id])) {
            hasLocalAudio = episode.streamMediaVersionID.flatMap { LocalMediaLocator().localFile(for: $0) } != nil
        }
        .task { await model.loadChapters(for: episode) }
        .sheet(item: Binding(get: { exported.map(ExportPreview.init) }, set: { exported = $0?.text })) {
            ExportPreviewSheet(text: $0.text)
        }
        .confirmationDialog("Folge löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Folge und alle Daten löschen", role: .destructive) {
                Task {
                    await model.removeEpisode(episode)
                    dismiss()
                }
            }
        } message: {
            Text("Transkript, Fakten, Belege und der Hörstand dieser Folge werden auf allen Geräten gelöscht. "
                 + "Der Feed legt die Folge nicht wieder an. Deine Notizen bleiben unter Wissen erhalten.")
        }
    }

    private struct LocalAudioCheck: Equatable {
        let storage: Int
        let stage: ProcessingStage?
    }

    /// Im Reiter „Fragen“ ist der Bereich fest und die Bereichsauswahl
    /// fehlt. Diese Zeile sagt, an welche Folge die Fragen gehen.
    private var askScopeHeader: some View {
        Label(episode.title, systemImage: "scope")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Spacing.standard)
            .padding(.bottom, Design.Spacing.small)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fragen an diese Folge: \(episode.title)")
            .accessibilityIdentifier("episode.ask.scope")
    }

    // MARK: Menü

    private var actionsMenu: some View {
        Menu {
            Button {
                Task { exported = await model.exportEpisode(episode) }
            } label: { Label("Exportieren mit Transkript", systemImage: "square.and.arrow.up") }
            Button {
                Task { exported = await model.exportEpisode(episode, includeTranscript: false) }
            } label: { Label("Exportieren ohne Transkript", systemImage: "doc.plaintext") }
            Divider()
            if hasLocalAudio {
                Button {
                    Task { await model.removeAudio(for: episode) }
                } label: { Label("Audio entfernen, Daten behalten", systemImage: "arrow.down.circle.dotted") }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Folge löschen", systemImage: "trash")
            }
        } label: {
            Label("Mehr", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("episode.menu")
    }

    // MARK: Überblick

    private var overview: some View {
        List {
            SwiftUI.Section {
                header
                playControls
            }

            if let stage {
                SwiftUI.Section("Erschliessung") {
                    Label {
                        Text(model.stageDetails[episode.id].map { "\(stage.label) · \($0)" } ?? stage.label)
                    } icon: {
                        Image(systemName: stage.symbol)
                            .symbolEffect(.pulse, isActive: stage.isRunning)
                    }
                    .foregroundStyle(stage == .failed ? .orange : .primary)
                    if hasLocalAudio {
                        Label("Audio liegt auf diesem Gerät", systemImage: "internaldrive")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let detail = model.stageDetails[episode.id] {
                SwiftUI.Section("Erschliessung") { Label(detail, systemImage: "clock") }
            }

            if !facts.isEmpty {
                SwiftUI.Section {
                    ForEach(facts.prefix(3)) { fact in FactRow(fact: fact, episode: episode) }
                    if facts.count > 3 {
                        Button("Alle \(facts.count) Fakten") { section = .facts }
                    }
                } header: {
                    Text("Das Wichtigste")
                }
            }

            let episodeNotes = model.notes(for: episode.id)
            if !episodeNotes.isEmpty {
                SwiftUI.Section("Deine Notizen") {
                    ForEach(episodeNotes) { note in
                        Button { Task { await model.playHighlight(note) } } label: {
                            NoteRow(highlight: note, showsEpisode: false).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !chapters.isEmpty {
                SwiftUI.Section("Kapitel") {
                    ForEach(Array(chapters.prefix(4).enumerated()), id: \.offset) { _, chapter in
                        ChapterRow(chapter: chapter, episode: episode, chapters: chapters)
                    }
                    if chapters.count > 4 {
                        Button("Alle \(chapters.count) Kapitel") { section = .chapters }
                    }
                }
            }

            if let notes = ShownotesText.render(episode.shownotesHTML ?? episode.summary) {
                SwiftUI.Section("Shownotes") {
                    Text(notes)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            EpisodeArtwork(url: episode.artworkURL ?? sourceArtwork, size: 160)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                if let source = model.sources.first(where: { $0.id == episode.sourceID }) {
                    Text(source.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(episode.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(4)
                HStack(spacing: Design.Spacing.small) {
                    if let published = episode.publishedAt { Text(published, style: .date) }
                    if let duration = episode.declaredDuration { Text(duration.shortDescription) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HeardProgress(fraction: model.heardFraction(for: episode))
            }
        }
        .padding(.vertical, Design.Spacing.small)
    }

    private var sourceArtwork: URL? {
        model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL
    }

    private var playControls: some View {
        HStack(spacing: Design.Spacing.small) {
            Button {
                if isCurrent { player.togglePlayPause() } else { model.playEpisode(episode) }
            } label: {
                Label(playLabel, systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("episode.play")

            Button {
                model.addToUpNext(episode)
            } label: {
                Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .disabled(model.upNext.contains { $0.id == episode.id } || isCurrent)
            .accessibilityLabel("Als Nächstes hören")

            if episode.audioURL != nil, stage == nil || stage == .failed {
                Button {
                    model.enqueueAnalysis(episode)
                } label: {
                    Label(stage == .failed ? "Erneut versuchen" : "Erschliessen",
                          systemImage: "waveform.badge.magnifyingglass")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .disabled(model.stageDetails[episode.id] == "wartet")
                .accessibilityLabel(stage == .failed ? "Erneut versuchen" : "Erschliessen")
            }
        }
        .buttonBorderShape(.capsule)
    }

    private var playLabel: String {
        if isCurrent { return player.isPlaying ? "Pause" : "Weiter" }
        let resume = model.resumePosition(for: episode)
        return resume > 5 ? "Weiter ab \(MediaTime(milliseconds: Int64(resume * 1000)).timecode)" : "Abspielen"
    }

    // MARK: Kapitel

    private var chapterList: some View {
        List {
            if chapters.isEmpty {
                ContentUnavailableView("Keine Kapitel", systemImage: "list.bullet",
                                       description: Text("Der Podcast liefert für diese Folge keine Kapitelmarken."))
            }
            ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                ChapterRow(chapter: chapter, episode: episode, chapters: chapters)
            }
        }
    }

    // MARK: Fakten

    private var factList: some View {
        List {
            if facts.isEmpty {
                SwiftUI.Section {
                    if model.factsInProgress.contains(episode.id) {
                        HStack { ProgressView(); Text("Fakten werden ermittelt …") }
                    } else if passages.isEmpty {
                        Text("Sobald die Folge erschlossen ist, zieht die App überprüfbare Aussagen mit "
                             + "Zeitmarke heraus.")
                            .foregroundStyle(.secondary)
                    } else if case .failure(let reason) = model.modelStatus.resolve(.extract) {
                        // Ohne Apple Intelligence gibt es keine Fakten. Das steht hier,
                        // statt dass ein Knopf ohne Wirkung angeboten wird.
                        Label(reason.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await model.prepareFacts(for: episode, force: true) }
                        } label: { Label("Fakten ermitteln", systemImage: "checkmark.seal") }
                    }
                }
            } else {
                SwiftUI.Section {
                    ForEach(facts) { fact in FactRow(fact: fact, episode: episode) }
                } footer: {
                    Text("Jede Aussage stammt aus dem Transkript. Antippen spielt die Stelle. "
                         + "Formuliert von: \(facts.first?.modelTier ?? "Apple Intelligence").")
                }
                SwiftUI.Section {
                    Button {
                        Task { await model.prepareFacts(for: episode, force: true) }
                    } label: { Label("Neu ermitteln", systemImage: "arrow.clockwise") }
                    .disabled(model.factsInProgress.contains(episode.id))
                }
            }
        }
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let episode: Episode
    let chapters: [Chapter]
    @Environment(AppModel.self) private var model

    private var isCurrent: Bool {
        model.episodePlayer.episode?.id == episode.id
            && model.episodePlayer.currentChapter?.start == chapter.start
    }

    var body: some View {
        Button {
            model.playEpisode(episode, at: chapter.start.seconds)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                TimecodeLabel(chapter.start)
                    .frame(minWidth: 56, alignment: .leading)
                Text(chapter.title)
                    .foregroundStyle(.primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer()
                if heard {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("gehört")
                }
            }
        }
    }

    private var heard: Bool {
        guard let id = episode.streamMediaVersionID else { return false }
        let next = chapters.first { $0.start.milliseconds > chapter.start.milliseconds }
        let endMs = next?.start.milliseconds
            ?? episode.declaredDuration.map { Int64($0.seconds * 1000) }
            ?? chapter.start.milliseconds + 60_000
        guard endMs > chapter.start.milliseconds else { return false }
        return model.hasHeard(MediaTimeRange(start: chapter.start, end: MediaTime(milliseconds: endMs)), in: id)
    }
}

struct FactRow: View {
    let fact: EpisodeFact
    let episode: Episode
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.playEpisode(episode, at: fact.range.start.seconds)
        } label: {
            HStack(alignment: .top, spacing: Design.Spacing.small) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Text(fact.statement).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    HStack(spacing: Design.Spacing.micro) {
                        TimecodeLabel(fact.range.start)
                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.tint)
                    }
                }
            }
        }
        .accessibilityHint("Spielt die Stelle, aus der die Aussage stammt")
        .contextMenu {
            PassageActions(text: fact.statement, start: fact.range.start, episode: episode)
        }
    }
}

/// Merken, Kopieren und Teilen für eine Stelle mit Zeitmarke.
struct PassageActions: View {
    let text: String
    let start: MediaTime
    let episode: Episode
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.playEpisode(episode, at: start.seconds)
        } label: {
            Label("Ab hier abspielen", systemImage: "play.fill")
        }
        Button {
            Task { await model.addNote(nil, at: start.seconds, in: episode, quote: text) }
        } label: {
            Label("Stelle merken", systemImage: "bookmark")
        }
        Button {
            Clipboard.copy(model.citation(text, at: start, in: episode))
        } label: {
            Label("Mit Quelle kopieren", systemImage: "doc.on.doc")
        }
        ShareLink(item: model.citation(text, at: start, in: episode)) {
            Label("Teilen", systemImage: "square.and.arrow.up")
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Das Transkript mit Zeitmarken. Antippen springt an die Stelle, die
/// laufende Stelle ist hervorgehoben, Gehörtes ist abgeblendet.
struct TranscriptSection: View {
    let episode: Episode
    @Environment(AppModel.self) private var model
    @State private var paragraphs: [(start: MediaTime, text: String)] = []
    @State private var loaded = false
    @State private var query = ""

    private var filtered: [(start: MediaTime, text: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return paragraphs }
        return paragraphs.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Die Suche steht im Inhalt, nicht in der Navigationsleiste.
                // Dort schob sie sich über die Reiter, und alles sprang.
                if !paragraphs.isEmpty {
                    HStack(spacing: Design.Spacing.small) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Im Transkript suchen", text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("transcript.search")
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Suche leeren")
                        }
                    }
                }
                if loaded && paragraphs.isEmpty {
                    ContentUnavailableView(
                        "Noch kein Transkript", systemImage: "text.alignleft",
                        description: Text("Die App erstellt das Transkript beim Erschliessen, auf dem Gerät und mit Zeitmarken."))
                }
                ForEach(Array(filtered.enumerated()), id: \.element.start) { _, paragraph in
                    Button {
                        model.playEpisode(episode, at: paragraph.start.seconds)
                    } label: {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                            TimecodeLabel(paragraph.start, emphasis: isCurrent(paragraph.start) ? .bold : .regular)
                            Text(paragraph.text)
                                .font(.callout)
                                .foregroundStyle(isHeard(paragraph.start) ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, Design.Spacing.micro)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    // Schlicht, damit der Text schwarz bleibt und nicht als Link blau erscheint.
                    .buttonStyle(.plain)
                    .listRowBackground(isCurrent(paragraph.start) ? Color.accentColor.opacity(0.1) : nil)
                    .swipeActions(edge: .leading) {
                        Button { remember(paragraph) } label: { Label("Merken", systemImage: "bookmark") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        PassageActions(text: paragraph.text, start: paragraph.start, episode: episode)
                    }
                    .id(paragraph.start.milliseconds)
                }
            }
            .onChange(of: currentStart) { _, start in
                guard let start, query.isEmpty else { return }
                withAnimation { proxy.scrollTo(start, anchor: .center) }
            }
        }
        // Mit der Stufe als Schlüssel: endet die Erschliessung, während der
        // Reiter offen ist, erscheint das Transkript ohne Umweg.
        .task(id: model.stages[episode.id]) {
            if let transcript = await model.transcript(for: episode) {
                paragraphs = EpisodeDossierExporter.paragraphs(transcript.segments, seconds: 30)
            }
            loaded = true
        }
    }

    private var currentStart: Int64? {
        guard model.episodePlayer.episode?.id == episode.id else { return nil }
        let now = model.episodePlayer.currentTime
        return paragraphs.last { $0.start.seconds <= now + 0.5 }?.start.milliseconds
    }

    private func isCurrent(_ start: MediaTime) -> Bool { currentStart == start.milliseconds }

    private func remember(_ paragraph: (start: MediaTime, text: String)) {
        Task { await model.addNote(nil, at: paragraph.start.seconds, in: episode, quote: paragraph.text) }
    }

    private func isHeard(_ start: MediaTime) -> Bool {
        guard let id = episode.streamMediaVersionID else { return false }
        let range = MediaTimeRange(start: start, end: MediaTime(milliseconds: start.milliseconds + 20_000))
        return model.hasHeard(range, in: id)
    }
}

private struct PassageRow: View {
    let passage: Evidence
    let range: MediaTimeRange
    let heard: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                TimecodeLabel(range, emphasis: .medium)
                Text(passage.quotedText)
                    .font(.callout)
                    .foregroundStyle(heard ? .secondary : .primary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Image(systemName: heard ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(heard ? Color.secondary : Color.accentColor)
                .accessibilityLabel(heard ? "gehört" : "noch nicht gehört")
        }
    }
}

struct HeardProgress: View {
    let fraction: Double

    var body: some View {
        if fraction > 0.01 {
            HStack(spacing: Design.Spacing.small) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 120)
                Text(fraction > 0.97 ? "gehört" : "\(Int(fraction * 100)) % gehört")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct EpisodeArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 8))
        .accessibilityHidden(true)
    }
}

// MARK: - Player

/// Der große Player für eine ganze Folge.
struct EpisodePlayerView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showingNote = false
    @State private var noteText = ""
    @State private var notePosition: Double = 0

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        NavigationStack {
            if let episode = player.episode {
                ScrollView {
                    VStack(spacing: Design.Spacing.control) {
                        EpisodeArtwork(url: episode.artworkURL ?? artwork(for: episode), size: 260)
                            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                            .padding(.top, Design.Spacing.section)
                        VStack(spacing: Design.Spacing.micro) {
                            Text(episode.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if let chapter = player.currentChapter {
                                Text(chapter.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.tint)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        if let error = player.playbackError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("player.error")
                        } else if player.isBuffering {
                            HStack(spacing: Design.Spacing.small) {
                                ProgressView()
                                Text("Audio wird geladen …")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        scrubber
                        transport
                        Button {
                            notePosition = player.currentTime
                            noteText = ""
                            showingNote = true
                        } label: {
                            Label("Moment merken", systemImage: "bookmark")
                                .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("player.note")
                        .accessibilityHint("Merkt die aktuelle Stelle, auf Wunsch mit Kommentar")
                        HStack(spacing: Design.Spacing.control) {
                            rateMenu
                            sleepMenu
                            RoutePickerButton()
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("Wiedergabe auf anderem Gerät")
                        }
                        if !player.chapters.isEmpty { chapterList }
                    }
                    .padding(.horizontal)
                }
                .navigationTitle("Jetzt läuft")
                .sheet(isPresented: $showingNote) {
                    NoteSheet(position: notePosition, text: $noteText) {
                        Task { await model.addNote(noteText, at: notePosition, in: episode) }
                    }
                    .presentationDetents([.medium])
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            QueueView()
                        } label: {
                            Label("Warteschlange", systemImage: "list.bullet")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Nichts läuft", systemImage: "play.slash")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    }
            }
        }
    }

    private func artwork(for episode: Episode) -> URL? {
        model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL
    }

    private var scrubber: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: Design.Spacing.micro) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...total
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            .accessibilityLabel("Position")
            HStack {
                Text(Self.format(scrubbing ?? player.currentTime))
                Spacer()
                Text("-" + Self.format(max(0, total - (scrubbing ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: Design.Spacing.control * 1.5) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill").tappableArea()
            }
            .accessibilityLabel("Vorheriges Kapitel")
            .disabled(player.chapters.isEmpty)
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title2).tappableArea()
            }
            .accessibilityLabel("15 Sekunden zurück")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.title2).tappableArea()
            }
            .accessibilityLabel("30 Sekunden vor")
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill").tappableArea()
            }
            .accessibilityLabel("Nächstes Kapitel")
            .disabled(player.chapters.isEmpty)
        }
        .buttonStyle(.pressable)
        .padding(.vertical, Design.Spacing.small)
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.8, 1.0, 1.2, 1.5, 1.8, 2.0], id: \.self) { rate in
                Button("\(rate.formatted(.number.precision(.fractionLength(1))))×") {
                    player.rate = Float(rate)
                }
            }
        } label: {
            Label("\(Double(player.rate).formatted(.number.precision(.fractionLength(1))))×",
                  systemImage: "speedometer")
                .font(.footnote)
                .padding(.horizontal, Design.Spacing.control)
                .padding(.vertical, Design.Spacing.small)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Geschwindigkeit")
    }

    private var sleepMenu: some View {
        Menu {
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) Minuten") { player.setSleepTimer(.minutes(minutes)) }
            }
            Button("Ende des Kapitels") { player.setSleepTimer(.endOfChapter) }
                .disabled(player.chapters.isEmpty)
            Button("Ende der Folge") { player.setSleepTimer(.endOfEpisode) }
            if player.sleepTimer != nil {
                Divider()
                Button("Schlaf-Timer aus", role: .destructive) { player.setSleepTimer(nil) }
            }
        } label: {
            Label(sleepLabel, systemImage: player.sleepTimer == nil ? "moon" : "moon.fill")
                .font(.footnote)
                .padding(.horizontal, Design.Spacing.control)
                .padding(.vertical, Design.Spacing.small)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Schlaf-Timer")
    }

    private var sleepLabel: String {
        // Die Restzeit steht auch in der Pause still, genau wie der Timer.
        if case .minutes = player.sleepTimer, let remaining = player.sleepRemaining {
            let minutes = max(1, Int(remaining / 60 + 0.5))
            return "\(minutes) Min"
        }
        return player.sleepTimer?.label ?? "Schlaf-Timer"
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Kapitel").font(.headline).padding(.vertical, Design.Spacing.small)
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { _, chapter in
                let isCurrent = player.currentChapter?.start == chapter.start
                Button { player.seek(to: chapter.start.seconds) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        TimecodeLabel(chapter.start).frame(minWidth: 56, alignment: .leading)
                        Text(chapter.title)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, Design.Spacing.control)
                    .padding(.horizontal, Design.Spacing.control)
                    .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: Design.Radius.control))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if !isCurrent { Divider() }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        MediaTime(milliseconds: Int64(max(0, seconds) * 1000)).timecode
    }
}

/// Kompakte Leiste für die laufende Folge.
struct EpisodeMiniBar: View {

    @Environment(AppModel.self) private var model
    @State private var showingPlayer = false

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        if let episode = player.episode {
            HStack(spacing: Design.Spacing.control) {
                Button { showingPlayer = true } label: {
                    HStack(spacing: Design.Spacing.small) {
                        EpisodeArtwork(url: episode.artworkURL
                                       ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                                       size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(episode.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(player.playbackError != nil ? "Nicht abspielbar"
                                 : player.isBuffering ? "lädt …"
                                 : player.currentChapter?.title ?? EpisodePlayerView.format(player.currentTime))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Player öffnen, \(episode.title)")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(player.isPlaying ? "Pausieren" : "Fortsetzen")

                Button { player.skip(by: 30) } label: {
                    Image(systemName: "goforward.30").tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("30 Sekunden vor")
            }
            .padding(.horizontal, Design.Spacing.control)
            .sheet(isPresented: $showingPlayer) {
                EpisodePlayerView()
                    .environment(model)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 560)
                    #endif
            }
        }
    }
}

// MARK: - Warteschlange

/// Ein Ort für alles, was ansteht: was läuft, was als Nächstes gehört wird
/// und was gerade oder demnächst erschlossen wird.
struct QueueView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let episode = model.episodePlayer.episode {
                Section("Jetzt läuft") {
                    NavigationLink { EpisodeDetailView(episode: episode) } label: {
                        QueueRow(episode: episode, detail: model.episodePlayer.currentChapter?.title)
                    }
                }
            }

            Section {
                if model.upNext.isEmpty {
                    Text("Leer. In einer Folge „Als Nächstes“ antippen, dann startet sie, sobald die laufende endet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.upNext) { episode in
                    NavigationLink { EpisodeDetailView(episode: episode) } label: {
                        QueueRow(episode: episode, detail: nil)
                    }
                    .swipeActions {
                        Button("Entfernen", role: .destructive) { model.removeFromUpNext(episode.id) }
                    }
                }
                .onMove { model.moveUpNext(from: $0, to: $1) }
            } header: {
                Text("Als Nächstes hören")
            }

            Section {
                if let current = model.analyzing {
                    NavigationLink { EpisodeDetailView(episode: current) } label: {
                        QueueRow(episode: current,
                                 detail: model.stages[current.id].map { stage in
                                     model.stageDetails[current.id].map { "\(stage.label) · \($0)" } ?? stage.label
                                 } ?? "startet")
                    }
                }
                ForEach(model.analysisQueue) { episode in
                    QueueRow(episode: episode, detail: "wartet")
                        .swipeActions {
                            Button("Entfernen", role: .destructive) { model.removeFromAnalysisQueue(episode.id) }
                        }
                }
                .onMove { model.moveAnalysisQueue(from: $0, to: $1) }
                if model.analyzing == nil && model.analysisQueue.isEmpty {
                    Text("Nichts in Arbeit. Erschliessen startest du in einer Folge.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Erschliessen")
            } footer: {
                if let unavailable = model.preparationUnavailable {
                    Text("Automatisch vorbereitet wird gerade nichts. \(unavailable)")
                } else {
                    Text("Es läuft immer eine Folge zur Zeit. Auf dem iPhone geht die Arbeit im Hintergrund weiter, "
                     + "solange die Fortschrittsanzeige des Systems zu sehen ist.")
                }
            }
        }
        .navigationTitle("Warteschlange")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

private struct QueueRow: View {
    let episode: Episode
    let detail: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            EpisodeArtwork(url: episode.artworkURL
                           ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Shownotes

/// Macht aus dem HTML der Shownotes lesbaren Text mit anklickbaren Links.
enum ShownotesText {

    /// Nur der Text, ohne Links, für Chat und Export.
    static func plain(_ html: String?) -> String? {
        guard let rendered = render(html) else { return nil }
        let text = String(rendered.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func render(_ html: String?) -> AttributedString? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var text = html
        // Links vor dem Entfernen der Tags als Markdown sichern.
        let linkPattern = #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(text.startIndex..., in: text)
            var result = ""
            var last = text.startIndex
            for match in regex.matches(in: text, range: range) {
                guard let whole = Range(match.range, in: text),
                      let href = Range(match.range(at: 1), in: text),
                      let label = Range(match.range(at: 2), in: text) else { continue }
                result += text[last..<whole.lowerBound]
                let labelText = stripTags(String(text[label])).trimmingCharacters(in: .whitespaces)
                let url = String(text[href])
                if url.hasPrefix("http") {
                    result += "[\(escape(labelText.isEmpty ? url : labelText))](\(url.replacingOccurrences(of: " ", with: "%20")))"
                } else {
                    result += labelText
                }
                last = whole.upperBound
            }
            result += text[last...]
            text = result
        }
        text = text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|h[1-6]|ul|ol)>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(stripTags(text))
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                     "&apos;": "'", "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—",
                     "&hellip;": "…", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü",
                     "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = result as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) {
                    output += String(Character(scalar))
                } else {
                    output += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        return result
    }
}

// MARK: - AirPlay

#if os(iOS)
import AVKit

/// Die Systemauswahl für AirPlay und Bluetooth.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
import AVKit

struct RoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - Notizen

/// Kommentar zu einem Moment. Die Stelle ist schon gemerkt, der Text ist freiwillig.
struct NoteSheet: View {
    let position: Double
    @Binding var text: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was ist dir hier wichtig? (freiwillig)", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("note.text")
                } header: {
                    Text("Moment bei \(MediaTime(milliseconds: Int64(position * 1000)).timecode)")
                } footer: {
                    Text("Die Notiz hängt an dieser Stelle. Du findest sie in der Folge und unter Wissen › Gemerkte Stellen. Sie bleibt auch, wenn du die Folge löschst.")
                }
            }
            .navigationTitle("Moment merken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merken") { save(); dismiss() }
                        .accessibilityIdentifier("note.save")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

/// Eine gemerkte Stelle mit Kommentar, Zitat und Herkunft.
struct NoteRow: View {
    let highlight: Highlight
    var showsEpisode = true

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            if let note = highlight.note {
                Text(note).font(.body)
            }
            if let quote = highlight.quote {
                Text("„\(quote)“")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: Design.Spacing.micro) {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                if let ms = highlight.positionMs {
                    TimecodeLabel(MediaTime(milliseconds: Int64(ms)))
                }
                if showsEpisode, let title = highlight.episodeTitle {
                    Text("· \(title)").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Design.Spacing.micro)
    }
}

//
//  EpisodeViews.swift
//  PodcastAI
//
//  Folgenliste und Erschliessung.
//
//  Die App bereitet die jüngsten Folgen einer Quelle von selbst vor: laden,
//  transkribieren, Belege mit Zeitmarken. Ohne das bleibt „Für dich“ leer,
//  und die Suche findet nichts. Ältere Folgen wartet sie ab, bis jemand sie
//  anfordert, und in den Einstellungen lässt sich das Vorbereiten ganz
//  abschalten. An jeder Folge steht deshalb sichtbar, in welchem Zustand
//  sie ist.
//

import SwiftUI
import PodcastAIKit

struct EpisodeListView: View {

    let sourceID: SourceID
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Episode?
    // Suche, Filter und Reihenfolge gelten nur für diese Liste.
    @State private var query = ""
    @State private var options = EpisodeArchive.Options()
    /// Im Auswahlmodus öffnet ein Tippen nicht die Folge, sondern wählt sie
    /// zum Auswerten aus.
    @State private var selecting = false
    @State private var selection: Set<EpisodeID> = []
    /// Durchsuchbarer Text je Folge, beim ersten Suchen im Hintergrund
    /// vorbereitet.
    @State private var searchIndex: [EpisodeID: String] = [:]
    /// Treffer der Suche, `nil`, solange nichts gesucht wird.
    @State private var matches: Set<EpisodeID>?

    private var source: Source? { model.sources.first { $0.id == sourceID } }
    private var episodes: [Episode] { model.episodes[sourceID] ?? [] }

    var body: some View {
        let analyzed = Set(episodes.lazy.map(\.id).filter { model.stages[$0] == .evidenceExtracted })
        let shown = EpisodeArchive.arrange(episodes, options: options, analyzed: analyzed, matches: matches)
        List {
            if !(source?.capabilities.supportsTimedKnowledge ?? true),
               let reason = source?.capabilities.limitationReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            // Zum YouTube-Kanal gibt es oft denselben Inhalt als Audio-Podcast.
            // Dessen Folgen lassen sich laden und transkribieren.
            if let counterparts = model.podcastCounterparts[sourceID], !counterparts.isEmpty {
                Section {
                    ForEach(counterparts) { podcast in
                        Button {
                            Task { await model.addSource(from: podcast.feedURL.absoluteString) }
                        } label: {
                            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                                Label("\(podcast.title) abonnieren", systemImage: "plus.circle")
                                Text(podcast.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Als Audio-Podcast verfügbar")
                } footer: {
                    Text("""
                        Der Audio-Podcast liefert die Tonspur, die PodcastAI transkribieren darf. \
                        Das Audio der YouTube-Videos selbst lädt die App nicht.
                        """)
                }
            }

            Section {
                ForEach(shown) { episode in
                    row(for: episode)
                    .swipeActions(edge: .leading) {
                        // Folgen ohne Audiodatei (YouTube) führen zum Video.
                        if model.canPlay(episode) {
                            Button { model.playEpisode(episode) } label: {
                                Label("Abspielen", systemImage: "play.fill")
                            }
                            .tint(.accentColor)
                        } else {
                            OpenEpisodeWebButton(episode: episode)
                                .tint(.red)
                        }
                        if canDownload(episode) {
                            Button { Task { await model.downloadForOffline(episode) } } label: {
                                Label("Laden (offline)", systemImage: "arrow.down.circle")
                            }
                            .tint(.green)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if model.canPlay(episode) {
                            Button { model.addToUpNext(episode) } label: {
                                Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.indigo)
                        }
                        Button(role: .destructive) { pendingDelete = episode } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        if episode.audioURL != nil, model.stages[episode.id] == nil || model.stages[episode.id] == .failed {
                            Button { model.enqueueAnalysis(episode) } label: {
                                Label("Transkript erstellen", systemImage: "waveform.badge.magnifyingglass")
                            }
                            .tint(.teal)
                        }
                    }
                    .contextMenu {
                        if model.canPlay(episode) {
                            Button { model.playEpisode(episode) } label: { Label("Abspielen", systemImage: "play.fill") }
                            Button { model.addToUpNext(episode) } label: {
                                Label("Als Nächstes hören", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button { model.addToUpNext(episode, placement: .last) } label: {
                                Label("Ans Ende der Warteschlange", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                        } else {
                            OpenEpisodeWebButton(episode: episode)
                        }
                        if episode.audioURL != nil {
                            Button { model.enqueueAnalysis(episode) } label: {
                                Label("Transkript erstellen", systemImage: "waveform.badge.magnifyingglass")
                            }
                        }
                        Divider()
                        // Nur bei geladener Datei. Ohne Datei gäbe es nichts
                        // zu entfernen, und eine gestreamte Folge würde
                        // trotzdem angehalten.
                        if hasLocalAudio(episode) {
                            Button { Task { await model.removeAudio(for: episode) } } label: {
                                Label("Audio entfernen, Daten behalten", systemImage: "arrow.down.circle.dotted")
                            }
                        } else if canDownload(episode) {
                            Button { Task { await model.downloadForOffline(episode) } } label: {
                                Label("Laden (offline)", systemImage: "arrow.down.circle")
                            }
                        }
                        Button(role: .destructive) { pendingDelete = episode } label: {
                            Label("Folge löschen", systemImage: "trash")
                        }
                    }
                }
            } header: {
                // Gefunden und ausgewertet sind getrennte Zahlen. Sie zu
                // vermischen würde behaupten, alles sei durchsuchbar.
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                        Text(coverage(analyzed: analyzed.count))
                        if matches != nil || options.onlyUnanalyzed {
                            Text(shown.count == 1 ? "1 Folge angezeigt" : "\(shown.count) Folgen angezeigt")
                        }
                    }
                    .textCase(nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("episodes.coverage")
                }
            }
        }
        .navigationTitle(source?.title ?? String(localized: "Folgen"))
        .searchable(text: $query, prompt: "Titel und Shownotes durchsuchen")
        .task(id: SearchRequest(query: query, episodeCount: episodes.count)) { await search() }
        .toolbar { archiveToolbar }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar(shown) }
        }
        .confirmationDialog("Folge löschen?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { episode in
            Button("Folge und alle Daten löschen", role: .destructive) {
                Task { await model.removeEpisode(episode) }
            }
        } message: { _ in
            Text("Transkript, Fakten, Belege und der Hörstand dieser Folge werden gelöscht. Deine Notizen bleiben unter Wissen erhalten.")
        }
        .task { await model.loadEpisodes(for: sourceID) }
        // Was mit dieser Quelle geht und wie weit ihr Archiv zurückreicht.
        .toolbar {
            ToolbarItem {
                NavigationLink { SourceDetailView(sourceID: sourceID) } label: {
                    Label("Über diese Quelle", systemImage: "info.circle")
                }
            }
        }
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "Keine Folgen",
                    systemImage: "list.bullet",
                    description: Text("In diesem Podcast wurden keine Folgen gefunden.")
                )
            } else if shown.isEmpty, matches != nil {
                ContentUnavailableView(
                    "Keine Treffer",
                    systemImage: "magnifyingglass",
                    description: Text("""
                        Keine Folge enthält „\(query.trimmingCharacters(in: .whitespaces))“ \
                        in Titel oder Shownotes.
                        """)
                )
            } else if shown.isEmpty {
                ContentUnavailableView(
                    "Alle Transkripte fertig",
                    systemImage: "checkmark.circle",
                    description: Text("Jede Folge dieser Quelle hat ein Transkript. Ohne den Filter siehst du alle.")
                )
            }
        }
    }

    // MARK: Ältere Folgen

    /// Normal führt die Zeile in die Folge. Im Auswahlmodus hakt ein Tippen
    /// sie an. Was schon ausgewertet ist, läuft oder keinen Ton hat, bleibt
    /// grau.
    @ViewBuilder
    private func row(for episode: Episode) -> some View {
        if selecting {
            let selectable = canQueue(episode)
            let selected = selection.contains(episode.id)
            Button {
                if selected { selection.remove(episode.id) } else { selection.insert(episode.id) }
            } label: {
                HStack(spacing: Design.Spacing.control) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    EpisodeRow(episode: episode)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .opacity(selectable ? 1 : 0.45)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink {
                EpisodeDetailView(episode: episode)
            } label: {
                EpisodeRow(episode: episode)
            }
        }
    }

    /// Lässt sich die Folge jetzt einreihen? Nicht ohne Ton, nicht wenn sie
    /// schon ausgewertet ist oder gerade läuft. Wartet sie schon, etwa von
    /// selbst eingereiht aufs WLAN, rückt sie beim Anfordern nach vorn.
    private func canQueue(_ episode: Episode) -> Bool {
        guard episode.audioURL != nil else { return false }
        let stage = model.stages[episode.id]
        guard stage == nil || stage == .failed else { return false }
        return model.analyzing?.id != episode.id
    }

    private func coverage(analyzed: Int) -> String {
        let automatic: EpisodeArchive.Automatic = !model.automaticAnalysis ? .off
            : model.preparationUnavailable != nil ? .paused
            : .newest(model.episodesPerSource)
        return EpisodeArchive.coverage(
            total: episodes.count, analyzed: analyzed,
            analyzable: episodes.contains { $0.audioURL != nil }, automatic: automatic)
    }

    @ToolbarContentBuilder
    private var archiveToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Toggle(isOn: $options.onlyUnanalyzed) {
                    Label("Nur ohne Transkript", systemImage: "circle.dashed")
                }
                Picker("Reihenfolge", selection: $options.oldestFirst) {
                    Text("Neueste zuerst").tag(false)
                    Text("Älteste zuerst").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filtern und sortieren", systemImage: options == EpisodeArchive.Options()
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityIdentifier("episodes.filter")

            if episodes.contains(where: { $0.audioURL != nil }) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    selecting.toggle()
                    selection.removeAll()
                }
                .accessibilityIdentifier("episodes.select")
            }
        }
    }

    /// Die Leiste im Auswahlmodus: was ausgewählt ist, wie lang es dauert,
    /// und der Knopf dazu.
    private func selectionBar(_ shown: [Episode]) -> some View {
        let chosen = episodes.filter { selection.contains($0.id) && canQueue($0) }
        let selectable = shown.filter(canQueue).map(\.id)
        let allChosen = !selectable.isEmpty && selectable.allSatisfy(selection.contains)
        return VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text(EpisodeArchive.selectionSummary(chosen))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(allChosen ? "Auswahl aufheben" : "Alle auswählen") {
                    if allChosen { selection.subtract(selectable) } else { selection.formUnion(selectable) }
                }
                .disabled(selectable.isEmpty)
                Spacer()
                Button { analyzeSelection() } label: {
                    Label("Transkripte erstellen", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("episodes.analyzeSelection")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.small)
        .background(.bar)
    }

    /// Reiht die Auswahl in der Reihenfolge der Liste ein. Jede Folge gilt
    /// als selbst angefordert, wie ein Tippen auf „Auswerten“. Abgespielt
    /// wird dabei nichts.
    private func analyzeSelection() {
        let ordered = options.oldestFirst ? EpisodeArchive.oldestFirst(episodes) : episodes
        for episode in ordered where selection.contains(episode.id) && canQueue(episode) {
            model.enqueueAnalysis(episode)
        }
        selection.removeAll()
        selecting = false
    }

    private struct SearchRequest: Equatable {
        let query: String
        let episodeCount: Int
    }

    /// Sucht kurz nach der letzten Eingabe, im Hintergrund. Den Text der
    /// Shownotes bereitet sie beim ersten Mal je Folge vor und behält ihn.
    private func search() async {
        let terms = EpisodeArchive.terms(of: query)
        guard !terms.isEmpty else {
            matches = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let list = episodes
        let missing = list.filter { searchIndex[$0.id] == nil }
        if !missing.isEmpty {
            let fresh = await Task.detached(priority: .userInitiated) {
                EpisodeArchive.searchIndex(for: missing)
            }.value
            searchIndex.merge(fresh) { _, new in new }
        }
        guard !Task.isCancelled else { return }
        let index = list.map { (id: $0.id, text: searchIndex[$0.id] ?? "") }
        let found = await Task.detached(priority: .userInitiated) {
            EpisodeArchive.matchingIDs(for: terms, in: index)
        }.value
        guard !Task.isCancelled else { return }
        matches = found
    }

    /// Liegt die Audiodatei auf dem Gerät? Liest Speicherzähler und Stufe
    /// mit, damit das Kontextmenü nach Laden oder Entfernen neu prüft.
    private func hasLocalAudio(_ episode: Episode) -> Bool {
        model.hasLocalAudio(episode)
    }

    /// Nur laden, was eine Audiodatei hat, noch nicht da ist und nicht gerade lädt.
    private func canDownload(_ episode: Episode) -> Bool {
        episode.audioURL != nil && !model.downloading.contains(episode.id) && !model.hasLocalAudio(episode)
    }
}

struct EpisodeRow: View {

    let episode: Episode
    @Environment(AppModel.self) private var model

    private var stage: ProcessingStage? { model.stages[episode.id] }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.control) {
            EpisodeArtwork(url: episode.artworkURL
                           ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 56)
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(3)

            HStack(spacing: Design.Spacing.small) {
                if let published = episode.publishedAt {
                    Text(published, style: .date)
                }
                if let duration = episode.declaredDuration {
                    Text(duration.shortDescription)
                }
                if model.downloading.contains(episode.id) {
                    Label("lädt …", systemImage: "arrow.down.circle")
                        .symbolEffect(.pulse)
                } else if model.hasLocalAudio(episode) {
                    Image(systemName: "arrow.down.circle.fill")
                        .accessibilityLabel("auf dem Gerät")
                        .help("Auf dem Gerät, spielt auch ohne Netz")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let stage {
                // Der Zustand trägt Symbol **und** Text. Farbe allein würde
                // für jeden, der sie nicht unterscheiden kann, nichts sagen.
                Label {
                    Text(model.stageDetails[episode.id].map { String(localized: "\(stage.label) · \($0)") }
                         ?? stage.label)
                } icon: {
                    Image(systemName: stage.symbol)
                        .symbolEffect(.pulse, isActive: stage.isRunning)
                }
                .font(.caption)
                .foregroundStyle(stage == .failed ? .orange : .secondary)
            }

            HeardProgress(fraction: model.heardFraction(for: episode))

            if stage == nil, let waiting = model.stageDetails[episode.id] {
                Label(waiting, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.episodePlayer.episode?.id == episode.id {
                Label(model.episodePlayer.isPlaying ? "läuft gerade" : "pausiert",
                      systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }

            if !episode.canBeAnalyzed {
                // Ehrlich statt stiller Fehlschlag: ohne Audio und ohne
                // getaktetes Transkript gibt es keinen Weg zu Timecodes.
                Label("Kein Audio, deshalb kein Transkript mit Zeitmarken",
                      systemImage: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Auswerten auf Wunsch

/// Wo eine Folge beim Auswerten steht, so wie die Oberfläche es braucht.
enum AnalysisPhase: Equatable {
    /// Ohne Audiodatei gibt es nichts auszuwerten. Der Text sagt warum.
    case unavailable(String)
    /// Wartet. So viele Folgen sind vorher dran.
    case waiting(ahead: Int)
    /// Läuft. Die Stufe ist die zuletzt erreichte.
    case running(ProcessingStage)
    case failed(String?)
    case ready
    case done
}

extension AppModel {

    /// Wo die Folge beim Auswerten steht. Knöpfe, Fortschritt und die
    /// Antwort im Reiter „Fragen“ lesen alle hier, damit keiner auf einen
    /// Knopf verweist, den es gerade nicht gibt.
    func analysisPhase(for episode: Episode) -> AnalysisPhase {
        let stage = stages[episode.id]
        if stage == .evidenceExtracted { return .done }
        if analyzing?.id == episode.id {
            return .running(stage.flatMap { $0.isRunning ? $0 : nil } ?? .discovered)
        }
        if let index = analysisQueue.firstIndex(where: { $0.id == episode.id }) {
            return .waiting(ahead: index + (analyzing == nil ? 0 : 1))
        }
        if let stage, stage.isRunning { return .running(stage) }
        if let reason = analysisUnavailableReason(for: episode) { return .unavailable(reason) }
        if stage == .failed { return .failed(stageDetails[episode.id]) }
        return .ready
    }

    /// Warum sich eine Folge nicht auswerten lässt, oder `nil`, wenn es geht.
    /// Ausgewertet wird der Ton. Ohne Audiodatei, etwa bei YouTube, entsteht
    /// kein Transkript und damit auch keine Fakten.
    func analysisUnavailableReason(for episode: Episode) -> String? {
        guard episode.audioURL == nil else { return nil }
        if let reason = sources.first(where: { $0.id == episode.sourceID })?.capabilities.limitationReason {
            return String(localized: "Für diese Folge lässt sich kein Transkript erstellen. \(reason)")
        }
        return String(localized: """
            Für diese Folge lässt sich kein Transkript erstellen, weil der Podcast zu ihr keine \
            Audiodatei anbietet. Ohne Ton gibt es kein Transkript.
            """)
    }

    /// Die Antwort im Reiter „Fragen“, solange eine Folge keine Belege hat.
    /// Sie nennt nur Knöpfe, die es im jeweiligen Zustand auch gibt.
    func unanalyzedEpisodeAnswer(_ id: EpisodeID) async -> String {
        guard let episode = try? await store.episodes(ids: [id]).first else {
            return String(localized: """
                Diese Folge ist nicht mehr in „Meine Podcasts“. Ohne Transkript habe ich keine Belege, \
                mit denen ich antworten kann.
                """)
        }
        switch analysisPhase(for: episode) {
        case .unavailable(let reason):
            return String(localized: "\(reason) Deshalb habe ich keine Belege, mit denen ich antworten kann.")
        case .waiting:
            return String(localized: """
                Das Transkript dieser Folge steht in der Warteschlange. Sobald es fertig ist, kann ich \
                mit Belegen aus dem Transkript antworten.
                """)
        case .running:
            return String(localized: """
                Das Transkript dieser Folge wird gerade erstellt. Sobald es fertig ist, kann ich \
                mit Belegen aus dem Transkript antworten.
                """)
        case .failed(let message?):
            return String(localized: """
                Das Transkript dieser Folge konnte nicht erstellt werden: \(message) Tippe in der Folge \
                auf „Erneut versuchen“, danach kann ich mit Belegen aus dem Transkript antworten.
                """)
        case .failed(nil):
            return String(localized: """
                Das Transkript dieser Folge konnte nicht erstellt werden. Tippe in der Folge \
                auf „Erneut versuchen“, danach kann ich mit Belegen aus dem Transkript antworten.
                """)
        case .ready:
            return String(localized: """
                Zu dieser Folge gibt es noch kein Transkript. Tippe in der Folge auf „Transkript erstellen“, \
                danach kann ich mit Belegen aus dem Transkript antworten.
                """)
        case .done:
            return String(localized: """
                Das Transkript dieser Folge ist fertig, aber daraus sind keine Belege entstanden. \
                Ohne Belege kann ich nicht antworten.
                """)
        }
    }
}

/// Der Weg zum Auswerten aus einer leeren Ansicht heraus.
///
/// Transkript, Fakten und Antworten entstehen erst beim Auswerten. Statt
/// nur darauf zu verweisen, steht hier ein Knopf mit Aufschrift. Läuft es
/// schon, zeigt die Ansicht den Schritt. Geht es nicht, sagt sie warum.
struct EpisodeAnalysisPrompt: View {

    enum Style: Equatable {
        /// Nur Knopf oder Fortschritt, unter einer Leeransicht.
        case actions
        /// Ein Satz, was danach hier steht, und darunter der Knopf.
        case inline(String)
        /// Eine schmale Zeile über dem Chat.
        case banner
    }

    let episode: Episode
    var style: Style = .actions
    @Environment(AppModel.self) private var model

    var body: some View {
        let phase = model.analysisPhase(for: episode)
        switch style {
        case .actions:
            controls(phase)
        case .inline(let outcome):
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                if case .unavailable(let reason) = phase {
                    Label(reason, systemImage: "speaker.slash")
                        .foregroundStyle(.secondary)
                } else if phase != .done {
                    Text(outcome)
                        .foregroundStyle(.secondary)
                    controls(phase)
                }
            }
        case .banner:
            banner(phase)
        }
    }

    @ViewBuilder
    private func controls(_ phase: AnalysisPhase) -> some View {
        switch phase {
        case .ready:
            Button { model.enqueueAnalysis(episode) } label: {
                Label("Transkript erstellen", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("episode.analyze")
        case .failed(let message):
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Button { model.enqueueAnalysis(episode) } label: {
                Label("Erneut versuchen", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("episode.analyze")
        case .waiting(let ahead):
            progress(Self.waitingDescription(ahead))
        case .running(let stage):
            progress(Self.stepDescription(stage))
        case .unavailable, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private func banner(_ phase: AnalysisPhase) -> some View {
        switch phase {
        case .done:
            EmptyView()
        case .unavailable:
            bannerRow {
                Label("Für diese Folge lässt sich kein Transkript erstellen.", systemImage: "speaker.slash")
            }
        case .ready, .failed:
            bannerRow {
                Text(phase == .ready
                     ? "Noch ohne Transkript. Antworten mit Belegen gibt es erst, wenn es fertig ist."
                     : "Das Transkript konnte nicht erstellt werden.")
                Spacer(minLength: Design.Spacing.small)
                Button(phase == .ready ? "Transkript erstellen" : "Erneut versuchen") {
                    model.enqueueAnalysis(episode)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("episode.analyze")
            }
        case .waiting(let ahead):
            bannerRow {
                ProgressView().controlSize(.small)
                Text(Self.waitingDescription(ahead))
            }
        case .running(let stage):
            bannerRow {
                ProgressView().controlSize(.small)
                Text(Self.stepDescription(stage))
            }
        }
    }

    private func bannerRow(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Design.Spacing.small) { content() }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Spacing.standard)
            .padding(.bottom, Design.Spacing.small)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Design.Spacing.small) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func waitingDescription(_ ahead: Int) -> String {
        switch ahead {
        // Einzahl und Mehrzahl als eigene Texte. Die automatische Beugung
        // braucht ein de.lproj, und der Katalog erzeugt noch keines.
        case 0: String(localized: "Wartet, kommt als Nächstes dran")
        case 1: String(localized: "Wartet, davor ist noch 1 Folge dran")
        default: String(localized: "Wartet, davor sind noch \(ahead) Folgen dran")
        }
    }

    /// Der Schritt, der gerade läuft. Die Stufe nennt, was schon fertig ist.
    static func stepDescription(_ stage: ProcessingStage) -> String {
        switch stage {
        case .mediaDownloaded: String(localized: "Schritt 2 von 3: Das Transkript wird erstellt")
        case .transcribed: String(localized: "Schritt 3 von 3: Fundstellen werden gebildet")
        default: String(localized: "Schritt 1 von 3: Der Ton wird geladen")
        }
    }
}

extension ProcessingStage {

    /// Ein eigenes Symbol je Stufe, damit der Fortschritt erkennbar ist,
    /// ohne die Beschriftung zu lesen.
    var symbol: String {
        switch self {
        case .discovered: "arrow.down.circle"
        case .mediaDownloaded: "waveform"
        case .transcribed: "text.alignleft"
        case .evidenceExtracted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Läuft gerade etwas? Dann pulsiert das Symbol — eine Bewegung, die
    /// Arbeit anzeigt, ohne den Bildschirm zu beanspruchen.
    var isRunning: Bool {
        switch self {
        case .discovered, .mediaDownloaded, .transcribed: true
        case .evidenceExtracted, .failed: false
        }
    }
}

// MARK: - Wissen

/// Gemerkte Stellen und ihr Weg nach draussen.
struct KnowledgeView: View {

    @Environment(AppModel.self) private var model
    @State private var exported: String?
    @State private var editing: Highlight?
    @State private var editText = ""
    /// Folgen, die noch da sind. `nil`, solange das noch nicht geprüft ist.
    @State private var availableEpisodes: Set<EpisodeID>?

    var body: some View {
        List {
            if model.highlights.isEmpty {
                ContentUnavailableView {
                    Label("Noch nichts gemerkt", systemImage: "bookmark")
                } description: {
                    Text("""
                        Tippe beim Hören im Player auf „Moment merken“. Die Stelle wird mit Zeitmarke, \
                        Zitat und deinem Kommentar gespeichert.
                        """)
                }
            }
            ForEach(model.highlights) { highlight in
                noteRow(highlight)
                .swipeActions {
                    Button(role: .destructive) { model.removeHighlight(highlight.id) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button { editing = highlight; editText = highlight.note ?? "" } label: {
                        Label("Kommentar", systemImage: "square.and.pencil")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button { editing = highlight; editText = highlight.note ?? "" } label: {
                        Label("Kommentar bearbeiten", systemImage: "square.and.pencil")
                    }
                    Button(role: .destructive) { model.removeHighlight(highlight.id) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Gemerkte Stellen")
        .task(id: model.highlights.compactMap(\.episodeID)) {
            model.fillMissingNoteTitles()
            availableEpisodes = await model.availableEpisodeIDs(for: model.highlights)
        }
        .sheet(item: $editing) { highlight in
            NoteSheet(position: highlight.positionMs.map { Double($0) / 1000 }, quote: highlight.quote,
                      text: $editText) {
                model.updateNote(highlight.id, text: editText)
            }
            .presentationDetents([.medium])
        }
        .toolbar {
            if !model.highlights.isEmpty {
                Button {
                    Task { exported = await model.exportKnowledge() }
                } label: {
                    Label("Als Markdown exportieren", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: Binding(
            get: { exported.map(ExportPreview.init) },
            set: { exported = $0?.text }
        )) { preview in
            ExportPreviewSheet(text: preview.text)
        }
    }

    /// Abspielbar ist eine Notiz nur mit Folge und Zeitmarke. Alles andere
    /// ist eine Zeile zum Lesen und sieht auch so aus.
    @ViewBuilder
    private func noteRow(_ highlight: Highlight) -> some View {
        let gone = highlight.episodeID.map { id in availableEpisodes.map { !$0.contains(id) } ?? false } ?? false
        if highlight.episodeID != nil, highlight.positionMs != nil, !gone {
            Button { Task { await model.playHighlight(highlight) } } label: {
                NoteRow(highlight: highlight).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Spielt die Folge ab dieser Stelle")
        } else {
            NoteRow(highlight: highlight, episodeGone: gone)
        }
    }
}

struct ExportPreview: Identifiable {
    let text: String
    var id: String { text }
    init(_ text: String) { self.text = text }
}

/// Der Export wird gezeigt, bevor er das Gerät verlässt.
///
/// Nicht aus Höflichkeit: ein Export kann Originalzitate und eigene Notizen
/// enthalten, und wer ihn weitergibt, sollte vorher gesehen haben, was darin
/// steht.
struct ExportPreviewSheet: View {

    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: text) { Label("Teilen", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

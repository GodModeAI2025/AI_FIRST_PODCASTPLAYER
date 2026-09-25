//
//  EpisodeViews.swift
//  PodcastAI
//
//  Folgenliste und Erschließung.
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
    /// Die Rückfrage vor „Ältere Folgen auch vorbereiten“.
    @State private var confirmBackCatalog = false

    private var source: Source? { model.sources.first { $0.id == sourceID } }
    private var episodes: [Episode] { model.episodes[sourceID] ?? [] }

    var body: some View {
        // Nur mit dem Filter „ohne Transkript“ gebraucht. Ohne ihn liest die
        // Liste die Stufen nicht, und eine neue Stufe zeichnet nur ihre Zeile neu.
        let analyzed = options.onlyUnanalyzed
            ? Set(episodes.lazy.map(\.id).filter { model.stages[$0] == .evidenceExtracted }) : []
        let shown = EpisodeArchive.arrange(episodes, options: options, analyzed: analyzed, matches: matches)
        List {
            // „Neu laden“: läuft gerade, hat geklappt oder nicht.
            SourceReloadStatus(sourceID: sourceID)
            // Beschreibung, Herausgeber und Rubriken aus dem Feed.
            if let source { SourceMetadataSection(source: source) }
            // Nur einzelne Folgen geholt: der Podcast ist kein Abo und wird
            // nicht von selbst aktualisiert. Ein Tipp abonniert ihn, die
            // geholten Folgen bleiben.
            if let source, !source.isSubscribed {
                Section {
                    NoticeLabel(String(localized: """
                        Nicht abonniert. Hier stehen die Folgen, die du einzeln geholt hast. \
                        Neue Folgen kommen erst nach dem Abonnieren.
                        """), kind: .info)
                    Button {
                        Task { await model.subscribeToSource(source) }
                    } label: {
                        Label("Abonnieren", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("source.subscribe")
                }
            }

            if source?.kind == .youTubeChannel {
                YouTubeChannelTranscriptNotice()
                if model.allowsSupadataRequests, let source, AppModel.youTubeChannelID(of: source) != nil {
                    OlderYouTubeVideosSection(sourceID: sourceID)
                }
            } else if !(source?.capabilities.supportsTimedKnowledge ?? true),
               let reason = source?.capabilities.limitationReason {
                Section {
                    // Eine Grenze der Quelle, kein Fehler.
                    NoticeLabel(reason, kind: .info)
                        .font(.callout)
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
                        if model.canTranscribe(episode), model.stages[episode.id] == nil || model.stages[episode.id] == .failed {
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
                        if model.canTranscribe(episode) {
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
                            Text("Gemerkte Stellen und Notizen bleiben")
                        }
                    }
                }
            } header: {
                // Gefunden und ausgewertet sind getrennte Zahlen. Sie zu
                // vermischen würde behaupten, alles sei durchsuchbar.
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            EpisodeCoverageLine(sourceID: sourceID)
                            if matches != nil || options.onlyUnanalyzed {
                                Text(shown.count == 1 ? "1 Folge angezeigt" : "\(shown.count) Folgen angezeigt")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("episodes.coverage")
                        // In der Kopfzeile, nicht als eigene Zeile: gleich bei
                        // der Zahl, um die es geht.
                        backCatalogControls
                    }
                    .textCase(nil)
                }
            } footer: {
                // Der Feed eines YouTube-Kanals nennt nur die neuesten Videos.
                if source?.kind == .youTubeChannel {
                    Text("YouTube nennt nur die 15 neuesten Videos. Ältere lassen sich nicht nachladen. Die App behält jedes Video, das sie einmal gesehen hat.")
                }
            }
        }
        .yieldsAIWhileScrolling()
        .navigationTitle(source?.title ?? String(localized: "Folgen"))
        // Auf dem iPhone steht die Suche immer da. Sonst erscheint sie erst
        // beim Herunterziehen, und niemand weiß, dass es sie gibt.
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Titel und Shownotes durchsuchen")
        #else
        .searchable(text: $query, prompt: "Titel und Shownotes durchsuchen")
        #endif
        .task(id: SearchRequest(query: query, episodeCount: episodes.count)) { await search() }
        // Herunterziehen liest den Feed dieser einen Quelle neu.
        .refreshable {
            if let source, model.canReload(source) { await model.reloadSource(sourceID) }
        }
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
        .confirmationDialog("Ältere Folgen auch vorbereiten?", isPresented: $confirmBackCatalog,
                            titleVisibility: .visible) {
            Button("Vorbereiten") { model.setPreparesBackCatalog(true, for: sourceID) }
                .accessibilityIdentifier("episodes.confirmOlder")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(backCatalogQuestion)
        }
        .task { await model.loadEpisodes(for: sourceID) }
        // Was mit dieser Quelle geht und wie weit ihr Archiv zurückreicht.
        .toolbar {
            ToolbarItem {
                NavigationLink { SourceDetailView(sourceID: sourceID) } label: {
                    Label("Über diese Quelle", systemImage: "info.circle")
                }
            }
            if let source, model.canReload(source) {
                ToolbarItem { SourceReloadButton(source: source) }
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
        guard model.canTranscribe(episode) else { return false }
        let stage = model.stages[episode.id]
        guard stage == nil || stage == .failed else { return false }
        return model.analyzing?.id != episode.id
    }

    // MARK: Ältere Folgen vorbereiten

    /// Nur für Podcast-Feeds mit Ton. Einzelne Folgen und YouTube-Kanäle
    /// haben kein Archiv, das sich so nachholen ließe.
    private var offersBackCatalog: Bool {
        guard source?.kind == .podcastRSS, source?.isSubscribed == true else { return false }
        return model.preparesBackCatalog(sourceID) || model.hasOlderEpisodesToPrepare(in: sourceID)
    }

    /// Der Knopf „Ältere Folgen auch vorbereiten“ und, wenn er an ist, was
    /// noch offen ist, samt dem Weg zurück.
    @ViewBuilder private var backCatalogControls: some View {
        if offersBackCatalog {
            if model.preparesBackCatalog(sourceID) {
                Label(backCatalogStatus, systemImage: "clock.arrow.circlepath")
                    .accessibilityIdentifier("episodes.olderStatus")
                Button("Ältere Folgen nicht mehr vorbereiten") {
                    model.setPreparesBackCatalog(false, for: sourceID)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Nimmt die älteren Folgen aus der Warteschlange. Fertige Transkripte bleiben.")
                .accessibilityIdentifier("episodes.stopOlder")
            } else {
                Button { confirmBackCatalog = true } label: {
                    Label("Ältere Folgen auch vorbereiten", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Erstellt Transkripte für alle Folgen dieses Podcasts, neueste zuerst")
                .accessibilityIdentifier("episodes.prepareOlder")
            }
        }
    }

    /// „Bereitet auch ältere Folgen vor, noch 12 offen“, oder warum gerade nichts läuft.
    private var backCatalogStatus: String {
        guard model.automaticAnalysis else {
            return String(localized: """
                Ältere Folgen: startet, sobald „Transkripte für neue Folgen erstellen“ in den Einstellungen an ist.
                """)
        }
        if model.preparationUnavailable != nil {
            return String(localized: "Bereitet auch ältere Folgen vor, gerade angehalten.")
        }
        let open = model.openTranscriptCount(in: sourceID)
        let status = open > 0
            ? String(AttributedString(localized: "Bereitet auch ältere Folgen vor, noch ^[\(open) Folge](inflect: true) offen.").characters)
            : String(localized: "Bereitet auch ältere Folgen vor, gerade ist keine offen.")
        guard open > 0, let wait = model.preparationWait else { return status }
        return String(localized: "\(status) \(wait.settingsLabel).")
    }

    /// Die Rückfrage vor dem Einschalten: wie viele Folgen, wie viel ungefähr
    /// zu laden, und nach welchen Regeln.
    private var backCatalogQuestion: String {
        // Nur was der Knopf hinzunimmt. Die neuesten Folgen bereitet die App
        // ohnehin vor, und was schon auf dem Gerät liegt, wird nicht geladen.
        let older = model.olderEpisodesToPrepare(in: sourceID)
        var sentences = [
            EpisodeArchive.backCatalogSummary(older, toLoad: older.filter { !model.hasAudioForTranscript($0) }),
            String(localized: "Die App erstellt die Transkripte von selbst, neueste zuerst, und reiht neue Folgen davor ein."),
        ]
        if !model.automaticAnalysis {
            sentences.append(String(localized: """
                Das beginnt, sobald „Transkripte für neue Folgen erstellen“ in den Einstellungen an ist.
                """))
        }
        if model.preparationOnWiFiOnly {
            #if os(iOS)
            sentences.append(String(localized: "Geladen wird nur im WLAN."))
            #else
            sentences.append(String(localized: "Über einen Hotspot lädt die App dafür nichts."))
            #endif
        } else {
            // Die einzige Stelle, an der man vor dem Archiv gefragt wird. Sie
            // sagt auch, wenn es über Mobilfunk käme.
            #if os(iOS)
            sentences.append(String(localized: """
                Geladen wird auch über Mobilfunk, so ist es in den Einstellungen unter Mobilfunk eingestellt.
                """))
            #else
            sentences.append(String(localized: """
                Geladen wird auch über einen Hotspot, so ist es in den Einstellungen unter Intelligenz eingestellt.
                """))
            #endif
        }
        if model.removeAudioAfterAnalysis {
            sentences.append(String(localized: """
                Nach dem Transkript nimmt die App den Ton wieder vom Gerät, abgespielt wird dann aus dem Netz.
                """))
        }
        return sentences.joined(separator: " ")
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

            if episodes.contains(where: { model.canTranscribe($0) }) {
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
    /// als selbst angefordert, wie ein Tippen auf „Transkript erstellen“.
    /// Was schon wartet, rückt dabei nach vorn, neue Folgen kommen ans Ende.
    /// In beiden Gruppen bleibt die Reihenfolge der Liste. Abgespielt wird
    /// dabei nichts.
    private func analyzeSelection() {
        let ordered = options.oldestFirst ? EpisodeArchive.oldestFirst(episodes) : episodes
        let chosen = ordered.filter { selection.contains($0.id) && canQueue($0) }
        let waiting = Set(model.analysisQueue.map(\.id))
        // Jede wartende Folge springt an den Anfang. Rückwärts eingereiht,
        // steht die erste der Liste am Ende ganz vorn.
        for episode in chosen.reversed() where waiting.contains(episode.id) {
            model.enqueueAnalysis(episode)
        }
        for episode in chosen where !waiting.contains(episode.id) {
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

/// „12 von 80 Folgen mit Transkript“. Eine eigene Ansicht, weil sie die
/// Stufen aller Folgen liest: eine neue Stufe zeichnet nur diese Zeile neu,
/// nicht die ganze Liste.
private struct EpisodeCoverageLine: View {
    let sourceID: SourceID
    @Environment(AppModel.self) private var model

    var body: some View {
        let episodes = model.episodes[sourceID] ?? []
        let analyzed = episodes.count { model.stages[$0.id] == .evidenceExtracted }
        let automatic: EpisodeArchive.Automatic = !model.automaticAnalysis ? .off
            : model.preparationUnavailable != nil ? .paused
            : model.preparesBackCatalog(sourceID) ? .all
            : .newest(model.episodesPerSource)
        Text(EpisodeArchive.coverage(
            total: episodes.count, analyzed: analyzed,
            analyzable: episodes.contains { model.canTranscribe($0, byHand: false) }, automatic: automatic))
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
                    // Als Wort, nicht nur als Symbol: ein kleiner grauer Pfeil
                    // sagte nicht, dass die Folge ohne Netz spielt.
                    Label("Auf dem Gerät", systemImage: "arrow.down.circle.fill")
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
                    // Nur eine Störung trägt Farbe, und nur das Symbol.
                    Image(systemName: stage.symbol)
                        .symbolEffect(.pulse, isActive: stage.isRunning)
                        .foregroundStyle(stage == .failed ? Design.Notice.failure.tint : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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

            if !episode.canBeAnalyzed, !model.canTranscribe(episode), model.stages[episode.id] != .evidenceExtracted {
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
    /// Wartet in der Warteschlange. `ahead`: so viele Folgen laufen vorher.
    /// `detail`: ein eigener Grund, etwa der zweite Versuch. `heldBy`: das
    /// Netz hält die Folge an, weil die App sie von selbst eingereiht hat
    /// oder weil sie ohne Zustimmung über Mobilfunk laden müsste. Dann zählt
    /// keine Position, und von Hand lässt sie sich trotzdem starten.
    case waiting(ahead: Int, detail: String?, heldBy: AppModel.NetworkLimit?)
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
            // Was aufs Netz wartet, von selbst eingereiht oder im Mobilfunk
            // ohne Zustimmung, läuft nicht vorher. Der Worker überspringt es,
            // also zählt es auch hier nicht mit.
            let ahead = analysisQueue.prefix(index).filter(mayRunNow).count + (analyzing == nil ? 0 : 1)
            let detail = stageDetails[episode.id].flatMap { $0 == Self.waitingDetail ? nil : $0 }
            return .waiting(ahead: ahead, detail: detail, heldBy: queueWait(for: episode))
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
        // YouTube: Untertitel über Supadata, sonst der Audio-Podcast, sonst
        // ein ruhiger Satz, warum es nur Metadaten gibt.
        if isCaptionVideo(episode) { return youTubeTranscriptHint(for: episode) }
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
        case .waiting(_, _, .offline?):
            return String(localized: """
                Das Transkript dieser Folge steht in der Warteschlange und wartet auf Netz. Sobald es \
                fertig ist, kann ich mit Belegen aus dem Transkript antworten.
                """)
        case .waiting(_, _, let limit?):
            return String(localized: """
                Das Transkript dieser Folge steht in der Warteschlange (\(limit.queueDetail)). Tippe in der \
                Folge auf „Transkript jetzt erstellen“, danach kann ich mit Belegen aus dem Transkript antworten.
                """)
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
                Das Transkript dieser Folge ist fertig, aber es steht kein Text darin, also habe ich \
                keine Belege. Meist enthält die Folge dann kaum Sprache. Im Reiter „Transkript“ kannst \
                du es mit „Erneut versuchen“ noch einmal erstellen.
                """)
        }
    }
}

/// Was man tun kann, wenn das Transkript einer Folge aufs Netz wartet: es
/// jetzt erstellen lassen, über die Verbindung, die gerade besteht, oder
/// die Regel für alle Podcasts ändern. Steht in der Folge unter „Transkript“.
struct TranscriptWaitControls: View {

    let episode: Episode
    let wait: AppModel.NetworkLimit
    @Environment(AppModel.self) private var model

    var body: some View {
        // Ohne Netz gibt es nichts zu laden. Liegt der Ton auf dem Gerät,
        // wartet die Folge gar nicht erst.
        if wait != .offline {
            // Von Hand angefordert: im Mobilfunk mit ausgeschaltetem Schalter
            // fragt die App vorher, wie bei jedem anderen Laden auch.
            Button { model.enqueueAnalysis(episode) } label: {
                Label("Jetzt erstellen", systemImage: "waveform.badge.magnifyingglass")
            }
            .accessibilityHint("Lädt die Folge über die Verbindung, die gerade besteht")
            .accessibilityIdentifier("episode.transcriptNow")
        }
        if Self.offersPreparationToggle(for: wait, episode: episode, model: model) {
            Toggle(Self.preparationToggleTitle, isOn: Binding(
                get: { !model.preparationOnWiFiOnly },
                set: { model.preparationOnWiFiOnly = !$0 }
            ))
            .accessibilityIdentifier("episode.preparationCellular")
        }
    }

    /// Der Schalter hilft nur, wenn die Regel „Nur im WLAN“ die Folge
    /// anhält: von selbst eingereiht, im Mobilfunk oder Hotspot. Den
    /// Datensparmodus achtet die App immer.
    static func offersPreparationToggle(for wait: AppModel.NetworkLimit, episode: Episode, model: AppModel) -> Bool {
        (wait == .cellular || wait == .hotspot) && model.isQueuedAutomatically(episode.id)
    }

    /// Berechnet: `LocalizedStringKey` ist nicht `Sendable`.
    static var preparationToggleTitle: LocalizedStringKey {
        #if os(iOS)
        "Neue Folgen auch über Mobilfunk vorbereiten"
        #else
        "Neue Folgen auch über einen Hotspot vorbereiten"
        #endif
    }

    /// Ein Satz unter der Zeile, was Schalter und Knopf bewirken.
    @ViewBuilder
    static func footnote(for wait: AppModel.NetworkLimit, episode: Episode, model: AppModel) -> some View {
        if offersPreparationToggle(for: wait, episode: episode, model: model) {
            #if os(iOS)
            Text("Der Schalter gilt für alle Podcasts und steht auch in den Einstellungen unter Mobilfunk.")
            #else
            Text("Der Schalter gilt für alle Podcasts und steht auch in den Einstellungen unter Intelligenz.")
            #endif
        } else if wait == .lowDataMode {
            Text("Im Datensparmodus lädt die App nichts von selbst. „Jetzt erstellen“ lädt trotzdem.")
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
    /// Fertig und trotzdem ohne Belege, im Speicher nachgesehen. Direkt nach
    /// dem Fertigwerden lädt die Ansicht darüber ihre Stellen erst noch, und
    /// bis dahin soll hier kein falsches „leer“ aufblitzen.
    @State private var confirmedEmpty = false

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
                    controls(phase)
                } else if phase == .done {
                    controls(phase)
                } else {
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
                NoticeLabel(message, kind: .failure)
                    .font(.callout)
            }
            Button { model.enqueueAnalysis(episode) } label: {
                Label("Erneut versuchen", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("episode.analyze")
        case .waiting(_, _, let limit?):
            // Nichts läuft, also kein Kreisel. Der Grund steht da, und von
            // Hand geht es trotzdem los, außer ganz ohne Netz.
            Label(limit.settingsLabel, systemImage: limit.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            if limit != .offline { startNowButton.buttonStyle(.bordered) }
        case .waiting(let ahead, let detail, nil):
            progress(detail.map(Self.sentence) ?? Self.waitingDescription(ahead))
        case .running(let stage):
            progress(Self.stepDescription(stage))
        case .done:
            emptyTranscriptNote
        case .unavailable:
            // Bei YouTube ohne Schlüssel: der Weg zur Einstellung.
            if model.youTubeHintNeedsKey(episode) {
                NavigationLink {
                    SupadataSettingsView()
                } label: {
                    Label("Supadata-Schlüssel eintragen", systemImage: "key")
                }
                .accessibilityIdentifier("episode.supadataSettings")
            }
        }
    }

    /// Stellt eine Folge, die aufs Netz wartet, von Hand an den Anfang. Sie
    /// lädt dann über die Verbindung, die gerade da ist.
    private var startNowButton: some View {
        Button { model.enqueueAnalysis(episode) } label: {
            Label("Transkript jetzt erstellen", systemImage: "waveform.badge.magnifyingglass")
        }
        .accessibilityHint("Lädt die Folge über die Verbindung, die gerade besteht")
        .accessibilityIdentifier("episode.analyze")
    }

    /// Fertig, aber ohne Text. Das passiert, wenn die Spracherkennung in der
    /// Folge nichts verstanden hat. Ohne diesen Satz stünde hier „noch kein
    /// Transkript“ oder gar nichts, als liefe noch etwas.
    private var emptyTranscriptNote: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            if confirmedEmpty {
                Text("""
                    Das Transkript ist fertig, aber es steht kein Text darin. Meist enthält die Folge \
                    dann kaum Sprache, zum Beispiel nur Musik.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button { model.enqueueAnalysis(episode) } label: {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("episode.analyze")
            }
        }
        .task(id: model.stages[episode.id]) {
            // Nach einem neuen Versuch gilt das alte Ergebnis nicht mehr.
            confirmedEmpty = false
            confirmedEmpty = await model.evidence(forEpisode: episode.id).isEmpty
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
        case .waiting(_, _, let limit?):
            bannerRow {
                Image(systemName: limit.symbol)
                    .accessibilityHidden(true)
                Text(limit.settingsLabel)
                if limit != .offline {
                    Spacer(minLength: Design.Spacing.small)
                    startNowButton
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        case .waiting(let ahead, let detail, nil):
            bannerRow {
                ProgressView().controlSize(.small)
                Text(detail.map(Self.sentence) ?? Self.waitingDescription(ahead))
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

    /// Ein Zustand aus der Warteschlange, etwa „wartet auf zweiten Versuch“,
    /// als Satz mit großem Anfang.
    static func sentence(_ detail: String) -> String {
        detail.prefix(1).uppercased() + detail.dropFirst()
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

/// Gemerkte Stellen und ihr Weg nach draußen.
struct KnowledgeView: View {

    @Environment(AppModel.self) private var model
    @State private var exported: String?
    @State private var editing: Highlight?
    @State private var editText = ""
    /// Folgen, die noch da sind. `nil`, solange das noch nicht geprüft ist.
    @State private var availableEpisodes: [EpisodeID: Episode]?
    /// Für die VoiceOver-Aktionen der Zeilen: ansagen, was passiert ist.
    @Environment(\.confirm) private var confirm

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
                    Button { edit(highlight) } label: {
                        Label("Kommentar", systemImage: "square.and.pencil")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    NoteActions(highlight: highlight, playable: isPlayable(highlight),
                                edit: { edit(highlight) }, deletable: true)
                }
            }
        }
        .yieldsAIWhileScrolling()
        .navigationTitle("Gemerkte Stellen")
        .task(id: model.highlights.compactMap(\.episodeID)) {
            model.fillMissingNoteTitles()
            availableEpisodes = await model.noteEpisodes(for: model.highlights)
        }
        // „Mit Quelle kopiert“ und „Spielt ab 4:00“.
        .confirmationBanner()
        .sheet(item: $editing) { highlight in
            NoteSheet(position: highlight.positionMs.map { Double($0) / 1000 }, quote: highlight.quote,
                      text: $editText) {
                model.updateNote(highlight.id, text: editText)
            }
            .presentationDetents([.medium])
            .sheetFeedback()
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
            ExportPreviewSheet(text: preview.text, fileName: String(localized: "Gemerkte Stellen"))
                .sheetFeedback()
        }
    }

    private func edit(_ highlight: Highlight) {
        editing = highlight
        editText = highlight.note ?? ""
    }

    private func episode(of highlight: Highlight) -> Episode? {
        highlight.episodeID.flatMap { availableEpisodes?[$0] }
    }

    /// Abspielbar ist eine Notiz nur mit Folge und Zeitmarke.
    private func isPlayable(_ highlight: Highlight) -> Bool {
        episode(of: highlight) != nil && highlight.positionMs != nil
    }

    /// Ein Tipp auf die Zeile öffnet die Folge und startet keinen Ton.
    /// Abgespielt wird über den eigenen Knopf, der die Zeitmarke nennt.
    /// Kopieren, Teilen, Bearbeiten und Löschen stehen im Menü „…“. Ohne
    /// Folge bleibt die Zeile zum Lesen, das Menü zum Kopieren gibt es trotzdem.
    @ViewBuilder
    private func noteRow(_ highlight: Highlight) -> some View {
        let gone = highlight.episodeID.map { id in availableEpisodes.map { $0[id] == nil } ?? false } ?? false
        let controls = HStack(spacing: Design.Spacing.none) {
            if isPlayable(highlight) { NotePlayButton(highlight: highlight) }
            NoteActionsMenu(highlight: highlight, playable: isPlayable(highlight),
                            edit: { edit(highlight) }, deletable: true)
        }
        if let episode = episode(of: highlight) {
            NavigationLink {
                EpisodeDetailView(episode: episode)
            } label: {
                HStack(alignment: .top, spacing: Design.Spacing.small) {
                    NoteRow(highlight: highlight).frame(maxWidth: .infinity, alignment: .leading)
                    controls
                }
            }
            .accessibilityHint("Öffnet die Folge. Abspielen und Kopieren unter Aktionen.")
            .accessibilityAction(named: "Abspielen") {
                NoteActions.play(highlight, model: model, confirm: confirm)
            }
            .accessibilityAction(named: "Mit Quelle kopieren") {
                Clipboard.copy(model.noteCitation(highlight))
                confirm(NoteFeedback.copied)
            }
        } else {
            HStack(alignment: .top, spacing: Design.Spacing.small) {
                NoteRow(highlight: highlight, episodeGone: gone).frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
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
    /// Wie die Datei heißt, ohne Endung, etwa der Titel der Folge. Ohne
    /// Angabe gilt die erste Überschrift des Exports.
    var fileName: String? = nil
    @Environment(\.dismiss) private var dismiss
    /// Die Markdown-Datei, die geteilt wird. Geteilt wurde vorher ein
    /// String, und „In Dateien sichern“ legte „Text.txt“ ab.
    @State private var file: URL?
    @State private var copied = false

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
                    if let file {
                        ShareLink(item: file) { Label("Teilen", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("export.share")
                    } else {
                        ShareLink(item: text) { Label("Teilen", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("export.share")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Clipboard.copy(text)
                        copied = true
                        AccessibilityNotification.Announcement(String(localized: "Text kopiert")).post()
                    } label: {
                        Label(copied ? "Kopiert" : "Text kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("export.copy")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task(id: text) {
            MarkdownFile.remove(file)
            file = MarkdownFile.write(text, named: fileName ?? MarkdownFile.title(of: text))
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        .onDisappear { MarkdownFile.remove(file) }
    }
}

/// Der Export als echte Datei mit Endung .md, benannt nach seinem Inhalt.
/// Sie liegt in einem eigenen Ordner im temporären Verzeichnis, damit zwei
/// Exporte mit gleichem Titel sich nicht überschreiben.
enum MarkdownFile {

    static func write(_ text: String, named title: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(fileName(title) + ".md", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Entfernt die Datei samt ihrem Ordner, sobald das Blatt zu ist.
    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Ein Dateiname aus dem Titel: ohne Zeichen, die Dateisysteme nicht
    /// mögen, ohne Zeilenumbrüche und nicht zu lang. Aus „Titel: Untertitel“
    /// wird „Titel - Untertitel“.
    static func fileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines).union(.controlCharacters)
        let cleaned = title.replacingOccurrences(of: ": ", with: " - ")
            .components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let short = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "PodcastAI" : short
    }

    /// Die erste Überschrift des Exports, ohne Markdown-Maskierung.
    static func title(of markdown: String) -> String {
        guard let heading = markdown.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) else {
            return "PodcastAI"
        }
        return String(heading.dropFirst(2)).replacingOccurrences(of: "\\", with: "")
    }
}

/// Was ein YouTube-Kanal an Transkripten hergibt, oben in seiner Folgenliste.
/// Mit Schlüssel holt die App die Untertitel; ohne sagt sie das ruhig und
/// zeigt den Weg zur Einstellung.
struct YouTubeChannelTranscriptNotice: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if !model.youTubeCaptionsEnabled {
                NoticeLabel("„YouTube-Transkripte über Supadata“ ist in den Einstellungen aus. Es gibt hier Titel, Beschreibung und Kapitel.",
                            kind: .info)
                    .font(.callout)
            } else if model.hasSupadataKey && !model.supadataKeyRejected {
                Label("Transkripte aus den Untertiteln von YouTube, geholt über Supadata. Ein Tipp auf eine Stelle öffnet das Video dort.",
                      systemImage: "captions.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                NoticeLabel(model.supadataKeyRejected
                            ? "Supadata hat den eingetragenen Schlüssel abgelehnt. Bis du einen neuen einträgst, holt die App keine Untertitel."
                            : "Zu YouTube-Videos gibt es hier Titel, Beschreibung und Kapitel. Mit eigenem Supadata-Schlüssel gibt es hier ein Transkript.",
                            kind: .info)
                    .font(.callout)
                NavigationLink {
                    SupadataSettingsView()
                } label: {
                    Label("Supadata-Schlüssel eintragen", systemImage: "key")
                }
            }
        }
    }
}

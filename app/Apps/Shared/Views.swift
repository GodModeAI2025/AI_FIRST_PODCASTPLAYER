//
//  Views.swift
//  PodcastAI
//
//  Die gemeinsamen Oberflächen. Plattformunterschiede stecken in den
//  Wurzelansichten der beiden App-Targets, nicht hier.
//

import SwiftUI
import PodcastAIKit

// MARK: - Für dich

/// Der Einstieg. Nicht „neue Folgen“, sondern „was davon solltest du wissen“.
struct ForYouView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.profile.confirmed.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Interessen", systemImage: "sparkles")
                } description: {
                    Text("PodcastAI zeigt dir erst dann relevante Stellen, wenn es weiß, "
                         + "wonach du suchst.")
                } actions: {
                    NavigationLink("Interessen anlegen") { InterestsView() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.relevantToday.isEmpty {
                ContentUnavailableView {
                    Label("Nichts Neues", systemImage: "checkmark.circle")
                } description: {
                    Text("Zu deinen Themen gibt es gerade keine ungehörten Stellen.")
                }
            } else {
                ForEach(model.relevantToday) { item in
                    RelevantItemRow(item: item)
                        .listRowInsets(EdgeInsets(top: Design.Spacing.small,
                                                  leading: Design.Spacing.standard,
                                                  bottom: Design.Spacing.small,
                                                  trailing: Design.Spacing.standard))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Für dich")
        .refreshable { await model.refreshAll() }
        .toolbar {
            NavigationLink { QueueView() } label: {
                Label("Warteschlange", systemImage: "list.bullet")
            }
        }
    }
}

struct RelevantItemRow: View {

    let item: RelevantItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.playRelevantItemInEpisode(item)
        } label: {
            content.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Spielt die Folge ab dieser Stelle")
        .contextMenu {
            Button { model.playRelevantItemInEpisode(item) } label: {
                Label("In der Folge ab hier hören", systemImage: "play.fill")
            }
            Button { model.playRelevantItem(item) } label: {
                Label("Nur diese Stelle hören", systemImage: "scope")
            }
        }
    }

    private var partlyHeard: Bool {
        guard let id = item.mediaVersionID else { return false }
        return model.ledger.heard(in: id).coverage(of: item.range) > 0.05
    }

    private var content: some View {
        card
            .padding(Design.Spacing.standard)
            .background(.background.secondary, in: .rect(cornerRadius: Design.Radius.card, style: .continuous))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            // Hierarchie über Gewicht und Farbe, nicht über Schriftwechsel:
            // Quelle zurückgenommen, Folge als Überschrift, Zitat als Text.
            HStack(spacing: Design.Spacing.micro) {
                Text(item.sourceTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                // Der Timecode steht sichtbar dabei. Er ist kein technisches
                // Detail, sondern das Versprechen: das hier kannst du nachhören.
                TimecodeLabel(item.range, emphasis: .medium)
                Spacer(minLength: 0)
                Image(systemName: partlyHeard ? "circle.lefthalf.filled" : "play.circle")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(partlyHeard ? "teilweise gehört" : "noch nicht gehört")
            }

            Text(item.episodeTitle)
                .font(.headline)
                .lineLimit(2)

            Text(item.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let relevance = item.relevance {
                // „Warum sehe ich das?“ steht hier und nicht hinter einem
                // Info-Symbol. Wer die Begründung suchen muss, glaubt sie nicht.
                Label {
                    Text(relevance.explanation)
                } icon: {
                    Image(systemName: "target")
                }
                .font(.caption)
                .foregroundStyle(.tint)
                .padding(.horizontal, Design.Spacing.small)
                .padding(.vertical, Design.Spacing.micro)
                .background(.tint.opacity(0.12), in: .capsule)
                .padding(.top, Design.Spacing.micro)
            }
        }
        .padding(.vertical, Design.Spacing.small)
        // Für VoiceOver eine Einheit statt fünf Fragmente.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [item.episodeTitle, "aus \(item.sourceTitle)",
                     TimecodeLabel.spoken("\(item.range.start.timecode)–\(item.range.end.timecode)")]
        if let relevance = item.relevance { parts.append(relevance.explanation) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Meine Feeds

struct SmartFeedListView: View {

    @Environment(AppModel.self) private var model
    @State private var showingNewFeed = false

    var body: some View {
        List {
            if model.smartFeeds.isEmpty {
                ContentUnavailableView {
                    Label("Noch kein Themen-Update", systemImage: "waveform.circle")
                } description: {
                    Text("Aus deinen Interessen kann PodcastAI einen eigenen Podcast bauen — "
                         + "aus den Originalstellen, die du noch nicht gehört hast.")
                } actions: {
                    Button("Themen-Update anlegen") { showingNewFeed = true }
                }
            }
            ForEach(model.smartFeeds) { feed in
                NavigationLink(value: feed.id) {
                    SmartFeedRow(feed: feed, editions: model.editions[feed.id] ?? [])
                }
            }
        }
        .navigationTitle("Meine Feeds")
        .navigationDestination(for: SmartFeedID.self) { feedID in
            if let latest = model.editions[feedID]?.first {
                PersonalEpisodeView(episode: latest)
            } else {
                // Kein leerer Bildschirm: der Zustand "noch keine Ausgabe"
                // ist ein eigener Zustand mit einer Handlung daran.
                SmartFeedEmptyView(feedID: feedID)
            }
        }
        .toolbar {
            Button { showingNewFeed = true } label: {
                Label("Neu", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingNewFeed) { NewSmartFeedSheet() }
    }
}

struct SmartFeedRow: View {

    let feed: SmartPodcastFeed
    let editions: [PersonalEpisode]

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            // Ein Themenfeed sieht aus wie ein Podcast — das ist Kapitel 7,
            // und es hing bis hierher an einem Renderer ohne Aufrufer.
            if let latest = editions.first {
                CoverView(
                    cover: NativeCoverRenderer().makeCover(for: latest, feedTitle: feed.title),
                    size: 56)
            }
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(feed.title).font(.headline)
                if let latest = editions.first {
                    Text("\(latest.title) · \(latest.totalMediaDuration.shortDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(feed.editionMode.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Eine persönliche Ausgabe — sieht aus wie eine Podcastfolge, besteht aber
/// aus Originalstellen.
struct PersonalEpisodeView: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Design.Spacing.control) {
                    if let cover = model.cover(for: episode) {
                        CoverView(cover: cover, size: 120)
                    }
                    Text(episode.title)
                        .font(.title2.weight(.bold))
                    if let subtitle = episode.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Label {
                        Text("\(episode.segments.count) Stellen · "
                             + "\(episode.distinctSourceCount) Quellen · "
                             + "\(episode.totalMediaDuration.shortDescription)")
                    } icon: {
                        Image(systemName: "waveform")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // Die primäre Aktion: gefüllt, getintet, in voller Breite.
                    // Sie ist die einzige gefüllte Schaltfläche auf diesem
                    // Bildschirm — sonst wäre keine mehr primär.
                    Button(action: play) {
                        Label("Abspielen", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityHint("Spielt \(episode.segments.count) Originalstellen nacheinander ab")
                }
                .padding(.vertical, Design.Spacing.small)
            }

            Section("Kapitel") {
                ForEach(Array(episode.shownotes.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.control) {
                            TimecodeLabel(entry.virtualStart, emphasis: .medium)
                                // Feste Breite, damit die Titel eine Kante
                                // bilden statt zu flattern.
                                .frame(width: 52, alignment: .leading)
                            Text(entry.title)
                                .font(.body)
                        }
                        // Jedes Kapitel zeigt seine Originalquelle. Ohne das
                        // wäre die Ausgabe ein Zusammenschnitt ohne Herkunft.
                        Text("\(entry.sourceTitle) · \(entry.episodeTitle) · "
                             + "Original \(entry.originalRange.start.timecode)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 52 + Design.Spacing.control)
                    }
                    .padding(.vertical, Design.Spacing.micro)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(TimecodeLabel.spokenSingle(entry.virtualStart.timecode)), "
                        + "\(entry.title), aus \(entry.sourceTitle)"
                    )
                }
            }

            Section {
                Text(episode.coverage.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Umfang")
            } footer: {
                if episode.segments.contains(where: \.contextReplay) {
                    Text("Einzelne Abschnitte beginnen mit ein paar Sekunden Kontext, "
                         + "die du eventuell schon gehört hast.")
                }
            }
        }
        .navigationTitle(episode.title)
    }

    private func play() {
        let plan = ValidatedPlaybackPlan(
            segments: episode.segments.map { segment in
                PlanSegment(
                    evidenceID: segment.evidenceIDs.first ?? EvidenceID(),
                    mediaVersionID: segment.mediaVersionID,
                    episodeID: segment.episodeID,
                    sourceID: segment.sourceID,
                    range: segment.playbackRange,
                    sourceTitle: segment.sourceTitle,
                    episodeTitle: segment.episodeTitle,
                    rationale: segment.reason
                )
            },
            requestSummary: episode.title,
            route: .smartFeedEpisode
        )
        model.play(plan, from: .tap)
    }
}

// MARK: - Mediathek

struct LibraryView: View {

    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var pendingRemoval: Source?

    var body: some View {
        List {
            if !model.sources.isEmpty {
                Section {
                    NavigationLink { QueueView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Warteschlange")
                                Text(queueSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet")
                        }
                    }
                }
            }
            Section {
                ForEach(model.sources) { source in
                    NavigationLink(value: source.id) {
                        SourceRow(source: source)
                    }
                    .swipeActions {
                        Button(role: .destructive) { pendingRemoval = source } label: {
                            Label("Abbestellen", systemImage: "minus.circle")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { pendingRemoval = source } label: {
                            Label("Abbestellen und Daten löschen", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Mediathek")
        .confirmationDialog("Abbestellen?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { source in
            Button("\(source.title) abbestellen", role: .destructive) {
                Task { await model.removeSource(source.id) }
            }
        } message: { _ in
            Text("Alle Folgen dieser Quelle werden mit Transkripten, Fakten und Hörstand gelöscht.")
        }
        .navigationDestination(for: SourceID.self) { sourceID in
            EpisodeListView(sourceID: sourceID)
        }
        .toolbar {
            Button { showingAdd = true } label: {
                Label("Quelle hinzufügen", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingAdd) { AddSourceSheet() }
        .overlay {
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Keine Quellen", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Füge einen Podcast-Feed, eine einzelne Folge oder einen "
                         + "YouTube-Kanal hinzu.")
                } actions: {
                    Button("Quelle hinzufügen") { showingAdd = true }
                }
            }
        }
    }
}

extension LibraryView {
    var queueSummary: String {
        let listen = model.upNext.count
        let analyze = model.analysisQueue.count + (model.analyzing == nil ? 0 : 1)
        if listen == 0 && analyze == 0 { return "Nichts vorgemerkt" }
        var parts: [String] = []
        if listen > 0 { parts.append(listen == 1 ? "1 Folge zum Hören" : "\(listen) Folgen zum Hören") }
        if analyze > 0 { parts.append(analyze == 1 ? "1 wird erschlossen" : "\(analyze) werden erschlossen") }
        return parts.joined(separator: " · ")
    }
}

struct SourceRow: View {

    let source: Source

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
        EpisodeArtwork(url: source.artworkURL, size: 52)
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(source.title).font(.headline).lineLimit(2)
            if let author = source.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // Grenzen werden angezeigt, nicht versteckt. Ein Kanal ohne
            // Audiozugang soll nicht so aussehen wie einer mit.
            if !source.capabilities.supportsTimedKnowledge,
               let reason = source.capabilities.limitationReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        }
    }
}

struct AddSourceSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse einfügen", text: $input, axis: .vertical)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Quelle")
                } footer: {
                    Text("Ein Podcast-Feed, eine einzelne Folge oder ein YouTube-Link. "
                         + "Abonnieren lädt nichts herunter — was verarbeitet wird, "
                         + "entscheidest du danach.")
                }
            }
            .navigationTitle("Quelle hinzufügen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        Task { await model.addSource(from: input); dismiss() }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Interessen

struct InterestsView: View {

    @Environment(AppModel.self) private var model
    @State private var newLabel = ""
    @State private var newKind: InterestKind = .topic

    var body: some View {
        List {
            Section {
                ForEach(model.profile.topics) { interest in
                    InterestRow(interest: interest)
                }
                .onDelete { offsets in remove(model.profile.topics, at: offsets) }
            } header: {
                Text("Themen")
            } footer: {
                Text("Diese Themen hast du bestätigt. Nur sie lösen persönliche Ausgaben aus.")
            }

            if !model.profile.activeProjects.isEmpty {
                Section("Aktuell") {
                    ForEach(model.profile.activeProjects) { InterestRow(interest: $0) }
                }
            }

            if !model.profile.openQuestions.isEmpty {
                Section("Offene Fragen") {
                    ForEach(model.profile.openQuestions) { InterestRow(interest: $0) }
                }
            }

            // Vorgeschlagenes bleibt sichtbar getrennt von Bestätigtem.
            if !model.profile.suggested.isEmpty {
                Section {
                    ForEach(model.profile.suggested) { interest in
                        HStack {
                            InterestRow(interest: interest)
                            Spacer()
                            // Beide Knöpfe taten nichts. „Übernehmen“ war
                            // ein leerer Block, „Ablehnen“ gab es nicht —
                            // ein Vorschlag, den man nicht loswird, ist
                            // keine Transparenz, sondern eine Zumutung.
                            Button("Übernehmen") { model.confirmSuggestion(interest.id) }
                                .buttonStyle(.bordered)
                            Button("Ablehnen") { model.rejectSuggestion(interest.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Vorschläge von PodcastAI")
                } footer: {
                    Text("Vermutet, nicht bestätigt. Sie wirken erst, wenn du sie übernimmst.")
                }
            }

            Section {
                Picker("Art", selection: $newKind) {
                    Text("Thema").tag(InterestKind.topic)
                    Text("Aktuelles Vorhaben").tag(InterestKind.activeProject)
                    Text("Offene Frage").tag(InterestKind.openQuestion)
                }
                Text(kindExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("interest.kind.explanation")
                TextField(placeholder, text: $newLabel)
                Button("Hinzufügen") {
                    let label = newLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    Task { await model.addInterest(label, kind: newKind); newLabel = "" }
                }
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Hinzufügen")
            }
        }
        .navigationTitle("Interessen")
    }

    private var kindExplanation: String {
        switch newKind {
        case .topic:
            "Ein Gebiet, das dich dauerhaft interessiert. Themen füllen „Für dich“ und sind die Grundlage für Themen-Updates."
        case .activeProject:
            "Etwas, woran du gerade arbeitest. Passende Stellen werden höher eingestuft, solange das Vorhaben aktuell ist. Die Begründung lautet dann „Passt zu deinem Vorhaben“."
        case .openQuestion:
            "Eine konkrete Frage, auf die du eine Antwort suchst. Die App markiert Stellen, die sie berühren könnten, und nimmt die Frage beim Erschliessen mit."
        }
    }

    private var placeholder: String {
        switch newKind {
        case .topic: "z. B. Datenschutz"
        case .activeProject: "z. B. Lokale KI-Modelle bewerten"
        case .openQuestion: "z. B. Was bietet iOS 27 für agentische Apps?"
        }
    }

    private func remove(_ interests: [Interest], at offsets: IndexSet) {
        for index in offsets {
            let id = interests[index].id
            Task { await model.removeInterest(id) }
        }
    }
}

struct InterestRow: View {

    let interest: Interest

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
            Text(interest.label)
            Text(interest.origin.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NewSmartFeedSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var selected: Set<InterestID> = []
    @State private var minutes = 20
    @State private var newTopic = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. Mein KI Update", text: $title)
                }
                Section {
                    ForEach(model.profile.topics) { interest in
                        Button {
                            if selected.contains(interest.id) { selected.remove(interest.id) }
                            else { selected.insert(interest.id) }
                        } label: {
                            HStack {
                                Text(interest.label).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(interest.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        // Das Häkchen ist für VoiceOver kein Zustand. Ohne
                        // diesen Zusatz klingen ausgewählte und nicht
                        // ausgewählte Themen identisch.
                        .accessibilityAddTraits(
                            selected.contains(interest.id) ? [.isButton, .isSelected] : .isButton
                        )
                    }
                    // Themen direkt hier anlegen. Vorher war die Liste leer,
                    // solange unter „Wissen › Interessen“ nichts stand, und
                    // „Anlegen“ blieb ohne Hinweis gesperrt.
                    HStack {
                        TextField("Neues Thema, z. B. KI-Modelle", text: $newTopic)
                            .onSubmit(addTopic)
                        Button("Hinzufügen", action: addTopic)
                            .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Themen")
                } footer: {
                    if model.profile.topics.isEmpty {
                        Text("Lege mindestens ein Thema an. Es wird auch unter „Wissen › Interessen“ gespeichert.")
                    } else {
                        Text("Antippen wählt ein Thema ab oder wieder aus. Ein eingetipptes Thema wird beim Anlegen mitgenommen.")
                    }
                }
                Section {
                    Stepper("\(minutes) Minuten je Ausgabe", value: $minutes, in: 5...120, step: 5)
                } footer: {
                    Text("„Alles Ungehörte“ ist ein eigener Modus und ausdrücklich etwas "
                         + "anderes als ein kurzes Update.")
                }
            }
            .navigationTitle("Themen-Update")
            .onAppear {
                // Alle Themen sind vorausgewählt. Wer nichts abwählt, bekommt
                // ein Update über alles, was ihn interessiert.
                if selected.isEmpty { selected = Set(model.profile.topics.map(\.id)) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Der Knopf legte bisher nichts an, er schloss nur das
                    // Blatt. Das Themen-Update — das sichtbarste Merkmal des
                    // Konzepts — war damit nicht erreichbar.
                    Button("Anlegen") {
                        Task { await create() }
                    }
                    // Gesperrt nur, wenn es wirklich nichts anzulegen gibt.
                    // Vorher blieb der Knopf grau, solange kein Thema
                    // angehakt war, ohne dass man das sehen konnte.
                    .disabled(!canCreate)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private var pendingTopic: String { newTopic.trimmingCharacters(in: .whitespaces) }

    private var canCreate: Bool {
        !selected.isEmpty || !pendingTopic.isEmpty
    }

    private func create() async {
        var topicIDs = model.profile.topics.map(\.id).filter(selected.contains)
        if !pendingTopic.isEmpty, let id = await model.addInterest(pendingTopic, kind: .topic) {
            topicIDs.append(id)
            newTopic = ""
        }
        guard !topicIDs.isEmpty else { return }
        let labels = model.profile.topics.filter { topicIDs.contains($0.id) }.map(\.label)
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? (labels.isEmpty ? "Mein Update" : labels.prefix(2).joined(separator: " und "))
            : title
        let feedID = model.createSmartFeed(title: name, topicIDs: topicIDs, minutes: minutes)
        dismiss()
        // Gleich eine erste Ausgabe bauen: ein leerer Feed direkt nach dem
        // Anlegen sieht aus wie ein Fehler.
        await model.buildEdition(feedID: feedID)
    }

    private func addTopic() {
        let label = newTopic.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        newTopic = ""
        Task {
            if let id = await model.addInterest(label, kind: .topic) { selected.insert(id) }
        }
    }
}

// MARK: - Player

struct FocusPlayerView: View {

    @Environment(AppModel.self) private var model
    @State private var showingNote = false
    @State private var note = ""

    /// Der Abschnitt des Plans, auch während er vorbereitet wird oder pausiert.
    private var activeSegmentIndex: Int? {
        switch model.playerState {
        case .playing(let index), .paused(let index), .preparing(let index): index
        default: nil
        }
    }

    private var isPaused: Bool {
        if case .paused = model.playerState { true } else { false }
    }

    var body: some View {
        VStack(spacing: Design.Spacing.standard) {
            // Gespiegelter Zustand, nicht der Koordinator: `PlaybackCoordinator`
            // ist nicht beobachtbar, eine Ansicht darauf bliebe stehen.
            if let plan = model.playerPlan,
               let index = activeSegmentIndex,
               index < plan.segments.count {
                let segment = plan.segments[index]

                Text(segment.sourceTitle)
                    .font(.caption).foregroundStyle(.secondary)
                Text(segment.episodeTitle)
                    .font(.headline).multilineTextAlignment(.center)
                Text("\(segment.range.start.timecode)–\(segment.range.end.timecode)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                if let rationale = segment.rationale {
                    Text(rationale)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text("Stelle \(index + 1) von \(plan.segments.count)")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack(spacing: Design.Spacing.large) {
                    // Pausiert bleibt der Plan sichtbar. Auf dem Mac gibt es
                    // sonst keinen Weg zurück, weil dort die Fokusleiste fehlt.
                    Button {
                        isPaused ? model.resumePlayback() : model.pausePlayback()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                            .tappableArea()
                    }
                    .accessibilityLabel(isPaused ? "Fortsetzen" : "Pausieren")

                    Button { model.skipSegment() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title)
                            .tappableArea()
                    }
                    .accessibilityLabel("Diese Stelle überspringen")
                    .accessibilityHint("Der übersprungene Teil zählt nicht als gehört")

                    Button { model.stopPlayback() } label: {
                        Image(systemName: "stop.fill")
                            .font(.title)
                            .tappableArea()
                    }
                    .accessibilityLabel("Wiedergabe beenden")
                }
                .buttonStyle(.pressable)

                // „Merken“ gab es bisher nur als Kurzbefehl — in der App
                // selbst führte kein Weg dorthin. Das Kapitel „Highlights
                // und Wissen“ beginnt aber hier, beim Hören.
                Button {
                    showingNote = true
                } label: {
                    Label("Diese Stelle merken", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .disabled(model.player.currentOriginalPosition() == nil)
            } else {
                ContentUnavailableView(
                    "Nichts wird abgespielt",
                    systemImage: "speaker.slash",
                    description: Text("Starte eine Ausgabe oder eine Stelle aus „Für dich“.")
                )
            }
        }
        .padding()
        .navigationTitle("Wiedergabe")
        .sheet(isPresented: $showingNote) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Notiz (optional)", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                    } footer: {
                        Text("Gemerkt wird die Stelle, die gerade gelaufen ist — "
                             + "mit Quelle, Timecode und Originaltext. Deine Notiz bleibt "
                             + "davon getrennt und wird nie überschrieben.")
                    }
                }
                .navigationTitle("Stelle merken")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Merken") { remember() }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { showingNote = false; note = "" }
                    }
                }
            }
        }
    }

    private func remember() {
        guard let (mediaVersionID, position) = model.player.currentOriginalPosition() else {
            showingNote = false
            return
        }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        showingNote = false
        note = ""
        Task {
            await model.rememberPassage(
                at: position, in: mediaVersionID,
                note: text.isEmpty ? nil : text, via: .player)
        }
    }
}


/// Ein Themenfeed ohne Ausgabe. „Noch nichts da“ ist ein Zustand mit einer
/// Handlung daran, kein leerer Bildschirm.
struct SmartFeedEmptyView: View {

    let feedID: SmartFeedID
    @Environment(AppModel.self) private var model
    @State private var message: String?

    var body: some View {
        ContentUnavailableView {
            Label("Noch keine Ausgabe", systemImage: "waveform.circle")
        } description: {
            Text(message ?? "Sobald genug ungehörtes Material zu deinen Themen vorliegt, "
                 + "entsteht daraus eine Ausgabe.")
        } actions: {
            Button("Jetzt zusammenstellen") {
                Task { message = await model.buildEdition(feedID: feedID) }
            }
        }
        .navigationTitle(model.smartFeeds.first { $0.id == feedID }?.title ?? "Themen-Update")
    }
}

struct SourceDetailView: View {

    let sourceID: SourceID
    @Environment(AppModel.self) private var model

    private var source: Source? { model.sources.first { $0.id == sourceID } }

    var body: some View {
        List {
            if let source {
                Section("Quelle") {
                    LabeledContent("Titel", value: source.title)
                    if let author = source.author {
                        LabeledContent("Herausgeber", value: author)
                    }
                    LabeledContent("Historie", value: source.backfillPolicy.label)
                }
                Section {
                    // Fähigkeiten einzeln und ehrlich: ein Kanal ohne
                    // Audiozugang soll nicht aussehen wie einer mit.
                    CapabilityRow(title: "Audio abrufbar",
                                  isAvailable: source.capabilities.audioDownload)
                    CapabilityRow(title: "Transkript vom Anbieter",
                                  isAvailable: source.capabilities.publisherTranscript)
                    CapabilityRow(title: "Gesamtes Archiv",
                                  isAvailable: source.capabilities.historicalCatalog)
                } header: {
                    Text("Was mit dieser Quelle geht")
                } footer: {
                    if let reason = source.capabilities.limitationReason {
                        Text(reason)
                    }
                }
            }
        }
        .navigationTitle(source?.title ?? "Quelle")
    }
}

struct CapabilityRow: View {

    let title: String
    let isAvailable: Bool

    var body: some View {
        HStack {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isAvailable ? .green : .secondary)
            Text(title)
        }
    }
}


/// Platzhalter während des Ladens.
///
/// Ein Kreisel sagt „es passiert etwas“. Ein Platzhalter in der Form des
/// erwarteten Inhalts sagt zusätzlich, *was* gleich da sein wird — und der
/// Sprung beim Erscheinen ist kleiner, weil das Layout schon steht.
struct SkeletonRow: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            bar(width: 120, height: 11)
            bar(width: .infinity, height: 16)
            bar(width: 220, height: 13)
        }
        .padding(.vertical, Design.Spacing.small)
        .opacity(shimmer ? 0.45 : 0.8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        // Für VoiceOver ist ein Platzhalter kein Inhalt.
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(.quaternary)
            .frame(maxWidth: width)
            .frame(height: height)
    }
}

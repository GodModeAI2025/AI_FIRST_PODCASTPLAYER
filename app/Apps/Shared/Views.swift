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
                         + "wonach du suchst. Themen legst du unter „Interessen“ an.")
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
                }
            }
        }
        .navigationTitle("Für dich")
        .refreshable { await model.refreshAll() }
    }
}

struct RelevantItemRow: View {

    let item: RelevantItem
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.sourceTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(item.episodeTitle)
                .font(.headline)

            // Der Timecode steht sichtbar dabei. Er ist kein technisches
            // Detail, sondern das Versprechen: das hier kannst du nachhören.
            Text("\(item.range.start.timecode)–\(item.range.end.timecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(item.excerpt)
                .font(.callout)
                .lineLimit(3)

            if let relevance = item.relevance {
                // „Warum sehe ich das?“ ist jederzeit beantwortet — nicht
                // hinter einem Info-Symbol versteckt.
                Label(relevance.explanation, systemImage: "target")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 4) {
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

/// Eine persönliche Ausgabe — sieht aus wie eine Podcastfolge, besteht aber
/// aus Originalstellen.
struct PersonalEpisodeView: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.title).font(.title2.bold())
                    if let subtitle = episode.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Label(
                        "\(episode.segments.count) Stellen · \(episode.distinctSourceCount) Quellen "
                        + "· \(episode.totalMediaDuration.shortDescription)",
                        systemImage: "waveform"
                    )
                    .font(.caption)

                    Button {
                        play()
                    } label: {
                        Label("Abspielen", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 8)
            }

            Section("Kapitel") {
                ForEach(Array(episode.shownotes.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.virtualStart.timecode)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(entry.title).font(.body)
                        }
                        // Jedes Kapitel zeigt seine Originalquelle. Ohne das
                        // wäre die Ausgabe ein Zusammenschnitt ohne Herkunft.
                        Text("\(entry.sourceTitle) · \(entry.episodeTitle) · "
                             + "Original \(entry.originalRange.start.timecode)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 52)
                    }
                    .padding(.vertical, 2)
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

    var body: some View {
        List {
            ForEach(model.sources) { source in
                NavigationLink(value: source.id) {
                    SourceRow(source: source)
                }
            }
        }
        .navigationTitle("Mediathek")
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

struct SourceRow: View {

    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source.title).font(.headline)
            if let author = source.author {
                Text(author).font(.caption).foregroundStyle(.secondary)
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
                            Button("Übernehmen") { }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Vorschläge von PodcastAI")
                } footer: {
                    Text("Vermutet, nicht bestätigt. Sie wirken erst, wenn du sie übernimmst.")
                }
            }

            Section("Hinzufügen") {
                Picker("Art", selection: $newKind) {
                    Text("Thema").tag(InterestKind.topic)
                    Text("Aktuelles Vorhaben").tag(InterestKind.activeProject)
                    Text("Offene Frage").tag(InterestKind.openQuestion)
                }
                TextField(placeholder, text: $newLabel)
                Button("Hinzufügen") {
                    let label = newLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    Task { await model.addInterest(label, kind: newKind); newLabel = "" }
                }
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Interessen")
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
        VStack(alignment: .leading, spacing: 2) {
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. Mein KI Update", text: $title)
                }
                Section("Themen") {
                    ForEach(model.profile.topics) { interest in
                        Button {
                            if selected.contains(interest.id) { selected.remove(interest.id) }
                            else { selected.insert(interest.id) }
                        } label: {
                            HStack {
                                Text(interest.label).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(interest.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { dismiss() }
                        .disabled(title.isEmpty || selected.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Player

struct FocusPlayerView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if let plan = model.player.activePlan,
               case .playing(let index) = model.player.state,
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

                HStack(spacing: 28) {
                    Button { model.player.pause() } label: {
                        Image(systemName: "pause.fill").font(.title)
                    }
                    Button { model.player.skipSegment() } label: {
                        Image(systemName: "forward.end.fill").font(.title)
                    }
                    Button { model.player.stop() } label: {
                        Image(systemName: "stop.fill").font(.title)
                    }
                }
                .buttonStyle(.plain)
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
    }
}

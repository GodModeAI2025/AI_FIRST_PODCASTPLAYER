//
//  TopicUpdateViews.swift
//  PodcastAI
//
//  Themen-Updates seit 0.11: generierte Podcasts aus Tags.
//
//  Ein Update sieht aus wie ein Podcast: Cover, Titel, Tags. Seine
//  Ausgaben stehen darunter wie Folgen, mit Datum, Länge und „Teil 2 von
//  3“. Eine Ausgabe öffnet sich wie eine Folge: Kapitel 0 ist die
//  Übersicht ohne Ton, danach die Kapitel mit „Original öffnen“. Der Kopf
//  des Tabs zählt neue Aussagen je Tag seit dem letzten Hören. Darüber
//  steht seit 0.12 eine Zeile mit den Tags, die gerade angesagt sind, dazu
//  der Schalter für das Update „Angesagt“, das die App aus ihnen führt.
//
//  Angelegt wird ein Update aus Tags, nicht aus Freitext: gefolgte Tags als
//  Kapseln, weitere bekannte Tags über eine Suche, dazu „eines davon“ oder
//  „alle zusammen“ und die Länge eines Teils.
//
//  Nichts hier startet Ton von selbst. Abgespielt wird nur über „Abspielen“
//  auf der Seite einer Ausgabe (`EditionHeader`) oder „Original öffnen“.
//

import SwiftUI
import PodcastAIKit

// MARK: - Tab

struct SmartFeedListView: View {

    /// Ein Tag, dessen Seite die Wurzel öffnen will, etwa nach einem Tipp
    /// aufs Widget. Die Liste übernimmt es und setzt es zurück, sonst ginge
    /// die Seite bei jeder Rückkehr in den Tab wieder auf.
    @Binding var linkedTag: InterestID?

    @Environment(AppModel.self) private var model
    @State private var showingNewFeed = false
    @State private var editingFeed: SmartPodcastFeed?
    @State private var pendingDeletion: SmartPodcastFeed?
    @State private var openedTag: InterestID?

    init(linkedTag: Binding<InterestID?> = .constant(nil)) {
        _linkedTag = linkedTag
    }

    /// Die Zeile „Angesagt“ und der Schalter erscheinen, sobald etwas
    /// angesagt ist oder das Update schon besteht.
    private var showsTrending: Bool { !model.trendingTags.isEmpty || model.trendingFeed != nil }

    var body: some View {
        List {
            if showsTrending {
                Section {
                    if !model.trendingTags.isEmpty {
                        TrendingTagsLine(entries: model.trendingTags) { openedTag = $0 }
                    }
                    TrendingFeedToggle()
                    if let feed = model.trendingFeed {
                        NavigationLink(value: feed.id) {
                            SmartFeedRow(feed: feed, editions: model.editions[feed.id] ?? [])
                        }
                        .accessibilityIdentifier("topicUpdates.trendingFeed.row")
                    }
                } footer: {
                    Text("""
                        Ein Themen-Update aus den Tags, die gerade angesagt sind. Seine Tags wechseln mit den \
                        Trends, Tags mit Minus bleiben draußen. Ausgaben entstehen wie bei deinen Updates und \
                        spielen nur, wenn du sie antippst.
                        """)
                }
            }
            if !model.topicUpdatesHeader.isEmpty {
                Section {
                    TopicStatisticsHeader(counts: model.topicUpdatesHeader) { openedTag = $0 }
                } header: {
                    Text("Neu seit dem letzten Hören")
                } footer: {
                    Text("Neue Aussagen je Tag aus Folgen, die nach der zuletzt gehörten Ausgabe erschienen sind.")
                }
            }
            if model.userSmartFeeds.isEmpty {
                ContentUnavailableView {
                    Label("Noch kein Themen-Update", systemImage: "waveform.circle")
                } description: {
                    Text("""
                        Aus den Tags, denen du folgst, baut PodcastAI einen eigenen Podcast. \
                        Er besteht aus Kapiteln, die du noch nicht gehört hast.
                        """)
                } actions: {
                    Button("Themen-Update anlegen") { showingNewFeed = true }
                }
            } else {
                Section {
                    ForEach(model.userSmartFeeds) { feed in
                        NavigationLink(value: feed.id) {
                            SmartFeedRow(feed: feed, editions: model.editions[feed.id] ?? [])
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDeletion = feed } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                            Button { editingFeed = feed } label: {
                                Label("Bearbeiten", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button { editingFeed = feed } label: {
                                Label("Bearbeiten", systemImage: "pencil")
                            }
                            Button(role: .destructive) { pendingDeletion = feed } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    if showsTrending || !model.topicUpdatesHeader.isEmpty { Text("Deine Updates") }
                }
            }
        }
        .yieldsAIWhileScrolling()
        .navigationTitle("Themen-Updates")
        .activityStatusToolbar()
        // Rechnet „Angesagt“ und gleicht das gleichnamige Update ab. Spielt nichts.
        .task(id: model.trendingFeedTrigger) { await model.refreshTrendingFeed() }
        .navigationDestination(for: SmartFeedID.self) { feedID in
            SmartFeedDetailView(feedID: feedID)
        }
        .navigationDestination(item: $openedTag) { id in TagDetailView(tagID: id) }
        // Öffnet nur die Seite, abgespielt wird dort nichts.
        .task(id: linkedTag) {
            guard let linkedTag else { return }
            openedTag = linkedTag
            self.linkedTag = nil
        }
        .toolbar {
            Button { showingNewFeed = true } label: {
                Label("Neu", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingNewFeed) { NewSmartFeedSheet().sheetFeedback() }
        .sheet(item: $editingFeed) { feed in NewSmartFeedSheet(editing: feed).sheetFeedback() }
        .smartFeedDeletionDialog(for: $pendingDeletion)
    }
}

/// Der Kopf des Tabs: je Tag die neuen Aussagen, kompakt als Kapseln. Ein
/// Tipp öffnet die Seite des Tags.
struct TopicStatisticsHeader: View {

    let counts: [TagStatementCount]
    let open: (InterestID) -> Void

    /// Mehr Kapseln liest niemand im Kopf einer Liste.
    static let maximumTags = 8

    var body: some View {
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.none) {
            ForEach(counts.prefix(Self.maximumTags)) { entry in
                Button { open(entry.tagID) } label: {
                    HStack(spacing: Design.Spacing.micro) {
                        Text(entry.label)
                        Text(entry.count, format: .number)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, Design.Spacing.control)
                    .frame(minHeight: Design.minimumTapTarget)
                    .background {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .padding(.vertical, (Design.minimumTapTarget - 28) / 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(TopicStatisticsHeader.spoken(entry)))
                .accessibilityHint("Öffnet die Seite des Tags")
                .accessibilityIdentifier("topicUpdates.stat.\(entry.label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("topicUpdates.header")
    }

    static func spoken(_ entry: TagStatementCount) -> String {
        "\(entry.label): \(NewStatements.text(entry.count))"
    }
}

/// „Angesagt: iOS 27, Datenschutz“. Jeder Name öffnet die Seite des Tags,
/// abgespielt wird nichts.
struct TrendingTagsLine: View {

    let entries: [TrendingTag]
    let open: (InterestID) -> Void

    /// Eine Zeile, keine Liste: mehr Namen passen nicht in den Kopf.
    static let maximumTags = 5

    var body: some View {
        let shown = Array(entries.prefix(Self.maximumTags))
        FlowLayout(spacing: Design.Spacing.micro, lineSpacing: Design.Spacing.none) {
            Label("Angesagt:", systemImage: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.secondary)
                .frame(minHeight: Design.minimumTapTarget)
                .accessibilityHidden(true)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                Button { open(entry.tag.id) } label: {
                    // Das Komma gehört zum Namen davor, damit es beim
                    // Umbruch nicht allein am Zeilenanfang steht.
                    Text(verbatim: index < shown.count - 1 ? entry.tag.label + "," : entry.tag.label)
                        .frame(minHeight: Design.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: entry.tag.label))
                .accessibilityHint("Öffnet die Seite des Tags")
                .accessibilityIdentifier("topicUpdates.trending.\(entry.tag.testKey)")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Angesagt")
        .accessibilityIdentifier("topicUpdates.trending")
    }
}

/// „Angesagt automatisch zusammenstellen“. Der Schalter zeigt, ob es das
/// Update gibt; das gilt auf allen Geräten. Er spielt nichts ab. Nach dem
/// Ausschalten bleibt er gesperrt, bis eine noch laufende Ausgabe des alten
/// Updates fertig und verworfen ist.
struct TrendingFeedToggle: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.trendingFeed != nil },
            set: { model.setTrendingFeedEnabled($0) }
        )) {
            Text("Angesagt automatisch zusammenstellen")
        }
        .disabled(!model.isLoaded || model.trendingFeedBlockedByOldBuild)
        .accessibilityIdentifier("topicUpdates.trendingFeed.toggle")
    }
}

/// „1 neue Aussage“, „3 neue Aussagen“. Zwei feste Sätze statt `inflect`,
/// damit die Mehrzahl im Deutschen sicher stimmt.
enum NewStatements {
    static func text(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 neue Aussage")
            : String(localized: "\(count) neue Aussagen")
    }
}

extension View {
    /// Fragt nach, bevor ein Themen-Update verschwindet. Gelöscht werden
    /// nur seine Ausgaben, nicht die Folgen, aus denen sie bestehen.
    func smartFeedDeletionDialog(
        for feed: Binding<SmartPodcastFeed?>, onDelete: @escaping () -> Void = {}
    ) -> some View {
        modifier(SmartFeedDeletionDialog(feed: feed, onDelete: onDelete))
    }
}

private struct SmartFeedDeletionDialog: ViewModifier {

    @Binding var feed: SmartPodcastFeed?
    let onDelete: () -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            feed?.followsTrends == true ? Text("„Angesagt“ ausschalten?") : Text("Themen-Update löschen?"),
            isPresented: Binding(get: { feed != nil }, set: { if !$0 { feed = nil } }),
            titleVisibility: .visible, presenting: feed
        ) { feed in
            // „Angesagt“ geht über den Schalter, damit dieses Gerät es nicht
            // von selbst wieder anlegt.
            if feed.followsTrends {
                Button("Ausschalten", role: .destructive) {
                    model.setTrendingFeedEnabled(false)
                    onDelete()
                }
            } else {
                Button("„\(feed.title)“ löschen", role: .destructive) {
                    model.removeSmartFeed(feed.id)
                    onDelete()
                }
            }
        } message: { feed in
            if feed.followsTrends {
                Text("""
                    Alle Ausgaben von „Angesagt“ werden gelöscht. Folgen, Transkripte und Hörstand bleiben. \
                    Einschalten lässt es sich wieder im Tab „Themen-Updates“.
                    """)
            } else {
                Text("Alle Ausgaben dieses Updates werden gelöscht. Folgen, Transkripte und Hörstand bleiben.")
            }
        }
    }
}

/// Ein Update in der Liste, wie ein Podcast: Cover, Titel, Tags, Zustand.
struct SmartFeedRow: View {

    let feed: SmartPodcastFeed
    let editions: [PersonalEpisode]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            // Ein Themenfeed sieht aus wie ein Podcast, auch bevor die
            // erste Ausgabe da ist.
            FeedCoverView(feed: feed, size: 56)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(feed.title).font(.headline)
                if let tags = model.tagSummary(for: feed) {
                    Text(tags)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // Der Zustand, nicht nur der Name: ob gerade etwas entsteht,
                // seit wann die letzte Ausgabe bereit ist und ob sie gehört ist.
                if model.buildingFeeds.contains(feed.id) {
                    Label("Wird zusammengestellt …", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(status)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(next)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var status: String {
        let run = PersonalEpisode.latestRun(in: editions)
        guard let latest = run.first else {
            return model.editionNotes[feed.id] ?? String(localized: "Noch keine Ausgabe")
        }
        let since = SmartFeedDetailView.readySince(latest.publishedAt)
        var parts = [String(localized: "Bereit seit \(since)")]
        if run.count > 1 {
            parts.append(String(localized: "\(run.count) Teile"))
        }
        let total = MediaDuration(milliseconds: run.reduce(0) { $0 + $1.totalMediaDuration.milliseconds })
        parts.append(total.shortDescription)
        if PersonalEpisode.heardFraction(of: run, in: model.ledger) >= AppModel.editionHeardThreshold {
            parts.append(String(localized: "gehört"))
        }
        return parts.joined(separator: " · ")
    }

    /// Wann die nächste Ausgabe kommen kann, kurz.
    private var next: String {
        let policy = feed.publicationPolicy
        if model.isWaitingForTrends(feed) { return String(localized: "Wartet auf angesagte Tags") }
        guard policy.isAutomatic else { return String(localized: "Neue Ausgabe nur auf Knopfdruck") }
        if let earliest = model.earliestAutomaticEdition(for: feed) {
            return String(localized: "Nächste frühestens \(AppModel.editionMoment(earliest))")
        }
        if let waiting = model.editionChecks[feed.id]?.waiting {
            return String(localized: """
                Wartet auf Material: \(waiting.shortDescription) von \(policy.minimumMaterial.shortDescription)
                """)
        }
        return String(localized: "Nächste ab \(policy.minimumMaterial.shortDescription) neuem Material")
    }
}

// MARK: - Seite eines Updates

/// Ein Themen-Update wie die Seite eines Podcasts: oben Cover, Titel und
/// Tags, darunter die Ausgaben wie Folgen. Der jüngste Lauf steht als
/// „Neueste Ausgabe“ oben, mit allen seinen Teilen.
struct SmartFeedDetailView: View {

    let feedID: SmartFeedID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingFeed: SmartPodcastFeed?
    @State private var pendingDeletion: SmartPodcastFeed?
    /// Läuft ein Zusammenstellen, um das hier jemand gebeten hat?
    @State private var requesting = false
    /// Wann das letzte Zusammenstellen von hier aus fertig war.
    @State private var resultAt: Date?
    @State private var openedTag: InterestID?
    /// Der Systemdialog von Image Playground, wenn die App selbst kein Bild erzeugen kann.
    @State private var showingPlayground = false

    private var feed: SmartPodcastFeed? { model.smartFeeds.first { $0.id == feedID } }
    private var editions: [PersonalEpisode] {
        (model.editions[feedID] ?? []).sorted { $0.publishedAt > $1.publishedAt }
    }
    private var latestRun: [PersonalEpisode] { PersonalEpisode.latestRun(in: editions) }
    private var earlier: [PersonalEpisode] {
        let latest = Set(latestRun.map(\.id))
        return editions.filter { !latest.contains($0.id) }
    }
    private var isBuilding: Bool { requesting || model.buildingFeeds.contains(feedID) }

    /// Tags des Updates, zu denen keine Stelle passt.
    private var topicsWithoutHits: [Interest] {
        let ids = model.editionChecks[feedID]?.topicsWithoutHits ?? []
        return model.profile.interests.filter { ids.contains($0.id) }
    }

    var body: some View {
        List {
            if let feed {
                Section {
                    SmartFeedHeader(feed: feed, statistics: model.smartFeedStatistics[feedID]) { openedTag = $0 }
                }
            }

            if !latestRun.isEmpty {
                Section {
                    ForEach(latestRun) { edition in editionLink(edition) }
                } header: {
                    Text("Neueste Ausgabe")
                } footer: {
                    if let first = latestRun.first {
                        Text("Erstellt \(AppModel.editionMoment(first.publishedAt))")
                    }
                }
            } else if isBuilding {
                // Nicht „Noch keine Ausgabe“, solange eine entsteht: das
                // sähe fertig und leer aus.
                Section {
                    HStack(spacing: Design.Spacing.control) {
                        ProgressView()
                        Text("Die Ausgabe wird zusammengestellt …")
                    }
                    .padding(.vertical, Design.Spacing.small)
                }
            } else {
                ContentUnavailableView {
                    Label("Noch keine Ausgabe", systemImage: "waveform.circle")
                } description: {
                    if let feed {
                        Text(model.editionHint(for: feed))
                    }
                }
            }

            if !isBuilding, !topicsWithoutHits.isEmpty {
                topicsWithoutHitsSection
            }

            Section {
                if let feed, !editions.isEmpty {
                    Text(model.editionHint(for: feed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(action: requestEdition) {
                    HStack {
                        Label(isBuilding ? "Wird zusammengestellt …" : "Neue Ausgabe zusammenstellen",
                              systemImage: "arrow.triangle.2.circlepath")
                        if isBuilding {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isBuilding || feed.map { model.isWaitingForTrends($0) } ?? true)
                // Die Rückmeldung als Satz: was entstanden ist oder warum
                // nicht. Nach einem Tipp mit der Uhrzeit, damit sichtbar ist,
                // dass gerade geprüft wurde, auch wenn dasselbe herauskam.
                if !isBuilding, let note = model.editionNotes[feedID] {
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                        if let resultAt {
                            Text("Geprüft \(AppModel.editionMoment(resultAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("edition.result")
                }
            } header: {
                Text("Nächste Ausgabe")
            } footer: {
                if let feed {
                    Text(AppModel.editionRule(for: feed.publicationPolicy))
                }
            }

            if !earlier.isEmpty {
                Section("Frühere Ausgaben") {
                    ForEach(earlier) { edition in editionLink(edition) }
                }
            }
        }
        .yieldsAIWhileScrolling()
        .navigationTitle(feed?.title ?? String(localized: "Themen-Update"))
        .navigationDestination(item: $openedTag) { id in TagDetailView(tagID: id) }
        .toolbar {
            if let feed {
                Menu {
                    // „Angesagt“ bekommt seine Tags aus den Trends. Was man
                    // hier änderte, schriebe der nächste Abgleich um.
                    if !feed.followsTrends {
                        Button { editingFeed = feed } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                    }
                    if model.coverArt.canCreate {
                        Button { createCover(for: feed) } label: {
                            Label("Neues Cover erzeugen", systemImage: "wand.and.sparkles")
                        }
                        .disabled(model.coverArt.isGenerating(feed.id))
                    }
                    if let latest = latestRun.first {
                        ShareLink(item: ShownotesBuilder().markdown(for: latest)) {
                            Label("Neueste Ausgabe als Text teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) { pendingDeletion = feed } label: {
                        if feed.followsTrends {
                            Label("Ausschalten", systemImage: "trash")
                        } else {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingFeed) { feed in NewSmartFeedSheet(editing: feed).sheetFeedback() }
        .coverPlaygroundSheet(isPresented: $showingPlayground, recipe: feed.map(model.coverRecipe(for:))) { url in
            guard let feed else { return }
            let recipe = model.coverRecipe(for: feed)
            Task {
                if await model.coverArt.adopt(fileAt: url, for: recipe) {
                    AccessibilityNotification.Announcement(String(localized: "Neues Cover ist fertig")).post()
                } else {
                    model.lastError = String(localized: "Das Cover konnte nicht übernommen werden. Das bisherige bleibt.")
                }
            }
        }
        .smartFeedDeletionDialog(for: $pendingDeletion) { dismiss() }
    }

    /// Eine Ausgabe wie eine Folge: öffnet ihre Seite, spielt nichts.
    private func editionLink(_ edition: PersonalEpisode) -> some View {
        NavigationLink {
            PersonalEpisodeView(episode: edition)
        } label: {
            EditionRow(episode: edition)
        }
        .accessibilityIdentifier("edition.row")
        .swipeActions {
            Button(role: .destructive) { model.removeEdition(edition) } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) { model.removeEdition(edition) } label: {
                Label("Ausgabe löschen", systemImage: "trash")
            }
        }
    }

    /// Ein Tag ohne Treffer sagt das und führt zu seiner Seite.
    private var topicsWithoutHitsSection: some View {
        Section {
            ForEach(topicsWithoutHits) { interest in
                NavigationLink {
                    TagDetailView(tagID: interest.id)
                } label: {
                    Text("Zu \(interest.label) noch keine passende Stelle")
                }
            }
        } header: {
            Text("Tags ohne Treffer")
        } footer: {
            Text("""
                Ein Tag findet Kapitel, die die App mit ihm eingeordnet hat. Folgen ohne Tags \
                durchsucht sie nach seinem Namen und seinen Schreibweisen, und nur Folgen mit Transkript.
                """)
        }
    }

    /// Stellt von Hand eine Ausgabe zusammen. Der Fortschritt bleibt kurz
    /// sichtbar, auch wenn die Prüfung sofort fertig ist: sonst sähe der
    /// Tipp aus, als hätte er nichts getan. Spielt nichts ab.
    private func requestEdition() {
        guard !isBuilding else { return }
        requesting = true
        Task {
            let started = Date()
            let note = await model.buildEdition(feedID: feedID)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.8 { try? await Task.sleep(for: .seconds(0.8 - elapsed)) }
            requesting = false
            resultAt = Date()
            AccessibilityNotification.Announcement(note).post()
        }
    }

    /// Ein neues Cover für das Update auf Wunsch. Kann die App kein Bild
    /// selbst erzeugen, übernimmt der Systemdialog von Image Playground.
    private func createCover(for feed: SmartPodcastFeed) {
        let recipe = model.coverRecipe(for: feed)
        Task {
            switch await model.coverArt.regenerate(recipe) {
            case .created:
                AccessibilityNotification.Announcement(String(localized: "Neues Cover ist fertig")).post()
            case .needsDialog:
                showingPlayground = true
            case .unavailable:
                model.lastError = String(localized: """
                    Image Playground ist auf diesem Gerät gerade nicht verfügbar. \
                    Das Update behält sein bisheriges Cover.
                    """)
            case .failed:
                model.lastError = String(localized: "Das Cover konnte nicht erzeugt werden. Das bisherige bleibt.")
            case .postponed:
                // Unterbrochen, etwa weil die App kurz im Hintergrund war.
                // Von selbst kommt kein neuer Versuch: das alte Cover passt
                // ja noch zu den Tags.
                model.lastError = String(localized: """
                    Das Cover wurde unterbrochen, etwa weil PodcastAI im Hintergrund war. \
                    Das bisherige bleibt. Wähle noch einmal „Neues Cover erzeugen“.
                    """)
            }
        }
    }

    /// „6:40“ für heute, sonst das Datum.
    static func readySince(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month())
    }
}

/// Kopf eines Updates: Cover, Titel, Tags mit ihren neuen Aussagen und die
/// Verknüpfung. Ein Tag öffnet seine Seite.
struct SmartFeedHeader: View {

    let feed: SmartPodcastFeed
    let statistics: SmartFeedStatistics?
    let open: (InterestID) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            HStack(alignment: .top, spacing: Design.Spacing.standard) {
                FeedCoverView(feed: feed, size: 112)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Text(feed.title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(modeLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("smartFeed.mode")
                    if let total = statistics?.total, total > 0 {
                        Text(NewStatements.text(total))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if model.coverArt.isGenerating(feed.id) {
                        Label {
                            Text("Cover wird mit Image Playground erzeugt …")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if !counts.isEmpty {
                TopicStatisticsHeader(counts: counts, open: open)
            }
        }
        .padding(.vertical, Design.Spacing.small)
    }

    /// Die Tags des Updates mit ihren Zahlen, auch mit null: Hier geht es
    /// um dieses Update, nicht um das, was gerade neu ist.
    private var counts: [TagStatementCount] {
        // „Angesagt“ nur mit den Tags, aus denen die nächste Ausgabe
        // entsteht, ohne die mit Minus.
        if feed.followsTrends {
            let current = Set(model.trendingFeedForEdition(feed).topicIDs)
            return allCounts.filter { current.contains($0.tagID) }
        }
        return allCounts
    }

    private var allCounts: [TagStatementCount] {
        if let statistics, !statistics.tags.isEmpty {
            return statistics.tags.map { entry in
                entry.label.isEmpty
                    ? TagStatementCount(tagID: entry.tagID,
                                        label: model.labels(forTags: [entry.tagID]).first ?? "",
                                        count: entry.count)
                    : entry
            }.filter { !$0.label.isEmpty }
        }
        return feed.topicIDs.compactMap { id in
            model.labels(forTags: [id]).first.map { TagStatementCount(tagID: id, label: $0, count: 0) }
        }
    }

    /// „Kapitel mit einem der Tags, je Teil 20 Minuten“.
    private var modeLine: String {
        let length = feed.editionMode.budget?.shortDescription ?? feed.editionMode.label
        if feed.followsTrends {
            guard !model.isWaitingForTrends(feed) else { return AppModel.nothingTrendingNote }
            return String(localized: "Kapitel mit einem der angesagten Tags, je Teil \(length). Die Tags wechseln mit den Trends.")
        }
        if feed.topicIDs.isEmpty {
            return String(localized: "Alle Tags, denen du folgst, je Teil \(length)")
        }
        switch feed.effectiveMatchMode {
        case .any: return String(localized: "Kapitel mit einem der Tags, je Teil \(length)")
        case .all: return String(localized: "Nur Kapitel mit allen Tags, je Teil \(length)")
        }
    }
}

/// Eine Ausgabe in der Liste, wie eine Folge: Cover, Titel, Datum, Länge
/// und Teil.
struct EditionRow: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            if let feed = model.smartFeeds.first(where: { $0.id == episode.feedID }) {
                FeedCoverView(feed: feed, edition: episode, size: 48)
            }
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [episode.publishedAt.formatted(date: .abbreviated, time: .omitted),
                     episode.totalMediaDuration.shortDescription]
        if let part = model.partLabel(for: episode) { parts.append(part) }
        if episode.newStatementCount > 0 { parts.append(NewStatements.text(episode.newStatementCount)) }
        if episode.heardFraction(in: model.ledger) >= AppModel.editionHeardThreshold {
            parts.append(String(localized: "gehört"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Seite einer Ausgabe

/// Kopf einer Ausgabe: Cover, Titel, Teil, Umfang und „Abspielen“.
struct EditionHeader: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            if let feed = model.smartFeeds.first(where: { $0.id == episode.feedID }) {
                FeedCoverView(feed: feed, edition: episode, size: 148, createsEditionCover: true)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                if model.coverArt.isGenerating(TopicCoverKey(feedID: feed.id, editionID: episode.id)) {
                    Label {
                        Text("Cover wird mit Image Playground erzeugt …")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(feed.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(episode.title)
                .font(.title2.weight(.bold))
            if let part = model.partLabel(for: episode) {
                Text(part)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("edition.part")
            }
            if let subtitle = episode.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("""
                    ^[\(episode.segments.count) Stelle](inflect: true) · \
                    ^[\(episode.distinctSourceCount) Quelle](inflect: true) · \
                    \(episode.totalMediaDuration.shortDescription)
                    """)
            } icon: {
                Image(systemName: "waveform")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            // Die primäre Aktion: gefüllt, getintet, in voller Breite.
            // Sie ist die einzige gefüllte Schaltfläche auf diesem
            // Bildschirm, sonst wäre keine mehr primär. Nur sie startet Ton.
            Button(action: play) {
                Label("Abspielen", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
            }
            .buttonStyle(.prominentAction)
            .accessibilityHint(playHint)
        }
        .padding(.vertical, Design.Spacing.small)
    }

    /// Zwei feste Sätze statt `inflect`: „Originalstelle“ kennt die
    /// automatische Beugung im Deutschen nicht, sie bliebe in der Einzahl.
    private var playHint: String {
        let count = episode.segments.count
        return count == 1
            ? String(localized: "Spielt 1 Originalstelle ab")
            : String(localized: "Spielt \(count) Originalstellen nacheinander ab")
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

/// Eine persönliche Ausgabe. Sie sieht aus wie eine Podcastfolge, besteht
/// aber aus Originalkapiteln. Kapitel 0 ist die Übersicht ohne Ton.
struct PersonalEpisodeView: View {

    let episode: PersonalEpisode

    var body: some View {
        List {
            Section {
                EditionHeader(episode: episode)
            }

            Section("Kapitel") {
                if !episode.overviewEntries.isEmpty {
                    EditionOverviewCard(episode: episode)
                }
                ForEach(Array(episode.shownotes.enumerated()), id: \.offset) { index, entry in
                    EditionChapterRow(episode: episode, entry: entry, index: index)
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
                    Text("Einzelne Abschnitte beginnen mit ein paar Sekunden Kontext, die du eventuell schon gehört hast.")
                }
            }
        }
        .navigationTitle(episode.title)
        .toolbar {
            // Übersicht und Kapitel mit Quelle und Originalzeit als Text,
            // etwa für Notizen.
            ShareLink(item: ShownotesBuilder().markdown(for: episode)) {
                Label("Als Text teilen", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Kapitel 0: die Übersicht. Je Abschnitt Quelle mit Cover, Folge, Datum
/// und die Zahl neuer Aussagen. Kein Ton, kein Knopf: sie sagt nur, was
/// kommt.
struct EditionOverviewCard: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.control) {
                Text(verbatim: "0")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                    Text("Übersicht")
                        .font(.body.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(episode.overviewEntries) { entry in
                HStack(alignment: .top, spacing: Design.Spacing.control) {
                    EpisodeArtwork(url: model.sources.first { $0.id == entry.sourceID }?.artworkURL, size: 44)
                    VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                        Text(entry.sourceTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(entry.episodeTitle)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(details(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Design.Spacing.control)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(
            cornerRadius: Design.Radius.card, style: .continuous))
        .listRowInsets(EdgeInsets(top: Design.Spacing.small, leading: Design.Spacing.small,
                                  bottom: Design.Spacing.small, trailing: Design.Spacing.small))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edition.overview")
    }

    /// „4 Kapitel · 12 neue Aussagen“.
    private var summary: String {
        let chapters = String(AttributedString(
            localized: "^[\(episode.overviewEntries.count) Kapitel](inflect: true)").characters)
        return "\(chapters) · \(NewStatements.text(episode.newStatementCount))"
    }

    /// Kapitel, Erscheinungsdatum und neue Aussagen eines Abschnitts.
    private func details(for entry: EditionOverviewEntry) -> String {
        var parts: [String] = []
        if let chapter = entry.chapterTitle, !chapter.isEmpty { parts.append(chapter) }
        if let published = entry.originalPublishedAt {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(NewStatements.text(entry.newStatementCount))
        if !entry.isWholeChapter { parts.append(String(localized: "Auszug")) }
        return parts.joined(separator: " · ")
    }
}

/// Ein Kapitel der Ausgabe mit Zeit, Titel, Herkunft und „Original öffnen“.
struct EditionChapterRow: View {

    let episode: PersonalEpisode
    let entry: ShownotesEntry
    let index: Int

    private var segment: PersonalEpisodeSegment? {
        index < episode.segments.count ? episode.segments[index] : nil
    }

    private var title: String {
        if let chapter = segment?.chapterTitle, !chapter.isEmpty { return chapter }
        return entry.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.control) {
                    TimecodeLabel(entry.virtualStart, emphasis: .medium)
                        // Feste Breite, damit die Titel eine Kante
                        // bilden statt zu flattern.
                        .frame(width: 52, alignment: .leading)
                    Text(title)
                        .font(.body)
                }
                // Jedes Kapitel zeigt seine Originalquelle. Ohne das
                // wäre die Ausgabe ein Zusammenschnitt ohne Herkunft.
                Text(origin)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 52 + Design.Spacing.control)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(TimecodeLabel.spokenSingle(entry.virtualStart.timecode)), \(title), aus \(entry.sourceTitle)"
            )
            // Zurück in die Folge, aus der das Kapitel stammt, an
            // dieselbe Stelle. Die Zeit rechnet die Ausgabe aus.
            if let original = episode.originalEpisodePosition(forVirtual: entry.virtualStart) {
                OpenOriginalButton(episodeID: original.episodeID, position: original.position)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .padding(.leading, 52 + Design.Spacing.control)
            }
        }
        .padding(.vertical, Design.Spacing.micro)
    }

    /// Quelle, Folge, Erscheinungsdatum der Originalfolge und Originalzeit.
    private var origin: String {
        var parts = [entry.sourceTitle, entry.episodeTitle]
        if let published = segment?.originalPublishedAt {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(String(localized: "Original \(entry.originalRange.start.timecode)"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Anlegen und Bearbeiten

/// Legt ein Themen-Update an oder ändert eines. Tags werden ausgewählt,
/// nicht eingetippt.
struct NewSmartFeedSheet: View {

    /// Gesetzt, wenn ein bestehendes Update bearbeitet wird.
    var editing: SmartPodcastFeed? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var selected: Set<InterestID> = []
    @State private var matchMode: TagMatchMode = .any
    @State private var minutes = 20
    /// Leer heißt: alle abonnierten Quellen.
    @State private var selectedSources: Set<SourceID> = []
    @State private var prepared = false

    /// Tags, denen jemand folgt, nach Name.
    private var followedTags: [Tag] {
        model.profile.topics.map(\.tag)
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Bekannte Tags, denen niemand folgt. Zur Auswahl über die Suche.
    private var otherTags: [Tag] {
        let followed = Set(followedTags.map(\.id))
        return model.profile.tags.filter { !followed.contains($0.id) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Die Kapseln: gefolgte Tags und ausgewählte weitere.
    private var chipTags: [Tag] {
        followedTags + otherTags.filter { selected.contains($0.id) }
    }

    /// Die ausgewählten Tags in der Reihenfolge der Kapseln.
    private var selectedTags: [Tag] { chipTags.filter { selected.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. Mein KI Update", text: $title)
                }
                Section {
                    if !chipTags.isEmpty {
                        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.none) {
                            ForEach(chipTags) { tag in
                                TagSelectChip(tag: tag, isSelected: selected.contains(tag.id)) {
                                    toggle(tag.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !otherTags.isEmpty {
                        NavigationLink {
                            TagPickerView(tags: otherTags, selected: $selected)
                        } label: {
                            Label("Weitere Tags", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("feed.moreTags")
                    }
                    // Eingetippt wird nichts: Tags kommen aus dem Inhalt.
                    // Ohne gefolgtes Tag führt der Weg dorthin, wo man folgt.
                    if followedTags.isEmpty {
                        NavigationLink { TagsView() } label: {
                            Label("Meine Tags", systemImage: "tag")
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    if chipTags.isEmpty {
                        Text("Folge zuerst einem Tag: in einer Folge unter „Kurz gesagt“ oder in „Meine Tags“ auf Plus tippen.")
                    } else {
                        Text("Antippen wählt ein Tag aus oder ab. Unter „Weitere Tags“ stehen Tags aus deinen Folgen, denen du nicht folgst.")
                    }
                }
                Section {
                    Picker("Kapitel passen, wenn sie", selection: $matchMode) {
                        ForEach(TagMatchMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(selectedTags.count < 2)
                    .accessibilityIdentifier("feed.matchMode")
                    Text(modeExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feed.matchMode.explanation")
                } header: {
                    Text("Verknüpfung")
                }
                Section {
                    Stepper("\(minutes) Minuten je Teil", value: $minutes, in: 5...120, step: 5)
                        .accessibilityIdentifier("feed.length")
                } footer: {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("""
                            Ein Kapitel kommt ganz hinein, wenn es in einen Teil passt. Was nicht mehr passt, \
                            kommt in Teil 2, Teil 3 und so weiter, höchstens fünf Teile auf einmal.
                            """)
                        // Wann Ausgaben entstehen, steht schon hier und nicht
                        // erst, wenn die erste ausbleibt.
                        Text(AppModel.editionRule(for: publicationPolicy))
                    }
                }
                if !model.sources.isEmpty {
                    Section {
                        ForEach(model.sources) { source in
                            Button {
                                if selectedSources.contains(source.id) { selectedSources.remove(source.id) }
                                else { selectedSources.insert(source.id) }
                            } label: {
                                HStack {
                                    Text(source.title).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedSources.contains(source.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityAddTraits(
                                selectedSources.contains(source.id) ? [.isButton, .isSelected] : .isButton
                            )
                        }
                    } header: {
                        Text("Podcasts")
                    } footer: {
                        if selectedSources.isEmpty {
                            Text("Ohne Auswahl sucht das Update in allen abonnierten Podcasts.")
                        } else {
                            Text("Das Update sucht nur in den ausgewählten Podcasts.")
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? "Themen-Update" : "Themen-Update bearbeiten")
            .onAppear(perform: prepare)
            .onChange(of: selectedTags.count) { _, count in
                // Mit einem Tag gibt es kein „alle zusammen“.
                if count < 2 { matchMode = .any }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Anlegen" : "Sichern") {
                        Task { await create() }
                    }
                    // Gesperrt nur, wenn es wirklich nichts anzulegen gibt.
                    .disabled(!canCreate)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    /// Ein Satz, was der Modus mit den gewählten Tags bedeutet, etwa
    /// „Datenschutz und USA: nur Kapitel, die beides behandeln“.
    private var modeExplanation: String {
        let labels = selectedTags.map(\.label)
        guard labels.count >= 2 else {
            return String(localized: "Mit einem Tag zählt jedes Kapitel, das es trägt. Für „alle zusammen“ wähle mindestens zwei.")
        }
        switch matchMode {
        case .any:
            let named = labels.formatted(.list(type: .or))
            return String(localized: "\(named): jedes Kapitel, das eines davon behandelt")
        case .all:
            let named = labels.formatted(.list(type: .and))
            return labels.count == 2
                ? String(localized: "\(named): nur Kapitel, die beides behandeln")
                : String(localized: "\(named): nur Kapitel, die alle \(labels.count) behandeln")
        }
    }

    /// Die Regel des Updates, beim Anlegen die übliche.
    private var publicationPolicy: PublicationPolicy {
        editing?.publicationPolicy ?? SmartPodcastFeed(title: "", topicIDs: []).publicationPolicy
    }

    private var canCreate: Bool { !selectedTags.isEmpty }

    private func toggle(_ id: InterestID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Füllt das Blatt einmal: beim Bearbeiten mit dem Update, sonst mit
    /// allen gefolgten Tags.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let editing {
            title = editing.title
            let known = Set(model.profile.tags.map(\.id))
            selected = Set(editing.topicIDs).intersection(known)
            matchMode = selected.count < 2 ? .any : editing.matchMode
            if let budget = editing.editionMode.budget {
                let value = Int(budget.milliseconds / 60_000)
                minutes = min(120, max(5, (value + 2) / 5 * 5))
            }
            let live = Set(model.sources.map(\.id))
            selectedSources = Set(editing.restrictedToSourceIDs).intersection(live)
            return
        }
        // Alle gefolgten Tags sind vorausgewählt. Wer nichts abwählt,
        // bekommt ein Update über alles, was ihn interessiert.
        if selected.isEmpty { selected = Set(followedTags.map(\.id)) }
    }

    private func create() async {
        let tags = selectedTags
        guard !tags.isEmpty else { return }
        let topicIDs = tags.map(\.id)
        let mode: TagMatchMode = tags.count < 2 ? .any : matchMode
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? Self.defaultName(for: tags.map(\.label), mode: mode)
            : title
        // In der Reihenfolge der Mediathek, damit gleiche Auswahl gleich aussieht.
        let sourceIDs = model.sources.map(\.id).filter(selectedSources.contains)
        if var feed = editing {
            feed.title = name
            feed.topicIDs = topicIDs
            feed.matchMode = mode
            feed.editionMode = .budgeted(MediaDuration(minutes: minutes))
            feed.restrictedToSourceIDs = sourceIDs
            model.updateSmartFeed(feed)
            dismiss()
            return
        }
        // Die erste Ausgabe baut das Modell, sobald der Feed gesichert ist,
        // unabhängig von diesem Blatt. Sie startet keinen Ton.
        model.createSmartFeed(
            title: name, topicIDs: topicIDs, matchMode: mode, minutes: minutes, sourceIDs: sourceIDs,
            buildFirstEdition: true)
        dismiss()
    }

    /// Der Name, wenn keiner eingetippt ist: die ersten beiden Tags.
    private static func defaultName(for labels: [String], mode: TagMatchMode) -> String {
        switch labels.count {
        case 0: String(localized: "Mein Update")
        case 1: labels[0]
        default: mode == .all
            ? String(localized: "\(labels[0]) und \(labels[1])")
            : String(localized: "\(labels[0]) oder \(labels[1])")
        }
    }
}

/// Ein Tag zum Auswählen: Kapsel mit Haken, wenn gewählt. Für VoiceOver und
/// UI-Tests heißt der Knopf wie das Tag und trägt „ausgewählt“.
struct TagSelectChip: View {

    let tag: Tag
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Design.Spacing.micro) {
                if isSelected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
                Text(tag.label)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, Design.Spacing.control)
            .frame(minHeight: Design.minimumTapTarget)
            .background {
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    .padding(.vertical, (Design.minimumTapTarget - 32) / 2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tag.label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Weitere Tags aus den Folgen, mit Suche. Auswählen nimmt ein Tag in das
/// Update auf, ohne ihm zu folgen.
struct TagPickerView: View {

    let tags: [Tag]
    @Binding var selected: Set<InterestID>
    @State private var query = ""
    @Environment(AppModel.self) private var model

    private var shown: [Tag] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let matching = text.isEmpty ? tags : tags.filter {
            $0.label.localizedStandardContains(text) || $0.aliases.contains { $0.localizedStandardContains(text) }
        }
        let counts = model.chapterTagCounts
        return matching.sorted { lhs, rhs in
            let left = counts[lhs.id] ?? 0, right = counts[rhs.id] ?? 0
            if left != right { return left > right }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if shown.isEmpty {
                Text("Kein Tag passt zur Suche.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { tag in
                Button {
                    if selected.contains(tag.id) { selected.remove(tag.id) } else { selected.insert(tag.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            Text(tag.label).foregroundStyle(.primary)
                            let count = model.chapterTagCounts[tag.id] ?? 0
                            Text("^[\(count) Kapitel](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(tag.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityLabel(Text(tag.label))
                .accessibilityAddTraits(selected.contains(tag.id) ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tagPicker.\(tag.testKey)")
            }
        }
        .searchable(text: $query, prompt: Text("Tags durchsuchen"))
        .navigationTitle("Weitere Tags")
    }
}

// MARK: - Modell

extension AppModel {

    /// Die Tags eines Updates als eine Zeile, mit „und“ oder „oder“ je
    /// nach Modus. Ohne eigene Tags: der Hinweis auf alle gefolgten.
    func tagSummary(for feed: SmartPodcastFeed) -> String? {
        // „Angesagt“ zeigt die Tags, mit denen die nächste Ausgabe entsteht.
        if feed.followsTrends {
            let labels = labels(forTags: trendingFeedForEdition(feed).topicIDs)
            return labels.isEmpty
                ? String(localized: "Gerade ist kein Tag angesagt")
                : labels.formatted(.list(type: .or))
        }
        let labels = labels(forTags: feed.topicIDs)
        guard !labels.isEmpty else {
            return feed.topicIDs.isEmpty ? String(localized: "Alle Tags, denen du folgst") : nil
        }
        return labels.formatted(.list(type: feed.effectiveMatchMode == .all ? .and : .or))
    }
}

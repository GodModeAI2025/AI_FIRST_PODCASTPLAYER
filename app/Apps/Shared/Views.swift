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

    @State private var addingSource = false

    var body: some View {
        List {
            let resume = model.continueListening
            if !resume.isEmpty {
                Section("Weiterhören") {
                    ForEach(resume, id: \.episode.id) { entry in
                        ResumeRow(episode: entry.episode, position: entry.position)
                    }
                }
            }

            let fresh = model.freshEpisodes
            if !fresh.isEmpty {
                Section("Neu in deinen Abos") {
                    ForEach(fresh) { episode in
                        NavigationLink { EpisodeDetailView(episode: episode) } label: {
                            FreshEpisodeRow(episode: episode)
                        }
                    }
                }
            }

            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Podcasts", systemImage: "mic")
                } description: {
                    Text("""
                        Such deine Lieblingssendungen nach Namen und abonniere sie. \
                        Danach stehen hier neue Folgen und die Stellen zu deinen Themen.
                        """)
                } actions: {
                    Button("Podcast suchen") { addingSource = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.profile.confirmed.isEmpty {
                ContentUnavailableView {
                    Label("Wonach suchst du?", systemImage: "sparkles")
                } description: {
                    Text("""
                        Leg ein oder zwei Themen an, etwa „Fußball“, „Kochen“ oder „Datenschutz“. \
                        Dann sammelt PodcastAI hier die passenden Stellen aus deinen Folgen.
                        """)
                } actions: {
                    NavigationLink("Themen anlegen") { InterestsView() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.relevantToday.isEmpty {
                Section("Zu deinen Themen") {
                    Text("Gerade keine ungehörten Stellen. Neue kommen dazu, sobald weitere Transkripte fertig sind.")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Woher die Stellen kommen, gleich darüber und mit dem Weg
                // zum Ändern. Sonst stand das nur in der Hilfe.
                Section {
                    NavigationLink { InterestsView() } label: {
                        LabeledContent {
                            Text("Bearbeiten")
                        } label: {
                            Label("Ausgewählt nach deinen Interessen", systemImage: "target")
                        }
                    }
                    .accessibilityIdentifier("forYou.interests")
                }
                ForEach(groupedRelevant) { group in
                    Section {
                        ForEach(group.cards) { card in
                            RelevantItemRow(bundle: card)
                                .listRowInsets(EdgeInsets(top: Design.Spacing.small,
                                                          leading: Design.Spacing.standard,
                                                          bottom: Design.Spacing.small,
                                                          trailing: Design.Spacing.standard))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        group.header
                    }
                }
            }

            // Gemerkte Stellen auch von hier, nicht nur unter „Wissen“.
            if !model.highlights.isEmpty {
                Section {
                    NavigationLink { KnowledgeView() } label: {
                        LabeledContent {
                            Text(model.highlights.count, format: .number)
                        } label: {
                            Label("Gemerkte Stellen", systemImage: "bookmark")
                        }
                    }
                    .accessibilityIdentifier("forYou.highlights")
                }
            }
        }
        .sheet(isPresented: $addingSource) { AddSourceSheet().sheetFeedback() }
        .listStyle(.plain)
        .navigationTitle("Für dich")
        .activityStatusToolbar()
        .refreshable { await model.refreshAll() }
        .toolbar {
            NavigationLink { QueueView() } label: {
                Label("Warteschlange", systemImage: "list.bullet")
            }
            // Nach dem ersten Abo verschwindet der große Suchknopf. Weitere
            // Podcasts kommen dann über das Plus dazu.
            Button { addingSource = true } label: {
                Label("Podcast hinzufügen", systemImage: "plus")
            }
            .accessibilityIdentifier("forYou.add")
            #if os(iOS)
            SettingsToolbarLink()
            #endif
        }
    }
}

#if os(iOS)
/// Das Zahnrad in „Für dich“ und „Meine Podcasts“. Einstellungen, Hilfe und
/// Datenschutz lagen vorher nur ganz unten im Reiter „Wissen“.
struct SettingsToolbarLink: View {
    var body: some View {
        NavigationLink { SettingsView() } label: {
            Label("Einstellungen", systemImage: "gearshape")
        }
        .accessibilityIdentifier("toolbar.settings")
    }
}
#endif

/// Eine Karte in „Für dich“: alle Treffer einer Folge zu einem Interesse.
struct RelevantCard: Identifiable {
    /// Der beste Treffer. Er steht auf der Karte, ein Tipp spielt ab ihm.
    let lead: RelevantItem
    /// Alle Treffer der Folge, in der Reihenfolge, in der sie laufen.
    let hits: [RelevantItem]
    var id: EvidenceID { lead.id }

    /// Was die Treffer erwähnen, ohne Doppelte, der beste Treffer zuerst.
    var mentioned: [String] {
        var result: [String] = []
        for term in ([lead] + hits).flatMap(\.mentioned)
        where !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            result.append(term)
        }
        return result
    }
}

/// Die Treffer zu einem Interesse.
struct RelevantGroup: Identifiable {
    let id: String
    let label: String
    let reason: PersonalRelevance.Reason?
    let cards: [RelevantCard]

    var header: some View {
        let (icon, spoken): (String, Text) = switch reason {
        case .activeProject: ("briefcase", Text("Vorhaben: \(label)"))
        case .openQuestion: ("questionmark.circle", Text("Frage: \(label)"))
        default: ("tag", Text("Thema: \(label)"))
        }
        return Label(label, systemImage: icon)
            .accessibilityLabel(spoken)
    }
}

extension ForYouView {
    /// Treffer nach Interesse, in der Reihenfolge des besten Treffers je
    /// Gruppe. Treffer derselben Folge teilen sich eine Karte, die neueste
    /// Folge steht oben.
    var groupedRelevant: [RelevantGroup] {
        var order: [String] = []
        var groups: [String: [RelevantItem]] = [:]
        for item in model.relevantToday {
            let key = item.relevance?.interestID.rawValue ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { key in
            let items = groups[key] ?? []
            return RelevantGroup(
                id: key,
                label: items.first?.relevance?.interestLabel ?? String(localized: "Weitere Treffer"),
                reason: items.first?.relevance?.reason,
                cards: Self.cards(from: items))
        }
    }

    /// `items` kommen bester Treffer zuerst. Die Karte einer Folge führt
    /// deshalb ihr bester Treffer an.
    static func cards(from items: [RelevantItem]) -> [RelevantCard] {
        var order: [String] = []
        var byEpisode: [String: [RelevantItem]] = [:]
        for item in items {
            let key = item.episodeID?.rawValue ?? item.id.rawValue
            if byEpisode[key] == nil { order.append(key) }
            byEpisode[key, default: []].append(item)
        }
        let cards = order.compactMap { key -> RelevantCard? in
            guard let hits = byEpisode[key], let lead = hits.first else { return nil }
            return RelevantCard(
                lead: lead,
                hits: hits.sorted { $0.range.start.milliseconds < $1.range.start.milliseconds })
        }
        // Neueste Folge zuerst. Ohne Datum ans Ende, bei Gleichstand bleibt
        // die Reihenfolge nach bestem Treffer.
        return cards.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lead.publishedAt, rhs.element.lead.publishedAt) {
            case let (left?, right?) where left != right: left > right
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

/// Eine angefangene Folge. Ein Tipp spielt ab der gemerkten Stelle weiter.
struct ResumeRow: View {
    let episode: Episode
    let position: Double
    @Environment(AppModel.self) private var model

    private var duration: Double { episode.declaredDuration?.seconds ?? 0 }

    var body: some View {
        Button { model.playEpisode(episode, at: position) } label: {
            HStack(spacing: Design.Spacing.control) {
                EpisodeArtwork(url: episode.artworkURL
                               ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                               size: 48)
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Text(episode.title).font(.headline).lineLimit(2)
                    if duration > 0 {
                        ProgressView(value: min(position, duration), total: duration)
                        Text("noch \(max(1, Int((duration - position) / 60))) Min.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("weiter ab \(MediaTime(milliseconds: Int64(position * 1000)).timecode)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Spielt ab der Stelle weiter, an der du aufgehört hast")
    }
}

/// Eine neue Folge aus den Abos.
struct FreshEpisodeRow: View {
    let episode: Episode
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            EpisodeArtwork(url: episode.artworkURL
                           ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 48)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(episode.title).font(.headline).lineLimit(2)
                HStack(spacing: Design.Spacing.micro) {
                    if let source = model.sources.first(where: { $0.id == episode.sourceID }) {
                        Text(source.title).lineLimit(1)
                    }
                    if let published = episode.publishedAt {
                        Text(verbatim: "·")
                        Text(published, format: .relative(presentation: .named))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            if model.canPlay(episode) {
                Button { model.playEpisode(episode) } label: { Label("Abspielen", systemImage: "play.fill") }
                    .tint(.accentColor)
            } else {
                OpenEpisodeWebButton(episode: episode)
                    .tint(.red)
            }
        }
    }
}

struct RelevantItemRow: View {

    let bundle: RelevantCard
    @Environment(AppModel.self) private var model

    private var item: RelevantItem { bundle.lead }
    private var others: [RelevantItem] { bundle.hits.filter { $0.id != item.id } }

    var body: some View {
        // Ein Tipp auf die Karte öffnet die Folge. Abgespielt wird nur über
        // den Knopf mit der Zeitmarke, damit kein Ton unerwartet startet.
        Group {
            if let episode = model.loadedEpisode(item.episodeID) {
                NavigationLink {
                    EpisodeDetailView(episode: episode)
                } label: {
                    content.contentShape(.rect)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityHint("Öffnet die Folge. Abspielen unter Aktionen.")
            } else {
                content
            }
        }
        .buttonStyle(.plain)
        .accessibilityAction(named: "Ab \(TimecodeLabel.spokenSingle(item.range.start.timecode)) abspielen") {
            model.playRelevantItemInEpisode(item)
        }
        .accessibilityAction(named: "Stelle merken") { model.rememberRelevantItem(item) }
        .accessibilityAction(named: "Nicht relevant") { model.dismissRelevantItems(bundle.hits) }
        .contextMenu {
            Button { model.playRelevantItemInEpisode(item) } label: {
                Label("In der Folge ab hier hören", systemImage: "play.fill")
            }
            Button { model.playRelevantItems(bundle.hits) } label: {
                if bundle.hits.count > 1 {
                    Label("Nur diese \(bundle.hits.count) Stellen hören", systemImage: "scope")
                } else {
                    Label("Nur diese Stelle hören", systemImage: "scope")
                }
            }
            if !others.isEmpty {
                Section("Weitere Stellen in dieser Folge") {
                    ForEach(others) { hit in
                        Button { model.playRelevantItemInEpisode(hit) } label: {
                            Label("Ab \(hit.range.start.timecode) hören", systemImage: "play")
                        }
                    }
                }
            }
            Divider()
            Button { model.rememberRelevantItem(item) } label: {
                Label("Stelle merken", systemImage: "bookmark")
            }
            .disabled(model.isRemembered(item))
            Button { model.dismissRelevantItems(bundle.hits) } label: {
                Label("Nicht relevant", systemImage: "eye.slash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button { model.dismissRelevantItems(bundle.hits) } label: {
                Label("Nicht relevant", systemImage: "eye.slash")
            }
        }
        .swipeActions(edge: .leading) {
            if !model.isRemembered(item) {
                Button { model.rememberRelevantItem(item) } label: {
                    Label("Merken", systemImage: "bookmark")
                }
                .tint(.accentColor)
            }
        }
    }

    /// Die Begründung auf der Karte. Das Thema steht schon darüber, hier
    /// steht, welche Wörter getroffen haben.
    private var reason: String? {
        let mentioned = bundle.mentioned
        if !mentioned.isEmpty {
            let terms = mentioned.prefix(3).joined(separator: ", ")
            return String(localized: "erwähnt: \(terms)")
        }
        return item.relevance?.explanation
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
                if let published = item.publishedAt {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(published, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if model.isRemembered(item) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("gemerkt")
                }
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

            HStack(spacing: Design.Spacing.micro) {
                // Der Timecode steht sichtbar dabei. Er ist kein technisches
                // Detail, sondern das Versprechen: das hier kannst du nachhören.
                // Als eigener Knopf: nur er spielt ab, ein Tipp auf die Karte
                // öffnet die Folge.
                Button {
                    model.playRelevantItemInEpisode(item)
                } label: {
                    Label {
                        TimecodeLabel(item.range, emphasis: .medium)
                    } icon: {
                        Image(systemName: "play.fill").font(.caption2)
                    }
                    .padding(.horizontal, Design.Spacing.small)
                    .padding(.vertical, Design.Spacing.micro)
                    .background(.tint.opacity(0.12), in: .capsule)
                    .frame(minHeight: Design.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                if bundle.hits.count > 1 {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text("\(bundle.hits.count) Stellen in dieser Folge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let reason {
                // „Warum sehe ich das?“ steht hier und nicht hinter einem
                // Info-Symbol. Wer die Begründung suchen muss, glaubt sie nicht.
                Label {
                    Text(reason)
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

    /// Zitat, Folge, Podcast, Zeit: in dieser Reihenfolge entscheidet man,
    /// ob man hinhören will.
    private var accessibilityDescription: String {
        var parts = [item.excerpt, item.episodeTitle, String(localized: "aus \(item.sourceTitle)")]
        if let published = item.publishedAt {
            parts.append(published.formatted(.relative(presentation: .named)))
        }
        parts.append(TimecodeLabel.spoken("\(item.range.start.timecode)–\(item.range.end.timecode)"))
        if bundle.hits.count > 1 { parts.append(String(localized: "\(bundle.hits.count) Stellen in dieser Folge")) }
        if let reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Themen

struct SmartFeedListView: View {

    @Environment(AppModel.self) private var model
    @State private var showingNewFeed = false
    @State private var editingFeed: SmartPodcastFeed?
    @State private var pendingDeletion: SmartPodcastFeed?

    var body: some View {
        List {
            if model.smartFeeds.isEmpty {
                ContentUnavailableView {
                    Label("Noch kein Themen-Update", systemImage: "waveform.circle")
                } description: {
                    Text("""
                        Aus deinen Interessen baut PodcastAI einen eigenen Podcast. \
                        Er besteht aus Originalstellen, die du noch nicht gehört hast.
                        """)
                } actions: {
                    Button("Themen-Update anlegen") { showingNewFeed = true }
                }
            }
            ForEach(model.smartFeeds) { feed in
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
        }
        .navigationTitle("Themen-Updates")
        .activityStatusToolbar()
        .navigationDestination(for: SmartFeedID.self) { feedID in
            SmartFeedDetailView(feedID: feedID)
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
        content.confirmationDialog("Themen-Update löschen?", isPresented: Binding(
            get: { feed != nil }, set: { if !$0 { feed = nil } }
        ), titleVisibility: .visible, presenting: feed) { feed in
            Button("„\(feed.title)“ löschen", role: .destructive) {
                model.removeSmartFeed(feed.id)
                onDelete()
            }
        } message: { _ in
            Text("Alle Ausgaben dieses Updates werden gelöscht. Folgen, Transkripte und Hörstand bleiben.")
        }
    }
}

struct SmartFeedRow: View {

    let feed: SmartPodcastFeed
    let editions: [PersonalEpisode]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            // Ein Themenfeed sieht aus wie ein Podcast, auch bevor die
            // erste Ausgabe da ist.
            FeedCoverView(feed: feed, edition: editions.first, size: 56)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(feed.title).font(.headline)
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
        guard let latest = editions.first else {
            return model.editionNotes[feed.id] ?? String(localized: "Noch keine Ausgabe")
        }
        let since = SmartFeedDetailView.readySince(latest.publishedAt)
        var parts = [String(localized: "Bereit seit \(since)"),
                     latest.totalMediaDuration.shortDescription]
        if latest.heardFraction(in: model.ledger) >= 0.8 { parts.append(String(localized: "gehört")) }
        return parts.joined(separator: " · ")
    }

    /// Wann die nächste Ausgabe kommen kann, kurz.
    private var next: String {
        let policy = feed.publicationPolicy
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

/// Ein Themen-Update: die neueste Ausgabe zum Abspielen, der Knopf für eine
/// neue und alle früheren Ausgaben.
///
/// Vorher sprang der Feed direkt in seine erste Ausgabe. Eine zweite
/// entstand in der App nie, frühere waren nicht zu erreichen, Ändern und
/// Löschen gab es nicht.
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
    @State private var addingSource = false
    /// Stichwortvorschläge je Thema ohne Treffer.
    @State private var keywordIdeas: [InterestID: [String]] = [:]
    /// Der Systemdialog von Image Playground, wenn die App selbst kein Bild erzeugen kann.
    @State private var showingPlayground = false

    private var feed: SmartPodcastFeed? { model.smartFeeds.first { $0.id == feedID } }
    private var editions: [PersonalEpisode] { model.editions[feedID] ?? [] }
    private var isBuilding: Bool { requesting || model.buildingFeeds.contains(feedID) }

    /// Themen des Updates, zu denen keine Stelle passt.
    private var topicsWithoutHits: [Interest] {
        let ids = model.editionChecks[feedID]?.topicsWithoutHits ?? []
        return model.profile.interests.filter { ids.contains($0.id) }
    }

    var body: some View {
        List {
            if let latest = editions.first {
                Section {
                    EditionHeader(episode: latest)
                    NavigationLink {
                        PersonalEpisodeView(episode: latest)
                    } label: {
                        Label("Kapitel und Quellen", systemImage: "list.bullet")
                    }
                } header: {
                    Text("Neueste Ausgabe")
                } footer: {
                    Text("Erstellt \(AppModel.editionMoment(latest.publishedAt))")
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
                        Text(model.nextEditionHint(for: feed))
                    }
                }
            }

            if !isBuilding, !topicsWithoutHits.isEmpty {
                topicsWithoutHitsSection
            }

            Section {
                if let feed, !editions.isEmpty {
                    Text(model.nextEditionHint(for: feed))
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
                .disabled(isBuilding || feed == nil)
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

            if editions.count > 1 {
                Section("Frühere Ausgaben") {
                    ForEach(editions.dropFirst()) { edition in
                        NavigationLink {
                            PersonalEpisodeView(episode: edition)
                        } label: {
                            EditionRow(episode: edition)
                        }
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
                }
            }
        }
        .navigationTitle(feed?.title ?? String(localized: "Themen-Update"))
        .toolbar {
            if let feed {
                Menu {
                    Button { editingFeed = feed } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    if model.coverArt.canCreate {
                        Button { createCover(for: feed) } label: {
                            Label("Neues Cover erzeugen", systemImage: "wand.and.sparkles")
                        }
                        .disabled(model.coverArt.isGenerating(feed.id))
                    }
                    if let latest = editions.first {
                        ShareLink(item: ShownotesBuilder().markdown(for: latest)) {
                            Label("Neueste Ausgabe als Text teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) { pendingDeletion = feed } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingFeed) { feed in NewSmartFeedSheet(editing: feed).sheetFeedback() }
        .sheet(isPresented: $addingSource) { AddSourceSheet().sheetFeedback() }
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
        .task(id: topicsWithoutHits) {
            var ideas: [InterestID: [String]] = [:]
            for interest in topicsWithoutHits {
                ideas[interest.id] = Array(
                    AppModel.keywordSuggestions(for: interest.label, existing: interest.keywords).prefix(3))
            }
            keywordIdeas = ideas
        }
    }

    /// Ein Thema ohne Treffer sagt das und schlägt Stichworte vor. Ohne
    /// Stichworte trifft ein Thema nur sein eigenes Wort.
    private var topicsWithoutHitsSection: some View {
        Section {
            ForEach(topicsWithoutHits) { interest in
                NavigationLink {
                    InterestEditView(interest: interest)
                } label: {
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        Text("Zu \(interest.label) noch keine passende Stelle")
                        if let ideas = keywordIdeas[interest.id], !ideas.isEmpty {
                            Text("Stichworte ergänzen, etwa \(ideas.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Stichworte ergänzen, etwa englische Begriffe oder Abkürzungen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button {
                addingSource = true
            } label: {
                Label("Passende Podcasts suchen", systemImage: "magnifyingglass")
            }
        } header: {
            Text("Themen ohne Treffer")
        } footer: {
            Text("""
                Ein Thema findet Stellen, in denen seine Bezeichnung oder eines seiner Stichworte vorkommt, \
                und nur in Folgen mit Transkript.
                """)
        }
    }

    /// Stellt von Hand eine Ausgabe zusammen. Der Fortschritt bleibt kurz
    /// sichtbar, auch wenn die Prüfung sofort fertig ist: sonst sähe der
    /// Tipp aus, als hätte er nichts getan.
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

    /// Ein neues Cover auf Wunsch. Kann die App kein Bild selbst erzeugen,
    /// übernimmt der Systemdialog von Image Playground.
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
                // ja noch zu den Themen.
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

/// Eine frühere Ausgabe in der Liste.
struct EditionRow: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(episode.title)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var details: String {
        let count = episode.segments.count
        var parts = [episode.publishedAt.formatted(date: .abbreviated, time: .shortened),
                     String(AttributedString(localized: "^[\(count) Stelle](inflect: true)").characters),
                     episode.totalMediaDuration.shortDescription]
        if episode.heardFraction(in: model.ledger) >= 0.8 { parts.append(String(localized: "gehört")) }
        return parts.joined(separator: " · ")
    }
}

/// Kopf einer Ausgabe: Cover, Titel, Umfang und „Abspielen“.
struct EditionHeader: View {

    let episode: PersonalEpisode
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            if let feed = model.smartFeeds.first(where: { $0.id == episode.feedID }) {
                FeedCoverView(feed: feed, edition: episode, size: 148)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
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
            Text(episode.title)
                .font(.title2.weight(.bold))
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
            // Bildschirm, sonst wäre keine mehr primär.
            Button(action: play) {
                Label("Abspielen", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
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
/// aber aus Originalstellen.
struct PersonalEpisodeView: View {

    let episode: PersonalEpisode

    var body: some View {
        List {
            Section {
                EditionHeader(episode: episode)
            }

            Section("Kapitel") {
                ForEach(Array(episode.shownotes.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
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
                            Text(origin(of: entry, at: index))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 52 + Design.Spacing.control)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(TimecodeLabel.spokenSingle(entry.virtualStart.timecode)), \(entry.title), aus \(entry.sourceTitle)"
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
            // Kapitel mit Quelle und Originalzeit als Text, etwa für Notizen.
            ShareLink(item: ShownotesBuilder().markdown(for: episode)) {
                Label("Als Text teilen", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Quelle, Folge, Erscheinungsdatum der Originalfolge und Originalzeit.
    private func origin(of entry: ShownotesEntry, at index: Int) -> String {
        var parts = [entry.sourceTitle, entry.episodeTitle]
        if index < episode.segments.count, let published = episode.segments[index].originalPublishedAt {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(String(localized: "Original \(entry.originalRange.start.timecode)"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Meine Podcasts

struct LibraryView: View {

    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var importingOPML = false
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
                            if source.isSubscribed {
                                Label("Abbestellen", systemImage: "minus.circle")
                            } else {
                                Label("Entfernen", systemImage: "minus.circle")
                            }
                        }
                    }
                    .contextMenu {
                        if !source.isSubscribed, source.feedURL != nil {
                            Button { Task { await model.subscribeToSource(source) } } label: {
                                Label("Abonnieren", systemImage: "plus.circle")
                            }
                        }
                        Button(role: .destructive) { pendingRemoval = source } label: {
                            if source.isSubscribed {
                                Label("Abbestellen und Daten löschen", systemImage: "minus.circle")
                            } else {
                                Label("Entfernen und Daten löschen", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Meine Podcasts")
        .activityStatusToolbar()
        .confirmationDialog(removalTitle, isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { source in
            // Ein Podcast mit nur einzeln geholten Folgen ist kein Abo.
            if source.isSubscribed {
                Button("\(source.title) abbestellen", role: .destructive) {
                    Task { await model.removeSource(source.id) }
                }
            } else {
                Button("\(source.title) entfernen", role: .destructive) {
                    Task { await model.removeSource(source.id) }
                }
            }
        } message: { _ in
            Text("Alle Folgen dieses Podcasts werden mit Transkripten, Fakten und Hörstand gelöscht.")
        }
        .navigationDestination(for: SourceID.self) { sourceID in
            EpisodeListView(sourceID: sourceID)
        }
        .toolbar {
            // Abos aus einer anderen App übernehmen oder mitnehmen.
            Menu {
                Button { importingOPML = true } label: {
                    Label("Abos aus Datei importieren", systemImage: "square.and.arrow.down")
                }
                ShareLink(item: SubscriptionsExport(feeds: model.exportableFeeds),
                          preview: SharePreview(SubscriptionsExport.fileName)) {
                    Label("Abos exportieren (OPML)", systemImage: "square.and.arrow.up")
                }
                .disabled(model.exportableFeeds.isEmpty)
            } label: {
                Label("Abos importieren oder exportieren", systemImage: "arrow.up.arrow.down.circle")
            }
            Button { showingAdd = true } label: {
                Label("Podcast hinzufügen", systemImage: "plus")
            }
            #if os(iOS)
            SettingsToolbarLink()
            #endif
        }
        .sheet(isPresented: $showingAdd) { AddSourceSheet().sheetFeedback() }
        .opmlImport(isPresented: $importingOPML)
        .overlay {
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Podcasts", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Füge einen Podcast, eine einzelne Folge oder einen YouTube-Kanal hinzu.")
                } actions: {
                    Button("Podcast hinzufügen") { showingAdd = true }
                    Button("Abos aus Datei importieren") { importingOPML = true }
                }
            }
        }
    }
}

extension LibraryView {
    var removalTitle: LocalizedStringKey {
        pendingRemoval?.isSubscribed == false ? "Entfernen?" : "Abbestellen?"
    }

    var queueSummary: String {
        let listen = model.upNext.count
        let analyze = model.analysisQueue.count + (model.analyzing == nil ? 0 : 1)
        if listen == 0 && analyze == 0 { return String(localized: "Nichts vorgemerkt") }
        var parts: [String] = []
        if listen > 0 {
            parts.append(String(AttributedString(localized: "^[\(listen) Folge](inflect: true) zum Hören").characters))
        }
        if analyze > 0 {
            parts.append(analyze == 1
                         ? String(localized: "1 Transkript wird erstellt")
                         : String(localized: "\(analyze) Transkripte werden erstellt"))
        }
        return parts.joined(separator: " · ")
    }
}

struct SourceRow: View {

    let source: Source
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
        EpisodeArtwork(url: source.artworkURL, size: 52)
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(source.title).font(.headline).lineLimit(2)
            if let author = source.author {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // Einzelne Folgen aus einem Podcast, der kein Abo ist.
            if !source.isSubscribed {
                Label("Nicht abonniert", systemImage: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("source.notSubscribed")
            }
            // Grenzen werden angezeigt, nicht versteckt. Ein Kanal ohne
            // Audiozugang soll nicht so aussehen wie einer mit. Mit eigenem
            // Supadata-Schlüssel bekommt ein YouTube-Kanal Transkripte.
            if !source.capabilities.supportsTimedKnowledge,
               !(source.kind == .youTubeChannel && model.allowsSupadataRequests),
               let reason = source.capabilities.limitationReason {
                NoticeLabel(reason, kind: .info)
                    .font(.caption2)
            }
        }
        }
    }
}

/// „Podcast hinzufügen“: Suche, eingefügter Link, OPML-Import und der
/// Podcast-Katalog mit Angesagt und Kategorien.
///
/// Gesucht wird bei Apple Podcasts und bei Podcast Index zugleich. Angesagt
/// und Kategorien sind die Charts von Apple Podcasts im Land des Geräts.
struct AddSourceSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var results: [CatalogPodcast] = []
    @State private var searchedTerm: String?
    @State private var searching = false
    @State private var addingLink = false
    @State private var failure: String?
    /// Das Suchfeld ist beim Öffnen aktiv. Wer das Blatt öffnet, will tippen.
    @FocusState private var fieldFocused: Bool
    /// Was zuletzt gescheitert ist, damit „Nochmal versuchen“ es wiederholt.
    @State private var lastAttempt: Attempt?
    /// Die offenen Seiten des Katalogs: Rubrik, Angesagt, Podcast.
    @State private var path: [CatalogRoute] = []
    /// Abos aus diesem Blatt. Trefferliste, Rubriken und Detailseite zeigen
    /// denselben Stand.
    @State private var subscriptions = CatalogSubscriptions()

    private let catalog = PodcastCatalog.shared

    private enum Attempt: Equatable {
        case search(String)
        case link(String)
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isLink: Bool {
        trimmed.contains("://") || trimmed.hasPrefix("www.") || FeedRefresher.firstLink(in: trimmed) != nil
    }

    /// Führt der Link zu einer Auswahl? YouTube und Folgen aus Apple
    /// Podcasts zeigen erst eine Vorschau, Feeds und Dateien nicht.
    private var linkOpensPreview: Bool {
        let text = FeedRefresher.firstLink(in: trimmed)?.absoluteString ?? trimmed
        if let url = URL(string: text), EpisodeLinks.appleEpisode(in: url) != nil { return true }
        switch try? SourceResolver().resolve(text) {
        case .youTubeChannel?, .youTubeChannelPage?, .youTubeVideo?, .youTubePlaylist?: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        // Einzeilig: in einem mehrzeiligen Feld fügt die
                        // Eingabetaste einen Zeilenumbruch ein, statt abzuschicken.
                        // Die Eingabetaste tut dasselbe wie der Knopf oben:
                        // suchen oder abonnieren, und die Tastatur geht weg.
                        TextField("Podcast suchen oder Link einfügen", text: $input)
                            .focused($fieldFocused)
                            .accessibilityIdentifier("source.input")
                            .onSubmit(submit)
                            .submitLabel(isLink ? .go : .search)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        if !input.isEmpty {
                            Button {
                                input = ""
                                fieldFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Eingabe löschen")
                            .accessibilityIdentifier("source.clear")
                        }
                    }
                } footer: {
                    // Kurz halten. Wer einen Link hat, fügt ihn ein, der Rest
                    // steht in der Hilfe.
                    Text("Tippe den Namen der Sendung ein. Ein Link aus Apple Podcasts oder von YouTube geht auch.")
                }

                if let failure {
                    Section {
                        NoticeLabel(failure, kind: .failure)
                            .accessibilityIdentifier("source.error")
                        if lastAttempt != nil {
                            Button("Nochmal versuchen", systemImage: "arrow.clockwise", action: retry)
                                .disabled(addingLink || searching)
                                .accessibilityIdentifier("source.retry")
                        }
                    }
                } else if let failed = subscriptions.failure {
                    Section {
                        NoticeLabel(String(localized: "„\(failed.podcast.title)“: \(failed.message)"), kind: .failure)
                            .accessibilityIdentifier("source.error")
                        Button("Nochmal versuchen", systemImage: "arrow.clockwise") {
                            Task { await subscriptions.subscribe(failed.podcast, model: model) }
                        }
                        .disabled(subscriptions.state(of: failed.podcast, in: model) == .working)
                        .accessibilityIdentifier("source.retry")
                    }
                }

                if isLink, let socialHint {
                    // Ein Profil oder ein Beitrag ohne Schlüssel: ein ruhiger
                    // Satz statt eines Knopfs, der nur scheitern könnte.
                    Section {
                        NoticeLabel(socialHint, kind: .info)
                            .accessibilityIdentifier("source.socialHint")
                        if case .post? = AppModel.socialLink(in: trimmed) {
                            NavigationLink {
                                SupadataSettingsView()
                            } label: {
                                Label("Supadata-Schlüssel eintragen", systemImage: "key")
                            }
                        }
                    }
                } else if isLink {
                    Section {
                        Button(action: submit) {
                            HStack {
                                if AppModel.socialLink(in: trimmed) != nil {
                                    Label("Diesen Beitrag hinzufügen", systemImage: "plus.circle.fill")
                                } else if linkOpensPreview {
                                    Label("Diesen Link öffnen", systemImage: "link.circle.fill")
                                } else {
                                    Label("Diesen Link hinzufügen", systemImage: "plus.circle.fill")
                                }
                                Spacer()
                                if addingLink { ProgressView() }
                            }
                        }
                        .disabled(addingLink)
                        .accessibilityIdentifier("source.addLink")
                    }
                } else if searching && results.isEmpty {
                    Section { HStack { ProgressView(); Text("Suche bei Apple Podcasts und Podcast Index …").foregroundStyle(.secondary) } }
                } else if !results.isEmpty {
                    Section {
                        ForEach(results) { podcast in
                            CatalogPodcastRow(podcast: podcast,
                                              state: subscriptions.state(of: podcast, in: model),
                                              subscribe: {
                                                  // Die Tastatur lag sonst über dem Knopf, den man als Nächstes braucht.
                                                  fieldFocused = false
                                                  Task { await subscriptions.subscribe(podcast, model: model) }
                                              },
                                              preview: {
                                                  fieldFocused = false
                                                  path.append(.podcast(podcast))
                                              })
                        }
                    } header: {
                        Text("Treffer aus Apple Podcasts und Podcast Index")
                    } footer: {
                        VStack(alignment: .leading, spacing: Design.Spacing.small) {
                            Text(preparationNote)
                            CatalogAttribution()
                        }
                    }
                } else if let searchedTerm, searchedTerm == trimmed, !trimmed.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }

                // Mit eigenem Supadata-Schlüssel: dieselbe Eingabe als Suche
                // nach YouTube-Kanälen, erst auf Tippen.
                if !isLink, !trimmed.isEmpty, searchedTerm == trimmed, model.allowsSupadataRequests {
                    YouTubeChannelSearchSection(term: trimmed)
                        .id(trimmed)
                }

                if trimmed.isEmpty {
                    // Der Import aus einer anderen App steht nur noch im Menü
                    // von „Meine Podcasts“, das Blatt beginnt mit dem Katalog.
                    CatalogTrendingSection()
                    Section {
                        CatalogCategoryGrid()
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    } header: {
                        Text("Kategorien")
                    } footer: {
                        CatalogAttribution()
                    }
                }
            }
            // Wer in der Trefferliste scrollt, will die Knöpfe sehen, nicht
            // die Tastatur. Sie lag sonst über „Abonnieren“.
            .scrollDismissesKeyboard(.immediately)
            .navigationDestination(for: CatalogRoute.self) { route in
                switch route {
                case .podcast(let podcast): CatalogPodcastDetailView(podcast: podcast)
                case .trending: CatalogListView(category: nil)
                case .category(let category): CatalogListView(category: category)
                case .linkPodcast(let link): LinkPodcastView(link: link)
                case .youTube(let link): YouTubeLinkView(link: link)
                }
            }
            .navigationTitle("Hinzufügen")
            .task {
                // Kurz warten, bis das Blatt steht. Sofort gesetzt, greift der Fokus nicht.
                try? await Task.sleep(for: .milliseconds(450))
                fieldFocused = true
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: trimmed) { await searchAfterPause() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !subscriptions.hasChanges {
                        // Bei einem Namen sucht der Knopf nur, abonniert wird
                        // in der Trefferliste.
                        Button(isLink ? "Hinzufügen" : "Suchen", action: submit)
                            .disabled(trimmed.isEmpty || addingLink)
                    } else {
                        Button("Fertig") { dismiss() }
                    }
                }
                // Nach einem Abo gibt es nichts mehr abzubrechen. Neben
                // „Fertig“ klang „Abbrechen“, als nähme es das Abo zurück.
                if !subscriptions.hasChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                }
            }
        }
        .environment(subscriptions)
        .environment(\.catalogNavigate, CatalogNavigator { route in
            fieldFocused = false
            path.append(route)
        })
        .onDisappear { Task { await model.forgetPodcastPreview() } }
    }

    /// Was nach dem Abonnieren passiert, so wie die Einstellungen es gerade
    /// vorsehen.
    private var preparationNote: String {
        guard model.automaticAnalysis else {
            let off = String(localized: """
                „Transkripte für neue Folgen erstellen“ ist in den Einstellungen aus. \
                Das Transkript einer Folge erstellst du dann selbst, wenn du es brauchst.
                """)
            guard model.keepNewestAudio else { return off }
            return off + " " + String(localized: """
                Die neueste Folge legt die App trotzdem für unterwegs aufs Gerät.
                """)
        }
        // Hat das Gerät keine Spracherkennung, reiht die App nichts von selbst
        // ein. Dann darf hier auch keine Vorbereitung versprochen werden.
        if let unavailable = model.preparationUnavailable {
            return String(localized: """
                Transkripte für neue Folgen erstellt die App gerade nicht. \(unavailable) \
                Das Transkript einer Folge kannst du trotzdem selbst anfordern.
                """)
        }
        let count = model.episodesPerSource
        var sentences = [count == 1
            ? String(localized: """
                Nach dem Abonnieren bereitet die App die neueste Folge vor: \
                laden, Transkript erstellen, Fakten finden.
                """)
            : String(localized: """
                Nach dem Abonnieren bereitet die App die \(count) neuesten Folgen vor: \
                laden, Transkript erstellen, Fakten finden.
                """)]
        // Sonst wundert man sich später, dass eine geladene Folge wieder weg ist.
        switch (model.keepNewestAudio, model.removeAudioAfterAnalysis) {
        case (true, true):
            sentences.append(String(localized: """
                Die neueste Folge bleibt für unterwegs auf dem Gerät. Bei den anderen nimmt die App \
                das Audio danach wieder weg, abgespielt wird dann aus dem Netz.
                """))
        case (false, true):
            sentences.append(String(localized: """
                Das Audio nimmt die App danach wieder vom Gerät, abgespielt wird dann aus dem Netz.
                """))
        case (true, false):
            sentences.append(String(localized: "Die neueste Folge bleibt für unterwegs auf dem Gerät."))
        case (false, false):
            break
        }
        // Was das Netz gerade erlaubt, nicht nur was eingestellt ist.
        switch model.preparationWait {
        case .offline?:
            sentences.append(String(localized: "Gerade ist kein Netz da. Die App fängt an, sobald wieder eines da ist."))
        case .lowDataMode?:
            sentences.append(String(localized: "Solange der Datensparmodus an ist, wartet die App damit."))
        case .hotspot?:
            sentences.append(String(localized: """
                Geladen wird dafür nur im WLAN. Ein Hotspot zählt nicht dazu, die App wartet also.
                """))
        case .cellular?:
            sentences.append(String(localized: "Geladen wird dafür nur im WLAN. Die App wartet, bis eines da ist."))
        case nil:
            if model.preparationOnWiFiOnly {
                sentences.append(String(localized: "Geladen wird dafür nur im WLAN."))
            }
        }
        sentences.append(String(localized: """
            Ältere Folgen bereitet die App vor, wenn du in der Folgenliste des Podcasts „Ältere Folgen \
            auch vorbereiten“ wählst.
            """))
        return sentences.joined(separator: " ")
    }

    /// Warum ein Link aus einem sozialen Netz hier nicht geht, oder `nil`.
    private var socialHint: String? {
        switch AppModel.socialLink(in: trimmed) {
        case .profile?:
            SupadataFeatureError.profileNotSupported.errorDescription
        case .post(let platform, _)? where !model.allowsSupadataRequests:
            SupadataFeatureError.needsKey(platform).errorDescription
        default:
            nil
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !(isLink && socialHint != nil) else { return }
        fieldFocused = false
        let text = trimmed
        if isLink {
            Task { await subscribeLink(text) }
        } else {
            Task { await search(text) }
        }
    }

    private func retry() {
        switch lastAttempt {
        case .search(let term)?: Task { await search(term) }
        case .link(let text)?: Task { await subscribeLink(text) }
        case nil: break
        }
    }

    private func searchAfterPause() async {
        failure = nil
        // Wer weitertippt, sucht etwas anderes. Der Fehler beim Abonnieren
        // eines früheren Treffers geht dann weg, wie jeder andere.
        subscriptions.failure = nil
        guard !isLink, trimmed.count >= 2 else { results = []; searchedTerm = nil; return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        await search(trimmed)
    }

    private func search(_ term: String) async {
        searching = true
        defer { searching = false }
        do {
            let found = try await catalog.search(term)
            guard term == trimmed else { return }
            // Ein erneuter Versuch über „Suchen“ ändert den Text nicht. Die
            // alte Fehlermeldung muss dann hier weg, nicht erst beim Tippen.
            failure = nil
            results = found
            searchedTerm = term
        } catch is CancellationError {
            return
        } catch {
            // Kein „Keine Ergebnisse“, wenn gar nicht gesucht werden konnte.
            guard term == trimmed else { return }
            results = []
            searchedTerm = nil
            failure = UserFacingError.describe(error)
            lastAttempt = .search(term)
        }
    }

    /// Feeds und Dateien werden gleich angelegt. Führt der Link zu einer
    /// Folge oder zu YouTube, kommt erst die Vorschau mit der Auswahl.
    private func subscribeLink(_ text: String) async {
        addingLink = true
        failure = nil
        subscriptions.linkFailure = nil
        defer { addingLink = false }
        do {
            // Beiträge aus TikTok, Instagram und Co. gehen über Supadata,
            // nicht über die Suche nach einem Feed.
            if AppModel.socialLink(in: text) != nil {
                try await model.subscribe(to: text)
                dismiss()
                return
            }
            switch try await model.inspectLink(text) {
            case .direct:
                try await model.subscribe(to: text)
                dismiss()
            case .audioFile(let url, let title):
                try await model.addAudioEpisode(url, title: title)
                dismiss()
            case .podcast(let link):
                path.append(.linkPodcast(link))
            case .youTube(let link):
                path.append(.youTube(link))
            }
        } catch is CancellationError {
            return
        } catch {
            failure = UserFacingError.describe(error)
            lastAttempt = .link(text)
        }
    }
}

// MARK: - Interessen

struct InterestsView: View {

    @Environment(AppModel.self) private var model
    @State private var newLabel = ""

    var body: some View {
        List {
            Section {
                ForEach(model.profile.topics) { interest in
                    NavigationLink { InterestEditView(interest: interest) } label: { InterestRow(interest: interest) }
                }
                .onDelete { offsets in remove(model.profile.topics, at: offsets) }
            } header: {
                Text("Themen")
            } footer: {
                Text("Deine Themen füllen „Für dich“ und die Themen-Updates. Antippen, um Stichworte zu ergänzen.")
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

            // Nur Themen. Die Arten „Vorhaben“ und „Frage“ machten das
            // Anlegen komplizierter (Rückmeldung zu 0.6 und 0.7).
            Section {
                TextField("z. B. Datenschutz", text: $newLabel)
                    .accessibilityIdentifier("interest.new")
                    .onSubmit(add)
                Button("Hinzufügen", action: add)
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Thema hinzufügen")
            }
        }
        .navigationTitle("Interessen")
    }

    private func add() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        newLabel = ""
        Task { await model.addInterest(label, kind: .topic) }
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
            if !interest.keywords.isEmpty {
                Text("Stichworte: \(interest.keywords.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(interest.origin.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Bezeichnung und Stichworte eines Interesses. Ohne Stichworte trifft ein
/// Thema nur sein eigenes Wort.
struct InterestEditView: View {

    @Environment(AppModel.self) private var model
    @State private var interest: Interest
    @State private var newKeyword = ""
    @State private var suggestions: [String] = []
    @State private var saved: Interest

    init(interest: Interest) {
        _interest = State(initialValue: interest)
        _saved = State(initialValue: interest)
    }

    var body: some View {
        Form {
            Section("Bezeichnung") {
                TextField("Bezeichnung", text: $interest.label)
                    .onSubmit(save)
            }
            Section {
                ForEach(interest.keywords, id: \.self) { Text($0) }
                    .onDelete { offsets in interest.keywords.remove(atOffsets: offsets); save() }
                HStack {
                    TextField("Stichwort hinzufügen", text: $newKeyword)
                        .accessibilityIdentifier("interest.keyword")
                        .onSubmit(addKeyword)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Hinzufügen", action: addKeyword)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Stichworte")
            } footer: {
                Text("""
                    Eine Stelle passt, wenn die Bezeichnung oder eines dieser Stichworte am Wortanfang vorkommt: \
                    „daten“ trifft „Datenschutz“, „schutz“ trifft es nicht. Begriffe mit bis zu drei Buchstaben \
                    wie KI zählen nur als ganzes Wort. Bei mehreren Wörtern braucht es den ganzen Ausdruck oder \
                    zwei der wichtigen Wörter daraus, Füllwörter zählen nicht. Englische Fachbegriffe und \
                    Abkürzungen hier ergänzen.
                    """)
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { word in
                        Button { add(word) } label: { Label(word, systemImage: "plus.circle") }
                    }
                } header: {
                    Text("Verwandte Wörter")
                } footer: {
                    Text("Aus dem Wortschatz des Systems, auf diesem Gerät berechnet. Nur übernehmen, was passt.")
                }
            }
        }
        .navigationTitle(interest.label.isEmpty ? String(localized: "Interesse") : interest.label)
        .task(id: interest.label) { refreshSuggestions() }
        .onDisappear(perform: save)
    }

    private func addKeyword() {
        for part in newKeyword.split(separator: ",") { add(String(part)) }
        newKeyword = ""
    }

    private func add(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty,
              !interest.keywords.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        interest.keywords.append(clean)
        refreshSuggestions()
        save()
    }

    private func refreshSuggestions() {
        suggestions = AppModel.keywordSuggestions(for: interest.label, existing: interest.keywords)
    }

    private func save() {
        let trimmed = interest.label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        interest.label = trimmed
        guard interest != saved else { return }
        saved = interest
        let snapshot = interest
        Task { await model.updateInterest(snapshot) }
    }
}

/// Legt ein Themen-Update an oder ändert eines.
struct NewSmartFeedSheet: View {

    /// Gesetzt, wenn ein bestehendes Update bearbeitet wird.
    var editing: SmartPodcastFeed? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var selected: Set<InterestID> = []
    @State private var minutes = 20
    @State private var newTopic = ""
    /// Leer heißt: alle abonnierten Quellen.
    @State private var selectedSources: Set<SourceID> = []
    @State private var prepared = false

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
                        Text(editing == nil
                             ? "Antippen wählt ein Thema ab oder wieder aus. Ein eingetipptes Thema wird beim Anlegen mitgenommen. Stichworte zu einem Thema ergänzt du unter „Wissen › Interessen“."
                             : "Antippen wählt ein Thema ab oder wieder aus. Ein eingetipptes Thema wird beim Sichern mitgenommen.")
                    }
                }
                Section {
                    Stepper("\(minutes) Minuten je Ausgabe", value: $minutes, in: 5...120, step: 5)
                } footer: {
                    // Eine neue Ausgabe nimmt nur Ungehörtes. Was nicht
                    // hineinpasst, rückt also erst nach, wenn das Vorige gehört ist.
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("""
                            Passt nicht alles hinein, kommen die wichtigsten Stellen zuerst. \
                            Der Rest rückt nach, sobald du sie gehört hast.
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Der Knopf legte bisher nichts an, er schloss nur das
                    // Blatt. Das Themen-Update — das sichtbarste Merkmal des
                    // Konzepts — war damit nicht erreichbar.
                    Button(editing == nil ? "Anlegen" : "Sichern") {
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

    /// Die Regel des Updates, beim Anlegen die übliche.
    private var publicationPolicy: PublicationPolicy {
        editing?.publicationPolicy ?? SmartPodcastFeed(title: "", topicIDs: []).publicationPolicy
    }

    private var canCreate: Bool {
        !selected.isEmpty || !pendingTopic.isEmpty
    }

    /// Füllt das Blatt einmal: beim Bearbeiten mit dem Update, sonst mit
    /// allen Themen.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let editing {
            title = editing.title
            let known = Set(model.profile.topics.map(\.id))
            selected = Set(editing.topicIDs).intersection(known)
            if let budget = editing.editionMode.budget {
                let value = Int(budget.milliseconds / 60_000)
                minutes = min(120, max(5, (value + 2) / 5 * 5))
            }
            let live = Set(model.sources.map(\.id))
            selectedSources = Set(editing.restrictedToSourceIDs).intersection(live)
            return
        }
        // Alle Themen sind vorausgewählt. Wer nichts abwählt, bekommt
        // ein Update über alles, was ihn interessiert.
        if selected.isEmpty { selected = Set(model.profile.topics.map(\.id)) }
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
            ? Self.defaultName(for: labels)
            : title
        // In der Reihenfolge der Mediathek, damit gleiche Auswahl gleich aussieht.
        let sourceIDs = model.sources.map(\.id).filter(selectedSources.contains)
        if var feed = editing {
            feed.title = name
            feed.topicIDs = topicIDs
            feed.editionMode = .budgeted(MediaDuration(minutes: minutes))
            feed.restrictedToSourceIDs = sourceIDs
            model.updateSmartFeed(feed)
            dismiss()
            return
        }
        let feedID = model.createSmartFeed(
            title: name, topicIDs: topicIDs, minutes: minutes, sourceIDs: sourceIDs)
        dismiss()
        // Gleich eine erste Ausgabe bauen: ein leerer Feed direkt nach dem
        // Anlegen sieht aus wie ein Fehler.
        await model.buildEdition(feedID: feedID)
    }

    /// Der Name, wenn keiner eingetippt ist: die ersten beiden Themen.
    private static func defaultName(for labels: [String]) -> String {
        switch labels.count {
        case 0: String(localized: "Mein Update")
        case 1: labels[0]
        default: String(localized: "\(labels[0]) und \(labels[1])")
        }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingNote = false
    @State private var note = ""
    /// Die Stelle beim Öffnen des Blatts. Läuft der Plan weiter, während
    /// der Kommentar entsteht, gehört die Notiz trotzdem hierher.
    @State private var captured: (media: MediaVersionID, position: MediaTime, episodeID: EpisodeID?)?

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

    /// Anteil der laufenden Stelle, der schon gespielt ist, zwischen 0 und 1.
    /// Die Position zählt in der Originalfolge, wie die Grenzen der Stelle.
    private func segmentProgress(_ range: MediaTimeRange) -> Double {
        let length = Double(range.end.milliseconds - range.start.milliseconds)
        guard length > 0 else { return 0 }
        let done = Double(model.playerPosition.milliseconds - range.start.milliseconds)
        return min(1, max(0, done / length))
    }

    var body: some View {
        Group {
            // Gespiegelter Zustand, nicht der Koordinator: `PlaybackCoordinator`
            // ist nicht beobachtbar, eine Ansicht darauf bliebe stehen.
            if let plan = model.playerPlan,
               let index = activeSegmentIndex,
               index < plan.segments.count {
                // Im Rollbereich, damit bei großer Schrift nichts abgeschnitten wird.
                ScrollView {
                    playing(plan, at: index)
                        .padding()
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Nichts wird abgespielt",
                    systemImage: "speaker.slash",
                    description: Text("Starte eine Ausgabe oder eine Stelle aus „Für dich“.")
                )
                .padding()
            }
        }
        .navigationTitle("Wiedergabe")
        .sheet(isPresented: $showingNote) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Notiz (optional)", text: $note, axis: .vertical)
                            .lineLimit(3...6)
                    } footer: {
                        Text("""
                            Gemerkt wird die Stelle, die beim Antippen lief, mit Folge, Quelle \
                            und Zeitmarke. Gibt es ein Transkript, kommt der Originaltext dazu. \
                            Deine Notiz bleibt davon getrennt und wird nie überschrieben.
                            """)
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
            .sheetFeedback()
        }
    }

    /// Oben groß das Cover, darunter klein die Quelle der laufenden Stelle.
    ///
    /// Bei einem Themen-Update ist das Cover das des Updates. Bei „Für dich“
    /// und im Chat gibt es kein eigenes Cover, dort steht oben das Cover des
    /// Podcasts, aus dem die Stelle gerade kommt.
    @ViewBuilder
    private func playing(_ plan: ValidatedPlaybackPlan, at index: Int) -> some View {
        let segment = plan.segments[index]
        let edition = model.edition(playing: plan)
        let feed = edition.flatMap { edition in model.smartFeeds.first { $0.id == edition.feedID } }
        let podcastArtwork = model.podcastArtworkURL(for: segment)

        VStack(spacing: Design.Spacing.section) {
            FocusHeroArtwork(
                feed: feed, edition: edition, podcastArtwork: podcastArtwork,
                maxSide: dynamicTypeSize.isAccessibilitySize ? 200 : 320)

            // Worum es in dieser Wiedergabe geht. Bei einer einzelnen Stelle
            // ist das die Folge selbst, dann steht sie nur einmal da.
            if plan.requestSummary != segment.episodeTitle {
                Text(plan.requestSummary)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            FocusSourceCard(
                segment: segment, position: index + 1, count: plan.segments.count,
                artworkURL: podcastArtwork)

            // Die ganze Folge, aus der die Stelle stammt, an der Stelle, die
            // gerade läuft. Das beendet diese Wiedergabe.
            // Auf dem iPhone liegt der Player in einem Blatt. Es schließt,
            // damit die Folge nicht hinter einem leeren Player läuft. Auf dem
            // Mac steht er in der Seitenansicht, dort schlösse `dismiss` das
            // Fenster.
            #if os(iOS)
            OpenOriginalButton(episodeID: segment.episodeID, position: originalPosition(of: segment)) {
                dismiss()
            }
            .font(.callout)
            #else
            OpenOriginalButton(episodeID: segment.episodeID, position: originalPosition(of: segment))
                .font(.callout)
            #endif

            // Wie weit die Stelle schon gelaufen ist.
            ProgressView(value: segmentProgress(segment.range))
                .accessibilityLabel("Fortschritt der Stelle")

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
                .accessibilityLabel(isPaused ? "Fortsetzen" : "Pause")

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

            if let rationale = segment.rationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // „Merken“ gab es bisher nur als Kurzbefehl, in der App
            // selbst führte kein Weg dorthin. Das Kapitel „Highlights
            // und Wissen“ beginnt aber hier, beim Hören.
            Button {
                captured = model.player.currentOriginalPosition().map { media, position in
                    let segments = model.playerPlan?.segments ?? []
                    let episodeID = activeSegmentIndex.flatMap {
                        $0 < segments.count ? segments[$0].episodeID : nil
                    }
                    return (media, position, episodeID)
                }
                showingNote = true
            } label: {
                Label("Diese Stelle merken", systemImage: "bookmark")
            }
            .buttonStyle(.bordered)
            .disabled(model.player.currentOriginalPosition() == nil)
        }
        // Wechselt die Stelle, gleiten Cover und Quelle über, statt zu springen.
        .animation(reduceMotion ? nil : Design.Motion.smooth, value: index)
    }

    /// Wo die laufende Stelle im Original gerade steht, wie beim
    /// Fortschritt. Liegt die Position außerhalb der Stelle, etwa während
    /// sie vorbereitet wird, ihr Anfang.
    private func originalPosition(of segment: PlanSegment) -> MediaTime {
        segment.range.contains(model.playerPosition) ? model.playerPosition : segment.range.start
    }

    private func remember() {
        guard let captured else {
            showingNote = false
            return
        }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        showingNote = false
        note = ""
        self.captured = nil
        Task {
            await model.rememberPassage(
                at: captured.position, in: captured.media, episodeID: captured.episodeID,
                note: text.isEmpty ? nil : text, via: .player)
        }
    }
}


/// Das große Cover im Player: das des Themen-Updates oder das des Podcasts
/// der laufenden Stelle.
private struct FocusHeroArtwork: View {

    let feed: SmartPodcastFeed?
    let edition: PersonalEpisode?
    let podcastArtwork: URL?
    let maxSide: CGFloat

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: maxSide)
            .overlay {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    if let feed {
                        FeedCoverView(feed: feed, edition: edition, size: side)
                    } else {
                        EpisodeArtwork(url: podcastArtwork, size: side)
                            .id(podcastArtwork)
                            .transition(.opacity)
                    }
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            .padding(.top, Design.Spacing.small)
    }
}

/// Die Quelle der laufenden Stelle, klein unter dem Cover: Podcastcover,
/// Podcast, Folge, Zeitbereich und Position im Plan.
private struct FocusSourceCard: View {

    let segment: PlanSegment
    let position: Int
    let count: Int
    let artworkURL: URL?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Spacing.small))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Design.Spacing.control))
        layout {
            EpisodeArtwork(url: artworkURL, size: 56)
                .id(artworkURL)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(segment.sourceTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(segment.episodeTitle)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Spacing.small) { timeAndPosition }
                    VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) { timeAndPosition }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Design.Spacing.control)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(
            cornerRadius: Design.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timeAndPosition: some View {
        TimecodeLabel(segment.range)
        Text("Stelle \(position) von \(count)")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    if let categories = source.categories, !categories.isEmpty {
                        LabeledContent("Rubriken", value: categories.joined(separator: " · "))
                    }
                    if let language = SourceFacts.languageName(source.language) {
                        LabeledContent("Sprache", value: language)
                    }
                    if let explicit = source.isExplicit {
                        LabeledContent("Explizite Inhalte", value: explicit
                            ? String(localized: "Ja") : String(localized: "Nein"))
                    }
                    if let url = source.websiteURL {
                        LabeledContent("Webseite") {
                            Link(url.host() ?? url.absoluteString, destination: url)
                        }
                    }
                    LabeledContent("Automatische Transkripte", value: source.backfillPolicy.label)
                }
                if let summary = source.summary {
                    Section("Beschreibung") {
                        Text(summary)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    // Fähigkeiten einzeln und ehrlich: ein Kanal ohne
                    // Audiozugang soll nicht aussehen wie einer mit.
                    CapabilityRow(title: "Audio abrufbar",
                                  isAvailable: source.capabilities.audioDownload)
                    CapabilityRow(title: "Transkript vom Anbieter",
                                  isAvailable: source.capabilities.publisherTranscript)
                    CapabilityRow(title: "Alle Folgen abrufbar",
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
        .navigationTitle(source?.title ?? String(localized: "Quelle"))
    }
}

struct CapabilityRow: View {

    let title: LocalizedStringKey
    let isAvailable: Bool

    var body: some View {
        HStack {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isAvailable ? .green : .secondary)
            Text(title)
        }
    }
}

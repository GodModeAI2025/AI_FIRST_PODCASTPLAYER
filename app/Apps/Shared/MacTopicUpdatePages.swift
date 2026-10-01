//
//  MacTopicUpdatePages.swift
//  PodcastAI
//
//  „Themen-Updates“ auf dem Mac: Updates als Karten in einem Raster, die
//  Seite eines Updates mit Kopf, Ausgaben als Karten mit sichtbarem
//  Abspielknopf und einem Kasten für die nächste Ausgabe. Nur macOS, die
//  iPhone-Listen in `TopicUpdateViews.swift` bleiben, wie sie sind.
//
//  Eine Karte öffnet. Ton startet nur der Knopf auf einer Ausgabe, und nur
//  auf einen Klick.
//

#if os(macOS)
import SwiftUI
import PodcastAIKit

// MARK: - Liste der Updates

extension SmartFeedListView {

    var macContent: some View {
        MacPage {
            if showsTrending { macTrendingSection }
            if !model.topicUpdatesHeader.isEmpty {
                MacSection(header: MacSectionHeader(
                    "Neu seit dem letzten Hören",
                    note: "Neue Aussagen je Tag aus Folgen, die nach der zuletzt gehörten Ausgabe erschienen sind."
                )) {
                    MacTagCountChips(counts: Array(model.topicUpdatesHeader.prefix(TopicStatisticsHeader.maximumTags)),
                                     container: "topicUpdates.header") { openedTag = $0 }
                }
            }
            if model.userSmartFeeds.isEmpty {
                MacEmptyState("Noch kein Themen-Update", symbol: "waveform.circle",
                              sentence: "Aus den Tags, denen du folgst, baut PodcastAI einen eigenen Podcast.",
                              minHeight: showsTrending || !model.topicUpdatesHeader.isEmpty ? 220 : 340) {
                    Button("Themen-Update anlegen") { showingNewFeed = true }
                        .buttonStyle(.prominentAction)
                }
            } else {
                MacSection(header: MacSectionHeader(
                    title: Text("Deine Updates"), count: model.userSmartFeeds.count,
                    note: Text("Jedes Update sammelt Kapitel zu seinen Tags und baut daraus Ausgaben.")
                )) {
                    LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
                        ForEach(model.userSmartFeeds) { feed in
                            MacFeedCard(feed: feed, editions: model.editions[feed.id] ?? [])
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
                }
            }
        }
        .yieldsAIWhileScrolling()
    }

    private var macTrendingSection: some View {
        MacSection(header: MacSectionHeader(
            title: Text("Angesagt"),
            count: model.trendingTags.isEmpty ? nil : model.trendingTags.count,
            note: Text(TrendText.footer())
        )) {
            if !model.trendingTags.isEmpty {
                MacTrendingChips(entries: model.trendingTags) { openedTag = $0 }
            }
            LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    TrendingFeedToggle()
                    Text("""
                        Ein Themen-Update aus den Tags, die gerade angesagt sind. Seine Tags wechseln mit den \
                        Trends, Tags mit Minus bleiben draußen. Ausgaben entstehen wie bei deinen Updates und \
                        spielen nur, wenn du sie antippst.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Design.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .macCard()
                if let feed = model.trendingFeed {
                    MacFeedCard(feed: feed, editions: model.editions[feed.id] ?? [])
                        .accessibilityIdentifier("topicUpdates.trendingFeed.row")
                }
            }
        }
    }
}

/// Ein Update als Karte: Cover, Titel, Tags und Zustand. Ein Klick öffnet
/// die Seite des Updates. Neue Aussagen stehen in der Akzentfarbe, ein
/// Update, an dem gerade gebaut wird, ebenso.
private struct MacFeedCard: View {

    let feed: SmartPodcastFeed
    let editions: [PersonalEpisode]
    @Environment(AppModel.self) private var model

    var body: some View {
        let building = model.buildingFeeds.contains(feed.id)
        let fresh = model.smartFeedStatistics[feed.id]?.total ?? 0
        NavigationLink(value: feed.id) {
            VStack(alignment: .leading, spacing: Design.Spacing.control) {
                HStack(alignment: .top, spacing: Design.Spacing.standard) {
                    SmartFeedRow(feed: feed, editions: editions, coverSize: 80)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Design.Spacing.small)
                        .accessibilityHidden(true)
                }
                if fresh > 0 {
                    Label(NewStatements.text(fresh), systemImage: "sparkle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(Design.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MacCardButtonStyle(accent: building))
        .accessibilityElement(children: .combine)
    }
}

/// „Neu seit dem letzten Hören“: je Tag die neuen Aussagen als Kapseln mit
/// Hover. Ein Klick öffnet die Seite des Tags.
struct MacTagCountChips: View {

    let counts: [TagStatementCount]
    let container: String
    let open: (InterestID) -> Void

    var body: some View {
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.small) {
            ForEach(counts) { entry in
                MacChip(action: { open(entry.tagID) }) {
                    HStack(spacing: Design.Spacing.small) {
                        Text(entry.label).fontWeight(.medium)
                        Text(entry.count, format: .number)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .accessibilityLabel(Text(TopicStatisticsHeader.spoken(entry)))
                .accessibilityHint("Öffnet die Seite des Tags")
                .accessibilityIdentifier("topicUpdates.stat.\(entry.label)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(container)
    }
}

/// „Angesagt“: die Tags, die gerade zulegen, als Kapseln mit Trendpfeil.
private struct MacTrendingChips: View {

    let entries: [TrendingTag]
    let open: (InterestID) -> Void

    var body: some View {
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.small) {
            ForEach(entries.prefix(10)) { entry in
                MacChip(action: { open(entry.tag.id) }) {
                    HStack(spacing: Design.Spacing.small) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(entry.tag.label).fontWeight(.medium)
                    }
                }
                .accessibilityLabel(Text(verbatim: entry.tag.label))
                .accessibilityHint("Öffnet die Seite des Tags")
                .accessibilityIdentifier("topicUpdates.trending.\(entry.tag.testKey)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Angesagt")
        .accessibilityIdentifier("topicUpdates.trending")
    }
}

/// Eine Kapsel als Knopf, mit Hover und Druck, in der Art von „Meine Tags“.
struct MacChip<Label: View>: View {

    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.callout)
                .padding(.horizontal, Design.Spacing.control + Design.Spacing.micro)
                .frame(minHeight: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(MacChipStyle())
    }
}

private struct MacChipStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary)
                .background {
                    Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.05))
                }
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Seite eines Updates

extension SmartFeedDetailView {

    var macContent: some View {
        MacPage {
            if let feed { macHeader(feed) }

            if !latestRun.isEmpty {
                MacSection(header: MacSectionHeader(
                    title: Text("Neueste Ausgabe"), count: nil,
                    note: latestRun.first.map { Text("Erstellt \(AppModel.editionMoment($0.publishedAt))") }
                )) {
                    editionGrid(latestRun)
                }
            } else if isBuilding {
                // Nicht „Noch keine Ausgabe“, solange eine entsteht: das
                // sähe fertig und leer aus.
                HStack(spacing: Design.Spacing.control) {
                    ProgressView().controlSize(.small)
                    Text("Die Ausgabe wird zusammengestellt …")
                }
                .padding(Design.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .macCard(accent: true)
            } else {
                ContentUnavailableView {
                    Label("Noch keine Ausgabe", systemImage: "waveform.circle")
                } description: {
                    if let feed { Text(model.editionHint(for: feed)) }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }

            if !isBuilding, !topicsWithoutHits.isEmpty { macTopicsWithoutHits }

            macNextEdition

            if !earlier.isEmpty {
                MacSection(header: MacSectionHeader(
                    title: Text("Frühere Ausgaben"), count: earlier.count
                )) {
                    editionGrid(earlier)
                }
            }
        }
        .yieldsAIWhileScrolling()
    }

    private func macHeader(_ feed: SmartPodcastFeed) -> some View {
        let counts = model.statementCounts(for: feed, statistics: model.smartFeedStatistics[feedID])
        return VStack(alignment: .leading, spacing: Design.Spacing.standard) {
            HStack(alignment: .top, spacing: Design.Spacing.large) {
                FeedCoverView(feed: feed, size: 148)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text(feed.title)
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.modeLine(for: feed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("smartFeed.mode")
                    if let total = model.smartFeedStatistics[feedID]?.total, total > 0 {
                        Label(NewStatements.text(total), systemImage: "sparkle")
                            .font(.callout.weight(.semibold))
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
                MacTagCountChips(counts: counts, container: "topicUpdates.header") { openedTag = $0 }
            }
        }
    }

    private func editionGrid(_ editions: [PersonalEpisode]) -> some View {
        LazyVGrid(columns: MacGrid.columns(minimum: 420), spacing: Design.Spacing.control) {
            ForEach(editions) { edition in
                MacEditionCard(edition: edition)
                    .contextMenu {
                        Button(role: .destructive) { model.removeEdition(edition) } label: {
                            Label("Ausgabe löschen", systemImage: "trash")
                        }
                    }
            }
        }
    }

    /// Ein Tag ohne Treffer sagt das und führt zu seiner Seite.
    private var macTopicsWithoutHits: some View {
        MacSection(header: MacSectionHeader(
            "Tags ohne Treffer",
            note: """
                Ein Tag findet Kapitel, die die App mit ihm eingeordnet hat. Folgen ohne Tags \
                durchsucht sie nach seinem Namen und seinen Schreibweisen, und nur Folgen mit Transkript.
                """
        )) {
            FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.small) {
                ForEach(topicsWithoutHits) { interest in
                    MacChip(action: { openedTag = interest.id }) {
                        Text("Zu \(interest.label) noch keine passende Stelle")
                    }
                }
            }
        }
    }

    /// Die nächste Ausgabe: was gilt, ein Knopf zum Zusammenstellen und das
    /// Ergebnis des letzten Versuchs als Satz. Spielt nichts ab.
    private var macNextEdition: some View {
        MacSection(header: MacSectionHeader("Nächste Ausgabe")) {
            VStack(alignment: .leading, spacing: Design.Spacing.control) {
                if let feed, !editions.isEmpty {
                    Text(model.editionHint(for: feed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Design.Spacing.control) {
                    Button(action: requestEdition) {
                        Label(isBuilding ? "Wird zusammengestellt …" : "Neue Ausgabe zusammenstellen",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.prominentAction)
                    .disabled(isBuilding || feed.map { model.isWaitingForTrends($0) } ?? true)
                    if isBuilding { ProgressView().controlSize(.small) }
                }
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
                if let feed {
                    Text(AppModel.editionRule(for: feed.publicationPolicy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macCard()
        }
    }
}

/// Eine Ausgabe als Karte: Cover, Titel, Datum, Länge und Umfang. Ein Klick
/// öffnet die Seite der Ausgabe, der Knopf rechts spielt sie ab. Läuft sie
/// gerade, trägt die Karte die Akzentfarbe und der Knopf hält an.
private struct MacEditionCard: View {

    let edition: PersonalEpisode
    @Environment(AppModel.self) private var model

    private var playback: EditionPlayback { EditionPlayback(episode: edition, model: model) }

    var body: some View {
        let current = playback.isCurrent
        NavigationLink {
            PersonalEpisodeView(episode: edition)
        } label: {
            HStack(alignment: .center, spacing: Design.Spacing.standard) {
                if let feed = model.smartFeeds.first(where: { $0.id == edition.feedID }) {
                    FeedCoverView(feed: feed, edition: edition, size: 72)
                }
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Text(edition.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if current {
                        Label("Läuft gerade", systemImage: "waveform")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else if heard {
                        Label("gehört", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // Platz für den Knopf, der über der Karte liegt.
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(Design.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MacCardButtonStyle(accent: current))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("edition.row")
        .accessibilityAction(named: playback.isRunning ? Text("Pause") : Text("Abspielen")) { playback.toggle() }
        .overlay(alignment: .trailing) {
            MacPlayButton(label: playback.isRunning ? "Pause" : current ? "Weiter" : "Abspielen",
                          symbol: playback.isRunning ? "pause.fill" : "play.fill",
                          size: 40) { playback.toggle() }
                .padding(.trailing, Design.Spacing.standard)
                .accessibilityHidden(true)
        }
    }

    private var heard: Bool {
        edition.heardFraction(in: model.ledger) >= AppModel.editionHeardThreshold
    }

    /// Datum, Länge, Umfang und neue Aussagen in einer Zeile.
    private var details: String {
        var parts = [edition.publishedAt.formatted(date: .abbreviated, time: .omitted),
                     edition.totalMediaDuration.shortDescription]
        let segments = edition.segments.count
        let sources = edition.distinctSourceCount
        parts.append(String(AttributedString(localized: "^[\(segments) Stelle](inflect: true)").characters))
        parts.append(String(AttributedString(localized: "^[\(sources) Quelle](inflect: true)").characters))
        if edition.newStatementCount > 0 { parts.append(NewStatements.text(edition.newStatementCount)) }
        return parts.joined(separator: " · ")
    }
}
#endif

//
//  CatalogViews.swift
//  PodcastAI
//
//  Die Ansichten des Podcast-Katalogs im Blatt „Podcast hinzufügen“:
//  Trefferzeile, Angesagt, Kategorien, Listen je Rubrik und die Seite eines
//  Podcasts vor dem Abonnieren.
//
//  Abgespielt wird hier nichts. Folgen stehen nur als Titel mit Datum und
//  Länge da, Abonnieren läuft über denselben Weg wie ein eingefügter Link.
//

import SwiftUI
import PodcastAIKit

/// Wohin ein Tipp im Katalog führt.
enum CatalogRoute: Hashable {
    case podcast(CatalogPodcast)
    case trending
    case category(CatalogCategory)
    /// Ein Podcast aus einem eingefügten Folgenlink.
    case linkPodcast(PodcastLinkPreview)
    /// Ein eingefügter YouTube-Link.
    case youTube(YouTubeLinkPreview)
}

/// Öffnet eine Seite des Katalogs im Stapel des Blatts. Als Typ und nicht
/// als nackter Block, damit die Umgebung ihn weitergeben kann.
struct CatalogNavigator: Sendable {
    let open: @MainActor @Sendable (CatalogRoute) -> Void

    @MainActor func callAsFunction(_ route: CatalogRoute) { open(route) }
}

extension EnvironmentValues {
    @Entry var catalogNavigate: CatalogNavigator? = nil
}

// MARK: - Abonnieren aus dem Katalog

/// Was im Blatt gerade abonniert wurde oder wird. Liegt beim Blatt, damit
/// Trefferliste, Rubriken und Detailseite denselben Stand zeigen und das
/// Blatt „Fertig“ anbietet, sobald irgendwo abonniert wurde.
@MainActor @Observable
final class CatalogSubscriptions {
    /// Frisch abonniert, mit der Zahl gefundener Folgen.
    var added: [URL: Int] = [:]
    var working: Set<URL> = []
    /// Der letzte Fehler beim Abonnieren, für „Nochmal versuchen“.
    var failure: (podcast: CatalogPodcast, message: String)?
    /// Einzeln geholte Folgen und Videos, je Feed und Folge.
    var singles: Set<String> = []
    var workingSingles: Set<String> = []
    /// Der letzte Fehler aus einer Vorschau zu einem Link.
    var linkFailure: String?

    /// Wurde in diesem Blatt etwas angelegt? Dann heißt der Knopf „Fertig“.
    var hasChanges: Bool { !added.isEmpty || !singles.isEmpty }

    func state(of podcast: CatalogPodcast, in model: AppModel) -> CatalogPodcastRow.State {
        if let count = added[podcast.feedURL] { return .added(count) }
        // Auch unter der alten Adresse oder der aus dem Apple-Verzeichnis
        // zählt ein Abo, und http oder ein Schrägstrich am Ende machen
        // keinen anderen Feed.
        let subscribed = subscribedFeedKeys(in: model)
        if podcast.knownFeedURLs.contains(where: { subscribed.contains(CatalogMerge.feedKey($0)) }) {
            return .subscribed
        }
        if working.contains(podcast.feedURL) { return .working }
        return .open
    }

    /// Die Schlüssel der abonnierten Feeds, neu berechnet nur, wenn sich die
    /// Abos ändern. Jede Zeile einer langen Liste fragt danach.
    @ObservationIgnored private var feedKeyMemo: (feeds: [URL], keys: Set<String>) = ([], [])

    private func subscribedFeedKeys(in model: AppModel) -> Set<String> {
        // Nur Abos. Aus einem Podcast mit einzeln geholten Folgen lässt sich
        // weiter abonnieren.
        let feeds = model.sources.filter(\.isSubscribed).compactMap(\.feedURL)
        if feeds != feedKeyMemo.feeds {
            feedKeyMemo = (feeds, Set(feeds.map(CatalogMerge.feedKey)))
        }
        return feedKeyMemo.keys
    }

    func failure(for podcast: CatalogPodcast) -> String? {
        guard let failure, failure.podcast.feedURL == podcast.feedURL else { return nil }
        return failure.message
    }

    func subscribe(_ podcast: CatalogPodcast, model: AppModel) async {
        guard !working.contains(podcast.feedURL) else { return }
        working.insert(podcast.feedURL)
        failure = nil
        defer { working.remove(podcast.feedURL) }
        do {
            let result = try await model.subscribe(to: podcast.feedURL.absoluteString)
            added[podcast.feedURL] = result.episodeCount
        } catch is CancellationError {
            return
        } catch {
            failure = (podcast, UserFacingError.describe(error))
        }
    }
}

// MARK: - Bausteine

/// Bild eines Podcasts, mit Mikrofon als Platzhalter, solange es lädt oder
/// wenn es fehlt. `AsyncImage` lädt über den gemeinsamen `URLCache`.
struct PodcastArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "mic")
                    .font(.system(size: max(12, size / 3)))
                    .foregroundStyle(.secondary)
            }
        }
        // Nach „Neu laden“ einer Quelle neu, auch unter derselben Adresse.
        .id(ArtworkRefresh.shared.revision(for: url))
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: size / 6))
        .accessibilityHidden(true)
    }
}

/// Das „E“ für Podcasts, die sich selbst als explizit kennzeichnen.
struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explizit")
    }
}

/// Woher die Daten des Katalogs kommen, mit Verweisen auf beide Dienste.
struct CatalogAttribution: View {
    var body: some View {
        Text("Charts und Verzeichnis: [Apple Podcasts](https://podcasts.apple.com). Die Suche fragt zusätzlich [Podcast Index](https://podcastindex.org).")
            .font(.footnote)
            .accessibilityIdentifier("catalog.attribution")
    }
}

/// Das Land der Charts. Es folgt der Region des Geräts, nicht der Sprache
/// der App; wer sich wundert, sieht hier, warum.
struct CatalogRegionNote: View {
    let country: String

    var body: some View {
        Text("Region der Charts: \(PodcastCatalog.regionName(country))")
            .font(.footnote)
            .accessibilityIdentifier("catalog.region")
    }
}

enum CatalogFormat {

    /// „Deutsch“ für „de-DE“, in der Sprache der App.
    static func languageName(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let code = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
            .languageCode?.identifier ?? identifier
        let locale = Locale(identifier: AppLanguage.current.rawValue)
        guard let name = locale.localizedString(forLanguageCode: code) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// „212 Folgen · neue Folge vor 3 Tagen“
    static func facts(for podcast: CatalogPodcast) -> String {
        var parts: [String] = []
        if let count = podcast.episodeCount, count > 0 {
            // Die Zahl mit passendem Wort, wie beim Abonnieren.
            parts.append(String(AttributedString(localized: "^[\(count) Folge](inflect: true)").characters))
        }
        if let date = podcast.newestEpisodeDate {
            let relative = date.formatted(.relative(presentation: .named))
            parts.append(String(localized: "neue Folge \(relative)"))
        }
        return parts.joined(separator: " · ")
    }

    /// „1 Std., 5 Min.“
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 60 else { return nil }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension CatalogCategory {
    var color: Color {
        switch tint {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

// MARK: - Trefferzeile

/// Ein Podcast in einer Liste: Bild, Titel, Anbieter, Zahl der Folgen,
/// neueste Folge, Sprache und Abo-Zustand.
struct CatalogPodcastRow: View {
    enum State: Equatable { case open, working, subscribed, added(Int) }

    let podcast: CatalogPodcast
    let state: State
    let subscribe: () -> Void
    /// Bild und Titel öffnen die Seite des Podcasts. Der Knopf „Abonnieren“
    /// bleibt für sich, damit ein Tipp daneben nicht aus Versehen abonniert.
    let preview: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 56

    private var byline: String {
        [podcast.author, podcast.categories.first?.title ?? podcast.genre].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    var body: some View {
        // Bei sehr großer Schrift steht der Knopf unter dem Text, statt ihn
        // auf wenige Buchstaben je Zeile zusammenzudrücken.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Spacing.small))
            : AnyLayout(HStackLayout(spacing: Design.Spacing.control))
        VStack(alignment: .leading, spacing: 2) {
            layout {
                Button(action: preview) {
                    HStack(alignment: .top, spacing: Design.Spacing.control) {
                        PodcastArtwork(url: podcast.artworkURL, size: min(artworkSize, 96))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(podcast.title).font(.body).lineLimit(3)
                            if !byline.isEmpty {
                                Text(byline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            facts
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Zeigt Beschreibung und neueste Folgen")
                .accessibilityIdentifier("catalog.row")
                control
            }
            // Außerhalb des Knopfs, damit es ein eigener Text bleibt.
            if case .added(let count) = state {
                Text("Abonniert · ^[\(count) Folge](inflect: true) gefunden")
                    .font(.caption).foregroundStyle(.green)
                    .padding(.leading, typeSize.isAccessibilitySize ? 0 : min(artworkSize, 96) + Design.Spacing.control)
            }
        }
    }

    @ViewBuilder private var facts: some View {
        let text = CatalogFormat.facts(for: podcast)
        if podcast.isExplicit || !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.micro) {
                if podcast.isExplicit { ExplicitBadge() }
                if !text.isEmpty { Text(text).lineLimit(3) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .open:
            Button("Abonnieren", action: subscribe)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("\(podcast.title) abonnieren")
        case .working:
            ProgressView()
        case .subscribed, .added:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Abonniert")
        }
    }
}

// MARK: - Angesagt

/// Die Charts von Apple Podcasts im Land des Geräts, als Reihe von Covern.
/// „Alle anzeigen“ öffnet die ganze Liste mit Abonnieren-Knöpfen.
struct CatalogTrendingSection: View {
    @Environment(\.catalogNavigate) private var navigate
    @State private var podcasts: [CatalogPodcast] = []
    @State private var country: String?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Section {
            if loading && podcasts.isEmpty {
                HStack { ProgressView(); Text("Angesagt wird geladen …").foregroundStyle(.secondary) }
            } else if let failure, podcasts.isEmpty {
                NoticeLabel(failure, kind: .failure)
                Button("Nochmal versuchen", systemImage: "arrow.clockwise") { Task { await load() } }
            } else if podcasts.isEmpty {
                Text("Gerade ist hier nichts angesagt.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Design.Spacing.control) {
                        ForEach(podcasts) { podcast in
                            Button { navigate?(.podcast(podcast)) } label: {
                                CatalogCoverCard(podcast: podcast)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("catalog.trending.card")
                        }
                    }
                    .padding(.vertical, Design.Spacing.micro)
                }
                .scrollIndicators(.hidden)
                Button { navigate?(.trending) } label: {
                    Label("Alle angesagten Podcasts", systemImage: "chart.line.uptrend.xyaxis")
                }
                .accessibilityIdentifier("catalog.trending.all")
            }
        } header: {
            // Geladen wird an der Überschrift, weil sie immer dasteht. An
            // der Section hinge die Aufgabe an jeder Zeile einzeln.
            Text("Angesagt")
                .task {
                    guard podcasts.isEmpty else { return }
                    await load()
                }
        } footer: {
            if let country, !podcasts.isEmpty {
                CatalogRegionNote(country: country)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let page = try await PodcastCatalog.shared.page(of: .top, offset: 0, count: 15)
            podcasts = page.podcasts
            country = page.country
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            podcasts = []
            failure = UserFacingError.describe(error)
        }
    }
}


/// Ein Cover mit Titel und Anbieter, für die Reihe „Angesagt“.
struct CatalogCoverCard: View {
    let podcast: CatalogPodcast
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            PodcastArtwork(url: podcast.artworkURL, size: width)
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.micro) {
                if podcast.isExplicit { ExplicitBadge().font(.caption) }
                Text(podcast.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !podcast.author.isEmpty {
                Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Zeigt Beschreibung und neueste Folgen")
    }
}

// MARK: - Kategorien

/// Die Rubriken als Kacheln mit Symbol und Farbe.
struct CatalogCategoryGrid: View {
    @Environment(\.catalogNavigate) private var navigate
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Bei sehr großer Schrift eine Kachel je Zeile, damit die Namen
        // nicht abgeschnitten werden.
        let minimum: CGFloat = typeSize.isAccessibilitySize ? 280 : 150
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Design.Spacing.small)],
                  spacing: Design.Spacing.small) {
            ForEach(CatalogCategory.allCases) { category in
                Button { navigate?(.category(category)) } label: {
                    CatalogCategoryTile(category: category)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Zeigt, was in dieser Kategorie angesagt ist")
                .accessibilityIdentifier("catalog.category.\(category.rawValue)")
            }
        }
        .padding(.vertical, Design.Spacing.micro)
    }
}

struct CatalogCategoryTile: View {
    let category: CatalogCategory

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            Image(systemName: category.symbol)
                .font(.title3)
                .foregroundStyle(category.color)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Design.Spacing.control)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(category.color.opacity(0.15), in: .rect(cornerRadius: Design.Radius.control))
        .contentShape(.rect)
    }
}

// MARK: - Liste je Rubrik

/// Die Charts, ganz oder einer Rubrik. Apple liefert sie auf einmal (100
/// Plätze, je Rubrik 200), „Mehr laden“ blättert darin und holt die
/// Einzelheiten der nächsten Seite.
struct CatalogListView: View {
    let category: CatalogCategory?

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions
    @Environment(\.catalogNavigate) private var navigate
    @State private var podcasts: [CatalogPodcast] = []
    /// Wo die nächste Seite beginnt. `nil` am Ende der Charts.
    @State private var nextOffset: Int? = 0
    @State private var country: String?
    @State private var loading = false
    @State private var failure: String?

    private static let pageSize = 25

    private var chart: CatalogChart { category.map(CatalogChart.genre) ?? .top }

    var body: some View {
        List {
            // Nur der Fehler zu einem Podcast aus dieser Liste, nicht der
            // aus einer anderen Rubrik oder der Suche.
            if let failed = subscriptions.failure, podcasts.contains(where: { $0.feedURL == failed.podcast.feedURL }) {
                Section {
                    NoticeLabel(String(localized: "„\(failed.podcast.title)“: \(failed.message)"), kind: .failure)
                    Button("Nochmal versuchen", systemImage: "arrow.clockwise") {
                        Task { await subscriptions.subscribe(failed.podcast, model: model) }
                    }
                }
            }
            if loading && podcasts.isEmpty {
                HStack { ProgressView(); Text("Angesagt wird geladen …").foregroundStyle(.secondary) }
            } else if let failure, podcasts.isEmpty {
                Section {
                    NoticeLabel(failure, kind: .failure)
                    Button("Nochmal versuchen", systemImage: "arrow.clockwise") { Task { await load() } }
                }
            } else if podcasts.isEmpty {
                ContentUnavailableView {
                    Label("Nichts angesagt", systemImage: category?.symbol ?? "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Gerade ist hier nichts angesagt.")
                }
            } else {
                Section {
                    ForEach(podcasts) { podcast in
                        CatalogPodcastRow(podcast: podcast,
                                          state: subscriptions.state(of: podcast, in: model),
                                          subscribe: { Task { await subscriptions.subscribe(podcast, model: model) } },
                                          preview: { navigate?(.podcast(podcast)) })
                    }
                    // „Mehr laden“ ist gescheitert, die bisherige Liste bleibt.
                    if let failure {
                        NoticeLabel(failure, kind: .failure)
                    }
                    if nextOffset != nil {
                        Button {
                            Task { await load() }
                        } label: {
                            HStack {
                                Label("Mehr laden", systemImage: "arrow.down.circle")
                                Spacer()
                                if loading { ProgressView() }
                            }
                        }
                        .disabled(loading)
                        .accessibilityIdentifier("catalog.loadMore")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        if let country { CatalogRegionNote(country: country) }
                        CatalogAttribution()
                    }
                }
            }
        }
        .navigationTitle(category?.title ?? String(localized: "Angesagt"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Zurück von der Seite eines Podcasts startet die Aufgabe neu.
            // Was „Mehr laden“ gebracht hat, bleibt dann stehen.
            guard podcasts.isEmpty else { return }
            await load()
        }
    }

    /// Die nächste Seite, beim ersten Mal die erste.
    private func load() async {
        guard let offset = nextOffset else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await PodcastCatalog.shared.page(of: chart, offset: offset, count: Self.pageSize)
            // Zwei Plätze können auf denselben Feed zeigen. Die Liste zählt
            // Podcasts, nicht Plätze.
            let known = Set(podcasts.flatMap { $0.knownFeedURLs.map(CatalogMerge.feedKey) })
            podcasts += page.podcasts.filter { !known.contains(CatalogMerge.feedKey($0.feedURL)) }
            nextOffset = page.nextOffset
            country = page.country
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = UserFacingError.describe(error)
        }
    }
}

// MARK: - Seite eines Podcasts

/// Ein Blick auf den Podcast vor dem Abonnieren: großes Bild, Rubriken,
/// Beschreibung, Website und die neuesten Folgen. Titel, Cover und
/// Rubriken kommen aus dem Katalog, Beschreibung und Folgen aus dem Feed.
struct CatalogPodcastDetailView: View {
    let podcast: CatalogPodcast

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions
    @State private var feed: PodcastPreview?
    @State private var loadFailure: String?
    @ScaledMetric(relativeTo: .title) private var artworkSize: CGFloat = 168

    /// Aus dem Feed, sonst was die Charts einer Rubrik mitbringen.
    private var summary: String? { feed.flatMap { ShownotesText.plain($0.summary) } ?? podcast.summary }

    private var tags: [String] {
        // In der Sprache der App wie die Kacheln der Kategorien. Apples
        // Namen folgen dem Land und bleiben für Rubriken ohne Kachel.
        let categories = podcast.categories.map(\.title)
        if !categories.isEmpty { return categories }
        if !podcast.genres.isEmpty { return podcast.genres }
        return [podcast.genre].compactMap { $0?.isEmpty == false ? $0 : nil }
    }

    var body: some View {
        List {
            Section {
                header
                subscribeControl
                if let failure = subscriptions.failure(for: podcast) {
                    NoticeLabel(failure, kind: .failure)
                }
            }

            facts

            Section("Beschreibung") {
                if let summary {
                    Text(summary).textSelection(.enabled)
                } else if feed != nil {
                    Text("Der Podcast hat keine Beschreibung.").foregroundStyle(.secondary)
                } else if loadFailure == nil {
                    HStack {
                        ProgressView()
                        Text("Beschreibung wird geladen …").foregroundStyle(.secondary)
                    }
                }
                if let loadFailure {
                    NoticeLabel(loadFailure, kind: .failure)
                    Button("Nochmal versuchen", systemImage: "arrow.clockwise") {
                        self.loadFailure = nil
                        Task { await load() }
                    }
                }
            }

            if let feed, !feed.latest.isEmpty {
                Section {
                    // „Nur diese Folge“ neben jeder Folge, solange der
                    // Podcast nicht abonniert ist.
                    ForEach(feed.latest) { episode in
                        PreviewEpisodeRow(episode: episode, preview: feed,
                                          offersSingle: subscriptions.state(of: podcast, in: model) == .open)
                    }
                    if let failure = subscriptions.linkFailure {
                        NoticeLabel(failure, kind: .failure)
                    }
                } header: {
                    Text("Neueste Folgen")
                } footer: {
                    CatalogAttribution()
                }
            } else {
                Section {} footer: { CatalogAttribution() }
            }
        }
        .navigationTitle(podcast.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // Ein Fehler beim Holen gehört zu dieser Seite, nicht zur nächsten.
        .onDisappear { subscriptions.linkFailure = nil }
    }

    private var header: some View {
        VStack(spacing: Design.Spacing.small) {
            PodcastArtwork(url: podcast.artworkURL, size: min(artworkSize, 280))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text(podcast.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !podcast.author.isEmpty {
                Text(podcast.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !tags.isEmpty || podcast.isExplicit {
                FlowLayout(spacing: Design.Spacing.micro, lineSpacing: Design.Spacing.micro) {
                    if podcast.isExplicit {
                        Label("Explizit", systemImage: "e.square.fill")
                            .font(.caption)
                            .padding(.horizontal, Design.Spacing.small)
                            .padding(.vertical, Design.Spacing.micro)
                            .background(.quaternary, in: .capsule)
                    }
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, Design.Spacing.small)
                            .padding(.vertical, Design.Spacing.micro)
                            .background(.tint.opacity(0.12), in: .capsule)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var facts: some View {
        let count = podcast.episodeCount ?? feed?.episodeCount
        let newest = podcast.newestEpisodeDate ?? feed?.latestDate
        let language = CatalogFormat.languageName(feed?.language)
        let website = feed?.websiteURL
        if count != nil || newest != nil || language != nil || website != nil {
            Section {
                if let count {
                    LabeledContent("Folgen") { Text(count, format: .number) }
                }
                if let newest {
                    LabeledContent("Neueste Folge") { Text(newest, style: .date) }
                }
                if let language {
                    LabeledContent("Sprache") { Text(verbatim: language) }
                }
                if let website {
                    Link(destination: website) {
                        Label("Website", systemImage: "safari")
                    }
                }
            }
        }
    }

    @ViewBuilder private var subscribeControl: some View {
        let failed = subscriptions.failure(for: podcast) != nil
        switch subscriptions.state(of: podcast, in: model) {
        case .added(let count):
            Label {
                Text("Abonniert · ^[\(count) Folge](inflect: true) gefunden")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .subscribed:
            Label("Schon abonniert", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .open, .working:
            let working = subscriptions.state(of: podcast, in: model) == .working
            Button {
                Task { await subscriptions.subscribe(podcast, model: model) }
            } label: {
                HStack {
                    if failed {
                        Label("Nochmal versuchen", systemImage: "arrow.clockwise")
                    } else {
                        Label("Abonnieren", systemImage: "plus.circle.fill")
                    }
                    Spacer()
                    if working { ProgressView() }
                }
            }
            .disabled(working)
            .accessibilityIdentifier("source.preview.subscribe")
        }
    }

    /// Beschreibung, Website und neueste Folgen aus dem Feed. Abgespielt
    /// wird davon nichts.
    private func load() async {
        guard feed == nil else { return }
        do {
            feed = try await PodcastCatalog.shared.preview(of: podcast.feedURL, model: model)
            loadFailure = nil
        } catch is CancellationError {
            return
        } catch {
            loadFailure = UserFacingError.describe(error)
        }
    }
}

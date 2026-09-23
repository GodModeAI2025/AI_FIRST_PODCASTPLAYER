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
    private(set) var added: [URL: Int] = [:]
    private(set) var working: Set<URL> = []
    /// Der letzte Fehler beim Abonnieren, für „Nochmal versuchen“.
    var failure: (podcast: CatalogPodcast, message: String)?

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
        let feeds = model.sources.compactMap(\.feedURL)
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

/// „Katalog: Podcast Index“ mit Verweis auf die Quelle der Daten.
struct CatalogAttribution: View {
    var body: some View {
        Link(destination: PodcastCatalog.website) {
            Text("Katalog: Podcast Index")
        }
        .font(.footnote)
        .accessibilityIdentifier("catalog.attribution")
    }
}

/// Angesagt in der Sprache der App oder in allen Sprachen.
struct CatalogLanguagePicker: View {
    @Binding var allLanguages: Bool

    var body: some View {
        Picker("Sprache", selection: $allLanguages) {
            Text(verbatim: CatalogFormat.languageName(AppLanguage.current.rawValue) ?? AppLanguage.current.rawValue)
                .tag(false)
            Text("Alle Sprachen").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("catalog.language")
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

    /// „212 Folgen · neue Folge vor 3 Tagen · Deutsch“
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
        if let language = languageName(podcast.language) { parts.append(language) }
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
        [podcast.author, podcast.genre].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
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

/// Was gerade viel gehört wird, als Reihe von Covern. „Alle anzeigen“
/// öffnet die ganze Liste mit Abonnieren-Knöpfen.
struct CatalogTrendingSection: View {
    @Environment(\.catalogNavigate) private var navigate
    @AppStorage("catalog.allLanguages") private var allLanguages = false
    @State private var podcasts: [CatalogPodcast] = []
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Section {
            // Geladen wird an dieser Zeile, weil sie immer dasteht. An der
            // Section hinge die Aufgabe an jeder Zeile einzeln.
            CatalogLanguagePicker(allLanguages: $allLanguages)
                .task(id: allLanguages) { await load() }
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
                        ForEach(podcasts.prefix(15)) { podcast in
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
            Text("Angesagt")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            podcasts = try await PodcastCatalog.shared.trending(language: allLanguages ? nil : .current, max: 30)
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

/// Angesagt, ganz oder in einer Rubrik. Die API kennt kein Blättern,
/// „Mehr laden“ fragt nach einer längeren Liste.
struct CatalogListView: View {
    let category: CatalogCategory?

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions
    @Environment(\.catalogNavigate) private var navigate
    @AppStorage("catalog.allLanguages") private var allLanguages = false
    @State private var podcasts: [CatalogPodcast] = []
    @State private var limit = Self.pageSize
    @State private var loading = false
    @State private var failure: String?
    @State private var exhausted = false
    /// Für welche Sprachwahl die Liste steht. Zurück von der Seite eines
    /// Podcasts startet die Aufgabe neu; was „Mehr laden“ gebracht hat,
    /// bleibt dann stehen.
    @State private var loadedLanguage: Bool?

    private static let pageSize = 40
    private static let maximum = 200

    var body: some View {
        List {
            Section {
                CatalogLanguagePicker(allLanguages: $allLanguages)
            }
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
                    if allLanguages {
                        Text("Gerade ist hier nichts angesagt.")
                    } else {
                        Text("In dieser Sprache ist hier gerade nichts angesagt.")
                    }
                } actions: {
                    if !allLanguages {
                        Button("Alle Sprachen zeigen") { allLanguages = true }
                    }
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
                    if !exhausted {
                        Button {
                            Task { await loadMore() }
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
                    CatalogAttribution()
                }
            }
        }
        .navigationTitle(category?.title ?? String(localized: "Angesagt"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: allLanguages) {
            guard loadedLanguage != allLanguages || podcasts.isEmpty else { return }
            limit = Self.pageSize
            await load()
        }
    }

    private func load(previousCount: Int? = nil) async {
        loading = true
        defer { loading = false }
        do {
            let found = try await PodcastCatalog.shared.trending(language: allLanguages ? nil : .current,
                                                                  category: category, max: limit)
            podcasts = found
            loadedLanguage = allLanguages
            failure = nil
            // Ohne Blättern sieht man das Ende nur daran, dass nichts dazukommt.
            if let previousCount {
                exhausted = found.count <= previousCount || limit >= Self.maximum
            } else {
                exhausted = found.count < limit / 2
            }
        } catch is CancellationError {
            return
        } catch {
            failure = UserFacingError.describe(error)
        }
    }

    private func loadMore() async {
        let before = podcasts.count
        limit = min(limit + Self.pageSize, Self.maximum)
        await load(previousCount: before)
    }
}

// MARK: - Seite eines Podcasts

/// Ein Blick auf den Podcast vor dem Abonnieren: großes Bild, Rubriken,
/// Beschreibung, Website und die neuesten Folgen. Kennt der Katalog den
/// Podcast, kommen die Angaben von dort, sonst aus dem Feed selbst.
struct CatalogPodcastDetailView: View {
    let podcast: CatalogPodcast

    @Environment(AppModel.self) private var model
    @Environment(CatalogSubscriptions.self) private var subscriptions
    @State private var details: CatalogPodcast?
    @State private var feed: PodcastPreview?
    @State private var episodes: [Episode]?
    @State private var summary: String?
    @State private var loadFailure: String?
    @State private var loaded = false
    @State private var fromCatalog = false
    @ScaledMetric(relativeTo: .title) private var artworkSize: CGFloat = 168

    /// Eine Folge zum Ansehen, egal ob aus dem Katalog oder aus dem Feed.
    struct Episode: Identifiable {
        let id: String
        let title: String
        let publishedAt: Date?
        let duration: Int?
        let isExplicit: Bool
    }

    private var shown: CatalogPodcast { details ?? podcast }
    private var tags: [String] {
        let categories = shown.categories.map(\.title)
        if !categories.isEmpty { return categories }
        return [shown.genre].compactMap { $0?.isEmpty == false ? $0 : nil }
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
                } else if loaded {
                    Text("Der Podcast hat keine Beschreibung.").foregroundStyle(.secondary)
                } else if let loadFailure {
                    NoticeLabel(loadFailure, kind: .failure)
                    Button("Nochmal versuchen", systemImage: "arrow.clockwise") {
                        self.loadFailure = nil
                        Task { await load() }
                    }
                } else {
                    HStack {
                        ProgressView()
                        Text("Beschreibung wird geladen …").foregroundStyle(.secondary)
                    }
                }
            }

            if let episodes, !episodes.isEmpty {
                Section {
                    ForEach(episodes) { episode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.title).lineLimit(3)
                            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.micro) {
                                if episode.isExplicit { ExplicitBadge() }
                                Text(episodeLine(episode))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Neueste Folgen")
                } footer: {
                    if fromCatalog { CatalogAttribution() }
                }
            } else if fromCatalog {
                Section {} footer: { CatalogAttribution() }
            }
        }
        .navigationTitle(shown.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Design.Spacing.small) {
            PodcastArtwork(url: shown.artworkURL, size: min(artworkSize, 280))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text(shown.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !shown.author.isEmpty {
                Text(shown.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !tags.isEmpty || shown.isExplicit {
                FlowLayout(spacing: Design.Spacing.micro, lineSpacing: Design.Spacing.micro) {
                    if shown.isExplicit {
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
        let count = shown.episodeCount ?? feed?.episodeCount
        let newest = shown.newestEpisodeDate ?? feed?.latestDate ?? episodes?.first?.publishedAt
        let language = CatalogFormat.languageName(shown.language ?? feed?.language)
        let website = shown.websiteURL ?? feed?.websiteURL
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

    private func episodeLine(_ episode: Episode) -> String {
        [episode.publishedAt.map { $0.formatted(date: .abbreviated, time: .omitted) },
         CatalogFormat.duration(episode.duration)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func load() async {
        guard !loaded else { return }
        let catalog = PodcastCatalog.shared
        if catalog.isAvailable, let id = podcast.podcastIndexID {
            do {
                let found = try await catalog.episodes(feedID: id)
                // Die Einzelheiten ergänzen, was die Trefferliste nicht
                // mitbringt: Beschreibung in voller Länge, Website, Zahl der Folgen.
                if let detail = try? await catalog.podcast(id: id) {
                    details = CatalogMerge.merged([detail], [podcast]).first
                }
                episodes = found.map {
                    Episode(id: "c\($0.id)", title: $0.title, publishedAt: $0.publishedAt,
                            duration: $0.duration, isExplicit: $0.isExplicit)
                }
                summary = shown.summary
                fromCatalog = true
                loaded = true
                return
            } catch is CancellationError {
                return
            } catch {
                // Weiter mit dem Feed selbst.
            }
        }
        do {
            let preview = try await model.previewPodcast(podcast.feedURL)
            feed = preview
            summary = ShownotesText.plain(preview.summary) ?? podcast.summary
            episodes = preview.latest.map {
                Episode(id: "f\($0.id)", title: $0.title, publishedAt: $0.publishedAt,
                        duration: $0.duration, isExplicit: false)
            }
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            loadFailure = UserFacingError.describe(error)
        }
    }
}

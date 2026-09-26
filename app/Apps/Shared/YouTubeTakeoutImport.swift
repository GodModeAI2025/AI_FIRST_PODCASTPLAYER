//
//  YouTubeTakeoutImport.swift
//  PodcastAI
//
//  YouTube-Abos aus Google Takeout übernehmen. Die CSV-Datei wird auf dem
//  Gerät gelesen, dann sucht die App zu jedem Kanal einen passenden
//  Audio-Podcast in Apples Verzeichnis und empfiehlt ihn, denn nur mit Ton
//  gibt es Transkript, Fakten und Tags. Wer auswählt, bestimmt je Kanal, ob
//  der Audio-Podcast oder der YouTube-Kanal abonniert wird.
//
//  Abonniert wird wie bei einer OPML-Liste über `importSubscription(from:)`:
//  nur die Folgenlisten, ausgewertet wird dabei nichts, abgespielt auch
//  nicht. Die Namen der Kanäle sind fremde Daten; sie gehen als Suchbegriff
//  an Apple und sonst nirgends hin, auch an kein Sprachmodell.
//

import SwiftUI
import UniformTypeIdentifiers
import PodcastAIKit

// MARK: - Datei

enum TakeoutFile {

    /// `subscriptions.csv`. Manche Dateianbieter melden eine CSV-Datei nur
    /// als Text; `.commaSeparatedText` gehört nicht zu `.plainText`.
    static var contentTypes: [UTType] { [.commaSeparatedText, .delimitedText, .plainText] }

    /// Liest die Kanäle aus der Datei, außerhalb des Hauptthreads.
    static func channels(in url: URL) async throws -> [TakeoutChannel] {
        let data = try await ImportedFile.read(url, maximumBytes: YouTubeTakeout.maximumBytes,
                                               tooLarge: TakeoutImportError.tooLarge,
                                               unreadable: TakeoutImportError.notTakeout)
        return try await Task.detached(priority: .userInitiated) {
            try YouTubeTakeout.channels(in: data)
        }.value
    }
}

/// Eine gelesene Abo-Liste von YouTube, bereit zum Abhaken.
struct TakeoutImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let channels: [TakeoutChannel]
}

extension View {
    /// Dateiauswahl für `subscriptions.csv` und danach die Liste zum Abonnieren.
    ///
    /// Gehört an eine andere Ansicht als `opmlImport`: Zwei `fileImporter`
    /// an derselben Ansicht vertragen sich in SwiftUI nicht zuverlässig.
    func takeoutImport(isPresented: Binding<Bool>) -> some View {
        modifier(TakeoutImportModifier(isPresented: isPresented))
    }
}

private struct TakeoutImportModifier: ViewModifier {

    @Binding var isPresented: Bool

    @Environment(AppModel.self) private var model
    @State private var request: TakeoutImportRequest?
    @State private var readError: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: pickerPresented, allowedContentTypes: TakeoutFile.contentTypes) { result in
                switch result {
                case .success(let url):
                    Task { await open(url) }
                case .failure(let error):
                    readError = error.localizedDescription
                }
            }
            .sheet(item: $request) { request in
                TakeoutImportSheet(request: request)
                    .sheetFeedback()
                    .environment(model)
            }
            .alert("Datei lässt sich nicht einlesen", isPresented: Binding(
                get: { readError != nil }, set: { if !$0 { readError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(readError ?? "")
            }
            #if DEBUG
            .onChange(of: isPresented) { _, open in
                guard open, TakeoutFixture.isActive else { return }
                isPresented = false
                request = TakeoutFixture.request
            }
            #endif
    }

    /// In UI-Tests mit fester Liste öffnet sich keine Dateiauswahl.
    private var pickerPresented: Binding<Bool> {
        #if DEBUG
        if TakeoutFixture.isActive { return .constant(false) }
        #endif
        return $isPresented
    }

    private func open(_ url: URL) async {
        do {
            let channels = try await TakeoutFile.channels(in: url)
            request = TakeoutImportRequest(fileName: url.lastPathComponent, channels: channels)
        } catch {
            readError = UserFacingError.describe(error)
        }
    }
}

// MARK: - Suche und Abonnieren

/// Führt die Liste: sucht nacheinander Audio-Podcasts und abonniert danach
/// die Auswahl. Lebt so lange wie das Blatt.
@MainActor @Observable
final class TakeoutImportRun {

    enum Phase { case choosing, subscribing, finished }

    /// Warum die Suche vor dem Ende aufgehört hat.
    enum LookupStop: Equatable { case rateLimited, offline }

    enum Status: Equatable, Sendable {
        case waiting
        case running
        case added(Int)
        case failed(String)
        case skipped
    }

    /// Mehrere Feeds zugleich, aber nicht alle, wie beim OPML-Import.
    private static let parallelImports = 3
    /// So oft hintereinander „zu viele Anfragen“ oder kein Netz, dann ruht die Suche.
    private static let strikesBeforeStop = 3

    private(set) var selection: TakeoutImportSelection
    private(set) var phase: Phase = .choosing
    private(set) var lookupStop: LookupStop?
    /// Stand je Abo, Schlüssel ist `Subscription.id`.
    private(set) var statuses: [String: Status] = [:]
    /// Welches Abo zu welchem Kanal gehört.
    private(set) var subscriptionByChannel: [String: String] = [:]
    /// Die Abos, die „Abonnieren“ angelegt hat oder anlegen will.
    private(set) var planned: [String: TakeoutImportSelection.Subscription] = [:]

    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = 0
    private var subscribeTask: Task<Void, Never>?

    init(channels: [TakeoutChannel]) {
        selection = TakeoutImportSelection(channels: channels, subscribedFeeds: [URL]())
    }

    var isSearching: Bool { lookupTask != nil }

    /// Kanäle, für die die Suche scheiterte oder beendet wurde.
    var unfinishedLookupCount: Int {
        selection.lookups.values.filter { $0 == .failed || $0 == .skipped }.count
    }

    func status(ofChannel id: String) -> Status? {
        subscriptionByChannel[id].flatMap { statuses[$0] }
    }

    func subscription(ofChannel id: String) -> TakeoutImportSelection.Subscription? {
        subscriptionByChannel[id].flatMap { planned[$0] }
    }

    func updateSubscribedFeeds(from model: AppModel) {
        selection.updateSubscribedFeeds(Self.subscribedFeeds(model))
    }

    // MARK: Auswahl

    func toggle(_ id: String) { selection.toggle(id) }
    func choose(_ target: TakeoutImportSelection.Target, for id: String) { selection.choose(target, for: id) }
    func selectRecommended() { selection.selectRecommended() }
    func selectAll() { selection.selectAll() }
    func deselectAll() { selection.deselectAll() }

    // MARK: Suche

    func startLookups() {
        guard lookupTask == nil, phase == .choosing, !selection.pendingIDs.isEmpty else { return }
        lookupStop = nil
        lookupGeneration += 1
        let generation = lookupGeneration
        lookupTask = Task { [weak self] in
            await self?.runLookups()
            guard let self, self.lookupGeneration == generation else { return }
            self.lookupTask = nil
        }
    }

    /// „Suche beenden“: Was noch wartet, bleibt ohne Audio-Podcast und
    /// lässt sich als YouTube-Kanal abonnieren.
    func stopLookups() {
        lookupTask?.cancel()
        lookupTask = nil
        selection.skipRemainingLookups()
    }

    func retryLookups() {
        guard lookupTask == nil else { return }
        selection.retryUnfinishedLookups()
        startLookups()
    }

    /// Eine Suche nach der anderen, im Tempo, das Apple verträgt. Meldet
    /// Apple „zu viele Anfragen“, wartet die Suche und fragt für denselben
    /// Kanal noch einmal.
    private func runLookups() async {
        var pace = DirectorySearchPace()
        var rateLimitStrikes = 0
        var offlineStrikes = 0
        channels: for channel in selection.channels {
            guard selection.lookups[channel.id] == .pending else { continue }
            guard ChannelCounterpartRanking.isSearchable(channel.title) else {
                selection.recordResults([], for: channel.id)
                continue
            }
            while true {
                if Task.isCancelled { break channels }
                let delay = pace.delay(before: .now)
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break channels }
                }
                do {
                    let results = try await PodcastCatalog.shared.searchApple(channel.title)
                    if Task.isCancelled { break channels }
                    selection.recordResults(results, for: channel.id)
                    rateLimitStrikes = 0
                    offlineStrikes = 0
                    continue channels
                } catch CatalogError.rateLimited {
                    // Eine beendete Suche darf eine neue nicht anhalten.
                    if Task.isCancelled { break channels }
                    rateLimitStrikes += 1
                    pace.noteRateLimited(at: .now)
                    if rateLimitStrikes >= Self.strikesBeforeStop {
                        lookupStop = .rateLimited
                        break channels
                    }
                } catch CatalogError.unreachable {
                    if Task.isCancelled { break channels }
                    offlineStrikes += 1
                    selection.recordFailure(for: channel.id)
                    if offlineStrikes >= Self.strikesBeforeStop {
                        lookupStop = .offline
                        break channels
                    }
                    continue channels
                } catch {
                    if Task.isCancelled || error is CancellationError { break channels }
                    selection.recordFailure(for: channel.id)
                    continue channels
                }
            }
        }
        if lookupStop != nil, !Task.isCancelled { selection.skipRemainingLookups() }
    }

    // MARK: Abonnieren

    var plannedCount: Int { selection.subscriptions.count }

    func subscribe(using model: AppModel) {
        let plan = selection.subscriptions
        guard phase == .choosing, !isSearching, !plan.isEmpty else { return }
        subscriptionByChannel = [:]
        for subscription in plan {
            statuses[subscription.id] = .waiting
            planned[subscription.id] = subscription
            for channelID in subscription.channelIDs { subscriptionByChannel[channelID] = subscription.id }
        }
        phase = .subscribing
        subscribeTask = Task { [weak self] in
            await self?.run(plan, model: model)
            guard let self else { return }
            self.selection.updateSubscribedFeeds(Self.subscribedFeeds(model))
            self.phase = .finished
            self.subscribeTask = nil
        }
    }

    func stopSubscribing() {
        subscribeTask?.cancel()
    }

    /// Das Blatt geht zu: Suche und Abonnieren enden.
    func cancelAll() {
        lookupTask?.cancel()
        lookupTask = nil
        subscribeTask?.cancel()
    }

    private func run(_ plan: [TakeoutImportSelection.Subscription], model: AppModel) async {
        var pending = plan[...]
        await withTaskGroup(of: (String, Status).self) { group in
            for _ in 0..<Self.parallelImports {
                guard let next = pending.popFirst() else { break }
                statuses[next.id] = .running
                group.addTask { await Self.subscribe(next, model: model) }
            }
            while let (id, result) = await group.next() {
                statuses[id] = result
                guard !Task.isCancelled, let next = pending.popFirst() else { continue }
                statuses[next.id] = .running
                group.addTask { await Self.subscribe(next, model: model) }
            }
        }
        // Nach dem Stoppen: was noch wartete, bleibt ohne Abo.
        for subscription in pending { statuses[subscription.id] = .skipped }
    }

    private nonisolated static func subscribe(
        _ subscription: TakeoutImportSelection.Subscription, model: AppModel
    ) async -> (String, Status) {
        do {
            let added = try await model.importSubscription(from: subscription.feedURL.absoluteString)
            return (subscription.id, .added(added.episodeCount))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return (subscription.id, .skipped)
            }
            return (subscription.id, .failed(ImportedFile.failureReason(error)))
        }
    }

    private static func subscribedFeeds(_ model: AppModel) -> [URL] {
        model.sources.filter(\.isSubscribed).compactMap(\.feedURL)
    }

    // MARK: Zählen

    var addedCount: Int { statuses.values.filter { if case .added = $0 { true } else { false } }.count }
    var failedCount: Int { statuses.values.filter { if case .failed = $0 { true } else { false } }.count }
    var skippedCount: Int { statuses.values.filter { $0 == .skipped }.count }
    var doneCount: Int { addedCount + failedCount + skippedCount }
    var total: Int { statuses.count }
}

// MARK: - Liste zum Abhaken

struct TakeoutImportSheet: View {

    let request: TakeoutImportRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var run: TakeoutImportRun
    @State private var prepared = false

    init(request: TakeoutImportRequest) {
        self.request = request
        _run = State(initialValue: TakeoutImportRun(channels: request.channels))
    }

    private var selection: TakeoutImportSelection { run.selection }

    var body: some View {
        NavigationStack {
            List {
                Section { overview }

                Section {
                    ForEach(request.channels) { channel in
                        TakeoutChannelRow(channel: channel, run: run)
                    }
                } header: {
                    HStack {
                        Text("^[\(request.channels.count) Kanal](inflect: true) in „\(request.fileName)“")
                        Spacer()
                        if run.phase == .choosing, !selection.selectableIDs.isEmpty {
                            selectionMenu
                        }
                    }
                } footer: {
                    if run.phase == .choosing {
                        VStack(alignment: .leading, spacing: Design.Spacing.small) {
                            Text("Empfohlen ist der Audio-Podcast: Nur mit Ton gibt es Transkript, Fakten und Tags. Von YouTube bekommt die App keinen Ton.")
                            Text("Die Namen der Kanäle gehen an die Podcast-Suche von Apple, einer nach dem anderen. Bei vielen Kanälen dauert das einige Minuten, weil Apple zu schnelle Suchen bremst. Abonnieren holt nur die Folgenlisten.")
                        }
                    }
                }
            }
            .navigationTitle("YouTube-Abos importieren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(run.phase == .subscribing)
        .task {
            guard !prepared else { return }
            prepared = true
            run.updateSubscribedFeeds(from: model)
            run.startLookups()
        }
        .onDisappear { run.cancelAll() }
    }

    // MARK: Kopf

    @ViewBuilder
    private var overview: some View {
        switch run.phase {
        case .choosing:
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                if run.isSearching {
                    ProgressView(value: Double(selection.lookupDoneCount), total: Double(max(selection.channels.count, 1)))
                    Text("Suche Audio-Podcasts bei Apple: \(selection.lookupDoneCount) von \(selection.channels.count)")
                        .font(.callout)
                        .accessibilityIdentifier("takeout.searchProgress")
                    Button("Suche beenden") { run.stopLookups() }
                        .accessibilityIdentifier("takeout.stopSearch")
                } else {
                    Text("Audio-Podcast gefunden: \(selection.recommendedIDs.count) von \(selection.channels.count)")
                        .font(.callout)
                        .accessibilityIdentifier("takeout.searchSummary")
                    switch run.lookupStop {
                    case .rateLimited:
                        NoticeLabel("Apple bremst die Suche gerade. Versuch es für die übrigen Kanäle in ein paar Minuten noch einmal.", kind: .failure)
                    case .offline:
                        NoticeLabel("Keine Verbindung zur Podcast-Suche von Apple. Prüf die Internetverbindung.", kind: .failure)
                    case nil:
                        EmptyView()
                    }
                    if run.unfinishedLookupCount > 0 {
                        Button("Noch einmal suchen (\(run.unfinishedLookupCount))") { run.retryLookups() }
                            .accessibilityIdentifier("takeout.retrySearch")
                    }
                }
            }
            .padding(.vertical, Design.Spacing.micro)
        case .subscribing, .finished:
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                ProgressView(value: Double(run.doneCount), total: Double(max(run.total, 1)))
                Text(summary)
                    .font(.callout)
                    .accessibilityIdentifier("takeout.summary")
            }
            .padding(.vertical, Design.Spacing.micro)
        }
    }

    private var selectionMenu: some View {
        Menu {
            Button("Alle mit Audio-Podcast") { run.selectRecommended() }
                .disabled(selection.recommendedIDs.isEmpty)
            Button("Alle auswählen") { run.selectAll() }
            Button("Alle abwählen") { run.deselectAll() }
        } label: {
            Text("Auswählen")
        }
        .font(.caption)
        .accessibilityIdentifier("takeout.selectionMenu")
    }

    private var summary: String {
        if run.phase == .subscribing {
            return String(localized: "\(run.doneCount) von \(run.total) erledigt")
        }
        var parts = [String(AttributedString(localized: "^[\(run.addedCount) Abo](inflect: true) angelegt").characters)]
        if run.failedCount > 0 {
            parts.append(run.failedCount == 1 ? String(localized: "1 ging nicht")
                         : String(localized: "\(run.failedCount) gingen nicht"))
        }
        if run.skippedCount > 0 {
            parts.append(String(localized: "\(run.skippedCount) nach dem Stoppen ausgelassen"))
        }
        let text = parts.formatted(.list(type: .and, width: .narrow))
        return run.failedCount > 0
            ? String(localized: "\(text). Den Grund siehst du beim jeweiligen Kanal.")
            : String(localized: "\(text).")
    }

    // MARK: Leiste

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch run.phase {
        case .choosing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                let count = run.plannedCount
                Button(count == 1 ? "1 abonnieren" : "\(count) abonnieren") { run.subscribe(using: model) }
                    .disabled(count == 0 || run.isSearching)
                    .accessibilityIdentifier("takeout.subscribe")
            }
        case .subscribing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Stoppen") { run.stopSubscribing() }
            }
        case .finished:
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
    }
}

// MARK: - Zeile

/// Ein Kanal mit Haken, dem Stand der Suche und, wenn es mehr als eine
/// Möglichkeit gibt, der Wahl zwischen Audio-Podcast und Kanal.
private struct TakeoutChannelRow: View {

    let channel: TakeoutChannel
    let run: TakeoutImportRun

    private var selection: TakeoutImportSelection { run.selection }
    private var id: String { channel.id }
    private var choosing: Bool { run.phase == .choosing }
    private var selectable: Bool { selection.isSelectable(id) }
    private var isSelected: Bool { selection.selected.contains(id) }

    var body: some View {
        HStack(spacing: Design.Spacing.control) {
            if choosing && selectable {
                Button { run.toggle(id) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                content.accessibilityElement(children: .combine)
            }
            if choosing, selectable, selection.availableTargets(for: id).count > 1 {
                targetMenu
            }
            statusSymbol
        }
    }

    private var content: some View {
        HStack(spacing: Design.Spacing.control) {
            if choosing {
                Image(systemName: isSelected || !selectable ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected && selectable ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayTitle)
                    .foregroundStyle(choosing && !selectable ? .secondary : .primary)
                    .lineLimit(2)
                if choosing {
                    lookupLine
                        .font(.caption)
                        .lineLimit(2)
                } else if let subscription = run.subscription(ofChannel: id) {
                    Group {
                        if subscription.isAudioPodcast {
                            Text("Audio-Podcast: \(subscription.title)")
                        } else {
                            Text("YouTube-Kanal")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                statusLine
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    /// Was die Suche ergeben hat und was abonniert würde.
    @ViewBuilder
    private var lookupLine: some View {
        switch selection.lookups[id] {
        case .pending where run.isSearching:
            Text("Sucht Audio-Podcast …").foregroundStyle(.secondary)
        case .found where selectable:
            if case .audioPodcast(let feed) = selection.target(for: id),
               let podcast = selection.openCandidates(for: id).first(where: { $0.feedURL == feed }) {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Audio-Podcast verfügbar", systemImage: "waveform")
                        .foregroundStyle(.tint)
                    Text([podcast.title, podcast.author].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            } else if selection.hasRecommendation(id) {
                Label("Audio-Podcast verfügbar, abonniert wird der Kanal", systemImage: "play.rectangle")
                    .foregroundStyle(.secondary)
            } else {
                Text("Audio-Podcast schon abonniert").foregroundStyle(.secondary)
            }
        case _ where !selectable:
            Text("Schon abonniert").foregroundStyle(.secondary)
        case .nothing:
            Text("Kein Audio-Podcast gefunden, nur der YouTube-Kanal").foregroundStyle(.secondary)
        case .failed:
            Text("Suche ging nicht, nur der YouTube-Kanal").foregroundStyle(.secondary)
        case .pending, .skipped:
            Text("Nicht gesucht, nur der YouTube-Kanal").foregroundStyle(.secondary)
        case .found, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch run.status(ofChannel: id) {
        case .waiting:
            Text("wartet").foregroundStyle(.secondary)
        case .running:
            Text("wird abonniert …").foregroundStyle(.secondary)
        case .added(let count):
            Text("Abonniert · ^[\(count) Folge](inflect: true)").foregroundStyle(.green)
        case .failed(let reason):
            // Das rote Symbol daneben sagt, dass es gescheitert ist. Der Grund bleibt lesbar.
            Text(reason).foregroundStyle(.secondary)
        case .skipped:
            Text("Nicht abonniert").foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    /// Audio-Podcast oder Kanal. Die Empfehlung steht oben.
    private var targetMenu: some View {
        Menu {
            Picker("Abonnieren als", selection: Binding(
                get: { selection.target(for: id) ?? .youTubeChannel },
                set: { run.choose($0, for: id) }
            )) {
                ForEach(selection.openCandidates(for: id)) { podcast in
                    Text("Audio-Podcast: \(podcast.title)")
                        .tag(TakeoutImportSelection.Target.audioPodcast(podcast.feedURL))
                }
                if selection.availableTargets(for: id).contains(.youTubeChannel) {
                    Text("YouTube-Kanal").tag(TakeoutImportSelection.Target.youTubeChannel)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if case .audioPodcast = selection.target(for: id) {
                Label("Audio-Podcast", systemImage: "waveform.circle")
            } else {
                Label("YouTube-Kanal", systemImage: "play.rectangle")
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        // Sonst löst ein Tipp auf die Zeile in einer Liste auch das Menü aus.
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Abonnieren als")
        .accessibilityValue(targetDescription)
        .accessibilityIdentifier("takeout.target")
    }

    private var targetDescription: String {
        if case .audioPodcast = selection.target(for: id) {
            return String(localized: "Audio-Podcast")
        }
        return String(localized: "YouTube-Kanal")
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch run.status(ofChannel: id) {
        case .running:
            ProgressView()
        case .added:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Abonniert")
        case .failed:
            Image(systemName: Design.Notice.failure.symbol)
                .foregroundStyle(Design.Notice.failure.tint)
                .accessibilityLabel("Nicht abonniert")
        case .waiting, .skipped, nil:
            EmptyView()
        }
    }
}

// MARK: - Feste Liste für UI-Tests

#if DEBUG
/// `-takeout-fixture` öffnet die Liste ohne Dateiauswahl mit drei Kanälen.
/// Mit `-catalog-fixtures` antwortet die Suche aus `CatalogFixtures`, ohne
/// Netz: „Code und Kaffee“ und „Beispiel Familie“ haben einen Audio-Podcast,
/// die Werkstatt nicht.
enum TakeoutFixture {

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-takeout-fixture") }

    static let csv = """
        \u{FEFF}Channel Id,Channel Url,Channel Title
        UCcodeundkaffee000000001,http://www.youtube.com/channel/UCcodeundkaffee000000001,Code und Kaffee
        UCbeispielfamilie0000002,http://www.youtube.com/channel/UCbeispielfamilie0000002,Beispiel Familie

        UCwerkstattohneton000003,http://www.youtube.com/channel/UCwerkstattohneton000003,"Werkstatt, ohne Ton"
        """

    static var request: TakeoutImportRequest? {
        guard let channels = try? YouTubeTakeout.channels(in: Data(csv.utf8)) else { return nil }
        return TakeoutImportRequest(fileName: "subscriptions.csv", channels: channels)
    }
}
#endif

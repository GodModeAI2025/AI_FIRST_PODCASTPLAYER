//
//  SubscriptionImport.swift
//  PodcastAI
//
//  Abos aus einer anderen App übernehmen und wieder mitnehmen. Wer mit 20
//  oder 30 Abos aus Overcast oder Pocket Casts kommt, sucht nicht jedes
//  einzeln. Die OPML-Datei wird gelesen, die Feeds stehen zum Abhaken da,
//  und das Abonnieren zeigt je Podcast, ob es geklappt hat.
//
//  Importiert wird nur die Folgenliste. Ausgewertet wird dabei nichts, das
//  kommt später Quelle für Quelle, wie bei jedem anderen Abo.
//

import SwiftUI
import UniformTypeIdentifiers
import PodcastAIKit

// MARK: - Datei lesen und schreiben

enum OPMLFile {

    /// `.opml` kennt das System meist nicht als eigenen Typ. Die Endung
    /// ergibt dann einen dynamischen Typ, der genau zu solchen Dateien
    /// passt. Mit `conformingTo: .xml` entstünde ein anderer, und die
    /// Dateiauswahl würde die Datei ausgrauen.
    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "opml"), .xml].compactMap { $0 }
    }

    /// Liest eine OPML-Datei aus der Dateiauswahl.
    static func read(_ url: URL) async throws -> Data {
        try await ImportedFile.read(url, maximumBytes: OPML.maximumBytes,
                                    tooLarge: OPMLError.tooLarge, unreadable: OPMLError.notOPML)
    }
}

/// Eine Abo-Liste aus der Dateiauswahl, als OPML oder als CSV aus Google Takeout.
enum ImportedFile {

    /// Liest die Datei. Sie kann in iCloud Drive liegen und erst geladen
    /// werden müssen; deshalb koordiniert und nicht auf dem Hauptthread.
    static func read(_ url: URL, maximumBytes: Int, tooLarge: any Error,
                     unreadable: any Error) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > maximumBytes {
                throw tooLarge
            }
            var coordinationError: NSError?
            var result: Result<Data, Error> = .failure(unreadable)
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                           error: &coordinationError) { readable in
                result = Result { try Data(contentsOf: readable) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Warum ein Abo aus einer Liste nicht ging, kurz genug für eine Zeile.
    nonisolated static func failureReason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorNotConnectedToInternet
                ? String(localized: "Keine Internetverbindung")
                : String(localized: "Der Server ist nicht erreichbar.")
        }
        return UserFacingError.describe(error)
    }
}

/// Alle Abos als OPML-Datei zum Teilen oder Sichern.
struct SubscriptionsExport: Transferable, Sendable {
    let feeds: [OPMLFeed]

    static let fileName = "PodcastAI-Abos.opml"

    static var transferRepresentation: some TransferRepresentation {
        // Als Datei, damit die Endung `.opml` erhalten bleibt. Andere Apps
        // erkennen die Liste daran.
        FileRepresentation(exportedContentType: .xml) { export in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(fileName)
            let text = OPML.document(title: "PodcastAI Abos", feeds: export.feeds)
            try Data(text.utf8).write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
        .suggestedFileName(fileName)
    }
}

// MARK: - Modell

extension AppModel {

    /// Was sich exportieren lässt: abonnierte Feeds im Netz. Einzelne Folgen
    /// und lokale Dateien haben keinen Feed, den eine andere App lesen könnte.
    var exportableFeeds: [OPMLFeed] {
        sources.compactMap { source in
            guard source.isExportableSubscription, let feed = source.feedURL else { return nil }
            return OPMLFeed(title: source.title, feedURL: feed, websiteURL: source.websiteURL)
        }
    }

    /// Abonniert einen Feed aus einer Abo-Liste.
    ///
    /// Anders als `subscribe(to:)` stößt das nichts weiter an. Wer 30 Abos
    /// mitbringt, soll nicht sofort 90 Folgen laden und auswerten lassen.
    func importSubscription(from input: String) async throws -> AddedSource {
        let added = try await refresher.addSource(from: input)
        sources = withSupadataMetadata(sources: try await store.sources())
        pruneSubscribedCounterparts(input: input)
        return added
    }

    /// Nimmt abonnierte Podcasts aus den Vorschlägen zu YouTube-Kanälen.
    ///
    /// Verglichen wird mit den gespeicherten Feeds und mit der Adresse, die
    /// gerade abonniert wurde. Liegt der Feed unter einer anderen Adresse,
    /// als das Verzeichnis nennt, verschwindet der Vorschlag trotzdem.
    func pruneSubscribedCounterparts(input: String? = nil) {
        var subscribed = Set(sources.filter(\.isSubscribed).compactMap { $0.feedURL?.absoluteString })
        if let input { subscribed.insert(input.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for (sourceID, list) in podcastCounterparts {
            let open = list.filter { !subscribed.contains($0.feedURL.absoluteString) }
            if open.count != list.count { podcastCounterparts[sourceID] = open }
        }
    }
}

// MARK: - Dateiauswahl

/// Eine gelesene Abo-Liste, bereit zum Abhaken.
struct OPMLImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let feeds: [OPMLFeed]
}

extension View {
    /// Dateiauswahl für eine OPML-Datei und danach die Liste zum Abonnieren.
    /// `onSubscribed` läuft, wenn die Liste geschlossen wird und dabei
    /// mindestens ein Podcast dazukam.
    func opmlImport(isPresented: Binding<Bool>, onSubscribed: (() -> Void)? = nil) -> some View {
        modifier(OPMLImportModifier(isPresented: isPresented, onSubscribed: onSubscribed))
    }
}

private struct OPMLImportModifier: ViewModifier {

    @Binding var isPresented: Bool
    let onSubscribed: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var request: OPMLImportRequest?
    @State private var readError: String?
    @State private var subscribedCount = 0

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: OPMLFile.contentTypes) { result in
                switch result {
                case .success(let url):
                    Task { await open(url) }
                case .failure(let error):
                    readError = error.localizedDescription
                }
            }
            .sheet(item: $request, onDismiss: {
                if subscribedCount > 0 { onSubscribed?() }
                subscribedCount = 0
            }) { request in
                OPMLImportSheet(request: request, subscribedCount: $subscribedCount)
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
    }

    private func open(_ url: URL) async {
        do {
            let data = try await OPMLFile.read(url)
            let feeds = try OPML.feeds(in: data)
            request = OPMLImportRequest(fileName: url.lastPathComponent, feeds: feeds)
        } catch {
            readError = UserFacingError.describe(error)
        }
    }
}

// MARK: - Liste zum Abhaken

struct OPMLImportSheet: View {

    let request: OPMLImportRequest
    @Binding var subscribedCount: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []
    @State private var status: [URL: FeedStatus] = [:]
    @State private var phase: Phase = .choosing
    @State private var prepared = false
    @State private var importTask: Task<Void, Never>?

    enum Phase { case choosing, running, finished }

    enum FeedStatus: Equatable, Sendable {
        case waiting
        case running
        case added(Int)
        case failed(String)
        case skipped
    }

    /// Mehrere Feeds zugleich, aber nicht alle: jeder Feed kann einige
    /// Megabyte groß sein.
    private static let parallelImports = 3

    private var feeds: [OPMLFeed] { request.feeds }
    private var chosen: [OPMLFeed] { feeds.filter { selected.contains($0.id) } }
    private var selectable: [OPMLFeed] { feeds.filter { !model.isSubscribed($0.feedURL) } }

    private var addedCount: Int {
        status.values.filter { if case .added = $0 { true } else { false } }.count
    }
    private var failedCount: Int {
        status.values.filter { if case .failed = $0 { true } else { false } }.count
    }
    private var skippedCount: Int {
        status.values.filter { $0 == .skipped }.count
    }
    private var doneCount: Int { addedCount + failedCount + skippedCount }
    private var total: Int { status.count }

    var body: some View {
        NavigationStack {
            List {
                if phase != .choosing {
                    Section {
                        VStack(alignment: .leading, spacing: Design.Spacing.small) {
                            ProgressView(value: Double(doneCount), total: Double(max(total, 1)))
                            Text(summary)
                                .font(.callout)
                                .accessibilityIdentifier("opml.summary")
                        }
                        .padding(.vertical, Design.Spacing.micro)
                    }
                }

                Section {
                    ForEach(feeds) { feed in
                        row(feed)
                    }
                } header: {
                    HStack {
                        Text("^[\(feeds.count) Podcast](inflect: true) in „\(request.fileName)“")
                        Spacer()
                        if phase == .choosing, !selectable.isEmpty {
                            Button {
                                selected = selected.count == selectable.count ? [] : Set(selectable.map(\.id))
                            } label: {
                                if selected.count == selectable.count { Text("Alle abwählen") } else { Text("Alle auswählen") }
                            }
                            .font(.caption)
                        }
                    }
                } footer: {
                    if phase == .choosing {
                        Text("Abonnieren holt nur die Folgenlisten. Transkripte entstehen dabei noch keine.")
                    }
                }
            }
            .navigationTitle("Abos importieren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(phase == .running)
        .task {
            guard !prepared else { return }
            prepared = true
            selected = Set(selectable.map(\.id))
        }
        .onDisappear { importTask?.cancel() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch phase {
        case .choosing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(chosen.count == 1 ? "1 abonnieren" : "\(chosen.count) abonnieren", action: start)
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("opml.subscribe")
            }
        case .running:
            ToolbarItem(placement: .cancellationAction) {
                Button("Stoppen") { importTask?.cancel() }
            }
        case .finished:
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
    }

    private var summary: String {
        if phase == .running {
            return String(localized: "\(doneCount) von \(total) erledigt")
        }
        var parts = [Self.inflected("^[\(addedCount) Podcast](inflect: true) abonniert")]
        if failedCount > 0 {
            parts.append(failedCount == 1 ? String(localized: "1 ging nicht") : String(localized: "\(failedCount) gingen nicht"))
        }
        if skippedCount > 0 {
            parts.append(String(localized: "\(skippedCount) nach dem Stoppen ausgelassen"))
        }
        let text = parts.formatted(.list(type: .and, width: .narrow))
        return failedCount > 0
            ? String(localized: "\(text). Den Grund siehst du beim jeweiligen Podcast.")
            : String(localized: "\(text).")
    }

    private static func inflected(_ resource: String.LocalizationValue) -> String {
        String(AttributedString(localized: resource).characters)
    }

    // MARK: Zeile

    @ViewBuilder
    private func row(_ feed: OPMLFeed) -> some View {
        let isSelected = selected.contains(feed.id)
        let alreadySubscribed = status[feed.id] == nil && model.isSubscribed(feed.feedURL)
        if phase == .choosing && !alreadySubscribed {
            Button {
                if isSelected { selected.remove(feed.id) } else { selected.insert(feed.id) }
            } label: {
                rowContent(feed, isSelected: isSelected, alreadySubscribed: false)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            rowContent(feed, isSelected: isSelected, alreadySubscribed: alreadySubscribed)
                .accessibilityElement(children: .combine)
        }
    }

    private func rowContent(_ feed: OPMLFeed, isSelected: Bool, alreadySubscribed: Bool) -> some View {
        HStack(spacing: Design.Spacing.control) {
            if phase == .choosing {
                Image(systemName: isSelected || alreadySubscribed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected && !alreadySubscribed ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title)
                    .foregroundStyle(alreadySubscribed ? .secondary : .primary)
                    .lineLimit(2)
                detail(feed, alreadySubscribed: alreadySubscribed)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            statusSymbol(feed)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func detail(_ feed: OPMLFeed, alreadySubscribed: Bool) -> some View {
        switch status[feed.id] {
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
            if alreadySubscribed {
                Text("Schon abonniert").foregroundStyle(.secondary)
            } else {
                Text(feed.feedURL.host() ?? feed.feedURL.absoluteString).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusSymbol(_ feed: OPMLFeed) -> some View {
        switch status[feed.id] {
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

    // MARK: Abonnieren

    private func start() {
        let queue = chosen
        guard !queue.isEmpty else { return }
        // Alle Gewählten zählen von Anfang an mit, damit „x von y“ stimmt.
        for feed in queue { status[feed.id] = .waiting }
        phase = .running
        importTask = Task {
            await run(queue)
            subscribedCount = addedCount
            phase = .finished
            importTask = nil
        }
    }

    private func run(_ queue: [OPMLFeed]) async {
        var pending = queue[...]
        let model = model
        await withTaskGroup(of: (URL, FeedStatus).self) { group in
            for _ in 0..<Self.parallelImports {
                guard let feed = pending.popFirst() else { break }
                status[feed.id] = .running
                group.addTask { await Self.subscribe(feed, model: model) }
            }
            while let (id, result) = await group.next() {
                status[id] = result
                guard !Task.isCancelled, let feed = pending.popFirst() else { continue }
                status[feed.id] = .running
                group.addTask { await Self.subscribe(feed, model: model) }
            }
        }
        // Nach dem Stoppen: was noch wartete, bleibt ohne Abo.
        for feed in pending { status[feed.id] = .skipped }
    }

    private nonisolated static func subscribe(_ feed: OPMLFeed, model: AppModel) async -> (URL, FeedStatus) {
        do {
            let added = try await model.importSubscription(from: feed.feedURL.absoluteString)
            return (feed.id, .added(added.episodeCount))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return (feed.id, .skipped)
            }
            return (feed.id, .failed(ImportedFile.failureReason(error)))
        }
    }
}

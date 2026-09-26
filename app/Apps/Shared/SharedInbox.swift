//
//  SharedInbox.swift
//  PodcastAI
//
//  Die App-Seite von „An PodcastAI senden“. Beim Start, beim Wechsel in den
//  Vordergrund und wenn die Erweiterung die App öffnet, liest die App den
//  Eingang der App Group. Ein Link öffnet das Blatt „Hinzufügen“ mit der
//  Vorschau, eine Audiodatei ein kleines Blatt mit „Zur Bibliothek
//  hinzufügen“. Angelegt wird erst auf Tippen, abgespielt gar nichts.
//
//  Was im Eingang steht, ist fremde Eingabe. `ShareInbox` prüft Link,
//  Dateiname und Größe, bevor hier etwas davon ankommt, und `AppModel`
//  prüft den Anfang der Datei, bevor sie in die Bibliothek geht.
//

import SwiftUI
import PodcastAIKit

/// Wartende Übergaben für die ganze App. Ein Fenster zeigt jeweils eine;
/// ist sie erledigt oder verworfen, kommt die nächste.
@MainActor
@Observable
final class SharedInboxCenter {

    static let shared = SharedInboxCenter()

    /// Eine geprüfte Übergabe.
    struct Offer: Identifiable, Equatable {
        let item: ShareInboxItem
        let content: SharedContent
        var id: UUID { item.id }
    }

    /// Die Übergabe, die gerade gezeigt wird oder als Nächstes drankommt.
    private(set) var current: Offer?
    /// Das Fenster, das sie zeigt. Auf dem iPad und dem Mac kann es mehrere geben.
    private(set) var presenter: UUID?

    @ObservationIgnored private var queue: [ShareInboxItem] = []
    @ObservationIgnored private var known: Set<UUID> = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let inbox: ShareInbox?

    /// Was ein Fenster übernehmen darf: die aktuelle Übergabe, solange kein
    /// anderes sie zeigt.
    var open: Offer? { presenter == nil ? current : nil }

    private init() {
        inbox = ShareInbox.appGroup()
        #if DEBUG
        Self.simulateSharingForUITests(into: inbox)
        #endif
    }

    #if DEBUG
    /// UI-Tests beginnen mit leerem Eingang. `-uitest-shared-link <Adresse>`
    /// und `-uitest-shared-audio <Dateiname>` spielen eine Übergabe der
    /// Erweiterung nach, ohne Teilen-Menü. Die Audiodatei beginnt wie MP3
    /// und enthält sonst nur Stille.
    private static func simulateSharingForUITests(into inbox: ShareInbox?) {
        guard let inbox else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("-uitest-fresh") { inbox.removeAll() }
        if let link = value(after: "-uitest-shared-link") { _ = try? inbox.deposit(link: link) }
        if let name = value(after: "-uitest-shared-audio") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            var data = Data("ID3".utf8)
            data.append(Data(repeating: 0, count: 64 * 1024))
            if (try? data.write(to: file)) != nil {
                _ = try? inbox.deposit(audioFileAt: file, originalName: name)
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    #endif

    /// Liest den Eingang. Schon Bekanntes kommt nicht noch einmal.
    func refresh() async {
        guard let inbox, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let items = await Task.detached(priority: .utility) { inbox.pending() }.value
        for item in items where !known.contains(item.id) {
            known.insert(item.id)
            queue.append(item)
        }
        advance()
    }

    /// Ein Fenster übernimmt die aktuelle Übergabe.
    func claim(_ offer: Offer, by window: UUID) -> Bool {
        guard current?.id == offer.id, presenter == nil || presenter == window else { return false }
        presenter = window
        return true
    }

    /// Das Fenster geht zu, ohne die Übergabe erledigt zu haben. Ein anderes
    /// darf sie dann zeigen.
    func release(_ window: UUID) {
        if presenter == window { presenter = nil }
    }

    /// Erledigt oder verworfen: Der Eintrag geht aus dem Eingang, samt Datei,
    /// falls die App sie nicht übernommen hat.
    func finish(_ id: UUID) {
        guard let offer = current, offer.id == id else { return }
        current = nil
        presenter = nil
        if let inbox {
            let item = offer.item
            Task.detached(priority: .utility) { inbox.remove(item) }
        }
        advance()
    }

    private func advance() {
        guard current == nil, let inbox else { return }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if let content = try? inbox.content(of: item) {
                current = Offer(item: item, content: content)
                return
            }
            inbox.remove(item)
        }
    }
}

// MARK: - Anschluss an die Wurzel

extension View {
    /// Nimmt Übergaben aus „An PodcastAI senden“ an. `isActive` ist auf dem
    /// Mac nur im Fenster wahr, das für die ganze App spricht.
    func sharedInbox(isActive: Bool = true) -> some View {
        modifier(SharedInboxIntake(isActive: isActive))
    }
}

private struct SharedInboxIntake: ViewModifier {

    let isActive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowID = UUID()
    @State private var shown: SharedInboxCenter.Offer?
    /// Schon gezeigt. Schließt ein Blatt, bevor die Übergabe als erledigt
    /// gilt, erscheint sie so nicht ein zweites Mal.
    @State private var handled: Set<UUID> = []
    #if os(iOS)
    @State private var anchor = PresentationAnchor()
    #endif

    private var center: SharedInboxCenter { .shared }

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                // Die Adresse trägt nichts außer dem Auftrag, nachzusehen.
                guard url.scheme == ShareInbox.openAppURL.scheme, url.host() == ShareInbox.openAppURL.host() else { return }
                Task { await center.refresh() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await center.refresh() } }
            }
            .onChange(of: center.open?.id, initial: true) { present() }
            .onChange(of: model.isLoaded) { present() }
            .onChange(of: isActive) { present() }
            .onChange(of: shown?.id) { present() }
            .onDisappear { center.release(windowID) }
            #if os(iOS)
            .background { PresentationAnchor.Marker(anchor: anchor) }
            #endif
            .sheet(item: $shown) { offer in
                SharedInboxSheet(offer: offer)
                    .sheetFeedback()
                    .environment(model)
            }
    }

    /// Zeigt die aktuelle Übergabe, sobald die Bibliothek geladen ist.
    /// Liegt schon ein Blatt offen, kommt sie darüber, statt zu warten.
    private func present() {
        guard isActive, model.isLoaded, shown == nil, let offer = center.open, !handled.contains(offer.id),
              center.claim(offer, by: windowID) else { return }
        handled.insert(offer.id)
        #if os(iOS)
        let model = model
        let shownAbove = anchor.presentAboveOpenSheet { close in
            SharedInboxSheet(offer: offer, close: close)
                .sheetFeedback()
                .environment(model)
        }
        if shownAbove { return }
        #endif
        shown = offer
    }
}

// MARK: - Blätter

/// Was zu einer Übergabe erscheint: das Blatt „Hinzufügen“ mit dem Link
/// oder das Blatt für eine Audiodatei.
private struct SharedInboxSheet: View {

    let offer: SharedInboxCenter.Offer
    var close: (@MainActor () -> Void)? = nil

    var body: some View {
        Group {
            switch offer.content {
            case .link(let url):
                AddSourceSheet(sharedLink: url.absoluteString, close: close)
            case .audioFile(let file, let title, let bytes):
                SharedAudioFileSheet(file: file, title: title, byteCount: bytes, close: close)
            }
        }
        // Zu, auf welchem Weg auch immer: Die Übergabe ist erledigt.
        .onDisappear { SharedInboxCenter.shared.finish(offer.id) }
    }
}

/// Eine geteilte Audiodatei vor dem Hinzufügen.
private struct SharedAudioFileSheet: View {

    let file: URL
    let title: String
    let byteCount: Int64
    var close: (@MainActor () -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                            Text(verbatim: title)
                                .font(.headline)
                                .lineLimit(3)
                            Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "waveform")
                    }
                    .accessibilityElement(children: .combine)
                } footer: {
                    Text("Die Datei kommt als Folge unter „Einzelne Folgen“ und bleibt auf diesem Gerät, bis du „Audio entfernen“ wählst. Auf deinen anderen Geräten steht die Folge mit Transkript, aber ohne Ton.")
                }

                if let failure {
                    Section {
                        NoticeLabel(failure, kind: .failure)
                            .accessibilityIdentifier("share.audio.error")
                    }
                }

                Section {
                    Button(action: add) {
                        HStack {
                            Label("Zur Bibliothek hinzufügen", systemImage: "plus.circle.fill")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("share.audio.add")
                }
            }
            .navigationTitle("Geteilte Audiodatei")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Verwerfen", action: finish)
                        .disabled(working)
                }
            }
        }
        // Während die Datei umzieht, bleibt das Blatt offen.
        .interactiveDismissDisabled(working)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private func finish() {
        if let close { close() } else { dismiss() }
    }

    private func add() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await model.addSharedAudioFile(file, title: title)
                AccessibilityNotification.Announcement(String(localized: "Folge hinzugefügt: \(title)")).post()
                finish()
            } catch {
                failure = UserFacingError.describe(error)
            }
        }
    }
}

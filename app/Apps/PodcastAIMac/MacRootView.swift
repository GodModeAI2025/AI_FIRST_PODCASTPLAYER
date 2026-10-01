//
//  MacRootView.swift
//  PodcastAI (macOS)
//
//  Ein Fenster: Seitenleiste, Inhalt mit eigenem Stapel je Eintrag,
//  Inspektor, der Player in der Symbolleiste.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PodcastAIKit

struct MacRootView: View {

    @Binding var startupIssue: StartupIssue?
    @Environment(AppModel.self) private var model
    @Environment(MacWindows.self) private var windows
    @State private var router = MacRouter()
    /// Nur der Eintrag der Seitenleiste überlebt einen Neustart.
    @SceneStorage("sidebarItem") private var storedItem = SidebarItem.forYou.storageValue
    @State private var restored = false
    @State private var showingOnboarding = OnboardingView.shouldShow
    @State private var isAddingSource = false
    @State private var showingActivity = false
    @State private var note = MomentNoteDraft()
    @State private var showingNote = false
    @State private var windowID = UUID()

    /// Zeigt dieses Fenster, was die ganze App betrifft?
    private var isPresenter: Bool { windows.presenter == windowID }

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            MacSidebar()
        } detail: {
            detail
                .onExitCommand { router.pop() }
                .confirmationBanner()
                .inspector(isPresented: $router.isInspectorPresented) {
                    MacInspector()
                }
        }
        .environment(router)
        .toolbar {
            MacNowPlayingToolbar(note: note, showingNote: $showingNote)
            ToolbarItem(placement: .primaryAction) {
                activityItem
            }
            ToolbarItem(placement: .primaryAction) {
                Button { router.toggleInspector(.upNext) } label: {
                    Label("Als Nächstes", systemImage: "sidebar.trailing")
                }
                .help("Als Nächstes und Informationen ein- oder ausblenden (⌥⌘U)")
                .accessibilityIdentifier("toolbar.inspector")
            }
        }
        .autoRefresh()
        .spotlightPassages()
        // Links und Audiodateien aus „An PodcastAI senden“, nur in einem Fenster.
        .sharedInbox(isActive: isPresenter)
        .environment(\.openQueue, OpenQueueAction(run: { showingActivity = true }))
        .environment(\.showInApp, ShowInAppAction { jump in router.jump(to: jump) })
        .onOpenURL { url in router.open(url) }
        // Eine Adresse aus dem Widget geht in ein offenes Fenster, statt
        // ein neues aufzumachen.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // Links und Audiodateien lassen sich aufs Fenster ziehen. Sie gehen
        // denselben Weg wie „An PodcastAI senden“; nichts davon spielt.
        .dropDestination(for: URL.self, isEnabled: isPresenter) { urls, _ in
            SharedInboxCenter.shared.accept(dropped: urls)
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView().sheetFeedback().environment(model).frame(minWidth: 480, minHeight: 620)
        }
        .sheet(isPresented: $isAddingSource) {
            AddSourceSheet()
                .sheetFeedback()
                .environment(model)
                .frame(minWidth: 640, minHeight: 560)
        }
        .focusedSceneValue(\.isAddingSource, $isAddingSource)
        .focusedSceneValue(\.router, router)
        .focusedSceneValue(\.momentNote,
                           MacNowPlayingDisplay.momentNoteAction(model: model, note: note, showingNote: $showingNote))
        // Nur ein Fenster meldet, was die ganze App betrifft. Die Meldungen
        // hängen an einer leeren Ansicht im Hintergrund, damit ein Wechsel
        // des meldenden Fensters den Inhalt nicht neu aufbaut.
        .background {
            if isPresenter {
                Color.clear
                    .startupIssueAlert($startupIssue)
                    .appFeedback()
            }
        }
        .onAppear {
            windows.opened(windowID)
            if !restored {
                restored = true
                router.selection = SidebarItem(storageValue: storedItem)
                #if DEBUG
                applyTestSidebarArgument()
                captureStoreShotsIfRequested()
                #endif
            }
        }
        .onDisappear { windows.closed(windowID) }
        .onChange(of: router.selection) { _, item in
            storedItem = (item ?? .forYou).storageValue
        }
        // Ein gespeicherter Podcast, den es nicht mehr gibt, führt zu
        // „Meine Podcasts“ statt auf eine leere Seite.
        .onChange(of: model.sources.map(\.id), initial: true) { _, ids in
            guard model.isLoaded, case .podcast(let id) = router.selection, !ids.contains(id) else { return }
            router.show(.library)
        }
    }

    // MARK: Inhalt

    @ViewBuilder private var detail: some View {
        switch router.selection ?? .forYou {
        case .forYou: stack(.forYou) { ForYouView() }
        case .feeds:
            stack(.feeds) { SmartFeedListView(linkedTag: Bindable(router).linkedTag) }
        case .library: stack(.library) { LibraryView() }
        case .chat: stack(.chat) { ChatView() }
        case .knowledge: stack(.knowledge) { KnowledgeView() }
        case .trails: stack(.trails) { TrailListView() }
        case .interests: stack(.interests) { TagsView() }
        case .help: stack(.help) { HelpView() }
        case .podcast(let id):
            stack(.podcast(id)) { EpisodeListView(sourceID: id) }
                .id(id)
        }
    }

    /// Ein eigener Stapel je Eintrag. Wechselt jemand zum Chat und zurück,
    /// liegt der geöffnete Podcast noch da.
    private func stack<Root: View>(_ item: SidebarItem, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: router.path(for: item)) {
            root()
                .navigationDestination(for: MacRoute.self) { route in
                    switch route {
                    case .episode(let episode): EpisodeDetailView(episode: episode)
                    case .sourceInfo(let id): SourceDetailView(sourceID: id)
                    }
                }
        }
    }

    #if DEBUG
    /// Für Tests: `-uitest-sidebar chat` beginnt bei diesem Eintrag,
    /// `-uitest-sidebar firstPodcast` beim ersten Podcast, sobald die
    /// Bibliothek geladen ist, und `-uitest-open-episode` öffnet dort die
    /// neueste Folge. Nichts davon spielt etwas ab.
    private func applyTestSidebarArgument() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-sidebar"), index + 1 < arguments.count else { return }
        let value = arguments[index + 1]
        guard value == "firstPodcast" else {
            router.show(SidebarItem(storageValue: value))
            return
        }
        let openEpisode = arguments.contains("-uitest-open-episode")
        Task {
            await model.ensureLoaded()
            for _ in 0..<50 where model.sources.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let source = model.sources.first else { return }
            router.show(.podcast(source.id))
            guard openEpisode else { return }
            await model.loadEpisodes(for: source.id)
            if let episode = model.episodes[source.id]?.first { router.push(.episode(episode)) }
        }
    }

    /// Für die Bilder im App Store: `-store-shots <Ordner>` zeigt die
    /// wichtigsten Bereiche nacheinander und legt je ein Bild des Fensters
    /// ab. Das Fenster zeichnet sich selbst, das braucht keine Freigabe für
    /// Bildschirmaufnahmen. Danach beendet sich die App.
    private func captureStoreShotsIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-store-shots"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await model.ensureLoaded()
            for _ in 0..<50 where model.sources.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(2))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.setContentSize(NSSize(width: 1440, height: 900))
                window.center()
            }
            // Nur für die Bilder: je zwei gemerkte Stellen und gesicherte Antworten,
            // damit die Karten zu sehen sind. Sie landen nicht im Speicher.
            let seedKnowledge = {
                let episode = DemoContent.episodeID
                model.highlights = [
                    Highlight(evidenceID: EvidenceID(), note: "Für den Workshop merken", capturedVia: .player,
                              quote: "Modelle auf dem Gerät verarbeiten Text lokal, dadurch verlassen Daten das Telefon nicht.",
                              episodeID: episode, episodeTitle: "KI im Arbeitsalltag: Datenschutz, Regeln, Haftung",
                              sourceTitle: "Beispiel: Arbeit und KI", positionMs: 135_000),
                    Highlight(evidenceID: EvidenceID(), capturedVia: .transcript,
                              quote: "Wer heute anfängt, sollte mit einem kleinen, messbaren Projekt starten.",
                              episodeID: episode, episodeTitle: "KI im Arbeitsalltag: Datenschutz, Regeln, Haftung",
                              sourceTitle: "Beispiel: Arbeit und KI", positionMs: 780_000),
                ]
                model.trails = [
                    KnowledgeTrail(question: "Wie schütze ich Daten beim Einsatz von KI im Team?",
                                   evidenceIDs: [EvidenceID(), EvidenceID(), EvidenceID()],
                                   answerText: "Modelle auf dem Gerät verarbeiten Text lokal. Für größere Aufgaben gibt es Serverlösungen, die Anfragen nicht speichern."),
                    KnowledgeTrail(question: "Wer haftet für Fehler eines Modells?",
                                   evidenceIDs: [EvidenceID()],
                                   answerText: "Die europäische KI-Verordnung verlangt Transparenz und Risikobewertung."),
                ]
            }
            var steps: [(String, () -> Void)] = [
                ("01-fuer-dich", { router.show(.forYou) }),
                ("02-meine-podcasts", { router.show(.library) }),
            ]
            if let source = model.sources.first {
                await model.loadEpisodes(for: source.id)
                steps.append(("03-podcast", { router.show(.podcast(source.id)) }))
                if let episode = model.episodes[source.id]?.last {
                    steps.append(("04-folge", { router.show(.podcast(source.id)); router.push(.episode(episode)) }))
                }
            }
            steps += [
                ("05-themen-updates", { router.show(.feeds) }),
                ("06-chat", { router.show(.chat) }),
                ("07-meine-tags", { router.show(.interests) }),
                ("08-gemerkte-stellen", { seedKnowledge(); router.show(.knowledge) }),
                ("09-gesicherte-antworten", { seedKnowledge(); router.show(.trails) }),
            ]
            NSApp.activate(ignoringOtherApps: true)
            for (name, show) in steps {
                show()
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
                try? await Task.sleep(for: .seconds(3))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { continue }
                let png = Self.windowPNG(window)
                try? png?.write(to: folder.appendingPathComponent("mac-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Das Fenster samt Seitenleiste und Glas. `cacheDisplay` lässt die
    /// Materialien weg; die Fensterliste des Systems zeigt, was auf dem
    /// Bildschirm steht. Für das eigene Fenster braucht das keine Freigabe.
    private static func windowPNG(_ window: NSWindow) -> Data? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: Create.self)
            // Nur dieses Fenster (8), ohne Rahmenschatten (1), volle Auflösung (8).
            if let image = create(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() {
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    // MARK: Aktivität

    @ViewBuilder private var activityItem: some View {
        ActivityStatusButton()
            .help("Verarbeitung anzeigen")
            .popover(isPresented: $showingActivity, arrowEdge: .bottom) {
                MacActivityPopover()
            }
    }
}

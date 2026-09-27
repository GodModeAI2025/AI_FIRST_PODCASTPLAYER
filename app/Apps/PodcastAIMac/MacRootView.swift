//
//  MacRootView.swift
//  PodcastAI (macOS)
//
//  Ein Fenster: Seitenleiste, Inhalt mit eigenem Stapel je Eintrag,
//  Inspektor, der Player in der Symbolleiste.
//

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

//
//  MacSidebar.swift
//  PodcastAI (macOS)
//
//  Die Seitenleiste: Hören, Wissen und die abonnierten Podcasts. Glas
//  bringt das System selbst mit, hier liegt keine eigene Fläche.
//

import SwiftUI
import PodcastAIKit

struct MacSidebar: View {

    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @AppStorage("sidebarPodcastsExpanded") private var podcastsExpanded = true
    @State private var pendingRemoval: Source?

    private var subscriptions: [Source] {
        model.sources.filter(\.isSubscribed)
    }

    /// Die Auswahl der Liste. „So funktioniert's“ hat keine Zeile; solange es
    /// offen ist, ist nichts markiert, und die Liste setzt es nicht zurück.
    private var listSelection: Binding<SidebarItem?> {
        Binding(
            get: { router.selection == .help ? nil : router.selection },
            set: { item in if let item { router.selection = item } }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            // „Wissen“ enthält dieselben Einträge wie der Reiter auf iOS,
            // damit Hinweise wie „Wissen › Meine Tags“ auf beiden Geräten stimmen.
            Section("Hören") {
                ForEach(SidebarItem.listening, id: \.self) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            Section("Wissen") {
                ForEach(SidebarItem.knowledgeItems, id: \.self) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            if !subscriptions.isEmpty {
                Section("Podcasts", isExpanded: $podcastsExpanded) {
                    ForEach(subscriptions) { source in
                        Label {
                            Text(source.title).lineLimit(1)
                        } icon: {
                            EpisodeArtwork(url: source.artworkURL, size: 18)
                        }
                        .tag(SidebarItem.podcast(source.id))
                        .contextMenu { podcastMenu(source) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .confirmationDialog("Abbestellen?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { source in
            Button("\(source.title) abbestellen", role: .destructive) {
                if router.selection == .podcast(source.id) { router.show(.library) }
                Task { await model.removeSource(source.id) }
            }
        } message: { _ in
            Text("Alle Folgen dieses Podcasts werden mit Transkripten, Fakten und Hörstand gelöscht.")
        }
    }

    @ViewBuilder
    private func podcastMenu(_ source: Source) -> some View {
        SourceReloadButton(source: source)
        Button {
            router.show(.podcast(source.id))
            router.inspectorMode = .info
            router.isInspectorPresented = true
        } label: {
            Label("Informationen", systemImage: "info.circle")
        }
        Divider()
        Button(role: .destructive) { pendingRemoval = source } label: {
            Label("Abbestellen …", systemImage: "minus.circle")
        }
    }
}

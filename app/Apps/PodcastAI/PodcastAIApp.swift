//
//  PodcastAIApp.swift
//  PodcastAI (iOS / iPadOS)
//
//  Auf dem iPhone steht das Hören im Vordergrund: vier fachliche Bereiche,
//  ein durchgehender Mini-Player. Das iPad bekommt dieselben Bereiche in
//  einer Mehrspaltenansicht — nicht dieselbe Ansicht, nur breiter.
//

import SwiftUI
import PodcastAIKit

@main
struct PodcastAIApp: App {

    @State private var model: AppModel
    @State private var startupError: String?

    init() {
        do {
            let container = try LibraryStore.makeContainer()
            _model = State(initialValue: AppModel(store: LibraryStore(modelContainer: container)))
        } catch {
            // Der Speicher wird nicht stillschweigend durch einen flüchtigen
            // ersetzt: das würde aussehen, als seien die Daten weg.
            // Stattdessen ein ehrlicher Fehler mit Wiederholmöglichkeit.
            let container = try! LibraryStore.makeContainer(inMemory: true)
            _model = State(initialValue: AppModel(store: LibraryStore(modelContainer: container)))
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.load() }
                .alert("Der Speicher konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("Erneut versuchen") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
        }
    }
}

struct RootView: View {

    @Environment(AppModel.self) private var model
    @State private var selection: Tab = .forYou

    enum Tab: Hashable { case forYou, feeds, library, knowledge }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Für dich", systemImage: "sparkles", value: Tab.forYou) {
                NavigationStack { ForYouView() }
            }
            Tab("Meine Feeds", systemImage: "waveform.circle", value: Tab.feeds) {
                NavigationStack { SmartFeedListView() }
            }
            Tab("Mediathek", systemImage: "books.vertical", value: Tab.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Wissen", systemImage: "brain", value: Tab.knowledge) {
                NavigationStack { InterestsView() }
            }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        .overlay(alignment: .top) { ActivityBanner() }
    }
}

/// Der durchgehende Mini-Player. Zeigt, was läuft, und beendet es —
/// er startet nie von sich aus etwas.
struct MiniPlayerBar: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        if let plan = model.player.activePlan, !plan.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.requestSummary)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("\(plan.segments.count) Stellen · \(plan.distinctSourceCount) Quellen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.player.pause() } label: {
                    Image(systemName: "pause.fill")
                }
                Button { model.player.stop() } label: {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

/// Eine Zeile, die sagt, was gerade passiert. Kein endloser Spinner.
struct ActivityBanner: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        if let activity = model.activity {
            Text(activity)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

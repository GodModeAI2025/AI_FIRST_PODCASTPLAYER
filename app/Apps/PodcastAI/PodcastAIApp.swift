//
//  PodcastAIApp.swift
//  PodcastAI (iOS / iPadOS)
//
//  Fünf Bereiche, nicht sieben.
//
//  Die Tab Bar verträgt drei bis fünf Einträge. Bei sieben wird jeder
//  einzelne schmaler, die Beschriftungen brechen um, und der Nutzer muss
//  lesen statt zu erkennen. Interessen, Gegenpositionen und
//  Wissenslandkarten sind deshalb keine eigenen Tabs, sondern liegen unter
//  „Wissen“ — sie gehören inhaltlich zusammen und werden seltener gebraucht
//  als Hören und Mediathek.
//
//  „Fragen“ steht an der Stelle, an der seit WWDC25 die Suche erwartet wird:
//  ein eigener Tab, immer erreichbar. In dieser App ist die Suche ein
//  Gespräch — aber sie bleibt Suche.
//

import SwiftUI
import PodcastAIKit

@main
struct PodcastAIApp: App {

    @State private var model: AppModel
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase

    /// Hält die geliehene Zeit beim Wechsel in den Hintergrund.
    private let continuation = BackgroundContinuation()

    /// Muss gehalten werden: `BGTaskScheduler` behält zwar die Startblöcke,
    /// aber die Planung der nächsten Ausführung läuft über dieses Objekt.
    private let background: BackgroundWork

    init() {
        let model: AppModel
        var failure: String?
        do {
            let container = try LibraryStore.makeContainer()
            model = AppModel(store: LibraryStore.make(container: container))
        } catch {
            // Der Speicher wird nicht stillschweigend durch einen flüchtigen
            // ersetzt: das sähe aus, als seien die Daten weg.
            let container = try! LibraryStore.makeContainer(inMemory: true)
            model = AppModel(store: LibraryStore.make(container: container))
            failure = error.localizedDescription
        }
        _model = State(initialValue: model)
        _startupError = State(initialValue: failure)
        // Hier und nicht in `.task`: Intent-Abhängigkeit, Audiositzung und
        // BGTask-Registrierung müssen stehen, bevor der Start fertig ist.
        self.background = AppBootstrap.start(with: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.load()
                    background.scheduleRefresh()
                    // Was beim letzten Mal offen blieb, wird jetzt
                    // weitergeführt — ohne dass jemand nochmal drücken muss.
                    model.workQueue()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        continuation.appDidEnterBackground(model: model)
                    case .active:
                        continuation.appWillEnterForeground(model: model)
                    default:
                        break
                    }
                }
                .alert("Der Speicher konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("Erneut versuchen") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
                .appFeedback()
        }
    }
}

struct RootView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Die Auswahl liegt am Modell, damit ein leerer Zustand auf den
        // nächsten Schritt zeigen kann — „Noch keine Quellen“ führt in die
        // Mediathek, statt nur dorthin zu verweisen.
        @Bindable var model = model
        return TabView(selection: $model.area) {
            Tab("Für dich", systemImage: "sparkles", value: AppArea.forYou) {
                NavigationStack { ForYouView() }
            }
            Tab("Meine Feeds", systemImage: "waveform.circle", value: AppArea.feeds) {
                NavigationStack { SmartFeedListView() }
            }
            // Eigener Such-Tab: die Rolle, die er seit WWDC25 hat.
            Tab("Fragen", systemImage: "magnifyingglass", value: AppArea.ask, role: .search) {
                NavigationStack { ChatView() }
            }
            Tab("Mediathek", systemImage: "books.vertical", value: AppArea.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Wissen", systemImage: "brain", value: AppArea.knowledge) {
                NavigationStack { KnowledgeHubView() }
            }
        }
        // Der Mini-Player als Zubehör der Tab Bar statt als eigene Leiste.
        // Er sitzt damit auf derselben Ebene wie die Navigation, statt eine
        // zweite Leiste darüber zu stapeln — und das System kümmert sich um
        // das Material, statt dass die App Glas auf Glas legt.
        .tabViewBottomAccessory { MiniPlayerAccessory() }
        .tabBarMinimizeBehavior(.onScrollDown)
        .animation(
            Design.Motion.respectingReduceMotion(Design.Motion.snappy,
                                                 reduceMotion: reduceMotion),
            value: model.playerPlan?.id
        )
        .overlay(alignment: .top) { ActivityBanner() }
    }
}

/// Was gerade läuft — kompakt, immer erreichbar.
///
/// Der Mini-Player zeigt und beendet. Er startet nie von sich aus etwas:
/// dafür gibt es keinen Knopf, weil es keine Freigabe gäbe.
struct MiniPlayerAccessory: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        if let plan = model.playerPlan, !plan.isEmpty {
            HStack(spacing: Design.Spacing.control) {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Design.Spacing.micro / 4) {
                    Text(plan.requestSummary)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle(for: plan))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: Design.Spacing.small)

                Button {
                    isPlaying ? model.pausePlayback() : model.resumePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isPlaying ? "Pausieren" : "Fortsetzen")

                Button {
                    model.stopPlayback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Wiedergabe beenden")
            }
            .padding(.horizontal, Design.Spacing.control)
        }
    }

    private var isPlaying: Bool { model.isPlaying }

    private func subtitle(for plan: ValidatedPlaybackPlan) -> String {
        let stellen = plan.segments.count == 1 ? "1 Stelle" : "\(plan.segments.count) Stellen"
        let quellen = plan.distinctSourceCount == 1
            ? "1 Quelle" : "\(plan.distinctSourceCount) Quellen"
        return "\(stellen) · \(quellen)"
    }
}

/// Eine Zeile, die sagt, was gerade passiert.
///
/// Kein endloser Kreisel: „es tut sich etwas“ ist keine Information. Hier
/// steht, *was* sich tut, und die Zeile verschwindet, wenn es vorbei ist.
struct ActivityBanner: View {

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let activity = model.activity {
            Text(activity)
                .font(.footnote)
                .padding(.horizontal, Design.Spacing.control)
                .padding(.vertical, Design.Spacing.small)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, Design.Spacing.small)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity)
                )
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

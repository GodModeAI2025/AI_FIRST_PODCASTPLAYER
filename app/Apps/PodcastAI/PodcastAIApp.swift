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
                }
                .alert("Der Speicher konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("Erneut versuchen") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
                .appFeedback()
                // Zuletzt, damit auch appFeedback und die Alerts das Modell sehen.
                .environment(model)
        }
    }
}

struct RootView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Area = .forYou

    /// Nicht `Tab` genannt: das verdeckte `SwiftUI.Tab` im eigenen
    /// Gültigkeitsbereich, und die Aufrufe darunter hätten versucht, das
    /// Enum als Funktion zu benutzen.
    enum Area: Hashable {
        case forYou, feeds, ask, library, knowledge
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Für dich", systemImage: "sparkles", value: Area.forYou) {
                NavigationStack { ForYouView() }
            }
            Tab("Meine Feeds", systemImage: "waveform.circle", value: Area.feeds) {
                NavigationStack { SmartFeedListView() }
            }
            // Eigener Such-Tab: die Rolle, die er seit WWDC25 hat.
            Tab("Fragen", systemImage: "magnifyingglass", value: Area.ask, role: .search) {
                NavigationStack { ChatView() }
            }
            Tab("Mediathek", systemImage: "books.vertical", value: Area.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Wissen", systemImage: "brain", value: Area.knowledge) {
                NavigationStack { KnowledgeHubView() }
            }
        }
        // Der Mini-Player als Zubehör der Tab Bar statt als eigene Leiste.
        // Er sitzt damit auf derselben Ebene wie die Navigation, statt eine
        // zweite Leiste darüber zu stapeln — und das System kümmert sich um
        // das Material, statt dass die App Glas auf Glas legt.
        .miniPlayerAccessory(isVisible: !(model.playerPlan?.isEmpty ?? true))
        .tabBarMinimizeBehavior(.onScrollDown)
        .animation(
            Design.Motion.respectingReduceMotion(Design.Motion.snappy,
                                                 reduceMotion: reduceMotion),
            value: model.playerPlan?.id
        )
        .overlay(alignment: .top) { ActivityBanner() }
    }
}

/// Blendet die Zubehörleiste nur ein, wenn etwas läuft. Ohne `isEnabled`
/// (vor iOS 26.1) bliebe eine leere Glasleiste über der Tab Bar stehen.
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isVisible) { MiniPlayerAccessory() }
        } else if isVisible {
            content.tabViewBottomAccessory { MiniPlayerAccessory() }
        } else {
            content
        }
    }
}

private extension View {
    func miniPlayerAccessory(isVisible: Bool) -> some View {
        modifier(MiniPlayerAccessoryModifier(isVisible: isVisible))
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

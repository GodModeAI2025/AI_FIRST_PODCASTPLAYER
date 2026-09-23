//
//  PodcastAIApp.swift
//  PodcastAI (iOS / iPadOS)
//
//  Fünf Bereiche, nicht sieben.
//
//  Die Tab Bar verträgt drei bis fünf Einträge. Bei sieben wird jeder
//  einzelne schmaler, die Beschriftungen brechen um, und der Nutzer muss
//  lesen statt zu erkennen. Interessen, Gegenpositionen und gesicherte
//  Antworten sind deshalb keine eigenen Tabs, sondern liegen unter
//  „Wissen“. Sie gehören inhaltlich zusammen und werden seltener gebraucht
//  als Hören und „Meine Podcasts“.
//
//  „Chat“ ist ein gewöhnlicher Tab ohne Such-Rolle. Hinter einer Lupe
//  erwartet man ein Suchfeld, hier wartet aber ein Gespräch über die eigenen
//  Podcasts. Sprechblasen und der Name sagen das gleich.
//

import SwiftUI
import PodcastAIKit

@main
struct PodcastAIApp: App {

    @State private var model: AppModel
    @State private var startupIssue: StartupIssue?

    /// Muss gehalten werden: `BGTaskScheduler` behält zwar die Startblöcke,
    /// aber die Planung der nächsten Ausführung läuft über dieses Objekt.
    private let background: BackgroundWork

    init() {
        let opened = AppBootstrap.openStore()
        let model = AppModel(store: LibraryStore.make(container: opened.container))
        model.syncDescription = opened.description
        _model = State(initialValue: model)
        _startupIssue = State(initialValue: StartupIssue(opened))
        // Hier und nicht in `.task`: Intent-Abhängigkeit, Audiositzung und
        // BGTask-Registrierung müssen stehen, bevor der Start fertig ist.
        self.background = AppBootstrap.start(with: model)
        // Einmal für die App, wie auf dem Mac. In `.task` lief das mit jeder
        // neu verbundenen Szene noch einmal. Baut iOS die Szene im
        // Hintergrund ab, während der Ton weiterläuft, lud danach jede
        // Änderung aus iCloud alles doppelt.
        Task {
            await model.ensureLoaded()
            model.observeRemoteChanges()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.ensureLoaded()
                    background.scheduleRefresh()
                    // Ohne diesen ersten Auftrag lief die Analyse-Aufgabe nie,
                    // und kein Themen-Update entstand im Hintergrund.
                    background.scheduleAnalysis()
                    // Erst nach dem Laden: vorher kennt das Modell keine
                    // Quellen, und die Aktualisierung beim Start fiele aus.
                    await AutoRefresh.run(for: model)
                }
                .startupIssueAlert($startupIssue)
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
    @State private var showingQueue = false
    @State private var showingOnboarding = OnboardingView.shouldShow
    /// „Zeig es mir“ aus der Hilfe: je Tab ein Zähler. Steigt er, baut der
    /// Tab seine Navigation neu auf und zeigt sich von vorn. Nur nötig, wenn
    /// die Hilfe im Ziel-Tab selbst liegt, sonst bliebe sie offen.
    @State private var stackResets: [Area: Int] = [:]

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
                    .activityBanner { showingQueue = true }
            }
            Tab("Themen-Updates", systemImage: "waveform.circle", value: Area.feeds) {
                NavigationStack { SmartFeedListView() }
                    .id(stackResets[.feeds, default: 0])
                    .activityBanner { showingQueue = true }
            }
            Tab("Meine Podcasts", systemImage: "books.vertical", value: Area.library) {
                NavigationStack { LibraryView() }
                    .id(stackResets[.library, default: 0])
                    .activityBanner { showingQueue = true }
            }
            Tab("Wissen", systemImage: "brain", value: Area.knowledge) {
                NavigationStack { KnowledgeHubView() }
                    .activityBanner { showingQueue = true }
            }
            // Keine Such-Rolle: hier wird gefragt, nicht gesucht. Der Chat
            // bleibt ganz rechts, wo früher die Lupe stand.
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: Area.ask) {
                NavigationStack { ChatView() }
                    .id(stackResets[.ask, default: 0])
                    .activityBanner { showingQueue = true }
            }
        }
        // Der Mini-Player als Zubehör der Tab Bar statt als eigene Leiste.
        // Er sitzt damit auf derselben Ebene wie die Navigation, statt eine
        // zweite Leiste darüber zu stapeln — und das System kümmert sich um
        // das Material, statt dass die App Glas auf Glas legt.
        .miniPlayerAccessory(isVisible: !(model.playerPlan?.isEmpty ?? true)
                             || model.episodePlayer.episode != nil)
        // Nie einklappen: der runde Restknopf lag beim Scrollen auf Text
        // und versteckte die übrigen Reiter, „Wissen“ war nicht zu treffen.
        .tabBarMinimizeBehavior(.never)
        .animation(
            Design.Motion.respectingReduceMotion(Design.Motion.snappy,
                                                 reduceMotion: reduceMotion),
            value: model.playerPlan?.id
        )
        .sheet(isPresented: $showingQueue) {
            NavigationStack {
                QueueView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fertig") { showingQueue = false }
                        }
                    }
            }
            // Abspielen und „Transkript erstellen“ gehen auch von hier aus.
            // Rückfrage und Fehler erscheinen dann über der Warteschlange.
            .sheetFeedback()
            .environment(model)
        }
        .autoRefresh()
        .spotlightPassages()
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView().sheetFeedback().environment(model)
        }
        .environment(\.showInApp, ShowInAppAction { jump in show(jump) })
    }

    // MARK: „Zeig es mir“ aus der Hilfe

    /// Wechselt in den Tab, den die Hilfe zeigen will. Was unter „Wissen“
    /// oder in den Einstellungen liegt, öffnet die Hilfe selbst.
    private func show(_ jump: HelpJump) {
        let area: Area
        switch jump {
        case .library: area = .library
        case .chat: area = .ask
        case .topicUpdates: area = .feeds
        case .queue:
            showingQueue = true
            return
        case .highlights, .trails, .counterpoints, .interests, .addPodcast, .settings, .privacy:
            return
        }
        // Meine Podcasts und Themen-Updates beginnen von vorn, dort geht
        // nichts verloren. Sonst läge dort noch die Folge oder die Hilfe von
        // vorhin. Der Chat nur, wenn die Hilfe in ihm liegt: eine laufende
        // Frage soll stehen bleiben.
        if area != .ask || selection == area { stackResets[area, default: 0] += 1 }
        selection = area
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

    func activityBanner(openQueue: @escaping @MainActor @Sendable () -> Void) -> some View {
        modifier(ActivityBannerInset(openQueue: openQueue))
    }
}

/// Stellt die Aktivitätszeile über die Navigation eines Tabs, nicht als
/// Overlay darauf. Das Overlay lag beim Erschließen auf Zurück, „Mehr“
/// und den Reitern einer Folge, und jeder Tipp dort öffnete die
/// Warteschlange.
///
/// Ein `safeAreaInset` reicht nicht: weder am TabView noch am
/// NavigationStack rückt die Navigationsleiste nach unten, die Zeile lag
/// dann wieder auf ihr. Im VStack beginnt der NavigationStack erst unter
/// der Zeile. Ohne Aktivität bleibt nur der NavigationStack übrig.
///
/// Auf dem iPad schwebt die Tab Bar oben und läge auf der Zeile. Bei
/// regulärer Breite steht sie deshalb unten.
private struct ActivityBannerInset: ViewModifier {
    let openQueue: @MainActor @Sendable () -> Void

    func body(content: Content) -> some View {
        // Kein Streifen mehr über dem Inhalt: das Symbol sitzt in der
        // Navigationsleiste der Ansichten (siehe `activityStatusToolbar`).
        content.environment(\.openQueue, openQueue)
    }
}

/// Was gerade läuft — kompakt, immer erreichbar.
///
/// Der Mini-Player zeigt und beendet. Er startet nie von sich aus etwas:
/// dafür gibt es keinen Knopf, weil es keine Freigabe gäbe.
struct MiniPlayerAccessory: View {

    @Environment(AppModel.self) private var model
    @State private var showingFocusPlayer = false

    var body: some View {
        if let plan = model.playerPlan, !plan.isEmpty {
            focusBar(plan)
        } else {
            EpisodeMiniBar()
        }
    }

    private func focusBar(_ plan: ValidatedPlaybackPlan) -> some View {
        Group {
            HStack(spacing: Design.Spacing.control) {
                // Ein Tipp auf die Leiste öffnet den Fokus-Player mit
                // Begründung, „Stelle überspringen“ und „Diese Stelle
                // merken“. In der Leiste selbst ist dafür kein Platz.
                Button { showingFocusPlayer = true } label: {
                    HStack(spacing: Design.Spacing.control) {
                        Image(systemName: "waveform")
                            .font(.body)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)

                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 4) {
                            Text(plan.requestSummary)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(subtitle(for: plan))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: Design.Spacing.small)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wiedergabe öffnen, \(plan.requestSummary)")
                .accessibilityValue(subtitle(for: plan))
                .accessibilityIdentifier("focusbar.open")

                Button {
                    isPlaying ? model.pausePlayback() : model.resumePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isPlaying ? "Pause" : "Fortsetzen")

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
            .sheet(isPresented: $showingFocusPlayer) {
                NavigationStack {
                    FocusPlayerView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Fertig") { showingFocusPlayer = false }
                            }
                        }
                }
                .sheetFeedback()
                .environment(model)
            }
        }
    }

    private var isPlaying: Bool { model.isPlaying }

    /// Als String, weil Anzeige und VoiceOver-Wert denselben Text brauchen.
    /// Einzahl und Mehrzahl regelt die Beugung, nicht der Code.
    private func subtitle(for plan: ValidatedPlaybackPlan) -> String {
        let passages = plan.segments.count
        let podcasts = plan.distinctSourceCount
        return String(AttributedString(
            localized: "^[\(passages) Stelle](inflect: true) · ^[\(podcasts) Podcast](inflect: true)"
        ).characters)
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
            // Eine Zeile. Lange Folgentitel werden in der Mitte gekürzt, damit
            // Anfang und „danach noch …“ lesbar bleiben. VoiceOver liest den
            // ganzen Text.
            Text(activity)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
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

//
//  MacRouting.swift
//  PodcastAI (macOS)
//
//  Wohin ein Fenster gerade zeigt: Eintrag in der Seitenleiste, der Stapel
//  jedes Eintrags und der Inspektor. Sprünge aus der Hilfe, Adressen aus dem
//  Widget und Menübefehle gehen alle durch `MacRouter.show`.
//

import SwiftUI
import PodcastAIKit

/// Ein Eintrag in der Seitenleiste.
///
/// Dieselben Namen wie die Tabs auf iOS, damit Hinweise wie
/// „Wissen › Meine Tags“ auf beiden Geräten stimmen.
enum SidebarItem: Hashable, Sendable {
    case forYou, feeds, library
    case chat, knowledge, trails, interests
    /// Nicht in der Seitenleiste, erreichbar über das Menü „Hilfe“.
    case help
    /// Ein einzelner Podcast aus dem Abschnitt „Podcasts“.
    case podcast(SourceID)

    /// Die festen Einträge in der Reihenfolge von ⌘1 bis ⌘7.
    static let numbered: [SidebarItem] = [.forYou, .feeds, .library, .chat, .knowledge, .trails, .interests]
    static let listening: [SidebarItem] = [.forYou, .feeds, .library]
    static let knowledgeItems: [SidebarItem] = [.chat, .knowledge, .trails, .interests]

    var label: LocalizedStringKey {
        switch self {
        case .forYou: "Für dich"
        case .feeds: "Themen-Updates"
        case .library: "Meine Podcasts"
        case .chat: "Chat"
        case .knowledge: "Gemerkte Stellen"
        case .trails: "Gesicherte Antworten"
        case .interests: "Meine Tags"
        case .help: "So funktioniert's"
        case .podcast: "Podcast"
        }
    }

    /// `sparkles` bleibt Apple Intelligence vorbehalten.
    var symbol: String {
        switch self {
        case .forYou: "rectangle.stack"
        case .feeds: "waveform.circle"
        case .library: "books.vertical"
        case .chat: "bubble.left.and.bubble.right"
        case .knowledge: "bookmark"
        case .trails: "map"
        case .interests: "tag"
        case .help: "questionmark.circle"
        case .podcast: "mic"
        }
    }

    // MARK: Gespeichert je Fenster

    /// Als Text für `@SceneStorage`: „forYou“ oder „podcast:<Kennung>“.
    var storageValue: String {
        switch self {
        case .forYou: "forYou"
        case .feeds: "feeds"
        case .library: "library"
        case .chat: "chat"
        case .knowledge: "knowledge"
        case .trails: "trails"
        case .interests: "interests"
        case .help: "help"
        case .podcast(let id): "podcast:" + id.rawValue
        }
    }

    /// Liest den gespeicherten Eintrag. „queue“ und „player“ gab es bis
    /// 0.13 in der Seitenleiste; beide liegen jetzt im Inspektor und in der
    /// Symbolleiste, das Fenster beginnt dann bei „Für dich“.
    init(storageValue: String) {
        switch storageValue {
        case "feeds": self = .feeds
        case "library": self = .library
        case "chat": self = .chat
        case "knowledge": self = .knowledge
        case "trails": self = .trails
        case "interests": self = .interests
        case "help": self = .help
        default:
            if storageValue.hasPrefix("podcast:") {
                let raw = String(storageValue.dropFirst("podcast:".count))
                self = raw.isEmpty ? .forYou : .podcast(SourceID(rawValue: raw))
            } else {
                self = .forYou
            }
        }
    }
}

/// Seiten, die der Mac nach Wert auf einen Stapel legt, etwa über
/// „Aktuelle Folge anzeigen“ oder die Auswahl in einer Liste.
enum MacRoute: Hashable {
    case episode(Episode)
    case sourceInfo(SourceID)
}

/// Was der Inspektor zeigt.
enum InspectorMode: Hashable {
    case upNext, info
}

/// Worüber „Informationen“ im Inspektor spricht. Die Seite meldet es,
/// solange sie zu sehen ist.
enum InfoSubject: Hashable {
    case source(SourceID)
    case episode(Episode)
}

/// Navigation eines Fensters. Nur der Eintrag der Seitenleiste überlebt
/// einen Neustart; die Stapel bleiben im Speicher, solange das Fenster offen ist.
@MainActor
@Observable
final class MacRouter {

    var selection: SidebarItem? = .forYou
    private(set) var paths: [SidebarItem: NavigationPath] = [:]
    var isInspectorPresented = false
    var inspectorMode: InspectorMode = .upNext
    /// Die Seite, deren Informationen der Inspektor zeigen kann.
    private(set) var infoSubject: InfoSubject?
    /// Die Tag-Seite, die eine Adresse aus dem Widget unter den
    /// Themen-Updates öffnen will.
    var linkedTag: InterestID?

    /// Der Stapel eines Eintrags, als Bindung für `NavigationStack(path:)`.
    func path(for item: SidebarItem) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[item] ?? NavigationPath() },
            set: { self.paths[item] = $0 }
        )
    }

    /// Wählt den Eintrag und beginnt seinen Stapel von vorn. Andere
    /// Einträge behalten ihren Stapel.
    func show(_ item: SidebarItem, push route: MacRoute? = nil) {
        selection = item
        var path = NavigationPath()
        if let route { path.append(route) }
        paths[item] = path
    }

    /// Legt eine Seite auf den Stapel des Eintrags, der gerade gewählt ist.
    func push(_ route: MacRoute) {
        guard let item = selection else { return }
        paths[item, default: NavigationPath()].append(route)
    }

    /// Eine Seite zurück, etwa mit Esc.
    func pop() {
        guard let item = selection, var path = paths[item], !path.isEmpty else { return }
        path.removeLast()
        paths[item] = path
    }

    func toggleInspector(_ mode: InspectorMode) {
        if isInspectorPresented && inspectorMode == mode {
            isInspectorPresented = false
        } else {
            inspectorMode = mode
            isInspectorPresented = true
        }
    }

    func report(_ subject: InfoSubject) { infoSubject = subject }

    func withdraw(_ subject: InfoSubject) {
        if infoSubject == subject { infoSubject = nil }
    }

    // MARK: Sprünge

    /// „Zeig es mir“ aus der Hilfe. Blatt, Einstellungsfenster und
    /// Datenschutz öffnet die Hilfe selbst.
    func jump(to jump: HelpJump) {
        switch jump {
        case .library: show(.library)
        case .chat: show(.chat)
        case .topicUpdates: show(.feeds)
        case .highlights: show(.knowledge)
        case .trails: show(.trails)
        case .interests: show(.interests)
        case .queue:
            inspectorMode = .upNext
            isInspectorPresented = true
        case .addPodcast, .settings, .privacy, .agentAccess: return
        }
    }

    /// `podcastai://topicupdates` öffnet die Themen-Updates,
    /// `podcastai://tag/<Kennung>` dort die Seite des Tags. Beides zeigt
    /// nur, keine Adresse spielt etwas ab. Unbekannte Adressen bleiben
    /// ohne Wirkung.
    func open(_ url: URL) {
        guard let link = WidgetLink(url: url) else { return }
        if case .tag(let id) = link {
            linkedTag = InterestID(rawValue: id)
        } else {
            linkedTag = nil
        }
        show(.feeds)
    }
}

extension FocusedValues {
    /// Die Navigation des vorderen Fensters, für die Menübefehle.
    @Entry var router: MacRouter?
}

/// Meldet dem Inspektor, worüber die Seite spricht, solange sie zu sehen ist.
struct MacInfoSubjectModifier: ViewModifier {

    let subject: InfoSubject
    @Environment(MacRouter.self) private var router: MacRouter?

    func body(content: Content) -> some View {
        content
            .onAppear { router?.report(subject) }
            .onDisappear { router?.withdraw(subject) }
    }
}

extension View {
    /// Nur auf dem Mac: „Informationen“ im Inspektor zeigt diese Seite.
    func macInfoSubject(_ subject: InfoSubject) -> some View {
        modifier(MacInfoSubjectModifier(subject: subject))
    }
}

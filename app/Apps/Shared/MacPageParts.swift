//
//  MacPageParts.swift
//  PodcastAI
//
//  Bausteine für die Mac-Seiten jenseits von „Meine Tags“: Seitenrahmen mit
//  lesbarer Breite, Abschnittskopf mit Zahl und einem Satz, Karten mit
//  Hover, Druck und Fokus, ruhige Leerzustände. Nur macOS. Die iPhone-Listen
//  bleiben, wie sie sind.
//
//  Nichts hier spielt Ton. Karten öffnen, Abspielen ist immer ein eigener Knopf.
//

#if os(macOS)
import SwiftUI

/// Der Rahmen einer Mac-Seite: scrollt, Inhalt links ausgerichtet bis zur
/// lesbaren Höchstbreite, mit Rand zum Fenster.
struct MacPage<Content: View>: View {

    /// Höchstbreite des Inhalts. Raster bekommen mehr Platz als Fließtext.
    static var contentWidth: CGFloat { 960 }

    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                content()
            }
            .frame(maxWidth: Self.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Design.Spacing.section)
        }
        .contentMargins(.horizontal, Design.Spacing.large, for: .scrollContent)
    }
}

/// Kopf eines Abschnitts: Titel, Zahl daneben, darunter ein Satz, was folgt.
/// Rechts kann ein Weg stehen, etwa „Tags bearbeiten“.
struct MacSectionHeader<Trailing: View>: View {

    let title: Text
    let count: Int?
    let note: Text?
    let trailing: Trailing

    init(title: Text, count: Int? = nil, note: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.count = count
        self.note = note
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                    title.font(.title3.weight(.semibold))
                    if let count {
                        Text(count, format: .number)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if let note {
                    note.font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Design.Spacing.small)
            trailing
        }
    }
}

extension MacSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, count: Int? = nil, note: LocalizedStringKey? = nil) {
        self.init(title: Text(title), count: count, note: note.map { Text($0) }) { EmptyView() }
    }

    init(title: Text, count: Int? = nil, note: Text? = nil) {
        self.init(title: title, count: count, note: note) { EmptyView() }
    }
}

/// Ein Abschnitt: Kopf, darunter der Inhalt.
struct MacSection<Header: View, Content: View>: View {

    let header: Header
    let content: Content

    init(header: Header, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            header
            content
        }
    }
}

/// Raster aus Karten: Spalten wachsen bis zur Höchstbreite, dann kommt eine
/// Spalte dazu.
enum MacGrid {
    static func columns(minimum: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: Design.Spacing.control, alignment: .top)]
    }
}

/// Flächen und Zustände einer Karte: ruhig im Ruhezustand, etwas heller
/// beim Überfahren, dunkler beim Drücken, mit Akzentrand für einen Zustand.
/// Den Fokusring zeichnet das System um den Knopf.
struct MacCardChrome: ViewModifier {

    var hovering = false
    var pressed = false
    /// Ein Zustand, etwa „läuft“ oder „neu“: Akzentfarbe statt Grau.
    var accent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? 0.992 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }

    private var fill: Color {
        if accent { return Color.accentColor.opacity(pressed ? 0.20 : hovering ? 0.16 : 0.10) }
        return Color.primary.opacity(pressed ? 0.12 : hovering ? 0.08 : 0.05)
    }

    private var stroke: Color {
        if accent { return Color.accentColor.opacity(hovering ? 0.5 : 0.3) }
        return Color.primary.opacity(hovering ? 0.16 : 0.08)
    }
}

extension View {
    /// Eine ruhige Karte ohne Interaktion, etwa für einen Hinweis.
    func macCard(accent: Bool = false) -> some View {
        modifier(MacCardChrome(accent: accent))
    }
}

/// Stil für Karten, die ein Knopf oder Link sind. Hover und Druck stecken
/// im Stil, damit der Link darin seine Wirkung behält.
struct MacCardButtonStyle: ButtonStyle {

    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, accent: accent)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let accent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .modifier(MacCardChrome(hovering: hovering, pressed: configuration.isPressed, accent: accent))
                .onHover { hovering = $0 }
        }
    }
}

/// Hover für eine Karte, die selbst kein Knopf ist, etwa weil mehrere
/// Knöpfe darin liegen.
struct MacHoverCard<Content: View>: View {

    var accent = false
    let content: Content
    @State private var hovering = false

    init(accent: Bool = false, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .modifier(MacCardChrome(hovering: hovering, accent: accent))
            .onHover { hovering = $0 }
    }
}

/// Ein runder Abspielknopf, gefüllt in der Akzentfarbe. Er spielt nur auf
/// einen Klick, nie von selbst.
struct MacPlayButton: View {

    let label: LocalizedStringKey
    var symbol = "play.fill"
    var size: CGFloat = 36
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.accentColor.opacity(hovering ? 1 : 0.88)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// Leerzustand: ein Symbol, eine Überschrift, ein Satz, bei Bedarf ein Knopf.
struct MacEmptyState<Actions: View>: View {

    let title: LocalizedStringKey
    let symbol: String
    let sentence: LocalizedStringKey
    let actions: Actions
    /// Steht der Leerzustand unter anderem Inhalt, braucht er weniger Höhe.
    let minHeight: CGFloat

    init(_ title: LocalizedStringKey, symbol: String, sentence: LocalizedStringKey, minHeight: CGFloat = 340,
         @ViewBuilder actions: () -> Actions) {
        self.minHeight = minHeight
        self.title = title
        self.symbol = symbol
        self.sentence = sentence
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(sentence)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

extension MacEmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String, sentence: LocalizedStringKey, minHeight: CGFloat = 340) {
        self.init(title, symbol: symbol, sentence: sentence, minHeight: minHeight) { EmptyView() }
    }
}
#endif

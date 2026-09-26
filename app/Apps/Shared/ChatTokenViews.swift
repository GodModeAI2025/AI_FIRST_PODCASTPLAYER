//
//  ChatTokenViews.swift
//  PodcastAI
//
//  Tokens, Vorschläge und letzte Fragen über dem Eingabefeld des Chats.
//
//  SwiftUI kennt Tokens nur im Suchfeld (`searchable(text:tokens:)`), und
//  das sitzt immer in der Navigation oder Seitenleiste. Das Fragefeld liegt
//  unten und steht auch im Reiter „Fragen“ einer Folge. Deshalb stehen die
//  Tokens als Chips über dem Feld. Ein Tipp nimmt ein Token heraus, am Mac
//  auch die Rückschritttaste im leeren Feld (`BackspaceRemovesToken`).
//
//  Nichts hier sendet eine Frage oder spielt etwas ab. Ein Vorschlag setzt
//  ein Token, eine letzte Frage kommt nur ins Feld.
//

import SwiftUI
import PodcastAIKit
#if os(macOS)
import AppKit
#endif

/// Ein Token oder ein Vorschlag mit seiner Beschriftung.
struct LabeledChatToken: Identifiable {
    let token: ChatToken
    let label: String
    /// Beim Vorschlag der Text, der danach im Feld steht.
    var remainingText: String?
    var id: String { token.id }
}

extension ChatToken {
    /// Symbol je Art, gleich für Token und Vorschlag.
    var symbol: String {
        switch kind {
        case .source: "antenna.radiowaves.left.and.right"
        case .date: "calendar"
        case .tag: "tag"
        case .episode: "waveform"
        }
    }
}

/// Die gesetzten Tokens als Chips. Ein Tipp nimmt ein Token heraus.
struct ChatTokenBar: View {
    let tokens: [LabeledChatToken]
    let remove: (ChatToken) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Spacing.small) {
                ForEach(tokens) { item in
                    Button { remove(item.token) } label: {
                        HStack(spacing: Design.Spacing.micro) {
                            Image(systemName: item.token.symbol)
                                .accessibilityHidden(true)
                            Text(item.label)
                                .lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .font(.callout)
                        .padding(.horizontal, Design.Spacing.control)
                        .padding(.vertical, Design.Spacing.small)
                        .background(.tint.opacity(0.15), in: .capsule)
                        .frame(minHeight: Design.minimumTapTarget)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityHint("Entfernt diese Eingrenzung")
                    .accessibilityIdentifier("chat.token")
                }
            }
            .padding(.horizontal, Design.Spacing.control)
        }
        .scrollIndicators(.hidden)
    }
}

/// Vorschläge, während jemand tippt. Ein Tipp setzt das Token und nimmt das
/// erkannte Stück aus dem Feld.
struct ChatTokenSuggestionBar: View {
    let suggestions: [LabeledChatToken]
    let accept: (LabeledChatToken) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Spacing.small) {
                ForEach(suggestions) { item in
                    Button { accept(item) } label: {
                        HStack(spacing: Design.Spacing.micro) {
                            Image(systemName: "plus.circle")
                                .accessibilityHidden(true)
                            Text(item.label)
                                .lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.horizontal, Design.Spacing.control)
                        .padding(.vertical, Design.Spacing.small)
                        .overlay(Capsule().strokeBorder(.tint.opacity(0.5)))
                        .frame(minHeight: Design.minimumTapTarget)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityHint("Grenzt die Frage darauf ein")
                    .accessibilityIdentifier("chat.tokenSuggestion")
                }
            }
            .padding(.horizontal, Design.Spacing.control)
        }
        .scrollIndicators(.hidden)
    }
}

/// Die letzten Fragen dieses Geräts, solange das Feld leer ist und den
/// Cursor hat. Ein Tipp setzt die Frage ins Feld, gesendet wird nichts.
struct RecentQuestionsPanel: View {
    let questions: [String]
    let choose: (String) -> Void
    let clear: () -> Void

    /// Höhe einer Zeile, mit der Schriftgröße wachsend. Mehr als vier und
    /// eine halbe Zeile scrollen, damit über der Tastatur Platz bleibt.
    @ScaledMetric private var rowHeight = Design.minimumTapTarget

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            HStack {
                Text("Letzte Fragen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Löschen", action: clear)
                    .font(.caption)
                    .frame(minHeight: Design.minimumTapTarget)
                    .accessibilityLabel("Letzte Fragen löschen")
                    .accessibilityIdentifier("chat.recent.clear")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.none) {
                    ForEach(questions, id: \.self) { text in
                        Button { choose(text) } label: {
                            Label {
                                Text(text).lineLimit(1)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(text)
                        .accessibilityHint("Setzt die Frage ins Eingabefeld, ohne sie zu senden")
                        .accessibilityIdentifier("chat.recent")
                    }
                }
            }
            .frame(height: min(CGFloat(questions.count), 4.5) * rowHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.small)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .padding(.horizontal, Design.Spacing.control)
    }
}

#if os(macOS)
/// Rückschritt im leeren Fragefeld nimmt am Mac das letzte Token heraus.
///
/// `onKeyPress(.delete)` am Feld kommt nicht an: Der Feldeditor von AppKit
/// verbraucht die Taste, auch wenn das Feld leer ist. Deshalb hört ein
/// lokaler Monitor mit, nur solange das Feld den Cursor hat. `action` sagt,
/// ob die Taste damit erledigt ist; sonst geht sie weiter ans Feld.
///
/// Ein lokaler Monitor sieht die Tasten aller Fenster der App. Er greift
/// deshalb nur im Fenster dieses Felds, nicht in einem zweiten Chat oder
/// in den Einstellungen, und nicht, solange eine Eingabe noch offen ist,
/// etwa ein Akzent über eine Tottaste.
struct BackspaceRemovesToken: ViewModifier {
    let isActive: Bool
    let action: () -> Bool
    @State private var monitor: Any?
    @State private var host = HostWindow()

    func body(content: Content) -> some View {
        content
            .background(HostWindowReader(host: host))
            .onChange(of: isActive, initial: true) { _, active in
                if active { install() } else { uninstall() }
            }
            .onDisappear(perform: uninstall)
    }

    /// Tastencode der Rückschritttaste, unabhängig von der Belegung.
    private static let backspaceKeyCode: UInt16 = 51

    private func install() {
        guard monitor == nil else { return }
        let action = action
        let host = host
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            guard event.keyCode == Self.backspaceKeyCode, modifiers.isEmpty,
                  let window = host.window, event.window === window,
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }
            return action() ? nil : event
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Das Fenster, in dem das Fragefeld steht.
@MainActor final class HostWindow {
    weak var window: NSWindow?
}

/// Meldet `HostWindow`, in welchem Fenster die Ansicht gerade liegt.
private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> Probe { Probe(host: host) }
    func updateNSView(_ view: Probe, context: Context) {
        view.host = host
        host.window = view.window
    }

    final class Probe: NSView {
        var host: HostWindow

        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// Nur zum Mithören, Klicks gehen ans Feld.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}
#endif

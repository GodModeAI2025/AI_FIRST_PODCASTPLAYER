//
//  DesignSystem.swift
//  PodcastAI
//
//  Die gestalterischen Festlegungen an einer Stelle.
//
//  Warum als Tokens und nicht als Zahlen im Code: eine App, in der an
//  dreißig Stellen `padding(12)` steht, driftet. Nach ein paar Wochen ist
//  es an zehn Stellen 12, an zwölf Stellen 14 und an acht Stellen 16 — und
//  niemand weiß mehr, welcher Wert der richtige war.
//
//  Grundlage ist Apples 8-Punkt-Raster. Alle Abstände sind Vielfache von 4,
//  die meisten von 8.
//

import SwiftUI
import PodcastAIKit

public enum Design {

    // MARK: - Abstände (8pt-Raster)

    public enum Spacing {
        /// 0pt — bewusst kein Abstand, etwa zwischen Inhalt und angrenzender
        /// Trennlinie. Als Token, damit erkennbar bleibt, dass die Null
        /// gewollt ist und nicht vergessen wurde.
        public static let none: CGFloat = 0
        /// 4pt — feinste Anpassung, etwa zwischen Zeile und Bildunterschrift.
        public static let micro: CGFloat = 4
        /// 8pt — Basiseinheit.
        public static let small: CGFloat = 8
        /// 12pt — Innenabstand von Steuerelementen.
        public static let control: CGFloat = 12
        /// 16pt — Standardrand für Inhalte.
        public static let standard: CGFloat = 16
        /// 20pt — kleine Abschnittstrennung.
        public static let section: CGFloat = 20
        /// 32pt — große Abstände.
        public static let large: CGFloat = 32
        /// 48pt — großzügige Trennung, etwa um leere Zustände.
        public static let generous: CGFloat = 48
    }

    // MARK: - Eckenradien

    /// Konzentrische Radien: ein Element **in** einem anderen bekommt einen
    /// kleineren Radius, und zwar genau um seinen Randabstand kleiner.
    /// Sonst laufen die Kurven nicht parallel und es sieht schief aus,
    /// ohne dass man sagen könnte warum.
    public enum Radius {
        public static let card: CGFloat = 16
        public static let control: CGFloat = 10
        public static let chip: CGFloat = 8

        /// Der passende Innenradius zu einem Außenradius bei gegebenem Abstand.
        public static func inner(outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(0, outer - inset)
        }
    }

    // MARK: - Treffflächen

    /// Apples Mindestmass. Alles, was angetippt wird, ist mindestens so groß —
    /// auch wenn das Symbol darin kleiner ist.
    public static let minimumTapTarget: CGFloat = 44

    // MARK: - Bewegung

    /// Apple animiert mit Federn, nicht mit Bezierkurven. Der Unterschied ist
    /// hörbar körperlich: eine Feder hat Masse und Reibung, eine Kurve nicht.
    public enum Motion {
        /// Ohne Nachschwingen. Standard für Übergänge und Navigation.
        public static let smooth = Animation.smooth(duration: 0.5)
        /// Leichtes Nachschwingen. Für Knöpfe und Umschalter.
        public static let snappy = Animation.snappy(duration: 0.35, extraBounce: 0.15)
        /// Deutliches Nachschwingen. Für Blätter und Modale.
        public static let bouncy = Animation.bouncy(duration: 0.5, extraBounce: 0.3)

        /// Die Fassung, die `Reduce Motion` respektiert.
        ///
        /// Nicht „keine Animation“: ein abruptes Erscheinen ist auch eine
        /// Zumutung. Stattdessen eine kurze Überblendung ohne Bewegung.
        public static func respectingReduceMotion(
            _ animation: Animation, reduceMotion: Bool
        ) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.2) : animation
        }
    }

    // MARK: - Tiefe

    /// Materialien für die Navigationsebene.
    ///
    /// Regel aus der Designsprache: Glas gehört über den Inhalt, nicht in
    /// ihn hinein — und niemals Glas auf Glas. Ein Blatt über einer
    /// Glasleiste bekommt deshalb eine Füllung, keine zweite Glasschicht.
    public enum Surface {
        public static let navigation: Material = .bar
        public static let sheet: Material = .regular
        public static let card: Material = .thin
    }

    // MARK: - Hinweise

    /// Die zwei Arten von Hinweisen in der App. Mehr gibt es nicht.
    ///
    /// Früher stand fast alles in Orange: ein gescheiterter Download genauso
    /// wie „keine Gegenposition gefunden“ oder ein Satz dazu, was ein
    /// YouTube-Kanal nicht liefert. Man konnte nicht sehen, ob etwas kaputt
    /// ist oder nur erklärt wird. Jetzt trägt nur eine echte Störung Farbe.
    public enum Notice: Sendable {
        /// Sagt, was passiert ist oder warum etwas fehlt. Kein Fehler, nichts
        /// zu tun: graue Schrift, ein „i“ davor.
        case info
        /// Etwas ist schiefgegangen und braucht einen neuen Versuch oder eine
        /// Entscheidung: rotes Warndreieck. Die Schrift bleibt in der
        /// Grundfarbe, damit sie auch klein gut lesbar ist.
        case failure

        public var symbol: String {
            switch self {
            case .info: "info.circle"
            case .failure: "exclamationmark.triangle.fill"
            }
        }

        /// Die Farbe des Symbols. Für einen Zustand, der nur aus Symbol und
        /// kurzem Wort besteht, auch die des Worts.
        public var tint: Color {
            switch self {
            case .info: .secondary
            case .failure: .red
            }
        }

        /// Die Farbe des Texts neben dem Symbol.
        public var textStyle: HierarchicalShapeStyle {
            switch self {
            case .info: .secondary
            case .failure: .primary
            }
        }
    }
}

// MARK: - Modifier

public extension View {

    /// Sorgt dafür, dass ein Element mindestens 44×44 Punkt zum Antippen hat,
    /// ohne es optisch zu vergrößern.
    func tappableArea() -> some View {
        frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
    }

    /// Eine Karte auf der Inhaltsebene.
    func contentCard() -> some View {
        padding(Design.Spacing.standard)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(
                cornerRadius: Design.Radius.card, style: .continuous
            ))
    }
}

/// Rückmeldung beim Drücken.
///
/// Apple verkleinert leicht und nimmt etwas Deckkraft — nicht mehr. Ein
/// Knopf, der beim Drücken hüpft, lenkt vom Ergebnis ab; einer, der gar
/// nicht reagiert, lässt einen zweifeln, ob man getroffen hat.
public struct PressableButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        // Der Rumpf liegt in einer eigenen View, nicht direkt hier.
        //
        // `ButtonStyle` ist kein `View` und kein `DynamicProperty`-Container:
        // ein `@Environment` darin wird nie befüllt und bleibt stumm beim
        // Standardwert. Ausgerechnet „Bewegung reduzieren“ wäre damit für
        // jeden Knopf der App wirkungslos gewesen — die eine Zusage, die
        // dieser Stil überhaupt macht.
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {

        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// Ein eigener Stil blendet einen gesperrten Knopf nicht von selbst
        /// ab. Ohne das sah „Nächstes Kapitel“ in einer Folge ohne Kapitel
        /// bedienbar aus und tat beim Antippen nichts.
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)
                .animation(
                    Design.Motion.respectingReduceMotion(
                        Design.Motion.snappy, reduceMotion: reduceMotion
                    ),
                    value: configuration.isPressed
                )
        }
    }
}

public extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Hinweis

/// Ein Hinweis in einer der zwei Arten aus ``Design/Notice``.
///
/// Symbol **und** Text, nie Farbe allein. Die Schriftgröße bestimmt der
/// Aufrufer mit `.font(_:)`.
///
/// Mit `explanation` wird der Hinweis zu einem Knopf: Das „i“ wird farbig,
/// und ein Tipp zeigt die Erklärung darunter. Oben steht in einem Satz, was
/// passiert ist, das Warum nur für den, der es wissen will.
public struct NoticeLabel: View {

    private let title: Text
    private let kind: Design.Notice
    private let explanation: Text?
    @State private var showsExplanation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: Text, kind: Design.Notice = .info, explanation: Text? = nil) {
        self.title = title
        self.kind = kind
        self.explanation = explanation
    }

    public init(_ title: LocalizedStringKey, kind: Design.Notice = .info) {
        self.init(Text(title), kind: kind)
    }

    /// Für Texte, die schon übersetzt als `String` ankommen, etwa Gründe
    /// aus dem Modell oder aus dem Netz. Sie stehen wörtlich da.
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, kind: Design.Notice = .info, explanation: String? = nil) {
        self.init(Text(title), kind: kind, explanation: explanation.map { Text($0) })
    }

    public var body: some View {
        if let explanation {
            Button {
                withAnimation(Design.Motion.respectingReduceMotion(Design.Motion.smooth, reduceMotion: reduceMotion)) {
                    showsExplanation.toggle()
                }
            } label: {
                label(explanation: showsExplanation ? explanation : nil)
                    .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsExplanation
                ? Text("Blendet die Erklärung aus")
                : Text("Zeigt die Erklärung"))
        } else {
            label(explanation: nil)
        }
    }

    private func label(explanation: Text?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                title
                    .foregroundStyle(kind.textStyle)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation {
                    explanation
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        } icon: {
            // Mit Erklärung ist das „i“ der Knopf und trägt die Farbe der App.
            Image(systemName: self.explanation != nil && kind == .info
                  ? (showsExplanation ? "info.circle.fill" : "info.circle")
                  : kind.symbol)
                .foregroundStyle(self.explanation != nil && kind == .info
                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(kind.tint))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Umbrechende Reihe

/// Legt Elemente nebeneinander wie Wörter in einem Absatz. Was nicht mehr
/// in die Zeile passt, beginnt die nächste.
///
/// Für Schlagworte und andere Chips. Seitlich gescrollt sah man nur die
/// ersten drei, und dass es weitergeht, war nicht zu erkennen. Ein Chip,
/// der allein breiter ist als die Zeile, bekommt eine eigene Zeile und
/// bricht seinen Text um, etwa bei sehr großer Schrift.
public struct FlowLayout: Layout {

    /// Abstand zwischen zwei Elementen einer Zeile.
    public var spacing: CGFloat
    /// Abstand zwischen zwei Zeilen.
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = Design.Spacing.small, lineSpacing: CGFloat = Design.Spacing.small) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(rows.count - 1)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                // In der Zeile mittig, falls Elemente verschieden hoch sind.
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Teilt die Elemente in Zeilen. Jedes Element bekommt höchstens die
    /// ganze Breite angeboten, so bricht ein zu langer Text in sich um.
    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        let offer = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(offer)
            size.width = min(size.width, width)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// Ein Zeitcode in der Oberfläche.
///
/// Immer mit gleichen Ziffernbreiten: sonst zappelt die Zahl beim Laufen der
/// Wiedergabe, weil die Eins schmaler ist als die Null.
public struct TimecodeLabel: View {

    private let text: String
    private let emphasis: Font.Weight

    public init(_ range: MediaTimeRange, emphasis: Font.Weight = .regular) {
        self.text = "\(range.start.timecode)–\(range.end.timecode)"
        self.emphasis = emphasis
    }

    public init(_ time: MediaTime, emphasis: Font.Weight = .regular) {
        self.text = time.timecode
        self.emphasis = emphasis
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(emphasis).monospacedDigit())
            .foregroundStyle(.secondary)
            // Für VoiceOver ausgeschrieben: „12 Minuten und 14 Sekunden“ statt „12 Doppelpunkt 14“.
            .accessibilityLabel(Self.spoken(text))
    }

    static func spoken(_ timecode: String) -> String {
        let parts = timecode.split(separator: "–")
        guard parts.count == 2 else { return spokenSingle(String(timecode)) }
        let start = spokenSingle(String(parts[0]))
        let end = spokenSingle(String(parts[1]))
        return String(localized: "von \(start) bis \(end)")
    }

    /// „4 Minuten“, „1 Minute und 5 Sekunden“, „1 Stunde und 2 Minuten“.
    /// Volle Minuten ohne eine „0“ dahinter, und Sekunden heißen Sekunden.
    /// Einzahl, Mehrzahl und Wortstellung kommen aus der Sprache der App.
    static func spokenSingle(_ value: String) -> String {
        let units = value.split(separator: ":").map(String.init)
        let numbers = units.compactMap { Int($0) }
        guard numbers.count == units.count, (2...3).contains(numbers.count) else { return value }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

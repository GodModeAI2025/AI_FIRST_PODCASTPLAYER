//
//  DesignSystem.swift
//  PodcastAI
//
//  Die gestalterischen Festlegungen an einer Stelle.
//
//  Warum als Tokens und nicht als Zahlen im Code: eine App, in der an
//  dreissig Stellen `padding(12)` steht, driftet. Nach ein paar Wochen ist
//  es an zehn Stellen 12, an zwölf Stellen 14 und an acht Stellen 16 — und
//  niemand weiss mehr, welcher Wert der richtige war.
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
        /// 32pt — grosse Abstände.
        public static let large: CGFloat = 32
        /// 48pt — grosszügige Trennung, etwa um leere Zustände.
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

        /// Der passende Innenradius zu einem Aussenradius bei gegebenem Abstand.
        public static func inner(outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(0, outer - inset)
        }
    }

    // MARK: - Treffflächen

    /// Apples Mindestmass. Alles, was angetippt wird, ist mindestens so gross —
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
}

// MARK: - Modifier

public extension View {

    /// Sorgt dafür, dass ein Element mindestens 44×44 Punkt zum Antippen hat,
    /// ohne es optisch zu vergrössern.
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

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.7 : 1)
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
            // Für VoiceOver ausgeschrieben: „12 Minuten 14“ statt „12 Doppelpunkt 14“.
            .accessibilityLabel(Self.spoken(text))
    }

    static func spoken(_ timecode: String) -> String {
        let parts = timecode.split(separator: "–")
        guard parts.count == 2 else { return spokenSingle(String(timecode)) }
        return "von \(spokenSingle(String(parts[0]))) bis \(spokenSingle(String(parts[1])))"
    }

    static func spokenSingle(_ value: String) -> String {
        let units = value.split(separator: ":").map(String.init)
        switch units.count {
        case 2: return "\(units[0]) Minuten \(units[1])"
        case 3: return "\(units[0]) Stunden \(units[1]) Minuten \(units[2])"
        default: return value
        }
    }
}

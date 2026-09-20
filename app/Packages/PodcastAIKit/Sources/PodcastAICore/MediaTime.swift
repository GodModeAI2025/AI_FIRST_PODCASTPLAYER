//
//  MediaTime.swift
//  PodcastAICore
//
//  Zeit *im Medium*, nicht Wanduhrzeit.
//
//  Bewusst als ganzzahlige Millisekunden statt als Double modelliert:
//  Vereinigung, Subtraktion und Deduplizierung von Intervallen müssen exakt
//  und reproduzierbar sein. Mit Double driften Grenzen, und zwei Geräte
//  kommen bei derselben Rechnung zu verschiedenen Ergebnissen — genau das,
//  was ein geräteübergreifender Hörzustand nicht verträgt.
//
//  Die Umrechnung nach CMTime findet ausschließlich in der Apple-Schicht
//  statt. Dieser Typ kennt AVFoundation nicht.
//

import Foundation

/// Rechenregeln, die nicht abstürzen dürfen.
///
/// Jede Zahl hier kommt am Ende aus einem fremden Feed: `<itunes:duration>`,
/// ein Kapitelmarker, ein `expectedContentLength`. `Int64(1e300)` ist in
/// Swift kein großer Wert, sondern ein Laufzeitabsturz — und ein Absturz,
/// den ein Fremder auslösen kann, ist ein Fehler, keine Randnotiz.
/// Deshalb sättigt hier jede Umrechnung und jede Addition, statt zu fallen.
enum SaturatingTime {

    /// Sekunden als Double in Millisekunden, ohne Falle.
    static func milliseconds(fromSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = (seconds * 1000).rounded()
        // `Double(Int64.max)` rundet auf 2^63 auf und liegt damit *über*
        // `Int64.max`; der strikte Vergleich ist deshalb der richtige.
        guard value < Double(Int64.max) else { return .max }
        return Int64(value)
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    static func multiplying(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return product }
        // Vorzeichen erhalten: ein Überlauf nach oben wird zur Obergrenze,
        // einer nach unten zur Untergrenze.
        return (lhs < 0) == (rhs < 0) ? Int64.max : Int64.min
    }
}

/// Ein Zeitpunkt innerhalb einer konkreten Medienfassung, in Millisekunden ab Medienbeginn.
public struct MediaTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    /// Millisekunden ab Medienbeginn. Nie negativ.
    public let milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = max(0, milliseconds)
    }

    /// Bequemer Einstieg aus Sekunden. Rundet kaufmännisch auf ganze Millisekunden.
    /// Unendlich, `NaN` und absurd große Werte ergeben 0 bzw. die Obergrenze,
    /// statt das Programm zu beenden.
    public init(seconds: Double) {
        self.milliseconds = SaturatingTime.milliseconds(fromSeconds: seconds)
    }

    public static let zero = MediaTime(milliseconds: 0)

    public var seconds: Double { Double(milliseconds) / 1000 }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public static func + (lhs: MediaTime, rhs: MediaDuration) -> MediaTime {
        MediaTime(milliseconds: SaturatingTime.adding(lhs.milliseconds, rhs.milliseconds))
    }

    /// Beide Seiten sind nicht-negativ, die Differenz kann also nicht
    /// überlaufen; der Initialisierer schneidet sie bei 0 ab.
    public static func - (lhs: MediaTime, rhs: MediaDuration) -> MediaTime {
        MediaTime(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }

    /// Abstand zwischen zwei Zeitpunkten, immer nicht-negativ.
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaDuration {
        MediaDuration(milliseconds: abs(lhs.milliseconds - rhs.milliseconds))
    }

    /// `hh:mm:ss` bzw. `mm:ss` — die Darstellung, die in Shownotes und Export erscheint.
    public var timecode: String {
        let totalSeconds = milliseconds / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        // `%ld`, nicht `%d`: die Werte sind Int64. `%d` erwartet 4 Byte und
        // verschiebt damit alle folgenden Argumente.
        return h > 0
            ? String(format: "%ld:%02ld:%02ld", h, m, s)
            : String(format: "%ld:%02ld", m, s)
    }

    /// `hh:mm:ss.mmm` — verlustfrei, für Exportformate mit Millisekundencues.
    public var preciseTimecode: String {
        let totalSeconds = milliseconds / 1000
        return String(format: "%02ld:%02ld:%02ld.%03ld",
                      totalSeconds / 3600, (totalSeconds % 3600) / 60,
                      totalSeconds % 60, milliseconds % 1000)
    }

    public var description: String { timecode }
}

/// Eine Zeitspanne. Getrennter Typ von ``MediaTime``, damit „Zeitpunkt plus Zeitpunkt“
/// gar nicht erst ausdrückbar ist.
public struct MediaDuration: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    public let milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = max(0, milliseconds)
    }

    public init(seconds: Double) {
        self.milliseconds = SaturatingTime.milliseconds(fromSeconds: seconds)
    }

    public init(minutes: Int) {
        self.milliseconds = max(0, SaturatingTime.multiplying(Int64(minutes), 60_000))
    }

    public static let zero = MediaDuration(milliseconds: 0)

    public var seconds: Double { Double(milliseconds) / 1000 }
    public var isZero: Bool { milliseconds == 0 }

    public static func < (lhs: MediaDuration, rhs: MediaDuration) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public static func + (lhs: MediaDuration, rhs: MediaDuration) -> MediaDuration {
        MediaDuration(milliseconds: SaturatingTime.adding(lhs.milliseconds, rhs.milliseconds))
    }

    public static func - (lhs: MediaDuration, rhs: MediaDuration) -> MediaDuration {
        MediaDuration(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }

    /// Tatsächliche Hördauer bei einer Wiedergabegeschwindigkeit.
    /// Ein Budget von 20 Minuten bei 1,5-facher Geschwindigkeit fasst 30 Minuten Medienzeit.
    public func listeningDuration(atRate rate: Double) -> MediaDuration {
        guard rate > 0, rate.isFinite else { return self }
        return MediaDuration(seconds: seconds / rate)
    }

    /// Menschliche Kurzform: „23 Min“, „1 Std 5 Min“, „45 Sek“.
    public var shortDescription: String {
        let totalSeconds = milliseconds / 1000
        if totalSeconds < 60 { return "\(totalSeconds) Sek" }
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes) Min" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) Std" : "\(minutes / 60) Std \(remainder) Min"
    }

    public var description: String { shortDescription }
}

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

/// Ein Zeitpunkt innerhalb einer konkreten Medienfassung, in Millisekunden ab Medienbeginn.
public struct MediaTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    /// Millisekunden ab Medienbeginn. Nie negativ.
    public let milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = max(0, milliseconds)
    }

    /// Bequemer Einstieg aus Sekunden. Rundet kaufmännisch auf ganze Millisekunden.
    public init(seconds: Double) {
        guard seconds.isFinite else { self.milliseconds = 0; return }
        self.milliseconds = max(0, Int64((seconds * 1000).rounded()))
    }

    public static let zero = MediaTime(milliseconds: 0)

    public var seconds: Double { Double(milliseconds) / 1000 }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public static func + (lhs: MediaTime, rhs: MediaDuration) -> MediaTime {
        MediaTime(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }

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
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// `hh:mm:ss.mmm` — verlustfrei, für Exportformate mit Millisekundencues.
    public var preciseTimecode: String {
        let totalSeconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d.%03d",
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
        guard seconds.isFinite else { self.milliseconds = 0; return }
        self.milliseconds = max(0, Int64((seconds * 1000).rounded()))
    }

    public init(minutes: Int) {
        self.milliseconds = max(0, Int64(minutes) * 60_000)
    }

    public static let zero = MediaDuration(milliseconds: 0)

    public var seconds: Double { Double(milliseconds) / 1000 }
    public var isZero: Bool { milliseconds == 0 }

    public static func < (lhs: MediaDuration, rhs: MediaDuration) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public static func + (lhs: MediaDuration, rhs: MediaDuration) -> MediaDuration {
        MediaDuration(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }

    public static func - (lhs: MediaDuration, rhs: MediaDuration) -> MediaDuration {
        MediaDuration(milliseconds: lhs.milliseconds - rhs.milliseconds)
    }

    /// Tatsächliche Hördauer bei einer Wiedergabegeschwindigkeit.
    /// Ein Budget von 20 Minuten bei 1,5-facher Geschwindigkeit fasst 30 Minuten Medienzeit.
    public func listeningDuration(atRate rate: Double) -> MediaDuration {
        guard rate > 0, rate.isFinite else { return self }
        return MediaDuration(milliseconds: Int64((Double(milliseconds) / rate).rounded()))
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

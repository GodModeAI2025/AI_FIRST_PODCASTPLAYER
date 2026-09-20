//
//  MediaTimeRange.swift
//  PodcastAICore
//

import Foundation

/// Ein halboffenes Intervall `[start, end)` innerhalb einer Medienfassung.
///
/// Halboffen, damit zwei aneinandergrenzende Bereiche sich nicht in einem
/// Punkt überlappen: `[0,10)` und `[10,20)` sind benachbart, nicht überlappend.
/// Das ist die Voraussetzung dafür, dass Vereinigung idempotent bleibt.
public struct MediaTimeRange: Hashable, Codable, Sendable, CustomStringConvertible {

    public let start: MediaTime
    public let end: MediaTime

    /// Ein leeres oder invertiertes Intervall ist kein Fehler, sondern wird auf
    /// eine leere Spanne bei `start` normalisiert. Aufrufer prüfen ``isEmpty``.
    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = max(start, end)
    }

    public init(start: MediaTime, duration: MediaDuration) {
        self.init(start: start, end: start + duration)
    }

    public var duration: MediaDuration {
        MediaDuration(milliseconds: end.milliseconds - start.milliseconds)
    }

    public var isEmpty: Bool { end.milliseconds <= start.milliseconds }

    public func contains(_ time: MediaTime) -> Bool {
        time.milliseconds >= start.milliseconds && time.milliseconds < end.milliseconds
    }

    /// Echte Überlappung. Berührung an der Grenze zählt nicht.
    public func overlaps(_ other: MediaTimeRange) -> Bool {
        start.milliseconds < other.end.milliseconds && other.start.milliseconds < end.milliseconds
    }

    /// Überlappend **oder** unmittelbar angrenzend — das Kriterium zum Verschmelzen.
    public func touchesOrOverlaps(_ other: MediaTimeRange, tolerance: MediaDuration = .zero) -> Bool {
        start.milliseconds <= other.end.milliseconds + tolerance.milliseconds
            && other.start.milliseconds <= end.milliseconds + tolerance.milliseconds
    }

    public func intersection(_ other: MediaTimeRange) -> MediaTimeRange? {
        let lo = max(start, other.start)
        let hi = min(end, other.end)
        guard lo.milliseconds < hi.milliseconds else { return nil }
        return MediaTimeRange(start: lo, end: hi)
    }

    /// Erweitert das Intervall in beide Richtungen, ohne unter null zu gehen.
    /// Wird benutzt, um eine Fundstelle auf Satz-/Dialogkontext auszudehnen.
    public func expanded(by padding: MediaDuration, limit: MediaTime? = nil) -> MediaTimeRange {
        let newStart = MediaTime(milliseconds: start.milliseconds - padding.milliseconds)
        var newEnd = MediaTime(milliseconds: end.milliseconds + padding.milliseconds)
        if let limit, newEnd > limit { newEnd = limit }
        return MediaTimeRange(start: newStart, end: newEnd)
    }

    /// Kürzt auf eine maximale Dauer, gemessen ab `start`.
    public func clamped(toDuration maximum: MediaDuration) -> MediaTimeRange {
        guard duration > maximum else { return self }
        return MediaTimeRange(start: start, duration: maximum)
    }

    public var description: String { "\(start.timecode)–\(end.timecode)" }
}

extension MediaTimeRange: Comparable {
    /// Sortierung nach Start, bei Gleichstand nach Ende. Deterministisch —
    /// Vereinigung und Export müssen auf jedem Gerät dieselbe Reihenfolge liefern.
    public static func < (lhs: MediaTimeRange, rhs: MediaTimeRange) -> Bool {
        lhs.start.milliseconds != rhs.start.milliseconds
            ? lhs.start.milliseconds < rhs.start.milliseconds
            : lhs.end.milliseconds < rhs.end.milliseconds
    }
}

//
//  IntervalSet.swift
//  PodcastAICore
//
//  Die zentrale Invariante des Produkts: „Gehört bleibt gehört.“
//
//  Eine ``IntervalSet`` ist eine normalisierte, disjunkte, sortierte Menge von
//  Medienintervallen. Jede Operation stellt die Normalform wieder her, damit
//  zwei Geräte bei derselben Eingabe byteidentische Ergebnisse produzieren.
//
//  Genau darauf steht die Aussage: wer Minute 10–15 einer Folge im
//  persönlichen Update gehört hat, bekommt sie in der Originalfolge nicht
//  noch einmal als ungehört angeboten — und umgekehrt.
//

import Foundation

public struct IntervalSet: Hashable, Codable, Sendable, CustomStringConvertible {

    /// Disjunkt, aufsteigend sortiert, keine leeren Intervalle, keine Berührungen.
    public private(set) var ranges: [MediaTimeRange]

    public init() { self.ranges = [] }

    public init(_ ranges: [MediaTimeRange]) {
        self.ranges = Self.normalize(ranges)
    }

    public init(_ range: MediaTimeRange) {
        self.ranges = range.isEmpty ? [] : [range]
    }

    // MARK: - Normalform

    /// Sortiert, entfernt Leeres und verschmilzt alles, was sich überlappt oder berührt.
    private static func normalize(_ input: [MediaTimeRange]) -> [MediaTimeRange] {
        let sorted = input.filter { !$0.isEmpty }.sorted()
        guard var current = sorted.first else { return [] }

        var result: [MediaTimeRange] = []
        result.reserveCapacity(sorted.count)

        for range in sorted.dropFirst() {
            if range.start.milliseconds <= current.end.milliseconds {
                // Überlappt oder grenzt direkt an: zusammenfassen.
                if range.end > current.end {
                    current = MediaTimeRange(start: current.start, end: range.end)
                }
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Mengenoperationen

    public func union(_ other: IntervalSet) -> IntervalSet {
        IntervalSet(ranges + other.ranges)
    }

    public func union(_ range: MediaTimeRange) -> IntervalSet {
        IntervalSet(ranges + [range])
    }

    public mutating func insert(_ range: MediaTimeRange) {
        self = union(range)
    }

    public mutating func formUnion(_ other: IntervalSet) {
        self = union(other)
    }

    /// Alles aus `self`, was nicht in `other` liegt. Die Operation hinter
    /// „welche Teile dieser Folge habe ich noch nicht gehört?“.
    public func subtracting(_ other: IntervalSet) -> IntervalSet {
        guard !other.ranges.isEmpty, !ranges.isEmpty else { return self }

        var result: [MediaTimeRange] = []
        for range in ranges {
            var cursor = range.start
            for hole in other.ranges {
                if hole.end <= cursor { continue }          // Loch liegt vor dem Rest
                if hole.start >= range.end { break }        // Löcher sind sortiert: fertig
                if hole.start > cursor {
                    result.append(MediaTimeRange(start: cursor, end: min(hole.start, range.end)))
                }
                cursor = max(cursor, hole.end)
                if cursor >= range.end { break }
            }
            if cursor < range.end {
                result.append(MediaTimeRange(start: cursor, end: range.end))
            }
        }
        // Ergebnis ist bereits disjunkt und sortiert; Normalisierung bleibt als Absicherung.
        var set = IntervalSet()
        set.ranges = Self.normalize(result)
        return set
    }

    public func subtracting(_ range: MediaTimeRange) -> IntervalSet {
        subtracting(IntervalSet(range))
    }

    public func intersection(_ other: IntervalSet) -> IntervalSet {
        guard !ranges.isEmpty, !other.ranges.isEmpty else { return IntervalSet() }

        var result: [MediaTimeRange] = []
        var i = 0, j = 0
        while i < ranges.count && j < other.ranges.count {
            if let overlap = ranges[i].intersection(other.ranges[j]) {
                result.append(overlap)
            }
            // Das Intervall, das früher endet, kann keine weiteren Treffer liefern.
            if ranges[i].end < other.ranges[j].end { i += 1 } else { j += 1 }
        }
        var set = IntervalSet()
        set.ranges = Self.normalize(result)
        return set
    }

    // MARK: - Abfragen

    public var isEmpty: Bool { ranges.isEmpty }

    /// Summe aller Intervalllängen — die tatsächlich abgedeckte Medienzeit.
    public var totalDuration: MediaDuration {
        MediaDuration(milliseconds: ranges.reduce(0) { $0 + $1.duration.milliseconds })
    }

    public func contains(_ time: MediaTime) -> Bool {
        ranges.contains { $0.contains(time) }
    }

    /// Wie viel von `range` bereits enthalten ist, als Anteil zwischen 0 und 1.
    /// `1.0` heißt vollständig abgedeckt, `0.0` gar nicht.
    public func coverage(of range: MediaTimeRange) -> Double {
        guard !range.isEmpty else { return 1.0 }
        let covered = intersection(IntervalSet(range)).totalDuration.milliseconds
        return Double(covered) / Double(range.duration.milliseconds)
    }

    /// Gilt `range` als gehört? Bewusst mit Schwelle statt exakt:
    /// die letzten Millisekunden vor einem Sprung werden praktisch nie abgespielt,
    /// und ein Rest von 200 ms darf eine Passage nicht als ungehört zurückbringen.
    public func covers(_ range: MediaTimeRange, threshold: Double = 0.95) -> Bool {
        coverage(of: range) >= threshold
    }

    /// Der noch nicht abgedeckte Teil von `range`.
    public func remainder(of range: MediaTimeRange) -> IntervalSet {
        IntervalSet(range).subtracting(self)
    }

    /// Verwirft Reststücke unterhalb einer Mindestlänge.
    /// Ein ungehörter Schnipsel von 1,5 Sekunden ist kein Inhalt, sondern Rauschen —
    /// er darf keine persönliche Ausgabe auslösen.
    public func droppingFragments(shorterThan minimum: MediaDuration) -> IntervalSet {
        var set = IntervalSet()
        set.ranges = ranges.filter { $0.duration >= minimum }
        return set
    }

    public var description: String {
        ranges.isEmpty ? "∅" : ranges.map(\.description).joined(separator: ", ")
    }
}

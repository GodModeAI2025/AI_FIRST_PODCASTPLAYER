//
//  ListeningLedger.swift
//  PodcastAICore
//
//  Ein einziger gemeinsamer Hörzustand über alle Wiedergabewege.
//
//  Die Regel, an der sich das Produkt messen lässt: wer Minute 10–15 einer
//  Folge im persönlichen Update gehört hat, bekommt dieselbe Passage nicht
//  noch einmal als neu angeboten — und umgekehrt.
//

import Foundation

/// Warum ein Medienbereich berührt wurde. Nur `.played` zählt als gehört.
///
/// Diese Unterscheidung ist der Kern von FR-130: Suchen, Herunterladen,
/// Analysieren, Lesen und Puffern erzeugen alle Zugriffe auf Medienbereiche,
/// aber keiner davon bedeutet, dass ein Mensch zugehört hat.
public enum LedgerEventKind: String, Codable, Sendable {
    /// Tatsächlich hörbar abgespielt.
    case played
    /// Übersprungen — ausdrücklich nicht gehört.
    case skipped
    /// Vom Nutzer manuell als bekannt markiert.
    case markedKnown

    public var countsAsHeard: Bool {
        switch self {
        case .played, .markedKnown: true
        case .skipped: false
        }
    }
}

public struct LedgerEvent: Hashable, Codable, Sendable {

    public let mediaVersionID: MediaVersionID
    public let range: MediaTimeRange
    public let kind: LedgerEventKind
    public let at: Date

    /// Auf welchem Weg gehört — nur zur Anzeige und Diagnose. Für den
    /// Hörzustand selbst ist der Weg bedeutungslos: das ist der Punkt.
    public let via: PlaybackRoute

    /// Identität des Geräts, für Konfliktauflösung beim Sync.
    public let deviceID: String

    public init(
        mediaVersionID: MediaVersionID, range: MediaTimeRange, kind: LedgerEventKind,
        at: Date = Date(), via: PlaybackRoute, deviceID: String
    ) {
        self.mediaVersionID = mediaVersionID; self.range = range; self.kind = kind
        self.at = at; self.via = via; self.deviceID = deviceID
    }
}

public enum PlaybackRoute: String, Codable, Sendable {
    case originalEpisode
    case chatFocus
    case interestFocus
    case smartFeedEpisode
    case counterpoint
}

/// Wie belastbar die Historie einer Medienfassung ist.
public enum HistoryQuality: String, Codable, Sendable {
    /// Intervallgenau erfasst.
    case exact
    /// Aus einem früheren Modell ohne Intervalle übernommen — etwa ein
    /// migriertes `played`-Flag. Dann ist nur bekannt, *dass* etwas gehört
    /// wurde, nicht welcher Bereich.
    case unknown

    public var label: String {
        switch self {
        case .exact: "genau erfasst"
        case .unknown: "aus älteren Daten übernommen"
        }
    }
}

/// Der Hörzustand einer einzelnen Medienfassung.
public struct MediaListeningState: Hashable, Codable, Sendable {

    public let mediaVersionID: MediaVersionID
    /// Vereinigung aller tatsächlich gehörten Bereiche.
    public private(set) var heard: IntervalSet
    /// Ausdrücklich übersprungene Bereiche. Getrennt geführt: übersprungen
    /// heißt nicht gehört, aber auch nicht „noch anzubieten“.
    public private(set) var skipped: IntervalSet
    public private(set) var quality: HistoryQuality
    public private(set) var lastEventAt: Date?

    /// Zuletzt erreichte Position für „weiterhören“. Getrennt von ``heard``,
    /// weil die größte Sekunde nach einem Rücksprung falsch wäre.
    public var resumePosition: MediaTime?

    public init(mediaVersionID: MediaVersionID, quality: HistoryQuality = .exact) {
        self.mediaVersionID = mediaVersionID
        self.heard = IntervalSet()
        self.skipped = IntervalSet()
        self.quality = quality
        self.lastEventAt = nil
    }

    public mutating func apply(_ event: LedgerEvent) {
        guard event.mediaVersionID == mediaVersionID, !event.range.isEmpty else { return }
        switch event.kind {
        case .played, .markedKnown:
            heard.insert(event.range)
            // Was jetzt gehört wurde, ist nicht mehr nur übersprungen.
            skipped = skipped.subtracting(event.range)
        case .skipped:
            // Bereits Gehörtes bleibt gehört — Überspringen macht das nicht rückgängig.
            skipped = skipped.union(IntervalSet(event.range).subtracting(heard))
        }
        if lastEventAt == nil || event.at > lastEventAt! { lastEventAt = event.at }
    }

    /// Der noch nicht gehörte Teil eines Bereichs.
    public func unheardPortion(of range: MediaTimeRange) -> IntervalSet {
        heard.remainder(of: range)
    }

    /// Gilt der Bereich als gehört?
    public func hasHeard(_ range: MediaTimeRange, threshold: Double = 0.95) -> Bool {
        heard.covers(range, threshold: threshold)
    }

    public var totalHeard: MediaDuration { heard.totalDuration }
}

/// Der gemeinsame Hörzustand über alle Medienfassungen.
///
/// Bewusst ein reiner Wertetyp: Persistenz und Synchronisierung liegen
/// außerhalb. Damit ist die Logik ohne Store und ohne Netzwerk testbar.
public struct ListeningLedger: Codable, Sendable {

    public private(set) var states: [MediaVersionID: MediaListeningState]

    public init(states: [MediaVersionID: MediaListeningState] = [:]) {
        self.states = states
    }

    public mutating func apply(_ event: LedgerEvent) {
        var state = states[event.mediaVersionID]
            ?? MediaListeningState(mediaVersionID: event.mediaVersionID)
        state.apply(event)
        states[event.mediaVersionID] = state
    }

    public mutating func apply(_ events: [LedgerEvent]) {
        for event in events { apply(event) }
    }

    public func state(for id: MediaVersionID) -> MediaListeningState {
        states[id] ?? MediaListeningState(mediaVersionID: id)
    }

    public func heard(in id: MediaVersionID) -> IntervalSet {
        states[id]?.heard ?? IntervalSet()
    }

    /// Die Kernabfrage für persönliche Ausgaben: welcher Teil dieses
    /// Kandidatenbereichs ist noch nicht gehört?
    ///
    /// `minimumFragment` verwirft Reststücke, die zu kurz sind, um Inhalt zu
    /// tragen — ohne diese Schwelle erzeugt jeder halb gehörte Abschnitt
    /// Sekundenschnipsel, die als „neu“ in einer Ausgabe landen.
    public func unheardPortion(
        of range: MediaTimeRange,
        in id: MediaVersionID,
        minimumFragment: MediaDuration = MediaDuration(seconds: 20)
    ) -> IntervalSet {
        heard(in: id)
            .remainder(of: range)
            .droppingFragments(shorterThan: minimumFragment)
    }

    /// Vereinigung zweier Hörstände — die Operation beim Zusammenführen
    /// zweier Geräte. Kommutativ und idempotent: ein Ereignis zweimal
    /// anzuwenden ändert nichts, und die Reihenfolge ist egal.
    public func merged(with other: ListeningLedger) -> ListeningLedger {
        var result = self
        for (id, otherState) in other.states {
            var state = result.states[id] ?? MediaListeningState(mediaVersionID: id)
            // Gehört gewinnt immer: Vereinigung, nie Ersetzung.
            for range in otherState.heard.ranges {
                state.apply(LedgerEvent(mediaVersionID: id, range: range, kind: .played,
                                        at: otherState.lastEventAt ?? Date(),
                                        via: .originalEpisode, deviceID: "merge"))
            }
            for range in otherState.skipped.ranges {
                state.apply(LedgerEvent(mediaVersionID: id, range: range, kind: .skipped,
                                        at: otherState.lastEventAt ?? Date(),
                                        via: .originalEpisode, deviceID: "merge"))
            }
            result.states[id] = state
        }
        return result
    }
}

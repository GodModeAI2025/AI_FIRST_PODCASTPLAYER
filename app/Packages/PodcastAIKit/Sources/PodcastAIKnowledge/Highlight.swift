//
//  Highlight.swift
//  PodcastAIKnowledge
//
//  „Diese Stelle merken.“
//
//  Ein Highlight ist mehr als ein Lesezeichen: es hält Originalquelle,
//  Timecode, Transkriptpassage, Kontext und die eigene Notiz zusammen.
//  Genau deshalb kann daraus später Wissen werden, das die App wieder
//  verlassen kann.
//

import Foundation
import PodcastAICore

public struct Highlight: Sendable, Identifiable, Hashable, Codable {

    public let id: HighlightID
    /// Der Beleg — und damit Fassung, Revision, Zeitbereich und Originaltext.
    public let evidenceID: EvidenceID
    /// Eigene Notiz. Bleibt von Modellableitungen getrennt: was der Nutzer
    /// geschrieben hat, wird nie überschrieben oder verbessert.
    public var note: String?
    /// Vom Nutzer vergebene Themen.
    public var interestIDs: [InterestID]
    public let capturedAt: Date
    /// Auf welchem Weg gemerkt — für die Anzeige, nicht für die Bedeutung.
    public let capturedVia: CaptureRoute
    /// Die Medienfassung, aus der die Stelle stammt. Beim Merken aus dem
    /// Player gibt es keinen gespeicherten Beleg; über die Fassung wird die
    /// Stelle trotzdem mit ihrer Folge gelöscht. Ältere Einträge haben sie nicht.
    public var mediaVersionID: MediaVersionID?

    public enum CaptureRoute: String, Sendable, Codable {
        case player
        case transcript
        case chat
        case appIntent

        public var label: String {
            switch self {
            case .player: "aus dem Player"
            case .transcript: "aus dem Transkript"
            case .chat: "aus dem Chat"
            case .appIntent: "per Kurzbefehl"
            }
        }
    }

    public init(
        id: HighlightID = HighlightID(), evidenceID: EvidenceID, note: String? = nil,
        interestIDs: [InterestID] = [], capturedAt: Date = Date(),
        capturedVia: CaptureRoute = .player, mediaVersionID: MediaVersionID? = nil
    ) {
        self.id = id; self.evidenceID = evidenceID; self.note = note
        self.interestIDs = interestIDs; self.capturedAt = capturedAt
        self.capturedVia = capturedVia; self.mediaVersionID = mediaVersionID
    }
}

/// Nimmt Highlights an der jeweils richtigen Stelle auf.
public struct HighlightCapture: Sendable {

    /// Wie viel Kontext um die aktuelle Position herum gemerkt wird, wenn
    /// aus dem Player gemerkt wird.
    ///
    /// Asymmetrisch mit Absicht: wer „merken“ drückt, hat das Interessante
    /// gerade **gehört**. Der Anlass liegt hinter der aktuellen Position,
    /// nicht davor.
    public var lookBehind: MediaDuration
    public var lookAhead: MediaDuration

    public init(
        lookBehind: MediaDuration = MediaDuration(seconds: 45),
        lookAhead: MediaDuration = MediaDuration(seconds: 10)
    ) {
        self.lookBehind = lookBehind
        self.lookAhead = lookAhead
    }

    /// Der Bereich, der beim Merken aus dem laufenden Ton entsteht.
    public func range(around position: MediaTime, limit: MediaTime?) -> MediaTimeRange {
        let start = MediaTime(milliseconds: position.milliseconds - lookBehind.milliseconds)
        var end = MediaTime(milliseconds: position.milliseconds + lookAhead.milliseconds)
        if let limit, end > limit { end = limit }
        return MediaTimeRange(start: start, end: end)
    }

    /// Rastet den Bereich auf Segmentgrenzen ein, damit das Zitat nicht
    /// mitten im Satz beginnt.
    public func snapped(_ range: MediaTimeRange, in transcript: Transcript) -> MediaTimeRange {
        transcript.snappedToSegmentBounds(range)
    }
}

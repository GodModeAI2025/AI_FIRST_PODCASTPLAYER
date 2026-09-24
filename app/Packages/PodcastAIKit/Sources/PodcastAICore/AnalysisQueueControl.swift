//
//  AnalysisQueueControl.swift
//  PodcastAICore
//
//  Pausieren und Abbrechen der Warteschlange als reine Regeln, ohne
//  Oberfläche und ohne Aufgaben. Das Modell der App fragt hier, ob der
//  Worker eine Folge beginnen darf und was „Alle abbrechen“ wegnimmt.
//

import Foundation

public enum AnalysisQueueControl {

    /// Darf der Worker jetzt eine neue Folge beginnen? Transkripte beginnen
    /// nur vorn, nie während einer Pause und nie, während „Alle abbrechen“
    /// die Warteschlange gerade leert.
    public static func mayStart(paused: Bool, inForeground: Bool, cancelling: Bool) -> Bool {
        !paused && inForeground && !cancelling
    }

    /// Wie viele Folgen auf die Warteschlange warten, die angehaltene
    /// laufende Folge mitgezählt. Für „Pausiert, 12 Folgen warten“.
    public static func waitingCount(running: Bool, transcripts: Int, facts: Int) -> Int {
        max(0, transcripts) + max(0, facts) + (running ? 1 : 0)
    }

    /// Was „Alle abbrechen“ mit der Warteschlange der Transkripte macht.
    public struct Cancellation: Equatable, Sendable {
        /// Alle Folgen, die aus der Warteschlange gehen, die laufende vorn.
        public let removed: [EpisodeID]
        /// Von selbst Eingereihtes. Das Vorbereiten nimmt es erst nach dem
        /// nächsten Aktualisieren von Hand oder auf ausdrücklichen Wunsch
        /// wieder, sonst stünde es nach dem nächsten Takt wieder da.
        public let restingUntilRefresh: Set<EpisodeID>
        /// Muss die laufende Folge anhalten? Ihr Zwischenstand bleibt.
        public let stopsRunning: Bool
    }

    /// Plant „Alle abbrechen“. Jede Folge einmal, die laufende zuerst.
    /// Was von Hand angefordert war, ruht nicht: ein neues Anfordern gilt
    /// ohnehin sofort.
    public static func cancelAll(
        running: EpisodeID?, queue: [EpisodeID], automatic: Set<EpisodeID>
    ) -> Cancellation {
        var seen: Set<EpisodeID> = []
        let removed = ([running].compactMap { $0 } + queue).filter { seen.insert($0).inserted }
        return Cancellation(
            removed: removed,
            restingUntilRefresh: Set(removed.filter(automatic.contains)),
            stopsRunning: running != nil)
    }
}

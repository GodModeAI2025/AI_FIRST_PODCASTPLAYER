//
//  TranscriptPauseNotice.swift
//  PodcastAICore
//
//  Wann die App mit einer lokalen Mitteilung sagt, dass Transkripte bis zum
//  nächsten Öffnen pausieren.
//
//  Transkripte laufen im Hintergrund nur unter der fortgesetzten
//  Verarbeitung, die im Vordergrund beginnen muss. Trägt sie die Arbeit
//  nicht oder läuft ihre Zeit ab, steht die Warteschlange, bis die App
//  wieder vorn ist. Ohne Hinweis sähe das so aus, als arbeite die App noch.
//

import Foundation

public enum TranscriptPauseNotice {

    /// Wer die Transkripte im Hintergrund trägt.
    public enum Carrier: Equatable, Sendable {
        /// Nichts: keine fortgesetzte Verarbeitung angemeldet, oder das System
        /// hat sie abgelehnt.
        case none
        /// Angemeldet, aber das System hat sie noch nicht gestartet. Dann
        /// kurz warten und noch einmal fragen.
        case pending
        /// Die fortgesetzte Verarbeitung läuft und trägt die Arbeit.
        case carrying
        /// Ihre Zeit ist abgelaufen.
        case expired
    }

    /// Soll die Mitteilung jetzt kommen?
    ///
    /// Nur im Hintergrund, nur mit wartender Arbeit, nur mit Erlaubnis und
    /// höchstens einmal, bis die App wieder vorn war. Läuft die fortgesetzte
    /// Verarbeitung oder ist sie noch nicht entschieden, nicht.
    public static func shouldNotify(
        inBackground: Bool,
        pendingTranscripts: Bool,
        carrier: Carrier,
        permitted: Bool,
        alreadyNotified: Bool
    ) -> Bool {
        guard inBackground, pendingTranscripts, permitted, !alreadyNotified else { return false }
        switch carrier {
        case .none, .expired: return true
        case .pending, .carrying: return false
        }
    }
}

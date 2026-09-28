//
//  Origin.swift
//  PodcastAICore
//
//  Wer eine Arbeit wollte: ein Mensch, die App von selbst oder der
//  Rückstand. Die Ereignisse der Pipeline tragen den Wert, und die Tabelle
//  für den Vorrang bei Apple Intelligence (`AIPriorityPolicy`) liest ihn.
//
//  Der Typ liegt in der Domäne, nicht bei den Ereignissen in PodcastAIKit:
//  PodcastAIIntelligence hängt nicht von PodcastAIKit ab und sähe ihn dort
//  nicht.
//

import Foundation

/// Wer eine Arbeit wollte. Die höhere gewinnt, wenn dieselbe Folge mehrfach
/// ansteht.
///
/// Den Wert setzt nur der Code an der Stelle, an der ein Mensch etwas
/// anfordert oder die App selbst etwas einreiht. Weder ein Feed noch
/// Supadata noch eine abgeglichene Zeile heben ihn an (Regel 2).
public enum Origin: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Das Archiv eines Podcasts oder der Rückstand der Bibliothek.
    case backlog
    /// Von selbst eingereiht, etwa eine neue Folge eines Abos.
    case automatic
    /// Von einem Menschen angefordert, per Tippen oder über Siri.
    case user

    // Enums mit Rohwert bekommen kein `<` geschenkt.
    public static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }
}

//
//  AIPriorityPolicy.swift
//  PodcastAIIntelligence
//
//  Eine Tabelle für den Vorrang bei Apple Intelligence. Bis 0.12 stand der
//  Wert an vier Stellen: im Extraktor je Profil, beim Faktenlauf der App,
//  fest in der Auswahl der Tags und still als Standard bei der Relevanz
//  eines Themen-Updates. Jetzt fragt jeder Aufrufer hier.
//
//  Wer ruft, gibt die echte Herkunft mit. Dass Tags nach „Jetzt ermitteln“
//  und die Relevanz einer angeforderten Ausgabe mit `.user` laufen
//  (Entscheidung 1 in docs/plan-pipeline.md), ändert nur diese Tabelle: die
//  Tags seit der Stufe „Wissen“, die Relevanz mit den Ausgaben.
//
//  Die Tabelle regelt den Vorrang je Aufruf, nicht die Reihenfolge der
//  Folgen und nicht, ob Arbeit überhaupt laufen darf. Das bleiben die
//  Warteschlangen und das Tor.
//

import Foundation
import PodcastAICore

public enum AIPriorityPolicy {

    /// Der Vorrang einer Anfrage.
    ///
    /// - Parameters:
    ///   - kind: die Art der Arbeit.
    ///   - origin: wer die Arbeit wollte, für die das Modell rechnet.
    ///   - force: „Jetzt ermitteln“, von Hand angetippt.
    public static func priority(kind: AIWorkKind, origin: Origin, force: Bool = false) -> AIWorkPriority {
        switch kind {
        case .answer, .chapterSummary:
            // Entsteht nur, wenn jemand fragt oder den Reiter „Kapitel“ öffnet.
            .user
        case .facts:
            // „Jetzt ermitteln“ geht vor Arbeit im Hintergrund. Fakten nach
            // einem von Hand angeforderten Transkript warten wie alles, was
            // von selbst kommt.
            force ? .user : .background
        case .tags:
            // Die Tags erben die Herkunft des Faktenlaufs: nach „Jetzt
            // ermitteln“ vorn, sonst im Hintergrund, auch aus dem Rückstand.
            origin == .user ? .user : .background
        case .relevance:
            // Im Hintergrund, auch für eine angeforderte Ausgabe und eine
            // Anfrage über Siri. Mit den Ausgaben als Stufe kommt `.user`.
            .background
        case .other:
            .background
        }
    }
}

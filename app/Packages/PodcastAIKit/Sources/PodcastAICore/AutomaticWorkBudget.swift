//
//  AutomaticWorkBudget.swift
//  PodcastAICore
//
//  Wie viel Arbeit die App von selbst auf einmal einreiht.
//
//  In 0.11 stand in der Warteschlange eines Testers „Pausiert, 591 Folgen
//  warten“: „Ältere Folgen auch vorbereiten“ reihte ganze Archive ein, und
//  das Nachholen der Fakten nahm jede Folge der Bibliothek ohne Fakten.
//  Apple Intelligence rechnete dann ohne Pause, und der Chat stand dahinter.
//
//  Jetzt kommt Automatisches in kleinen Portionen, neueste zuerst. Ist eine
//  Portion abgearbeitet, rückt die nächste nach. Was jemand selbst anfordert,
//  zählt nicht mit und wird nie gekürzt.
//

import Foundation

public enum AutomaticWorkBudget {

    /// So viele ältere Folgen eines Podcasts warten höchstens zugleich auf ihr
    /// Transkript. Am Strom oder auf dem Mac mehr, im Akkubetrieb wenige.
    public static func backCatalogBatch(charging: Bool, isMac: Bool) -> Int {
        charging || isMac ? 10 : 3
    }

    /// So viele Folgen holen ihre Fakten von selbst höchstens zugleich nach.
    public static let factsBackfillBatch = 10

    /// So viele Folgen warten von selbst höchstens zugleich auf Kapitel-Tags.
    public static let tagsBackfillBatch = 10

    /// Nimmt aus `candidates`, neueste zuerst, so viele, dass danach
    /// höchstens `batch` warten. Wartet schon genug, nichts.
    public static func refill<T>(_ candidates: [T], alreadyWaiting: Int, batch: Int) -> [T] {
        Array(candidates.prefix(max(0, batch - alreadyWaiting)))
    }

    /// Kürzt eine gesicherte Warteschlange nach dem Update: von den älteren
    /// Folgen eines Podcasts bleiben nur die ersten `batch`, in der Reihenfolge
    /// der Warteschlange. Alles andere bleibt, auch von Hand Angefordertes.
    public static func trimmed<T, Key: Hashable>(
        _ queue: [T], isBacklog: (T) -> Bool, group: (T) -> Key, batch: Int
    ) -> [T] {
        var kept: [Key: Int] = [:]
        return queue.filter { item in
            guard isBacklog(item) else { return true }
            let key = group(item)
            let count = kept[key, default: 0]
            guard count < batch else { return false }
            kept[key] = count + 1
            return true
        }
    }
}

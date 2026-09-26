//
//  TrendingFeed.swift
//  PodcastAISmartFeeds
//
//  „Angesagt“ seit 0.12: ein Themen-Update, das die App selbst führt. Seine
//  Tags sind die Tags, die gerade angesagt sind (`TrendDetector`), im Modus
//  „eines davon“. Sonst ist es ein Themen-Update wie jedes andere: Teile zu
//  20 Minuten, Übersicht, Cover, Hörzustand, dieselbe Automatik.
//
//  Gespeichert wird es als gewöhnlicher `StoredSmartFeed`, ohne neues Feld
//  im Schema. Die Kennung ist fest und auf jedem Gerät dieselbe. Legen zwei
//  Geräte das Update gleichzeitig an, entstehen zwei Zeilen mit derselben
//  Kennung, und das Bereinigen nach dem Abgleich lässt eine übrig.
//
//  Hier stehen nur Regeln ohne Store und ohne Oberfläche, damit sie sich
//  prüfen lassen. Das Modell der App wendet sie an
//  (`AppModel+TrendingFeed.swift`). Nichts hier startet Ton (Regel 1), und
//  welche Tags gelten, entscheidet der Code aus der Zählung (Regel 3).
//

import Foundation
import PodcastAICore
import PodcastAIKnowledge

public enum TrendingFeed {

    /// Die Kennung des Updates, aus einem festen Schlüssel gerechnet.
    public static let id = SmartFeedID(stable: "podcastai|smartfeed|trending")

    /// So viele angesagte Tags nimmt das Update höchstens, so viele wie die
    /// Zeile „Angesagt“ im Tab zeigt. Mehr ergäben kein Thema mehr, sondern
    /// einen Querschnitt.
    public static let maximumTags = 5

    /// Die Länge eines Teils, wie bei einem neuen Themen-Update.
    public static let partMinutes = 20

    /// Hat jemand diesem Tag mit Minus das Folgen entzogen?
    ///
    /// Plus macht aus einem erkannten Tag ein bestätigtes
    /// (`LibraryStore.setStance`). Bestätigt und neutral heißt deshalb: Es
    /// wurde einmal gefolgt und dann abgewählt. Ein erkanntes, neutrales Tag
    /// hat niemand bewertet; es darf angesagt sein.
    public static func isUnfollowed(_ tag: Tag) -> Bool {
        tag.origin == .confirmedByUser && tag.stance == .neutral
    }

    /// Die Tags des Updates aus den angesagten Tags: in der Reihenfolge der
    /// Trends, jedes einmal, ohne Tags mit Minus, höchstens ``maximumTags``.
    /// Ohne Trends bleibt die Liste leer, und es entsteht keine Ausgabe.
    public static func tagIDs(from trending: [TrendingTag]) -> [InterestID] {
        var seen: Set<InterestID> = []
        return Array(trending
            .filter { !isUnfollowed($0.tag) && seen.insert($0.tag.id).inserted }
            .map(\.tag.id)
            .prefix(maximumTags))
    }

    /// Die Tags, mit denen eine Ausgabe jetzt entsteht: die gespeicherten
    /// ohne die, denen inzwischen jemand mit Minus das Folgen entzogen hat.
    /// Die Haltung kann über iCloud kommen, bevor sich die Trends auf diesem
    /// Gerät ändern.
    public static func editionTagIDs(of feed: SmartPodcastFeed, tags: [Tag]) -> [InterestID] {
        let unfollowed = Set(tags.filter(isUnfollowed).map(\.id))
        return feed.topicIDs.filter { !unfollowed.contains($0) }
    }

    /// Das Update, wie es angelegt wird. Der Titel kommt aus der Sprache
    /// des Geräts, das es anlegt, und bleibt danach stehen.
    public static func makeFeed(title: String, tagIDs: [InterestID], createdAt: Date = Date()) -> SmartPodcastFeed {
        SmartPodcastFeed(
            id: id, title: title, topicIDs: tagIDs, matchMode: .any,
            editionMode: .budgeted(MediaDuration(minutes: partMinutes)),
            createdAt: createdAt)
    }

    /// Was mit dem gespeicherten Update geschehen soll.
    public enum Action: Equatable, Sendable {
        case none
        /// Anlegen, mit diesen Tags.
        case create([InterestID])
        /// Die Tags ersetzen.
        case update([InterestID])
    }

    /// Entscheidet, ob das Update angelegt wird oder neue Tags bekommt.
    ///
    /// - Parameters:
    ///   - existing: das gespeicherte Update, falls es eins gibt.
    ///   - desired: die Tags aus den Trends dieses Geräts.
    ///   - lastApplied: die Tags, die dieses Gerät zuletzt geschrieben hat.
    ///     Hat ein anderes Gerät seither andere geschrieben und haben sich
    ///     die Trends hier nicht geändert, bleibt es dabei. Zwei Geräte mit
    ///     verschieden weit abgeglichenen Kapitel-Tags schreiben sich sonst
    ///     abwechselnd um.
    ///   - decided: Hat dieses Gerät schon einmal über das Update befunden,
    ///     von selbst oder über den Schalter? Dann legt es das Update nie
    ///     wieder von selbst an. Das Anlegen ohne Zutun gibt es nur einmal,
    ///     sobald es Trends gibt.
    public static func reconcile(
        existing: SmartPodcastFeed?, desired: [InterestID], lastApplied: [InterestID]?, decided: Bool
    ) -> Action {
        guard let existing else {
            return !decided && !desired.isEmpty ? .create(desired) : .none
        }
        let wanted = Set(desired)
        guard wanted != Set(existing.topicIDs), lastApplied.map(Set.init) != wanted else { return .none }
        return .update(desired)
    }
}

extension SmartPodcastFeed {
    /// Führt die App dieses Update selbst, mit den angesagten Tags? Dann
    /// heißen leere Tags „gerade nichts angesagt“, nicht „alle gefolgten“.
    public var followsTrends: Bool { id == TrendingFeed.id }

    /// Die Tags, nach denen das Update sucht: seine eigenen, ohne eigene
    /// die gefolgten. „Angesagt“ fällt nie auf die gefolgten zurück.
    public func searchTags(followed: Set<InterestID>) -> Set<InterestID> {
        topicIDs.isEmpty && !followsTrends ? followed : Set(topicIDs)
    }
}

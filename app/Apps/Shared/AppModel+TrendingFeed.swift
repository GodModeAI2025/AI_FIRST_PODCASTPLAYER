//
//  AppModel+TrendingFeed.swift
//  PodcastAI
//
//  Das Themen-Update „Angesagt“ seit 0.12. Die Regeln stehen in
//  `TrendingFeed` (PodcastAISmartFeeds); hier wendet das Modell sie an.
//
//  „Angesagt“ ist ein gewöhnliches Themen-Update mit fester Kennung. Seine
//  Tags sind die angesagten Tags ohne die mit Minus, im Modus „eines
//  davon“. Ausgaben entstehen dort, wo alle Themen-Updates ihre Ausgaben
//  bekommen (`processPendingEditions`), mit derselben Mindestmenge und
//  derselben Ruhezeit. Vorher rechnet das Modell die Trends nach, damit das
//  Update auch im Hintergrund den aktuellen Tags folgt. Keine Ausgabe
//  startet Ton.
//
//  Ob das Update an ist, steht in iCloud: Es ist an, solange es die Zeile
//  gibt. Zwei Merkzeichen liegen nur auf diesem Gerät in `DeviceState`: ob
//  es schon einmal über das Update befunden hat und welche Tags es zuletzt
//  geschrieben hat. Ein eigenes Feld für „ausgeschaltet“ gäbe es nur mit
//  einer Änderung am Schema. Deshalb erfährt ein Gerät, das das Update nie
//  gesehen hat, nicht, dass es anderswo ausgeschaltet wurde, und legt es
//  einmal an, sobald es selbst Trends zählt.
//

import Foundation
import PodcastAIKit

/// Wann der Tab „Themen-Updates“ „Angesagt“ abgleicht: wenn sich
/// Kapitel-Tags ändern und wenn die Bibliothek fertig geladen ist. Lief die
/// erste Rechnung vor dem Laden, holt der zweite Anlass das Abgleichen nach.
struct TrendingFeedTrigger: Hashable {
    let trends: TagTrendsTrigger
    let loaded: Bool
}

extension AppModel {

    // MARK: - Zustand

    /// Das Update „Angesagt“, solange es an ist.
    public var trendingFeed: SmartPodcastFeed? { smartFeeds.first { $0.followsTrends } }

    /// Die Themen-Updates, die jemand selbst angelegt hat.
    public var userSmartFeeds: [SmartPodcastFeed] { smartFeeds.filter { !$0.followsTrends } }

    /// Die Tags, die „Angesagt“ nach den Trends dieses Geräts tragen soll.
    var desiredTrendingFeedTags: [InterestID] { TrendingFeed.tagIDs(from: trendingTags) }

    /// Hat dieses Gerät schon über „Angesagt“ befunden? Dann legt es das
    /// Update nicht mehr von selbst an.
    nonisolated static let trendingFeedDecidedKey = "trendingFeedDecided"
    /// Die Tags, die dieses Gerät zuletzt in „Angesagt“ geschrieben hat.
    nonisolated static let trendingFeedAppliedKey = "trendingFeedAppliedTags"

    private var trendingFeedDecided: Bool {
        get { DeviceState.shared.value(Bool.self, for: Self.trendingFeedDecidedKey) ?? false }
        set {
            guard newValue != trendingFeedDecided else { return }
            DeviceState.shared.set(newValue, for: Self.trendingFeedDecidedKey)
        }
    }

    private var trendingFeedAppliedTags: [InterestID]? {
        get {
            DeviceState.shared.value([String].self, for: Self.trendingFeedAppliedKey)?
                .map(InterestID.init(rawValue:))
        }
        set {
            guard newValue != trendingFeedAppliedTags else { return }
            DeviceState.shared.set(newValue?.map(\.rawValue), for: Self.trendingFeedAppliedKey)
        }
    }

    // MARK: - Schalter

    /// „Angesagt automatisch zusammenstellen“. An legt das Update an und
    /// stellt gleich die erste Ausgabe zusammen, wie beim Anlegen eines
    /// eigenen Updates, sofern etwas angesagt ist. Aus löscht das Update mit
    /// allen seinen Ausgaben; Folgen, Transkripte und Hörstand bleiben.
    /// Solange eine Ausgabe des ausgeschalteten Updates noch entsteht, geht
    /// es nicht wieder an (``trendingFeedBlockedByOldBuild``). Beides spielt
    /// nichts ab.
    public func setTrendingFeedEnabled(_ enabled: Bool) {
        guard isLoaded else { return }
        trendingFeedDecided = true
        if enabled {
            guard trendingFeed == nil else { return }
            addTrendingFeed(tags: desiredTrendingFeedTags, buildFirstEdition: true)
        } else if trendingFeed != nil {
            removeSmartFeed(TrendingFeed.id)
            trendingFeedAppliedTags = nil
        }
    }

    // MARK: - Den Trends folgen

    /// Für `.task(id:)` im Tab „Themen-Updates“.
    var trendingFeedTrigger: TrendingFeedTrigger {
        TrendingFeedTrigger(trends: tagTrendsTrigger, loaded: isLoaded)
    }

    /// Rechnet die Trends nach, falls ihr Stand alt ist, und gleicht
    /// „Angesagt“ damit ab. Aufgerufen, bevor die Automatik Ausgaben prüft,
    /// und vom Tab „Themen-Updates“.
    func refreshTrendingFeed() async {
        await refreshTagTrends()
        // Galt der letzte Stand der Trends noch, hat `refreshTagTrends`
        // nichts gerechnet und nichts abgeglichen.
        await reconcileTrendingFeed()
    }

    /// Legt „Angesagt“ einmal von selbst an, sobald es Trends gibt, und
    /// schreibt seine Tags um, wenn sie sich auf diesem Gerät geändert
    /// haben. Stellt keine Ausgabe zusammen und spielt nichts ab.
    func reconcileTrendingFeed() async {
        // Vor der ersten Rechnung in diesem Start heißt eine leere Liste
        // „noch nicht gerechnet“, nicht „nichts angesagt“. Sie darf die
        // Tags, die ein anderes Gerät geschrieben hat, nicht löschen.
        guard isLoaded, tagTrendsStamp != nil else { return }
        guard trendingFeedAction() != .none else { return }
        guard await storeMatchesSmartFeeds() else { return }
        // Während des Lesens können neue Trends gekommen sein, und ein
        // zweiter Abgleich kann schon geschrieben haben. Deshalb entscheidet
        // der Stand nach dem Lesen, nicht der davor; sonst schriebe ein
        // später fertiger Abgleich alte Tags über neue.
        switch trendingFeedAction() {
        case .none:
            return
        case .create(let tags):
            guard !trendingFeedBlockedByOldBuild else { return }
            trendingFeedDecided = true
            addTrendingFeed(tags: tags, buildFirstEdition: false)
        case .update(let tags):
            guard var feed = trendingFeed else { return }
            feed.topicIDs = tags
            updateSmartFeed(feed)
            trendingFeedAppliedTags = tags
        }
    }

    /// Was mit „Angesagt“ nach dem jetzigen Stand geschehen soll. Merkt sich
    /// nebenbei, was ohne Schreiben schon feststeht.
    private func trendingFeedAction() -> TrendingFeed.Action {
        let desired = desiredTrendingFeedTags
        let existing = trendingFeed
        // Kam das Update über iCloud, hat ein anderes Gerät schon befunden.
        // Schaltet es danach jemand aus, legt dieses Gerät es nicht wieder an.
        if existing != nil { trendingFeedDecided = true }
        let action = TrendingFeed.reconcile(
            existing: existing, desired: desired,
            lastApplied: trendingFeedAppliedTags, decided: trendingFeedDecided)
        // Stimmen die Tags schon, gilt das als geschrieben. Sonst holte ein
        // späterer Stand eines anderen Geräts einen alten zurück.
        if action == .none, let existing, Set(existing.topicIDs) == Set(desired) {
            trendingFeedAppliedTags = desired
        }
        return action
    }

    /// Kennt die Liste im Speicher genau die gesicherten Updates? Nur dann
    /// schreibt die App „Angesagt“ von selbst. Das Sichern schreibt die ganze
    /// Liste: Was ihr fehlt, etwa ein Update, das gerade über iCloud kam,
    /// verschwände aus der Datenbank, und was nur sie noch hat, weil ein
    /// anderes Gerät es gelöscht hat, käme zurück. Stimmt es nicht, holt das
    /// nächste Abgleichen nach dem Neuladen das Schreiben nach.
    private func storeMatchesSmartFeeds() async -> Bool {
        guard let stored = try? await store.smartFeeds() else { return false }
        return Set(stored.map(\.id)) == Set(smartFeeds.map(\.id))
    }

    /// Läuft noch eine Ausgabe für ein ausgeschaltetes „Angesagt“? Dann
    /// entsteht es erst neu, wenn sie fertig und verworfen ist. Die feste
    /// Kennung nähme sie sonst als Ausgabe des neuen Updates an, und eine
    /// zweite liefe daneben.
    var trendingFeedBlockedByOldBuild: Bool {
        trendingFeed == nil && buildingFeeds.contains(TrendingFeed.id)
    }

    private func addTrendingFeed(tags: [InterestID], buildFirstEdition: Bool) {
        guard !trendingFeedBlockedByOldBuild else { return }
        // Die feste Kennung erbt sonst die letzte Rückmeldung des alten
        // Updates, etwa „gibt es nicht mehr“ von der verworfenen Ausgabe.
        editionNotes[TrendingFeed.id] = nil
        editionChecks[TrendingFeed.id] = nil
        createSmartFeed(
            title: String(localized: "Angesagt"), topicIDs: tags, matchMode: .any,
            minutes: TrendingFeed.partMinutes, buildFirstEdition: buildFirstEdition && !tags.isEmpty,
            id: TrendingFeed.id)
        trendingFeedAppliedTags = tags
    }

    // MARK: - Ausgaben

    /// „Angesagt“ ohne die Tags, denen inzwischen jemand mit Minus das
    /// Folgen entzogen hat. Damit stellt `buildEdition` zusammen.
    func trendingFeedForEdition(_ feed: SmartPodcastFeed) -> SmartPodcastFeed {
        var copy = feed
        copy.topicIDs = TrendingFeed.editionTagIDs(of: feed, tags: profile.tags)
        return copy
    }

    /// Wartet „Angesagt“ auf angesagte Tags?
    func isWaitingForTrends(_ feed: SmartPodcastFeed) -> Bool {
        feed.followsTrends && trendingFeedForEdition(feed).topicIDs.isEmpty
    }

    static var nothingTrendingNote: String {
        String(localized: "Gerade ist kein Tag angesagt. Neue Ausgaben entstehen erst, wenn wieder Tags angesagt sind.")
    }

    /// Wann die nächste Ausgabe kommen kann, in einem Satz. Für „Angesagt“
    /// ohne angesagte Tags sagt er das.
    func editionHint(for feed: SmartPodcastFeed) -> String {
        isWaitingForTrends(feed) ? Self.nothingTrendingNote : nextEditionHint(for: feed)
    }
}

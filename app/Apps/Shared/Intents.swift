//
//  Intents.swift
//  PodcastAI
//
//  App Intents — PodcastAI per Siri, Kurzbefehl oder Bildschirmaktion
//  bedienen.
//
//  Die Regel, die hier nicht aufweicht: ein Intent ist eine **Handlung
//  eines Menschen** und darf deshalb eine Wiedergabefreigabe erzeugen. Er
//  umgeht aber keine einzige Prüfung — er geht durch dieselbe Policy wie
//  ein Fingertipp. Ein Intent, der von einer Automation ohne Zutun
//  ausgelöst wird, bereitet vor und spielt nicht ab.
//

#if canImport(AppIntents)
import AppIntents
import Foundation
import PodcastAIKit

// MARK: - Entitäten

/// Ein Themenfeed als adressierbares Objekt.
///
/// Damit wird „Spiel mein AI Update“ möglich, ohne dass der Nutzer eine
/// Kennung nennen muss.
struct SmartFeedEntity: AppEntity, Identifiable {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Themen-Update")
    }
    static let defaultQuery = SmartFeedQuery()

    var id: String
    var title: String
    var latestEditionSummary: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: latestEditionSummary.map { "\($0)" }
        )
    }
}

struct SmartFeedQuery: EntityQuery {

    @Dependency private var model: AppModel

    func entities(for identifiers: [String]) async throws -> [SmartFeedEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SmartFeedEntity] {
        // Bei einem Kaltstart über Siri hat noch niemand geladen, und die
        // Auswahl bliebe leer.
        await model.ensureLoaded()
        return await MainActor.run {
            model.smartFeeds.map { feed in
                let latest = model.editions[feed.id]?.first
                return SmartFeedEntity(
                    id: feed.id.rawValue,
                    title: feed.title,
                    latestEditionSummary: latest.map {
                        "\($0.segments.count) Stellen · \($0.totalMediaDuration.shortDescription)"
                    }
                )
            }
        }
    }
}

// MARK: - Aktionen

/// „Spiel mein AI Update.“
struct PlaySmartFeedIntent: AppIntent {

    static let title: LocalizedStringResource = "Themen-Update abspielen"
    static let description = IntentDescription(
        "Spielt die neueste Ausgabe eines Themen-Updates ab, also Originalstellen aus deinen Quellen, die du noch nicht gehört hast. Ist sie schon gehört, entsteht vorher eine neue."
    )
    /// Die App kommt nach vorn: Wiedergabe ist etwas, das man sehen soll.
    static let openAppWhenRun = true

    @Parameter(title: "Themen-Update")
    var feed: SmartFeedEntity

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.ensureLoaded()
        let feedID = SmartFeedID(rawValue: feed.id)
        guard model.smartFeeds.contains(where: { $0.id == feedID }) else {
            return .result(dialog: "„\(feed.title)“ gibt es nicht mehr.")
        }
        // „Spiel mein Update“ meint das Neue. Ist die letzte Ausgabe schon
        // gehört oder gibt es keine, wird zuerst eine neue zusammengestellt.
        // Das hat jemand ausdrücklich verlangt, es ist keine Empfehlung.
        // Entsteht keine, sagt Siri warum, statt Gehörtes zu wiederholen.
        let previous = model.editions[feedID]?.first
        if previous.map({ $0.heardFraction(in: model.ledger) >= 0.8 }) ?? true {
            let note = await model.buildEdition(feedID: feedID)
            let latest = model.editions[feedID]?.first
            if latest == nil || latest?.id == previous?.id {
                return .result(dialog: "„\(feed.title)“: \(note)")
            }
        }
        guard let edition = model.editions[feedID]?.first else {
            return .result(dialog: "Für „\(feed.title)“ gibt es noch keine Ausgabe.")
        }

        let plan = ValidatedPlaybackPlan(
            segments: edition.segments.map { segment in
                PlanSegment(
                    evidenceID: segment.evidenceIDs.first ?? EvidenceID(),
                    mediaVersionID: segment.mediaVersionID,
                    episodeID: segment.episodeID,
                    sourceID: segment.sourceID,
                    range: segment.playbackRange,
                    sourceTitle: segment.sourceTitle,
                    episodeTitle: segment.episodeTitle,
                    rationale: segment.reason
                )
            },
            requestSummary: edition.title,
            route: .smartFeedEpisode
        )
        // Über dieselbe Policy wie ein Fingertipp — kein Sonderweg.
        model.play(plan, from: .intent)
        // `play` meldet einen Fehler nur über `lastError`. Läuft der Plan
        // nicht, sagt Siri das, statt eine Ausgabe anzukündigen, die still bleibt.
        guard model.playerPlan?.id == plan.id else {
            model.policy.endFocusSession()
            let reason = model.lastError ?? "Die Stellen sind gerade nicht abspielbar."
            model.lastError = nil
            return .result(dialog: "„\(edition.title)“ lässt sich nicht abspielen. \(reason)")
        }

        return .result(dialog: "\(edition.title): \(edition.segments.count) Stellen aus \(edition.distinctSourceCount) Quellen.")
    }
}

/// „Erstelle mir ein 20-Minuten-Datenschutz-Update.“
struct BuildEditionIntent: AppIntent {

    static let title: LocalizedStringResource = "Themen-Update erstellen"
    static let description = IntentDescription(
        "Stellt aus deinen ungehörten Originalstellen eine neue Ausgabe zusammen. Startet keine Wiedergabe."
    )
    /// Ausdrücklich nicht: die App nach vorn holen. Zusammenstellen ist
    /// Vorbereitung, und Vorbereitung darf im Hintergrund passieren.
    static let openAppWhenRun = false

    @Parameter(title: "Themen-Update")
    var feed: SmartFeedEntity

    @Parameter(title: "Dauer in Minuten", default: 20,
               inclusiveRange: (5, 120))
    var minutes: Int

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.ensureLoaded()
        let summary = await model.buildEdition(
            feedID: SmartFeedID(rawValue: feed.id),
            budget: MediaDuration(minutes: minutes)
        )
        // Eine fertige Ausgabe ist ein Zustand, kein Tonstart.
        return .result(dialog: "\(summary)")
    }
}

/// „Merke diese Aussage.“ — bezogen auf das, was gerade läuft.
struct RememberCurrentPassageIntent: AppIntent {

    static let title: LocalizedStringResource = "Diese Stelle merken"
    static let description = IntentDescription(
        "Merkt sich die Stelle, die gerade läuft, mit Folge, Quelle und Zeitmarke. Gibt es ein Transkript, kommt der Originaltext dazu."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Notiz", default: nil)
    var note: String?

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.ensureLoaded()
        guard let (mediaVersionID, position, episodeID) = currentPassage() else {
            return .result(dialog: "Gerade läuft nichts, das ich merken könnte.")
        }
        let saved = await model.rememberPassage(
            at: position, in: mediaVersionID, episodeID: episodeID, note: note, via: .appIntent
        )
        return .result(dialog: "\(saved)")
    }

    /// Die Stelle, die gerade klingt. Läuft eine ganze Folge, gilt sie.
    /// Sonst der Fokus-Plan, aber nur, solange das Modell ihn als laufend
    /// führt: der Koordinator kann nach einem Fehler noch einen toten Plan
    /// kennen. Zuletzt die angehaltene Folge.
    /// Die Folge kennt nur der Zweig mit ganzer Folge, beim Fokus-Plan
    /// sucht `rememberPassage` sie über den laufenden Abschnitt.
    @MainActor
    private func currentPassage() -> (MediaVersionID, MediaTime, EpisodeID?)? {
        let player = model.episodePlayer
        var episodePassage: (MediaVersionID, MediaTime, EpisodeID?)? {
            guard let episode = player.episode, let mediaVersionID = episode.streamMediaVersionID,
                  player.currentTime > 0 else { return nil }
            return (mediaVersionID, MediaTime(milliseconds: Int64(player.currentTime * 1000)), episode.id)
        }
        if player.isPlaying, let passage = episodePassage { return passage }
        if model.playerPlan != nil, let (media, position) = model.player.currentOriginalPosition() {
            return (media, position, nil)
        }
        return episodePassage
    }
}

/// Stoppt die Wiedergabe.
struct StopPlaybackIntent: AppIntent {

    static let title: LocalizedStringResource = "Wiedergabe stoppen"
    static let openAppWhenRun = false

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.stopPlayback()
        model.policy.endFocusSession()
        // Auch eine ganze Folge hört auf, wie beim Menübefehl auf dem Mac.
        model.episodePlayer.stop()
        return .result()
    }
}

// MARK: - Kurzbefehle

struct PodcastAIShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySmartFeedIntent(),
            phrases: [
                "Spiel mein Update in \(.applicationName)",
                "Starte mein Themen-Update in \(.applicationName)",
            ],
            shortTitle: "Update abspielen",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: RememberCurrentPassageIntent(),
            phrases: [
                "Merke diese Stelle in \(.applicationName)",
                "Diese Aussage merken in \(.applicationName)",
            ],
            shortTitle: "Stelle merken",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: StopPlaybackIntent(),
            phrases: ["Stoppe \(.applicationName)"],
            shortTitle: "Stoppen",
            systemImageName: "stop.circle"
        )
    }
}
#endif

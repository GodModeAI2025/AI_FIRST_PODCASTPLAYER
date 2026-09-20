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
    static var defaultQuery = SmartFeedQuery()

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
        await MainActor.run {
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

    static var title: LocalizedStringResource = "Themen-Update abspielen"
    static var description = IntentDescription(
        "Spielt die neueste Ausgabe eines Themen-Updates ab — die Originalstellen "
        + "aus deinen Quellen, die du noch nicht gehört hast."
    )
    /// Die App kommt nach vorn: Wiedergabe ist etwas, das man sehen soll.
    static var openAppWhenRun = true

    @Parameter(title: "Themen-Update")
    var feed: SmartFeedEntity

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let feedID = SmartFeedID(rawValue: feed.id)
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

        return .result(dialog: "\(edition.title): \(edition.segments.count) Stellen aus "
                       + "\(edition.distinctSourceCount) Quellen.")
    }
}

/// „Erstelle mir ein 20-Minuten-Datenschutz-Update.“
struct BuildEditionIntent: AppIntent {

    static var title: LocalizedStringResource = "Themen-Update erstellen"
    static var description = IntentDescription(
        "Stellt aus deinen ungehörten Originalstellen eine neue Ausgabe zusammen. "
        + "Startet keine Wiedergabe."
    )
    /// Ausdrücklich nicht: die App nach vorn holen. Zusammenstellen ist
    /// Vorbereitung, und Vorbereitung darf im Hintergrund passieren.
    static var openAppWhenRun = false

    @Parameter(title: "Themen-Update")
    var feed: SmartFeedEntity

    @Parameter(title: "Dauer in Minuten", default: 20,
               inclusiveRange: (5, 120))
    var minutes: Int

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
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

    static var title: LocalizedStringResource = "Diese Stelle merken"
    static var description = IntentDescription(
        "Merkt sich die Stelle, die gerade läuft, mit Quelle, Timecode und Originaltext."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Notiz", default: nil)
    var note: String?

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let (mediaVersionID, position) = model.player.currentOriginalPosition() else {
            return .result(dialog: "Gerade läuft nichts, das ich merken könnte.")
        }
        let saved = await model.rememberPassage(
            at: position, in: mediaVersionID, note: note, via: .appIntent
        )
        return .result(dialog: "\(saved)")
    }
}

/// Stoppt die Wiedergabe.
struct StopPlaybackIntent: AppIntent {

    static var title: LocalizedStringResource = "Wiedergabe stoppen"
    static var openAppWhenRun = false

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.player.stop()
        model.policy.endFocusSession()
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

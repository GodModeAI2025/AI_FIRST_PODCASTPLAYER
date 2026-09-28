//
//  BackgroundRunProgress.swift
//  PodcastAIKit
//
//  Der Fortschritt eines ganzen Laufs im Hintergrund, für die Anzeige der
//  fortgesetzten Verarbeitung (`BGContinuedProcessingTask`).
//
//  iOS beendet eine solche Aufgabe, wenn ihr Fortschritt stehen bleibt
//  („Tasks that appear stalled may be forcibly expired“, BGTask.h im SDK
//  27.0). Bis 0.13 bewegte sich die Anzeige nur beim Transkribieren: Der
//  Download sprang von 20 auf 100, Fakten und Tags nach 950 zählten nicht
//  mehr, und jede neue Folge begann wieder bei 20. Nach einigen Minuten
//  Fakten mit Private Cloud Compute hielt das System die Arbeit für hängend.
//
//  Hier zählt der ganze Lauf: jede Folge mit Laden und Transkript, danach
//  ihre Fakten und ihre Kapitel-Tags, als eine Summe über die Warteschlange.
//  `completedUnitCount` wächst nur, auch über Folgen hinweg.
//  `totalUnitCount` folgt dem, was noch erwartet wird, und liegt immer
//  mindestens eine Einheit darüber.
//
//  Steht ein Schritt eine Weile ohne Meldung, etwa während eines langen
//  Aufrufs bei Private Cloud Compute oder eines zähen Downloads, rückt die
//  Anzeige in kleinen, kleiner werdenden Schritten auf das Ende der
//  laufenden Phase zu, erreicht es aber nie (`tick`). Die nächste echte
//  Meldung übernimmt wieder. Das gilt nur, solange ein Schritt tatsächlich
//  läuft; ohne Schritt bewegt sich nichts.
//
//  Reine Rechnung ohne Uhr: Die verstrichene Zeit gibt der Aufrufer mit.
//

import Foundation
import PodcastAICore

public struct BackgroundRunProgress: Sendable, Equatable {

    /// Die Arten von Schritten eines Laufs.
    public enum Step: String, Sendable, Hashable, CaseIterable {
        case transcript
        case facts
        case tags

        /// Das Gewicht in Einheiten. Ein Transkript dauert meist Minuten,
        /// Fakten und Tags mit Private Cloud Compute deutlich weniger. Die
        /// Einheiten sind fein, damit auch kleine Schritte zählen.
        public var weight: Int64 {
            switch self {
            case .transcript: 10_000
            case .facts: 3_000
            case .tags: 1_500
            }
        }
    }

    /// Wie weit ein Schritt ist. Jede Phase hat eine obere Grenze, bis zu der
    /// das Aufrücken ohne Meldung höchstens geht.
    public enum Phase: Sendable, Equatable {
        /// Der Ton lädt, Anteil der Bytes von 0 bis 1.
        case download(Double)
        /// Das Transkript entsteht, Anteil von 0 bis 1.
        case transcription(Double)
        /// Transkript gespeichert, die Fundstellen entstehen.
        case transcribed
        /// Fakten einer Folge, Anteil der Abschnitte von 0 bis 1.
        case facts(Double)
        /// Kapitel-Tags einer Folge, Anteil der Kapitel von 0 bis 1.
        case tags(Double)

        /// Anteil am Schritt, den diese Meldung bedeutet.
        var value: Double {
            switch self {
            case .download(let f): Self.downloadShare * Self.clamped(f)
            case .transcription(let f): Self.downloadShare + Self.transcriptionShare * Self.clamped(f)
            case .transcribed: Self.downloadShare + Self.transcriptionShare
            case .facts(let f), .tags(let f): Self.workShare * Self.clamped(f)
            }
        }

        /// Bis hierher rückt die Anzeige ohne weitere Meldung höchstens vor.
        var ceiling: Double {
            switch self {
            case .download: Self.downloadShare
            case .transcription: Self.downloadShare + Self.transcriptionShare
            case .transcribed: 1
            case .facts, .tags: 1
            }
        }

        /// Laden ist ein Fünftel eines Transkripts, das Erkennen drei Viertel,
        /// der Rest sind die Fundstellen.
        static let downloadShare = 0.2
        static let transcriptionShare = 0.75
        /// Fakten und Tags lassen das letzte Zwanzigstel fürs Speichern.
        static let workShare = 0.95

        static func clamped(_ value: Double) -> Double {
            value.isFinite ? min(max(value, 0), 1) : 0
        }
    }

    /// Was nach dem laufenden Schritt noch erwartet wird.
    public struct Expected: Sendable, Equatable {
        public var transcripts: Int
        public var facts: Int
        public var tags: Int

        public init(transcripts: Int = 0, facts: Int = 0, tags: Int = 0) {
            self.transcripts = max(0, transcripts)
            self.facts = max(0, facts)
            self.tags = max(0, tags)
        }

        var units: Int64 {
            Int64(transcripts) * Step.transcript.weight + Int64(facts) * Step.facts.weight
                + Int64(tags) * Step.tags.weight
        }
    }

    /// Nach so vielen Sekunden ohne Meldung beginnt das Aufrücken.
    public static let creepDelay: Double = 10
    /// Je Takt rückt die Anzeige um diesen Teil des Abstands zur Grenze vor.
    public static let creepShare: Double = 0.02
    /// Ein Takt des Herzschlags in Sekunden.
    public static let creepInterval: Double = 5

    /// Einheiten der abgeschlossenen Schritte.
    public private(set) var finishedUnits: Int64 = 0
    /// Der laufende Schritt und die Folge, zu der er gehört.
    public private(set) var current: Step?
    public private(set) var currentEpisode: EpisodeID?
    /// Anteil des laufenden Schritts, von 0 bis 1.
    public private(set) var fraction: Double = 0
    /// Bis hier darf das Aufrücken gehen.
    private var ceiling: Double = 0
    /// Sekunden seit der letzten echten Meldung.
    private var idle: Double = 0
    public private(set) var expected = Expected()
    /// Der höchste je gemeldete Stand. Wird nie kleiner.
    public private(set) var completedUnitCount: Int64 = 0

    public init() {}

    /// Die Gesamtzahl: Fertiges, der laufende Schritt und was noch
    /// erwartet wird, immer über dem Stand.
    public var totalUnitCount: Int64 {
        let planned = finishedUnits + (current?.weight ?? 0) + expected.units
        return max(planned, completedUnitCount + 1)
    }

    /// Eine Meldung aus einem Schritt. Gehört sie zu einem anderen Schritt
    /// oder einer anderen Folge als dem laufenden, ist der laufende fertig
    /// und der neue beginnt. Innerhalb eines Schritts geht es nur vorwärts.
    public mutating func report(_ step: Step, episode: EpisodeID, _ phase: Phase) {
        if current != step || currentEpisode != episode {
            finishCurrent()
            current = step
            currentEpisode = episode
            fraction = 0
            ceiling = 0
        }
        fraction = max(fraction, phase.value)
        ceiling = max(ceiling, phase.ceiling, fraction)
        idle = 0
        refresh()
    }

    /// Der laufende Schritt ist fertig, mit seinem ganzen Gewicht, auch wenn
    /// die letzte Meldung kleiner war.
    public mutating func finishCurrent() {
        guard let step = current else { return }
        finishedUnits += step.weight
        current = nil
        currentEpisode = nil
        fraction = 0
        ceiling = 0
        idle = 0
        refresh()
    }

    /// Was nach dem laufenden Schritt noch aussteht, aus den Warteschlangen.
    public mutating func expect(_ expected: Expected) {
        self.expected = expected
    }

    /// Ein Takt ohne Meldung. Nach ``creepDelay`` Sekunden rückt der laufende
    /// Schritt um ``creepShare`` des Abstands zur Grenze seiner Phase vor.
    /// Die Grenze selbst erreicht er so nie.
    public mutating func tick(seconds: Double) {
        guard current != nil, seconds > 0 else { return }
        idle += seconds
        guard idle >= Self.creepDelay, fraction < ceiling else { return }
        fraction += (ceiling - fraction) * Self.creepShare
        refresh()
    }

    private mutating func refresh() {
        let running = current.map { Int64((Double($0.weight) * fraction).rounded(.down)) } ?? 0
        completedUnitCount = max(completedUnitCount, finishedUnits + running)
    }
}

/// Was gerade an Arbeit ansteht, aus den Ständen der Stufen „Transkript“
/// und „Wissen“. Entscheidet, ob die fortgesetzte Verarbeitung gebraucht
/// wird, und schätzt, was nach dem laufenden Schritt noch kommt.
public struct BackgroundWorkLoad: Sendable, Equatable {
    /// Ein Transkript entsteht gerade.
    public var transcriptRunning: Bool
    /// Transkripte, die jetzt laufen dürften, ohne das laufende.
    public var transcriptsQueued: Int
    /// Fakten einer Folge entstehen gerade.
    public var factsRunning: Bool
    public var factsQueued: Int
    /// Kapitel-Tags entstehen gerade.
    public var tagsRunning: Bool
    public var tagsQueued: Int
    /// Fakten und Tags warten auf ein Modell, etwa ohne Netz für Private
    /// Cloud Compute und ohne Gerätemodell. Dann kommen sie nicht voran.
    public var knowledgeWaiting: Bool
    /// „Fakten automatisch sammeln“: Auf jedes Transkript folgen Fakten und Tags.
    public var automaticFacts: Bool

    public init(transcriptRunning: Bool = false, transcriptsQueued: Int = 0,
                factsRunning: Bool = false, factsQueued: Int = 0,
                tagsRunning: Bool = false, tagsQueued: Int = 0,
                knowledgeWaiting: Bool = false, automaticFacts: Bool = true) {
        self.transcriptRunning = transcriptRunning
        self.transcriptsQueued = max(0, transcriptsQueued)
        self.factsRunning = factsRunning
        self.factsQueued = max(0, factsQueued)
        self.tagsRunning = tagsRunning
        self.tagsQueued = max(0, tagsQueued)
        self.knowledgeWaiting = knowledgeWaiting
        self.automaticFacts = automaticFacts
    }

    /// Gibt es Arbeit, die im Hintergrund vorankäme? Fakten und Tags, die
    /// auf ein Modell warten, zählen nicht: Die Anzeige stünde still, und
    /// das System beendete die Aufgabe ohnehin.
    public var hasWork: Bool {
        if transcriptRunning || transcriptsQueued > 0 { return true }
        guard !knowledgeWaiting else { return false }
        return factsRunning || factsQueued > 0 || tagsRunning || tagsQueued > 0
    }

    /// Was nach dem laufenden Schritt noch erwartet wird. Auf ein Transkript
    /// folgen mit „Fakten automatisch sammeln“ seine Fakten, auf Fakten die
    /// Tags derselben Folge. Eine Schätzung: Stimmt sie nicht, ändert sich
    /// nur die Gesamtzahl, nie der Stand.
    public var expected: BackgroundRunProgress.Expected {
        let transcriptsAhead = transcriptsQueued + (transcriptRunning ? 1 : 0)
        let followUps = automaticFacts ? transcriptsAhead : 0
        return BackgroundRunProgress.Expected(
            transcripts: transcriptsQueued,
            facts: factsQueued + followUps,
            tags: tagsQueued + factsQueued + (factsRunning ? 1 : 0) + followUps)
    }
}

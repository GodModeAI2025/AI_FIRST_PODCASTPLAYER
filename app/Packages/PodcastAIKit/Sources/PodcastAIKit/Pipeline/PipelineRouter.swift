//
//  PipelineRouter.swift
//  PodcastAIKit
//
//  Wer welches Ereignis bekommt. Die Verdrahtung der Pipeline steht nur
//  hier, als reine Funktion mit erschöpfendem `switch`: Ein neues Ereignis
//  baut erst, wenn es einen Weg hat.
//
//  Der Router kennt nur Wege, keine Schalter. Ob etwa „Fakten automatisch
//  sammeln“ an ist, gehört dem Hauptakteur und ist im synchronen,
//  nicht isolierten `emit` nicht lesbar. Das prüft die Stufe, wenn sie
//  anfängt.
//

import Foundation

/// Die Empfänger der Pipeline. Die meisten sind Stufen mit eigener Arbeit.
/// „Für dich“ und die Senke rechnen nur nach, was sich geändert hat.
public enum PipelineStage: String, Sendable, Hashable, CaseIterable {
    /// Vorbereiten: was von selbst in die Warteschlange kommt, samt
    /// Metadaten von Supadata.
    case prepare
    /// Download: Vorhalten, Vorausladen und Ton aufräumen.
    case download
    /// Transkript: Ton, Transkript des Podcasts, Zwilling und Untertitel,
    /// eine Folge nach der anderen.
    case transcript
    /// Wissen: Fakten und Kapitel-Tags, eine Folge nach der anderen.
    case knowledge
    /// Ausgaben der Themen-Updates, ihre Zahlen und Cover.
    case editions
    /// Pflege: räumt nach dem Löschen auf, auch nach einem Neustart.
    case maintenance
    /// „Für dich“ rechnet neu.
    case forYou
    /// Die Senke auf dem Hauptakteur schreibt, was die Oberfläche liest.
    case sink
}

/// Ein Ereignis für eine Stufe.
public struct StageInput: Sendable, Equatable {
    public let stage: PipelineStage
    public let event: PipelineEvent

    public init(stage: PipelineStage, event: PipelineEvent) {
        self.stage = stage
        self.event = event
    }
}

public enum PipelineRouter {

    /// Die Eingänge für ein Ereignis, eines je Empfänger.
    public static func deliveries(for event: PipelineEvent) -> [StageInput] {
        receivers(of: event.kind).map { StageInput(stage: $0, event: event) }
    }

    /// Wer Ereignisse dieser Art bekommt. Die Reihenfolge ist fest, sie sagt
    /// aber nichts über die Reihenfolge der Arbeit: Jede Stufe hat ihr
    /// eigenes Postfach.
    public static func receivers(of kind: PipelineEvent.Kind) -> [PipelineStage] {
        switch kind {
        case .episodesAdded:
            // Vorbereiten reiht ein, der Download hält die neueste Folge vor.
            [.prepare, .download]
        case .audioAvailable:
            [.transcript]
        case .audioRemoved:
            // Das Transkript rechnet nur neu, worauf eine Folge wartet. Daten
            // ändert es nicht (Regel 5).
            [.download, .transcript]
        case .transcriptSaved:
            [.sink]
        case .transcriptFailed:
            // Vorbereiten merkt sich den Fehlschlag, der Download räumt den
            // Ton wieder weg, den er nur fürs Transkript geholt hat.
            [.prepare, .download]
        case .evidenceReady:
            // Wissen sammelt Fakten, der Download räumt den Ton auf, das
            // Archiv rückt nach, „Für dich“ und die Senke rechnen neu.
            [.prepare, .download, .knowledge, .forYou, .sink]
        case .transcriptsIdle:
            [.editions]
        case .factsDone:
            // Nach den Fakten einer Folge kommen ihre Tags.
            [.knowledge]
        case .tagsDone:
            [.sink]
        case .feedsRefreshed:
            // Dieselben Folgen wie heute nach `refreshAll`: einreihen,
            // fehlende Fakten suchen, „Für dich“, Ton aufräumen, Ausgaben.
            [.prepare, .download, .knowledge, .forYou, .editions]
        case .editionPublished:
            // Cover und Zahlen der neuen Ausgabe.
            [.editions]
        case .episodesRemoved:
            // Alle brechen ab und vergessen die Folgen, die Pflege räumt auf.
            [.prepare, .download, .transcript, .knowledge, .editions, .maintenance, .forYou, .sink]
        case .changedElsewhere:
            // Jede Stufe gleicht ihre Arbeit mit dem Store ab.
            [.prepare, .download, .transcript, .knowledge, .editions, .maintenance, .forYou]
        }
    }
}

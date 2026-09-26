//
//  PipelineOutcomes.swift
//  PodcastAIKit
//
//  Wie ein Lauf der Fakten oder der Kapitel-Tags ausging. Bis 0.12 lagen
//  beide Typen in der App. Die Ereignisse `factsDone` und `tagsDone` tragen
//  sie, also stehen sie jetzt im Paket.
//

import Foundation
import PodcastAIIntelligence

/// Wie ein Lauf der Fakten einer Folge ausging.
public enum FactsOutcome: Sendable, Equatable {
    /// Die Fakten liegen vor, frisch gespeichert oder schon vorhanden.
    case stored
    /// Nichts zu tun: keine Stellen mit Zeitmarke, die Folge ist gelöscht,
    /// oder für sie läuft schon ein Lauf.
    case nothingToDo
    /// Durchgelaufen, aber ohne Fakten: das Modell hat alles abgelehnt
    /// oder keine überprüfbare Aussage gefunden. Mit demselben Modell
    /// käme wieder dasselbe heraus.
    case noFacts(String)
    /// Gescheitert aus einem Grund, der vorbeigeht: Last,
    /// Zeitüberschreitung, Speichern.
    case failed(String?)
    /// Gespeichert, aber mit Lücken: einzelne Abschnitte sind aus einem
    /// Grund gescheitert, der vorbeigeht. Ein späterer Lauf holt nur sie nach.
    case partial(String?)
    /// Das Gerätemodell steht gerade nicht bereit.
    case modelUnavailable(ModelUnavailability)
    /// Abgebrochen, etwa weil die Hintergrundzeit endet.
    case cancelled
}

/// Wie eine Einordnung der Kapitel einer Folge ausging.
public enum ChapterTagsOutcome: Sendable, Equatable {
    /// Gespeichert, auch wenn kein Kapitel ein Tag bekam.
    case stored
    /// Nichts zu tun: schon eingeordnet, keine Belege oder gelöscht.
    case nothingToDo
    /// Kein Modell für Tags. Die Folge wartet.
    case modelUnavailable
    /// Nur Private Cloud Compute stünde bereit, und das Netz erlaubt gerade
    /// kein Vorbereiten. Die Folge wartet.
    case waiting
    /// Abgebrochen, etwa weil die Zeit im Hintergrund endete. Die fertigen
    /// Kapitel bleiben gemerkt.
    case cancelled
    /// Ein Aufruf ist an Last oder Zeit gescheitert. Ein späterer Lauf setzt fort.
    case failed
}

//
//  EpisodeProgress.swift
//  PodcastAI
//
//  Wo die Arbeit an einer Folge steht, je Folge beobachtbar.
//
//  Bis 0.10 lagen Stufe, Angabe und Fortschritt der Fakten als Wörterbücher
//  im `AppModel`. Jede Änderung an einer Folge meldete das ganze Wörterbuch
//  als geändert, und jede Zeile jeder Folgenliste, die ihre Stufe las,
//  zeichnete sich neu. Während die Warteschlange lief, geschah das bei
//  jedem Schritt und bei jeder Prüfung des Netzes für alle wartenden Folgen.
//
//  Jetzt hat jede Folge einen eigenen Eintrag. Eine Ansicht liest nur den
//  Eintrag ihrer Folge und hängt nur an ihm. Wer denselben Wert noch einmal
//  schreibt, löst nichts aus.
//

import Foundation
import Observation
import PodcastAIKit

/// Stufe, Angabe und Fortschritt der Fakten einer Folge.
@MainActor
@Observable
final class EpisodeProgress {
    var stage: ProcessingStage?
    var detail: String?
    var factsFraction: Double?
}

/// Alle Einträge. Selbst nicht beobachtbar: ein Eintrag entsteht beim
/// ersten Lesen oder Schreiben und bleibt, damit eine Ansicht, die ihn
/// einmal gelesen hat, auch spätere Änderungen sieht.
@MainActor
final class EpisodeProgressBoard {
    private var entries: [EpisodeID: EpisodeProgress] = [:]

    func entry(_ id: EpisodeID) -> EpisodeProgress {
        if let entry = entries[id] { return entry }
        let entry = EpisodeProgress()
        entries[id] = entry
        return entry
    }
}

/// Liest und schreibt einen Wert je Folge wie ein Wörterbuch:
/// `model.stages[id]`, `model.stageDetails[id] = nil`.
@MainActor
public struct EpisodeProgressMap<Value: Equatable> {
    private let board: EpisodeProgressBoard
    private let keyPath: ReferenceWritableKeyPath<EpisodeProgress, Value?>

    init(_ board: EpisodeProgressBoard, _ keyPath: ReferenceWritableKeyPath<EpisodeProgress, Value?>) {
        self.board = board
        self.keyPath = keyPath
    }

    public subscript(id: EpisodeID) -> Value? {
        get { board.entry(id)[keyPath: keyPath] }
        nonmutating set {
            let entry = board.entry(id)
            guard entry[keyPath: keyPath] != newValue else { return }
            entry[keyPath: keyPath] = newValue
        }
    }
}

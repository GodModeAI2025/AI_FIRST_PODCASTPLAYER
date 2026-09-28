//
//  PipelineHost.swift
//  PodcastAIKit
//
//  Nimmt Ereignisse an und legt sie in die Postfächer der Stufen, die der
//  Router nennt. Entsteht einmal je Prozess in `AppBootstrap.start`, nicht
//  je Szene: Auf dem iPad läuft `.task` je Fenster.
//
//  `emit(_:)` ist nicht isoliert und synchron. Es wartet nie, also kann es
//  jeder aufrufen, auch der Hauptakteur mitten in einem Abschnitt ohne
//  `await`. Ein Postfach ist ein `AsyncStream` ohne Grenze. Zwischen einem
//  Sender und einer Stufe gilt die Reihenfolge des Sendens. Ein Ereignis
//  kommt höchstens einmal an; dass die Arbeit genau einmal wirkt, sichern
//  die Prüfung im Store und `reconcile()`.
//
//  Ein Postfach entsteht erst, wenn eine Stufe zuhört. Ein Ereignis für
//  eine Stufe ohne Postfach fällt weg. So wächst kein Puffer, solange eine
//  Stufe noch im alten Code steckt, und das Senden kostet dann fast nichts.
//

import Foundation
import Synchronization
import PodcastAICore

public final class PipelineHost: Sendable {

    private struct Mailbox {
        let token: UInt64
        let continuation: AsyncStream<PipelineEvent>.Continuation
    }

    private struct State {
        var mailboxes: [PipelineStage: Mailbox] = [:]
        var nextToken: UInt64 = 0
    }

    /// Wann Arbeit laufen darf. Ein Zustand, kein Ereignis.
    public let gate: WorkGate

    private let state = Mutex(State())

    public init(gate: WorkGate = WorkGate()) {
        self.gate = gate
    }

    /// Sendet ein Ereignis an alle Stufen, die der Router nennt und die
    /// zuhören.
    public func emit(_ event: PipelineEvent) {
        let receivers = PipelineRouter.receivers(of: event.kind)
        state.withLock { state in
            // Unter der Sperre, damit zwei Sender sich nicht überholen,
            // während jemand ein Postfach öffnet oder schließt. `yield`
            // wartet nie.
            for stage in receivers {
                state.mailboxes[stage]?.continuation.yield(event)
            }
        }
    }

    /// Sendet Ereignisse zu einer Folge, außer sie wurde seit `ticket`
    /// gelöscht. Für Ereignisse, die erst nach einem `await` hinausgehen,
    /// etwa weil sie ihre Eingangsfassung im Store lesen: Ohne diese Prüfung
    /// käme `evidenceReady` einer Folge womöglich hinter ihrem
    /// `episodesRemoved` an, und eine Stufe nähme die gelöschte Folge wieder auf.
    ///
    /// Geprüft und gesendet wird unter der Sperre des Löschprotokolls. Wer
    /// löscht, schreibt dort zuerst und sendet `episodesRemoved` erst danach.
    /// Also liegen diese Ereignisse entweder vor dem Löschen im Postfach
    /// oder gar nicht. Gibt zurück, ob gesendet wurde.
    @discardableResult
    public func emit(_ events: [PipelineEvent], about id: EpisodeID,
                     unlessRemovedSince ticket: RemovalLedger.Ticket, in ledger: RemovalLedger) -> Bool {
        ledger.unlessRemoved(id, since: ticket) { () -> Void in
            for event in events { emit(event) }
        } != nil
    }

    /// Das Postfach einer Stufe. Eine Stufe hat einen Besitzer: Wer ein
    /// zweites öffnet, beendet das erste. Hört der Leser auf, fällt das
    /// Postfach weg.
    public func mailbox(for stage: PipelineStage) -> AsyncStream<PipelineEvent> {
        let (stream, continuation) = AsyncStream<PipelineEvent>.makeStream(bufferingPolicy: .unbounded)
        let (token, previous) = state.withLock { state -> (UInt64, AsyncStream<PipelineEvent>.Continuation?) in
            state.nextToken += 1
            let previous = state.mailboxes[stage]?.continuation
            state.mailboxes[stage] = Mailbox(token: state.nextToken, continuation: continuation)
            return (state.nextToken, previous)
        }
        // Außerhalb der Sperre: `finish` ruft das `onTermination` des alten
        // Postfachs, und das greift wieder zur Sperre.
        previous?.finish()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                if state.mailboxes[stage]?.token == token { state.mailboxes[stage] = nil }
            }
        }
        return stream
    }

    /// Hört eine Stufe zu, die Ereignisse dieser Art bekäme? Wer ein
    /// Ereignis erst aus dem Store zusammensetzen muss, fragt vorher, damit
    /// die eine Queue des Stores keine Arbeit für niemanden bekommt.
    public func hasListeners(for kind: PipelineEvent.Kind) -> Bool {
        let receivers = PipelineRouter.receivers(of: kind)
        return state.withLock { state in receivers.contains { state.mailboxes[$0] != nil } }
    }

    /// Welche Stufen gerade zuhören.
    public var listeningStages: Set<PipelineStage> {
        state.withLock { Set($0.mailboxes.keys) }
    }
}

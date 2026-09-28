//
//  RemovalLedger.swift
//  PodcastAICore
//
//  Das Löschprotokoll eines Prozesses. Eine Arbeit zieht beim Start einen
//  Stand und erkennt daran, ob ihre Folge gelöscht wurde, während sie lief.
//
//  Bis 0.12 führten das Modell der App und drei Zwischenspeicher (Nennungen,
//  Sätze je Kapitel, Übersetzungen) je einen eigenen Zähler. Jetzt gibt es
//  einen, ohne Akteur und hinter einer Sperre (`Mutex` aus der
//  Standardbibliothek), damit auch Code abseits des Hauptakteurs synchron
//  fragen kann.
//
//  Eine bloße Menge gelöschter Kennungen reicht nicht: Wer eine Quelle
//  abbestellt und im selben Prozess neu abonniert, bekommt dieselben
//  Kennungen zurück. Deshalb bekommt jede Löschung einen neuen Stand, und
//  eine Arbeit gilt nur dann als überholt, wenn ihre Folge nach ihrem Start
//  gelöscht wurde.
//
//  Gespeichert wird nichts. Nach einem Neustart läuft keine alte Arbeit mehr.
//

import Foundation
import Synchronization

public final class RemovalLedger: Sendable {

    /// Ein Stand des Protokolls. Jede Löschung zählt eins weiter.
    public struct Ticket: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let value: Int

        public init(_ value: Int) { self.value = value }

        public static func < (lhs: Ticket, rhs: Ticket) -> Bool { lhs.value < rhs.value }

        public var description: String { "\(value)" }
    }

    private struct State {
        var count = 0
        var episodes: [EpisodeID: Int] = [:]
        var sources: [SourceID: Int] = [:]
    }

    /// Eines je Prozess. Tests legen sich ein eigenes an.
    public static let shared = RemovalLedger()

    private let state = Mutex(State())

    public init() {}

    /// Der Stand jetzt. Eine Arbeit zieht ihn, bevor sie liest.
    public var ticket: Ticket { state.withLock { Ticket($0.count) } }

    /// Merkt die Löschung dieser Folgen vor, bei einer abbestellten Quelle
    /// auch die Quelle. Zählt einmal weiter, auch ohne Folgen: eine
    /// Abbestellung ist immer ein neuer Stand.
    @discardableResult
    public func markRemoved(_ ids: some Sequence<EpisodeID>, source: SourceID? = nil) -> Ticket {
        state.withLock { state in
            state.count += 1
            for id in ids { state.episodes[id] = state.count }
            if let source { state.sources[source] = state.count }
            return Ticket(state.count)
        }
    }

    /// Wurde die Folge gelöscht, nachdem eine Arbeit mit diesem Stand begann?
    public func wasRemoved(_ id: EpisodeID, since ticket: Ticket) -> Bool {
        state.withLock { Self.removed(id, since: ticket, in: $0) }
    }

    /// Wurde die Quelle abbestellt, nachdem eine Arbeit mit diesem Stand begann?
    public func wasRemoved(source: SourceID, since ticket: Ticket) -> Bool {
        state.withLock { state in
            guard let removedAt = state.sources[source] else { return false }
            return removedAt > ticket.value
        }
    }

    /// Gab es seit diesem Stand überhaupt eine Löschung?
    public func hasRemovals(since ticket: Ticket) -> Bool {
        state.withLock { $0.count > ticket.value }
    }

    /// Führt `body` nur aus, wenn die Folge seit `ticket` nicht gelöscht
    /// wurde, und zwar unter derselben Sperre wie `markRemoved`. So fällt
    /// keine Löschung zwischen Prüfen und Handeln. Gibt `nil` zurück, wenn
    /// nichts ausgeführt wurde.
    ///
    /// `body` hält die Sperre, die auch der Hauptakteur bei jeder Meldung
    /// eines Transkripts fragt. Es bleibt deshalb kurz: keine Datei
    /// schreiben, kein Netz, nichts, was selbst das Protokoll fragt. Für
    /// Dateien gibt es ``write(_:to:staging:for:since:)``.
    @discardableResult
    public func unlessRemoved<Result>(
        _ id: EpisodeID, since ticket: Ticket, _ body: () throws -> Result
    ) rethrows -> Result? {
        try state.withLock { state in
            if Self.removed(id, since: ticket, in: state) { return nil }
            return try body()
        }
    }

    /// Legt eine Datei ab, die aus einer Folge entstanden ist, außer die
    /// Folge wurde seit `ticket` gelöscht.
    ///
    /// Geschrieben wird zuerst eine Zwischendatei, außerhalb der Sperre.
    /// Unter der Sperre kommen nur noch die Prüfung, der Ordner und das
    /// Umbenennen, also Arbeit von Mikrosekunden. Wer die Dateien der Folge
    /// nach `markRemoved` entfernt, erwischt damit auch alles, was hier noch
    /// durchging, und nichts kommt danach zurück.
    ///
    /// Die Zwischendatei liegt im Ordner des Systems für Zwischenstände
    /// (`itemReplacementDirectory`), wie bei `Data.write(options: .atomic)`.
    /// Endet der Prozess zwischen Schreiben und Umbenennen, räumt das System
    /// sie weg. Im Ordner des Zwischenspeichers bliebe sie für immer liegen.
    ///
    /// `staging` liegt auf demselben Datenträger wie `file`, am besten der
    /// Ordner des Zwischenspeichers selbst. Danach wählt das System seinen
    /// Ordner, und nur wenn es keinen hergibt, liegt die Zwischendatei dort.
    @discardableResult
    public func write(_ data: Data, to file: URL, staging: URL,
                      for id: EpisodeID, since ticket: Ticket) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let system = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: staging, create: true)
        let scratch = (system ?? staging).appendingPathComponent(".staging-\(UUID().uuidString)")
        defer {
            // Nach dem Umbenennen ist die Zwischendatei schon weg, sonst geht sie hier.
            try? fileManager.removeItem(at: system ?? scratch)
        }
        do {
            try data.write(to: scratch)
        } catch {
            return false
        }
        return unlessRemoved(id, since: ticket) { () -> Bool in
            try? fileManager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return rename(scratch.path, file.path) == 0
        } ?? false
    }

    private static func removed(_ id: EpisodeID, since ticket: Ticket, in state: State) -> Bool {
        guard let removedAt = state.episodes[id] else { return false }
        return removedAt > ticket.value
    }
}

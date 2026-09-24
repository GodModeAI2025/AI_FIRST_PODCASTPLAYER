//
//  ProcessingTrace.swift
//  PodcastAIKit
//
//  Messpunkte für das Erschließen von Folgen: Laden, Transkript, Belege,
//  Fakten, Kapitel-Tags, Themen-Updates und jeder Sprung zurück auf den
//  Hauptakteur. Jeder Schritt ist ein Intervall in Instruments
//  (os_signpost, Kategorie „processing“). Wer auf dem Gerät wissen will,
//  wo die Zeit hingeht oder wann der Hauptthread steht, legt im Profiler
//  das Instrument „os_signpost“ neben „Hangs“.
//
//  Im Protokoll stehen nur Namen der Schritte und Zahlen, nie Titel,
//  Transkripte oder Fakten.
//

import Foundation
import os

public enum ProcessingTrace {

    public static let signposter = OSSignposter(subsystem: ChatTrace.subsystem, category: "processing")
    public static let logger = Logger(subsystem: ChatTrace.subsystem, category: "processing")

    /// Misst einen Schritt als Intervall und schreibt seine Dauer ins Protokoll.
    @discardableResult
    public static func interval<T>(
        _ name: StaticString,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            log(name, since: start)
        }
        return try await work()
    }

    /// Dasselbe für Arbeit ohne `await`.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            log(name, since: start)
        }
        return try work()
    }

    /// Beginnt ein Intervall, das anderswo endet, etwa auf einem anderen
    /// Akteur. Ohne Eintrag im Protokoll: solche Intervalle sind häufig.
    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Ein einzelnes Ereignis, etwa eine neue Stufe einer Folge.
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    static func log(_ name: StaticString, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        logger.debug("\(name.description, privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }
}

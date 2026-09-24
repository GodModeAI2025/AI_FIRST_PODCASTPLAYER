//
//  ChatTrace.swift
//  PodcastAIIntelligence
//
//  Messpunkte für den Chat. Jeder Schritt einer Frage ist ein Intervall in
//  Instruments (os_signpost, Kategorie „chat“) und eine Zeile im Protokoll
//  mit seiner Dauer. So lässt sich auf dem Gerät sehen, wohin die Zeit geht,
//  ohne dass die App dafür anders gebaut werden muss.
//
//  Im Protokoll stehen nur Namen der Schritte und Zahlen, nie Fragen,
//  Transkripte oder Antworten.
//

import Foundation
import os

public enum ChatTrace {

    public static let subsystem = "com.godmodeai.podcastai"
    public static let signposter = OSSignposter(subsystem: subsystem, category: "chat")
    public static let logger = Logger(subsystem: subsystem, category: "chat")

    /// Misst einen Schritt als Intervall und schreibt seine Dauer ins Protokoll.
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
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            log(name, since: start)
        }
        return try work()
    }

    /// Ein einzelnes Ereignis, etwa der Rückfall von PCC aufs Gerät.
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        logger.debug("\(name.description, privacy: .public)")
    }

    /// Schreibt die Dauer seit `start` ins Protokoll.
    public static func log(_ name: StaticString, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        logger.debug("\(name.description, privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }
}

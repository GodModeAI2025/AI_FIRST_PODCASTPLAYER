//
//  AISchedulerTests.swift
//  PodcastAIKitTests
//
//  Die eine Stelle für Apple Intelligence, ohne Modell: eine Anfrage zur
//  Zeit, Menschen zuerst, Hintergrund wartet auf Ruhe und wird für eine
//  Frage abgebrochen und wiederholt.
//

import Testing
import Foundation
import Synchronization
@testable import PodcastAIIntelligence

/// Merkt sich, was wann lief.
private final class Recorder: Sendable {
    let events = Mutex<[String]>([])
    let active = Mutex(0)
    let maxActive = Mutex(0)
    func add(_ event: String) { events.withLock { $0.append(event) } }
    func enter() {
        let now = active.withLock { value -> Int in value += 1; return value }
        maxActive.withLock { $0 = max($0, now) }
    }
    func leave() { active.withLock { $0 -= 1 } }
    var all: [String] { events.withLock { $0 } }
}

private func work(_ recorder: Recorder, _ name: String, for duration: Duration) -> @Sendable () async throws -> String {
    {
        recorder.enter()
        defer { recorder.leave() }
        recorder.add("start \(name)")
        try await Task.sleep(for: duration)
        recorder.add("end \(name)")
        return name
    }
}

@Suite("Eine Stelle für Apple Intelligence")
struct AISchedulerTests {

    @Test("Es läuft immer nur eine Anfrage")
    func oneAtATime() async throws {
        let scheduler = AIScheduler(idleInterval: .zero, backgroundPause: .zero)
        let recorder = Recorder()
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await scheduler.run(.facts, priority: .background,
                                            operation: work(recorder, "b\(index)", for: .milliseconds(20)))
                }
            }
            group.addTask {
                try await scheduler.run(.answer, priority: .user, operation: work(recorder, "u", for: .milliseconds(20)))
            }
            try await group.waitForAll()
        }
        #expect(recorder.maxActive.withLock { $0 } == 1)
        #expect(recorder.all.filter { $0.hasPrefix("end") }.count == 5)
    }

    @Test("Eine Frage bricht Arbeit im Hintergrund ab, die danach von vorn läuft")
    func userPreemptsBackground() async throws {
        let scheduler = AIScheduler(idleInterval: .zero, backgroundPause: .zero)
        let recorder = Recorder()
        let background = Task {
            try await scheduler.run(.facts, priority: .background, operation: work(recorder, "b", for: .milliseconds(400)))
        }
        try await Task.sleep(for: .milliseconds(50))
        let answer = try await scheduler.run(.answer, priority: .user, operation: work(recorder, "u", for: .milliseconds(20)))
        #expect(answer == "u")
        #expect(try await background.value == "b")
        // Erst der abgebrochene Anfang, dann die Frage, dann der Hintergrund von vorn.
        #expect(recorder.all == ["start b", "start u", "end u", "start b", "end b"])
    }

    @Test("Hintergrund wartet, solange jemand scrollt")
    func backgroundWaitsForIdle() async throws {
        let scheduler = AIScheduler(idleInterval: .milliseconds(300), backgroundPause: .zero)
        let recorder = Recorder()
        scheduler.noteInteraction()
        let started = ContinuousClock.now
        _ = try await scheduler.run(.tags, priority: .background, operation: work(recorder, "b", for: .zero))
        #expect(ContinuousClock.now - started >= .milliseconds(290))
        // Eine Frage wartet nicht auf die Ruhe.
        scheduler.noteInteraction()
        let asked = ContinuousClock.now
        _ = try await scheduler.run(.answer, priority: .user, operation: work(recorder, "u", for: .zero))
        #expect(ContinuousClock.now - asked < .milliseconds(250))
    }

    @Test("Solange eine Liste scrollt, beginnt nichts im Hintergrund, danach nach der Ruhezeit")
    func backgroundWaitsWhileScrolling() async throws {
        let scheduler = AIScheduler(idleInterval: .milliseconds(100), backgroundPause: .zero)
        let recorder = Recorder()
        scheduler.noteScrolling(true)
        let background = Task {
            try await scheduler.run(.facts, priority: .background, operation: work(recorder, "b", for: .zero))
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.all.isEmpty)
        let ended = ContinuousClock.now
        scheduler.noteScrolling(false)
        _ = try await background.value
        #expect(ContinuousClock.now - ended >= .milliseconds(90))
        #expect(recorder.all == ["start b", "end b"])
    }

    @Test("Zwischen zwei Anfragen im Hintergrund liegt eine Pause")
    func pauseBetweenBackgroundRequests() async throws {
        let scheduler = AIScheduler(idleInterval: .zero, backgroundPause: .milliseconds(200))
        let recorder = Recorder()
        _ = try await scheduler.run(.facts, priority: .background, operation: work(recorder, "1", for: .zero))
        let between = ContinuousClock.now
        _ = try await scheduler.run(.facts, priority: .background, operation: work(recorder, "2", for: .zero))
        #expect(ContinuousClock.now - between >= .milliseconds(190))
    }

    @Test("Während einer Frage beginnt nichts im Hintergrund")
    func userActivityHoldsBackground() async throws {
        let scheduler = AIScheduler(idleInterval: .zero, backgroundPause: .zero)
        let recorder = Recorder()
        await scheduler.beginUserActivity()
        let background = Task {
            try await scheduler.run(.facts, priority: .background, operation: work(recorder, "b", for: .zero))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.all.isEmpty)
        #expect(await scheduler.snapshot().queued[.facts] == 1)
        await scheduler.endUserActivity()
        _ = try await background.value
        #expect(recorder.all == ["start b", "end b"])
    }

    @Test("Wer abbricht, während er wartet, bekommt einen Abbruch")
    func cancelWhileWaiting() async throws {
        let scheduler = AIScheduler(idleInterval: .zero, backgroundPause: .zero)
        let recorder = Recorder()
        scheduler.setBackgroundHeld(true)
        let waiting = Task {
            try await scheduler.run(.tags, priority: .background, operation: work(recorder, "b", for: .zero))
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(recorder.all.isEmpty)
        #expect(await scheduler.snapshot().queuedCount == 0)
    }
}

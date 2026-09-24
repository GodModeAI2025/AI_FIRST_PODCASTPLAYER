//
//  AnswerStreamingTests.swift
//
//  Was während einer Antwort sichtbar wird und wie viel in sie hineinpasst:
//  - Der Text im Entstehen zeigt keine Blocknamen aus dem Prompt, auch
//    keinen halben am Ende. Verweise bleiben stehen, ungeprüft.
//  - Die Zahl der Stellen folgt den gezählten Token, in Schritten von vier,
//    nie unter vier, nie über der Decke der Stufe.
//  - Zählt der Tokenizer nicht, gilt die alte Schätzung.
//  - Die Zeile zu den Apple-Servern nennt den Zeitpunkt, ab dem es wieder geht.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIIntelligence

@Suite("Antwort im Entstehen")
struct PartialAnswerTextTests {

    @Test("Blocknamen fallen weg, Verweise bleiben", arguments: [
        ("Das steht in der Bibliothek [BIBLIOTHEK].", "Das steht in der Bibliothek."),
        ("Er sagt (BIBLIOTHEK) das Gegenteil [3].", "Er sagt das Gegenteil [3]."),
        ("Zwei Stellen [3, 5] und [Musik].", "Zwei Stellen [3, 5] und [Musik]."),
        ("Beides [4, BIBLIOTHEK].", "Beides [4]."),
        ("Ohne Klammer.", "Ohne Klammer."),
    ])
    func closedMarkers(raw: String, expected: String) {
        #expect(KnowledgeExtractor.partialAnswerText(raw) == expected)
    }

    @Test("Ein angefangener Blockname oder Verweis am Ende bleibt verborgen", arguments: [
        ("Laut der Folge [3] geht es um Strom [BIBLIO", "Laut der Folge [3] geht es um Strom"),
        ("Es geht um Strom [", "Es geht um Strom"),
        ("Es geht um Strom [1", "Es geht um Strom"),
        ("Es geht um Strom (Bib", "Es geht um Strom"),
        ("Es geht um Strom (", "Es geht um Strom"),
    ])
    func openMarkers(raw: String, expected: String) {
        #expect(KnowledgeExtractor.partialAnswerText(raw) == expected)
    }

    @Test("Offene runde Klammern mit anderem Inhalt bleiben stehen", arguments: [
        "Das war (2023",
        "Das war (etwa",
        "Das sagt die DSGVO (Datenschutz",
    ])
    func ordinaryParentheses(raw: String) {
        #expect(KnowledgeExtractor.partialAnswerText(raw) == raw)
    }

    @Test("Zeilenumbrüche und Steuerzeichen werden zu Leerzeichen")
    func whitespace() {
        #expect(KnowledgeExtractor.partialAnswerText("Erste Zeile\nzweite\tZeile") == "Erste Zeile zweite Zeile")
    }

    @Test("Die fertige Antwort prüft Verweise, der Text im Entstehen nicht")
    func unvalidatedCitations() {
        let raw = "Das stimmt [9]."
        #expect(KnowledgeExtractor.partialAnswerText(raw) == raw)
        #expect(KnowledgeExtractor.cleanedAnswerText(raw, validNumbers: [1, 2]) == "Das stimmt.")
    }
}

@Suite("Budget nach Token")
struct AnswerTokenPlanTests {

    @Test("Stellen in Schritten von vier, zwischen vier und der Decke")
    func steps() {
        let count = AnswerTokenPlan.candidateCount(
            contextSize: 8_192, fixedTokens: 1_200, tokensPerCandidate: 150, ceiling: 60)
        #expect(count % AnswerTokenPlan.step == 0)
        #expect(count == (8_192 - 1_200 - AnswerTokenPlan.answerReserve) / 150 / 4 * 4)
        #expect(AnswerTokenPlan.candidateCount(
            contextSize: 8_192, fixedTokens: 1_200, tokensPerCandidate: 150, ceiling: 16) == 16)
        #expect(AnswerTokenPlan.candidateCount(
            contextSize: 2_000, fixedTokens: 1_900, tokensPerCandidate: 150, ceiling: 32) == 4)
        #expect(AnswerTokenPlan.candidateCount(
            contextSize: 2_000, fixedTokens: 1_900, tokensPerCandidate: 150, ceiling: 2) == 2)
    }

    @Test("Mehr Fenster heißt nie weniger Stellen")
    func monotone() {
        var previous = 0
        for size in stride(from: 2_048, through: 65_536, by: 1_024) {
            let count = AnswerTokenPlan.candidateCount(
                contextSize: size, fixedTokens: 1_500, tokensPerCandidate: 140, ceiling: 60)
            #expect(count >= previous)
            previous = count
        }
        #expect(previous == 60)
    }

    @Test("Gezählt wird zweimal, und die gezählten Token bestimmen das Budget")
    func measured() async {
        let calls = Counter()
        let budget = await AnswerTokenPlan.fitted(
            ContextBudget(maximumCandidates: 32, excerptLimit: 420, libraryContextLimit: 3_000),
            contextSize: 8_192, fixedText: "fest", schemaTokens: 200,
            sample: "probe", sampleCount: 8
        ) { text in
            calls.value += 1
            return text == "fest" ? 1_000 : 8 * 120
        }
        #expect(calls.value == 2)
        // (8192 - 1000 - 200 - 800) / 120 = 51, gedeckelt auf 32.
        #expect(budget.maximumCandidates == 32)
        #expect(budget.excerptLimit == 420)
        #expect(budget.libraryContextLimit == 3_000)

        let tight = await AnswerTokenPlan.fitted(
            ContextBudget(maximumCandidates: 32, excerptLimit: 420, libraryContextLimit: 3_000),
            contextSize: 4_096, fixedText: "fest", schemaTokens: 200,
            sample: "probe", sampleCount: 8
        ) { text in text == "fest" ? 1_000 : 8 * 120 }
        // (4096 - 1000 - 200 - 800) / 120 = 17, abgerundet auf 16.
        #expect(tight.maximumCandidates == 16)
    }

    @Test("Ein Aufschlag macht das Budget kleiner")
    func margin() async {
        let base = ContextBudget(maximumCandidates: 60, excerptLimit: 900, libraryContextLimit: 6_000)
        let plain = await AnswerTokenPlan.fitted(
            base, contextSize: 16_000, fixedText: "fest", schemaTokens: 200,
            sample: "probe", sampleCount: 8) { text in text == "fest" ? 2_000 : 8 * 250 }
        let padded = await AnswerTokenPlan.fitted(
            base, contextSize: 16_000, fixedText: "fest", schemaTokens: 200,
            sample: "probe", sampleCount: 8, margin: 1.2) { text in text == "fest" ? 2_000 : 8 * 250 }
        #expect(padded.maximumCandidates < plain.maximumCandidates)
    }

    @Test("Zählt der Tokenizer nicht, gilt die Schätzung mit drei Zeichen je Token")
    func fallback() async {
        struct Broken: Error {}
        let fixedText = String(repeating: "a", count: 3_000)
        let budget = await AnswerTokenPlan.fitted(
            ContextBudget(maximumCandidates: 32, excerptLimit: 420, libraryContextLimit: 3_000),
            contextSize: 4_096, fixedText: fixedText, schemaTokens: nil,
            sample: "probe", sampleCount: 8
        ) { _ in throw Broken() }
        let expected = AnswerTokenPlan.candidateCount(
            contextSize: 4_096, fixedTokens: 1_000 + 350,
            tokensPerCandidate: Double(420 + 8) / 3, ceiling: 32)
        #expect(budget.maximumCandidates == expected)
        #expect(expected == 12)
    }

    #if canImport(FoundationModels)
    @Test("Hängt der Tokenizer, wartet die Frage nur bis zur Frist")
    func tokenDeadline() async throws {
        let fast = try await KnowledgeExtractor.withinTokenDeadline(.seconds(2)) { 42 }
        #expect(fast == 42)

        let started = ContinuousClock.now
        await #expect(throws: KnowledgeExtractor.TokenCountTimeout.self) {
            try await KnowledgeExtractor.withinTokenDeadline(.milliseconds(100)) {
                try? await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
    #endif
}

/// Zählt Aufrufe aus einer Schließung heraus.
private final class Counter: @unchecked Sendable {
    var value = 0
}

@Suite("Grenzen der Apple-Server")
struct PrivateCloudLimitTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test("Heute ausgeschöpft nennt nur die Uhrzeit")
    func sameDay() {
        let reset = date(24, 18)
        let time = PrivateCloudLimit.time(reset, calendar: calendar)
        let note = PrivateCloudLimit.quotaExhausted(resetDate: reset).note(now: date(24, 9), calendar: calendar)
        #expect(note == TestLanguage.pick(
            de: "Apple-Server heute ausgeschöpft, wieder ab \(time). Diese Antwort kommt vom Gerät.",
            en: "Apple servers are used up for today, back at \(time). This answer comes from your device."))
    }

    @Test("Ein anderer Tag nennt Datum und Uhrzeit")
    func otherDay() {
        let reset = date(25, 6)
        let moment = PrivateCloudLimit.dayAndTime(reset, calendar: calendar)
        let note = PrivateCloudLimit.quotaExhausted(resetDate: reset).note(now: date(24, 22), calendar: calendar)
        #expect(note == TestLanguage.pick(
            de: "Apple-Server ausgeschöpft, wieder ab \(moment). Diese Antwort kommt vom Gerät.",
            en: "Apple servers are used up, back on \(moment). This answer comes from your device."))
    }

    @Test("Ohne Zeitpunkt oder mit einem vergangenen steht keiner da")
    func noDate() {
        let expected = TestLanguage.pick(
            de: "Apple-Server gerade ausgeschöpft. Diese Antwort kommt vom Gerät.",
            en: "Apple servers are used up for now. This answer comes from your device.")
        #expect(PrivateCloudLimit.quotaExhausted(resetDate: nil).note(now: date(24, 9), calendar: calendar) == expected)
        #expect(PrivateCloudLimit.quotaExhausted(resetDate: date(24, 8))
            .note(now: date(24, 9), calendar: calendar) == expected)
    }

    @Test("Ausgelastet ist etwas anderes als ausgeschöpft")
    func rateLimited() {
        let reset = date(24, 18, 5)
        let time = PrivateCloudLimit.time(reset, calendar: calendar)
        #expect(PrivateCloudLimit.rateLimited(resetDate: reset).note(now: date(24, 18), calendar: calendar)
            == TestLanguage.pick(
                de: "Apple-Server gerade ausgelastet, wieder ab \(time). Diese Antwort kommt vom Gerät.",
                en: "Apple servers are busy right now, back at \(time). This answer comes from your device."))
        #expect(PrivateCloudLimit.rateLimited(resetDate: nil).note(now: date(24, 18), calendar: calendar)
            == TestLanguage.pick(
                de: "Apple-Server gerade ausgelastet. Diese Antwort kommt vom Gerät.",
                en: "Apple servers are busy right now. This answer comes from your device."))
    }

    @Test("Der Zustand der Modelle trägt das Kontingent weiter")
    func statusCarriesQuota() {
        let reset = date(24, 18)
        let status = ModelStatus(
            onDevice: .available, privateCloudCompute: .unavailable(.quotaExhausted(resetDate: reset)))
        #expect(status.privateCloudLimit == .quotaExhausted(resetDate: reset))
        #expect(status.resolve(.answer) == .success(.onDevice))
        let other = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.offline))
        #expect(other.privateCloudLimit == nil)
    }
}

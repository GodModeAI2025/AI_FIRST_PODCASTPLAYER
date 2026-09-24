//
//  LanguageDirectiveTests.swift
//  PodcastAIKitTests
//
//  Was Apple Intelligence formuliert, steht in der Sprache der App, auch
//  wenn der Podcast englisch ist:
//  - Die Sprache kommt aus der Lokalisierung der App, nicht aus dem Gerät.
//  - Jede Anweisung und jeder Prompt, der Text erzeugt, nennt die Sprache
//    ausdrücklich, auch für Deutsch.
//  - Wörtliche Zitate bleiben in ihrer Sprache.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIIntelligence

@Suite("Sprache der App")
struct AppLanguageTests {

    @Test("Lokalisierungen werden zu Deutsch oder Englisch", arguments: [
        ("de", AppLanguage.german),
        ("de-CH", .german),
        ("de_DE", .german),
        ("en", .english),
        ("en-GB", .english),
        ("en_US", .english),
        ("fr", .german),
        ("", .german),
    ])
    func resolve(identifier: String, expected: AppLanguage) {
        #expect(AppLanguage.resolve(identifier) == expected)
    }

    @Test("Ohne Lokalisierung gilt Deutsch")
    func missing() {
        #expect(AppLanguage.resolve(nil) == .german)
    }

    @Test("Sprachangaben aus Transkript und Feed werden verglichen")
    func matches() {
        #expect(AppLanguage.german.matches("de_DE") == true)
        #expect(AppLanguage.german.matches("en_US") == false)
        #expect(AppLanguage.german.matches("en-us") == false)
        #expect(AppLanguage.english.matches("en-US") == true)
        #expect(AppLanguage.english.matches(nil) == nil)
        #expect(AppLanguage.english.matches("") == nil)
    }
}

@Suite("Vorgabe zur Sprache in Anweisungen und Prompts")
struct LanguageDirectiveTests {

    static let german = "Formuliere alles auf Deutsch, auch wenn die Abschnitte in einer anderen Sprache sind."
    static let english = "Write everything in English, even if the passages are in another language."

    func extractor(_ language: AppLanguage) -> KnowledgeExtractor {
        KnowledgeExtractor(configuration: ExtractorConfiguration(outputLanguage: language))
    }

    /// Englische Abschnitte, wie sie aus einem englischen Podcast kommen.
    func englishEvidence(count: Int = 3) -> [Evidence] {
        let media = MediaVersionID(stable: "https://example.com/episode.mp3")
        return (0..<count).map { index in
            Evidence(
                id: EvidenceID(stable: "en\(index)"), mediaVersionID: media,
                episodeID: EpisodeID(stable: "episode"), sourceID: SourceID(stable: "show"),
                transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                range: MediaTimeRange(
                    start: MediaTime(milliseconds: Int64(index) * 10_000),
                    end: MediaTime(milliseconds: Int64(index) * 10_000 + 9_000)),
                quotedText: "Heat pumps cut emissions by half in cold climates, the study says.")
        }
    }

    @Test("Die Vorgabe nennt die Sprache auch für Deutsch")
    func directiveText() {
        #expect(AppLanguage.german.directive == Self.german)
        #expect(AppLanguage.english.directive == Self.english)
    }

    @Test("Antworten, Fakten und Begründungen bekommen die Vorgabe", arguments: AppLanguage.allCases)
    func instructions(language: AppLanguage) {
        let extractor = extractor(language)
        let profile = InterestProfile(interests: [Interest(label: "Wärmepumpen")])
        for text in [extractor.answerInstructions(), extractor.claimInstructions(),
                     extractor.relevanceInstructions(profile: profile)] {
            #expect(text.contains(language.directive))
            #expect(!text.contains("—"))
        }
        // Die andere Sprache steht nirgends.
        let other = AppLanguage.allCases.first { $0 != language }!
        #expect(!extractor.answerInstructions().contains(other.directive))
        #expect(!extractor.claimInstructions().contains(other.directive))
    }

    @Test("Jeder Prompt, der Text erzeugt, endet mit der Vorgabe", arguments: AppLanguage.allCases)
    func prompts(language: AppLanguage) {
        let extractor = extractor(language)
        let configuration = ExtractorConfiguration(outputLanguage: language)
        let candidates = configuration.candidateBuilder.build(from: englishEvidence())

        #expect(extractor.claimPrompt(for: candidates).hasSuffix(language.directive))
        #expect(extractor.relevancePrompt(for: candidates).hasSuffix(language.directive))

        for tier in [ModelTier.onDevice, .privateCloudCompute] {
            let answer = configuration.answerRequest(
                question: "What do they say about heat pumps?", evidence: englishEvidence(),
                libraryContext: "", tier: tier)
            #expect(answer.prompt.hasSuffix(language.directive))
            #expect(answer.candidates.count == 3)
        }
        let libraryOnly = configuration.answerRequest(
            question: "Welche Folgen habe ich noch nicht gehört?", evidence: [],
            libraryContext: "Podcast: Beispiel (1 Folge)", tier: .onDevice)
        #expect(libraryOnly.prompt.hasSuffix(language.directive))
    }

    @Test("Wörtliche Zitate bleiben im Original, in jeder Sprache", arguments: AppLanguage.allCases)
    func quotes(language: AppLanguage) {
        let instructions = extractor(language).answerInstructions()
        #expect(instructions.contains("Wörtliche Zitate aus den Abschnitten bleiben in ihrer Originalsprache."))
    }

    @Test("Fakten sind eigene Sätze in der Sprache der App, keine Zitate")
    func claimsAreParaphrased() {
        let instructions = extractor(.german).claimInstructions()
        #expect(instructions.contains("mit eigenen Worten"))
        #expect(!instructions.contains("Originalsprache"))
    }
}

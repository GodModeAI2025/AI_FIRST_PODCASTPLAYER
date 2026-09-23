//
//  ClaimStatementTests.swift
//
//  Fakten ohne Reste der nummerierten Liste:
//  - Das Modell sieht für Fakten keine Zeilen mit „<Nummer> |“ mehr, weder
//    in den Anweisungen noch im Prompt.
//  - Eine Aussage mit Trennstrich oder Verweisklammer mitten im Text wird
//    verworfen, eine vorangestellte Nummer und Verweise am Ende fallen weg.
//  - Gespeicherte Fakten aus älteren Läufen mit solchen Resten erkennt die
//    App und zeigt sie nicht. Steht nur vorn eine Nummer oder am Ende ein
//    Verweis, zeigt sie den Fakt ohne sie.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIIntelligence

@Suite("Aussagen ohne Listenreste")
struct ClaimStatementTests {

    /// So stand ein Fakt in einer Bibliothek aus Version 0.6.
    static let gluedFact = """
        Datenschutz geht nicht, muss ich mich nicht beschäftigen. 2 | Ich habe ein Unternehmen \
        zusammen mit meinem Vater gegründet, die IITR Datenschutz Gmb… 3 | DSGVO oder jetzt AI Act \
        und so weiter besprochen. 4 | Ist ja nett, aber das geht in die Cloud und geht in die USA.
        """

    @Test("Verklebte Fakten aus älteren Läufen werden erkannt")
    func storedArtifacts() {
        #expect(ClaimStatement.hasListMarkers(Self.gluedFact))
        let fact = EpisodeFact(
            id: "f", episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "s"),
            evidenceID: EvidenceID(stable: "b"), mediaVersionID: MediaVersionID(stable: "m"),
            statement: Self.gluedFact,
            range: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 1_000)),
            modelTier: "onDevice")
        #expect(fact.hasListArtifacts)
    }

    @Test("Gespeicherte Fakten mit Nummer vorn oder Verweis am Ende bleiben, ohne die Verweise", arguments: [
        ("[3] Modelle laufen auf dem Gerät.", "Modelle laufen auf dem Gerät."),
        ("Die DSGVO gilt seit 2018 [2].", "Die DSGVO gilt seit 2018."),
        ("3 | Viele Firmen testen Assistenten.", "Viele Firmen testen Assistenten."),
        ("Die DSGVO gilt seit 2018.", "Die DSGVO gilt seit 2018."),
    ])
    func storedCitationsAreCleaned(stored: String, shown: String) throws {
        let fact = EpisodeFact(
            id: "f", episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "s"),
            evidenceID: EvidenceID(stable: "b"), mediaVersionID: MediaVersionID(stable: "m"),
            statement: stored,
            range: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 1_000)),
            modelTier: "onDevice")
        #expect(!fact.hasListArtifacts)
        let cleaned = try #require(fact.cleaned)
        #expect(cleaned.statement == shown)
        #expect(cleaned.id == fact.id)
        #expect(cleaned.range == fact.range)
    }

    @Test("Verklebte Fakten bleiben auch nach dem Putzen verborgen")
    func gluedFactStaysHidden() {
        let fact = EpisodeFact(
            id: "f", episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "s"),
            evidenceID: EvidenceID(stable: "b"), mediaVersionID: MediaVersionID(stable: "m"),
            statement: "[1] " + Self.gluedFact + " [4].",
            range: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 1_000)),
            modelTier: "onDevice")
        #expect(fact.hasListArtifacts)
        #expect(fact.cleaned == nil)
    }

    @Test("Normale Aussagen, Jahreszahlen und Abkürzungen sind keine Listenreste", arguments: [
        "Die DSGVO gilt seit 2018 in der ganzen EU.",
        "Viele Firmen testen Assistenten (etwa 40 Prozent).",
        "Im Jahr 2023 stiegen die Kosten um 12 Prozent.",
        "Die Folge beginnt mit [Musik] und einem Interview.",
    ])
    func cleanStatements(text: String) {
        #expect(!ClaimStatement.hasListMarkers(text))
        #expect(ClaimStatement.validated(text) == text)
    }

    @Test("Trennstriche in jeder Schreibweise und Verweisklammern zählen als Listenrest", arguments: [
        "Erste Aussage hier. 2 | Zweite Aussage dort.",
        "Erste Aussage hier. 2 \u{FF5C} Zweite Aussage dort.",
        "Erste Aussage hier. 2 \u{00A6} Zweite Aussage dort.",
        "Erste Aussage hier [2] und die zweite dort.",
        "Erste Aussage hier [2, 5] und die zweite dort.",
    ])
    func markers(text: String) {
        #expect(ClaimStatement.hasListMarkers(text))
        #expect(ClaimStatement.validated(text) == nil)
    }

    @Test("Eine vorangestellte Nummer und Verweise am Ende fallen weg")
    func strippedNumbers() {
        #expect(ClaimStatement.validated("3 | Modelle laufen auf dem Gerät.") == "Modelle laufen auf dem Gerät.")
        #expect(ClaimStatement.validated("[3] Modelle laufen auf dem Gerät.") == "Modelle laufen auf dem Gerät.")
        #expect(ClaimStatement.validated("Modelle laufen auf dem Gerät [3].") == "Modelle laufen auf dem Gerät.")
        #expect(ClaimStatement.validated("Modelle laufen auf dem Gerät [3] [5].") == "Modelle laufen auf dem Gerät.")
        #expect(ClaimStatement.validated("Modelle laufen auf dem Gerät [3, 5]") == "Modelle laufen auf dem Gerät")
        // Eine Zahl am Satzanfang ohne Strich bleibt.
        #expect(ClaimStatement.validated("2024 kamen drei neue Modelle heraus.") == "2024 kamen drei neue Modelle heraus.")
    }

    @Test("Abgeschriebene, gekürzte Abschnitte sind keine Aussage")
    func truncatedEcho() {
        #expect(ClaimStatement.validated(
            "Ich habe ein Unternehmen zusammen mit meinem Vater gegründet, die IITR Datenschutz Gmb…") == nil)
        #expect(ClaimStatement.validated("Das Modell läuft lokal und dann ...") == nil)
    }

    @Test("Aus Nummer und Satz werden Aussagen, nur zu Nummern aus der Liste")
    func claimsFromFields() {
        let candidates = [
            EvidenceCandidate(index: 1, id: EvidenceID(stable: "a"), excerpt: "A"),
            EvidenceCandidate(index: 2, id: EvidenceID(stable: "b"), excerpt: "B"),
        ]
        let claims = KnowledgeExtractor.claims(
            from: [
                (1, "Datenschutz ist für viele Firmen ein Hindernis."),
                (2, "Ich habe ein Unternehmen gegründet, die IITR Datenschutz Gmb…"),
                (7, "Diese Nummer gibt es in der Liste nicht."),
                (2, "Erste Aussage hier. 3 | Zweite Aussage dort."),
                (2, "[2] Die DSGVO gilt auch für KI-Anwendungen."),
            ],
            candidates: candidates, openQuestions: ["Was heißt das für kleine Firmen?"])
        #expect(claims.map(\.statement) == [
            "Datenschutz ist für viele Firmen ein Hindernis.",
            "Die DSGVO gilt auch für KI-Anwendungen.",
        ])
        #expect(claims.map { $0.evidenceIDs.first?.rawValue } == [
            EvidenceID(stable: "a").rawValue, EvidenceID(stable: "b").rawValue,
        ])
        #expect(claims.first?.openQuestion == "Was heißt das für kleine Firmen?")
    }

    @Test("Für Fakten sieht das Modell keine Zeilen mit Nummer und Strich", arguments: AppLanguage.allCases)
    func noPipeFormatInClaimPrompt(language: AppLanguage) {
        let configuration = ExtractorConfiguration(outputLanguage: language)
        let extractor = KnowledgeExtractor(configuration: configuration)
        let media = MediaVersionID(stable: "https://example.com/folge.mp3")
        let evidence = (0..<3).map { index in
            Evidence(
                id: EvidenceID(stable: "e\(index)"), mediaVersionID: media,
                episodeID: EpisodeID(stable: "folge"), sourceID: SourceID(stable: "quelle"),
                transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                range: MediaTimeRange(
                    start: MediaTime(milliseconds: Int64(index) * 10_000),
                    end: MediaTime(milliseconds: Int64(index) * 10_000 + 9_000)),
                quotedText: "Abschnitt \(index) über Datenschutz und KI in Unternehmen.")
        }
        let candidates = configuration.candidateBuilder.build(from: evidence)
        for text in [extractor.claimInstructions(), extractor.claimPrompt(for: candidates)] {
            #expect(!text.contains("|"))
            #expect(!text.contains("—"))
        }
        #expect(extractor.claimInstructions().contains("keine Nummer"))
    }
}

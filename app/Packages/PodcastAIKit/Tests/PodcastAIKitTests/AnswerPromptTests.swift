//
//  AnswerPromptTests.swift
//
//  Was eine Frage dem Modell vorlegt und wie die Antwort gelesen wird:
//  - Verweise wie [3, 5] zählen als zwei Belege, [1 2] nicht als 12.
//  - Der Prompt ist je Stufe bemessen. Fällt PCC aufs Gerät zurück, bekommt
//    das Gerät eine Liste, die in sein Kontextfenster passt.
//  - Fragen über die Bibliothek erreichen das Modell auch ohne Abschnitte.
//  - Wer Sätze schreiben soll, hört nicht, er solle nur mit Nummern antworten.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIIntelligence

@Suite("Verweise im Antworttext")
struct CitedNumberTests {

    @Test("Gruppierte Verweise werden einzeln erkannt", arguments: [
        ("Beide sagen das [3, 5].", [3, 5]),
        ("Beide sagen das [3,5].", [3, 5]),
        ("Beide sagen das [3; 7].", [3, 7]),
        ("Zwei Stellen [1 2].", [1, 2]),
        ("Eine Stelle [12].", [12]),
        ("Erst [2], dann [3, 5].", [2, 3, 5]),
    ])
    func grouped(text: String, expected: [Int]) {
        #expect(KnowledgeExtractor.citedNumbers(in: text) == expected)
    }

    @Test("Bereiche werden ausgeschrieben, übergroße nicht")
    func ranges() {
        #expect(KnowledgeExtractor.citedNumbers(in: "Siehe [2-4].") == [2, 3, 4])
        #expect(KnowledgeExtractor.citedNumbers(in: "Siehe [2 – 4].") == [2, 3, 4])
        #expect(KnowledgeExtractor.citedNumbers(in: "Siehe [1-40].") == [1, 40])
    }

    @Test("Klammern ohne Verweis bleiben ohne Nummer")
    func notCitations() {
        #expect(KnowledgeExtractor.citedNumbers(in: "[Musik] [00:12] [3a] [Abschnitt 4]") == [])
        #expect(KnowledgeExtractor.citedNumbers(in: "Offen [3 und dann") == [])
        #expect(KnowledgeExtractor.citedNumbers(in: "Doppelt [[3]]") == [3])
    }
}

@Suite("Aussagen und Antworttext aufräumen")
struct StatementCleanupTests {

    @Test("Aussagen in einer Zeile werden getrennt")
    func runOnLine() {
        let parsed = KnowledgeExtractor.parsePipedLines(
            "1 | Viele Firmen testen Assistenten. 2 | Datenschutz ist ein Problem. 3 | Modelle laufen lokal.")
        #expect(parsed.map(\.0) == [1, 2, 3])
        #expect(parsed.map(\.1) == [
            "Viele Firmen testen Assistenten.", "Datenschutz ist ein Problem.", "Modelle laufen lokal.",
        ])
    }

    @Test("Zeilen wie bisher, Jahreszahlen sind keine Nummern")
    func lines() {
        let parsed = KnowledgeExtractor.parsePipedLines("2 | Erste Aussage\n\n5 |Zweite 2023 | bleibt\nohne Nummer")
        #expect(parsed.map(\.0) == [2, 5])
        #expect(parsed[1].1 == "Zweite 2023 | bleibt")
    }

    @Test("Verklebte, zu kurze und zu lange Aussagen werden verworfen")
    func validation() {
        #expect(KnowledgeExtractor.validatedStatement("  Modelle   laufen auf dem Gerät. ") == "Modelle laufen auf dem Gerät.")
        #expect(KnowledgeExtractor.validatedStatement("Zu kurz") == nil)
        #expect(KnowledgeExtractor.validatedStatement("Erste Aussage hier. 2 | Zweite Aussage dort.") == nil)
        #expect(KnowledgeExtractor.validatedStatement(String(repeating: "Wort ", count: 100)) == nil)
        #expect(KnowledgeExtractor.validatedStatement(
            "Das ist der erste Satz. Das ist der zweite Satz. Und hier kommt der dritte Satz.") == nil)
    }

    @Test("Blocknamen und Verweise ohne Beleg verschwinden")
    func answerMarkers() {
        let text = "Es gibt zehn Folgen [BIBLIOTHEK]. Keine davon spricht darüber. [3] [5] Mehr nicht (BIBLIOTHEK)."
        #expect(KnowledgeExtractor.cleanedAnswerText(text, validNumbers: []) ==
            "Es gibt zehn Folgen. Keine davon spricht darüber. Mehr nicht.")
        #expect(KnowledgeExtractor.cleanedAnswerText("Stimmt [3] [5].", validNumbers: [3]) == "Stimmt [3].")
        #expect(KnowledgeExtractor.cleanedAnswerText("Beide [3, 7].", validNumbers: [3]) == "Beide [3].")
        #expect(KnowledgeExtractor.cleanedAnswerText("Beide [3, 5].", validNumbers: [3, 5]) == "Beide [3, 5].")
        #expect(KnowledgeExtractor.cleanedAnswerText("Laut [BIBLIOTHEK, 4] so.", validNumbers: [4]) == "Laut [4] so.")
        #expect(KnowledgeExtractor.cleanedAnswerText("[Musik] im Jahr (2023) [00:12].", validNumbers: []) ==
            "[Musik] im Jahr (2023) [00:12].")
    }

    @Test("Abkürzungen in Klammern bleiben, nur Blocknamen aus dem Prompt fallen weg")
    func acronymsStay() {
        #expect(KnowledgeExtractor.cleanedAnswerText(
            "Die Datenschutz-Grundverordnung (DSGVO) gilt seit 2018 [2].", validNumbers: [2]) ==
            "Die Datenschutz-Grundverordnung (DSGVO) gilt seit 2018 [2].")
        #expect(KnowledgeExtractor.cleanedAnswerText("Die NATO (NATO) und die NASA [NASA].", validNumbers: []) ==
            "Die NATO (NATO) und die NASA [NASA].")
        #expect(KnowledgeExtractor.cleanedAnswerText("Laut OECD (OECD, 2023) steigt es.", validNumbers: []) ==
            "Laut OECD (OECD, 2023) steigt es.")
        #expect(KnowledgeExtractor.cleanedAnswerText(
            "Zwei Folgen [KANDIDATEN] passen (PROFIL). Mehr [ENDE BIBLIOTHEK] nicht [Library].",
            validNumbers: []) == "Zwei Folgen passen. Mehr nicht.")
        #expect(KnowledgeExtractor.cleanedAnswerText("Two episodes [CANDIDATES, 3] fit (PROFILE).",
                                                     validNumbers: [3]) == "Two episodes [3] fit.")
    }
}

@Suite("Prompt für Fragen")
struct AnswerPromptTests {

    let episodeID = EpisodeID(stable: "folge")
    let sourceID = SourceID(stable: "quelle")

    func evidence(count: Int, length: Int = 1_200) -> [Evidence] {
        let media = MediaVersionID(stable: "https://example.com/folge.mp3")
        return (0..<count).map { index in
            Evidence(
                id: EvidenceID(stable: "e\(index)"), mediaVersionID: media, episodeID: episodeID,
                sourceID: sourceID, transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                range: MediaTimeRange(
                    start: MediaTime(milliseconds: Int64(index) * 10_000),
                    end: MediaTime(milliseconds: Int64(index) * 10_000 + 9_000)),
                quotedText: "Stelle \(index) " + String(repeating: "wort ", count: length / 5))
        }
    }

    /// So bestellt die App eine Antwort, wenn PCC verfügbar scheint.
    let wide = ExtractorConfiguration(
        candidateBuilder: CandidateListBuilder(excerptLimit: 900, maximumCandidates: 60))

    let library = String(repeating: "- Folge mit langem Titel, 3. März 2026, nicht erschlossen\n", count: 200)

    func numberedLines(_ prompt: String) -> Int {
        prompt.split(separator: "\n").filter { $0.first == "[" }.count
    }

    @Test("Auf dem Gerät gilt das Gerätebudget, auch wenn für PCC bestellt wurde")
    func onDeviceBudget() {
        let builder = wide.candidateBuilder(for: .onDevice)
        #expect(builder.maximumCandidates == 16)
        #expect(builder.excerptLimit == 420)
        #expect(wide.candidateBuilder(for: .privateCloudCompute) == CandidateListBuilder(
            excerptLimit: 900, maximumCandidates: 60))

        // Eine kleinere Bestellung bleibt klein.
        let small = ExtractorConfiguration(
            candidateBuilder: CandidateListBuilder(excerptLimit: 300, maximumCandidates: 8))
        #expect(small.candidateBuilder(for: .onDevice) == CandidateListBuilder(
            excerptLimit: 300, maximumCandidates: 8))
    }

    @Test("Der Rückfall aufs Gerät baut einen kleineren Prompt")
    func promptPerTier() {
        let pool = evidence(count: 60)
        let cloud = wide.answerRequest(
            question: "Was wird über Wärmepumpen gesagt?", evidence: pool,
            libraryContext: library, tier: .privateCloudCompute)
        let device = wide.answerRequest(
            question: "Was wird über Wärmepumpen gesagt?", evidence: pool,
            libraryContext: library, tier: .onDevice)

        #expect(cloud.candidates.count == 60)
        #expect(numberedLines(cloud.prompt) == 60)
        #expect(device.candidates.count == 16)
        #expect(numberedLines(device.prompt) == 16)
        #expect(device.candidates.allSatisfy { $0.excerpt.count <= 421 })

        // Die ersten sechzehn sind dieselben Belege mit denselben Nummern:
        // die Liste ist nach Rang sortiert, das Gerät bekommt die besten.
        #expect(device.candidates.map(\.id) == Array(cloud.candidates.prefix(16)).map(\.id))
        #expect(device.candidates.map(\.index) == Array(1...16))

        // Bibliothek je Stufe begrenzt.
        let libraryLine = { (prompt: String) -> String in
            let lines = prompt.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.hasPrefix("--- BIBLIOTHEK") }) else { return "" }
            return lines[start + 1]
        }
        #expect(libraryLine(device.prompt).count <= 1_501)
        #expect(libraryLine(cloud.prompt).count > 1_501)
        #expect(libraryLine(cloud.prompt).count <= 6_001)

        // Grob: das Gerät bekommt weniger als ein Viertel der Zeichen.
        #expect(device.prompt.count < 10_000)
        #expect(device.prompt.count * 4 < cloud.prompt.count)
    }

    @Test("Eine Frage über die Bibliothek braucht keine Abschnitte")
    func libraryOnly() {
        let request = wide.answerRequest(
            question: "Welche Folgen habe ich noch nicht gehört?", evidence: [],
            libraryContext: "Podcast: Beispiel (2 Folgen)\n- Folge A, nicht erschlossen", tier: .onDevice)
        #expect(!request.isEmpty)
        #expect(request.candidates.isEmpty)
        #expect(request.prompt.contains("--- BIBLIOTHEK"))
        #expect(!request.prompt.contains("KANDIDATEN"))
        #expect(request.prompt.contains("keine Abschnitte"))
        #expect(request.prompt.contains("Welche Folgen habe ich noch nicht gehört?"))
    }

    @Test("Ohne Abschnitte und ohne Bibliothek gibt es nichts zu fragen")
    func nothingToAsk() {
        let request = wide.answerRequest(
            question: "Irgendwas?", evidence: [], libraryContext: "  \n ", tier: .onDevice)
        #expect(request.isEmpty)
    }

    @Test("Ohne Grundlage läuft kein Modell, und die Antwort nennt keine Stufe")
    func noModelWithoutMaterial() async throws {
        let status = ModelStatus(onDevice: .available, privateCloudCompute: .unavailable(.userConsentMissing))
        let composed = try await KnowledgeExtractor(configuration: wide).answer(
            question: "Irgendwas?", from: [], libraryContext: "", availability: status)
        #expect(composed.tier == nil)
        #expect(composed.text.isEmpty)
        #expect(composed.citations.isEmpty)
    }

    @Test("Antworten verweisen auf Nummern, statt nur Nummern zu liefern")
    func prefacePerTask() {
        let candidates = CandidateListBuilder().build(from: evidence(count: 2, length: 20))
        let select = CandidateListBuilder().promptBlock(for: candidates, usage: .selectNumbers)
        let reference = CandidateListBuilder().promptBlock(for: candidates, usage: .referenceNumbers)
        #expect(select.contains("Antworte ausschließlich mit Nummern"))
        #expect(!reference.contains("Antworte ausschließlich mit Nummern"))
        #expect(reference.contains("Verweise nur auf Nummern"))
        #expect(reference.contains("[1] Stelle 0"))

        let answer = wide.answerRequest(
            question: "Was?", evidence: evidence(count: 3, length: 20), libraryContext: "", tier: .onDevice)
        #expect(!answer.prompt.contains("Antworte ausschließlich mit Nummern"))
        #expect(answer.prompt.contains("Verweise nur auf Nummern"))
        #expect(!answer.prompt.contains("BIBLIOTHEK"))
    }

    @Test("Die Instruktion lässt die Bibliothek als Quelle für Bibliotheksfragen zu")
    func instructionsNameLibrary() {
        let instructions = KnowledgeExtractor().answerInstructions()
        #expect(instructions.contains("BIBLIOTHEK"))
        #expect(instructions.contains("Nur sie belegen"))
        #expect(!instructions.contains("ausschließlich aus den vorgelegten Abschnitten"))
        #expect(!instructions.contains("Nur was in den Abschnitten steht"))
        #expect(!instructions.contains("—"))
    }
}

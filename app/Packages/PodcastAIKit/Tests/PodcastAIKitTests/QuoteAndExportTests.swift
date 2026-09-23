//
//  QuoteAndExportTests.swift
//  PodcastAIKitTests
//
//  „Moment merken“ nimmt den Satz, der gerade läuft, mit seinem Anfang als
//  Zeitmarke. Der Export ist eine Markdown-Datei mit Kopfdaten, gültigen
//  Listen, eigenen Notizen und dem Erscheinungsdatum in der Quelle.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIKnowledge
@testable import PodcastAIExport

private func ms(_ seconds: Int) -> MediaTime { MediaTime(milliseconds: Int64(seconds) * 1000) }

private func transcript(_ lines: [(Int, Int, String)]) -> Transcript {
    Transcript(
        id: TranscriptID(stable: "t"), mediaVersionID: MediaVersionID(stable: "m"), revision: .initial,
        origin: .speechAnalysis, locale: "de_DE",
        segments: lines.map { start, end, text in
            TranscriptSegment(id: SegmentID(stable: "s\(start)"),
                              range: MediaTimeRange(start: ms(start), end: ms(end)), text: text)
        },
        analyzedRanges: IntervalSet(MediaTimeRange(start: ms(0), end: ms(600))))
}

@Suite("Moment merken: der laufende Satz")
struct MomentCaptureTests {

    private let demo = transcript([
        (200, 238, "Für grössere Aufgaben gibt es Serverlösungen."),
        (240, 278, "Eine Studie zeigt, dass Teams mit klaren Regeln zwanzig Prozent schneller arbeiten."),
        (280, 318, "Automatisierung verändert eher einzelne Tätigkeiten."),
    ])

    @Test("Getippt bei 4:18: der Satz ab 4:00, nicht der davor")
    func takesRunningSentence() {
        let segment = HighlightCapture().segment(at: ms(258), in: demo)
        #expect(segment?.range.start == ms(240))
        #expect(segment?.text.hasPrefix("Eine Studie") == true)
    }

    @Test("In der Pause nach einem Satz gilt der, der gerade zu Ende ging")
    func pauseTakesSentenceJustHeard() {
        #expect(HighlightCapture().segment(at: ms(239), in: demo)?.range.start == ms(200))
    }

    @Test("Lange nach dem letzten Satz gibt es kein Zitat")
    func nothingLongAfterTheEnd() {
        #expect(HighlightCapture().segment(at: ms(500), in: demo) == nil)
    }

    @Test("Kurz vor dem ersten Satz gilt der erste")
    func beforeFirstSentence() {
        #expect(HighlightCapture().segment(at: ms(195), in: demo)?.range.start == ms(200))
        #expect(HighlightCapture().segment(at: ms(10), in: demo) == nil)
    }
}

@Suite("Export als Markdown-Datei")
struct MarkdownFileExportTests {

    @Test("Kopfdaten stehen als YAML am Anfang, Werte in Anführungszeichen")
    func frontMatter() {
        let published = Date(timeIntervalSince1970: 1_790_000_000)
        let dossier = EpisodeDossier(
            title: "KI im Alltag: \"Regeln\"", sourceTitle: "Arbeit und KI", publishedAt: published,
            duration: MediaDuration(seconds: 600), webPageURL: URL(string: "https://example.com/folge-12"))
        let text = EpisodeDossierExporter().markdown(dossier, includeTranscript: false)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        #expect(lines.contains("title: \"KI im Alltag: \\\"Regeln\\\"\""))
        #expect(lines.contains("podcast: \"Arbeit und KI\""))
        #expect(lines.contains("duration: \"10:00\""))
        #expect(lines.contains("link: \"https://example.com/folge-12\""))
        #expect(lines.contains { $0.hasPrefix("published: ") && !$0.contains("\"") })
        let closing = lines.dropFirst().firstIndex(of: "---")
        #expect(closing != nil)
        #expect(lines.firstIndex { $0.hasPrefix("# ") }.map { $0 > closing! } == true)
    }

    @Test("Ein Link mit Zugangsdaten landet auch nicht in den Kopfdaten")
    func frontMatterSkipsPrivateLink() {
        let dossier = EpisodeDossier(title: "Folge", sourceTitle: "Podcast",
                                     webPageURL: URL(string: "https://example.com/f?token=geheim"))
        let text = EpisodeDossierExporter().markdown(dossier, includeTranscript: false)
        #expect(!text.contains("geheim"))
        #expect(!text.contains("link:"))
    }

    @Test("Aufzählungen aus den Shownotes werden zu Markdown-Listen")
    func shownotesBullets() {
        let dossier = EpisodeDossier(title: "Folge", sourceTitle: "Podcast",
                                     shownotes: "Worum es geht:\n• Modelle auf dem Gerät\n• Haftung")
        let text = EpisodeDossierExporter().markdown(dossier, includeTranscript: false)
        #expect(text.contains("\n- Modelle auf dem Gerät\n- Haftung"))
        #expect(!text.contains("•"))
    }

    @Test("Jeder Satz des Transkripts behält seine Zeitmarke")
    func transcriptKeepsEachTimecode() {
        let dossier = EpisodeDossier(title: "Folge", sourceTitle: "Podcast", transcript: transcript([
            (80, 118, "Viele Unternehmen testen KI-Assistenten."),
            (120, 158, "Ein Problem ist der Datenschutz."),
        ]))
        let text = EpisodeDossierExporter().markdown(dossier)
        #expect(text.contains("`1:20` Viele Unternehmen testen KI-Assistenten."))
        #expect(text.contains("`2:00` Ein Problem ist der Datenschutz."))
    }

    @Test("Eigene Notizen stehen im Folgen-Export")
    func dossierIncludesNotes() {
        let note = ExportedNote(note: "Quelle der Studie prüfen", quote: "Eine Studie zeigt …",
                                position: ms(240))
        let dossier = EpisodeDossier(title: "Folge", sourceTitle: "Podcast", notes: [note])
        let text = EpisodeDossierExporter().markdown(dossier, includeTranscript: false)
        #expect(text.contains("- `4:00` Quelle der Studie prüfen"))
        #expect(text.contains("  > Eine Studie zeigt …"))
    }

    @Test("Gemerkte Stellen nennen das Erscheinungsdatum, die Merkzeit steht getrennt")
    func notesUsePublicationDate() {
        let published = Date(timeIntervalSince1970: 1_790_000_000)
        let captured = published.addingTimeInterval(86_400 * 3)
        let note = ExportedNote(
            note: "Studie", quote: "Eine Studie zeigt, dass Teams schneller arbeiten.",
            episodeTitle: "KI im Alltag", sourceTitle: "Arbeit und KI", position: ms(240),
            publishedAt: published, webPageURL: URL(string: "https://example.com/folge"),
            capturedAt: captured)
        let text = NotesExporter().markdown([note])
        let publishedDay = published.formatted(date: .long, time: .omitted)
        let sourceLine = text.components(separatedBy: "\n").first { $0.contains("KI im Alltag · Arbeit und KI · 4:00") }
        #expect(sourceLine?.contains(publishedDay) == true)
        #expect(sourceLine?.contains(captured.formatted(date: .long, time: .omitted)) == false)
        #expect(text.contains("<https://example.com/folge>"))
        #expect(text.contains(captured.formatted(date: .long, time: .shortened)))
        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("> Eine Studie zeigt, dass Teams schneller arbeiten."))
    }

    @Test("Eine einzelne Stelle als Klartext: Zitat, Quelle, Link, Notiz, ohne Markdown")
    func singleNotePlainText() {
        let published = Date(timeIntervalSince1970: 1_790_000_000)
        let note = ExportedNote(
            note: "Unbedingt Mia zeigen", quote: "Das war der beste Witz.",
            episodeTitle: "#362 Der Hund", sourceTitle: "Gemischtes Hack", position: ms(19),
            publishedAt: published, webPageURL: URL(string: "https://example.com/362"))
        let text = Citation.plainText(note)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "„Das war der beste Witz.“")
        #expect(lines[1].hasPrefix("(#362 Der Hund · Gemischtes Hack · 0:19 · "))
        #expect(lines[1].contains(published.formatted(date: .long, time: .omitted)))
        #expect(lines.contains("https://example.com/362"))
        #expect(lines.last?.hasSuffix("Unbedingt Mia zeigen") == true)
        #expect(!text.contains("\\#") && !text.contains("**"))
    }
}

//
//  DemoContent.swift
//  PodcastAI
//
//  Eine erschlossene Beispielfolge für UI-Tests und Vorführungen im
//  Simulator. Der Simulator hat keine Spracherkennung; ohne diese Daten
//  blieben Transkript, Fakten, „Für dich“ und der Chat dort immer leer.
//
//  Nur mit dem Startargument `-demo-content` und nur in einen leeren
//  Speicher. Der Text ist für diesen Zweck geschrieben und gehört zu keiner
//  echten Sendung. Die Audiodatei ist ein öffentlicher Podcast-Download, damit
//  die Wiedergabe funktioniert; Zeitmarken und Text passen nicht zu ihr.
//  Die angegebene Länge ist aber die der Datei, 53:10. Sonst zeigten Liste,
//  „Weiterhören“ und Warteschlange eine andere Länge als der Player.
//

import Foundation
import PodcastAIKit

enum DemoContent {

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-demo-content") }

    static let sourceID = SourceID(stable: "demo-quelle")
    static let episodeID = EpisodeID(stable: "demo-folge-1")
    static let audio = URL(string: "https://audio.podigee-cdn.net/2598733-m-21b7bc55dcb4707563cae78e503f9c5e.mp3")!
    /// Die Länge der Audiodatei, beide Beispielfolgen spielen sie.
    static let audioLength = MediaDuration(seconds: 3_190)

    private static let lines: [String] = [
        "Willkommen zur Beispielfolge über künstliche Intelligenz im Arbeitsalltag.",
        "Heute geht es darum, wie Teams Sprachmodelle einsetzen, ohne Daten preiszugeben.",
        "Viele Unternehmen testen KI-Assistenten zuerst im Kundenservice.",
        "Ein Problem ist der Datenschutz, denn Anfragen enthalten oft persönliche Daten.",
        "Modelle auf dem Gerät verarbeiten Text lokal, dadurch verlassen Daten das Telefon nicht.",
        "Für größere Aufgaben gibt es Serverlösungen, die Anfragen nicht speichern.",
        "Eine Studie zeigt, dass Teams mit klaren Regeln zwanzig Prozent schneller arbeiten.",
        "Ohne Regeln entstehen dagegen Schattenlösungen, bei denen niemand den Überblick hat.",
        "Wichtig ist, Mitarbeitende früh einzubinden und Ängste ernst zu nehmen.",
        "Automatisierung ersetzt selten ganze Berufe, sie verändert einzelne Tätigkeiten.",
        "Gerade Routinearbeit wie Protokolle schreiben lässt sich gut unterstützen.",
        "Kritisch bleibt die Frage, wer für Fehler eines Modells haftet.",
        "Die europäische KI-Verordnung verlangt dafür Transparenz und Risikobewertung.",
        "Zum Schluss: Wer heute anfängt, sollte mit einem kleinen, messbaren Projekt starten.",
        // Für „Erwähnt“: ein Termin mit Adresse und eine gesprochene Webadresse.
        // Hinten angehängt, denn die Fakten zeigen über ihre Nummer auf Belege.
        "Unser Workshop dazu ist am 12. November in der Musterstraße 12, 10115 Berlin.",
        "Anmeldung und alle Links findet ihr unter example punkt org slash workshop.",
    ]

    /// Legt Quelle, Folge, Transkript, Belege, Fakten, Tags und Kapitel-Tags an.
    static func seed(into store: LibraryStore) async {
        guard ((try? await store.sources()) ?? []).isEmpty else { return }
        let source = Source(id: sourceID, kind: .podcastRSS, title: "Beispiel: Arbeit und KI",
                            author: "PodcastAI Demo", capabilities: .fullPodcast, language: "de")
        // „Für dich“ ordnet einen Beleg über seinen Anfang einem Kapitel zu,
        // und jeder Beleg fasst 80 Sekunden. Das Kapitel Datenschutz beginnt
        // deshalb mit dem Beleg ab 1:20, der den Datenschutz anspricht. So
        // trägt es zwei Stellen, und die Karte zeigt die Mehrzahl.
        let chapters = [
            Chapter(start: MediaTime(milliseconds: 0), title: "Einstieg", provenance: .original),
            Chapter(start: MediaTime(milliseconds: 80_000), title: "Datenschutz und Modelle", provenance: .original),
            Chapter(start: MediaTime(milliseconds: 240_000), title: "Regeln im Team", provenance: .original),
            Chapter(start: MediaTime(milliseconds: 420_000), title: "Haftung und Verordnung", provenance: .original),
        ]
        let episode = Episode(
            id: episodeID, sourceID: sourceID, title: "KI im Arbeitsalltag: Datenschutz, Regeln, Haftung",
            summary: "Wie Teams Sprachmodelle sinnvoll einsetzen.",
            publishedAt: Date().addingTimeInterval(-86_400),
            declaredDuration: audioLength, audioURL: audio,
            publisherChapters: chapters,
            shownotesHTML: "<p>In dieser Beispielfolge geht es um KI-Assistenten im Arbeitsalltag, "
                + "Datenschutz, Regeln für Teams und die europäische KI-Verordnung.</p>"
                + "<ul><li>Modelle auf dem Gerät</li><li>Regeln statt Schattenlösungen</li>"
                + "<li>Haftung</li></ul>"
                + "<p>Mehr zur Folge: <a href=\"https://example.org/ki-arbeit\">example.org/ki-arbeit</a>. "
                + "Workshop am 12. November 2026 um 18 Uhr, Musterstraße 12, 10115 Berlin.</p>")
        let second = Episode(
            id: EpisodeID(stable: "demo-folge-2"), sourceID: sourceID,
            title: "Ohne Transkript: Ausblick auf die nächste Folge",
            publishedAt: Date(), declaredDuration: audioLength, audioURL: audio)
        do {
            try await store.upsert(source: source)
            _ = try await store.upsert(episodes: [episode, second], forSource: sourceID)

            let media = MediaVersionID(stable: audio.absoluteString)
            var segments: [TranscriptSegment] = []
            for (index, line) in lines.enumerated() {
                let start = Int64(index) * 40_000
                segments.append(TranscriptSegment(
                    id: SegmentID(stable: "demo|\(index)"),
                    range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                          end: MediaTime(milliseconds: start + 38_000)),
                    text: line))
            }
            let transcriptID = TranscriptID(stable: "\(media.rawValue)|de_DE")
            let transcript = Transcript(
                id: transcriptID, mediaVersionID: media, revision: .initial, origin: .speechAnalysis,
                locale: "de_DE", segments: segments,
                analyzedRanges: IntervalSet(MediaTimeRange(
                    start: MediaTime(milliseconds: 0),
                    end: MediaTime(milliseconds: Int64(lines.count) * 40_000))))
            try await store.save(transcript: transcript,
                                 media: MediaVersion(id: media, episodeID: episodeID, remoteURL: audio),
                                 forEpisode: episodeID)

            var evidence: [Evidence] = []
            for pair in stride(from: 0, to: segments.count, by: 2) {
                let slice = segments[pair..<min(pair + 2, segments.count)]
                let range = MediaTimeRange(start: slice.first!.range.start, end: slice.last!.range.end)
                evidence.append(Evidence(
                    id: Evidence.stableID(mediaVersionID: media, transcriptRevision: .initial, range: range),
                    mediaVersionID: media, episodeID: episodeID, sourceID: sourceID,
                    transcriptID: transcriptID, transcriptRevision: .initial, range: range,
                    quotedText: slice.map(\.text).joined(separator: " ")))
            }
            try await store.store(evidence: evidence)

            // Der Index zählt Belege, und jeder Beleg fasst zwei Zeilen. „Modelle
            // auf dem Gerät“ ist Zeile 4 und steht damit in Beleg 2.
            let statements = [
                (2, "Modelle auf dem Gerät verarbeiten Text lokal, Daten verlassen das Telefon nicht."),
                (3, "Teams mit klaren Regeln arbeiten laut einer Studie zwanzig Prozent schneller."),
                (4, "Automatisierung verändert eher einzelne Tätigkeiten als ganze Berufe."),
                (6, "Die europäische KI-Verordnung verlangt Transparenz und Risikobewertung."),
            ]
            // Die Zeitmarke zeigt wie bei echten Fakten auf den Satz im Beleg.
            let facts = statements.map { index, text in
                let passage = evidence[index].range!
                return EpisodeFact(
                    id: "demo-fakt-\(index)", episodeID: episodeID, sourceID: sourceID,
                    evidenceID: evidence[index].id, mediaVersionID: media, statement: text,
                    range: FactAnchor.range(for: text, within: passage, in: segments) ?? passage,
                    modelTier: "Beispieldaten")
            }
            try await store.save(facts: facts, forEpisode: episodeID)

            try await seedTags(into: store, chapters: chapters, media: media, episode: episode)
            if DemoTrends.isRequested { await DemoTrends.seed(into: store) }
        } catch {
            NSLog("Demo-Inhalte konnten nicht angelegt werden: %@", error.localizedDescription)
        }
    }

    /// Tags und Kapitel-Tags ohne Modell, damit Tag-Wolke, Tag-Seite und
    /// „Für dich“ im Simulator immer dasselbe zeigen. Einem Tag folgt die
    /// Beispielfolge schon (Datenschutz), die anderen stehen neutral da.
    /// Die Tags entstehen vor den Kapitel-Tags: Der Speicher nimmt nur
    /// Kapitel-Tags an, deren Tag er kennt.
    private static func seedTags(
        into store: LibraryStore, chapters: [Chapter], media: MediaVersionID, episode: Episode
    ) async throws {
        let followed = Interest(label: "Datenschutz", kind: .topic)
        try await store.upsert(interest: followed)
        var ids: [String: InterestID] = ["Datenschutz": followed.id]
        for label in ["Sprachmodelle", "Automatisierung", "Haftung", "KI-Verordnung"] {
            if let tag = try await store.addDetectedTag(label: label, seenAt: episode.publishedAt ?? Date()) {
                ids[label] = tag.id
            }
        }
        // Je Kapitel die Tags, die zu seinem Text passen. Das letzte Kapitel
        // endet mit dem Transkript.
        let perChapter: [[String]] = [
            ["Sprachmodelle"],
            ["Datenschutz", "Sprachmodelle"],
            ["Automatisierung"],
            ["Haftung", "KI-Verordnung"],
        ]
        let transcriptEnd = lines.count * 40_000
        var tags: [ChapterTag] = []
        for (index, labels) in perChapter.enumerated() where index < chapters.count {
            let start = Int(chapters[index].start.milliseconds)
            let end = index + 1 < chapters.count ? Int(chapters[index + 1].start.milliseconds) : transcriptEnd
            for label in labels {
                guard let id = ids[label] else { continue }
                tags.append(ChapterTag(
                    episodeID: episodeID, mediaVersionID: media, chapterStartMs: start, chapterEndMs: end,
                    interestID: id, normalizedKey: "", confidence: 0.9, matchedKnown: label == "Datenschutz",
                    sourceID: sourceID, publishedAt: episode.publishedAt, transcriptRevision: .initial))
            }
        }
        try await store.save(chapterTags: tags, forEpisode: episodeID, transcriptRevision: .initial)
    }
}

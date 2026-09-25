//
//  DemoBacklog.swift
//  PodcastAI
//
//  Folgen mit Transkript, aber ohne Fakten und ohne Kapitel-Tags, für
//  Messungen im Simulator. Der Simulator transkribiert nicht; ohne diese
//  Folgen liefe dort nie ein Faktenlauf oder eine Einordnung, und die
//  Oberfläche ließe sich nicht unter Last von Apple Intelligence messen.
//
//  Nur mit dem Startargument `-demo-backlog`, zusammen mit `-demo-content`,
//  und nur einmal je Speicher. Die Texte sind für diesen Zweck geschrieben.
//

import Foundation
import PodcastAIKit

enum DemoBacklog {

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-demo-backlog") }

    /// Drei Quellen zu je acht Folgen, jede mit acht Kapiteln und 80 Zeilen.
    /// Genug, damit Fakten und Tags während einer Messung von vier Minuten laufen.
    private static let topics: [(source: String, sentences: [String])] = [
        ("Beispiel: Energie und Klima", [
            "Der Ausbau der Windkraft an Land kommt in Süddeutschland nur langsam voran.",
            "Genehmigungsverfahren dauern oft mehrere Jahre, weil Gutachten fehlen.",
            "Photovoltaik auf Dächern liefert inzwischen mehr Strom als manche Kohlekraftwerke.",
            "Speicher werden wichtiger, denn Sonne und Wind liefern nicht gleichmäßig.",
            "Wärmepumpen verbrauchen weniger Energie als eine Gasheizung, brauchen aber Strom.",
            "Der Emissionshandel verteuert fossile Brennstoffe Jahr für Jahr.",
            "Netzbetreiber müssen tausende Kilometer neue Leitungen bauen.",
            "Wasserstoff gilt als Lösung für Stahl und Chemie, ist aber knapp.",
            "Kommunen planen Wärmenetze, die Abwärme aus Rechenzentren nutzen.",
            "Die Strompreise an der Börse schwanken stark mit dem Wetter.",
            "Ein Bürgerwindpark verteilt die Gewinne an die Menschen im Ort.",
            "Die Klimaziele für 2030 sind nur mit mehr Tempo erreichbar.",
        ]),
        ("Beispiel: Gesundheit und Forschung", [
            "Die elektronische Patientenakte soll Befunde zwischen Praxen teilen.",
            "Viele Ärztinnen fürchten zusätzlichen Aufwand in der Sprechstunde.",
            "Eine neue Studie untersucht, wie Schlaf das Gedächtnis beeinflusst.",
            "Wer regelmäßig sieben Stunden schläft, lernt nachweislich leichter.",
            "Impfstoffe auf mRNA-Basis werden jetzt auch gegen Krebs getestet.",
            "Kliniken setzen Software ein, die Röntgenbilder vorsortiert.",
            "Die Entscheidung trifft weiterhin ein Mensch, nicht die Software.",
            "Pflegekräfte fehlen vor allem in ländlichen Regionen.",
            "Telemedizin spart Wege, ersetzt aber nicht jede Untersuchung.",
            "Gesundheitsdaten gelten als besonders schützenswert.",
            "Forschende brauchen trotzdem Zugang zu anonymisierten Daten.",
            "Ein europäischer Datenraum für Gesundheit ist in Planung.",
        ]),
        ("Beispiel: Verkehr und Stadt", [
            "Immer mehr Städte richten Fahrradstraßen ein.",
            "Der Nahverkehr leidet unter fehlendem Personal und alten Fahrzeugen.",
            "Ein günstiges Monatsticket hat viele Menschen in Busse und Bahnen gebracht.",
            "Elektroautos brauchen mehr öffentliche Ladepunkte in Wohngebieten.",
            "Carsharing lohnt sich vor allem dort, wo Parkplätze knapp sind.",
            "Autonome Busse fahren testweise in einigen Stadtteilen.",
            "Die Bahn saniert wichtige Strecken und sperrt sie dafür monatelang.",
            "Lieferverkehr in der Innenstadt verursacht viel Lärm und Stau.",
            "Lastenräder ersetzen auf kurzen Wegen manchen Transporter.",
            "Tempo dreißig senkt die Zahl schwerer Unfälle deutlich.",
            "Stadtplaner wollen Straßen grüner und kühler machen.",
            "Bürgerbeteiligung entscheidet oft, ob ein Projekt gelingt.",
        ]),
    ]

    private static let chapterTitles = [
        "Einstieg", "Hintergrund", "Zahlen", "Beispiele", "Streitfragen", "Politik", "Fragen der Hörer", "Ausblick",
    ]

    static func seed(into store: LibraryStore) async {
        let firstID = SourceID(stable: "demo-backlog-0")
        guard ((try? await store.sources()) ?? []).allSatisfy({ $0.id != firstID }) else { return }
        for (sourceIndex, topic) in topics.enumerated() {
            let sourceID = SourceID(stable: "demo-backlog-\(sourceIndex)")
            let source = Source(id: sourceID, kind: .podcastRSS, title: topic.source,
                                author: "PodcastAI Demo", capabilities: .fullPodcast, language: "de")
            do {
                try await store.upsert(source: source)
                for number in 0..<8 {
                    try await seedEpisode(number, of: sourceID, sentences: topic.sentences, store: store)
                }
            } catch {
                NSLog("Demo-Folgen ohne Fakten konnten nicht angelegt werden: %@", error.localizedDescription)
            }
        }
    }

    private static func seedEpisode(
        _ number: Int, of sourceID: SourceID, sentences: [String], store: LibraryStore
    ) async throws {
        let lineCount = 80
        let episodeID = EpisodeID(stable: "\(sourceID.rawValue)-folge-\(number)")
        let audio = URL(string: "\(DemoContent.audio.absoluteString)?backlog=\(sourceID.rawValue)-\(number)")!
        let chapterLength = Int64(lineCount / chapterTitles.count) * 40_000
        let chapters = chapterTitles.enumerated().map { index, title in
            Chapter(start: MediaTime(milliseconds: Int64(index) * chapterLength),
                    title: title, provenance: .original)
        }
        let episode = Episode(
            id: episodeID, sourceID: sourceID, title: "Folge \(number + 1): \(sentences[number % sentences.count])",
            summary: sentences[(number + 3) % sentences.count],
            publishedAt: Date().addingTimeInterval(-Double(2 + number) * 86_400),
            declaredDuration: DemoContent.audioLength, audioURL: audio,
            publisherChapters: chapters)
        _ = try await store.upsert(episodes: [episode], forSource: sourceID)

        let media = MediaVersionID(stable: audio.absoluteString)
        var segments: [TranscriptSegment] = []
        for index in 0..<lineCount {
            // Jede Folge mischt die Sätze anders, damit sich Fakten und Tags unterscheiden.
            let text = sentences[(index * (number + 1) + number) % sentences.count]
                + " " + sentences[(index + number + 5) % sentences.count]
            let start = Int64(index) * 40_000
            segments.append(TranscriptSegment(
                id: SegmentID(stable: "\(episodeID.rawValue)|\(index)"),
                range: MediaTimeRange(start: MediaTime(milliseconds: start),
                                      end: MediaTime(milliseconds: start + 38_000)),
                text: text))
        }
        let transcriptID = TranscriptID(stable: "\(media.rawValue)|de_DE")
        let transcript = Transcript(
            id: transcriptID, mediaVersionID: media, revision: .initial, origin: .speechAnalysis,
            locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(MediaTimeRange(
                start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: Int64(lineCount) * 40_000))))
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
    }
}

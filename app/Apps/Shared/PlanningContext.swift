//
//  PlanningContext.swift
//  PodcastAI
//
//  Ein `FocusPlanningContext` über einen festen Satz Belege.
//
//  Genau dafür ist der Planer als Protokoll gebaut: er soll auch dann
//  arbeiten, wenn die Belege nicht aus der Datenbank kommen, sondern aus
//  einer Chat-Antwort, einer Auswahl im Transkript oder einer persönlichen
//  Ausgabe.
//

import Foundation
import PodcastAIKit

struct SnapshotPlanningContext: FocusPlanningContext {

    private let evidenceByID: [EvidenceID: Evidence]
    private let mediaByID: [MediaVersionID: MediaVersion]
    private let episodesByID: [EpisodeID: Episode]
    private let sourcesByID: [SourceID: Source]
    private let transcriptsByMedia: [MediaVersionID: Transcript]
    private let locator: any MediaLocating

    init(
        evidence: [Evidence],
        media: [MediaVersion] = [],
        episodes: [Episode] = [],
        sources: [Source] = [],
        transcripts: [Transcript] = [],
        locator: any MediaLocating = LocalMediaLocator()
    ) {
        self.evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.mediaByID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.episodesByID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.transcriptsByMedia = Dictionary(
            transcripts.map { ($0.mediaVersionID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        self.locator = locator
    }

    func evidence(for id: EvidenceID) -> Evidence? { evidenceByID[id] }

    func mediaVersion(for id: MediaVersionID) -> MediaVersion? {
        // Liegt keine geladene Fassung vor, wird aus dem Beleg eine minimale
        // abgeleitet. Sie trägt bewusst keine Dauer: der Planer soll nicht
        // gegen eine geratene Länge rechnen.
        mediaByID[id] ?? evidenceByID.values.first { $0.mediaVersionID == id }.map {
            MediaVersion(id: id, episodeID: $0.episodeID)
        }
    }

    func episode(for id: EpisodeID) -> Episode? {
        episodesByID[id] ?? evidenceByID.values.first { $0.episodeID == id }.map {
            Episode(id: id, sourceID: $0.sourceID, title: "Folge")
        }
    }

    func source(for id: SourceID) -> Source? {
        sourcesByID[id] ?? Source(id: id, kind: .podcastRSS, title: "Quelle")
    }

    func transcript(for id: MediaVersionID) -> Transcript? { transcriptsByMedia[id] }

    /// In diesem Zusammenhang ist die Fassung des Belegs die maßgebliche:
    /// die Belege stammen aus genau dem Schnappschuss, mit dem gearbeitet
    /// wird. Eine Prüfung gegen eine neuere Fassung findet statt, wenn der
    /// Kontext aus dem Store kommt.
    func currentMediaVersionID(for episodeID: EpisodeID) -> MediaVersionID? { nil }

    func isPlayable(_ mediaVersionID: MediaVersionID) -> Bool {
        locator.playbackURL(for: mediaVersionID) != nil
    }
}

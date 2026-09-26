//
//  PipelineSink.swift
//  PodcastAI
//
//  Die App an der Stufen-Pipeline (docs/plan-pipeline.md).
//
//  Schritt 0: Der alte Code sendet an den Stellen, an denen er bisher die
//  nächste Arbeit direkt aufruft, ein Ereignis an den `PipelineHost`. Die
//  direkten Aufrufe bleiben. Zu hören tut noch keine Stufe, nur die Tests im
//  Paket. Ein Ereignis ohne Zuhörer fällt im Host weg und kostet fast
//  nichts. Ereignisse mit Eingangsfassung müssten erst im Store lesen; das
//  geschieht nur, wenn jemand zuhört (`emit(_:of:media:_:)`).
//
//  Die Senke ist das Ende der Pipeline auf dem Hauptakteur. Sie wird die
//  Felder schreiben, die die Oberfläche heute liest (`stages`,
//  `stageDetails`, `factsProgress`, `chapterTagsRevision` und so weiter),
//  sobald die Stufen übernehmen. Bis dahin hört sie nicht zu und schreibt
//  nichts, denn sonst stünde jede Änderung doppelt da und jede Ansage käme
//  zweimal.
//

import Foundation
import PodcastAIKit

/// Das Ende der Pipeline auf dem Hauptakteur. Keine Ansicht abonniert
/// Ereignisse, die Oberfläche liest weiter das `AppModel`.
@MainActor
final class PipelineSink {

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    /// Was die Senke mit einem Ereignis tut. Erschöpfend, damit ein neues
    /// Ereignis hier eine Entscheidung verlangt. In Schritt 0 hört die Senke
    /// noch nicht zu; jeder Fall nennt, welcher Schritt ihn füllt.
    func receive(_ event: PipelineEvent) {
        guard model != nil else { return }
        switch event {
        case .transcriptSaved:
            // Schritt 5b: Stufe `.transcribed` der Folge.
            break
        case .evidenceReady:
            // Schritt 5b: Stufe `.evidenceExtracted`. Angesagt wird nur bei
            // `.user`, nie für Arbeit, die `reconcile()` gefunden hat.
            break
        case .tagsDone:
            // Schritt 3: `chapterTagsRevision` steigt.
            break
        case .episodesRemoved:
            // Schritt 3 und 5: Stufe, Angabe und Fortschritt der Folgen fallen weg.
            break
        case .episodesAdded, .audioAvailable, .audioRemoved, .transcriptFailed, .transcriptsIdle,
             .factsDone, .feedsRefreshed, .editionPublished, .changedElsewhere:
            // Laut Router nicht für die Senke.
            break
        }
    }
}

// MARK: - Senden aus dem alten Code

extension AppModel {

    /// Sendet ein Ereignis an die Pipeline. Vor `AppBootstrap.start` fällt es weg.
    func emit(_ event: PipelineEvent) {
        pipeline?.emit(event)
    }

    /// Sendet Ereignisse, die eine Eingangsfassung tragen. Die Fassung liest
    /// der Store, und nur, wenn eine Stufe zuhört, die eines davon bekäme.
    /// Die Ereignisse kommen deshalb etwas nach dem Aufruf; der Vertrag
    /// verlangt nur, dass sie nach dem Schreiben kommen. Untereinander
    /// bleiben sie in der Reihenfolge der Aufrufe.
    ///
    /// Wird die Folge in der Zwischenzeit gelöscht, fällt alles weg. Sonst
    /// käme etwa `evidenceReady` hinter `episodesRemoved` an, das ohne
    /// Warten hinausgeht.
    ///
    /// `media`: die Fassung, falls bekannt. Sonst gilt die aktuelle der Folge.
    func emit(_ kinds: [PipelineEvent.Kind], of id: EpisodeID, media: MediaVersionID? = nil,
              _ make: @escaping @Sendable (InputVersion) -> [PipelineEvent]) {
        guard let pipeline, kinds.contains(where: pipeline.hasListeners(for:)) else { return }
        let store = store
        let removals = removals
        // Der Stand jetzt, beim Aufruf: Was danach gelöscht wird, sendet nichts mehr.
        let ticket = removals.ticket
        let previous = pendingEmission
        pendingEmission = Task {
            let version = await Self.inputVersion(of: id, media: media, in: store)
            await previous?.value
            guard let version else { return }
            pipeline.emit(make(version), about: id, unlessRemovedSince: ticket, in: removals)
        }
    }

    /// Sendet ein Ereignis, sobald ein Schreiben zurückgekehrt ist, das als
    /// eigene Aufgabe läuft. So gilt der Vertrag der Pipeline (erst
    /// speichern, dann melden), ohne dass der Aufrufer auf das Speichern wartet.
    func emit(_ event: PipelineEvent, after write: Task<Void, Never>) {
        guard let pipeline, pipeline.hasListeners(for: event.kind) else { return }
        Task {
            await write.value
            pipeline.emit(event)
        }
    }

    /// Die Eingangsfassung einer Folge, wie der Store sie jetzt sieht.
    private nonisolated static func inputVersion(
        of id: EpisodeID, media: MediaVersionID?, in store: LibraryStore
    ) async -> InputVersion? {
        var mediaID = media
        if mediaID == nil { mediaID = try? await store.episodes(ids: [id]).first?.currentMediaVersionID }
        guard let mediaID, let fingerprint = try? await store.transcriptFingerprint(forMedia: mediaID) else {
            return nil
        }
        return InputVersion(mediaVersionID: mediaID, fingerprint: fingerprint)
    }

    /// Transkript und Belege sind gespeichert: `transcriptSaved`, dann
    /// `evidenceReady`. Der alte Weg meldet das Speichern des Transkripts
    /// nicht einzeln, und seine Stufe `.transcribed` kommt noch vor dem
    /// Speichern. Also gehen beide erst nach den Belegen hinaus.
    func emitTranscriptFinished(_ id: EpisodeID, media: MediaVersionID, origin: Origin) {
        emit([.transcriptSaved, .evidenceReady], of: id, media: media) { version in
            [.transcriptSaved(id, version, origin), .evidenceReady(id, version, origin)]
        }
    }

    /// Ein Lauf der Fakten ist zu Ende. Die Fakten sind da schon gespeichert.
    func emitFactsDone(_ id: EpisodeID, _ outcome: FactsOutcome, origin: Origin) {
        emit([.factsDone], of: id) { [.factsDone(id, $0, outcome, origin)] }
    }

    /// Eine Einordnung der Kapitel ist zu Ende. Die Kapitel-Tags sind da
    /// schon gespeichert.
    func emitTagsDone(_ id: EpisodeID, _ outcome: ChapterTagsOutcome, origin: Origin) {
        emit([.tagsDone], of: id) { [.tagsDone(id, $0, outcome, origin)] }
    }

    /// Welche Art von Fehlschlag ein Transkript hatte. Dieselben Regeln, nach
    /// denen `runAnalysis` entscheidet.
    static func transcriptFailure(_ error: Error, message: String?) -> TranscriptFailure {
        let kind: TranscriptFailure.Kind = switch error {
        case TranscriptionError.localeNotSupported: .localeNotSupported
        case TranscriptionError.speechUnavailableOnDevice: .speechUnavailable
        default:
            UserFacingError.isTransient(error) ? .transient
                : UserFacingError.isPermanent(error) ? .permanent : .other
        }
        return TranscriptFailure(kind, message: message)
    }

    /// Dasselbe für Untertitel über Supadata. Ein Fehler am Schlüssel oder
    /// Konto betrifft jedes Video, nicht diese Folge.
    static func transcriptFailure(_ failure: SupadataError) -> TranscriptFailure {
        let kind: TranscriptFailure.Kind = if failure.isTransient {
            .transient
        } else if failure.affectsAccount {
            .other
        } else {
            .permanent
        }
        return TranscriptFailure(kind, message: failure.errorDescription)
    }
}

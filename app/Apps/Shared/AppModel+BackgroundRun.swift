//
//  AppModel+BackgroundRun.swift
//  PodcastAI
//
//  Wann die fortgesetzte Verarbeitung beginnt und endet
//  (`BackgroundContinuation`).
//
//  Sie beginnt, solange die App vorn ist: wenn ein Lauf der Transkripte
//  startet, wenn jemand Fakten anfordert, und spätestens, wenn die App
//  inaktiv wird, also bevor sie in den Hintergrund geht. Im Hintergrund
//  lehnte das System die Anmeldung ab. Sie endet erst, wenn weder
//  Transkripte noch Fakten noch Kapitel-Tags etwas vorhaben, oder wenn
//  Fakten und Tags nur noch auf ein Modell warten.
//
//  Bis 0.13 endete sie mit dem letzten Transkript. Fakten und Tags dieser
//  Folge verloren damit ihren Träger, und die Anzeige stand während der
//  Fakten still, bis das System die Arbeit beendete.
//

import Foundation
import PodcastAIKit

extension AppModel {

    /// Was gerade ansteht, aus den Spiegeln der Stufen „Transkript“ und „Wissen“.
    var backgroundWorkLoad: BackgroundWorkLoad {
        let held = queueHeld
        return BackgroundWorkLoad(
            transcriptRunning: !held && analyzing != nil,
            transcriptsQueued: held ? 0 : analysisQueue.filter(mayRunNow).count,
            factsRunning: gatheringFacts != nil,
            factsQueued: factsQueue.count,
            tagsRunning: knowledgeTagsRunning,
            tagsQueued: knowledgeTagsQueued,
            knowledgeWaiting: held || factsWait != nil,
            automaticFacts: automaticFacts)
    }

    /// Meldet die fortgesetzte Verarbeitung an, wenn Arbeit ansteht und
    /// noch keine Anmeldung läuft. Nur vorn: Inaktiv, etwa beim Wechsel in
    /// den App-Umschalter, zählt noch als vorn.
    ///
    /// `transcriptStarting`: Die Stufe „Transkript“ beginnt gerade einen
    /// Lauf, ihr Spiegel zeigt das noch nicht.
    func beginBackgroundRunIfNeeded(subtitle: String? = nil, transcriptStarting: Bool = false) {
        #if os(iOS)
        // UI-Tests und ein Speicher nur im Arbeitsspeicher melden nichts beim
        // System an, wie beim Widget: Jeder Neustart der App im Test käme sonst
        // mit einer Anzeige des Systems über die Oberfläche.
        guard appInForeground, !store.isInMemory else { return }
        var load = backgroundWorkLoad
        if transcriptStarting { load.transcriptRunning = true }
        guard load.hasWork else { return }
        backgroundEndCheck?.cancel()
        backgroundEndCheck = nil
        if let running = backgroundContinuation, running.isActive {
            running.expect(load.expected)
            if let subtitle { running.setSubtitle(subtitle) }
            return
        }
        // Abgelaufen oder abgelehnt: eine neue Anmeldung, solange die App vorn ist.
        backgroundContinuation?.end()
        let step: BackgroundRunProgress.Step =
            load.transcriptRunning || load.transcriptsQueued > 0 ? .transcript
            : load.factsRunning || load.factsQueued > 0 ? .facts : .tags
        let continuation = BackgroundContinuation.begin(
            title: BackgroundContinuation.title(for: step),
            subtitle: subtitle ?? backgroundSubtitle(for: step),
            lease: holdCarrier(.continued),
            onExpire: { [weak self] in self?.backgroundTimeExpired() })
        continuation.expect(load.expected)
        backgroundContinuation = continuation
        #endif
    }

    /// Die Stände der Stufen haben sich geändert. Die Anzeige bekommt die
    /// neue Schätzung, und steht nichts mehr an, endet die Anmeldung. Kurz
    /// gewartet wird trotzdem: Zwischen dem letzten Transkript und seinen
    /// Fakten liegt ein Ereignis, und die Anmeldung endete sonst zu früh.
    func backgroundWorkChanged() {
        guard let continuation = backgroundContinuation else { return }
        let load = backgroundWorkLoad
        continuation.expect(load.expected)
        guard !load.hasWork else {
            backgroundEndCheck?.cancel()
            backgroundEndCheck = nil
            return
        }
        guard backgroundEndCheck == nil else { return }
        backgroundEndCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.backgroundEndCheck = nil
            guard !self.backgroundWorkLoad.hasWork else { return }
            self.backgroundContinuation?.end()
            self.backgroundContinuation = nil
        }
    }

    /// Die Zeit des Systems ist um. Die Anmeldung hat ihren Träger schon
    /// zurückgegeben: Fakten und Tags halten am Tor an und bleiben vorn in
    /// ihrer Warteschlange, Transkripte behalten ihren Zwischenstand. Ist
    /// die App wieder vorn, geht alles von selbst weiter.
    func backgroundTimeExpired() {
        backgroundEndCheck?.cancel()
        backgroundEndCheck = nil
        transcriptTimeExpired()
    }

    /// Fakten einer Folge beginnen oder kommen voran (`PipelineSink`).
    func backgroundFactsProgress(_ id: EpisodeID, fraction: Double) {
        guard let continuation = backgroundContinuation else { return }
        let subtitle = continuation.isCurrent(.facts, episode: id) ? nil : runEpisodeTitle(id)
        continuation.report(.facts, episode: id, .facts(fraction), subtitle: subtitle)
    }

    /// Kapitel-Tags einer Folge kommen voran (`PipelineSink`).
    func backgroundTagsProgress(_ id: EpisodeID, fraction: Double) {
        guard let continuation = backgroundContinuation else { return }
        let subtitle = continuation.isCurrent(.tags, episode: id) ? nil : runEpisodeTitle(id)
        continuation.report(.tags, episode: id, .tags(fraction), subtitle: subtitle)
    }

    private func runEpisodeTitle(_ id: EpisodeID) -> String? {
        episodes.values.lazy.joined().first { $0.id == id }?.title
    }

    /// Die Zeile unter der Überschrift, bevor der erste Schritt sich meldet.
    private func backgroundSubtitle(for step: BackgroundRunProgress.Step) -> String {
        let title: String? = switch step {
        case .transcript: analyzing?.title ?? analysisQueue.first?.title
        case .facts: gatheringFacts?.title ?? factsQueue.first?.title
        case .tags: nil
        }
        return title ?? BackgroundContinuation.title(for: step)
    }
}

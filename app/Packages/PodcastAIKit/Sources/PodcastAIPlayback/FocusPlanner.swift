//
//  FocusPlanner.swift
//  PodcastAIPlayback
//
//  Macht aus einem nicht vertrauenswürdigen Modellvorschlag einen geprüften
//  Hörplan. Die einzige Stelle, an der aus Kennungen Zeiten werden.
//
//  Reihenfolge der Prüfungen ist bewusst: erst Existenz und Scope, dann
//  Rechte und Fassung, dann Zeitbezug, dann Kontext, dann Verschmelzen,
//  dann Budget. Wer das Budget vorzieht, kürzt Stellen weg, die später
//  ohnehin ausgeschlossen worden wären. Erst ganz am Ende entsteht die
//  Abspielfolge; das Budget soll nach Wichtigkeit kürzen, nicht nach Zeit.
//

import Foundation
import PodcastAICore

/// Alles, was der Planer über den freigegebenen Bestand wissen muss.
/// Als Protokoll, damit der Planer ohne Store, ohne Netzwerk und ohne
/// Apple-Frameworks testbar bleibt.
public protocol FocusPlanningContext: Sendable {
    /// Liefert die Fundstelle — oder `nil`, wenn sie nicht existiert oder
    /// außerhalb des freigegebenen Bereichs liegt.
    func evidence(for id: EvidenceID) -> Evidence?
    func mediaVersion(for id: MediaVersionID) -> MediaVersion?
    func episode(for id: EpisodeID) -> Episode?
    func source(for id: SourceID) -> Source?
    func transcript(for id: MediaVersionID) -> Transcript?
    /// Die aktuell maßgebliche Fassung einer Folge. Weicht sie von der
    /// Fassung der Fundstelle ab, ist die Fundstelle veraltet.
    func currentMediaVersionID(for episodeID: EpisodeID) -> MediaVersionID?
    /// Ist das Medium lokal oder über eine autorisierte URL abspielbar?
    func isPlayable(_ mediaVersionID: MediaVersionID) -> Bool
}

public struct FocusPlannerOptions: Sendable {

    /// Wie weit eine Fundstelle in beide Richtungen ausgedehnt wird, bevor
    /// auf Segmentgrenzen eingerastet wird. Ohne Kontext beginnt ein Zitat
    /// mitten im Satz.
    public var contextPadding: MediaDuration
    /// Obergrenze für die reine Medienzeit. `nil` heißt: alles Passende.
    public var budget: MediaDuration?
    /// Wiedergabegeschwindigkeit, mit der das Budget gerechnet wird.
    public var playbackRate: Double
    /// Hörbare Pause zwischen zwei Abschnitten.
    public var transition: MediaDuration
    /// Bereits Gehörtes überspringen. Für persönliche Ausgaben immer an,
    /// für „diese Stelle nochmal“ aus.
    public var skipAlreadyHeard: Bool
    /// Der gemeinsame Hörzustand.
    public var ledger: ListeningLedger
    /// Abschnitte unterhalb dieser Länge werden verworfen.
    public var minimumSegmentDuration: MediaDuration
    /// Längenbegrenzung je Einzelabschnitt, damit eine Fundstelle nicht
    /// versehentlich die halbe Folge abspielt.
    public var maximumSegmentDuration: MediaDuration

    public init(
        contextPadding: MediaDuration = MediaDuration(seconds: 8),
        budget: MediaDuration? = nil,
        playbackRate: Double = 1.0,
        transition: MediaDuration = MediaDuration(milliseconds: 600),
        skipAlreadyHeard: Bool = true,
        ledger: ListeningLedger = ListeningLedger(),
        minimumSegmentDuration: MediaDuration = MediaDuration(seconds: 15),
        maximumSegmentDuration: MediaDuration = MediaDuration(minutes: 12)
    ) {
        self.contextPadding = contextPadding
        self.budget = budget
        self.playbackRate = playbackRate
        self.transition = transition
        self.skipAlreadyHeard = skipAlreadyHeard
        self.ledger = ledger
        self.minimumSegmentDuration = minimumSegmentDuration
        self.maximumSegmentDuration = maximumSegmentDuration
    }
}

public struct FocusPlanner: Sendable {

    private let context: any FocusPlanningContext

    public init(context: any FocusPlanningContext) {
        self.context = context
    }

    /// Erzeugt einen geprüften Plan. Kann einen leeren Plan liefern — das ist
    /// ein gültiges Ergebnis und kein Fehler.
    public func plan(
        from proposal: PlaylistProposal,
        route: PlaybackRoute,
        options: FocusPlannerOptions = FocusPlannerOptions()
    ) -> ValidatedPlaybackPlan {

        var resolved: [ResolvedCandidate] = []
        var excluded: [PlanExclusion] = []

        // 1. Auflösen und prüfen. Reihenfolge des Vorschlags bleibt erhalten.
        for evidenceID in proposal.evidenceIDs {
            switch resolve(evidenceID, options: options) {
            case .success(let candidate): resolved.append(candidate)
            case .failure(let exclusion): excluded.append(exclusion)
            }
        }

        // 2. Überlappende Bereiche derselben Fassung verschmelzen.
        let merged = mergeOverlapping(resolved)

        // 3. Budget anwenden — erst jetzt, wenn feststeht, was überhaupt übrig ist.
        //    In der Reihenfolge des Vorschlags, damit das Wichtigste bleibt.
        let (kept, overBudget) = applyBudget(merged, options: options)
        excluded.append(contentsOf: overBudget)

        // 4. Abspielfolge: Folgen in der Reihenfolge des Vorschlags, ihre
        //    Stellen am Stück und in der Zeitfolge des Originals.
        let ordered = playbackOrder(kept)

        // 5. In Abschnitte übersetzen.
        let segments = ordered.map { candidate in
            PlanSegment(
                evidenceID: candidate.primaryEvidenceID,
                mediaVersionID: candidate.mediaVersionID,
                episodeID: candidate.episodeID,
                sourceID: candidate.sourceID,
                range: candidate.range,
                sourceTitle: candidate.sourceTitle,
                episodeTitle: candidate.episodeTitle,
                rationale: proposal.rationales[candidate.primaryEvidenceID],
                mergedEvidenceIDs: candidate.contributions
                    .map(\.id)
                    .filter { $0 != candidate.primaryEvidenceID }
            )
        }

        return ValidatedPlaybackPlan(
            segments: segments,
            excluded: excluded,
            requestSummary: proposal.requestSummary,
            route: route
        )
    }

    // MARK: - Auflösen

    private struct ResolvedCandidate {
        var primaryEvidenceID: EvidenceID
        /// Fundstelle samt dem Bereich, den sie beisteuert. Nur mit dem
        /// Bereich lässt sich nach einer Kürzung sagen, welche Belege noch
        /// tatsächlich abgespielt werden — eine Liste blanker IDs würde
        /// Abdeckung behaupten, die es nicht mehr gibt.
        var contributions: [(id: EvidenceID, range: MediaTimeRange)] = []
        var mediaVersionID: MediaVersionID
        var episodeID: EpisodeID
        var sourceID: SourceID
        var range: MediaTimeRange
        var sourceTitle: String
        var episodeTitle: String
        /// Reihenfolge im ursprünglichen Vorschlag. Bestimmt, was ins Budget
        /// kommt und welche Folge zuerst läuft.
        var proposalIndex: Int = 0
    }

    private func resolve(
        _ id: EvidenceID,
        options: FocusPlannerOptions
    ) -> Result<ResolvedCandidate, PlanExclusion> {

        // Existenz und Scope in einem Schritt: der Kontext liefert nur, was
        // im freigegebenen Bereich liegt.
        guard let evidence = context.evidence(for: id) else {
            return .failure(.unknownEvidence(id))
        }
        guard let range = evidence.range, !range.isEmpty else {
            return .failure(.noTimingAvailable(id))
        }
        guard let media = context.mediaVersion(for: evidence.mediaVersionID) else {
            return .failure(.mediaUnavailable(id))
        }
        // Veraltete Fassung: die Fundstelle zeigt auf Zeiten, die in der
        // aktuellen Fassung woanders liegen können.
        if let current = context.currentMediaVersionID(for: evidence.episodeID),
           current != evidence.mediaVersionID {
            return .failure(.staleMediaVersion(id))
        }
        guard context.isPlayable(evidence.mediaVersionID) else {
            return .failure(.mediaUnavailable(id))
        }
        // Ein nicht zuverlässig suchbarer Stream darf nicht als exakt verkauft werden.
        guard media.supportsExactSeeking else {
            return .failure(.notSeekable(id))
        }
        guard let episode = context.episode(for: evidence.episodeID),
              let source = context.source(for: evidence.sourceID) else {
            return .failure(.unknownEvidence(id))
        }

        // Auf Satzkontext ausdehnen, dann auf Segmentgrenzen einrasten.
        var effective = range.expanded(by: options.contextPadding, limit: media.duration.map {
            MediaTime(milliseconds: $0.milliseconds)
        })
        if let transcript = context.transcript(for: evidence.mediaVersionID) {
            effective = transcript.snappedToSegmentBounds(effective)
        }
        effective = effective.clamped(toDuration: options.maximumSegmentDuration)

        // Bereits Gehörtes abziehen. Bleibt zu wenig übrig, fällt die Stelle raus.
        if options.skipAlreadyHeard {
            let unheard = options.ledger.unheardPortion(
                of: effective, in: evidence.mediaVersionID,
                minimumFragment: options.minimumSegmentDuration
            )
            guard let first = unheard.ranges.first else {
                return .failure(.alreadyHeard(id))
            }
            // Zusammenhängend bleiben: das größte ungehörte Stück gewinnt,
            // statt die Passage in Schnipsel zu zerlegen.
            effective = unheard.ranges.max { $0.duration < $1.duration } ?? first
        }

        guard effective.duration >= options.minimumSegmentDuration else {
            return .failure(.alreadyHeard(id))
        }

        return .success(ResolvedCandidate(
            primaryEvidenceID: id,
            contributions: [(id: id, range: effective)],
            mediaVersionID: evidence.mediaVersionID,
            episodeID: evidence.episodeID,
            sourceID: evidence.sourceID,
            range: effective,
            sourceTitle: source.title,
            episodeTitle: episode.title
        ))
    }

    // MARK: - Verschmelzen

    /// Fasst überlappende oder direkt angrenzende Bereiche **derselben
    /// Medienfassung** zusammen. Zwei Fundstellen 30 Sekunden auseinander
    /// erzeugen sonst einen hörbaren Sprung mitten im selben Gedanken.
    private func mergeOverlapping(_ candidates: [ResolvedCandidate]) -> [ResolvedCandidate] {
        guard candidates.count > 1 else { return candidates }

        var indexed = candidates
        for i in indexed.indices { indexed[i].proposalIndex = i }

        var byMedia: [MediaVersionID: [ResolvedCandidate]] = [:]
        for candidate in indexed {
            byMedia[candidate.mediaVersionID, default: []].append(candidate)
        }

        var merged: [ResolvedCandidate] = []
        for (_, group) in byMedia {
            let sorted = group.sorted { $0.range < $1.range }
            var current = sorted[0]
            for next in sorted.dropFirst() {
                if current.range.touchesOrOverlaps(next.range) {
                    current.range = MediaTimeRange(
                        start: min(current.range.start, next.range.start),
                        end: max(current.range.end, next.range.end)
                    )
                    current.contributions.append(contentsOf: next.contributions)
                    // Die früheste Position im Vorschlag bestimmt die Abspielfolge.
                    current.proposalIndex = min(current.proposalIndex, next.proposalIndex)
                } else {
                    merged.append(current)
                    current = next
                }
            }
            merged.append(current)
        }

        // Deterministische Endreihenfolge: nach Position im Vorschlag, bei
        // Gleichstand nach Medienzeit. Ohne das zweite Kriterium hinge die
        // Reihenfolge an der Iterationsreihenfolge des Dictionary.
        return merged.sorted {
            $0.proposalIndex != $1.proposalIndex
                ? $0.proposalIndex < $1.proposalIndex
                : $0.range < $1.range
        }
    }

    // MARK: - Abspielfolge

    /// Eine Folge steht dort, wo ihre früheste Stelle im Vorschlag stand.
    /// Ihre Stellen laufen danach am Stück und in der Zeitfolge der Folge,
    /// statt darin vor und zurück zu springen.
    private func playbackOrder(_ candidates: [ResolvedCandidate]) -> [ResolvedCandidate] {
        var order: [EpisodeID] = []
        var groups: [EpisodeID: [ResolvedCandidate]] = [:]
        for candidate in candidates {
            if groups[candidate.episodeID] == nil { order.append(candidate.episodeID) }
            groups[candidate.episodeID, default: []].append(candidate)
        }
        return order.flatMap { key in
            (groups[key] ?? []).sorted { lhs, rhs in
                if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
                return lhs.proposalIndex < rhs.proposalIndex
            }
        }
    }

    // MARK: - Budget

    /// Füllt bis zum Budget. Das Budget rechnet mit **tatsächlicher Hördauer**
    /// inklusive Übergängen, nicht mit reiner Medienzeit — „20 Minuten“ soll
    /// bedeuten, dass nach 20 Minuten Schluss ist.
    private func applyBudget(
        _ candidates: [ResolvedCandidate],
        options: FocusPlannerOptions
    ) -> ([ResolvedCandidate], [PlanExclusion]) {

        guard let budget = options.budget else { return (candidates, []) }

        var kept: [ResolvedCandidate] = []
        var dropped: [PlanExclusion] = []
        var usedMilliseconds: Int64 = 0

        for candidate in candidates {
            let listening = candidate.range.duration
                .listeningDuration(atRate: options.playbackRate).milliseconds
            let transition = kept.isEmpty ? 0 : options.transition.milliseconds

            if usedMilliseconds + transition + listening <= budget.milliseconds {
                usedMilliseconds += transition + listening
                kept.append(candidate)
                continue
            }

            // Passt nicht ganz — reicht der Rest noch für einen sinnvollen
            // Anfang? Lieber ein gekürzter Abschnitt als ein Loch im Budget.
            let remaining = budget.milliseconds - usedMilliseconds - transition
            let remainingMedia = MediaDuration(milliseconds: remaining)
                .listeningDuration(atRate: 1.0 / max(options.playbackRate, 0.01))

            if remainingMedia >= options.minimumSegmentDuration {
                var truncated = candidate
                truncated.range = candidate.range.clamped(toDuration: remainingMedia)
                // Belege, die nach der Kürzung nicht mehr erklingen, sind
                // ausgeschlossen — auch wenn der Abschnitt selbst bleibt.
                let stillCovered = truncated.contributions.filter {
                    $0.range.overlaps(truncated.range)
                }
                for lost in truncated.contributions where !stillCovered.contains(where: { $0.id == lost.id }) {
                    dropped.append(.budgetExhausted(lost.id))
                }
                truncated.contributions = stillCovered
                // Der Primärbeleg muss weiterhin der erste verbliebene sein.
                if !stillCovered.contains(where: { $0.id == truncated.primaryEvidenceID }),
                   let replacement = stillCovered.first {
                    truncated.primaryEvidenceID = replacement.id
                }
                usedMilliseconds = budget.milliseconds
                if !stillCovered.isEmpty { kept.append(truncated) }
            } else {
                // Alle Belege dieses Kandidaten fallen weg, nicht nur der erste.
                for contribution in candidate.contributions {
                    dropped.append(.budgetExhausted(contribution.id))
                }
            }
        }
        return (kept, dropped)
    }
}

//
//  LibraryStore+Commits.swift
//  PodcastAIPersistence
//
//  Geschütztes Schreiben der Erschließung: Transkript mit Belegen, Fakten,
//  Kapitel-Tags und erkannte Tags. Jede Methode prüft den Wächter
//  (`CommitGuard`) im selben Schritt, in dem sie schreibt.
//
//  Die alten Methoden (`save(transcript:…)`, `store(evidence:)`,
//  `save(facts:…)`, `save(chapterTags:…)`, `addDetectedTag(label:)`) bleiben
//  ohne Wächter stehen. Beispielinhalte und Tests legen damit absichtlich
//  Zustände an, die der Wächter ablehnen würde: Kapitel-Tags ohne Zeile der
//  Folge, verwaiste Belege nach einem Abgleich. Die Erschließung der App
//  schreibt nur noch über diese Datei.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAIKnowledge
import PodcastAISmartFeeds

extension LibraryStore {

    /// Was der Wächter über die Zeile der Folge sagt.
    enum GuardVerdict {
        case live(StoredEpisode)
        case stale(CommitGuard.StaleReason)
    }

    /// Prüft Folge, Quelle und Löschprotokoll. Läuft im selben Schritt wie
    /// das Schreiben danach, also kann dazwischen nichts geschehen.
    ///
    /// Gelöscht heißt hier wie beim Bereinigen: Es gibt keine lebende Kopie,
    /// oder eine Kopie unter derselben Quelle trägt das Merkzeichen. Ein
    /// Merkzeichen ohne Quelle aus einem früheren Abo zählt nicht, sonst
    /// ließe sich eine neu abonnierte Folge nie mehr erschließen.
    func verify(_ commitGuard: CommitGuard) throws -> GuardVerdict {
        // Eine Löschung auf diesem Gerät gilt, bevor der Store sie ausführt.
        if commitGuard.ledger.wasRemoved(commitGuard.episodeID, since: commitGuard.ticket) {
            return .stale(.removedWhileRunning)
        }
        let key = commitGuard.episodeID.rawValue
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.identifier == key }))
        let live = rows.filter { $0.removedAt == nil }
        guard !live.isEmpty else { return .stale(rows.isEmpty ? .episodeMissing : .episodeRemoved) }
        // Lieber die Kopie, an der schon eine Fassung hängt, wie `episodes(ids:)`.
        guard let row = live.first(where: { $0.source != nil && $0.currentMediaVersionIdentifier != nil })
                ?? live.first(where: { $0.source != nil }),
              let source = row.source?.identifier else {
            return .stale(.sourceMissing)
        }
        if commitGuard.ledger.wasRemoved(source: SourceID(rawValue: source), since: commitGuard.ticket) {
            return .stale(.removedWhileRunning)
        }
        if rows.contains(where: { $0.removedAt != nil && $0.source?.identifier == source }) {
            return .stale(.episodeRemoved)
        }
        return .live(row)
    }

    // MARK: - Transkript und Belege

    /// Sichert Fassung, Transkript und Belege einer Folge in einem Schritt.
    ///
    /// Bis 0.12 kamen Transkript und Belege in zwei Schritten, dazwischen
    /// ging der Zwischenstand des Transkripts weg. Endete die App genau
    /// dort, blieb ein Transkript ohne Belege, und nichts holte sie nach.
    ///
    /// Zeigt der Feed inzwischen auf eine andere Fassung, die schon ein
    /// Transkript hat, ist das Schreiben überholt. Liegt für die eigene
    /// Fassung schon ein Transkript mit Segmenten, von diesem Gerät oder über
    /// iCloud, bleibt es stehen, und die Belege entstehen aus ihm
    /// (`rebuild`), nicht aus dem neuen. Sonst passten die Belege nicht zum
    /// gespeicherten Transkript. Geprüft wird über die Fassung, nicht über
    /// die Kennung des Transkripts: die enthält die Sprache, und die kann
    /// je Gerät eine andere sein.
    ///
    /// `evidence` gehört zum neuen Transkript. `rebuild` läuft nur, wenn
    /// ein anderes schon da war, und dann in diesem Schritt.
    public func commit(
        transcript: Transcript,
        media: MediaVersion,
        evidence: [Evidence],
        rebuild: @Sendable (Transcript) -> [Evidence],
        under commitGuard: CommitGuard
    ) throws -> CommitResult<[Evidence]> {
        evidenceChanged()
        defer { evidenceChanged() }
        let episode: StoredEpisode
        switch try verify(commitGuard) {
        case .stale(let reason): return .stale(reason)
        case .live(let row): episode = row
        }
        // Zeigt der Feed inzwischen auf eine andere Fassung, und hat die schon
        // ein Transkript, verdrängte das alte Ergebnis das neue. Ohne
        // Transkript der neuen Fassung wird geschrieben wie bisher: Manche
        // Feeds ändern die Audioadresse bei jedem Abruf, etwa mit einem
        // Zeitstempel, und ein Aktualisieren während eines Transkripts
        // machte die Arbeit sonst jedes Mal zunichte.
        if let feed = commitGuard.feedMedia(episode.snapshot), feed != media.id,
           let newer = try latestTranscriptRow(forMedia: feed.rawValue), try fingerprint(of: newer) != nil {
            return .stale(.mediaChanged)
        }

        var receipt = WriteReceipt(episodeID: commitGuard.episodeID)
        let mediaKey = media.id.rawValue
        let storedMedia: StoredMediaVersion
        if let existing = try modelContext.fetch(FetchDescriptor<StoredMediaVersion>(
            predicate: #Predicate { $0.identifier == mediaKey })).first {
            storedMedia = existing
        } else {
            storedMedia = StoredMediaVersion(identifier: mediaKey)
            modelContext.insert(storedMedia)
            receipt.mediaVersionIDs.append(media.id)
        }
        storedMedia.remoteURLString = media.remoteURL?.absoluteString
        storedMedia.localRelativePath = media.localRelativePath
        storedMedia.byteCount = Int(media.byteCount ?? 0)
        storedMedia.contentHash = media.contentHash
        storedMedia.durationMs = Int(media.duration?.milliseconds ?? 0)
        storedMedia.mimeType = media.mimeType
        storedMedia.supportsExactSeeking = media.supportsExactSeeking
        storedMedia.episode = episode
        // Die aktuelle Fassung der Folge ist die zuletzt erschlossene.
        episode.currentMediaVersionIdentifier = mediaKey

        // Schon da? Zuerst über die Fassung, dann über die eigene Kennung:
        // ein Transkript, das seine Fassung beim Abgleich verloren hat.
        var kept: StoredTranscript?
        if let latest = try latestTranscriptRow(forMedia: mediaKey), try fingerprint(of: latest) != nil {
            kept = latest
        }
        let transcriptKey = transcript.id.rawValue
        let sameID = try modelContext.fetch(FetchDescriptor<StoredTranscript>(
            predicate: #Predicate { $0.identifier == transcriptKey })).first
        if kept == nil, let sameID, try fingerprint(of: sameID) != nil {
            sameID.mediaVersion = storedMedia
            kept = sameID
        }

        let items: [Evidence]
        if let kept {
            let stored = kept.snapshot
            receipt.keptTranscriptID = stored.id
            items = rebuild(stored)
        } else {
            // Eine leere Zeile mit derselben Kennung wird gefüllt, statt
            // eine zweite anzulegen.
            let row = sameID ?? {
                let fresh = StoredTranscript(identifier: transcriptKey)
                modelContext.insert(fresh)
                return fresh
            }()
            row.revisionValue = transcript.revision.value
            row.originRaw = transcript.origin.rawValue
            row.locale = transcript.locale
            row.createdAt = transcript.createdAt
            row.analyzedRangesFlat = StoredTranscript.flat(from: transcript.analyzedRanges)
            row.untimedText = transcript.untimedText
            row.mediaVersion = storedMedia
            for segment in transcript.segments {
                let piece = StoredSegment(
                    identifier: segment.id.rawValue,
                    startMs: Int(segment.range.start.milliseconds),
                    endMs: Int(segment.range.end.milliseconds),
                    text: segment.text)
                piece.speakerLabel = segment.speakerLabel
                piece.transcript = row
                modelContext.insert(piece)
            }
            receipt.transcriptIDs.append(transcript.id)
            items = evidence
        }

        receipt.evidenceIDs = try insertEvidence(items)
        try modelContext.save()
        return .written(receipt, items)
    }

    /// Legt Belege an, die es noch nicht gibt. Belege sind unveränderlich,
    /// wie in ``store(evidence:)``. Zurück kommen die neuen Kennungen.
    private func insertEvidence(_ evidence: [Evidence]) throws -> [EvidenceID] {
        var inserted: [EvidenceID] = []
        var seen: Set<String> = []
        for item in evidence {
            let identifier = item.id.rawValue
            guard seen.insert(identifier).inserted else { continue }
            let existing = try modelContext.fetchCount(FetchDescriptor<StoredEvidence>(
                predicate: #Predicate { $0.identifier == identifier }))
            guard existing == 0 else { continue }
            let stored = StoredEvidence(identifier: identifier)
            stored.mediaVersionIdentifier = item.mediaVersionID.rawValue
            stored.episodeIdentifier = item.episodeID.rawValue
            stored.sourceIdentifier = item.sourceID.rawValue
            stored.transcriptIdentifier = item.transcriptID.rawValue
            stored.transcriptRevisionValue = item.transcriptRevision.value
            stored.hasTiming = item.range != nil
            stored.startMs = Int(item.range?.start.milliseconds ?? 0)
            stored.endMs = Int(item.range?.end.milliseconds ?? 0)
            stored.quotedText = item.quotedText
            stored.attributedSpeaker = item.attributedSpeaker
            modelContext.insert(stored)
            inserted.append(item.id)
        }
        return inserted
    }

    // MARK: - Fakten

    /// Ersetzt die Fakten einer Folge.
    ///
    /// Die Eingabe der Fakten sind Belege. Zeigt ein Fakt auf einen Beleg,
    /// den es nicht mehr gibt, ist sie überholt, und nichts wird ersetzt.
    /// Die Fassung vergleicht der Wächter hier nicht: Belege einer Folge
    /// können aus mehreren Fassungen stammen, etwa nachdem der Feed die
    /// Audioadresse geändert hat, und ihre Fakten bleiben gültig.
    public func commit(facts: [EpisodeFact], under commitGuard: CommitGuard) throws -> CommitResult<Void> {
        if case .stale(let reason) = try verify(commitGuard) { return .stale(reason) }
        let key = commitGuard.episodeID.rawValue
        var descriptor = FetchDescriptor<StoredEvidence>(predicate: #Predicate { $0.episodeIdentifier == key })
        descriptor.propertiesToFetch = [\.identifier]
        let known = Set(try modelContext.fetch(descriptor).map(\.identifier))
        guard facts.allSatisfy({ known.contains($0.evidenceID.rawValue) }) else { return .stale(.inputChanged) }

        for row in try modelContext.fetch(FetchDescriptor<StoredFact>(
            predicate: #Predicate { $0.episodeIdentifier == key })) {
            modelContext.delete(row)
        }
        var receipt = WriteReceipt(episodeID: commitGuard.episodeID)
        var written: Set<String> = []
        for fact in facts {
            let row = StoredFact(identifier: fact.id)
            row.episodeIdentifier = fact.episodeID.rawValue
            row.sourceIdentifier = fact.sourceID.rawValue
            row.evidenceIdentifier = fact.evidenceID.rawValue
            row.mediaVersionIdentifier = fact.mediaVersionID.rawValue
            row.statement = fact.statement
            row.startMs = Int(fact.range.start.milliseconds)
            row.endMs = Int(fact.range.end.milliseconds)
            row.modelTier = fact.modelTier
            modelContext.insert(row)
            if written.insert(fact.id).inserted { receipt.factIDs.append(fact.id) }
        }
        try modelContext.save()
        return .written(receipt, ())
    }

    // MARK: - Kapitel-Tags

    /// Ersetzt die Kapitel-Tags einer Folge durch die einer Einordnung.
    ///
    /// Die Eingabe ist die Fassung, die eine Einordnung jetzt lesen würde
    /// (``ChapterTagVersion``), in genau dieser Revision. Ist es inzwischen
    /// eine andere, etwa weil ein neues Transkript angekommen ist, oder
    /// gibt es ihre Belege nicht mehr, ist sie überholt. Liegen schon
    /// Kapitel-Tags aus einer neueren Revision derselben Fassung vor, heißt
    /// das Ergebnis `.superseded`, wie bisher ohne zu schreiben.
    ///
    /// Regel 3 wie in ``save(chapterTags:forEpisode:transcriptRevision:)``:
    /// Jedes Kapitel-Tag muss auf ein gespeichertes Tag zeigen, den
    /// Schlüssel nimmt der Store vom Tag.
    public func commit(
        chapterTags: [ChapterTag], media: MediaVersionID, transcriptRevision: Revision,
        under commitGuard: CommitGuard
    ) throws -> CommitResult<Void> {
        let episode: StoredEpisode
        switch try verify(commitGuard) {
        case .stale(let reason): return .stale(reason)
        case .live(let row): episode = row
        }
        let episodeID = commitGuard.episodeID
        let key = episodeID.rawValue
        var timed = FetchDescriptor<StoredEvidence>(
            predicate: #Predicate { $0.episodeIdentifier == key && $0.hasTiming == true })
        timed.propertiesToFetch = [\.mediaVersionIdentifier, \.transcriptRevisionValue]
        var revisions: [MediaVersionID: Int] = [:]
        for row in try modelContext.fetch(timed) {
            let id = MediaVersionID(rawValue: row.mediaVersionIdentifier)
            revisions[id] = max(revisions[id] ?? 0, row.transcriptRevisionValue)
        }
        let preferred = episode.currentMediaVersionIdentifier.map(MediaVersionID.init(rawValue:))
        guard ChapterTagVersion.current(revisions: revisions, preferred: preferred) == media,
              revisions[media] == transcriptRevision.value else {
            return .stale(.inputChanged)
        }

        let existing = try modelContext.fetch(
            FetchDescriptor<StoredChapterTag>(predicate: #Predicate { $0.episodeIdentifier == key }))
        if existing.contains(where: {
            $0.mediaVersionIdentifier == media.rawValue && $0.transcriptRevisionValue > transcriptRevision.value
        }) { return .stale(.superseded) }

        let interestKeys = Set(chapterTags.map(\.interestID.rawValue))
        var storedKey: [String: String] = [:]
        for row in try modelContext.fetch(FetchDescriptor<StoredInterest>(
            predicate: #Predicate { interestKeys.contains($0.identifier) })) {
            let normalized = row.normalizedKey.isEmpty ? TagNormalizer.key(for: row.label) : row.normalizedKey
            if !normalized.isEmpty { storedKey[row.identifier] = normalized }
        }
        for row in existing { modelContext.delete(row) }

        var receipt = WriteReceipt(episodeID: episodeID)
        var written: Set<ChapterTagID> = []
        var firstSeen: [String: Date] = [:]
        for proposed in chapterTags where proposed.episodeID == episodeID && proposed.mediaVersionID == media {
            guard let normalizedKey = storedKey[proposed.interestID.rawValue] else { continue }
            let tag = ChapterTag(
                episodeID: proposed.episodeID, mediaVersionID: proposed.mediaVersionID,
                chapterStartMs: proposed.chapterStartMs, chapterEndMs: proposed.chapterEndMs,
                interestID: proposed.interestID, normalizedKey: normalizedKey,
                confidence: proposed.confidence, matchedKnown: proposed.matchedKnown,
                sourceID: proposed.sourceID, publishedAt: proposed.publishedAt,
                createdAt: proposed.createdAt, transcriptRevision: transcriptRevision)
            guard written.insert(tag.id).inserted else { continue }
            let row = StoredChapterTag(identifier: tag.id.rawValue)
            row.apply(tag)
            modelContext.insert(row)
            receipt.chapterTagIDs.append(tag.id)
            let interest = tag.interestID.rawValue
            firstSeen[interest] = min(firstSeen[interest] ?? tag.createdAt, tag.createdAt)
        }
        try modelContext.save()
        try noteFirstSeen(firstSeen)
        return .written(receipt, ())
    }

    // MARK: - Erkannte Tags

    /// Ein Tag, das die Einordnung im Inhalt einer Folge erkannt hat, wie
    /// ``addDetectedTag(label:seenAt:)``, aber nur, solange der Wächter
    /// nichts einwendet. Der Beleg nennt das Tag, wenn es neu angelegt
    /// wurde. Wird die Folge danach gelöscht, geht es mit, sofern nichts
    /// anderes darauf zeigt (``removeOrphanedDetectedTags(_:)``).
    public func addDetectedTag(
        label: String, seenAt: Date = Date(), under commitGuard: CommitGuard
    ) throws -> CommitResult<Tag?> {
        if case .stale(let reason) = try verify(commitGuard) { return .stale(reason) }
        var receipt = WriteReceipt(episodeID: commitGuard.episodeID)
        let (tag, created) = try insertDetectedTag(label: label, seenAt: seenAt)
        if created, let tag { receipt.tagIDs.append(tag.id) }
        return .written(receipt, tag)
    }

    /// Löscht erkannte Tags, die aus einer gelöschten Folge entstanden sind
    /// und auf die nichts mehr zeigt: kein Kapitel-Tag, kein Themen-Update,
    /// keine Ausgabe, keine gemerkte Stelle. Nur, solange sie erkannt und
    /// neutral sind. Wer einem Tag folgt oder es bestätigt hat, behält es.
    @discardableResult
    public func removeOrphanedDetectedTags(_ ids: [InterestID]) throws -> [InterestID] {
        let keys = Set(ids.map(\.rawValue))
        guard !keys.isEmpty else { return [] }
        let detected = InterestOrigin.detected.rawValue
        let neutral = TagStance.neutral.rawValue
        let rows = try modelContext.fetch(FetchDescriptor<StoredInterest>(
            predicate: #Predicate { keys.contains($0.identifier) }))
            .filter { $0.originRaw == detected && $0.stanceRaw == neutral }
        var orphans = Set(rows.map(\.identifier))
        guard !orphans.isEmpty else { return [] }

        let candidates = orphans
        for tag in try modelContext.fetch(FetchDescriptor<StoredChapterTag>(
            predicate: #Predicate { candidates.contains($0.interestIdentifier) })) {
            orphans.remove(tag.interestIdentifier)
        }
        if !orphans.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredSmartFeed>()) {
                guard let feed = try? Self.decoder.decode(SmartPodcastFeed.self, from: row.payload) else { continue }
                orphans.subtract(feed.topicIDs.map(\.rawValue))
            }
        }
        if !orphans.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredPersonalEpisode>()) {
                guard let edition = try? Self.decoder.decode(PersonalEpisode.self, from: row.payload) else { continue }
                for segment in edition.segments { orphans.subtract(segment.topicIDs.map(\.rawValue)) }
                for entry in edition.overviewEntries { orphans.subtract(entry.tagIDs.map(\.rawValue)) }
            }
        }
        if !orphans.isEmpty {
            for row in try modelContext.fetch(FetchDescriptor<StoredHighlight>()) {
                guard let data = row.payload,
                      let highlight = try? Self.decoder.decode(Highlight.self, from: data) else { continue }
                orphans.subtract(highlight.interestIDs.map(\.rawValue))
            }
        }
        guard !orphans.isEmpty else { return [] }
        for row in rows where orphans.contains(row.identifier) { modelContext.delete(row) }
        try modelContext.save()
        return orphans.sorted().map(InterestID.init(rawValue:))
    }
}
#endif

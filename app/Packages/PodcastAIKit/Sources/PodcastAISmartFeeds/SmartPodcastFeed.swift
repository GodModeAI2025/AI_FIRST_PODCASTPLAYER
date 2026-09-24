//
//  SmartPodcastFeed.swift
//  PodcastAISmartFeeds
//
//  „Deine Interessen werden zu einem eigenen Podcast — aber die Stimmen und
//  Aussagen bleiben die der Originalquellen.“
//
//  Feldnamen und Zustände folgen
//  specs/001-ai-podcast-player/contracts/smart-feed.schema.json und
//  personal-episode.schema.json.
//

import Foundation
import PodcastAICore

/// Was als ungehört gilt.
public enum UnheardFilter: String, Codable, Sendable, CaseIterable {
    /// Auch ungehörte Teile bereits angefangener Folgen.
    case unheardSegments
    /// Nur Folgen, die noch gar nicht begonnen wurden.
    case neverStartedEpisodes

    public var label: String {
        switch self {
        case .unheardSegments: String(localized: "Alles Ungehörte, auch aus angefangenen Folgen", bundle: .module)
        case .neverStartedEpisodes: String(localized: "Nur noch nicht begonnene Folgen", bundle: .module)
        }
    }
}

/// Wie viel in eine Ausgabe kommt.
///
/// Die Trennung ist ausdrücklich gefordert (FR-126): „alles Ungehörte“ ist
/// ein anderer Modus als ein kurzes budgetiertes Update, und das eine darf
/// nicht stillschweigend als das andere ausgeliefert werden.
public enum EditionMode: Codable, Sendable, Hashable {
    case allUnheard
    case budgeted(MediaDuration)

    public var budget: MediaDuration? {
        if case .budgeted(let duration) = self { return duration }
        return nil
    }

    public var label: String {
        switch self {
        case .allUnheard: String(localized: "Alles Ungehörte", bundle: .module)
        case .budgeted(let d): d.shortDescription
        }
    }
}

/// Wann eine neue Ausgabe entsteht.
///
/// Schließt die im Plan als FR-147 vorgeschlagene Lücke: feste
/// Hintergrundzeitpunkte werden nicht zugesagt, weil das Betriebssystem sie
/// nicht garantiert. Stattdessen ein Auslöser plus sichtbarer Zustand.
public enum PublicationPolicy: Codable, Sendable, Hashable {
    /// Sobald genug neues Material vorliegt.
    case whenNewSegments(minimumMaterial: MediaDuration)
    /// Nur auf ausdrückliche Anforderung.
    case manual

    public var minimumMaterial: MediaDuration {
        switch self {
        case .whenNewSegments(let minimum): minimum
        case .manual: MediaDuration(seconds: 30)
        }
    }

    public var isAutomatic: Bool {
        if case .whenNewSegments = self { return true }
        return false
    }
}

/// Ein persönlicher Themenfeed: „Mein KI Update“, „Morning Knowledge“.
public struct SmartPodcastFeed: Codable, Sendable, Identifiable, Hashable {

    public let id: SmartFeedID
    public var title: String
    public var subtitle: String?

    /// Die Interessen, aus denen dieser Feed gespeist wird. Mehrere Themen
    /// ergeben einen gemischten Feed, ein Thema einen fokussierten.
    public var topicIDs: [InterestID]

    /// Auf welche Quellen der Feed schauen darf. Leer heißt: alle abonnierten.
    /// Ein Feed sucht niemals außerhalb des Bestands — keine Websuche.
    public var restrictedToSourceIDs: [SourceID]

    public var unheardFilter: UnheardFilter
    public var editionMode: EditionMode
    public var publicationPolicy: PublicationPolicy
    public var notificationsEnabled: Bool

    /// Fassung des Interessenprofils, mit der zuletzt gearbeitet wurde.
    /// Ändert sich das Profil, ändert das **nicht** bereits veröffentlichte
    /// Ausgaben — die bleiben, wie sie waren.
    public var profileRevision: Revision
    public var policyRevision: Revision
    public var createdAt: Date

    /// Vom Nutzer bestätigtes Feedmotiv, das neue Ausgaben wiederverwenden dürfen.
    public var confirmedCoverAssetID: String?

    public init(
        id: SmartFeedID = SmartFeedID(), title: String, subtitle: String? = nil,
        topicIDs: [InterestID], restrictedToSourceIDs: [SourceID] = [],
        unheardFilter: UnheardFilter = .unheardSegments,
        editionMode: EditionMode = .budgeted(MediaDuration(minutes: 20)),
        publicationPolicy: PublicationPolicy = .whenNewSegments(minimumMaterial: MediaDuration(minutes: 5)),
        notificationsEnabled: Bool = false,
        profileRevision: Revision = .initial, policyRevision: Revision = .initial,
        createdAt: Date = Date(), confirmedCoverAssetID: String? = nil
    ) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.topicIDs = topicIDs; self.restrictedToSourceIDs = restrictedToSourceIDs
        self.unheardFilter = unheardFilter; self.editionMode = editionMode
        self.publicationPolicy = publicationPolicy; self.notificationsEnabled = notificationsEnabled
        self.profileRevision = profileRevision; self.policyRevision = policyRevision
        self.createdAt = createdAt; self.confirmedCoverAssetID = confirmedCoverAssetID
    }
}

/// Ein Abschnitt einer persönlichen Ausgabe.
///
/// Drei Zeitbereiche, die sich bewusst unterscheiden:
///
///   coreRange     — das tatsächlich Neue. Nur dieser Teil zählt als „neu für dich“.
///   playbackRange — was abgespielt wird, inklusive nötiger Kontextwiederholung.
///   virtualRange  — die Position in der Zeitachse der persönlichen Ausgabe.
///
/// Die Trennung von core und playback ist der Grund, warum Kontext nicht
/// fälschlich als ungehörter Inhalt zählt: wer die Kontextsekunden schon
/// kennt, bekommt sie trotzdem zu hören, aber sie machen die Ausgabe nicht
/// „neu“.
public struct PersonalEpisodeSegment: Codable, Sendable, Hashable, Identifiable {

    public let id: SegmentID
    public let episodeID: EpisodeID
    public let mediaVersionID: MediaVersionID
    public let transcriptRevision: Revision
    /// Mindestens ein Beleg. Ohne Beleg entsteht kein Abschnitt.
    public let evidenceIDs: [EvidenceID]

    public let coreRange: MediaTimeRange
    public let playbackRange: MediaTimeRange
    public let virtualRange: MediaTimeRange

    /// Warum dieser Abschnitt hier ist — wird in den Shownotes angezeigt.
    public let reason: String
    public let topicIDs: [InterestID]
    /// Enthält dieser Abschnitt bewusst bereits Gehörtes als Kontext?
    public let contextReplay: Bool

    /// Für die Anzeige des Quellenwechsels.
    public let sourceID: SourceID
    public let sourceTitle: String
    public let episodeTitle: String
    /// Datum der **Originalfolge** — nicht das der persönlichen Veröffentlichung.
    public let originalPublishedAt: Date?

    public init(
        id: SegmentID, episodeID: EpisodeID, mediaVersionID: MediaVersionID,
        transcriptRevision: Revision, evidenceIDs: [EvidenceID],
        coreRange: MediaTimeRange, playbackRange: MediaTimeRange, virtualRange: MediaTimeRange,
        reason: String, topicIDs: [InterestID], contextReplay: Bool,
        sourceID: SourceID, sourceTitle: String, episodeTitle: String,
        originalPublishedAt: Date? = nil
    ) {
        self.id = id; self.episodeID = episodeID; self.mediaVersionID = mediaVersionID
        self.transcriptRevision = transcriptRevision; self.evidenceIDs = evidenceIDs
        self.coreRange = coreRange; self.playbackRange = playbackRange
        self.virtualRange = virtualRange; self.reason = reason; self.topicIDs = topicIDs
        self.contextReplay = contextReplay; self.sourceID = sourceID
        self.sourceTitle = sourceTitle; self.episodeTitle = episodeTitle
        self.originalPublishedAt = originalPublishedAt
    }
}

public enum PublicationState: String, Codable, Sendable {
    case draft, published, unavailable, archived
}

public enum ConsumptionState: String, Codable, Sendable {
    case unplayed, inProgress, completed
}

/// Eine veröffentlichte persönliche Ausgabe.
///
/// **Unveränderlich.** Neue passende Segmente erzeugen eine neue Ausgabe,
/// nie eine stillschweigende Änderung an dieser (FR-127). Wer mitten in
/// einer Ausgabe steckt, soll nicht merken, dass sich unter ihm die
/// Kapitelstruktur verschiebt.
public struct PersonalEpisode: Codable, Sendable, Identifiable, Hashable {

    public let id: PersonalEpisodeID
    public let feedID: SmartFeedID
    public let revision: Revision
    public let policyRevision: Revision

    /// Identität des Kandidatenlaufs. Zweimal derselbe Refresh erzeugt
    /// denselben Schlüssel und damit **eine** Ausgabe, nicht zwei.
    public let batchKey: String
    /// Inhaltsadresse des Manifests. Ändert sich ein Abschnitt, ändert sich
    /// der Hash — daran erkennt der Sync eine echte Änderung.
    public let manifestHash: String

    public let title: String
    public let subtitle: String?
    /// Wann **diese Ausgabe** entstanden ist. Nicht das Datum der Originalfolgen.
    public let publishedAt: Date
    public let publicationState: PublicationState
    public var consumptionState: ConsumptionState

    public let segments: [PersonalEpisodeSegment]
    public let shownotes: [ShownotesEntry]
    public let coverAssetID: String?

    /// Wie viel Bestand noch aussteht — macht sichtbar, dass eine budgetierte
    /// Ausgabe nicht alles enthält.
    public let coverage: EditionCoverage

    public init(
        id: PersonalEpisodeID = PersonalEpisodeID(), feedID: SmartFeedID,
        revision: Revision = .initial, policyRevision: Revision,
        batchKey: String, title: String, subtitle: String? = nil,
        publishedAt: Date = Date(), publicationState: PublicationState = .published,
        consumptionState: ConsumptionState = .unplayed,
        segments: [PersonalEpisodeSegment], shownotes: [ShownotesEntry],
        coverAssetID: String? = nil, coverage: EditionCoverage
    ) {
        self.id = id; self.feedID = feedID; self.revision = revision
        self.policyRevision = policyRevision; self.batchKey = batchKey
        self.title = title; self.subtitle = subtitle; self.publishedAt = publishedAt
        self.publicationState = publicationState; self.consumptionState = consumptionState
        self.segments = segments; self.shownotes = shownotes
        self.coverAssetID = coverAssetID; self.coverage = coverage
        // Das Manifest belegt, aus welchen Stellen eine Ausgabe besteht.
        // Auch hier entscheidet die Prüfsumme, nicht nur benennt sie.
        self.manifestHash = SecureDigest.hex(ofOrdered: segments.map {
            "\($0.mediaVersionID.rawValue):\($0.coreRange.start.milliseconds)-\($0.coreRange.end.milliseconds)"
        })
    }

    /// Gesamtlänge der Ausgabe in ihrer eigenen Zeitachse.
    public var totalMediaDuration: MediaDuration {
        MediaDuration(milliseconds: segments.last?.virtualRange.end.milliseconds ?? 0)
    }

    public var distinctSourceCount: Int { Set(segments.map(\.sourceID)).count }

    /// Übersetzt eine Position in der persönlichen Ausgabe zurück auf die
    /// Originalfassung. Grundlage für „im Original weiterhören“ und dafür,
    /// dass Gehörtes im gemeinsamen Hörzustand landet.
    public func originalPosition(forVirtual time: MediaTime) -> (mediaVersionID: MediaVersionID, position: MediaTime)? {
        guard let segment = segments.first(where: { $0.virtualRange.contains(time) }) else { return nil }
        let offset = time.milliseconds - segment.virtualRange.start.milliseconds
        return (segment.mediaVersionID,
                MediaTime(milliseconds: segment.playbackRange.start.milliseconds + offset))
    }

    /// Wie ``originalPosition(forVirtual:)``, dazu die Originalfolge. Dafür
    /// steht „Original öffnen“ an jedem Kapitel einer Ausgabe.
    public func originalEpisodePosition(
        forVirtual time: MediaTime
    ) -> (episodeID: EpisodeID, mediaVersionID: MediaVersionID, position: MediaTime)? {
        guard let original = originalPosition(forVirtual: time),
              let segment = segments.first(where: { $0.virtualRange.contains(time) }) else { return nil }
        return (segment.episodeID, original.mediaVersionID, original.position)
    }

    /// Die Ledger-Ereignisse, die beim Hören dieser Ausgabe entstehen.
    ///
    /// Hier schließt sich der Kreis: was im persönlichen Update gehört wurde,
    /// ist danach auch in der Originalfolge gehört.
    public func ledgerEvents(forVirtualRange range: MediaTimeRange, deviceID: String) -> [LedgerEvent] {
        segments.compactMap { segment in
            guard let overlap = segment.virtualRange.intersection(range) else { return nil }
            let startOffset = overlap.start.milliseconds - segment.virtualRange.start.milliseconds
            let endOffset = overlap.end.milliseconds - segment.virtualRange.start.milliseconds
            let original = MediaTimeRange(
                start: MediaTime(milliseconds: segment.playbackRange.start.milliseconds + startOffset),
                end: MediaTime(milliseconds: segment.playbackRange.start.milliseconds + endOffset)
            )
            return LedgerEvent(mediaVersionID: segment.mediaVersionID, range: original,
                               kind: .played, via: .smartFeedEpisode, deviceID: deviceID)
        }
    }
}

/// Wie vollständig eine Ausgabe den verfügbaren Bestand abdeckt.
public struct EditionCoverage: Codable, Sendable, Hashable {
    /// Wie viele passende ungehörte Segmente insgesamt vorlagen.
    public let candidateCount: Int
    /// Wie viele davon in diese Ausgabe kamen.
    public let includedCount: Int
    /// Wie viel Medienzeit noch aussteht.
    public let remaining: MediaDuration
    /// Quellen, die nicht vollständig analysiert sind — deren Beitrag könnte
    /// unvollständig sein, und das bleibt sichtbar.
    public let partiallyAnalyzedSourceIDs: [SourceID]

    public init(candidateCount: Int, includedCount: Int, remaining: MediaDuration,
                partiallyAnalyzedSourceIDs: [SourceID] = []) {
        self.candidateCount = candidateCount; self.includedCount = includedCount
        self.remaining = remaining; self.partiallyAnalyzedSourceIDs = partiallyAnalyzedSourceIDs
    }

    public var isExhaustive: Bool {
        includedCount == candidateCount && partiallyAnalyzedSourceIDs.isEmpty
    }

    public var label: String {
        if isExhaustive { return String(localized: "Enthält alles Ungehörte zu diesen Themen.", bundle: .module) }
        if remaining.isZero {
            return String(AttributedString(localized: """
                Enthält \(includedCount) von ^[\(candidateCount) Stelle](inflect: true).
                """, bundle: .module).characters)
        }
        return String(AttributedString(localized: """
            Enthält \(includedCount) von ^[\(candidateCount) Stelle](inflect: true). \
            Es bleiben \(remaining.shortDescription).
            """, bundle: .module).characters)
    }
}

/// Ein Kapiteleintrag der persönlichen Ausgabe, mit Rückverweis auf das Original.
public struct ShownotesEntry: Codable, Sendable, Hashable {
    public let virtualStart: MediaTime
    public let title: String
    public let sourceTitle: String
    public let episodeTitle: String
    public let originalRange: MediaTimeRange
    public let evidenceIDs: [EvidenceID]

    public init(virtualStart: MediaTime, title: String, sourceTitle: String,
                episodeTitle: String, originalRange: MediaTimeRange, evidenceIDs: [EvidenceID]) {
        self.virtualStart = virtualStart; self.title = title; self.sourceTitle = sourceTitle
        self.episodeTitle = episodeTitle; self.originalRange = originalRange
        self.evidenceIDs = evidenceIDs
    }
}

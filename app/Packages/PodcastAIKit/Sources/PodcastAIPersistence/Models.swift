//
//  Models.swift
//  PodcastAIPersistence
//
//  SwiftData-Modelle. Sie spiegeln die Domänentypen, sind aber bewusst
//  getrennt von ihnen:
//
//  - Domänentypen sind `Sendable` Wertetypen und wandern frei zwischen
//    Actors. SwiftData-Modelle dürfen das nicht — ein `@Model` gehört seinem
//    `ModelContext` und darf keine Actor-Grenze überqueren.
//  - Die Domäne soll ohne Datenbank testbar bleiben. Genau das hat die
//    Verifikation der Kernlogik überhaupt erst möglich gemacht.
//
//  Umgerechnet wird an genau einer Stelle: in den `snapshot`-Eigenschaften
//  und den `apply`-Methoden weiter unten.
//

#if canImport(SwiftData)
import Foundation
import SwiftData
import PodcastAICore
import PodcastAIKnowledge
import PodcastAISmartFeeds

@Model
public final class StoredSource {
    #Index<StoredSource>([\.identifier])
    public var identifier: String = ""
    public var kindRaw: String = SourceKind.podcastRSS.rawValue
    public var title: String = ""
    public var author: String?
    public var feedURLString: String?
    public var websiteURLString: String?
    public var artworkURLString: String?
    public var languageCode: String?
    public var isSubscribed: Bool = true
    public var addedAt: Date = Date()
    public var revisionValue: Int = 0

    // Fähigkeiten als einzelne Spalten statt als verschachteltes Objekt:
    // sie werden gefiltert und angezeigt, nicht nur gelesen.
    public var canDownloadAudio: Bool = false
    public var hasPublisherTranscript: Bool = false
    public var embeddedPlayerOnly: Bool = false
    public var hasHistoricalCatalog: Bool = false
    public var limitationReason: String?

    // Metadaten aus dem Feed, seit 0.9. Optional oder mit Standardwert,
    // damit das Schema für CloudKit nur ergänzt wird.
    public var summary: String?
    public var categories: [String] = []
    public var isExplicit: Bool?

    /// `.nullify` statt `.cascade`: Löscht ein anderes Gerät beim Bereinigen
    /// von Doppelten diese Zeile, bevor hier die umgehängten Folgen angekommen
    /// sind, verlieren die Folgen nur ihre Quelle und nicht ihre Daten. Beim
    /// Abbestellen löscht ``LibraryStore/removeSource(_:)`` die Folgen selbst.
    /// Die Löschregel gehört nicht zum Versions-Hash des Modells, der Wechsel
    /// braucht also keine Migration und ändert das CloudKit-Schema nicht.
    @Relationship(deleteRule: .nullify, inverse: \StoredEpisode.source)
    public var episodes: [StoredEpisode]? = []

    public init(identifier: String, kind: SourceKind, title: String) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.title = title
    }

    public var snapshot: Source {
        Source(
            id: SourceID(rawValue: identifier),
            kind: SourceKind(rawValue: kindRaw) ?? .podcastRSS,
            title: title, author: author,
            feedURL: feedURLString.flatMap(URL.init(string:)),
            websiteURL: websiteURLString.flatMap(URL.init(string:)),
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            capabilities: SourceCapabilities(
                metadata: true, audioDownload: canDownloadAudio,
                publisherTranscript: hasPublisherTranscript,
                embeddedPlayerOnly: embeddedPlayerOnly,
                historicalCatalog: hasHistoricalCatalog,
                limitationReason: limitationReason
            ),
            language: languageCode,
            summary: summary,
            categories: categories.isEmpty ? nil : categories,
            isExplicit: isExplicit,
            isSubscribed: isSubscribed,
            addedAt: addedAt,
            revision: Revision(revisionValue)
        )
    }
}

@Model
public final class StoredEpisode {
    #Index<StoredEpisode>([\.identifier], [\.publishedAt])
    public var identifier: String = ""
    public var title: String = ""
    public var summary: String?
    public var publishedAt: Date?
    public var declaredDurationMs: Int = 0
    public var webPageURLString: String?
    public var audioURLString: String?
    public var timedTranscriptURLString: String?
    public var artworkURLString: String?
    public var currentMediaVersionIdentifier: String?
    public var revisionValue: Int = 0
    public var chaptersData: Data?
    public var chaptersURLString: String?
    public var shownotesHTML: String?
    /// Gesetzt, wenn jemand die Folge gelöscht hat. Die Zeile bleibt als
    /// Merkzeichen stehen, damit der nächste Abgleich mit dem Feed sie nicht
    /// wieder anlegt. Alles, was aus ihr entstanden ist, ist dann gelöscht.
    public var removedAt: Date?

    // Metadaten aus dem Feed, seit 0.9, alle optional oder mit Standardwert.
    public var author: String?
    public var episodeNumber: Int?
    public var season: Int?
    public var episodeType: String?
    public var keywords: [String] = []

    public var source: StoredSource?

    /// `.nullify` aus demselben Grund wie bei ``StoredSource/episodes``.
    /// Eine Fassung ohne Folge bleibt über ihre Kennung auffindbar und wird
    /// beim nächsten Bereinigen wieder angehängt.
    @Relationship(deleteRule: .nullify, inverse: \StoredMediaVersion.episode)
    public var mediaVersions: [StoredMediaVersion]? = []

    public init(identifier: String, title: String) {
        self.identifier = identifier
        self.title = title
    }

    public var snapshot: Episode {
        Episode(
            id: EpisodeID(rawValue: identifier),
            sourceID: SourceID(rawValue: source?.identifier ?? ""),
            title: title, summary: summary, publishedAt: publishedAt,
            declaredDuration: declaredDurationMs > 0
                ? MediaDuration(milliseconds: Int64(declaredDurationMs)) : nil,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            webPageURL: webPageURLString.flatMap(URL.init(string:)),
            audioURL: audioURLString.flatMap(URL.init(string:)),
            timedTranscriptURL: timedTranscriptURLString.flatMap(URL.init(string:)),
            publisherChapters: chaptersData.flatMap { try? JSONDecoder().decode([Chapter].self, from: $0) } ?? [],
            chaptersURL: chaptersURLString.flatMap(URL.init(string:)),
            shownotesHTML: shownotesHTML,
            currentMediaVersionID: currentMediaVersionIdentifier.map(MediaVersionID.init(rawValue:)),
            revision: Revision(revisionValue),
            author: author, episodeNumber: episodeNumber, season: season,
            episodeType: episodeType, keywords: keywords.isEmpty ? nil : keywords
        )
    }
}

@Model
public final class StoredMediaVersion {
    public var identifier: String = ""
    public var remoteURLString: String?
    public var localRelativePath: String?
    public var byteCount: Int = 0
    /// SHA-256 der vollständigen Datei. Solange leer, ist die Identität
    /// vorläufig und Analyseergebnisse sind nicht endgültig.
    public var contentHash: String?
    public var durationMs: Int = 0
    public var mimeType: String?
    public var acquiredAt: Date = Date()
    public var supportsExactSeeking: Bool = true

    public var episode: StoredEpisode?

    /// `.nullify` aus demselben Grund wie bei ``StoredSource/episodes``.
    /// Beim Löschen einer Folge entfernt der Store die Transkripte selbst.
    @Relationship(deleteRule: .nullify, inverse: \StoredTranscript.mediaVersion)
    public var transcripts: [StoredTranscript]? = []

    public init(identifier: String) { self.identifier = identifier }

    public var snapshot: MediaVersion {
        MediaVersion(
            id: MediaVersionID(rawValue: identifier),
            episodeID: EpisodeID(rawValue: episode?.identifier ?? ""),
            remoteURL: remoteURLString.flatMap(URL.init(string:)),
            localRelativePath: localRelativePath,
            byteCount: byteCount > 0 ? Int64(byteCount) : nil,
            contentHash: contentHash,
            duration: durationMs > 0 ? MediaDuration(milliseconds: Int64(durationMs)) : nil,
            mimeType: mimeType, acquiredAt: acquiredAt,
            supportsExactSeeking: supportsExactSeeking
        )
    }
}

@Model
public final class StoredTranscript {
    public var identifier: String = ""
    public var revisionValue: Int = 0
    public var originRaw: String = TranscriptOrigin.speechAnalysis.rawValue
    public var locale: String = "de_DE"
    public var createdAt: Date = Date()
    /// Analysierte Bereiche als Millisekundenpaare. Flach gespeichert, damit
    /// SwiftData sie ohne eigenen Objekttyp mitführen kann.
    public var analyzedRangesFlat: [Int] = []
    public var untimedText: String?

    public var mediaVersion: StoredMediaVersion?

    @Relationship(deleteRule: .cascade, inverse: \StoredSegment.transcript)
    public var segments: [StoredSegment]? = []

    public init(identifier: String) { self.identifier = identifier }

    public var snapshot: Transcript {
        Transcript(
            id: TranscriptID(rawValue: identifier),
            mediaVersionID: MediaVersionID(rawValue: mediaVersion?.identifier ?? ""),
            revision: Revision(revisionValue),
            origin: TranscriptOrigin(rawValue: originRaw) ?? .speechAnalysis,
            locale: locale,
            segments: Self.uniqueSegments(segments ?? []).map(\.snapshot),
            untimedText: untimedText,
            analyzedRanges: IntervalSet(Self.ranges(from: analyzedRangesFlat)),
            createdAt: createdAt
        )
    }

    /// Segmente nach Zeit, jede Kennung einmal. Doppelte bleiben stehen,
    /// wenn sich beim Bereinigen keine Kopie eindeutig vorziehen ließ.
    static func uniqueSegments(_ segments: [StoredSegment]) -> [StoredSegment] {
        var seen: Set<String> = []
        return segments
            .sorted { ($0.startMs, $0.endMs, $0.identifier) < ($1.startMs, $1.endMs, $1.identifier) }
            .filter { seen.insert($0.identifier).inserted }
    }

    static func ranges(from flat: [Int]) -> [MediaTimeRange] {
        stride(from: 0, to: flat.count - 1, by: 2).map { index in
            MediaTimeRange(start: MediaTime(milliseconds: Int64(flat[index])),
                           end: MediaTime(milliseconds: Int64(flat[index + 1])))
        }
    }

    static func flat(from set: IntervalSet) -> [Int] {
        set.ranges.flatMap { [Int($0.start.milliseconds), Int($0.end.milliseconds)] }
    }
}

@Model
public final class StoredSegment {
    #Index<StoredSegment>([\.startMs])
    public var identifier: String = ""
    public var startMs: Int = 0
    public var endMs: Int = 0
    public var text: String = ""
    public var speakerLabel: String?

    public var transcript: StoredTranscript?

    public init(identifier: String, startMs: Int, endMs: Int, text: String) {
        self.identifier = identifier
        self.startMs = startMs; self.endMs = endMs; self.text = text
    }

    public var snapshot: TranscriptSegment {
        TranscriptSegment(
            id: SegmentID(rawValue: identifier),
            range: MediaTimeRange(start: MediaTime(milliseconds: Int64(startMs)),
                                  end: MediaTime(milliseconds: Int64(endMs))),
            text: text, speakerLabel: speakerLabel
        )
    }
}

/// Der Hörzustand einer Medienfassung auf einem Gerät.
///
/// Ein Datensatz je Fassung und Gerät mit den vereinigten Intervallen,
/// nicht eine Ereignisliste. Die Vereinigung ist die Wahrheit; einzelne
/// Ereignisse aufzubewahren würde den Datensatz unbegrenzt wachsen lassen
/// und beim Zusammenführen zweier Geräte nichts hinzufügen, denn die
/// Operation ist idempotent.
///
/// Je Gerät, weil CloudKit bei zwei Änderungen an derselben Zeile die
/// letzte gewinnen lässt. Die Intervalle stehen in einem einzigen Feld, und
/// was ein Gerät gehört hatte, wäre mit dem Schreiben des anderen weg. So
/// hat jede Zeile genau einen Schreiber. ``LibraryStore/ledger()``
/// vereinigt beim Lesen alle Zeilen einer Fassung.
///
/// Das Gerät steckt im Schlüssel, `"<Fassung>#<Gerät>"` in
/// `mediaVersionIdentifier`. Ein eigenes Feld ginge nicht: Das CloudKit-Schema
/// ist ausgeliefert und bleibt, wie es ist. Zeilen im alten Format tragen nur
/// die Fassung. Sie werden weiter gelesen, aber nicht mehr beschrieben.
///
/// Gelöscht wird beim Bereinigen keine dieser Zeilen: Ohne ein
/// unveränderliches Merkmal könnte jedes Gerät die Zeile des anderen
/// löschen, und nach dem nächsten Abgleich wären beide weg.
@Model
public final class StoredListeningState {
    public var mediaVersionIdentifier: String = ""
    public var heardFlat: [Int] = []
    public var skippedFlat: [Int] = []
    public var historyQualityRaw: String = HistoryQuality.exact.rawValue
    public var resumePositionMs: Int = 0
    /// Wann die Fortsetzungsstelle zuletzt gesetzt wurde, also das letzte
    /// Hören der ganzen Folge. Siehe ``MediaListeningState/lastEventAt``.
    public var lastEventAt: Date?

    public init(mediaVersionIdentifier: String) {
        self.mediaVersionIdentifier = mediaVersionIdentifier
    }

    /// Trennt Fassung und Gerät im Schlüssel. Kennungen von Fassungen
    /// bestehen aus Hexzeichen, ein `#` kommt darin nie vor.
    static let deviceSeparator: Character = "#"

    /// Der Schlüssel der Zeile, die ein Gerät für eine Fassung schreibt.
    /// Ohne Gerät bleibt es beim alten Format.
    static func rowKey(media: String, deviceID: String) -> String {
        deviceID.isEmpty ? media : media + String(deviceSeparator) + deviceID
    }

    /// Die Fassung, ohne das Gerät.
    var mediaKey: String {
        String(mediaVersionIdentifier.prefix { $0 != Self.deviceSeparator })
    }

    /// Der gespeicherte Zustand, so wie er geschrieben wurde.
    ///
    /// Früher wurden die Bereiche hier als neue Ereignisse nachgespielt, mit
    /// dem Zeitpunkt des Ladens und dem Weg der ganzen Folge. Das hatte zwei
    /// Folgen: Jedes spätere echte Ereignis galt als älter, die
    /// Fortsetzungsstelle blieb nach dem ersten Abschnitt stehen. Und ohne
    /// gespeicherte Stelle wurde das Ende eines Chat-Fokus zur Stelle, an der
    /// die ganze Folge weitergehen sollte.
    public var snapshot: MediaListeningState {
        MediaListeningState(
            mediaVersionID: MediaVersionID(rawValue: mediaKey),
            heard: IntervalSet(StoredTranscript.ranges(from: heardFlat)),
            skipped: IntervalSet(StoredTranscript.ranges(from: skippedFlat)),
            quality: HistoryQuality(rawValue: historyQualityRaw) ?? .exact,
            lastEventAt: lastEventAt,
            resumePosition: resumePositionMs > 0
                ? MediaTime(milliseconds: Int64(resumePositionMs)) : nil
        )
    }

    public func apply(_ state: MediaListeningState) {
        heardFlat = StoredTranscript.flat(from: state.heard)
        skippedFlat = StoredTranscript.flat(from: state.skipped)
        historyQualityRaw = state.quality.rawValue
        resumePositionMs = Int(state.resumePosition?.milliseconds ?? 0)
        // Der Zeitpunkt des Hörens, nicht der des Schreibens. Sonst wäre das
        // nächste Ereignis scheinbar älter als der Zustand.
        lastEventAt = state.lastEventAt
    }
}

@Model
public final class StoredInterest {
    public var identifier: String = ""
    public var label: String = ""
    public var kindRaw: String = InterestKind.topic.rawValue
    public var originRaw: String = InterestOrigin.confirmedByUser.rawValue
    public var keywords: [String] = []
    public var expiresAt: Date?
    public var createdAt: Date = Date()

    public init(identifier: String, label: String) {
        self.identifier = identifier; self.label = label
    }

    public var snapshot: Interest {
        Interest(
            id: InterestID(rawValue: identifier), label: label,
            kind: InterestKind(rawValue: kindRaw) ?? .topic,
            origin: InterestOrigin(rawValue: originRaw) ?? .confirmedByUser,
            keywords: keywords, expiresAt: expiresAt, createdAt: createdAt
        )
    }
}

@Model
public final class StoredEvidence {
    public var identifier: String = ""
    public var mediaVersionIdentifier: String = ""
    public var episodeIdentifier: String = ""
    public var sourceIdentifier: String = ""
    public var transcriptIdentifier: String = ""
    public var transcriptRevisionValue: Int = 0
    public var startMs: Int = 0
    public var endMs: Int = 0
    public var hasTiming: Bool = true
    public var quotedText: String = ""
    public var attributedSpeaker: String?

    public init(identifier: String) { self.identifier = identifier }

    public var snapshot: Evidence {
        Evidence(
            id: EvidenceID(rawValue: identifier),
            mediaVersionID: MediaVersionID(rawValue: mediaVersionIdentifier),
            episodeID: EpisodeID(rawValue: episodeIdentifier),
            sourceID: SourceID(rawValue: sourceIdentifier),
            transcriptID: TranscriptID(rawValue: transcriptIdentifier),
            transcriptRevision: Revision(transcriptRevisionValue),
            range: hasTiming
                ? MediaTimeRange(start: MediaTime(milliseconds: Int64(startMs)),
                                 end: MediaTime(milliseconds: Int64(endMs)))
                : nil,
            quotedText: quotedText,
            attributedSpeaker: attributedSpeaker
        )
    }
}

@Model
public final class StoredHighlight {
    public var identifier: String = ""
    public var evidenceIdentifier: String = ""
    public var note: String?
    public var createdAt: Date = Date()
    /// Der vollständige Wert als JSON. Siehe die Begründung bei
    /// ``StoredSmartFeed``.
    @Attribute(.externalStorage) public var payload: Data?

    public init(identifier: String, evidenceIdentifier: String) {
        self.identifier = identifier; self.evidenceIdentifier = evidenceIdentifier
    }
}

// MARK: - Was der Nutzer selbst anlegt

//  Diese vier Typen wurden bisher **nur im Speicher** gehalten. Jeder
//  Themenfeed, jede persönliche Ausgabe, jeder gemerkte Gedanke und jede
//  geparkte Frage war beim nächsten App-Start weg. Das betraf ausgerechnet
//  das, was der Nutzer selbst erzeugt hat — nicht das Nachladbare.
//
//  **Warum JSON und keine zerlegten Tabellen.** Eine persönliche Ausgabe ist
//  ein Baum: Abschnitte, darin Zeitbereiche, Belegverweise, Begründungen,
//  ein Cover. Ihn relational zu zerlegen hiesse, jedes Feld von Hand
//  doppelt zu führen — und ein vergessenes Feld fällt nicht auf, es
//  verschwindet einfach still. Die `Codable`-Ableitung ist bereits die eine
//  Wahrheit über die Form dieser Typen; sie wird hier benutzt statt neben
//  ihr eine zweite zu pflegen.
//
//  Der Preis, ausdrücklich: über Felder **innerhalb** des JSON lässt sich
//  nicht mit `#Predicate` filtern. Deshalb stehen genau die Felder, nach
//  denen tatsächlich gesucht wird, zusätzlich als eigene Spalten daneben.
//  Reicht das eines Tages nicht mehr, ist das der Anlass zu zerlegen — bis
//  dahin wäre es Arbeit ohne Nutzen.

@Model
public final class StoredSmartFeed {
    #Index<StoredSmartFeed>([\.identifier], [\.createdAt])
    public var identifier: String = ""
    /// Zum Sortieren und Anzeigen, ohne das JSON zu lesen.
    public var title: String = ""
    public var createdAt: Date = Date()
    @Attribute(.externalStorage) public var payload: Data = Data()

    public init(identifier: String, title: String, payload: Data) {
        self.identifier = identifier
        self.title = title
        self.payload = payload
    }
}

@Model
public final class StoredPersonalEpisode {
    #Index<StoredPersonalEpisode>([\.identifier], [\.feedIdentifier], [\.publishedAt])
    public var identifier: String = ""
    /// Die Spalte, nach der wirklich gefragt wird: „alle Ausgaben dieses Feeds“.
    public var feedIdentifier: String = ""
    public var publishedAt: Date = Date()
    @Attribute(.externalStorage) public var payload: Data = Data()

    public init(identifier: String, feedIdentifier: String, publishedAt: Date, payload: Data) {
        self.identifier = identifier
        self.feedIdentifier = feedIdentifier
        self.publishedAt = publishedAt
        self.payload = payload
    }
}

@Model
public final class StoredKnowledgeTrail {
    #Index<StoredKnowledgeTrail>([\.identifier], [\.parkedAt])
    public var identifier: String = ""
    public var question: String = ""
    public var parkedAt: Date = Date()
    @Attribute(.externalStorage) public var payload: Data = Data()

    public init(identifier: String, question: String, parkedAt: Date, payload: Data) {
        self.identifier = identifier
        self.question = question
        self.parkedAt = parkedAt
        self.payload = payload
    }
}
// MARK: - Fakten je Folge

/// Eine überprüfbare Aussage aus einer Folge, mit Beleg und Zeitmarke.
///
/// Fakten entstehen aus den Belegen einer erschlossenen Folge. Sie werden
/// gespeichert, damit Chat, Export und die Folgenansicht sie nicht jedes
/// Mal neu vom Modell erfragen müssen, und sie synchronisieren sich mit.
@Model
public final class StoredFact {
    #Index<StoredFact>([\.identifier], [\.episodeIdentifier])
    public var identifier: String = ""
    public var episodeIdentifier: String = ""
    public var sourceIdentifier: String = ""
    public var evidenceIdentifier: String = ""
    public var mediaVersionIdentifier: String = ""
    public var statement: String = ""
    public var startMs: Int = 0
    public var endMs: Int = 0
    public var createdAt: Date = Date()
    /// Welches Modell die Aussage formuliert hat, zur Nachvollziehbarkeit.
    public var modelTier: String = ""

    public init(identifier: String) { self.identifier = identifier }

    public var snapshot: EpisodeFact {
        EpisodeFact(
            id: identifier,
            episodeID: EpisodeID(rawValue: episodeIdentifier),
            sourceID: SourceID(rawValue: sourceIdentifier),
            evidenceID: EvidenceID(rawValue: evidenceIdentifier),
            mediaVersionID: MediaVersionID(rawValue: mediaVersionIdentifier),
            statement: statement,
            range: MediaTimeRange(start: MediaTime(milliseconds: Int64(startMs)),
                                  end: MediaTime(milliseconds: Int64(endMs))),
            modelTier: modelTier
        )
    }
}
#endif

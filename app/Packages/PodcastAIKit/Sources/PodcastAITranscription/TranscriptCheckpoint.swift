//
//  TranscriptCheckpoint.swift
//  PodcastAITranscription
//
//  Zwischenstand eines Transkripts, damit ein abgebrochener Lauf dort
//  weitermacht, wo er stand.
//
//  Der Stand liegt als Datei auf diesem Gerät, nicht in der Datenbank. Ein
//  Transkript in der Datenbank gilt als fertig: es ist unveränderlich, wird
//  per iCloud abgeglichen, und andere Geräte bauen darauf Fakten. Ein halbes
//  Transkript dort sähe überall wie ein ganzes aus. Ohne Apple-Frameworks,
//  damit sich Speichern und Fortsetzen ohne Sprachmodell prüfen lassen.
//

import Foundation
import PodcastAICore

/// Was bis zum letzten Schub eines Laufs erkannt war.
public struct TranscriptCheckpoint: Codable, Equatable, Sendable {

    public let mediaVersionID: MediaVersionID
    public let locale: String
    public let segments: [TranscriptSegment]
    /// Analysierte Bereiche als Millisekundenpaare, dieselbe Form wie
    /// `StoredTranscript.analyzedRangesFlat`.
    public let analyzedRangesFlat: [Int]
    public let savedAt: Date

    public init(
        mediaVersionID: MediaVersionID, locale: String, segments: [TranscriptSegment],
        analyzedThrough: MediaTime, savedAt: Date = Date()
    ) {
        self.mediaVersionID = mediaVersionID
        self.locale = locale
        self.segments = segments
        self.analyzedRangesFlat = analyzedThrough.milliseconds > 0
            ? [0, Int(analyzedThrough.milliseconds)] : []
        self.savedAt = savedAt
    }

    /// Bis wohin der Lauf Audio verarbeitet hatte.
    public var analyzedThrough: MediaTime {
        let ends = stride(from: 1, to: analyzedRangesFlat.count, by: 2).map { analyzedRangesFlat[$0] }
        return MediaTime(milliseconds: Int64(ends.max() ?? 0))
    }
}

/// Legt Zwischenstände als Dateien ab, einen je Fassung.
///
/// Ein Zwischenstand hilft nur für dieselbe Fassung in derselben Sprache.
/// Passt er nicht oder ist er älter als ``maximumAge``, gilt er als nicht da.
public struct TranscriptCheckpointStore: Sendable {

    /// Nach so langer Zeit fängt ein Lauf lieber neu an. Die Datei wurde
    /// inzwischen vielleicht neu geladen, und alte Stände räumt niemand sonst auf.
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for mediaVersionID: MediaVersionID) -> URL {
        // Die Kennung ist ein Hash der Adresse, also ein sicherer Dateiname.
        directory.appendingPathComponent(mediaVersionID.rawValue).appendingPathExtension("json")
    }

    public func save(_ checkpoint: TranscriptCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: fileURL(for: checkpoint.mediaVersionID), options: .atomic)
    }

    /// Der Zwischenstand für diese Fassung und Sprache, falls es einen
    /// brauchbaren gibt.
    public func load(
        mediaVersionID: MediaVersionID, locale: String, now: Date = Date()
    ) -> TranscriptCheckpoint? {
        let url = fileURL(for: mediaVersionID)
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(TranscriptCheckpoint.self, from: data) else {
            return nil
        }
        guard checkpoint.mediaVersionID == mediaVersionID, checkpoint.locale == locale,
              now.timeIntervalSince(checkpoint.savedAt) < Self.maximumAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return checkpoint
    }

    public func remove(_ mediaVersionIDs: [MediaVersionID]) {
        for id in mediaVersionIDs {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    /// Entfernt Zwischenstände, die älter als ``maximumAge`` sind. Einmal je
    /// Start: einen Stand, dessen Folge nie wieder transkribiert wird, etwa
    /// weil ein anderes Gerät das Transkript geschrieben hat, lädt sonst
    /// niemand, und er bliebe für immer liegen.
    public func removeExpired(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let checkpoint = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode(TranscriptCheckpoint.self, from: $0) }
            if checkpoint.map({ now.timeIntervalSince($0.savedAt) >= Self.maximumAge }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Entfernt alle Zwischenstände, etwa für einen frischen UI-Test.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

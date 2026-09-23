//
//  MediaLibrary.swift
//  PodcastAIMedia
//
//  Was auf der Platte liegt — und ein Weg, es wieder loszuwerden.
//
//  Gelöscht wurde bisher nur, wenn ein Download fehlschlug. Es gab keine
//  Übersicht, keinen Löschbefehl und keine Obergrenze über alle Dateien
//  hinweg. Wer zehn Folgen erschloss, hatte mehrere Gigabyte auf dem Gerät
//  und als einzige Möglichkeit, sie loszuwerden: die App löschen.
//
//  **Was hier bewusst nicht steht:** eine Regel, die von selbst aufräumt.
//  Ob eine Audiodatei nach der Analyse noch gebraucht wird, ist eine
//  Produktfrage und keine technische — Belege und Transkript liegen danach
//  in der Datenbank, aber das Nachhören der Originalstelle braucht die
//  Datei. Diese Entscheidung trifft nicht ein Aufräumalgorithmus, den
//  niemand bestellt hat.
//
//  Was Löschen kostet, steht in `Consequence` und wird in der Oberfläche
//  angezeigt, bevor jemand darauf drückt.
//

#if canImport(Foundation)
import Foundation
import PodcastAICore

public struct MediaEntry: Sendable, Identifiable, Hashable {
    public let id: MediaVersionID
    public let byteCount: Int64
    public let modifiedAt: Date

    public init(id: MediaVersionID, byteCount: Int64, modifiedAt: Date) {
        self.id = id
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public actor MediaLibrary {

    /// Der Zwischenort laufender Downloads. Er taucht in der Übersicht
    /// nicht auf — dort liegt nichts, was der Nutzer besitzt —, wird beim
    /// Aufräumen aber mitgenommen: nach einem Absturz bleiben hier Reste
    /// liegen, die niemandem mehr gehören.
    static let stagingName = "incoming"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Alles, was abspielbar herumliegt, neueste zuerst.
    public func entries() -> [MediaEntry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return [] }

        return contents.compactMap { url -> MediaEntry? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard values.isDirectory != true else { return nil }
            return MediaEntry(
                id: MediaVersionID(rawValue: url.lastPathComponent),
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.byteCount }
    }

    /// Reste abgebrochener Downloads. Kosten Platz und gehören niemandem.
    public func stagingBytes() -> Int64 {
        let staging = directory.appendingPathComponent(Self.stagingName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    @discardableResult
    public func removeStaging() -> Int64 {
        let staging = directory.appendingPathComponent(Self.stagingName, isDirectory: true)
        let freed = stagingBytes()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil
        ) {
            for url in contents { try? FileManager.default.removeItem(at: url) }
        }
        return freed
    }

    /// Entfernt eine Medienfassung.
    ///
    /// **Belege und Transkript bleiben.** Was verloren geht, ist das
    /// Nachhören des Originals — und das meldet die Wiedergabe von selbst
    /// als „Medium nicht verfügbar", weil `MediaLocating` die Datei nicht
    /// mehr findet. Kein stiller Fehlschlag.
    @discardableResult
    public func remove(_ id: MediaVersionID) -> Int64 {
        let url = directory.appendingPathComponent(id.rawValue)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        try? FileManager.default.removeItem(at: url)
        return size
    }

    @discardableResult
    public func removeAll() -> Int64 {
        var freed: Int64 = 0
        for entry in entries() { freed += remove(entry.id) }
        freed += removeStaging()
        return freed
    }

    /// Was ein Löschen tatsächlich bedeutet — zum Anzeigen, bevor gelöscht wird.
    public enum Consequence {
        public static let summary =
            "Notizen, Belege und der Hörzustand bleiben erhalten. Verloren geht "
            + "nur die Audiodatei: die Stelle lässt sich danach nicht mehr "
            + "nachhören, bis die Folge erneut erschlossen wird."
    }
}

public extension Int64 {
    /// Bytes als lesbare Größe. Eigene Formatierung statt `ByteCountFormatter`,
    /// damit die Angabe in Referenzmodellen prüfbar bleibt.
    var readableByteSize: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, self))
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}
#endif

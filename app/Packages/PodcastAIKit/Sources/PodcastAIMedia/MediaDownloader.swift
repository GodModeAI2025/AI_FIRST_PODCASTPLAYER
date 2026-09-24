//
//  MediaDownloader.swift
//  PodcastAIMedia
//
//  Lädt eine Medienfassung und stellt ihre Identität fest.
//
//  Die Reihenfolge ist wichtig und bewusst so: erst vollständig in eine
//  temporäre Datei laden, dann prüfen, dann den Hash bilden, und erst zum
//  Schluss atomar an den endgültigen Ort verschieben. Ein abgebrochener
//  Download darf keine halbe Datei hinterlassen, die später wie eine
//  vollständige aussieht — und ein Hash über eine halbe Datei wäre eine
//  falsche Identität, an der anschließend Belege hängen.
//
//  Die Adressprüfung steht nicht mehr hier, sondern in `SafeHTTP`: sie gilt
//  für Feeds und Medien gleichermaßen, und sie greift vor der *ersten*
//  Anfrage, nicht erst bei einer Weiterleitung.
//

#if canImport(Foundation)
import Foundation
import CryptoKit
import PodcastAICore

public struct DownloadResult: Sendable {
    public let localRelativePath: String
    public let byteCount: Int64
    /// SHA-256 der **vollständigen** Datei. Erst damit ist die Identität
    /// der Medienfassung bewiesen.
    public let contentHash: String
    public let duration: MediaDuration?
    public let mimeType: String?
}

public actor MediaDownloader {

    /// Obergrenze je Datei. Eine Podcastfolge über diesem Wert ist kein
    /// normaler Fall mehr und wird gemeldet statt still geladen.
    ///
    /// Die Grenze greift während der Übertragung (siehe `SafeHTTP.save`),
    /// nicht erst am fertigen Ergebnis — ein Server, der endlos sendet,
    /// füllt sonst die Platte, bevor irgendjemand nachsieht.
    public static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let temporaryDirectory: URL
    private let session: URLSession

    public init(directory: URL) {
        let staging = directory.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        self.directory = directory
        self.temporaryDirectory = staging
        self.session = SafeHTTP.makeSession { configuration in
            // Eine Folge darf lange laden; nur der einzelne Leseschritt hat
            // ein kurzes Zeitfenster.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
        }
    }

    /// `progress` meldet geladene und angekündigte Byte, etwa für
    /// „23 von 70 MB“. Abbrechen geht über die umgebende Aufgabe; eine halbe
    /// Datei bleibt dabei nicht liegen.
    ///
    /// Mit `background` lädt die Sitzung des Systems, im WLAN auch weiter,
    /// wenn die App anhält. Ein Abbruch der Aufgabe beendet dann nur das
    /// Warten, nicht die Übertragung (`BackgroundDownloadSession`).
    public func download(
        from url: URL, mediaVersionID: MediaVersionID,
        background: BackgroundDownloadSession? = nil,
        progress: (@Sendable (_ received: Int64, _ expected: Int64?) -> Void)? = nil
    ) async throws -> DownloadResult {

        // Eigener Zwischenort je Fassung: zwei parallele Downloads derselben
        // Quelle überschreiben einander sonst mitten im Schreiben.
        let staging = temporaryDirectory.appendingPathComponent(
            mediaVersionID.rawValue + "." + UUID().uuidString)

        if let background {
            // Die Sitzung legt die geprüfte Datei selbst am endgültigen Ort ab.
            try await background.download(url, mediaVersionID: mediaVersionID, progress: progress)
            guard let stored = existing(mediaVersionID: mediaVersionID) else {
                throw HTTPTransferError.emptyResponse
            }
            return stored
        }
        let saved = try await SafeHTTP.save(
            url, to: staging, using: session, limit: Self.maximumBytes, progress: progress)

        do {
            // Hash über die vollständige Datei, blockweise — die Datei wird
            // nicht als Ganzes in den Speicher geladen.
            let hash = try Self.sha256(of: staging)

            let destination = directory.appendingPathComponent(mediaVersionID.rawValue)
            try? FileManager.default.removeItem(at: destination)
            // Atomar: entweder die Datei ist vollständig da oder gar nicht.
            try FileManager.default.moveItem(at: staging, to: destination)

            let duration = try? AudioFileReader.duration(of: destination)

            return DownloadResult(
                localRelativePath: mediaVersionID.rawValue,
                byteCount: saved.byteCount,
                contentHash: hash,
                duration: duration,
                mimeType: saved.mimeType
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Die schon geladene Datei dieser Fassung, ohne neue Anfrage, etwa nach
    /// „Laden (offline)“ oder einem gescheiterten Transkript. Am endgültigen
    /// Ort liegt nur, was vollständig geladen wurde (siehe oben), deshalb
    /// gilt sie ohne weitere Prüfung als ganz. Liegt nichts da, `nil`.
    public func existing(mediaVersionID: MediaVersionID) -> DownloadResult? {
        let destination = directory.appendingPathComponent(mediaVersionID.rawValue)
        guard let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let bytes = values.fileSize, bytes > 0,
              let hash = try? Self.sha256(of: destination) else { return nil }
        return DownloadResult(
            localRelativePath: mediaVersionID.rawValue,
            byteCount: Int64(bytes),
            contentHash: hash,
            duration: try? AudioFileReader.duration(of: destination),
            mimeType: PlayableAsset.sniffMIMEType(at: destination)
        )
    }

    /// Blockweiser SHA-256. 1 MB je Block: groß genug, dass der Overhead
    /// nicht ins Gewicht fällt, klein genug für ein Telefon.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif

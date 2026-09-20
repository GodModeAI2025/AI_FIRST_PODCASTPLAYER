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

#if canImport(Foundation)
import Foundation
import CryptoKit
import PodcastAICore

public enum DownloadError: Error, LocalizedError {
    case httpStatus(Int)
    case unsupportedScheme(String)
    case redirectToUnsafeHost(String)
    case emptyResponse
    case tooLarge(Int64)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "Der Server hat mit Status \(code) geantwortet."
        case .unsupportedScheme(let scheme): "Adressen vom Typ „\(scheme)“ werden nicht geladen."
        case .redirectToUnsafeHost(let host): "Weiterleitung auf \(host) abgelehnt."
        case .emptyResponse: "Die Antwort war leer."
        case .tooLarge(let bytes): "Die Datei ist zu groß (\(bytes) Bytes)."
        }
    }
}

public struct DownloadResult: Sendable {
    public let localRelativePath: String
    public let byteCount: Int64
    /// SHA-256 der **vollständigen** Datei. Erst damit ist die Identität
    /// der Medienfassung bewiesen.
    public let contentHash: String
    public let duration: MediaDuration?
    public let mimeType: String?
}

public actor MediaDownloader: NSObject {

    /// Obergrenze je Datei. Eine Podcastfolge über diesem Wert ist kein
    /// normaler Fall mehr und wird gemeldet statt still geladen.
    public static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private var session: URLSession!

    public init(directory: URL) {
        self.directory = directory
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: configuration,
                                  delegate: RedirectGuard(), delegateQueue: nil)
    }

    public func download(
        from url: URL, mediaVersionID: MediaVersionID
    ) async throws -> DownloadResult {

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedScheme(url.scheme ?? "unbekannt")
        }

        var request = URLRequest(url: url)
        request.setValue("PodcastAI", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await session.download(for: request)

        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw DownloadError.httpStatus(http.statusCode)
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.emptyResponse
        }
        guard byteCount <= Self.maximumBytes else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.tooLarge(byteCount)
        }

        // Hash über die vollständige Datei, blockweise — die Datei wird nicht
        // als Ganzes in den Speicher geladen.
        let hash = try Self.sha256(of: temporaryURL)

        let destination = directory.appendingPathComponent(mediaVersionID.rawValue)
        try? FileManager.default.removeItem(at: destination)
        // Atomar: entweder die Datei ist vollständig da oder gar nicht.
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let duration = try? AudioFileReader.duration(of: destination)

        return DownloadResult(
            localRelativePath: mediaVersionID.rawValue,
            byteCount: byteCount,
            contentHash: hash,
            duration: duration,
            mimeType: response.mimeType
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

/// Weiterleitungen werden geprüft, nicht blind befolgt.
///
/// Ein Feed kann auf eine Adresse zeigen, die auf etwas ganz anderes
/// weiterleitet. Zwei Dinge werden hier verhindert: ein Wechsel von https
/// auf http, und eine Weiterleitung auf eine lokale oder private Adresse —
/// der Weg, auf dem ein fremder Feed sonst Dienste im eigenen Netz erreicht.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !Self.isLocalOrPrivate(host) else {
            completionHandler(nil)
            return
        }
        // Herabstufung von https auf http nicht mitmachen.
        if task.originalRequest?.url?.scheme?.lowercased() == "https", scheme == "http" {
            completionHandler(nil)
            return
        }
        // Zugangsdaten werden bei einem Hostwechsel nicht weitergereicht.
        var sanitized = request
        if task.originalRequest?.url?.host?.lowercased() != host {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(sanitized)
    }

    /// Lehnt alles ab, was im eigenen Netz oder auf dem Gerät selbst liegt.
    ///
    /// `169.254.169.254` ist nicht willkürlich in der Liste: unter dieser
    /// Adresse liegt bei mehreren Cloud-Anbietern der Metadatendienst mit
    /// Zugangsdaten. `0.0.0.0` fehlt ebenso wenig — es landet auf vielen
    /// Systemen bei localhost.
    static func isLocalOrPrivate(_ host: String) -> Bool {
        var value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") { return true }

        // IPv6 kommt in URLs in eckigen Klammern.
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }

        if value.contains(":") {
            if value == "::1" || value == "::" { return true }
            let first = value.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
            // Unique Local fc00::/7 und Link-Local fe80::/10.
            for prefix in ["fc", "fd", "fe8", "fe9", "fea", "feb"] where first.hasPrefix(prefix) {
                return true
            }
            return false
        }

        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        switch (numbers[0], numbers[1]) {
        case (0, _), (127, _), (10, _): return true
        case (169, 254), (192, 168): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }
}
#endif

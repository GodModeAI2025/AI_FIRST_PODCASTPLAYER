//
//  SafeHTTP.swift
//  PodcastAICore
//
//  Der einzige Weg der App ins Netz.
//
//  Vorher gab es zwei Sessions mit zwei verschiedenen Vorstellungen davon,
//  was erlaubt ist: die Feed-Session hatte gar keinen Delegaten, die
//  Medien-Session prüfte Weiterleitungen, aber nicht die erste Adresse.
//  Beide konnten beliebig viel in den Speicher laden, und beide nahmen
//  Cookies an.
//
//  Hier stehen die vier Regeln an einem Ort, damit sie nicht auseinander
//  driften:
//
//  1. **Vor jeder Anfrage** läuft `NetworkDestination.validate` — auch vor
//     der ersten, nicht nur vor Weiterleitungen.
//  2. **Jede Weiterleitung** wird erneut geprüft, mit derselben Regel.
//  3. **Jede Übertragung hat eine Obergrenze**, und zwar eine, die *während*
//     des Ladens greift, nicht erst danach.
//  4. **Keine Cookies, keine gespeicherten Zugangsdaten.** Ein Podcastfeed
//     braucht keine Sitzung, und was nicht gespeichert wird, kann auch nicht
//     an den nächsten Host mitgehen.
//

import Foundation

public enum HTTPTransferError: Error, LocalizedError, Equatable {
    case rejectedDestination(NetworkDestination.Rejection)
    case rejectedRedirect(NetworkDestination.Rejection)
    case httpStatus(Int)
    case tooLarge(limit: Int64)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .rejectedDestination(let reason):
            "Diese Adresse wird nicht abgerufen: \(reason.errorDescription ?? "unzulässig")"
        case .rejectedRedirect(let reason):
            "Die Weiterleitung wurde abgelehnt: \(reason.errorDescription ?? "unzulässig")"
        case .httpStatus(let code):
            "Der Server hat mit Status \(code) geantwortet."
        case .tooLarge(let limit):
            "Die Antwort überschreitet die Obergrenze von \(limit) Bytes."
        case .emptyResponse:
            "Die Antwort war leer."
        }
    }
}

public enum SafeHTTP {

    /// Obergrenze für Textantworten (Feeds, Transkripte). Ein RSS-Feed mit
    /// über 32 MB ist kein Feed mehr.
    public static let textLimit: Int64 = 32 * 1024 * 1024

    /// Eine Session, die die Regeln oben schon mitbringt.
    ///
    /// Der Delegat gehört zur Session; `URLSession` hält ihn stark bis
    /// `invalidateAndCancel()` oder `finishTasksAndInvalidate()`. Das ist
    /// hier gewollt: die Session lebt so lange wie der Dienst, der sie
    /// besitzt.
    public static func makeSession(
        configure: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.allowsCellularAccess = true
        configure(configuration)
        return URLSession(configuration: configuration,
                          delegate: RedirectGuard(),
                          delegateQueue: nil)
    }

    /// Baut die Anfrage — und lehnt vorher ab, wenn das Ziel nicht zulässig ist.
    ///
    /// Es gibt bewusst keinen Weg, eine `URLRequest` an dieser Prüfung vorbei
    /// zu bauen und trotzdem `load`/`save` zu benutzen: beide nehmen eine
    /// `URL`, keine fertige Anfrage.
    public static func request(for url: URL) throws -> URLRequest {
        do {
            try NetworkDestination.validate(url)
        } catch {
            throw HTTPTransferError.rejectedDestination(error)
        }
        var request = URLRequest(url: url)
        request.setValue("PodcastAI", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Lädt eine Antwort vollständig in den Speicher — aber nie mehr als `limit`.
    ///
    /// Die Grenze greift an zwei Stellen: an der angekündigten Länge, bevor
    /// ein Byte gelesen wird, und am tatsächlich Gelesenen, falls die
    /// Ankündigung log oder fehlte.
    public static func load(
        _ url: URL, using session: URLSession, limit: Int64 = textLimit,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = try request(for: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (stream, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw HTTPTransferError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > limit {
            throw HTTPTransferError.tooLarge(limit: limit)
        }

        var data = Data()
        data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), 1 << 20))
        var count: Int64 = 0
        for try await byte in stream {
            count += 1
            if count > limit { throw HTTPTransferError.tooLarge(limit: limit) }
            data.append(byte)
        }
        guard !data.isEmpty else { throw HTTPTransferError.emptyResponse }
        return data
    }

    /// Lädt in eine Datei, ohne den Inhalt je vollständig im Speicher zu halten.
    ///
    /// Die Obergrenze bricht die Übertragung ab, statt sie erst zu Ende zu
    /// laden und danach zu verwerfen — sonst wäre die Grenze eine Aussage
    /// über die Festplatte, nicht über die Leitung.
    ///
    /// `bytes(for:)` liefert Byte für Byte; gesammelt wird deshalb in
    /// Blöcken, bevor geschrieben wird. Für Mediendateien ist das die
    /// langsamste Stelle des Downloads und der Preis dafür, die Grenze
    /// *während* der Übertragung durchzusetzen.
    public struct SavedFile: Sendable {
        public let byteCount: Int64
        public let mimeType: String?
    }

    public static func save(
        _ url: URL, to destination: URL, using session: URLSession, limit: Int64
    ) async throws -> SavedFile {
        let request = try request(for: url)
        let (stream, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw HTTPTransferError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > limit {
            throw HTTPTransferError.tooLarge(limit: limit)
        }

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)

        var total: Int64 = 0
        let blockSize = 256 * 1024
        var block = Data()
        block.reserveCapacity(blockSize)

        do {
            for try await byte in stream {
                total += 1
                if total > limit { throw HTTPTransferError.tooLarge(limit: limit) }
                block.append(byte)
                if block.count >= blockSize {
                    try handle.write(contentsOf: block)
                    block.removeAll(keepingCapacity: true)
                }
            }
            if !block.isEmpty { try handle.write(contentsOf: block) }
            try handle.close()
        } catch {
            // Kein halber Download bleibt liegen: was hier entsteht, sähe
            // später wie eine vollständige Medienfassung aus.
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        guard total > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw HTTPTransferError.emptyResponse
        }
        return SavedFile(byteCount: total, mimeType: response.mimeType)
    }
}

/// Weiterleitungen werden geprüft, nicht blind befolgt.
///
/// Dieselbe Regel wie vor der ersten Anfrage — eine Weiterleitung ist nur
/// eine zweite Anfrage, die der Server aussucht. Zusätzlich fällt hier eine
/// Herabstufung von https auf http weg, und Kopfzeilen mit Zugangsdaten
/// überleben keinen Hostwechsel.
public final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, NetworkDestination.isAllowed(url) else {
            completionHandler(nil)
            return
        }
        let original = task.originalRequest?.url
        if original?.scheme?.lowercased() == "https",
           url.scheme?.lowercased() == "http" {
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.httpShouldHandleCookies = false
        if original?.host?.lowercased() != url.host?.lowercased() {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(sanitized)
    }
}

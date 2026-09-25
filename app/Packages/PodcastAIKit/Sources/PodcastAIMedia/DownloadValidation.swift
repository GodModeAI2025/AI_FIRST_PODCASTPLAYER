//
//  DownloadValidation.swift
//  PodcastAIMedia
//
//  Prüft einen Download, der im Hintergrund fertig wurde.
//
//  Eine Sitzung im Hintergrund folgt Weiterleitungen, ohne den Delegaten zu
//  fragen; `RedirectGuard` greift dort nicht. Deshalb wird hinterher
//  geprüft, bevor die Datei irgendwo liegen bleibt: dieselben Regeln wie
//  in `SafeHTTP`, angewandt auf die Adresse, von der der Inhalt am Ende
//  kam. Was durchfällt, wird gelöscht.
//

import Foundation
import PodcastAICore

public enum DownloadValidation {

    public enum Rejection: Error, Equatable, Sendable {
        /// Die letzte Adresse verstößt gegen `NetworkDestination`.
        case destination(NetworkDestination.Rejection)
        /// Am Ende kam der Inhalt ohne Verschlüsselung.
        case insecureFinalScheme
        case status(Int)
        case empty
        case tooLarge(limit: Int64)
        /// Eine Webseite, ein Bild oder Text statt Ton, etwa eine Anmeldeseite.
        case notMedia(String)
    }

    /// Urteilt über einen fertigen Download. `nil` heißt: in Ordnung.
    ///
    /// `sniffedType` kommt aus den ersten Bytes der Datei
    /// (`PlayableAsset.sniffMIMEType`) und zählt mehr als die Angabe des
    /// Servers: viele Hoster schicken Ton als `application/octet-stream`.
    /// Abgelehnt wird nach der Angabe nur, was sicher kein Ton ist und auch
    /// nicht wie Ton beginnt.
    public static func check(
        original: URL?, final: URL?, statusCode: Int?, declaredType: String?,
        sniffedType: String?, byteCount: Int64, limit: Int64
    ) -> Rejection? {
        guard let address = final ?? original else { return .destination(.missingHost) }
        do {
            try NetworkDestination.validate(address)
        } catch {
            return .destination(error)
        }
        // Jede Anfrage geht über https hinaus (`SafeHTTP.secureVariant`). Kam
        // der Inhalt am Ende über http, lag dazwischen eine Herabstufung.
        guard address.scheme?.lowercased() == "https" else { return .insecureFinalScheme }
        if let statusCode, !(200..<300).contains(statusCode) { return .status(statusCode) }
        guard byteCount > 0 else { return .empty }
        guard byteCount <= limit else { return .tooLarge(limit: limit) }
        if sniffedType == nil, let declared = declaredType?.lowercased(), isClearlyNotMedia(declared) {
            return .notMedia(declared)
        }
        return nil
    }

    /// Typen, hinter denen kein Ton steckt.
    static func isClearlyNotMedia(_ type: String) -> Bool {
        type.hasPrefix("text/") || type.hasPrefix("image/")
            || ["application/json", "application/xml", "application/xhtml+xml",
                "application/rss+xml", "application/atom+xml", "application/javascript",
                "application/pdf"].contains(type)
    }

    /// Derselbe Fehler, den ein Download im Vordergrund meldete.
    public static func transferError(for rejection: Rejection) -> HTTPTransferError {
        switch rejection {
        case .destination(let reason): .rejectedRedirect(reason)
        case .insecureFinalScheme: .rejectedRedirect(.unsupportedScheme("http"))
        case .status(let code): .httpStatus(code)
        case .empty: .emptyResponse
        case .tooLarge(let limit): .tooLarge(limit: limit)
        case .notMedia: .notMedia
        }
    }
}

/// Welcher Weg einen Ton lädt.
public enum DownloadRoute: Equatable, Sendable {
    /// Die bisherige Sitzung der App. Endet, wenn die App anhält.
    case foreground
    /// Die Sitzung des Systems, die im Hintergrund weiterlädt, nur im WLAN.
    case background(BackgroundDownloadSession.Mode)

    /// Im WLAN ohne Datenlimit lädt der Hintergrund, sonst der Vordergrund:
    /// über Mobilfunk nur mit Zustimmung und nur, solange die App läuft.
    /// Von selbst Eingereihtes, das im Hintergrund beginnt, darf das System
    /// auf einen günstigen Moment legen. Beginnt es vorn, wartet die
    /// Warteschlange darauf, dann lädt es sofort.
    public static func choose(
        unmeteredWiFi: Bool, automatic: Bool, inForeground: Bool, backgroundAvailable: Bool
    ) -> DownloadRoute {
        guard backgroundAvailable, unmeteredWiFi else { return .foreground }
        return .background(automatic && !inForeground ? .automatic : .manual)
    }

    /// So viele Folgen der Warteschlange lädt die App im Voraus über die
    /// Sitzung des Systems, neben der laufenden.
    public static let lookahead = 3

    /// Welche Folgen der Warteschlange jetzt im Voraus laden: die ersten
    /// `limit`, die laufen dürften und deren Ton noch fehlt, in der
    /// Reihenfolge der Warteschlange. Nur vorn, im WLAN ohne Datenlimit und
    /// nicht pausiert. Im Hintergrund begonnen, legte das System sie auf
    /// einen Moment seiner Wahl.
    public static func lookaheadDownloads<T>(
        _ queue: [T], limit: Int = lookahead, paused: Bool, inForeground: Bool, unmeteredWiFi: Bool,
        needsDownload: (T) -> Bool
    ) -> [T] {
        guard !paused, inForeground, unmeteredWiFi, limit > 0 else { return [] }
        return Array(queue.lazy.filter(needsDownload).prefix(limit))
    }
}

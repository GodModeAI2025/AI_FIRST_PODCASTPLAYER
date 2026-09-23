//
//  NetworkDestination.swift
//  PodcastAICore
//
//  Wohin die App eine Anfrage schicken darf.
//
//  Die vorige Fassung war eine Sperrliste auf Namensebene, tief in
//  `MediaDownloader` vergraben, und sie lief nur im Redirect-Handler — die
//  **erste** Anfrage ging ungeprüft hinaus. Ein Feed konnte damit
//  `http://127.0.0.1:11434/api/tags` als Audiodatei angeben, und die App
//  hätte geladen.
//
//  Zwei Lehren daraus, die hier umgesetzt sind:
//
//  1. **Whitelist statt Sperrliste.** Eine Sperrliste gegen IP-Schreibweisen
//     ist nicht zu gewinnen: `127.1`, `2130706433`, `0x7f000001`,
//     `0177.0.0.1`, `[::ffff:127.0.0.1]` zeigen alle auf localhost und sehen
//     alle anders aus. Ein Podcast-Enclosure hat keinen Grund, überhaupt
//     eine nackte IP zu sein — also wird die Frage gar nicht erst gestellt.
//  2. **Ein Ort, vor jeder Anfrage.** Nicht im Callback einer von zwei
//     Sessions.
//
//  Was das **nicht** löst: DNS-Rebinding. Geprüft wird der Name, verbunden
//  wird zur aufgelösten Adresse, und dazwischen kann sich der Eintrag
//  ändern. Das dagegen abzusichern verlangt eigene Auflösung und Bindung an
//  die geprüfte Adresse. Solange das nicht steht, ist es hier benannt statt
//  als gelöst behauptet.
//

import Foundation

public enum NetworkDestination {

    public enum Rejection: Error, Equatable, LocalizedError {
        case unsupportedScheme(String)
        case missingHost
        case ipLiteral(String)
        case localOrPrivateName(String)
        case unsupportedPort(Int)
        case embeddedCredentials

        public var errorDescription: String? {
            switch self {
            case .unsupportedScheme(let scheme):
                String(localized: "Adressen vom Typ „\(scheme)“ werden nicht abgerufen.", bundle: .module)
            case .missingHost:
                String(localized: "Die Adresse hat keinen Server.", bundle: .module)
            case .ipLiteral(let host):
                String(localized: "Direkte IP-Adressen werden nicht abgerufen (\(host)).", bundle: .module)
            case .localOrPrivateName(let host):
                String(localized: "Adressen im eigenen Netz werden nicht abgerufen (\(host)).", bundle: .module)
            case .unsupportedPort(let port):
                String(localized: "Nur die Standardports sind zugelassen, nicht \(String(port)).", bundle: .module)
            case .embeddedCredentials:
                String(localized: "Adressen mit eingebetteten Zugangsdaten werden nicht abgerufen.", bundle: .module)
            }
        }
    }

    /// Prüft eine Zieladresse. Wirft mit Grund, statt still `false` zu liefern —
    /// der Grund geht in die Oberfläche.
    public static func validate(_ url: URL) throws(Rejection) {
        guard let scheme = url.scheme?.lowercased() else {
            throw .unsupportedScheme(String(localized: "keines", bundle: .module))
        }
        guard scheme == "http" || scheme == "https" else {
            throw .unsupportedScheme(scheme)
        }
        // `file:` fällt damit weg — und mit ihm der Weg, eigene App-Daten
        // als Feed einzulesen.
        guard url.user == nil, url.password == nil else {
            throw .embeddedCredentials
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw .missingHost
        }
        if let port = url.port, port != 80, port != 443 {
            throw .unsupportedPort(port)
        }
        if looksLikeIPLiteral(host) {
            throw .ipLiteral(host)
        }
        if isLocalName(host) {
            throw .localOrPrivateName(host)
        }
    }

    public static func isAllowed(_ url: URL) -> Bool {
        do { try validate(url); return true } catch { return false }
    }

    // MARK: - Erkennung

    /// Sieht der Host wie eine IP-Adresse aus — in **irgendeiner** Schreibweise?
    ///
    /// Bewusst großzügig: im Zweifel ablehnen. Ein echter Podcast-Host hat
    /// Buchstaben und einen Punkt; alles, was nur aus Ziffern, Punkten,
    /// Hex-Präfix oder Doppelpunkten besteht, ist keiner.
    public static func looksLikeIPLiteral(_ host: String) -> Bool {
        var value = host
        // IPv6 steht in URLs in eckigen Klammern.
        if value.hasPrefix("["), value.hasSuffix("]") { return true }
        if value.contains(":") { return true }

        // Abschließenden Punkt entfernen: `example.com.` und `127.0.0.1.`
        // sind beide gültig und beide gleichbedeutend mit der Form ohne.
        if value.hasSuffix(".") { value.removeLast() }

        // Dezimal, oktal oder hexadezimal — `2130706433`, `0177.0.0.1`,
        // `0x7f000001`, `127.1` sind alle localhost.
        let withoutSeparators = value.replacingOccurrences(of: ".", with: "")
        if withoutSeparators.isEmpty { return false }
        if withoutSeparators.allSatisfy(\.isNumber) { return true }
        if value.lowercased().hasPrefix("0x"),
           withoutSeparators.dropFirst(2).allSatisfy(\.isHexDigit) { return true }
        return false
    }

    /// Namen, die auf das eigene Gerät oder das eigene Netz zeigen.
    public static func isLocalName(_ host: String) -> Bool {
        var value = host
        if value.hasSuffix(".") { value.removeLast() }

        if value == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".home", ".lan", ".intranet"]
        where value.hasSuffix(suffix) {
            return true
        }
        // Ein Name ohne Punkt ist ein Name aus dem lokalen Suchpfad —
        // `nas`, `router`, `printer`. Kein Podcast liegt dort.
        return !value.contains(".")
    }
}

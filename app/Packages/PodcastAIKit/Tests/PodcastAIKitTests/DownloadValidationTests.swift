//
//  DownloadValidationTests.swift
//  PodcastAIKitTests
//
//  Downloads im Hintergrund: die Prüfung nach dem Laden und die Wahl
//  zwischen Vorder- und Hintergrund.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIMedia

private let original = URL(string: "https://cdn.example.com/folge.mp3")!
private let limit: Int64 = 2 * 1024 * 1024 * 1024

private func check(
    final: URL? = URL(string: "https://media.example.org/folge.mp3"), status: Int? = 200,
    declared: String? = "audio/mpeg", sniffed: String? = "audio/mpeg", bytes: Int64 = 50_000_000
) -> DownloadValidation.Rejection? {
    DownloadValidation.check(original: original, final: final, statusCode: status, declaredType: declared,
                             sniffedType: sniffed, byteCount: bytes, limit: limit)
}

@Suite("Download im Hintergrund prüfen")
struct DownloadValidationTests {

    @Test("Eine Audiodatei über eine erlaubte Weiterleitung geht durch")
    func acceptsAudioAfterRedirect() {
        #expect(check() == nil)
    }

    @Test("Hoster, die Ton als octet-stream schicken, gehen durch")
    func acceptsOctetStream() {
        #expect(check(declared: "application/octet-stream", sniffed: "audio/mp4") == nil)
        #expect(check(declared: "application/octet-stream", sniffed: nil) == nil)
        #expect(check(declared: nil, sniffed: nil) == nil)
    }

    @Test("Eine Weiterleitung ins eigene Netz oder auf eine IP-Adresse fällt durch")
    func rejectsForbiddenFinalHost() {
        #expect(check(final: URL(string: "https://192.168.0.10/folge.mp3")) == .destination(.ipLiteral("192.168.0.10")))
        if case .destination? = check(final: URL(string: "https://router.local/folge.mp3")) {} else {
            Issue.record("Ein lokaler Name wurde nicht abgelehnt")
        }
        if case .destination? = check(final: URL(string: "https://nutzer:geheim@cdn.example.com/folge.mp3")) {} else {
            Issue.record("Zugangsdaten in der Adresse wurden nicht abgelehnt")
        }
    }

    @Test("Eine Herabstufung auf http fällt durch")
    func rejectsDowngrade() {
        #expect(check(final: URL(string: "http://cdn.example.com/folge.mp3")) == .insecureFinalScheme)
    }

    @Test("Ohne letzte Adresse gilt die erste")
    func fallsBackToOriginal() {
        #expect(check(final: nil) == nil)
    }

    @Test("Fehlerstatus, leere und zu große Dateien fallen durch")
    func rejectsStatusSizeAndEmpty() {
        #expect(check(status: 404) == .status(404))
        #expect(check(status: 503) == .status(503))
        #expect(check(bytes: 0) == .empty)
        #expect(check(bytes: limit + 1) == .tooLarge(limit: limit))
        #expect(check(bytes: limit) == nil)
    }

    @Test("Eine Webseite statt Ton fällt durch, außer sie beginnt wie Ton")
    func rejectsPagesInsteadOfAudio() {
        #expect(check(declared: "text/html", sniffed: nil) == .notMedia("text/html"))
        #expect(check(declared: "application/json", sniffed: nil) == .notMedia("application/json"))
        #expect(check(declared: "image/jpeg", sniffed: nil) == .notMedia("image/jpeg"))
        // Falsch deklariert, aber die Datei beginnt mit einem MP3-Kopf.
        #expect(check(declared: "text/plain", sniffed: "audio/mpeg") == nil)
    }

    @Test("Jede Ablehnung wird zum selben Fehler wie im Vordergrund")
    func mapsToTransferErrors() {
        #expect(DownloadValidation.transferError(for: .status(404)) == .httpStatus(404))
        #expect(DownloadValidation.transferError(for: .empty) == .emptyResponse)
        #expect(DownloadValidation.transferError(for: .tooLarge(limit: 5)) == .tooLarge(limit: 5))
        #expect(DownloadValidation.transferError(for: .notMedia("text/html")) == .notMedia)
        #expect(DownloadValidation.transferError(for: .insecureFinalScheme)
                == .rejectedRedirect(.unsupportedScheme("http")))
    }
}

@Suite("Weg eines Downloads")
struct DownloadRouteTests {

    @Test("Im WLAN lädt der Hintergrund, sonst der Vordergrund")
    func wifiUsesBackground() {
        #expect(DownloadRoute.choose(unmeteredWiFi: true, automatic: false, inForeground: true,
                                     backgroundAvailable: true) == .background(.manual))
        #expect(DownloadRoute.choose(unmeteredWiFi: false, automatic: false, inForeground: true,
                                     backgroundAvailable: true) == .foreground)
        #expect(DownloadRoute.choose(unmeteredWiFi: false, automatic: true, inForeground: false,
                                     backgroundAvailable: true) == .foreground)
    }

    @Test("Ohne Sitzung im Hintergrund, etwa auf dem Mac, bleibt es beim Vordergrund")
    func withoutBackgroundSession() {
        #expect(DownloadRoute.choose(unmeteredWiFi: true, automatic: true, inForeground: false,
                                     backgroundAvailable: false) == .foreground)
    }

    @Test("Von selbst Eingereihtes wartet nur im Hintergrund auf den Moment des Systems")
    func automaticIsDiscretionaryOnlyInBackground() {
        #expect(DownloadRoute.choose(unmeteredWiFi: true, automatic: true, inForeground: false,
                                     backgroundAvailable: true) == .background(.automatic))
        // Vorn wartet die Warteschlange auf den Download; er soll gleich laden.
        #expect(DownloadRoute.choose(unmeteredWiFi: true, automatic: true, inForeground: true,
                                     backgroundAvailable: true) == .background(.manual))
    }

    @Test("Beide Sitzungen laden sofort, nur im WLAN ohne Datenlimit, und wecken die App")
    func sessionsAreNotDiscretionary() {
        for mode in [BackgroundDownloadSession.Mode.manual, .automatic] {
            let configuration = BackgroundDownloadSession.configuration(for: mode)
            // Zurückhaltend durfte das System den Ton bis zum nächsten Laden am Strom verschieben.
            #expect(configuration.isDiscretionary == false)
            #expect(configuration.sessionSendsLaunchEvents)
            #expect(!configuration.allowsCellularAccess)
            #expect(!configuration.allowsExpensiveNetworkAccess)
            #expect(!configuration.allowsConstrainedNetworkAccess)
            // Dieselbe Kennung nach jedem Start, sonst fänden sich laufende Übertragungen nicht wieder.
            #expect(configuration.identifier == BackgroundDownloadSession.identifier(for: mode))
        }
        #expect(BackgroundDownloadSession.identifier(for: .manual) == "com.godmodeai.podcastai.downloads.manual")
    }

    @Test("Im Voraus laden: die nächsten, die laufen dürften und keinen Ton haben, nur vorn im WLAN")
    func lookahead() {
        let queue = Array(1...10)
        let needs: (Int) -> Bool = { $0 != 2 && $0 != 5 }
        #expect(DownloadRoute.lookaheadDownloads(queue, paused: false, inForeground: true, unmeteredWiFi: true,
                                                 needsDownload: needs) == [1, 3, 4])
        #expect(DownloadRoute.lookaheadDownloads(queue, paused: true, inForeground: true, unmeteredWiFi: true,
                                                 needsDownload: needs).isEmpty)
        #expect(DownloadRoute.lookaheadDownloads(queue, paused: false, inForeground: false, unmeteredWiFi: true,
                                                 needsDownload: needs).isEmpty)
        #expect(DownloadRoute.lookaheadDownloads(queue, paused: false, inForeground: true, unmeteredWiFi: false,
                                                 needsDownload: needs).isEmpty)
    }
}

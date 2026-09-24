//
//  UserFacingError.swift
//  PodcastAI
//
//  Übersetzt technische Fehler in Sätze, mit denen man etwas anfangen kann:
//  was passiert ist und was man jetzt tun kann.
//

import Foundation
import PodcastAIKit

public enum UserFacingError {

    public static func describe(_ error: Error) -> String {
        if let transcription = error as? TranscriptionError {
            switch transcription {
            case .alreadyRunning:
                return String(localized: "Gerade wird schon ein Transkript erstellt. Die Folge ist vorgemerkt und kommt danach dran.")
            case .speechUnavailableOnDevice:
                return transcription.errorDescription ?? ""
            case .localeNotSupported(let locale):
                return String(localized: """
                    Für die Sprache \(locale) hat dieses Gerät kein Sprachmodell. \
                    In den Einstellungen unter Allgemein > Sprache & Region lässt sich die Sprache hinzufügen.
                    """)
            case .modelUnavailable:
                return String(localized: "Das Sprachmodell wird noch geladen. Das Transkript später noch einmal erstellen, am besten im WLAN.")
            case .noCompatibleAudioFormat, .fileUnreadable:
                return String(localized: "Die Audiodatei dieser Folge lässt sich nicht lesen. Das liegt meist an der Datei selbst, nicht an der App.")
            }
        }
        if let http = error as? HTTPTransferError {
            switch http {
            case .httpStatus(404), .httpStatus(410):
                return String(localized: """
                    Der Anbieter meldet diese Adresse als nicht vorhanden (Status 404). \
                    Oft hat sich nur die Adresse geändert. Den Podcast aktualisieren und noch einmal versuchen.
                    """)
            case .httpStatus(let code) where code >= 500:
                return String(localized: "Der Server des Podcasts antwortet gerade nicht (Status \(code)). Später noch einmal versuchen.")
            case .httpStatus(let code):
                return String(localized: "Der Server des Podcasts hat die Anfrage abgelehnt (Status \(code)).")
            case .tooLarge:
                return String(localized: "Die Datei ist größer, als die App lädt. Für sehr lange Folgen lässt sich im Moment kein Transkript erstellen.")
            case .emptyResponse:
                return String(localized: "Der Server hat nichts geliefert. Später noch einmal versuchen.")
            case .notMedia:
                return String(localized: """
                    Der Server hat statt der Audiodatei eine Webseite oder Text geschickt. \
                    Den Podcast aktualisieren und später noch einmal versuchen.
                    """)
            case .rejectedDestination, .rejectedRedirect:
                return http.errorDescription ?? String(localized: "Diese Adresse wird nicht abgerufen.")
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return String(localized: """
                    Keine Internetverbindung. Die Folge bleibt vorgemerkt. \
                    Sobald wieder Netz da ist, das Transkript noch einmal erstellen.
                    """)
            case NSURLErrorTimedOut:
                return String(localized: "Der Download hat zu lange gedauert. Im WLAN noch einmal versuchen.")
            default:
                return String(localized: "Die Folge ließ sich nicht laden: \(nsError.localizedDescription)")
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("recognizer") {
            return String(localized: "Die Spracherkennung war belegt. Die Folge wurde neu eingereiht und startet gleich noch einmal.")
        }
        if text.localizedCaseInsensitiveContains("The operation couldn’t be completed")
            || text.localizedCaseInsensitiveContains("Der Vorgang konnte nicht abgeschlossen werden") {
            // Domäne und Code als fertiger Text, sonst bekäme ein vierstelliger
            // Code einen Tausenderpunkt.
            let code = "\(nsError.domain) \(nsError.code)"
            return String(localized: """
                Beim Erstellen des Transkripts ist etwas schiefgegangen (\(code)). \
                Noch einmal versuchen, bei Wiederholung bitte als Feedback melden.
                """)
        }
        return text
    }

    /// Fehler, bei denen ein zweiter Versuch sinnvoll ist, ohne dass jemand etwas tun muss.
    public static func isTransient(_ error: Error) -> Bool {
        if case TranscriptionError.alreadyRunning? = error as? TranscriptionError { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("recognizer")
    }

    /// Fehler, die bei jedem neuen Versuch wieder kämen: keine Sprache dafür,
    /// kein passendes Audioformat, eine Adresse, die der Server nicht (mehr)
    /// herausgibt. Netzfehler gehören nicht dazu, die vergehen.
    public static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case TranscriptionError.localeNotSupported, TranscriptionError.noCompatibleAudioFormat:
            return true
        case HTTPTransferError.httpStatus(let code):
            // Zu viele Anfragen und Zeitüberschreitung vergehen wieder.
            return (400..<500).contains(code) && code != 408 && code != 429
        case HTTPTransferError.tooLarge, HTTPTransferError.rejectedDestination,
             HTTPTransferError.rejectedRedirect:
            return true
        default:
            return false
        }
    }
}

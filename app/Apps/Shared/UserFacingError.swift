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
                return "Gerade läuft schon eine Erschliessung. Die Folge ist vorgemerkt und kommt danach dran."
            case .speechUnavailableOnDevice:
                return transcription.errorDescription ?? ""
            case .localeNotSupported(let locale):
                return "Für die Sprache \(locale) hat dieses Gerät kein Sprachmodell. "
                    + "In den Einstellungen unter Allgemein > Sprache & Region lässt sich die Sprache hinzufügen."
            case .modelUnavailable:
                return "Das Sprachmodell wird noch geladen. Später noch einmal erschliessen, am besten im WLAN."
            case .noCompatibleAudioFormat, .fileUnreadable:
                return "Die Audiodatei dieser Folge lässt sich nicht lesen. Das liegt meist an der Datei selbst, nicht an der App."
            }
        }
        if let http = error as? HTTPTransferError {
            switch http {
            case .httpStatus(404), .httpStatus(410):
                return "Die Audiodatei gibt es beim Anbieter nicht mehr. Feed aktualisieren und die neue Fassung erschliessen."
            case .httpStatus(let code) where code >= 500:
                return "Der Server des Podcasts antwortet gerade nicht (Status \(code)). Später noch einmal versuchen."
            case .httpStatus(let code):
                return "Der Server des Podcasts hat die Anfrage abgelehnt (Status \(code))."
            case .tooLarge:
                return "Die Datei ist größer, als die App lädt. Sehr lange Folgen lassen sich im Moment nicht erschliessen."
            case .emptyResponse:
                return "Der Server hat nichts geliefert. Später noch einmal versuchen."
            case .rejectedDestination, .rejectedRedirect:
                return http.errorDescription ?? "Diese Adresse wird nicht abgerufen."
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "Keine Internetverbindung. Die Folge bleibt vorgemerkt, sobald das Netz da ist, noch einmal erschliessen."
            case NSURLErrorTimedOut:
                return "Der Download hat zu lange gedauert. Im WLAN noch einmal versuchen."
            default:
                return "Die Folge ließ sich nicht laden: \(nsError.localizedDescription)"
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("recognizer") {
            return "Die Spracherkennung war belegt. Die Folge wurde neu eingereiht und startet gleich noch einmal."
        }
        if text.localizedCaseInsensitiveContains("The operation couldn’t be completed")
            || text.localizedCaseInsensitiveContains("Der Vorgang konnte nicht abgeschlossen werden") {
            return "Beim Erschliessen ist etwas schiefgegangen (\(nsError.domain) \(nsError.code)). Noch einmal versuchen, bei Wiederholung bitte als Feedback melden."
        }
        return text
    }

    /// Fehler, bei denen ein zweiter Versuch sinnvoll ist, ohne dass jemand etwas tun muss.
    public static func isTransient(_ error: Error) -> Bool {
        if case TranscriptionError.alreadyRunning? = error as? TranscriptionError { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("recognizer")
    }
}

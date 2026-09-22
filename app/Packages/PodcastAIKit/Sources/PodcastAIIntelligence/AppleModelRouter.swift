//
//  AppleModelRouter.swift
//  PodcastAIIntelligence
//
//  Nur Apple-Modelle. Kein fremder Anbieter, kein API-Schlüssel, kein
//  heruntergeladenes Drittmodell.
//
//  Fehlende Hardware, abgeschaltete Apple Intelligence, kein PCC-Recht oder
//  ein erschöpftes Kontingent sind **ehrliche Funktionszustände** — und
//  ausdrücklich keine Erlaubnis, auf etwas anderes auszuweichen. Die App
//  sagt dann, was sie nicht kann, statt es heimlich woanders zu holen.
//

import Foundation
import PodcastAICore

/// Wo eine Anfrage verarbeitet werden soll.
public enum ModelTier: String, Sendable, CaseIterable {
    /// Auf dem Gerät. Erste Wahl: nichts verlässt das Gerät.
    case onDevice
    /// Private Cloud Compute. Nur mit tatsächlicher Berechtigung und
    /// ausdrücklicher Einwilligung, für größere Synthesen.
    case privateCloudCompute

    public var label: String {
        switch self {
        case .onDevice: "Auf diesem Gerät"
        case .privateCloudCompute: "Private Cloud Compute"
        }
    }
}

/// Warum eine Stufe nicht zur Verfügung steht. Wird dem Nutzer wörtlich
/// angezeigt — „nicht verfügbar“ ohne Grund ist keine Antwort.
public enum ModelUnavailability: Error, Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case entitlementMissing
    case userConsentMissing
    case quotaExhausted
    case offline
    case unknown(String)

    public var message: String {
        switch self {
        case .deviceNotEligible:
            "Dieses Gerät unterstützt Apple Intelligence nicht."
        case .appleIntelligenceDisabled:
            "Apple Intelligence ist in den Systemeinstellungen nicht aktiviert."
        case .modelNotReady:
            "Das Modell wird noch vorbereitet."
        case .entitlementMissing:
            "Diese App hat keine Berechtigung für Private Cloud Compute."
        case .userConsentMissing:
            "Private Cloud Compute ist noch nicht freigegeben."
        case .quotaExhausted:
            "Das Kontingent für Private Cloud Compute ist aufgebraucht."
        case .offline:
            "Private Cloud Compute braucht eine Internetverbindung."
        case .unknown(let detail):
            "Nicht verfügbar: \(detail)"
        }
    }

    /// Lässt sich der Zustand durch den Nutzer beheben?
    public var isUserActionable: Bool {
        switch self {
        case .appleIntelligenceDisabled, .userConsentMissing, .offline: true
        default: false
        }
    }
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(ModelUnavailability)

    public var isAvailable: Bool { self == .available }
}

/// Was eine Anfrage braucht. Entscheidet über die Stufe — nicht das Modell
/// selbst und nicht der Zufall.
public enum TaskProfile: String, Sendable, CaseIterable {
    /// Aussagen und Belege aus einem einzelnen Abschnitt ziehen.
    /// Kleinteilig, läuft lokal.
    case extract
    /// Eine Frage über einen begrenzten Bestand beantworten.
    case answer
    /// Relevanz gegen das Interessenprofil einschätzen.
    case recommend
    /// Eine Auswahl von Belegen für einen Hörplan vorschlagen.
    case proposePlayback
    /// Mehrere Folgen vergleichen. Braucht viel Kontext.
    case compare

    /// Welche Stufe bevorzugt wird. `compare` profitiert von PCC, funktioniert
    /// lokal aber weiterhin — nur mit kleineren Häppchen.
    public var preferredTier: ModelTier {
        switch self {
        case .extract, .recommend, .proposePlayback: .onDevice
        case .answer, .compare: .privateCloudCompute
        }
    }

    /// Darf lokal ausgeführt werden, wenn die bevorzugte Stufe fehlt?
    public var hasLocalFallback: Bool { true }

    /// Kein Profil bekommt Zugriff auf Player, Schlüsselbund, Dateisystem
    /// oder freies Netzwerk. Diese Liste ist die vollständige Werkzeugmenge.
    public var allowedTools: Set<ModelTool> {
        switch self {
        case .extract: []
        case .answer, .compare: [.searchOwnIndex]
        case .recommend: [.readInterestProfile]
        case .proposePlayback: [.searchOwnIndex]
        }
    }
}

/// Die einzigen Werkzeuge, die ein Modell bekommen kann.
public enum ModelTool: String, Sendable, Hashable {
    /// Suche ausschließlich im eigenen App-Index, innerhalb des Scopes.
    case searchOwnIndex
    /// Lesender Blick auf die bestätigten Interessen.
    case readInterestProfile
}

/// Zustand beider Stufen, wie ihn die Oberfläche anzeigt.
public struct ModelStatus: Sendable, Equatable {
    public let onDevice: ModelAvailability
    public let privateCloudCompute: ModelAvailability

    public init(onDevice: ModelAvailability, privateCloudCompute: ModelAvailability) {
        self.onDevice = onDevice
        self.privateCloudCompute = privateCloudCompute
    }

    public func availability(for tier: ModelTier) -> ModelAvailability {
        switch tier {
        case .onDevice: onDevice
        case .privateCloudCompute: privateCloudCompute
        }
    }

    /// Welche Stufe für ein Profil tatsächlich benutzt wird — oder warum keine.
    public func resolve(_ profile: TaskProfile) -> Result<ModelTier, ModelUnavailability> {
        let preferred = profile.preferredTier
        if case .available = availability(for: preferred) { return .success(preferred) }

        if preferred == .privateCloudCompute, profile.hasLocalFallback,
           case .available = onDevice {
            return .success(.onDevice)
        }
        if case .unavailable(let reason) = availability(for: preferred) {
            return .failure(reason)
        }
        return .failure(.unknown("keine Stufe verfügbar"))
    }
}

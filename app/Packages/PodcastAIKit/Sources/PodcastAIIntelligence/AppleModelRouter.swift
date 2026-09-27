//
//  AppleModelRouter.swift
//  PodcastAIIntelligence
//
//  Nur Apple-Modelle. Kein fremder Anbieter, kein API-Schlüssel, kein
//  heruntergeladenes Drittmodell.
//
//  Seit dem 27. September 2026 (Entscheidung des Product Owners „PCC Cloud
//  für alles“) läuft jede Anfrage zuerst auf Private Cloud Compute. Das
//  Gerätemodell ließ das iPhone stocken, und das System beendete Arbeit im
//  Hintergrund. Es springt nur noch ein, wenn PCC fehlt: ohne Netz, mit
//  erschöpftem Kontingent, ohne Berechtigung oder ohne Freigabe.
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
    /// Auf dem Gerät. Nur noch Ersatz, wenn Private Cloud Compute fehlt.
    case onDevice
    /// Private Cloud Compute. Erste Wahl für jede Anfrage, nur mit
    /// tatsächlicher Berechtigung und eingeschaltetem „Apple-Server nutzen“.
    case privateCloudCompute

    public var label: String {
        switch self {
        case .onDevice: String(localized: "Auf diesem Gerät", bundle: .module)
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
    /// Das Kontingent ist aufgebraucht. `resetDate` sagt, ab wann es wieder
    /// reicht, falls das System es nennt.
    case quotaExhausted(resetDate: Date? = nil)
    case offline
    case unknown(String)

    public var message: String {
        switch self {
        case .deviceNotEligible:
            String(localized: "Dieses Gerät unterstützt Apple Intelligence nicht.", bundle: .module)
        case .appleIntelligenceDisabled:
            String(localized: "Apple Intelligence ist in den Systemeinstellungen nicht aktiviert.", bundle: .module)
        case .modelNotReady:
            String(localized: "Das Modell wird noch vorbereitet.", bundle: .module)
        case .entitlementMissing:
            String(localized: "Diese App hat keine Berechtigung für Private Cloud Compute.", bundle: .module)
        case .userConsentMissing:
            String(localized: "Private Cloud Compute ist noch nicht freigegeben.", bundle: .module)
        case .quotaExhausted:
            String(localized: "Das Kontingent für Private Cloud Compute ist aufgebraucht.", bundle: .module)
        case .offline:
            String(localized: "Private Cloud Compute braucht eine Internetverbindung.", bundle: .module)
        case .unknown(let detail):
            String(localized: "Nicht verfügbar: \(detail)", bundle: .module)
        }
    }

    /// Lässt sich der Zustand durch den Nutzer beheben?
    public var isUserActionable: Bool {
        switch self {
        case .appleIntelligenceDisabled, .userConsentMissing, .offline: true
        default: false
        }
    }

    /// Vergeht der Zustand von selbst? Dann wartet Arbeit im Hintergrund,
    /// statt zu scheitern: das Modell lädt noch, das Netz kommt wieder, das
    /// Kontingent füllt sich auf.
    public var isTemporary: Bool {
        switch self {
        case .modelNotReady, .offline, .quotaExhausted: true
        default: false
        }
    }
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(ModelUnavailability)

    public var isAvailable: Bool { self == .available }
}

/// Was eine Anfrage braucht. Entscheidet über die Werkzeuge, nicht das
/// Modell selbst und nicht der Zufall. Die Stufe ist für alle Profile
/// dieselbe: Private Cloud Compute, das Gerät nur als Ersatz.
public enum TaskProfile: String, Sendable, CaseIterable {
    /// Aussagen und Belege aus einem einzelnen Abschnitt ziehen.
    case extract
    /// Eine Frage über einen begrenzten Bestand beantworten.
    case answer
    /// Relevanz gegen das Interessenprofil einschätzen.
    case recommend
    /// Eine Auswahl von Belegen für einen Hörplan vorschlagen.
    case proposePlayback
    /// Ein Satz je Kapitel, worum es darin geht.
    case summarize
    /// Tags je Kapitel: das Modell wählt Kennungen aus einer Liste, die der
    /// Code gebaut hat. PCC kennt den Anwendungsfall `.contentTagging` nicht,
    /// dort wählt das allgemeine Modell mit demselben Schema.
    case tag

    /// Welche Stufe bevorzugt wird: für jedes Profil Private Cloud Compute
    /// (Entscheidung des Product Owners vom 27. September 2026).
    public var preferredTier: ModelTier { .privateCloudCompute }

    /// Darf das Gerät rechnen, wenn Private Cloud Compute fehlt? Für jedes
    /// Profil ja. Auf dem Gerät passt weniger Text in eine Anfrage, und es
    /// kostet Rechenzeit, aber die App bleibt benutzbar.
    public var hasLocalFallback: Bool { true }

    /// Kein Profil bekommt Zugriff auf Player, Schlüsselbund, Dateisystem
    /// oder freies Netzwerk. Diese Liste ist die vollständige Werkzeugmenge.
    public var allowedTools: Set<ModelTool> {
        switch self {
        case .extract, .summarize, .tag: []
        case .answer: [.searchOwnIndex]
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

    /// Welche Stufe für ein Profil tatsächlich benutzt wird, oder warum keine.
    ///
    /// Private Cloud Compute zuerst, sonst das Gerät. Fehlen beide, nennt
    /// das Ergebnis den Grund, der weiterhilft: Ist Apple Intelligence in den
    /// Systemeinstellungen aus, diesen, denn das Einschalten hilft beiden
    /// Stufen. Fehlt PCC nur vorübergehend (kein Netz, Kontingent erschöpft,
    /// noch nicht bereit), diesen, denn danach geht es weiter. Sonst den des
    /// Geräts.
    public func resolve(_ profile: TaskProfile) -> Result<ModelTier, ModelUnavailability> {
        if case .available = privateCloudCompute { return .success(.privateCloudCompute) }
        if profile.hasLocalFallback, case .available = onDevice { return .success(.onDevice) }
        if onDevice == .unavailable(.appleIntelligenceDisabled) { return .failure(.appleIntelligenceDisabled) }
        if case .unavailable(let cloud) = privateCloudCompute, cloud.isTemporary { return .failure(cloud) }
        if case .unavailable(let device) = onDevice { return .failure(device) }
        if case .unavailable(let cloud) = privateCloudCompute { return .failure(cloud) }
        return .failure(.unknown(String(localized: "keine Stufe verfügbar", bundle: .module)))
    }

    /// Derselbe Zustand ohne Netz: Private Cloud Compute fehlt dann, und das
    /// Gerät springt ein, falls es kann. Ein schon genannter Grund, etwa das
    /// erschöpfte Kontingent, bleibt stehen.
    public func assumingOffline(_ offline: Bool) -> ModelStatus {
        guard offline, case .available = privateCloudCompute else { return self }
        return ModelStatus(onDevice: onDevice, privateCloudCompute: .unavailable(.offline))
    }

    /// Ist Private Cloud Compute gerade wegen des Kontingents gesperrt? Dann
    /// antwortet das Gerät, und die Antwort sagt das in einer Zeile.
    public var privateCloudLimit: PrivateCloudLimit? {
        if case .unavailable(.quotaExhausted(let resetDate)) = privateCloudCompute {
            return .quotaExhausted(resetDate: resetDate)
        }
        return nil
    }
}

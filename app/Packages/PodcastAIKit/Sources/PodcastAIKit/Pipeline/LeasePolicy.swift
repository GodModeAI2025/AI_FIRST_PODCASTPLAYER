//
//  LeasePolicy.swift
//  PodcastAIKit
//
//  Wie die Stufen „Transkript“ und „Wissen“ die Sperre über Geräte hinweg
//  nutzen (`StoredProcessingLease`, `LibraryStore+Leases.swift`):
//
//    1. Vor dem Start, nach der Vorprüfung im Store (Vertrag (I)), nimmt die
//       Stufe die Sperre. Hält ein anderes Gerät eine gültige, wartet die
//       Folge bis zu deren Ablauf in der Warteschlange und läuft nicht.
//    2. Während der Arbeit verlängert die Stufe die Sperre in festen
//       Abständen. Endet die App mitten in der Arbeit, läuft die Sperre ab,
//       und ein anderes Gerät übernimmt.
//    3. Danach gibt sie die Sperre frei. Nur ein Anhalten (Zeit im
//       Hintergrund zu Ende, Pause) lässt sie bis zum Ablauf stehen: Dieses
//       Gerät hat einen Zwischenstand und setzt dort an, wenn es innerhalb
//       der Frist weitermacht.
//
//  Ohne Richtlinie (Tests, UI-Tests im Speicher) sperrt keine Stufe.
//

import Foundation
import PodcastAICore
import PodcastAIPersistence

public struct LeasePolicy: Sendable {
    /// Die Kennung dieses Geräts, dieselbe wie im Hörzustand.
    public var deviceID: String
    /// So lange gilt eine Sperre ohne Verlängerung.
    public var duration: TimeInterval
    /// So oft verlängert die Stufe während der Arbeit.
    public var renewal: Duration

    public static let defaultDuration: TimeInterval = 15 * 60
    public static let defaultRenewal: Duration = .seconds(5 * 60)

    public init(deviceID: String, duration: TimeInterval = LeasePolicy.defaultDuration,
                renewal: Duration = LeasePolicy.defaultRenewal) {
        self.deviceID = deviceID
        self.duration = duration
        self.renewal = renewal
    }

    /// Nimmt die Sperre. Scheitert das Lesen oder Schreiben, gilt sie als
    /// genommen: Ein Fehler der Datenbank soll die Arbeit nicht aufhalten,
    /// und der Wächter prüft beim Schreiben ohnehin.
    func acquire(_ kind: ProcessingLeaseKind, for id: EpisodeID, in store: LibraryStore, now: Date) async
        -> LeaseDecision {
        (try? await store.acquireLease(kind, for: id, device: deviceID, duration: duration, now: now))
            ?? .granted(until: now.addingTimeInterval(duration))
    }

    /// Verlängert die Sperre, bis die Aufgabe abgebrochen wird.
    func heartbeat(_ kind: ProcessingLeaseKind, for id: EpisodeID, in store: LibraryStore,
                   clock: @escaping @Sendable () -> Date) -> Task<Void, Never> {
        let deviceID = deviceID
        let duration = duration
        let renewal = renewal
        return Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: renewal)
                guard !Task.isCancelled else { return }
                _ = try? await store.renewLease(kind, for: id, device: deviceID, duration: duration, now: clock())
            }
        }
    }

    func release(_ kind: ProcessingLeaseKind, for id: EpisodeID, in store: LibraryStore) async {
        try? await store.releaseLease(kind, for: id, device: deviceID)
    }

    /// Wie lange bis `date`, mindestens ein kurzer Moment.
    static func delay(until date: Date, now: Date) -> Duration {
        .milliseconds(max(50, Int((date.timeIntervalSince(now) * 1000).rounded(.up))))
    }
}

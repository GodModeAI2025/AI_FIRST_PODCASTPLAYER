//
//  StoredProcessingLease.swift
//  PodcastAIPersistence
//
//  Eine Sperre über Geräte hinweg, seit dem Schema nach 0.14: Dieses Gerät
//  transkribiert eine Folge oder sammelt ihre Fakten, bis `expiresAt`.
//
//  Bis 0.14 prüften die Stufen nur vor dem Start, ob das Ergebnis schon in
//  der Datenbank steht. Zwei Geräte, die dieselbe neue Folge fast
//  gleichzeitig sahen, transkribierten sie beide. Jetzt schreibt eine Stufe
//  vor dem Start eine Sperre mit Gerät und Ablauf, verlängert sie während
//  der Arbeit und löscht sie danach. Ein anderes Gerät, das eine gültige
//  Sperre sieht, wartet bis zum Ablauf; eine abgelaufene übernimmt es.
//
//  CloudKit kennt kein atomares „nimm, wenn frei“. Schreiben zwei Geräte
//  ihre Sperre, bevor der Abgleich die andere gebracht hat, gilt unter den
//  gültigen die älteste, bei Gleichstand die kleinere Gerätekennung
//  (`LibraryStore+Leases.swift`). Das Fenster wird so klein, ganz schließt
//  es sich nicht. Entsteht doch ein zweites Transkript, trägt es dieselbe
//  Kennung (feste Sprache, `TranscriptID.forMedia`), und das Bereinigen
//  behält eines.
//
//  CloudKit-tauglich: jedes Feld mit Standardwert, keine eindeutigen
//  Schlüssel, keine Beziehungen. Ältere Fassungen der App kennen die Art
//  nicht und arbeiten wie bisher.
//

#if canImport(SwiftData)
import Foundation
import SwiftData

@Model
public final class StoredProcessingLease {
    #Index<StoredProcessingLease>([\.identifier], [\.episodeIdentifier])
    /// „<Kennung der Folge>|<Art>“, siehe `ProcessingLeaseKind`.
    public var identifier: String = ""
    public var episodeIdentifier: String = ""
    /// `ProcessingLeaseKind.rawValue`.
    public var kindRaw: String = ""
    /// Das Gerät, das die Sperre hält (Kennung aus dem Schlüsselbund).
    public var deviceIdentifier: String = ""
    /// Wann dieses Gerät die Sperre genommen hat. Verlängern ändert es nicht.
    public var acquiredAt: Date = Date()
    /// Bis wann sie gilt. Danach darf ein anderes Gerät übernehmen.
    public var expiresAt: Date = Date()

    public init(identifier: String, episodeIdentifier: String, kindRaw: String, deviceIdentifier: String,
                acquiredAt: Date, expiresAt: Date) {
        self.identifier = identifier
        self.episodeIdentifier = episodeIdentifier
        self.kindRaw = kindRaw
        self.deviceIdentifier = deviceIdentifier
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}
#endif

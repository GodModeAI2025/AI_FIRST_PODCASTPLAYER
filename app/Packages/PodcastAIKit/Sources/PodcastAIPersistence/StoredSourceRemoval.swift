//
//  StoredSourceRemoval.swift
//  PodcastAIPersistence
//
//  Das Merkzeichen „Quelle abbestellt“, seit dem Schema nach 0.14.
//
//  Eine gelöschte Folge behält ihre Zeile als Merkzeichen (`removedAt`).
//  Eine abbestellte Quelle verschwand bis 0.14 ganz, und ein anderes Gerät
//  erfuhr davon nur, wenn die Löschung ankam, bevor es selbst etwas an die
//  Quelle schrieb. Kam dort vorher noch ein Transkript, ein Fakt oder eine
//  Änderung an der Quellzeile zustande, blieb das stehen oder brachte die
//  Quelle zurück. Jetzt bleibt je Abbestellung eine kleine Zeile stehen.
//  Jedes Gerät, das sie sieht, geht denselben Weg wie beim Abbestellen
//  (Regel 5) und legt die Quelle nicht wieder an.
//
//  Eine eigene Art statt eines Felds an `StoredSource`: Ältere Fassungen
//  der App kennen sie nicht und sehen die Quelle gelöscht wie bisher. Ein
//  Feld an der Quellzeile hielte die Zeile am Leben, und eine ältere App
//  zeigte die Quelle weiter an.
//
//  CloudKit-tauglich: jedes Feld mit Standardwert oder optional, keine
//  eindeutigen Schlüssel, keine Beziehungen. Mehrere Zeilen je Quelle sind
//  erlaubt, es gilt die jüngste.
//

#if canImport(SwiftData)
import Foundation
import SwiftData

@Model
public final class StoredSourceRemoval {
    #Index<StoredSourceRemoval>([\.sourceIdentifier])
    /// Die Kennung der abbestellten Quelle (`SourceID`).
    public var sourceIdentifier: String = ""
    /// Wann abbestellt wurde. Eine Quellzeile, die danach angelegt wurde
    /// (`StoredSource.addedAt`), ist ein neues Abo und bleibt.
    public var removedAt: Date = Date()
    /// Das Gerät, das abbestellt hat. Nur zur Auskunft.
    public var deviceIdentifier: String?

    public init(sourceIdentifier: String, removedAt: Date, deviceIdentifier: String?) {
        self.sourceIdentifier = sourceIdentifier
        self.removedAt = removedAt
        self.deviceIdentifier = deviceIdentifier
    }
}
#endif

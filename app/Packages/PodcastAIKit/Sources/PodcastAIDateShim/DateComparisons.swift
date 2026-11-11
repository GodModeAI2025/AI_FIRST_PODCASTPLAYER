//
//  DateComparisons.swift
//  PodcastAIDateShim
//
//  Das SDK aus Xcode 27.2 ruft `Date <= Date` und `Date >= Date` ab 27.2
//  direkt im System auf (`@backDeployed(before: 27.2)`). Den Betas von 27.2
//  vor der fertigen Fassung fehlen diese beiden Funktionen in Foundation,
//  sie melden sich aber schon als 27.2. Dort stürzt jede App beim ersten
//  solchen Vergleich ab. Mit den beiden Funktionen hier bindet der Linker
//  die Aufrufe an die eigene Fassung, auf jedem System.
//
//  shortcut: hängt an den Symbolnamen aus Foundation; löschen, sobald
//  niemand mehr eine Beta von 27.2 benutzt.
//

import Foundation

@_silgen_name("$s10Foundation4DateV2geoiySbAC_ACtFZ")
public func dateGreaterOrEqual(_ lhs: Date, _ rhs: Date) -> Bool {
    lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
}

@_silgen_name("$s10Foundation4DateV2leoiySbAC_ACtFZ")
public func dateLessOrEqual(_ lhs: Date, _ rhs: Date) -> Bool {
    lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
}

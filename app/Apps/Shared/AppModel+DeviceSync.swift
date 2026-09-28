//
//  AppModel+DeviceSync.swift
//  PodcastAI
//
//  Was die Schemaänderung nach 0.14 (Entscheidung 11 in
//  docs/plan-pipeline.md, docs/cloudkit-schema-0.15.md) in der App braucht:
//
//    - Pfade der Audiodateien je Gerät in `DeviceState` statt in der
//      Datenbank, mit einem einmaligen Umzug beim ersten Start.
//    - Das Merkzeichen „Quelle abbestellt“: Ein anderes Gerät hat eine
//      Quelle abbestellt, und dieses Gerät geht denselben Weg wie beim
//      eigenen Abbestellen (Regel 5).
//    - Die Sperre über Geräte hinweg für die Stufen „Transkript“ und
//      „Wissen“ (`LeasePolicy`).
//

import Foundation
import PodcastAIKit

extension AppModel {

    /// Die Sperre über Geräte hinweg, mit der Kennung dieses Geräts.
    var leasePolicy: LeasePolicy { LeasePolicy(deviceID: deviceID) }

    /// Sagt dem Store, wo dieses Gerät seine Pfade merkt, und zieht beim
    /// ersten Start nach dem Update die alten Pfade aus der Datenbank um.
    /// Übernommen wird nur, was hier als Datei liegt; das alte Feld bleibt
    /// unberührt, denn auch Leeren ginge über iCloud an alle Geräte.
    func prepareLocalMediaPaths() async {
        let paths = LocalMediaPaths(state: .shared)
        await store.useLocalMediaPaths(paths)
        await paths.migrate(from: store) { LocalMediaLocator.fileExists(relativePath: $0) }
    }

    /// Holt Abbestellungen nach, die ein anderes Gerät per Merkzeichen
    /// gemeldet hat. Derselbe Weg wie „Abbestellen“ hier: Löschprotokoll,
    /// Vermerk für die Pflege, `episodesRemoved` an die Stufen, dann der
    /// Store, danach Dateien, Zwischenspeicher, Unterhaltungen und die
    /// Vermerke dieses Geräts. Ein zweites Merkzeichen entsteht nicht.
    ///
    /// Wiederholt sich beliebig oft: Nach dem Nachholen hält der Store
    /// nichts mehr von der Quelle, und die Liste ist leer.
    func applySourceRemovalsFromElsewhere() async {
        guard let pending = try? await store.sourceRemovalsToApply(), !pending.isEmpty else { return }
        for sourceID in pending {
            await removeSource(sourceID, fromElsewhere: true)
        }
    }
}

//
//  CarPlaySceneDelegate.swift
//  PodcastAI (iOS)
//
//  CarPlay Audio: Abos, Neu, Warteschlange und „Wiedergabe“. Nur Player,
//  ohne jede KI-Funktion der App.
//
//  Der Code ist immer im Build, die Szene meldet sich aber nur an, wenn
//  Entitlement und Szenen-Eintrag gesetzt sind. Beides liegt absichtlich
//  nicht in den Standarddateien (`PodcastAI.entitlements`, `Info.plist`),
//  weil `com.apple.developer.carplay-audio` erst nach Apples Freigabe
//  signiert werden kann. Es steckt in `PodcastAICarPlay.entitlements` und
//  `InfoCarPlay.plist` und wird mit der Build-Einstellung
//  `PODCASTAI_VARIANT: CarPlay` eingeschaltet, siehe
//  docs/plan-player-plattformen.md.
//
//  Regel 1: Die Szene startet keinen Ton. Eine Zeile in einer Liste spielt
//  erst, wenn jemand sie im Auto antippt oder per Siri verlangt.
//

import UIKit
import CarPlay

/// Reicht das Modell der App an die CarPlay-Szene. Die App legt es beim Start
/// an (`PodcastAIApp.init`), die Szene kann später kommen, auch wenn CarPlay
/// die App im Hintergrund startet.
@MainActor
enum CarPlayBridge {
    static var model: AppModel?
}

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            // CarPlay kann die App starten, bevor das Modell steht.
            var waited = 0
            while CarPlayBridge.model == nil, waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard let model = CarPlayBridge.model else { return }
            let controller = CarPlayController(model: model, interfaceController: interfaceController)
            self.controller = controller
            await controller.start()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            self.controller?.stop()
            self.controller = nil
        }
    }
}

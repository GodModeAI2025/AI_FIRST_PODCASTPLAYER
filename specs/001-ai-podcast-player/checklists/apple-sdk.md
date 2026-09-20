# Checkliste — apple-sdk

Status: App-Implementierung und Gerätetests nicht durchgeführt. Alle Punkte bleiben als Freigabearbeit offen.

- [ ] Xcode-/Swift-/SDK-Buildnummern auf Mac erfasst.
- [ ] Vier native Mindesttargets 27.0; keine Legacy-/Catalystpfade.
- [ ] SwiftUI State-Makro/ContentBuilder gegen aktuelle Signaturen geprüft.
- [ ] Foundation Models/PCC Fehler-, Quota- und Context-APIs kompiliert.
- [ ] Speech-Locale-/Asset-/Timingpfad auf Gerät geprüft.
- [ ] PCC-Account und Entitlement nachgewiesen.
- [ ] Watch-PCC-Verfügbarkeit unabhängig vom Modulimport geprüft.
- [ ] Beta-APIs nur bei dokumentierter Freigabe im Release.
- [ ] SwiftData/CKSyncEngine mit echter StateSerialisierung integriert.

## Zusatz 1.3
- [ ] GATE-COVER: kein ImageCreator; unterstützte Image-Playground-Sheet-APIs gegen iOS/iPadOS/macOS 27 kompilieren; Apple-only-Stile und temporäre Dateipersistenz prüfen. Watch zeigt synchronisierte Assets.

//
//  SpotlightIndex.swift
//  PodcastAI
//
//  Erkenntnisse und persönliche Ausgaben in der Systemsuche.
//
//  Der Punkt, an dem hier alles hängt: der **app-interne Index und der
//  Systemindex sind zwei verschiedene Dinge** mit verschiedenen Folgen.
//  Was im app-internen Index liegt, bleibt im Scope der App. Was im
//  Systemindex liegt, ist von aussen auffindbar — von der Systemsuche, von
//  Vorschlägen, unter Umständen von anderen Stellen des Systems.
//
//  Deshalb: standardmässig aus, eigene Einwilligung, und beim Widerruf wird
//  wirklich entfernt statt nur nicht mehr ergänzt.
//
//  Und: PodcastAI stellt Relevanz bereit. Ob das Betriebssystem daraus
//  einen Vorschlag macht, entscheidet das Betriebssystem. Die App verspricht
//  keine Platzierung.
//

import Foundation
import SwiftUI
import PodcastAIKit

#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@MainActor
public final class SpotlightIndex {

    /// Standardmässig aus. Eine Funktion, die Inhalte aus der App heraus
    /// sichtbar macht, schaltet sich nicht selbst ein.
    private let consentKey = "com.podcastai.spotlight.consent"

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: consentKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: consentKey)
            if !newValue { Task { await removeAll() } }
        }
    }

    public init() {}

    #if canImport(CoreSpotlight)

    private static let domain = "com.podcastai.insights"

    /// Meldet gemerkte Stellen an den Systemindex.
    ///
    /// Bewusst nur Highlights und veröffentlichte Ausgaben — also das, was
    /// der Nutzer selbst angelegt hat oder was die App ihm gegenüber schon
    /// als eigenes Objekt darstellt. Rohe Transkripte gehen nicht hinein:
    /// sie sind fremder Inhalt und gehören nicht in einen Systemindex.
    public func index(highlights: [Highlight], evidence: [EvidenceID: Evidence]) async {
        guard isEnabled else { return }

        let items = highlights.compactMap { highlight -> CSSearchableItem? in
            guard let item = evidence[highlight.evidenceID] else { return nil }

            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = highlight.note ?? "Gemerkte Stelle"
            // Der Originaltext, gekürzt. Der Systemindex ist kein Archiv.
            attributes.contentDescription = String(item.quotedText.prefix(300))
            attributes.contentCreationDate = highlight.capturedAt
            if let range = item.range {
                attributes.startTime = NSNumber(value: range.start.seconds)
                attributes.endTime = NSNumber(value: range.end.seconds)
            }
            return CSSearchableItem(
                uniqueIdentifier: highlight.id.rawValue,
                domainIdentifier: Self.domain,
                attributeSet: attributes
            )
        }
        guard !items.isEmpty else { return }
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Entfernt einen einzelnen Eintrag — beim Löschen eines Highlights.
    public func remove(_ id: HighlightID) async {
        try? await CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [id.rawValue])
    }

    /// Entfernt alles. Wird beim Widerruf der Einwilligung aufgerufen.
    ///
    /// Widerruf heisst entfernen, nicht „ab jetzt nichts Neues mehr“ —
    /// sonst bliebe alles Bisherige für immer auffindbar.
    public func removeAll() async {
        try? await CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    }

    #else

    public func index(highlights: [Highlight], evidence: [EvidenceID: Evidence]) async {}
    public func remove(_ id: HighlightID) async {}
    public func removeAll() async {}

    #endif
}

/// Der Einwilligungsschalter, mit der Erklärung daneben.
struct SpotlightSettingsSection: View {

    @Environment(AppModel.self) private var model
    @State private var isEnabled = false

    var body: some View {
        Section {
            Toggle("In der Systemsuche auffindbar", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    model.spotlight.isEnabled = newValue
                    // Einschalten heisst: die vorhandenen Stellen jetzt
                    // melden, nicht erst bei der nächsten Änderung.
                    if newValue { model.reindexSpotlight() }
                }
        } header: {
            Text("Systemsuche")
        } footer: {
            Text("Gemerkte Stellen werden dann auch ausserhalb von PodcastAI gefunden. "
                 + "Ausgeschaltet werden vorhandene Einträge wieder entfernt.\n\n"
                 + "PodcastAI stellt Relevanz bereit — ob das System daraus einen Vorschlag "
                 + "macht, entscheidet das System.")
        }
        .task { isEnabled = model.spotlight.isEnabled }
    }
}

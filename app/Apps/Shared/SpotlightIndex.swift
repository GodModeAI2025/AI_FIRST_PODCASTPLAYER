//
//  SpotlightIndex.swift
//  PodcastAI
//
//  Erkenntnisse und persönliche Ausgaben in der Systemsuche.
//
//  Der Punkt, an dem hier alles hängt: der **app-interne Index und der
//  Systemindex sind zwei verschiedene Dinge** mit verschiedenen Folgen.
//  Was im app-internen Index liegt, bleibt im Scope der App. Was im
//  Systemindex liegt, ist von außen auffindbar — von der Systemsuche, von
//  Vorschlägen, unter Umständen von anderen Stellen des Systems.
//
//  Deshalb: standardmäßig aus, eigene Einwilligung, und beim Widerruf wird
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

#if os(iOS)
import UIKit
#endif

@MainActor
public final class SpotlightIndex {

    /// Standardmäßig aus. Eine Funktion, die Inhalte aus der App heraus
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

    /// Der letzte Lauf gegen den Systemindex. Läufe warten aufeinander,
    /// sonst könnte ein älterer Stand einen neueren überschreiben.
    private var lastRun: Task<Void, Never>?

    /// Meldet gemerkte Stellen an den Systemindex.
    ///
    /// Bewusst nur Highlights und veröffentlichte Ausgaben — also das, was
    /// der Nutzer selbst angelegt hat oder was die App ihm gegenüber schon
    /// als eigenes Objekt darstellt. Rohe Transkripte gehen nicht hinein:
    /// sie sind fremder Inhalt und gehören nicht in einen Systemindex.
    ///
    /// Die Liste ersetzt den bisherigen Stand. Eine gelöschte Stelle
    /// verschwindet so auch aus der Systemsuche, statt dort weiter auf
    /// etwas zu zeigen, das es nicht mehr gibt.
    public func index(highlights: [Highlight], evidence: [EvidenceID: Evidence]) async {
        guard isEnabled else { return }
        let items = highlights.compactMap { Self.item(for: $0, evidence: evidence[$0.evidenceID]) }
        await enqueue { [weak self] in
            let index = CSSearchableIndex.default()
            try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            // Inzwischen widerrufen? Dann bleibt der Index leer.
            guard self?.isEnabled == true, !items.isEmpty else { return }
            try? await index.indexSearchableItems(items)
        }
    }

    /// Ein Eintrag für eine gemerkte Stelle.
    ///
    /// Stellen aus dem Player haben meist keinen gespeicherten Beleg. Dann
    /// trägt der Eintrag die Kopie, die beim Merken mitgesichert wurde:
    /// Zitat, Zeitmarke, Folge. Ohne diesen Weg fand die Systemsuche keine
    /// einzige Stelle, die mit „Moment merken“ entstanden war.
    private static func item(for highlight: Highlight, evidence: Evidence?) -> CSSearchableItem? {
        let quote = evidence?.quotedText ?? highlight.quote
        guard quote != nil || highlight.note != nil else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = highlight.note ?? highlight.episodeTitle ?? String(localized: "Gemerkte Stelle")
        // Der Originaltext, gekürzt. Der Systemindex ist kein Archiv.
        // Die Zeitmarke steht vorn, weil das Attributset keine Start-
        // und Endzeit für Textelemente kennt.
        var parts: [String] = []
        if let range = evidence?.range {
            parts.append("\(range.start.timecode)–\(range.end.timecode)")
            attributes.duration = NSNumber(value: range.end.seconds - range.start.seconds)
        } else if let ms = highlight.positionMs {
            parts.append(MediaTime(milliseconds: Int64(ms)).timecode)
        }
        if let title = highlight.episodeTitle, title != attributes.title { parts.append(title) }
        if let quote { parts.append(String(quote.prefix(300))) }
        attributes.contentDescription = parts.joined(separator: " · ")
        attributes.contentCreationDate = highlight.capturedAt
        return CSSearchableItem(
            uniqueIdentifier: highlight.id.rawValue,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }

    /// Hängt einen Lauf hinter den vorigen und wartet auf ihn.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = lastRun
        let run = Task { @MainActor in
            await previous?.value
            await work()
        }
        lastRun = run
        await run.value
    }

    /// Entfernt einen einzelnen Eintrag — beim Löschen eines Highlights.
    public func remove(_ id: HighlightID) async {
        try? await CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [id.rawValue])
    }

    /// Entfernt alles. Wird beim Widerruf der Einwilligung aufgerufen.
    ///
    /// Widerruf heißt entfernen, nicht „ab jetzt nichts Neues mehr“ —
    /// sonst bliebe alles Bisherige für immer auffindbar.
    public func removeAll() async {
        await enqueue {
            try? await CSSearchableIndex.default()
                .deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }
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
                    // Einschalten heißt: die vorhandenen Stellen jetzt
                    // melden, nicht erst bei der nächsten Änderung.
                    if newValue { model.reindexSpotlight() }
                }
        } header: {
            Text("Systemsuche")
        } footer: {
            Text("""
                Gemerkte Stellen werden dann auch außerhalb von PodcastAI gefunden. \
                Ausgeschaltet werden vorhandene Einträge wieder entfernt.

                PodcastAI stellt Relevanz bereit. Ob das System daraus einen Vorschlag \
                macht, entscheidet das System.
                """)
        }
        .task { isEnabled = model.spotlight.isEnabled }
    }
}

// MARK: - Aus der Systemsuche zurück

/// Öffnet die gemerkte Stelle, die in der Systemsuche angetippt wurde.
///
/// Geöffnet heißt gezeigt, nicht abgespielt. Hören startet erst der Knopf
/// in der Ansicht, also ein eigener Tipp.
private struct SpotlightContinuation: ViewModifier {

    @Environment(AppModel.self) private var model
    @State private var opened: OpenedHighlight?
    #if os(iOS)
    @State private var anchor = PresentationAnchor()
    #endif

    private struct OpenedHighlight: Identifiable {
        let id: HighlightID
    }

    func body(content: Content) -> some View {
        content
            #if canImport(CoreSpotlight)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                else { return }
                open(HighlightID(rawValue: identifier))
            }
            #endif
            #if os(macOS)
            // Ein offenes Fenster nimmt den Treffer an. Ohne das öffnet der
            // Mac für jeden Tipp in der Systemsuche ein neues Fenster.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            #endif
            #if os(iOS)
            .background { PresentationAnchor.Marker(anchor: anchor) }
            #endif
            .sheet(item: $opened) { item in
                RememberedPassageView(highlightID: item.id)
                    .sheetFeedback()
                    .environment(model)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 320)
                    #endif
            }
    }

    private func open(_ id: HighlightID) {
        #if os(iOS)
        let model = model
        let shown = anchor.presentAboveOpenSheet { close in
            RememberedPassageView(highlightID: id, close: close)
                .sheetFeedback()
                .environment(model)
        }
        if shown { return }
        #endif
        opened = OpenedHighlight(id: id)
    }
}

#if os(iOS)
/// Zeigt eine Ansicht über dem Blatt, das gerade offen ist.
///
/// Ein `.sheet` an der Wurzel erscheint nicht, solange dort schon ein Blatt
/// offen ist: die Warteschlange, der Player aus der Leiste, „Podcast
/// hinzufügen“ oder eine Notiz. iOS legt dann kein zweites darüber, und wer
/// aus der Systemsuche kam, sah die gemerkte Stelle nie. Geschlossen wird
/// dafür nichts. Was im offenen Blatt steht, bleibt stehen, und nach
/// „Fertig“ ist man wieder dort.
@MainActor
final class PresentationAnchor {

    /// Eine Ansicht im Fenster der Wurzel. Über sie findet sich das Fenster,
    /// in dem der Treffer ankam.
    weak var view: UIView?

    /// `false`, wenn an der Wurzel gerade nichts offen ist oder das Fenster
    /// noch fehlt. Dann reicht das gewohnte `.sheet`.
    func presentAboveOpenSheet<Content: View>(
        _ content: (_ close: @escaping @MainActor () -> Void) -> Content
    ) -> Bool {
        guard let root = view?.window?.rootViewController else { return false }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        guard top !== root else { return false }
        let host = UIHostingController<Content?>(rootView: nil)
        host.rootView = content { [weak host] in host?.dismiss(animated: true) }
        top.present(host, animated: true)
        return true
    }

    /// Unsichtbar im Hintergrund der Wurzel.
    struct Marker: UIViewRepresentable {
        let anchor: PresentationAnchor

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            anchor.view = view
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            anchor.view = uiView
        }
    }
}
#endif

extension View {
    /// Nimmt Treffer aus der Systemsuche entgegen.
    func spotlightPassages() -> some View { modifier(SpotlightContinuation()) }
}

/// Eine gemerkte Stelle für sich: Kommentar, Zitat, Zeitmarke, Folge.
struct RememberedPassageView: View {

    let highlightID: HighlightID
    /// Schließt die Ansicht, wenn sie nicht als `.sheet` gezeigt wird,
    /// sondern über einem offenen Blatt. Dort erreicht `dismiss` sie nicht
    /// verlässlich.
    var close: (@MainActor () -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var highlight: Highlight? { model.highlights.first { $0.id == highlightID } }

    private func finish() {
        if let close { close() } else { dismiss() }
    }

    /// Abspielen geht nur, solange die Folge noch da ist.
    private func canPlay(_ highlight: Highlight) -> Bool {
        guard let episodeID = highlight.episodeID else { return false }
        return model.episodes.values.contains { $0.contains { $0.id == episodeID } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let highlight {
                    List {
                        Section {
                            NoteRow(highlight: highlight)
                        } footer: {
                            if let source = highlight.sourceTitle {
                                Text(source)
                            }
                        }
                        if canPlay(highlight) {
                            Section {
                                Button {
                                    Task { await model.playHighlight(highlight) }
                                    finish()
                                } label: {
                                    Label("Stelle anhören", systemImage: "play.fill")
                                }
                            }
                        }
                    }
                } else if model.isLoaded {
                    ContentUnavailableView(
                        "Diese Stelle gibt es nicht mehr",
                        systemImage: "bookmark.slash",
                        description: Text("Sie wurde gelöscht oder ist auf diesem Gerät noch nicht angekommen.")
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Gemerkte Stelle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { finish() }
                }
            }
        }
    }
}

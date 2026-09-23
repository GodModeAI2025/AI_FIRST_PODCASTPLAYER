//
//  SettingsView.swift
//  PodcastAI
//
//  Die Einstellungen, auf beiden Plattformen dieselben Inhalte.
//
//  Auf dem Mac liegen sie hinter „Einstellungen …“ im Programmmenü; auf iOS
//  gab es sie gar nicht. Damit war der Spotlight-Schalter nur auf einem der
//  beiden Geräte erreichbar, und der Modellstatus — die Antwort auf „warum
//  formuliert die App gerade nicht?“ — ebenso.
//
//  Der Inhalt steht deshalb hier und wird von beiden Plattformen benutzt,
//  statt zweimal geschrieben zu werden. Zwei Fassungen driften.
//

import SwiftUI
import PodcastAIKit

/// Was das Gerät an Modellen hergibt — und was daraus folgt.
struct IntelligenceSettingsSection: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("Auf diesem Gerät") {
                Text(ModelAvailabilityText.describe(model.modelStatus.onDevice))
            }
            PrivateCloudToggle()
            LabeledContent("Apple-Server") {
                Text(ModelAvailabilityText.describe(model.modelStatus.privateCloudCompute))
            }
        } header: {
            Text("Intelligenz")
        } footer: {
            Text("""
                PodcastAI nutzt nur Apple Intelligence. Antworten und Fakten entstehen auf dem Gerät. \
                Ist „Apple-Server nutzen“ an, gehen Fragen und Vergleiche an Apples Private Cloud \
                Compute. Dort passt mehr Text in eine Anfrage, und Apple speichert sie nicht. Fehlt \
                eine Stufe, sagt die App das, statt einen anderen Anbieter zu nutzen.
                """)
        }
    }
}

/// Der Schalter für Apples Server, in den Einstellungen und auf der
/// Datenschutzseite derselbe.
///
/// Ohne die Berechtigung für Private Cloud Compute steht er aus und lässt
/// sich nicht einschalten. Eine Anfrage käme ohnehin nicht an, und ein
/// eingeschalteter Schalter verspräche etwas anderes.
struct PrivateCloudToggle: View {

    @Environment(AppModel.self) private var model

    private var entitled: Bool { KnowledgeExtractor.privateCloudEntitled }

    var body: some View {
        Toggle("Apple-Server nutzen (Private Cloud Compute)", isOn: Binding(
            get: { entitled && model.allowPrivateCloudCompute },
            set: { model.allowPrivateCloudCompute = $0 }
        ))
        .disabled(!entitled)
        .accessibilityIdentifier("settings.privateCloud")
    }
}

/// Ob Folgen über Mobilfunk laden, wenn jemand sie selbst abspielt, lädt
/// oder ein Transkript anfordert.
///
/// Vorher stand die Antwort nur im Kleingedruckten der Transkripte, und
/// abschalten ließ sich nichts. Die Zeilen sagen jetzt selbst, was gilt.
struct MobileDataSettingsSection: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.allowsCellularLoading },
                set: { model.allowsCellularLoading = $0 }
            )) {
                Text("Abspielen und Laden über Mobilfunk")
                Text(loadingRule)
            }
            .accessibilityIdentifier("settings.cellular")
            LabeledContent("Transkripte für neue Folgen") {
                Text(transcriptRule)
            }
        } header: {
            Text("Mobilfunk")
        } footer: {
            Text("""
                Gemeint ist, was du selbst abspielst, für unterwegs lädst oder als Transkript \
                anforderst. Ein Hotspot zählt wie Mobilfunk. Für Transkripte neuer Folgen gilt \
                der Schalter „Nur im WLAN“ unter Transkripte.
                """)
        }
    }

    private var loadingRule: LocalizedStringKey {
        model.allowsCellularLoading
            ? "An: Folgen laden auch ohne WLAN."
            : "Aus: Ohne WLAN fragt die App vorher."
    }

    private var transcriptRule: LocalizedStringKey {
        if !model.automaticAnalysis { return "aus" }
        return model.preparationOnWiFiOnly ? "nur im WLAN" : "auch über Mobilfunk"
    }
}

/// Die Rückfrage „Über Mobilfunk laden?“, gestellt von `AppModel`, wenn
/// Mobilfunk in den Einstellungen aus ist. Hängt mit der Fehlermeldung an
/// `appFeedback()` und `sheetFeedback()` (`AppAlerts`).
struct MobileDataQuestion: ViewModifier {

    @Environment(AppModel.self) private var model
    /// Nur eine Ansicht fragt, die oberste mit Meldungen (`FeedbackHosts`).
    var isActive = true

    func body(content: Content) -> some View {
        content
            .alert("Über Mobilfunk laden?", isPresented: Binding(
                get: { isActive && model.pendingMobileData != nil },
                set: { if !$0, isActive { model.dismissMobileDataQuestion() } }
            ), presenting: model.pendingMobileData) { request in
                // Die Anfrage kommt mit, damit die Reihenfolge von Knopf
                // und Schließen keine Rolle spielt.
                Button("Laden") { model.answerMobileData(request, load: true) }
                Button("Immer über Mobilfunk laden") { model.answerMobileData(request, load: true, always: true) }
                Button("Abbrechen", role: .cancel) { model.answerMobileData(request, load: false) }
            } message: { request in
                Text("""
                    \(request.detail) In den Einstellungen ist Mobilfunk dafür aus. \
                    Bis du wieder im WLAN bist, fragt die App nach einem Ja nicht noch einmal.
                    """)
            }
    }
}

/// Der Lernschalter.
///
/// Er gehört zu den Einstellungen und nicht in die Interessenliste: dort
/// wäre er eine Option neben Themen, hier ist er eine Entscheidung über die
/// App.
struct AutomaticAnalysisSection: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Transkripte für neue Folgen erstellen", isOn: Binding(
                get: { model.automaticAnalysis },
                set: { model.automaticAnalysis = $0 }
            ))
            if model.automaticAnalysis {
                Picker("Folgen je Podcast", selection: Binding(
                    get: { model.episodesPerSource },
                    set: { model.episodesPerSource = $0 }
                )) {
                    ForEach(AppModel.episodesPerSourceChoices, id: \.self) { count in
                        Text(Self.choiceLabel(count)).tag(count)
                    }
                }
                Toggle("Nur im WLAN", isOn: Binding(
                    get: { model.preparationOnWiFiOnly },
                    set: { model.preparationOnWiFiOnly = $0 }
                ))
                if let wait = model.preparationWait {
                    Label(wait.settingsLabel, systemImage: wait.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            // Auch ohne automatische Transkripte: selbst angeforderte Folgen
            // bekommen ihre Fakten dann ebenfalls von selbst.
            Toggle("Fakten automatisch sammeln", isOn: Binding(
                get: { model.automaticFacts },
                set: { model.automaticFacts = $0 }
            ))
            .accessibilityIdentifier("settings.automaticFacts")
        } header: {
            Text("Transkripte")
        } footer: {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("""
                    Für ein Transkript lädt die App die Folge und schreibt sie auf dem Gerät mit \
                    Zeitmarken mit. Erst dann finden „Für dich“, der Chat und die Themen-Updates etwas \
                    darin. Für ältere Folgen erstellst du das Transkript bei Bedarf einzeln. Im \
                    Datensparmodus erstellt die App keine Transkripte von selbst.
                    """)
                Text("""
                    Fakten zieht die App nach jedem Transkript mit Apple Intelligence auf dem Gerät \
                    heraus, auch im Hintergrund und für ältere Folgen mit Transkript. Dafür braucht es \
                    kein Netz.
                    """)
            }
        }
    }

    /// Der Eintrag im Auswahlmenü. Bei einer Folge heißt er „nur die neueste“.
    private static func choiceLabel(_ count: Int) -> LocalizedStringKey {
        count == 1 ? "nur die neueste" : "die \(count) neuesten"
    }
}

/// Belegter Speicher und das Entfernen von Audiodateien.
struct StorageSettingsSection: View {

    @Environment(AppModel.self) private var model
    @State private var bytes: Int64 = 0
    @State private var confirm = false

    var body: some View {
        Section {
            LabeledContent("Audiodateien auf diesem Gerät") {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Toggle("Audio entfernen, wenn das Transkript fertig ist", isOn: Binding(
                get: { model.removeAudioAfterAnalysis },
                set: { model.removeAudioAfterAnalysis = $0 }
            ))
            Toggle("Gehörte Folgen nach einem Tag vom Gerät entfernen", isOn: Binding(
                get: { model.removeHeardAudio },
                set: { model.removeHeardAudio = $0 }
            ))
            Button("Alle Audiodateien entfernen", role: .destructive) { confirm = true }
                .disabled(bytes == 0)
        } header: {
            Text("Speicher")
        } footer: {
            Text("""
                „Audio entfernen“ löscht nur den Ton. Transkripte, Fakten, gemerkte Stellen und der \
                Hörstand bleiben, abgespielt wird dann aus dem Netz. Was du mit „Laden (offline)“ \
                holst, bleibt auch mit fertigem Transkript auf dem Gerät. Eine einzelne Folge löschst \
                du in der Folge selbst; dann verschwinden auch ihre Daten.
                """)
        }
        .task(id: model.mediaStorageChanged) { bytes = LocalMediaLocator.storedBytes() }
        .confirmationDialog("Alle Audiodateien entfernen?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Audio entfernen, Daten behalten", role: .destructive) {
                Task { await model.removeAllAudio() }
            }
        }
    }
}

/// Ob und wie die Daten zwischen den Geräten abgeglichen werden.
struct SyncSettingsSection: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("iCloud") { Text(model.syncDescription) }
        } header: {
            Text("Synchronisation")
        } footer: {
            Text("""
                Abos, Transkripte, Fakten, Hörstand, Interessen, Themen-Updates und gemerkte Stellen \
                gleichen sich über deine private iCloud-Datenbank zwischen iPhone, iPad und Mac ab. \
                Audiodateien lädt jedes Gerät selbst.
                """)
        }
    }
}

struct LearningSettingsSection: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Interessen vorschlagen", isOn: Binding(
                get: { model.profile.learningEnabled },
                set: { model.setLearningEnabled($0) }
            ))
            Button("Vorschläge zurücksetzen", role: .destructive) {
                model.resetSuggestions()
            }
            .disabled(!model.canResetSuggestions)
        } header: {
            Text("Lernen")
        } footer: {
            Text("""
                PodcastAI leitet Themen aus dem ab, was du tatsächlich gehört hast. Vorschläge \
                wirken erst, wenn du sie übernimmst. Ausgeschaltet entstehen keine neuen.
                """)
        }
    }
}

enum ModelAvailabilityText {
    static func describe(_ availability: ModelAvailability) -> String {
        switch availability {
        case .available: String(localized: "Verfügbar")
        case .unavailable(let reason): reason.message
        }
    }
}

/// Anbieter, Datenschutzerklärung und was die App mit Daten macht.
struct LegalSettingsSection: View {

    static let imprint = URL(string: "https://www.mobilebox-consulting.de/impressum-site-notice/")!
    static let privacyPolicy = URL(string: "https://www.mobilebox-consulting.de/datenschutzerkl%C3%A4rung-privacy-policy/")!

    var body: some View {
        Section {
            NavigationLink { PrivacyOverviewView() } label: {
                Label("Datenschutz in PodcastAI", systemImage: "hand.raised")
            }
            Link(destination: Self.privacyPolicy) {
                Label("Datenschutzerklärung", systemImage: "doc.text")
            }
            Link(destination: Self.imprint) {
                Label("Impressum", systemImage: "building.2")
            }
        } header: {
            Text("Rechtliches")
        } footer: {
            Text("Anbieter: MOBILE BOX - App Consulting UG (haftungsbeschränkt), Karlsruhe.")
        }
    }
}

/// Welche Daten wohin gehen, in einfachen Sätzen.
struct PrivacyOverviewView: View {

    /// Titel und Text sind Schlüssel für den String-Katalog.
    private let items: [(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey)] = [
        ("person.crop.circle.badge.xmark", "Kein Konto, kein eigener Server",
         """
         PodcastAI hat keine Anmeldung, keine Werbung und keine Analyse- oder Tracking-Dienste. \
         Der Anbieter der App bekommt keine deiner Daten.
         """),
        ("waveform", "Transkripte entstehen auf dem Gerät",
         """
         Die Spracherkennung von Apple läuft auf deinem iPhone, iPad oder Mac. Der Ton verlässt \
         dafür das Gerät nicht.
         """),
        ("sparkles", "Antworten und Fakten mit Apple Intelligence",
         """
         Das Modell auf dem Gerät formuliert Antworten und Fakten. Ist „Apple-Server nutzen“ \
         eingeschaltet, gehen deine Frage und die passenden Transkriptstellen an Apples Server \
         (Private Cloud Compute). Apple speichert sie nach eigenen Angaben nicht. Den Schalter \
         findest du unten auf dieser Seite und in den Einstellungen unter Intelligenz.
         """),
        ("translate", "Übersetzen",
         """
         Transkripte und Shownotes übersetzt die App auf dem Gerät mit Apples Übersetzung, nur wenn \
         du auf „Übersetzen“ tippst. Die Sprachen lädt das System beim ersten Mal von Apple, danach \
         geht es auch ohne Netz. Einzelne Stellen übersetzt das Übersetzungsfenster des Systems. Es \
         kann den Text dafür an Apple schicken und sagt das dort selbst. Merken und Kopieren nehmen \
         immer den Originaltext.
         """),
        ("icloud", "Abgleich über deine iCloud",
         """
         Abos, Transkripte, Fakten, Notizen, Interessen und Hörstand liegen in deiner privaten \
         iCloud-Datenbank. Nur deine Geräte mit derselben Apple-ID lesen sie.
         """),
        ("network", "Anfragen ins Netz",
         """
         Feeds und Audiodateien lädt die App direkt beim Anbieter des Podcasts. Die Podcastsuche \
         und Links aus Apple Podcasts fragen Apples Podcast-Verzeichnis mit deinem Suchbegriff, \
         YouTube-Kanäle fragen YouTube. Diese Anbieter sehen dabei, wie bei jedem Abruf, deine \
         IP-Adresse.
         """),
        ("magnifyingglass", "Spotlight nur auf Wunsch",
         """
         Gemerkte Stellen erscheinen in der Systemsuche nur, wenn du das einschaltest. Der Index \
         bleibt auf dem Gerät.
         """),
        ("trash", "Löschen",
         """
         Eine gelöschte Folge verschwindet mit Transkript, Fakten und Hörstand auf allen Geräten. \
         Deine Notizen bleiben, bis du sie selbst löschst. Alles in iCloud entfernst du in den \
         Systemeinstellungen unter Apple-ID › iCloud › Speicher verwalten › PodcastAI.
         """),
    ]

    /// Berechnet: `LocalizedStringKey` ist nicht `Sendable`, eine gespeicherte
    /// statische Eigenschaft müsste es sein.
    static var appleLinks: [(title: LocalizedStringKey, url: URL)] {
        [
            ("Apple Intelligence und Datenschutz", URL(string: "https://www.apple.com/de/legal/privacy/data/de/intelligence-engine/")!),
            ("Private Cloud Compute", URL(string: "https://security.apple.com/blog/private-cloud-compute/")!),
            ("Datensicherheit in iCloud", URL(string: "https://support.apple.com/de-de/102651")!),
            ("Apple Podcasts und Datenschutz", URL(string: "https://www.apple.com/de/legal/privacy/data/de/apple-podcasts/")!),
            ("Datenschutzrichtlinie von Apple", URL(string: "https://www.apple.com/de/legal/privacy/de-ww/")!),
        ]
    }

    var body: some View {
        List {
            ForEach(items, id: \.symbol) { item in
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Label(item.title, systemImage: item.symbol).font(.headline)
                    Text(item.text).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, Design.Spacing.micro)
            }
            // Der Schalter gleich hier, wo steht, was er bewirkt.
            Section {
                PrivateCloudToggle()
            } footer: {
                Text("Aus heißt: Deine Fragen und die Transkriptstellen dazu bleiben auf dem Gerät.")
            }
            Section {
                Link("Vollständige Datenschutzerklärung", destination: LegalSettingsSection.privacyPolicy)
                Link("Impressum", destination: LegalSettingsSection.imprint)
            } footer: {
                Text("Beide Links öffnen die Website des Anbieters im Browser.")
            }
            Section {
                ForEach(Self.appleLinks, id: \.url) { link in
                    Link(link.title, destination: link.url)
                }
            } header: {
                Text("Erklärungen von Apple")
            } footer: {
                Text("""
                    Spracherkennung, Apple Intelligence, Private Cloud Compute, iCloud und das \
                    Podcast-Verzeichnis sind Dienste von Apple. Für sie gelten Apples eigene \
                    Datenschutzangaben.
                    """)
            }
        }
        .navigationTitle("Datenschutz")
    }
}

#if os(iOS)
/// Die Einstellungen auf iOS. Erreichbar über das Zahnrad in „Für dich“ und
/// „Meine Podcasts“ und über „Wissen“.
struct SettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            // Hilfe und Datenschutz zuerst. Wer hier ankommt, sucht oft genau
            // das, und unten bei „Rechtliches“ fand es niemand.
            Section {
                NavigationLink { HelpView() } label: {
                    Label("So funktioniert's", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("settings.help")
                NavigationLink { PrivacyOverviewView() } label: {
                    Label("Datenschutz in PodcastAI", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacy")
            }
            MobileDataSettingsSection()
            IntelligenceSettingsSection()
            AutomaticAnalysisSection()
            SyncSettingsSection()
            StorageSettingsSection()
            LearningSettingsSection()
            SpotlightSettingsSection()
            LegalSettingsSection()
        }
        .navigationTitle("Einstellungen")
    }
}
#endif

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

/// Beide Regeln fürs Netz an einem Ort: was jemand selbst abspielt, lädt
/// oder als Transkript anfordert, und was die App von selbst vorbereitet.
///
/// Vorher stand die zweite Regel als „Nur im WLAN“ unter Transkripte, und
/// hier nur ihr Zustand. Wer nach Mobilfunk suchte, fand sie nicht.
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
            Toggle(isOn: Binding(
                get: { !model.preparationOnWiFiOnly },
                set: { model.preparationOnWiFiOnly = !$0 }
            )) {
                Text("Neue Folgen auch über Mobilfunk vorbereiten")
                Text(preparationRule)
            }
            .accessibilityIdentifier("settings.preparationCellular")
        } header: {
            Text("Mobilfunk")
        } footer: {
            Text("""
                „Abspielen und Laden“ gilt für alles, was du selbst abspielst, für unterwegs lädst oder \
                als Transkript anforderst. „Neue Folgen vorbereiten“ gilt für das, was die App von selbst \
                lädt: Transkripte neuer und älterer Folgen und die neueste Folge je Podcast. Ein Hotspot \
                zählt wie Mobilfunk. Im Datensparmodus lädt die App nichts von selbst. Liegt der Ton schon \
                auf dem Gerät, entsteht das Transkript auch ohne Netz.
                """)
        }
    }

    private var loadingRule: LocalizedStringKey {
        model.allowsCellularLoading
            ? "An: Folgen laden auch ohne WLAN."
            : "Aus: Ohne WLAN fragt die App vorher."
    }

    private var preparationRule: LocalizedStringKey {
        model.preparationOnWiFiOnly
            ? "Aus: Was die App von selbst lädt, wartet auf WLAN."
            : "An: Die App lädt auch ohne WLAN von selbst."
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
            }
            #if os(macOS)
            // Der Mac hat keinen Mobilfunk, wohl aber den Hotspot eines
            // Telefons. Auf iOS steht der Schalter unter Mobilfunk.
            Toggle("Neue Folgen auch über einen Hotspot vorbereiten", isOn: Binding(
                get: { !model.preparationOnWiFiOnly },
                set: { model.preparationOnWiFiOnly = !$0 }
            ))
            .accessibilityIdentifier("settings.preparationCellular")
            #endif
            if model.automaticAnalysis, let wait = model.preparationWait {
                Label(wait.settingsLabel, systemImage: wait.symbol)
                    .foregroundStyle(.secondary)
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
                    darin. Ältere Folgen eines Podcasts nimmt die App dazu, wenn du in seiner Folgenliste \
                    „Ältere Folgen auch vorbereiten“ wählst. Liegt der Ton schon auf dem Gerät, entsteht \
                    das Transkript auch ohne Netz. Im Datensparmodus lädt die App nichts von selbst.
                    """)
                #if os(iOS)
                Text("Ob die App dafür auch Mobilfunk nutzt, stellst du oben unter Mobilfunk ein.")
                #else
                Text("Über den Hotspot eines Telefons lädt die App nur, wenn der Schalter dafür an ist.")
                #endif
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

/// Transkripte für YouTube-Videos über Supadata, mit eigenem Schlüssel.
///
/// Die App bringt keinen Schlüssel mit. Wer bei Supadata ein Konto hat,
/// trägt seinen Schlüssel hier ein; er liegt dann nur im Schlüsselbund
/// dieses Geräts. Ohne Schlüssel ist die Funktion aus, und YouTube-Folgen
/// bekommen ihr Transkript über den Audio-Podcast oder gar nicht.
struct YouTubeTranscriptSettingsSection: View {

    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    static let supadataWebsite = URL(string: "https://supadata.ai")!

    var body: some View {
        Section {
            Toggle("YouTube-Transkripte über Supadata", isOn: Binding(
                get: { model.youTubeCaptionsEnabled },
                set: { model.youTubeCaptionsEnabled = $0 }
            ))
            .accessibilityIdentifier("settings.youTubeCaptions")

            if model.hasSupadataKey {
                LabeledContent("Supadata-Schlüssel") {
                    Text("im Schlüsselbund gesichert")
                }
                status
                HStack {
                    Button("Prüfen") { Task { await model.checkSupadataKey() } }
                        .disabled(model.supadataKeyCheck == .checking)
                        .accessibilityIdentifier("settings.supadataCheck")
                    Spacer()
                    Button("Entfernen", role: .destructive) { Task { await model.removeSupadataKey() } }
                        .accessibilityIdentifier("settings.supadataRemove")
                }
                .buttonStyle(.borderless)
            }
            // Auch mit Schlüssel: nach einer Ablehnung trägt man hier einen neuen ein.
            if !model.hasSupadataKey || model.supadataKeyRejected {
                SecureField(model.hasSupadataKey ? "Neuer Supadata-Schlüssel" : "Eigener Supadata-Schlüssel",
                            text: $draft)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .accessibilityIdentifier("settings.supadataKey")
                Button("Sichern und prüfen", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.supadataSave")
            }
            Link(destination: Self.supadataWebsite) { Text(verbatim: "supadata.ai") }
        } header: {
            Text("YouTube-Transkripte (Supadata)")
        } footer: {
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("""
                    Supadata ist ein unabhängiger Dienst und kein Teil von PodcastAI. Wer einen eigenen \
                    Supadata-Schlüssel hat, kann ihn hier eintragen. Die App holt damit Untertitel und \
                    Metadaten, die es zu einem Video schon gibt, und macht daraus ein Transkript mit \
                    Zeitmarken, Fakten und Chat. Das gilt für YouTube und für einzelne Beiträge von \
                    TikTok, Instagram, X und Facebook.
                    """)
                Text("""
                    Dafür gehen die Links der Videos und Beiträge an supadata.ai, dazu für die Suche nach \
                    einer Folge auf YouTube die Titel von Podcast und Folge. Sonst nichts. Kosten und \
                    Bedingungen regelst du direkt mit Supadata. Der Schlüssel liegt nur im Schlüsselbund \
                    dieses Geräts, nicht in iCloud und in keinem Export.
                    """)
                Text("""
                    Auch Folgen mit Ton, zu denen der Podcast kein Transkript liefert, bekommen es dann \
                    zuerst aus den Untertiteln derselben Folge auf YouTube. Ein paar kurze Stücke des Tons \
                    zeigen, ob die Zeiten verschoben sind, etwa durch Werbung, und die App passt sie an. \
                    Passt es nicht sicher, lädt sie den Ton und transkribiert ihn wie gewohnt auf dem Gerät. \
                    Gesucht wird je Folge höchstens einmal in der Woche.
                    """)
                Text("""
                    Ohne Schlüssel bekommen YouTube-Folgen ihr Transkript aus dem passenden Audio-Podcast, \
                    falls du ihn abonnierst, sonst gibt es Titel, Beschreibung und Kapitel.
                    """)
            }
        }
    }

    /// Was über den Schlüssel bekannt ist. Eine Ablehnung steht immer da,
    /// sonst das Ergebnis der letzten Prüfung.
    @ViewBuilder private var status: some View {
        if model.supadataKeyRejected {
            NoticeLabel("Supadata hat den Schlüssel abgelehnt. Bis du einen neuen einträgst, ist die Funktion aus.",
                        kind: .failure)
        } else {
            switch model.supadataKeyCheck {
            case .idle:
                if let until = model.supadataRestingUntil, until > Date() {
                    Label("Supadata ruht bis \(until.formatted(date: .omitted, time: .shortened)).",
                          systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            case .checking:
                HStack(spacing: Design.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Wird geprüft …").foregroundStyle(.secondary)
                }
            case .valid(let used?, let max?):
                Label("Schlüssel gültig, \(used) von \(max) Credits in diesem Zeitraum verbraucht.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .valid:
                Label("Schlüssel gültig.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .exhausted:
                NoticeLabel("Schlüssel gültig, aber das Kontingent bei Supadata ist aufgebraucht.", kind: .info)
            case .rejected:
                NoticeLabel("Supadata hat den Schlüssel abgelehnt.", kind: .failure)
            case .unreachable:
                Label("Supadata war nicht erreichbar. Über den Schlüssel sagt das nichts.",
                      systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Das Feld leert sich gleich, der Schlüssel bleibt nicht im Zustand der Ansicht.
        draft = ""
        fieldFocused = false
        Task { await model.saveSupadataKey(key) }
    }
}

/// Derselbe Abschnitt als eigene Seite, erreichbar aus einer YouTube-Folge.
struct SupadataSettingsView: View {
    var body: some View {
        Form { YouTubeTranscriptSettingsSection() }
            .formStyle(.grouped)
            .navigationTitle("YouTube-Transkripte")
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
            Toggle("Neueste Folge je Podcast behalten", isOn: Binding(
                get: { model.keepNewestAudio },
                set: { model.keepNewestAudio = $0 }
            ))
            .accessibilityIdentifier("settings.keepNewest")
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
            // Je Schalter ein Satz, was er bewirkt. So stimmt der Text, wie
            // auch immer die Schalter darüber stehen.
            Text("""
                Mit „Neueste Folge je Podcast behalten“ bleibt die neueste Folge jedes Podcasts auf dem \
                Gerät und spielt ohne Netz, bis eine neuere geladen ist. Mit „Audio entfernen, wenn das \
                Transkript fertig ist“ nimmt die App die anderen Folgen nach dem Transkript wieder vom \
                Gerät, abgespielt wird dann aus dem Netz. Was du mit „Laden (offline)“ holst, bleibt, \
                bis du „Audio entfernen“ wählst. „Audio entfernen“ löscht nur den Ton; Transkripte, \
                Fakten, gemerkte Stellen und der Hörstand bleiben. Eine einzelne Folge löschst du in der \
                Folge selbst, dann verschwinden auch ihre Daten.
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
            VStack(alignment: .leading, spacing: Design.Spacing.small) {
                Text("Anbieter: MOBILE BOX - App Consulting UG (haftungsbeschränkt), Karlsruhe.")
                Text("""
                    Podcast-Daten: Charts und Kategorien kommen von Apple Podcasts, gesucht wird bei Apple \
                    und bei Podcast Index (podcastindex.org). Beide sehen deinen Suchbegriff und deine \
                    IP-Adresse, ein Konto gibt es bei keinem.
                    """)
            }
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
         Das Modell auf dem Gerät formuliert Antworten, Fakten und den Satz je Kapitel und wählt \
         die Tags der Kapitel. Ist „Apple-Server nutzen“ eingeschaltet, gehen deine Frage und die \
         passenden Transkriptstellen an Apples Server (Private Cloud Compute). Satz und Tags je \
         Kapitel kommen nur von Apples Servern, wenn das Modell auf dem Gerät fehlt oder für die \
         Tags zu langsam ist, dann mit den Transkriptstellen des Kapitels. Apple speichert sie \
         nach eigenen Angaben nicht. Den Schalter findest du unten auf dieser Seite \
         und in den Einstellungen unter Intelligenz.
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
         Feeds und Audiodateien lädt die App direkt beim Anbieter des Podcasts. Links aus Apple \
         Podcasts fragen Apples Podcast-Verzeichnis, YouTube-Kanäle fragen YouTube. Diese Anbieter \
         sehen dabei, wie bei jedem Abruf, deine IP-Adresse.
         """),
        ("play.rectangle", "YouTube-Transkripte über Supadata",
         """
         Nur wenn du einen eigenen Supadata-Schlüssel einträgst: Für YouTube-Videos und einzelne \
         Beiträge von TikTok, Instagram, X und Facebook gehen die Links an Supadata (supadata.ai), \
         einen unabhängigen Dienst, um Untertitel und Metadaten abzurufen. Für Folgen mit Ton ohne \
         eigenes Transkript sucht die App dort mit den Titeln von Podcast und Folge nach derselben \
         Folge auf YouTube. Kontodaten, Fragen und \
         deine übrigen Daten gehen dorthin nicht. Der Schlüssel liegt nur im Schlüsselbund dieses \
         Geräts. Supadata sieht dabei deine IP-Adresse, und für den Dienst gelten seine eigenen \
         Bedingungen.
         """),
        ("square.grid.2x2", "Podcast-Katalog",
         """
         Angesagt und Kategorien im Blatt „Podcast hinzufügen“ kommen von Apple Podcasts. Deinen \
         Suchbegriff schickt die App an Apple und an Podcast Index (podcastindex.org), einen \
         offenen Podcast-Katalog. Ein Konto brauchst du bei keinem der beiden, beide sehen aber \
         deine IP-Adresse. Die Cover kommen von Apple oder vom Server des jeweiligen Podcasts.
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
                    Spracherkennung, Apple Intelligence, Private Cloud Compute, iCloud und Apples \
                    Podcast-Verzeichnis sind Dienste von Apple. Für sie gelten Apples eigene \
                    Datenschutzangaben.
                    """)
            }
            Section {
                Link("Datenschutzerklärung von Podcast Index", destination: PodcastCatalog.podcastIndexPrivacyPolicy)
                Link(destination: PodcastCatalog.podcastIndexWebsite) { Text(verbatim: "podcastindex.org") }
            } header: {
                Text("Podcast-Katalog")
            } footer: {
                Text("""
                    Podcast Index ist ein unabhängiger Dienst. Die App fragt ihn nur bei der Suche. Für ihn \
                    gilt seine eigene Datenschutzerklärung.
                    """)
            }
            Section {
                Link(destination: YouTubeTranscriptSettingsSection.supadataWebsite) { Text(verbatim: "supadata.ai") }
            } header: {
                Text("YouTube-Transkripte (Supadata)")
            } footer: {
                Text("""
                    Supadata ist ein unabhängiger Dienst und kein Teil von PodcastAI. Die App fragt ihn nur \
                    mit deinem eigenen Schlüssel. Für ihn gelten seine eigenen Bedingungen und seine \
                    Datenschutzerklärung.
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
            YouTubeTranscriptSettingsSection()
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

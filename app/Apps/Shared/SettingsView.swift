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
            Toggle("Private Cloud Compute nutzen", isOn: Binding(
                get: { model.allowPrivateCloudCompute },
                set: { model.allowPrivateCloudCompute = $0 }
            ))
            LabeledContent("Private Cloud Compute") {
                Text(ModelAvailabilityText.describe(model.modelStatus.privateCloudCompute))
            }
        } header: {
            Text("Intelligenz")
        } footer: {
            Text("PodcastAI nutzt ausschliesslich Apple Intelligence. Antworten und Fakten entstehen "
                 + "auf dem Gerät oder, wenn eingeschaltet und verfügbar, auf Apples Private Cloud "
                 + "Compute. Dort ist mehr Kontext möglich; Apple speichert die Anfragen nicht. Fehlt "
                 + "eine Stufe, sagt die App das, statt einen anderen Anbieter zu nutzen.")
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
            Toggle("Neue Folgen vorbereiten", isOn: Binding(
                get: { model.automaticAnalysis },
                set: { model.automaticAnalysis = $0 }
            ))
        } header: {
            Text("Vorbereiten")
        } footer: {
            Text("Die App lädt die \(AppModel.automaticAnalysisPerSource) jüngsten Folgen je Quelle und "
                 + "transkribiert sie mit Zeitmarken. Erst dadurch finden „Für dich“, die Suche und die "
                 + "Themen-Updates etwas. Das kostet Daten und Akku; ausgeschaltet erschliesst die App nur, "
                 + "was du selbst anforderst.")
        }
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
            Button("Alle Audiodateien entfernen", role: .destructive) { confirm = true }
                .disabled(bytes == 0)
        } header: {
            Text("Speicher")
        } footer: {
            Text("Audio entfernen löscht nur den Ton. Transkripte, Fakten, gemerkte Stellen und der "
                 + "Hörstand bleiben, abgespielt wird dann aus dem Netz. Eine einzelne Folge löschst du "
                 + "in der Folge selbst; dann verschwinden auch ihre Daten.")
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
            Text("Abos, Transkripte, Fakten, Hörstand, Interessen, Themen-Updates und gemerkte Stellen "
                 + "gleichen sich über deine private iCloud-Datenbank zwischen iPhone, iPad und Mac ab. "
                 + "Audiodateien lädt jedes Gerät selbst.")
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
            .disabled(model.profile.suggested.isEmpty)
        } header: {
            Text("Lernen")
        } footer: {
            Text("PodcastAI leitet Themen aus dem ab, was du tatsächlich gehört hast. "
                 + "Vorschläge wirken erst, wenn du sie übernimmst. Ausgeschaltet "
                 + "entstehen keine neuen.")
        }
    }
}

enum ModelAvailabilityText {
    static func describe(_ availability: ModelAvailability) -> String {
        switch availability {
        case .available: "Verfügbar"
        case .unavailable(let reason): reason.message
        }
    }
}

#if os(iOS)
/// Die Einstellungen auf iOS. Erreichbar über „Wissen“.
struct SettingsView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            IntelligenceSettingsSection()
            AutomaticAnalysisSection()
            SyncSettingsSection()
            StorageSettingsSection()
            LearningSettingsSection()
            SpotlightSettingsSection()
        }
        .navigationTitle("Einstellungen")
    }
}
#endif

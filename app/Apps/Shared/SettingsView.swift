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
            LabeledContent("Private Cloud Compute") {
                Text(ModelAvailabilityText.describe(model.modelStatus.privateCloudCompute))
            }
        } header: {
            Text("Intelligenz")
        } footer: {
            Text("PodcastAI nutzt ausschließlich Apple-Modelle. Ist eine Stufe nicht "
                 + "verfügbar, fehlt die Funktion — es wird kein anderer Anbieter "
                 + "eingesetzt.")
        }
    }
}

/// Der Lernschalter.
///
/// Er gehört zu den Einstellungen und nicht in die Interessenliste: dort
/// wäre er eine Option neben Themen, hier ist er eine Entscheidung über die
/// App.
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
            LearningSettingsSection()
            StorageSettingsSection()
            SpotlightSettingsSection()
        }
        .navigationTitle("Einstellungen")
    }
}
#endif

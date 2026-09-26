//
//  ShareView.swift
//  „An PodcastAI senden“ (iOS und macOS)
//
//  Die ganze Oberfläche der Erweiterung: ein Satz, was gerade passiert,
//  und ein Knopf zum Schließen. Keine Vorschau, kein Netz; die Vorschau
//  zeigt die App.
//

import SwiftUI

struct ShareView: View {

    let intake: ShareIntake

    var body: some View {
        VStack(spacing: 14) {
            Text("An PodcastAI senden")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            switch intake.phase {
            case .working:
                ProgressView()
                    .controlSize(.large)
                Text("Wird an PodcastAI übergeben …")
                    .foregroundStyle(.secondary)

            case .handedOver(let summary):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("An PodcastAI gesendet")
                    .font(.title3.weight(.semibold))
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Text("In PodcastAI geöffnet, sobald du die App startest.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fertig") { intake.done() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Nicht gesendet")
                    .font(.title3.weight(.semibold))
                Text(verbatim: message)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Schließen") { intake.dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await intake.start() }
    }
}

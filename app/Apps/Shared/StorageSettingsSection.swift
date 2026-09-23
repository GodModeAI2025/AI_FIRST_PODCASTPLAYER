//
//  StorageSettingsSection.swift
//  PodcastAI
//
//  Was die App an Platz belegt — und wie man ihn zurückbekommt.
//
//  Vorher gab es dafür keinen Weg. Die einzige Möglichkeit, mehrere
//  Gigabyte Audiodateien loszuwerden, war: die App löschen. Das ist die Art
//  Befund, die in einer Beta als „frisst meinen Speicher“ zurückkommt.
//
//  Was hier **nicht** passiert: automatisches Aufräumen. Ob eine Audiodatei
//  nach der Analyse noch gebraucht wird, ist eine Produktentscheidung. Bis
//  sie getroffen ist, entscheidet der Nutzer je Folge.
//

import SwiftUI
import PodcastAIKit

struct StorageSettingsSection: View {

    @Environment(AppModel.self) private var model
    @State private var entries: [MediaEntry] = []
    @State private var total: Int64 = 0
    @State private var staging: Int64 = 0
    @State private var confirmingRemoveAll = false

    private var library: MediaLibrary {
        MediaLibrary(directory: LocalMediaLocator.mediaDirectory)
    }

    var body: some View {
        Section {
            LabeledContent("Belegt") {
                Text(total.readableByteSize)
                    .monospacedDigit()
            }

            if staging > 0 {
                // Reste abgebrochener Downloads. Sie gehören niemandem, und
                // sie zu behalten hat keinen Zweck — deshalb ohne Rückfrage.
                Button {
                    Task {
                        _ = await library.removeStaging()
                        await reload()
                    }
                } label: {
                    Text("Reste entfernen (\(staging.readableByteSize))")
                        .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                }
            }

            if entries.isEmpty {
                Text("Keine geladenen Folgen.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            Text(title(for: entry))
                                .lineLimit(1)
                            Text(entry.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Design.Spacing.small)
                        Text(entry.byteCount.readableByteSize)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Löschen", role: .destructive) {
                            Task {
                                _ = await library.remove(entry.id)
                                await reload()
                            }
                        }
                    }
                }

                Button(role: .destructive) {
                    confirmingRemoveAll = true
                } label: {
                    Text("Alle Audiodateien löschen")
                        .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                }
            }
        } header: {
            Text("Speicher")
        } footer: {
            // Die wichtigste Zeile dieses Abschnitts: was Löschen kostet
            // und was es **nicht** kostet.
            Text(MediaLibrary.Consequence.summary)
        }
        .task { await reload() }
        .confirmationDialog(
            "Alle Audiodateien löschen?",
            isPresented: $confirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("\(total.readableByteSize) freigeben", role: .destructive) {
                Task {
                    _ = await library.removeAll()
                    await reload()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(MediaLibrary.Consequence.summary)
        }
    }

    /// Der Dateiname ist die Kennung der Medienfassung — für Menschen
    /// unlesbar. Wo die zugehörige Folge bekannt ist, steht ihr Titel da.
    private func title(for entry: MediaEntry) -> String {
        for list in model.episodes.values {
            if let episode = list.first(where: { $0.currentMediaVersionID == entry.id }) {
                return episode.title
            }
        }
        return "Geladene Folge"
    }

    private func reload() async {
        let library = self.library
        entries = await library.entries()
        total = await library.totalBytes()
        staging = await library.stagingBytes()
    }
}

//
//  PerspectiveViews.swift
//  PodcastAI
//
//  Widerspruchs-Mixer und Breadcrumb-Trail.
//
//  Beide Oberflächen tragen dieselbe Zurückhaltung: sie helfen beim eigenen
//  Urteil, statt eines nahezulegen. Konkret heisst das — die These steht als
//  These da und nicht als Feststellung, Gegenpositionen kommen nach den
//  stützenden statt zuerst, und eine unausgewogene Lage wird benannt,
//  statt sie als Prüfung auszugeben.
//

import SwiftUI
import PodcastAIKit

// MARK: - Widerspruchs-Mixer

struct CounterpointView: View {

    @Environment(AppModel.self) private var model
    @State private var thesis = ""
    @State private var stance: Stance?
    @State private var candidates: [CounterpointCandidate] = []
    @State private var notice: String?

    private let mixer = CounterpointMixer()

    var body: some View {
        List {
            Section {
                TextField("Deine These", text: $thesis, axis: .vertical)
                    .lineLimit(1...3)
                Button("Prüfen") { check() }
                    .frame(minHeight: Design.minimumTapTarget)
                    .buttonStyle(.pressable)
                    .disabled(thesis.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("These")
            } footer: {
                Text("Formuliere, was du für richtig hältst. PodcastAI sucht dazu belegte "
                     + "Positionen aus deinen Quellen — dafür und dagegen.")
            }

            if let stance {
                Section("Status") {
                    // Der Unterschied zwischen „gespeichert“ und „das ist
                    // meine Meinung“ steht hier ausdrücklich.
                    Label(
                        stance.isUserPosition
                            ? "Als dein Standpunkt bestätigt"
                            : "Noch nicht als dein Standpunkt bestätigt",
                        systemImage: stance.isUserPosition ? "checkmark.seal" : "questionmark.circle"
                    )
                    .font(.callout)

                    if !stance.isUserPosition {
                        Button("Als meinen Standpunkt bestätigen") {
                            self.stance?.status = .confirmed
                        }
                    } else {
                        Button("Bestätigung zurücknehmen", role: .destructive) {
                            self.stance?.status = .withdrawn
                        }
                    }
                }
            }

            if let notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if !candidates.isEmpty {
                ForEach(CounterpointRelation.allOrdered, id: \.self) { relation in
                    let group = candidates.filter { $0.relation == relation }
                    if !group.isEmpty {
                        Section(relation.label) {
                            ForEach(group) { candidate in
                                CounterpointRow(candidate: candidate)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        model.playCounterpoints(candidates, thesis: thesis)
                    } label: {
                        Label("Nacheinander anhören", systemImage: "play.circle")
                            .frame(minHeight: Design.minimumTapTarget)
                    }
                    .buttonStyle(.pressable)
                } footer: {
                    Text("Du hörst die Originalstellen in ihrem Kontext. PodcastAI fasst sie "
                         + "nicht zusammen und spricht sie nicht nach.")
                }
            }
        }
        .navigationTitle("Gegenpositionen")
    }

    private func check() {
        let text = thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Origin ist explicitUser, Status bleibt proposed: formuliert zu
        // haben ist noch nicht dasselbe wie bestätigt zu haben.
        stance = Stance(text: text, origin: .explicitUser)
        Task {
            let found = await model.findCounterpoints(for: text)
            candidates = mixer.balance(found)
            notice = mixer.imbalanceNotice(candidates)
        }
    }
}

extension CounterpointRelation {
    /// Stützendes zuerst, dann Widerspruch, dann abweichende Voraussetzungen.
    /// Wer mit der Gegenposition anfängt, hört sie als Angriff.
    static var allOrdered: [CounterpointRelation] {
        [.supports, .contradicts, .differentPremise, .qualifies]
    }
}

struct CounterpointRow: View {

    let candidate: CounterpointCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(candidate.sourceTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(candidate.excerpt)
                .font(.callout)
                .lineLimit(4)
            if !candidate.isModelConfirmed {
                // Eine vermutete Zuordnung wird als vermutet gezeigt. Sie als
                // Tatsache auszugeben wäre genau der Fehler, den dieser
                // Modus vermeiden soll.
                //
                // Symbol **und** Text: Farbe allein trägt die Warnung nicht
                // für jeden.
                Label("Zuordnung vermutet, nicht geprüft",
                      systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, Design.Spacing.micro / 2)
    }
}

// MARK: - Breadcrumb Trail

/// Die Abschlusskarte einer Hörsession.
///
/// Sie erscheint nur bei einem bewussten Ende, einmal, und sie ist
/// überspringbar. „Später“ ist eine vollwertige Antwort.
struct SessionClosureSheet: View {

    let closure: SessionClosure
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(closure.question)
                        .font(.title3)
                        .padding(.vertical, Design.Spacing.small)
                } header: {
                    Text("Was nimmst du daraus mit?")
                }

                Section {
                    Button {
                        model.deepen(closure); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            Label("Vertiefen", systemImage: "arrow.down.circle")
                            Text(closure.followUpLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Nicht anbieten, was ins Leere führt.
                    .disabled(!closure.canDeepen)

                    Button {
                        model.park(closure); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            Label("Parken", systemImage: "tray.and.arrow.down")
                            Text("Frage, Belege und Notizen als Wissenslandkarte sichern.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                            Label("Verwerfen", systemImage: "xmark.circle")
                            // Die wichtigste Zeile dieser Ansicht.
                            Text("Verwirft nur diesen Vorschlag. Gemerkte Stellen, Notizen "
                                 + "und Belege bleiben.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Session beenden")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Später") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Geparkte Wissenslandkarten.
struct TrailListView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.trails.isEmpty {
                ContentUnavailableView {
                    Label("Keine Wissenslandkarten", systemImage: "map")
                } description: {
                    Text("Am Ende einer Hörsession kannst du eine Frage samt Belegen parken. "
                         + "Sie landet hier.")
                }
            }
            ForEach(model.trails) { trail in
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    Text(trail.question).font(.headline)
                    Text("\(trail.evidenceIDs.count) Belege · geparkt \(trail.parkedAt, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Aufbewahren ist keine Zustimmung — und das steht da.
                    Text("Aufbewahrt, nicht zugestimmt.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, Design.Spacing.micro / 2)
            }
        }
        .navigationTitle("Wissenslandkarten")
    }
}

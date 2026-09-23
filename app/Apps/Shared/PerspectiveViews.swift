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

    private let mixer = CounterpointMixer()

    private var check: CounterpointCheck? { model.counterpointCheck }
    private var isChecking: Bool { check?.isRunning ?? false }

    var body: some View {
        List {
            Section {
                TextField("Deine These", text: $thesis, axis: .vertical)
                    .lineLimit(1...3)
                Button("Prüfen") { model.checkThesis(thesis) }
                    .frame(minHeight: Design.minimumTapTarget)
                    .buttonStyle(.pressable)
                    .disabled(isChecking || thesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("These")
            } footer: {
                Text("Formuliere, was du für richtig hältst. PodcastAI sucht dazu belegte "
                     + "Positionen aus deinen Quellen, dafür und dagegen.")
            }

            if let check {
                // Die geprüfte These steht da, wie sie geprüft wurde. Wird das
                // Textfeld danach geändert, gehören die Stellen trotzdem zu ihr.
                Section("Geprüft") {
                    Text(check.thesis)
                        .font(.callout)
                    if check.isRunning {
                        HStack(spacing: Design.Spacing.small) {
                            ProgressView()
                            Text("Stellen werden gesucht und eingeordnet …")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }

                if !check.isRunning {
                    results(check)
                }
            }
        }
        .navigationTitle("Gegenpositionen")
        .onAppear {
            if thesis.isEmpty, let check { thesis = check.thesis }
        }
    }

    @ViewBuilder
    private func results(_ check: CounterpointCheck) -> some View {
        if let notice = check.classificationProblem ?? mixer.imbalanceNotice(check.candidates) {
            Section {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }

        ForEach(CounterpointRelation.allOrdered, id: \.self) { relation in
            let group = check.candidates.filter { $0.relation == relation }
            if !group.isEmpty {
                Section(relation.label) {
                    ForEach(group) { candidate in
                        CounterpointRow(candidate: candidate)
                    }
                }
            }
        }

        if !check.candidates.isEmpty {
            Section {
                Button {
                    model.playCounterpoints(check.candidates, thesis: check.thesis)
                } label: {
                    Label("Nacheinander anhören", systemImage: "play.circle")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                Button {
                    model.saveCounterpointCheck()
                } label: {
                    Label(check.isSaved ? "Als Wissenslandkarte gesichert" : "Als Wissenslandkarte sichern",
                          systemImage: check.isSaved ? "checkmark" : "map")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                .disabled(check.isSaved)
            } footer: {
                Text("Du hörst die Originalstellen in ihrem Kontext. PodcastAI fasst sie nicht "
                     + "zusammen und spricht sie nicht nach. Eine gesicherte These ist aufbewahrt, "
                     + "nicht als deine Meinung vermerkt.")
            }
        }
    }
}

extension CounterpointRelation {
    /// Stützendes zuerst, dann Widerspruch, dann abweichende Voraussetzungen.
    /// Wer mit der Gegenposition anfängt, hört sie als Angriff. Was nicht
    /// eingeordnet ist, steht zuletzt.
    static var allOrdered: [CounterpointRelation] {
        [.supports, .contradicts, .differentPremise, .qualifies, .unclassified]
    }
}

struct CounterpointRow: View {

    let candidate: CounterpointCandidate
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.playCounterpoint(candidate)
        } label: {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(candidate.excerpt)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                if let range = candidate.range {
                    HStack(spacing: Design.Spacing.micro) {
                        TimecodeLabel(range.start)
                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.tint)
                    }
                }
                if !candidate.isModelConfirmed, candidate.relation != .unclassified {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(candidate.range == nil || candidate.episodeID == nil)
        .accessibilityHint("Spielt die Folge ab dieser Stelle")
        .contextMenu {
            Button { model.playCounterpoint(candidate) } label: {
                Label("In der Folge ab hier hören", systemImage: "play.fill")
            }
            Button { model.rememberCounterpoint(candidate) } label: {
                Label("Stelle merken", systemImage: "bookmark")
            }
        }
    }

    /// Podcast und Folge, damit man sieht, wer das gesagt hat.
    private var origin: String {
        [candidate.sourceTitle, candidate.episodeTitle].compactMap { $0 }.joined(separator: " · ")
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
                            Text("Frage, Belege und die Notizen dieser Session als Wissenslandkarte sichern.")
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

/// Gesicherte Wissenslandkarten. Jede lässt sich öffnen und löschen.
struct TrailListView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.trails.isEmpty {
                ContentUnavailableView {
                    Label("Keine Wissenslandkarten", systemImage: "map")
                } description: {
                    Text("Eine Wissenslandkarte hält eine Frage mit ihren Belegen und Notizen fest. "
                         + "Unter „Fragen“ steht an jeder Antwort „Als Wissenslandkarte sichern“. "
                         + "Hörst du Belege nacheinander und beendest die Wiedergabe nach mindestens "
                         + "zwei Minuten, bietet die Abschlusskarte „Parken“ an.")
                }
            }
            ForEach(model.trails) { trail in
                NavigationLink {
                    TrailDetailView(trailID: trail.id)
                } label: {
                    TrailRow(trail: trail, noteCount: model.notes(of: trail).count)
                }
                .swipeActions {
                    Button(role: .destructive) { model.removeTrail(trail.id) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { model.removeTrail(trail.id) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Wissenslandkarten")
    }
}

/// Eine Zeile der Liste: Frage, Anfang der Antwort, was dazugehört.
private struct TrailRow: View {

    let trail: KnowledgeTrail
    let noteCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(trail.question).font(.headline).lineLimit(3)
            if let answer = trail.answerText {
                Text(answer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Aufbewahren ist keine Zustimmung, und das steht da.
            Text("Aufbewahrt, nicht zugestimmt.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Design.Spacing.micro / 2)
    }

    private var details: String {
        let count = trail.evidenceIDs.count
        var parts = [count == 1 ? "1 Beleg" : "\(count) Belege"]
        if noteCount > 0 { parts.append(noteCount == 1 ? "1 Notiz" : "\(noteCount) Notizen") }
        parts.append("gesichert am \(trail.parkedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}

/// Eine geöffnete Wissenslandkarte: Frage, Antwort, Belege zum Anhören und
/// die Notizen dazu. Abgespielt wird nur, was jemand antippt.
struct TrailDetailView: View {

    let trailID: KnowledgeNodeID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: [Evidence] = []
    @State private var origins: [EpisodeID: String] = [:]
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var trail: KnowledgeTrail? { model.trails.first { $0.id == trailID } }

    var body: some View {
        Group {
            if let trail {
                content(trail)
            } else {
                ContentUnavailableView("Diese Wissenslandkarte gibt es nicht mehr", systemImage: "map")
            }
        }
        .navigationTitle("Wissenslandkarte")
        .task(id: trail?.evidenceIDs) {
            guard let trail else { return }
            let found = await model.evidence(of: trail)
            origins = await model.citationOrigins(for: found)
            evidence = found
            loaded = true
        }
    }

    /// Die Belege mit den Nummern, auf die der Antworttext verweist.
    private func numbered(_ trail: KnowledgeTrail) -> [(number: Int, evidence: Evidence)] {
        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let numbers = trail.citationNumbers {
            let pairs = numbers.sorted { $0.key < $1.key }.compactMap { number, id in
                byID[id].map { (number: number, evidence: $0) }
            }
            if !pairs.isEmpty { return pairs }
        }
        return evidence.enumerated().map { (number: $0.offset + 1, evidence: $0.element) }
    }

    private func content(_ trail: KnowledgeTrail) -> some View {
        let items = numbered(trail)
        let playable = items.filter { $0.evidence.isPlayable }.count
        let missing = loaded ? trail.evidenceIDs.count - evidence.count : 0
        let notes = model.notes(of: trail)
        return List {
            Section {
                Text(trail.question)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let answer = trail.answerText {
                    Text(answer)
                        .textSelection(.enabled)
                }
                Text("Gesichert am \(trail.parkedAt.formatted(date: .long, time: .omitted)). "
                     + "Aufbewahrt, nicht zugestimmt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !items.isEmpty || missing > 0 {
                Section {
                    ForEach(items, id: \.number) { item in
                        CitationRow(number: item.number, evidence: item.evidence,
                                    origin: origins[item.evidence.episodeID])
                    }
                    if playable > 0 {
                        Button {
                            model.playTrail(trail)
                        } label: {
                            Label(playable == 1 ? "Diese Stelle anhören"
                                                : "Alle \(playable) Stellen nacheinander anhören",
                                  systemImage: "play.circle")
                                .frame(minHeight: Design.minimumTapTarget)
                        }
                        .accessibilityHint("Spielt die belegten Originalstellen nacheinander ab")
                    }
                } header: {
                    Text("Belege")
                } footer: {
                    if missing > 0 {
                        Text(missing == 1 ? "Ein Beleg ist nicht mehr da." : "\(missing) Belege sind nicht mehr da.")
                    }
                }
            }

            if !notes.isEmpty {
                Section("Notizen") {
                    ForEach(notes) { note in
                        if note.episodeID != nil {
                            Button { Task { await model.playHighlight(note) } } label: {
                                NoteRow(highlight: note).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Spielt die Folge ab dieser Stelle")
                        } else {
                            NoteRow(highlight: note)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Wissenslandkarte löschen", systemImage: "trash")
                }
            } footer: {
                Text("Belege und Notizen bleiben erhalten.")
            }
        }
        .confirmationDialog("Wissenslandkarte löschen?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                dismiss()
                model.removeTrail(trail.id)
            }
        } message: {
            Text("Belege und Notizen bleiben erhalten.")
        }
    }
}

/// Zeigt, was schiefgegangen ist, und schliesst die Hörsession ab.
///
/// Zwei Befunde in einem: `lastError` wurde an fünfzehn Stellen gesetzt und
/// an keiner gelesen — jeder Fehler verschwand still. Und
/// `SessionClosureSheet` war geschrieben, aber nirgends eingehängt.
struct AppFeedbackModifier: ViewModifier {

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("Das hat nicht geklappt", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.clearError() } }
            )) {
                Button("OK") { model.clearError() }
            } message: {
                Text(model.lastError ?? "")
            }
            .sheet(isPresented: Binding(
                get: { model.pendingClosure != nil },
                set: { if !$0 { model.dismissClosure() } }
            )) {
                if let closure = model.pendingClosure {
                    SessionClosureSheet(closure: closure)
                        .environment(model)
                }
            }
    }
}

extension View {
    /// Fehlermeldung und Abschlusskarte, an einer Stelle je Plattform.
    func appFeedback() -> some View { modifier(AppFeedbackModifier()) }
}

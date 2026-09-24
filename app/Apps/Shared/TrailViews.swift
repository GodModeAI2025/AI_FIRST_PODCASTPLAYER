//
//  TrailViews.swift
//  PodcastAI
//
//  Gesicherte Antworten und die Abschlusskarte einer Hörsession, dazu die
//  Meldungen an der Wurzel und an jedem Blatt.
//
//  Eine gesicherte Antwort ist aufbewahrt, nicht zugestimmt. Das steht an
//  jeder Karte.
//

import SwiftUI
import PodcastAIKit

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
                            Text("Frage, Belege und die Notizen dieser Session als gesicherte Antwort ablegen.")
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
                            Text("Verwirft nur diesen Vorschlag. Gemerkte Stellen, Notizen und Belege bleiben.")
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

/// Gesicherte Antworten. Jede lässt sich öffnen und löschen.
struct TrailListView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.trails.isEmpty {
                ContentUnavailableView {
                    Label("Keine gesicherten Antworten", systemImage: "map")
                } description: {
                    Text("""
                        Eine gesicherte Antwort hält eine Frage mit ihren Belegen und Notizen fest. \
                        Im Chat steht an jeder Antwort „Antwort sichern“. \
                        Hörst du Belege nacheinander und beendest die Wiedergabe nach mindestens \
                        zwei Minuten, bietet die Abschlusskarte „Parken“ an.
                        """)
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
        .navigationTitle("Gesicherte Antworten")
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
        var parts = [String(AttributedString(localized: "^[\(count) Beleg](inflect: true)").characters)]
        if noteCount > 0 {
            parts.append(String(AttributedString(localized: "^[\(noteCount) Notiz](inflect: true)").characters))
        }
        let date = trail.parkedAt.formatted(date: .abbreviated, time: .omitted)
        parts.append(String(localized: "gesichert am \(date)"))
        return parts.joined(separator: " · ")
    }
}

/// Eine geöffnete gesicherte Antwort: Frage, Antwort, Belege zum Anhören und
/// die Notizen dazu. Abgespielt wird nur, was jemand antippt.
struct TrailDetailView: View {

    let trailID: KnowledgeNodeID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var evidence: [Evidence] = []
    @State private var origins: [EpisodeID: String] = [:]
    /// Länge je Folge, für „34:10 von 58:00“ an den Belegen.
    @State private var durations: [EpisodeID: MediaDuration] = [:]
    /// Der Beleg, zu dem ein Verweis im Antworttext gerade geführt hat.
    @State private var highlighted: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedCitation: Int?
    @State private var loaded = false
    @State private var confirmingDelete = false
    /// Folgen der Notizen, die es noch gibt. `nil`, solange das nicht
    /// geladen ist.
    @State private var availableEpisodes: Set<EpisodeID>?

    private var trail: KnowledgeTrail? { model.trails.first { $0.id == trailID } }

    var body: some View {
        Group {
            if let trail {
                content(trail)
            } else {
                ContentUnavailableView("Diese gesicherte Antwort gibt es nicht mehr", systemImage: "map")
            }
        }
        .navigationTitle("Gesicherte Antwort")
        .task(id: trail?.evidenceIDs) {
            guard let trail else { return }
            let found = await model.evidence(of: trail)
            origins = await model.citationOrigins(for: found)
            durations = (await model.citedEpisodes(for: found)).compactMapValues(\.duration)
            evidence = found
            loaded = true
        }
        .task(id: trail.map { model.notes(of: $0).compactMap(\.episodeID) }) {
            guard let trail else { return }
            availableEpisodes = await model.availableEpisodeIDs(for: model.notes(of: trail))
        }
        .task(id: highlighted) {
            // Die Hervorhebung zeigt nur, wo man gelandet ist, und geht wieder.
            guard highlighted != nil else { return }
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            withAnimation(motion) { highlighted = nil }
        }
    }

    private var motion: Animation {
        Design.Motion.respectingReduceMotion(Design.Motion.smooth, reduceMotion: reduceMotion)
    }

    private static func anchor(_ number: Int) -> String { "trail-citation-\(number)" }

    /// Ein Verweis im Text führt zu seinem Beleg, wie im Chat. Ton entsteht
    /// dabei nie, abgespielt wird erst, wenn jemand den Beleg antippt.
    private func showCitation(_ number: Int, proxy: ScrollViewProxy) {
        withAnimation(motion) {
            highlighted = number
            proxy.scrollTo(Self.anchor(number), anchor: .center)
        }
        focusedCitation = number
    }

    private func citationRow(number: Int, evidence item: Evidence) -> some View {
        CitationRow(number: number, evidence: item, origin: origins[item.episodeID],
                    highlighted: highlighted == number, episodeDuration: durations[item.episodeID])
            .id(Self.anchor(number))
            .accessibilityFocused($focusedCitation, equals: number)
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
        return ScrollViewReader { proxy in
            List {
                Section {
                    Text(trail.question)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if let answer = trail.answerText {
                        // Gegliedert wie im Chat, jeder Verweis führt zu seinem
                        // Beleg.
                        AnswerText(text: answer,
                                   citations: Set(items.map(\.number)),
                                   onCitation: { showCitation($0, proxy: proxy) })
                    }
                    Text("Gesichert am \(trail.parkedAt.formatted(date: .long, time: .omitted)). Aufbewahrt, nicht zugestimmt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !items.isEmpty || missing > 0 {
                    Section {
                        ForEach(items, id: \.number) { item in
                            citationRow(number: item.number, evidence: item.evidence)
                        }
                        playButton(trail, playable: playable)
                    } header: {
                        Text("Belege")
                    } footer: {
                        if missing == 1 {
                            Text("Ein Beleg ist nicht mehr da.")
                        } else if missing > 1 {
                            Text("\(missing) Belege sind nicht mehr da.")
                        }
                    }
                }

                if !notes.isEmpty {
                    Section("Notizen") {
                        ForEach(notes) { note in
                            noteRow(note)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Gesicherte Antwort löschen", systemImage: "trash")
                    }
                } footer: {
                    Text("Belege und Notizen bleiben erhalten.")
                }
            }
        }
        .confirmationDialog("Gesicherte Antwort löschen?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                dismiss()
                model.removeTrail(trail.id)
            }
        } message: {
            Text("Belege und Notizen bleiben erhalten.")
        }
    }

    @ViewBuilder
    private func playButton(_ trail: KnowledgeTrail, playable: Int) -> some View {
        if playable > 0 {
            Button {
                model.playTrail(trail)
            } label: {
                Label(playLabel(playable), systemImage: "play.circle")
                    .frame(minHeight: Design.minimumTapTarget)
            }
            .accessibilityHint("Spielt die belegten Originalstellen nacheinander ab")
        }
    }

    /// Abspielbar ist eine Notiz nur mit Folge und Zeitmarke, und nur,
    /// solange die Folge noch da ist. Sonst ist sie eine Zeile zum Lesen und
    /// sieht auch so aus, wie unter „Gemerkte Stellen“.
    @ViewBuilder
    private func noteRow(_ note: Highlight) -> some View {
        let gone = note.episodeID.map { id in availableEpisodes.map { !$0.contains(id) } ?? false } ?? false
        if note.episodeID != nil, note.positionMs != nil, !gone {
            Button { Task { await model.playHighlight(note) } } label: {
                NoteRow(highlight: note).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Spielt die Folge ab dieser Stelle")
        } else {
            NoteRow(highlight: note, episodeGone: gone)
        }
    }

    /// Mehr als eine Stelle heißt immer mindestens zwei, daher reicht der Plural.
    private func playLabel(_ playable: Int) -> LocalizedStringKey {
        playable == 1 ? "Diese Stelle anhören" : "Alle \(playable) Stellen nacheinander anhören"
    }
}

/// Zeigt, was schiefgegangen ist, und schließt die Hörsession ab.
///
/// Zwei Befunde in einem: `lastError` wurde an fünfzehn Stellen gesetzt und
/// an keiner gelesen — jeder Fehler verschwand still. Und
/// `SessionClosureSheet` war geschrieben, aber nirgends eingehängt.
struct AppFeedbackModifier: ViewModifier {

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            // Solange ein Blatt mit eigenen Meldungen offen ist, zeigt es sie.
            .modifier(AppAlerts(isActive: FeedbackHosts.shared.openSheets.isEmpty))
            .sheet(isPresented: Binding(
                get: { model.pendingClosure != nil },
                set: { if !$0 { model.dismissClosure() } }
            )) {
                if let closure = model.pendingClosure {
                    SessionClosureSheet(closure: closure)
                        .sheetFeedback()
                        .environment(model)
                }
            }
    }
}

/// Fehlermeldung und Mobilfunk-Rückfrage. Nur die Ansicht mit `isActive`
/// zeigt sie. Sonst hingen zwei Alerts am selben Zustand, und wer einen
/// davon schließt, schlösse auch den anderen.
struct AppAlerts: ViewModifier {

    @Environment(AppModel.self) private var model
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .alert("Das hat nicht geklappt", isPresented: Binding(
                get: { isActive && model.lastError != nil },
                set: { if !$0, isActive { model.clearError() } }
            )) {
                Button("OK") { model.clearError() }
            } message: {
                Text(model.lastError ?? "")
            }
            .modifier(MobileDataQuestion(isActive: isActive))
            .modifier(TranscriptNotificationQuestion(isActive: isActive))
    }
}

/// Welche Ansicht Fehlermeldung und Mobilfunk-Rückfrage zeigt.
///
/// Ein Alert erscheint nicht an einer Ansicht, über der schon ein Blatt
/// liegt, auf dem Mac so wenig wie auf dem iPhone. Hingen die Meldungen nur
/// an der Wurzel, warteten „Über Mobilfunk laden?“ und „Das hat nicht
/// geklappt“ hinter der Warteschlange oder dem Player, bis das Blatt zu war,
/// und „Abspielen“ oder „Nächste Folge“ schienen nichts zu tun. Deshalb
/// trägt jedes Blatt die Meldungen selbst (`sheetFeedback()`), und das
/// zuletzt geöffnete zeigt sie. Die Wurzel zeigt sie nur, solange keins
/// offen ist.
@MainActor @Observable
final class FeedbackHosts {

    static let shared = FeedbackHosts()

    /// Offene Blätter mit Meldungen, das zuletzt geöffnete am Ende.
    private(set) var openSheets: [UUID] = []

    func opened(_ id: UUID) {
        openSheets.removeAll { $0 == id }
        openSheets.append(id)
    }

    func closed(_ id: UUID) { openSheets.removeAll { $0 == id } }
}

/// Die Meldungen im Inhalt eines Blatts.
private struct SheetFeedbackModifier: ViewModifier {

    @State private var id = UUID()

    func body(content: Content) -> some View {
        let hosts = FeedbackHosts.shared
        content
            .modifier(AppAlerts(isActive: hosts.openSheets.last == id))
            .onAppear { hosts.opened(id) }
            .onDisappear { hosts.closed(id) }
    }
}

extension View {
    /// Fehlermeldung, Mobilfunk-Rückfrage und Abschlusskarte an der Wurzel,
    /// an einer Stelle je Plattform.
    func appFeedback() -> some View { modifier(AppFeedbackModifier()) }

    /// Für den Inhalt jedes Blatts, vor `.environment(model)`: Fehlermeldung
    /// und Mobilfunk-Rückfrage erscheinen dann über dem Blatt statt erst,
    /// wenn es zu ist.
    func sheetFeedback() -> some View { modifier(SheetFeedbackModifier()) }
}

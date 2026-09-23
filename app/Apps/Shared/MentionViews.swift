//
//  MentionViews.swift
//  PodcastAI
//
//  „Erwähnt“ in der Folge: im Überblick eine Zeile mit der Zusammenfassung
//  („3 Links, 2 Termine, 1 Adresse“), dahinter die ganze Liste nach Art.
//
//  Links öffnen im Browser, Adressen und Orte in Karten, Telefonnummern
//  rufen an, E-Mail-Adressen öffnen eine neue Mail. Termine kommen auf dem
//  iPhone und iPad über das Blatt des Systems in den Kalender, ohne dass die
//  App Zugriff auf den Kalender braucht. Auf dem Mac öffnet der Kalender
//  eine Termindatei. Jede Stelle aus dem Transkript nennt ihre Zeitmarke
//  und spielt auf Tippen genau dort. Von selbst spielt hier nichts.
//

import SwiftUI
import PodcastAIKit
#if os(iOS)
import EventKit
import EventKitUI
#elseif os(macOS)
import AppKit
#endif

/// Der Abschnitt „Erwähnt“ im Überblick einer Folge.
struct MentionsOverviewSection: View {
    let episode: Episode
    let mentions: EpisodeMentions

    var body: some View {
        SwiftUI.Section {
            NavigationLink {
                MentionsListView(episode: episode, mentions: mentions)
            } label: {
                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    if let main = MentionSummary.text(mentions.mentions, kinds: Self.actionable) {
                        Text(main)
                    }
                    if let names = MentionSummary.text(mentions.mentions, kinds: Self.names) {
                        Text(names)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
            }
            .accessibilityIdentifier("episode.mentions")
            .accessibilityHint("Zeigt alle Links, Termine, Adressen und Namen der Folge")
        } header: {
            Text("Erwähnt")
        } footer: {
            if !mentions.hasTranscript {
                Text("Bisher aus den Shownotes. Mit dem Transkript kommt mehr dazu.")
            }
        }
    }

    static let actionable: Set<Mention.Kind> = [.link, .date, .address, .phone, .email]
    static let names: Set<Mention.Kind> = [.person, .organization, .place]
}

/// Alle Nennungen einer Folge, nach Art.
struct MentionsListView: View {
    let episode: Episode
    let mentions: EpisodeMentions
    @State private var calendarDraft: CalendarDraft?

    private var kinds: [Mention.Kind] {
        MentionSummary.counts(mentions.mentions).map { $0.kind }
    }

    var body: some View {
        List {
            if !mentions.hasTranscript {
                SwiftUI.Section {
                    Label {
                        Text("Bisher nur aus den Shownotes. Mit dem Transkript kommt mehr dazu, mit Zeitmarke.")
                    } icon: {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(kinds, id: \.self) { kind in
                SwiftUI.Section {
                    ForEach(mentions.mentions.filter { $0.kind == kind }) { mention in
                        MentionRow(mention: mention, episode: episode) {
                            calendarDraft = CalendarDraft(mention: mention, episode: episode,
                                                          addresses: mentions.mentions.filter { $0.kind == .address })
                        }
                    }
                } header: {
                    Label {
                        Text(kind.label)
                    } icon: {
                        Image(systemName: kind.symbol).accessibilityHidden(true)
                    }
                }
            }
        }
        .navigationTitle("Erwähnt")
        .accessibilityIdentifier("mentions.list")
        #if os(iOS)
        .sheet(item: $calendarDraft) { draft in
            CalendarEventEditor(draft: draft) { calendarDraft = nil }
                .ignoresSafeArea()
        }
        #elseif os(macOS)
        .onChange(of: calendarDraft?.id) {
            // Auf dem Mac gibt es das Blatt des Systems nicht. Der Kalender
            // öffnet die Termindatei und fragt selbst, wohin.
            guard let draft = calendarDraft else { return }
            draft.openInCalendarApp()
            calendarDraft = nil
        }
        #endif
    }
}

/// Ein Wert mit seiner Aktion und seinen Stellen.
struct MentionRow: View {
    let mention: Mention
    let episode: Episode
    let addToCalendar: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.confirm) private var confirm

    /// Mehr Stellen stehen nicht untereinander, der Rest wird gezählt.
    private static let shownOccurrences = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(mention.title)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if mention.kind == .date, mention.isVague {
                    Text("Ungefähr, gesagt: „\(mention.display)“")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let action {
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.symbol)
                        .font(.callout)
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("mention.action")
            }
            ForEach(Array(mention.occurrences.prefix(Self.shownOccurrences).enumerated()), id: \.offset) { _, occurrence in
                MentionOccurrenceRow(occurrence: occurrence, episode: episode)
            }
            if mention.occurrences.count > Self.shownOccurrences {
                Text("Dazu \(mention.occurrences.count - Self.shownOccurrences) weitere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Design.Spacing.micro)
        .contextMenu {
            Button {
                Clipboard.copy(mention.kind == .date ? mention.title : mention.display)
                confirm(NoteFeedback.copied)
            } label: {
                Label("Kopieren", systemImage: "doc.on.doc")
            }
            if let action {
                Button(action: action.perform) { Label(action.title, systemImage: action.symbol) }
            }
        }
    }

    private struct Action {
        let title: LocalizedStringKey
        let symbol: String
        let perform: () -> Void
    }

    /// Was ein Tipp auf den Knopf tut. Namen von Personen und
    /// Organisationen haben keine Aktion, Orte öffnen Karten.
    private var action: Action? {
        switch mention.kind {
        case .link:
            guard let url = mention.url else { return nil }
            return Action(title: "Im Browser öffnen", symbol: "safari") { openURL(url) }
        case .email:
            guard let url = mention.url else { return nil }
            return Action(title: "E-Mail schreiben", symbol: "envelope") { openURL(url) }
        case .phone:
            guard let url = mention.url else { return nil }
            return Action(title: "Anrufen", symbol: "phone") { openURL(url) }
        case .address, .place:
            guard let url = mention.url else { return nil }
            return Action(title: "In Karten öffnen", symbol: "map") { openURL(url) }
        case .date:
            guard mention.date != nil else { return nil }
            return Action(title: "In den Kalender", symbol: "calendar.badge.plus", perform: addToCalendar)
        case .person, .organization:
            return nil
        }
    }
}

/// Eine Stelle: aus den Shownotes oder mit Zeitmarke aus dem Transkript.
/// Nur die Stelle aus dem Transkript ist ein Knopf, und nur ein Tipp spielt.
private struct MentionOccurrenceRow: View {
    let occurrence: Mention.Occurrence
    let episode: Episode
    @Environment(AppModel.self) private var model

    var body: some View {
        if let time = occurrence.time, model.canPlay(episode) {
            Button {
                model.playEpisode(episode, at: time.seconds)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                    HStack(spacing: Design.Spacing.micro) {
                        TimecodeLabel(time)
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    contextText
                }
                .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Spielt die Folge ab dieser Stelle")
            .accessibilityIdentifier("mention.occurrence")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                if let time = occurrence.time {
                    TimecodeLabel(time)
                } else {
                    Text("Shownotes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                contextText
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var contextText: some View {
        Text(occurrence.context)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Kalender

/// Ein Termin zum Anlegen. Titel ist der Satz, in dem er fiel, die Notiz
/// nennt Folge, Podcast und Zeitmarke. Angelegt wird erst im Blatt des
/// Systems, nach dem Tippen auf „Hinzufügen“.
struct CalendarDraft: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let allDay: Bool
    let notes: String
    let url: URL?
    let location: String?

    @MainActor
    init?(mention: Mention, episode: Episode, addresses: [Mention]) {
        guard let date = mention.date else { return nil }
        let occurrence = mention.occurrences.first
        let context = occurrence?.context.trimmingCharacters(in: CharacterSet(charactersIn: "… ")) ?? ""
        title = context.isEmpty ? episode.title : String(context.prefix(90))
        start = date
        allDay = !mention.hasTime
        var lines = [String(localized: "Erwähnt in „\(episode.title)“.")]
        if let time = occurrence?.time {
            lines.append(String(localized: "Stelle in der Folge: \(time.timecode)"))
        }
        if mention.isVague {
            lines.append(String(localized: "Das Datum ist ungefähr, gesagt wurde: „\(mention.display)“"))
        }
        if !context.isEmpty { lines.append("„\(context)“") }
        notes = lines.joined(separator: "\n")
        url = episode.webPageURL
        location = addresses.first { address in
            mention.occurrences.contains { $0.context.contains(address.display) }
        }?.display
    }

    #if os(macOS)
    /// Legt eine Termindatei an und öffnet sie im Kalender.
    func openInCalendarApp() {
        let text = CalendarFile.event(title: title, start: start, allDay: allDay, notes: notes,
                                      url: url, location: location)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAI-Termin-\(id.uuidString).ics")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            NSLog("Termindatei konnte nicht angelegt werden: %@", error.localizedDescription)
        }
    }
    #endif
}

#if os(iOS)
/// Das Blatt des Systems zum Anlegen eines Termins. Seit iOS 17 läuft es
/// außerhalb der App und braucht keinen Zugriff auf den Kalender: Die App
/// sieht keine Termine, und es erscheint keine Frage nach der Erlaubnis.
struct CalendarEventEditor: UIViewControllerRepresentable {
    let draft: CalendarDraft
    let finish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.allDay ? draft.start : draft.start.addingTimeInterval(3_600)
        event.isAllDay = draft.allDay
        event.notes = draft.notes
        event.url = draft.url
        event.location = draft.location
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            finish()
        }
    }
}
#endif

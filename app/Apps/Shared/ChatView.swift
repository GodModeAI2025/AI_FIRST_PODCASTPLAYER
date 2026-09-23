//
//  ChatView.swift
//  PodcastAI
//
//  Fragen an eine Folge oder an alles, was erschlossen ist.
//
//  Der Bereich steht sichtbar oben, damit klar ist, worüber gesprochen wird.
//  Jede Antwort nennt ihre Belege mit Nummer und springt auf Wunsch an die
//  Stelle im Originalton. Antworten lassen sich als Markdown exportieren.
//

import SwiftUI
import PodcastAIKit

struct ChatView: View {

    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var isAsking = false
    /// Im eigenständigen Chat: gilt die Frage der Folge, die gerade läuft?
    @State private var followsPlayer = false
    /// Eingrenzung der Mediathek auf einen Podcast und einen Zeitraum.
    @State private var filter = LibraryFilter()
    /// Innerhalb einer Folge ist der Bereich fest.
    private let pinnedScope: ChatScope?
    private var fixedScope: Bool { pinnedScope != nil }

    /// Mit `fixed` gilt `scope` fest. Ohne beginnt der Chat bei allem
    /// Erschlossenen, und der Nutzer kann zur laufenden Folge wechseln.
    init(scope: ChatScope = .allAnalyzed, fixed: Bool = false) {
        pinnedScope = fixed ? scope : nil
    }

    /// Der Bereich, für den gerade gefragt wird. Folgt der Chat der
    /// laufenden Folge, ist es immer die, die gerade spielt. Spielt nichts,
    /// gilt alles Erschlossene. So zeigen Auswahl, Antworten und Frage
    /// stets auf dieselbe Folge.
    private var scope: ChatScope {
        if let pinnedScope { return pinnedScope }
        if followsPlayer, let playing = model.episodePlayer.episode { return .episode(playing.id) }
        return filter.isUnrestricted ? .allAnalyzed : .library(filter)
    }

    private var answers: [ChatAnswer] {
        model.chatAnswers.filter { $0.scope == scope }
    }

    var body: some View {
        VStack(spacing: Design.Spacing.none) {
            if !fixedScope {
                ScopeBar(followsPlayer: $followsPlayer, filter: $filter)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Spacing.section) {
                    if answers.isEmpty {
                        ChatEmptyState(scope: scope) { suggestion in
                            question = suggestion
                            ask()
                        }
                        .padding(.top, fixedScope ? Design.Spacing.standard : Design.Spacing.large)
                    }
                    ForEach(answers) { answer in
                        AnswerCard(answer: answer)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            askField
        }
        .modifier(ChatTitle(show: !fixedScope))
        .onChange(of: model.episodePlayer.episode?.id) { _, playing in
            // Endet die Wiedergabe, bleibt der Chat bei allem Erschlossenen
            // und springt nicht mit der nächsten Folge von selbst zurück.
            if playing == nil { followsPlayer = false }
        }
        .onChange(of: model.sources.map(\.id)) { _, sources in
            // Ein abbestellter Podcast kann nicht mehr Bereich sein.
            if let id = filter.sourceID, !sources.contains(id) { filter.sourceID = nil }
        }
    }

    /// Das Eingabefeld schwebt als Bedienelement über dem Inhalt.
    private var askField: some View {
        HStack(spacing: Design.Spacing.small) {
            inputField
                .textFieldStyle(.plain)
                .onSubmit(ask)
                .accessibilityLabel("Frage")
                .accessibilityIdentifier("chat.input")

            Button(action: ask) {
                Image(systemName: isAsking ? "ellipsis" : "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolEffect(.pulse, isActive: isAsking)
                    .tappableArea()
            }
            .buttonStyle(.pressable)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
            .accessibilityLabel("Frage senden")
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.small)
        .glassEffect(.regular, in: .capsule)
        .padding(Design.Spacing.control)
    }

    @ViewBuilder private var inputField: some View {
        let prompt: LocalizedStringKey = fixedScope ? "Frage zu dieser Folge …" : "Frage stellen …"
        #if os(iOS)
        // Einzeilig: in einem mitwachsenden Feld schreibt Return auf dem
        // iPhone eine neue Zeile, statt die Frage zu senden.
        TextField(prompt, text: $question)
            .submitLabel(.send)
        #else
        TextField(prompt, text: $question, axis: .vertical)
            .lineLimit(1...4)
        #endif
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        question = ""
        isAsking = true
        let currentScope = scope
        Task {
            // Das Modell nimmt die Antwort selbst in den Verlauf auf. Nur dort
            // lässt sich prüfen, ob während der Suche eine Folge gelöscht wurde.
            if let answer = await model.ask(text, scope: currentScope) {
                // Wer nicht auf den Bildschirm sieht, erfährt so, dass die Antwort steht.
                let count = answer.citations.count
                AccessibilityNotification.Announcement(
                    count == 0
                        ? AttributedString(localized: "Antwort da")
                        : AttributedString(localized: "Antwort da, ^[\(count) Beleg](inflect: true)")
                ).post()
            }
            isAsking = false
        }
    }
}

/// Eigenständig trägt der Chat den Titel „Frag deine Podcasts“. Innerhalb
/// einer Folge bleibt deren Titel stehen.
private struct ChatTitle: ViewModifier {
    let show: Bool
    func body(content: Content) -> some View {
        if show { content.navigationTitle("Frag deine Podcasts").activityStatusToolbar() } else { content }
    }
}

/// Der Bereich steht oben und ist jederzeit änderbar: die ganze Mediathek,
/// ein Podcast, ein Zeitraum oder die laufende Folge.
struct ScopeBar: View {

    @Binding var followsPlayer: Bool
    @Binding var filter: LibraryFilter
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Menu {
                // Die Auswahl zeigt „Laufende Folge“ nur, solange eine läuft.
                // Sonst gäbe es keinen passenden Eintrag.
                Picker("Bereich", selection: Binding(
                    get: { followsPlayer && currentTitle != nil ? ScopeChoice.currentEpisode : .allAnalyzed },
                    set: { followsPlayer = $0 == .currentEpisode }
                )) {
                    Text("Meine Podcasts").tag(ScopeChoice.allAnalyzed)
                    if let title = currentTitle {
                        Text("Laufende Folge: \(title)").tag(ScopeChoice.currentEpisode)
                    }
                }
                .pickerStyle(.inline)

                // Podcast und Zeitraum gelten für die Mediathek. Wer sie
                // wählt, fragt nicht mehr die laufende Folge.
                if !model.sources.isEmpty {
                    Picker("Podcast", selection: Binding(
                        get: { filter.sourceID },
                        set: { filter.sourceID = $0; followsPlayer = false }
                    )) {
                        Text("Alle Podcasts").tag(SourceID?.none)
                        ForEach(model.sources) { source in
                            Text(source.title).tag(SourceID?.some(source.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Picker("Zeitraum", selection: Binding(
                    get: { filter.period },
                    set: { filter.period = $0; followsPlayer = false }
                )) {
                    ForEach(LibraryFilter.Period.allCases, id: \.self) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.menu)
            } label: {
                Label(summary, systemImage: "scope")
                    .lineLimit(1)
            }
            .accessibilityLabel("Bereich: \(summary)")
            .accessibilityIdentifier("chat.scope")
            Spacer()
            if let label = model.modelStatus.resolveLabel {
                Label(label, systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, Design.Spacing.control)
        .padding(.vertical, Design.Spacing.small)
    }

    private var currentTitle: String? {
        model.episodePlayer.episode.map { String($0.title.prefix(40)) }
    }

    /// Was gerade gefragt wird, in einer Zeile.
    private var summary: String {
        if followsPlayer, let title = currentTitle { return String(localized: "Laufende Folge: \(title)") }
        if filter.isUnrestricted { return ChatScope.allAnalyzed.label }
        return model.scopeLabel(.library(filter))
    }

    enum ScopeChoice: Hashable {
        case allAnalyzed, currentEpisode
    }
}

extension ModelStatus {
    /// Kurzform für die Anzeige, womit geantwortet wird.
    var resolveLabel: String? {
        switch resolve(.answer) {
        case .success(let tier):
            tier == .privateCloudCompute
                ? String(localized: "Private Cloud Compute")
                : String(localized: "Auf dem Gerät")
        case .failure: nil
        }
    }
}

struct ChatEmptyState: View {

    let scope: ChatScope
    var suggest: (String) -> Void = { _ in }

    private var suggestions: [String] {
        switch scope {
        case .episode:
            [String(localized: "Worum geht es in dieser Folge?"),
             String(localized: "Was sind die wichtigsten Aussagen?"),
             String(localized: "Welche Zahlen und Namen werden genannt?"),
             String(localized: "Wo sind sich die Gesprächspartner uneinig?")]
        default:
            [String(localized: "Welche Folgen behandeln künstliche Intelligenz?"),
             String(localized: "Was wurde zuletzt über Datenschutz gesagt?"),
             String(localized: "Welche Folgen mit Transkript habe ich noch nicht gehört?"),
             String(localized: "Wo widersprechen sich zwei Podcasts?")]
        }
    }

    private var title: LocalizedStringKey {
        scope.isEpisode ? "Frag diese Folge" : "Frag deine Podcasts"
    }

    var body: some View {
        VStack(spacing: Design.Spacing.control) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text("""
                Jede Antwort nennt die Stellen, aus denen sie stammt. \
                Ein Tipp auf einen Beleg spielt die Stelle im Original.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: Design.Spacing.small) {
                ForEach(suggestions, id: \.self) { text in
                    Button { suggest(text) } label: {
                        Text(text)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Design.Spacing.control)
                            .padding(.vertical, Design.Spacing.small)
                            .background(.tint.opacity(0.1), in: .rect(cornerRadius: Design.Radius.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Stellt diese Frage")
                }
            }
            .padding(.top, Design.Spacing.small)
        }
        .padding(.horizontal, Design.Spacing.standard)
    }
}

extension ChatScope {
    var isEpisode: Bool { if case .episode = self { return true } else { return false } }
}

struct AnswerCard: View {

    let answer: ChatAnswer
    @Environment(AppModel.self) private var model
    @State private var exported: String?
    /// „Podcast · Folge · Datum“ je Folge. Innerhalb einer Folge leer.
    @State private var origins: [EpisodeID: String] = [:]

    private var numbered: [(number: Int, evidence: Evidence)] {
        let byID = Dictionary(answer.citations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairs = answer.citationNumbers.sorted { $0.key < $1.key }.compactMap { number, id in
            byID[id].map { (number: number, evidence: $0) }
        }
        if !pairs.isEmpty { return pairs }
        return answer.citations.enumerated().map { (number: $0.offset + 1, evidence: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            HStack(alignment: .firstTextBaseline) {
                Text(answer.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button {
                        Task { exported = await model.exportAnswer(answer) }
                    } label: { Label("Als Markdown exportieren", systemImage: "square.and.arrow.up") }
                    Button {
                        copy(answer.text)
                    } label: { Label("Antwort kopieren", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis.circle").tappableArea()
                }
                .accessibilityLabel("Antwort teilen")
            }

            Text(answer.text)
                .font(.body)
                .textSelection(.enabled)

            HStack(spacing: Design.Spacing.small) {
                if let label = answer.modelLabel {
                    Label(label, systemImage: "sparkles")
                }
                if !answer.scope.isEpisode {
                    Label(model.scopeLabel(answer.scope), systemImage: "scope")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let caveat = answer.coverageCaveat {
                Label(caveat, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !numbered.isEmpty {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    ForEach(numbered, id: \.number) { item in
                        CitationRow(number: item.number, evidence: item.evidence,
                                    origin: origins[item.evidence.episodeID])
                    }
                }
                .padding(.top, Design.Spacing.micro / 2)
            }

            if !answer.playableCitations.isEmpty {
                Button {
                    model.playAnswer(answer)
                } label: {
                    Label(playLabel, systemImage: "play.circle")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Spielt die belegten Originalstellen nacheinander ab")
            }

            // Jede echte Antwort lässt sich sichern. Ein reiner Hinweis ohne
            // Beleg und ohne Modell („noch kein Transkript“) nicht.
            if !answer.citations.isEmpty || answer.modelLabel != nil {
                Button {
                    model.park(answer)
                } label: {
                    Label(saveLabel, systemImage: isParked ? "checkmark.circle" : "map")
                        .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.borderless)
                .disabled(isParked)
                .accessibilityHint("Legt Frage, Antwort, Belege und die Notizen zu diesen Stellen unter „Gesicherte Antworten“ ab")
                .accessibilityIdentifier("chat.saveTrail")
            }
        }
        .contentCard()
        .task(id: answer.id) {
            // Innerhalb einer Folge ist die Herkunft klar.
            guard !answer.scope.isEpisode else { return }
            origins = await model.citationOrigins(for: answer.citations)
        }
        .sheet(item: Binding(
            get: { exported.map(ExportPreview.init) },
            set: { exported = $0?.text }
        )) { preview in
            ExportPreviewSheet(text: preview.text)
        }
    }

    private var isParked: Bool { model.isParked(answer) }

    private var saveLabel: LocalizedStringKey {
        isParked ? "Antwort gesichert" : "Antwort sichern"
    }

    /// Mehr als eine Stelle heisst immer mindestens zwei, daher reicht der Plural.
    private var playLabel: LocalizedStringKey {
        let count = answer.playableCitations.count
        return count == 1 ? "Diese Stelle anhören" : "Alle \(count) Stellen nacheinander anhören"
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Ein Beleg mit Nummer, Herkunft, Zitat und Zeitmarke.
///
/// Nur ein Beleg mit Zeitbereich ist ein Knopf. Ohne Zeitmarke gibt es
/// nichts abzuspielen, und die Zeile tut auch nicht so.
struct CitationRow: View {

    var number: Int = 0
    let evidence: Evidence
    /// „Podcast · Folge · Datum“. Fehlt innerhalb einer Folge.
    var origin: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if evidence.isPlayable, let range = evidence.range {
                Button {
                    Task { await model.playEvidenceInEpisode(evidence, at: range.start.seconds) }
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityHint("Spielt die Folge ab dieser Stelle")
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
        .contextMenu {
            // Gemerkt wird genau dieser Beleg: sein Wortlaut, seine Zeit.
            if evidence.range != nil {
                Button {
                    Task { await model.rememberEvidence(evidence, via: .chat) }
                } label: {
                    Label("Stelle merken", systemImage: "bookmark")
                }
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Text(number > 0 ? number.formatted() : "")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .background(evidence.isPlayable ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray), in: .circle)
            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                if let origin {
                    Text(origin)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(evidence.quotedText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let range = evidence.range, evidence.isPlayable {
                    HStack(spacing: Design.Spacing.micro) {
                        TimecodeLabel(range)
                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.tint)
                    }
                } else if let range = evidence.range {
                    HStack(spacing: Design.Spacing.micro) {
                        TimecodeLabel(range.start)
                        Text("· nicht abspielbar")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Ohne Zeitmarke, nicht abspielbar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
    }
}

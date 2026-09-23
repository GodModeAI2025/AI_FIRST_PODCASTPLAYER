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
import NaturalLanguage
import Translation
import PodcastAIKit

struct ChatView: View {

    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var isAsking = false
    /// Die Frage, auf die gerade eine Antwort gesucht wird, und ihr Bereich.
    /// Sie steht unten im Verlauf, dort, wo die Antwort erscheinen wird.
    @State private var pending: (question: String, scope: ChatScope)?
    /// Eine neue Antwort bekommt den VoiceOver-Fokus.
    @AccessibilityFocusState private var focusedAnswer: UUID?
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

            // Der Verlauf liest sich von oben nach unten: die neueste Antwort
            // steht unten, und die Ansicht springt an ihren Anfang.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Design.Spacing.section) {
                        if answers.isEmpty && pendingQuestion == nil {
                            ChatEmptyState(scope: scope) { suggestion in
                                question = suggestion
                                ask()
                            }
                            .padding(.top, fixedScope ? Design.Spacing.standard : Design.Spacing.large)
                        }
                        ForEach(answers) { answer in
                            // Über dem Verlauf stehen Bereich und Modell schon
                            // in der Leiste. Die Antwort wiederholt sie nicht.
                            AnswerCard(answer: answer, focus: $focusedAnswer,
                                       scrollProxy: proxy, contextShownAbove: !fixedScope)
                                .id(answer.id)
                        }
                        if let pendingQuestion {
                            PendingAnswerCard(question: pendingQuestion)
                                .id(Self.pendingID)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: pendingQuestion) { _, waiting in
                    guard waiting != nil else { return }
                    withAnimation { proxy.scrollTo(Self.pendingID, anchor: .bottom) }
                }
                .onChange(of: answers.last?.id) { _, newest in
                    guard let newest else { return }
                    withAnimation { proxy.scrollTo(newest, anchor: .top) }
                }
            }

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
                Group {
                    if isAsking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .tappableArea()
            }
            .buttonStyle(.pressable)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
            .accessibilityLabel(sendLabel)
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.small)
        .glassEffect(.regular, in: .capsule)
        .padding(Design.Spacing.control)
    }

    /// Solange gesucht wird, sagt der Knopf das, statt weiter „senden“ zu heißen.
    private var sendLabel: LocalizedStringKey {
        isAsking ? "Antwort wird gesucht" : "Frage senden"
    }

    /// Die wartende Frage, nur im Bereich, in dem sie gestellt wurde.
    private var pendingQuestion: String? {
        guard let pending, pending.scope == scope else { return nil }
        return pending.question
    }

    private static let pendingID = "chat.pending"

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
        pending = (question: text, scope: currentScope)
        Task {
            // Das Modell nimmt die Antwort selbst in den Verlauf auf. Nur dort
            // lässt sich prüfen, ob während der Suche eine Folge gelöscht wurde.
            let answer = await model.ask(text, scope: currentScope)
            pending = nil
            isAsking = false
            if let answer {
                // VoiceOver springt auf die neue Antwort und liest sie vor.
                focusedAnswer = answer.id
                // Wer nicht auf den Bildschirm sieht, erfährt so, dass die
                // Antwort steht. Nachrangig, damit die Antwort selbst zuerst kommt.
                let count = answer.citations.count
                var message = count == 0
                    ? AttributedString(localized: "Antwort da")
                    : AttributedString(localized: "Antwort da, ^[\(count) Beleg](inflect: true)")
                message.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(message).post()
            }
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
                // Name auch an der Beschriftung: ein Menü im Inhalt bringt
                // einen eigenen Knopf dafür mit, der sonst leer blieb.
                Label {
                    Text(summary)
                } icon: {
                    Image(systemName: "scope").accessibilityHidden(true)
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Bereich: \(summary)")
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
        // „Welche Links …“ und „Welche Termine …“ beantworten die erkannten
        // Nennungen, auch ohne Apple Intelligence.
        case .episode:
            [String(localized: "Worum geht es in dieser Folge?"),
             String(localized: "Was sind die wichtigsten Aussagen?"),
             String(localized: "Welche Links werden genannt?"),
             String(localized: "Welche Termine kommen vor?"),
             String(localized: "Welche Zahlen und Namen werden genannt?"),
             String(localized: "Wo sind sich die Gesprächspartner uneinig?")]
        default:
            [String(localized: "Welche Folgen behandeln künstliche Intelligenz?"),
             String(localized: "Was wurde zuletzt über Datenschutz gesagt?"),
             String(localized: "Welche Links werden genannt?"),
             String(localized: "Welche Termine kommen vor?"),
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

/// Die gestellte Frage, solange ihre Antwort gesucht wird.
private struct PendingAnswerCard: View {
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            Text(question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Design.Spacing.small) {
                ProgressView()
                Text("Antwort wird gesucht …")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .accessibilityElement(children: .combine)
    }
}

struct AnswerCard: View {

    let answer: ChatAnswer
    /// Welche Antwort den VoiceOver-Fokus bekommt.
    var focus: AccessibilityFocusState<UUID?>.Binding
    /// Führt von einem Verweis im Text zu seinem Beleg.
    var scrollProxy: ScrollViewProxy?
    /// Stehen Bereich und Modell schon in der Leiste über dem Verlauf?
    var contextShownAbove = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exported: String?
    /// Podcast, Folge, Datum und Cover je Folge. Innerhalb einer Folge leer.
    @State private var episodes: [EpisodeID: CitedEpisode] = [:]
    /// Folgen, deren Stellen ganz aufgeklappt sind.
    @State private var expanded: Set<EpisodeID> = []
    /// Der Beleg, zu dem ein Verweis im Text gerade geführt hat.
    @State private var highlighted: Int?
    @State private var showingCoverageInfo = false
    @AccessibilityFocusState private var focusedCitation: Int?

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
                    // Das Symbol hiess für VoiceOver nur „Weitere“.
                    Image(systemName: "ellipsis.circle")
                        .tappableArea()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Antwort teilen oder kopieren")
                }
                .accessibilityLabel("Antwort teilen oder kopieren")
            }

            AnswerText(text: answer.text, citations: Set(numbered.map(\.number)),
                       focus: focus, answerID: answer.id, onCitation: showCitation)

            if let caveat = answer.coverageCaveat {
                coverageNote(caveat)
            }

            // Der Bereich steht immer in der Leiste oder ist die Folge selbst.
            // Das Modell nur dann, wenn keine Leiste es nennt oder die
            // Antwort mit einem anderen entstand als dem, das sie jetzt zeigt.
            if let label = answer.modelLabel,
               !contextShownAbove || label != model.modelStatus.resolveLabel {
                Label(label, systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !numbered.isEmpty {
                citationList
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
                    // Das Symbol ist Schmuck. VoiceOver las „Karte einblenden“.
                    Label {
                        Text(saveLabel)
                    } icon: {
                        Image(systemName: isParked ? "checkmark.circle" : "map").accessibilityHidden(true)
                    }
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
            episodes = await model.citedEpisodes(for: answer.citations)
        }
        .task(id: highlighted) {
            // Die Hervorhebung zeigt nur, wo man gelandet ist, und geht wieder.
            guard highlighted != nil else { return }
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            withAnimation(motion) { highlighted = nil }
        }
        .sheet(item: Binding(
            get: { exported.map(ExportPreview.init) },
            set: { exported = $0?.text }
        )) { preview in
            ExportPreviewSheet(text: preview.text).sheetFeedback()
        }
    }

    /// Die Belege, eine Karte je Folge. Innerhalb einer Folge ohne Kopf,
    /// denn welche Folge gemeint ist, steht schon über dem Chat.
    private var citationList: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Belege")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(groups) { group in
                CitedEpisodeCard(
                    items: group.items,
                    episode: episodes[group.id],
                    showsHeader: !answer.scope.isEpisode,
                    isExpanded: Binding(
                        get: { expanded.contains(group.id) },
                        set: { open in
                            if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
                        }),
                    highlighted: highlighted,
                    anchor: citationAnchor,
                    focusedCitation: $focusedCitation)
            }
        }
    }

    /// Belege je Folge, in der Reihenfolge ihrer ersten Nummer.
    private var groups: [CitationGroup] { CitationGroup.grouping(numbered) }

    /// Wie viel durchsucht wurde, als ruhige Zeile. Ein Tipp erklärt, warum.
    private func coverageNote(_ caveat: String) -> some View {
        Button {
            showingCoverageInfo = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.micro) {
                Text(caveat)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Erklärt, warum nur Folgen mit Transkript durchsucht werden")
        .popover(isPresented: $showingCoverageInfo) {
            CoverageExplanation()
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Ein Verweis im Text führt zu seinem Beleg: aufklappen, hinscrollen,
    /// kurz hervorheben. Ton entsteht dabei nie. Abgespielt wird erst, wenn
    /// jemand den Beleg selbst antippt.
    private func showCitation(_ number: Int) {
        guard let group = groups.first(where: { $0.items.contains { $0.number == number } }),
              let position = group.items.firstIndex(where: { $0.number == number }) else { return }
        let hidden = !expanded.contains(group.id)
            && group.items.count > CitedEpisodeCard.collapsedCount
            && position >= CitedEpisodeCard.collapsedCount
        withAnimation(motion) {
            if hidden { expanded.insert(group.id) }
            highlighted = number
        }
        Task { @MainActor in
            // Eine eben aufgeklappte Stelle steht erst nach dem nächsten Layout.
            if hidden { try? await Task.sleep(for: .milliseconds(80)) }
            withAnimation(motion) {
                scrollProxy?.scrollTo(citationAnchor(number), anchor: .center)
            }
            focusedCitation = number
        }
    }

    /// Je Antwort eigen: zwei Antworten können dieselbe Stelle belegen.
    private func citationAnchor(_ number: Int) -> String {
        "\(answer.id.uuidString)-citation-\(number)"
    }

    private var motion: Animation {
        Design.Motion.respectingReduceMotion(Design.Motion.smooth, reduceMotion: reduceMotion)
    }

    private var isParked: Bool { model.isParked(answer) }

    private var saveLabel: LocalizedStringKey {
        isParked ? "Antwort gesichert" : "Antwort sichern"
    }

    /// Mehr als eine Stelle heißt immer mindestens zwei, daher reicht der Plural.
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
///
/// Ein Beleg in einer anderen Sprache als die App bietet „Übersetzen“ an.
/// Die Übersetzung erscheint darüber, der Beleg bleibt im Wortlaut.
struct CitationRow: View {

    var number: Int = 0
    let evidence: Evidence
    /// „Podcast · Folge · Datum“. Fehlt innerhalb einer Folge und in der
    /// Belegkarte einer Folge, die das schon im Kopf trägt.
    var origin: String?
    /// Kurz hinterlegt, wenn ein Verweis im Antworttext hierher geführt hat.
    var highlighted = false
    @Environment(AppModel.self) private var model
    @State private var foreign = false
    @State private var translating = false

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
            if foreign {
                TranslateTextButton(isPresented: $translating)
            }
        }
        .translationPresentation(isPresented: $translating, text: evidence.quotedText)
        .task(id: evidence.id) { foreign = AppLanguage.current.isForeign(evidence.quotedText) }
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
        // Über die ganze Breite: so trifft ein Tipp die Zeile überall, und
        // die Hervorhebung reicht von Rand zu Rand.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // Die Fläche ragt über den Rand hinaus, damit die Zeile beim
        // Hervorheben nicht springt.
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(.tint.opacity(highlighted ? 0.15 : 0))
                .padding(-Design.Spacing.micro)
        }
    }
}

// MARK: - Antwort gegliedert

/// Der Antworttext in Abschnitten: zuerst die direkte Antwort, dann Absätze
/// oder Punkte. Jeder Verweis wie [3] ist ein Link zu seinem Beleg.
///
/// Der Text ist Modellformulierung und damit fremde Daten. Er wird nie als
/// Markdown gelesen, Links entstehen nur aus Verweisnummern mit Beleg, und
/// jeder andere Link wird verworfen.
private struct AnswerText: View {

    let text: String
    /// Nummern, zu denen es einen Beleg gibt. Nur sie werden zu Links.
    let citations: Set<Int>
    var focus: AccessibilityFocusState<UUID?>.Binding
    let answerID: UUID
    let onCitation: (Int) -> Void

    var body: some View {
        let blocks = AnswerLayout.blocks(for: text)
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .lead(let sentence):
                    focusable(line(sentence).font(.body.weight(.semibold)), first: index == 0)
                case .paragraph(let paragraph):
                    focusable(line(paragraph).font(.body), first: index == 0)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
                                Text(verbatim: "•")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                focusable(line(item), first: index == 0 && position == 0)
                            }
                            .font(.body)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let number = AnswerLayout.citationNumber(in: url) else { return .discarded }
            onCitation(number)
            return .handled
        })
    }

    private func line(_ text: String) -> Text {
        Text(AnswerLayout.attributed(text, linking: citations))
    }

    /// Eine neue Antwort bekommt den VoiceOver-Fokus auf ihrem ersten Satz.
    @ViewBuilder
    private func focusable(_ text: some View, first: Bool) -> some View {
        if first {
            text.accessibilityFocused(focus, equals: answerID)
        } else {
            text
        }
    }
}

/// Ein Abschnitt der Antwort, wie er angezeigt wird.
enum AnswerBlock: Hashable {
    /// Die direkte Antwort, der erste Satz.
    case lead(String)
    case paragraph(String)
    case bullets([String])
}

/// Gliedert einen Antworttext, ohne ein Wort wegzulassen.
///
/// Das Modell liefert Fließtext in einer Zeile. Daraus wird: der erste Satz
/// als direkte Antwort, danach Punkte, wenn die Sätze je einen eigenen Beleg
/// tragen, sonst kurze Absätze. Texte mit Zeilenumbrüchen stammen aus dem
/// Code, etwa die Liste der passendsten Stellen ohne Modell. Sie behalten
/// ihre Zeilen.
enum AnswerLayout {

    static let scheme = "podcastai-citation"

    /// Absätze mit höchstens so vielen Sätzen.
    private static let sentencesPerParagraph = 3

    @MainActor private static var cache: [String: [AnswerBlock]] = [:]

    @MainActor
    static func blocks(for text: String) -> [AnswerBlock] {
        if let cached = cache[text] { return cached }
        let blocks = layout(text)
        if cache.count > 64 { cache.removeAll() }
        cache[text] = blocks
        return blocks
    }

    static func layout(_ text: String) -> [AnswerBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains(where: \.isNewline) { return lineBlocks(trimmed) }
        let sentences = sentences(in: trimmed)
        guard sentences.count > 1 else { return [.paragraph(trimmed)] }
        let rest = Array(sentences.dropFirst())
        var blocks: [AnswerBlock] = [.lead(sentences[0])]
        let cited = rest.filter { !citationNumbers(in: $0).isEmpty }.count
        if rest.count >= 2, cited * 2 >= rest.count {
            blocks.append(.bullets(rest))
        } else {
            for start in stride(from: 0, to: rest.count, by: sentencesPerParagraph) {
                let end = min(start + sentencesPerParagraph, rest.count)
                blocks.append(.paragraph(rest[start..<end].joined(separator: " ")))
            }
        }
        return blocks
    }

    /// Zeilen bleiben Zeilen. Aufeinanderfolgende Listenzeilen werden eine Liste.
    private static func lineBlocks(_ text: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let item = listItem(line) {
                if case .bullets(let items) = blocks.last {
                    blocks[blocks.count - 1] = .bullets(items + [item])
                } else {
                    blocks.append(.bullets([item]))
                }
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    /// „• Aussage“, „- Aussage“ oder „[2] Zitat …“ ist ein Listenpunkt.
    private static func listItem(_ line: String) -> String? {
        for prefix in ["• ", "- ", "* ", "– "] where line.hasPrefix(prefix) {
            let item = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
           !numbers(inBrackets: line[line.index(after: line.startIndex)..<close]).isEmpty {
            return line
        }
        return nil
    }

    /// Sätze nach der Sprache des Textes. Ein Verweis hinter dem Punkt gehört
    /// zum Satz davor, und „am 12. Sept.“ beendet keinen Satz.
    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            if !result.isEmpty {
                let (markers, remainder) = leadingMarkers(sentence)
                if !markers.isEmpty {
                    result[result.count - 1] += " " + markers
                    sentence = remainder
                    if sentence.isEmpty { return true }
                }
            }
            if let last = result.last, isFragment(sentence, after: last) {
                result[result.count - 1] = last + " " + sentence
            } else {
                result.append(sentence)
            }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    private static func isFragment(_ sentence: String, after previous: String) -> Bool {
        guard let first = sentence.first else { return true }
        if first.isLowercase || first.isNumber { return true }
        if previous.hasSuffix("."), let digit = previous.dropLast().last, digit.isNumber { return true }
        return sentence.count < 6
    }

    private static func leadingMarkers(_ sentence: String) -> (markers: String, rest: String) {
        var rest = Substring(sentence)
        var markers: [String] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
              !numbers(inBrackets: rest[rest.index(after: rest.startIndex)..<close]).isEmpty {
            markers.append(String(rest[...close]))
            rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
        }
        return (markers.joined(separator: " "), String(rest))
    }

    /// Alle Verweisnummern eines Textes.
    static func citationNumbers(in text: String) -> [Int] {
        var result: [Int] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]") {
            result += numbers(inBrackets: text[text.index(after: open)..<close])
            index = text.index(after: close)
        }
        return result
    }

    /// „3“, „3, 5“, „3 5“ und „2-4“ sind Verweise. „Musik“ oder „00:12“ nicht.
    static func numbers(inBrackets content: Substring) -> [Int] {
        let allowed = CharacterSet(charactersIn: "0123456789,; -–")
        guard !content.isEmpty, content.unicodeScalars.allSatisfy(allowed.contains),
              content.contains(where: \.isNumber) else { return [] }
        var result: [Int] = []
        for part in content.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let bounds = part.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Int($0) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] <= 10 {
                result += Array(bounds[0]...bounds[1])
            } else {
                result += bounds
            }
        }
        return result
    }

    /// Der Text mit einem Link je Verweisnummer, die einen Beleg hat.
    /// Eine Klammer mit anderen Nummern bleibt, wie sie ist.
    static func attributed(_ text: String, linking valid: Set<Int>) -> AttributedString {
        var result = AttributedString()
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "[") {
            guard let close = text[open...].firstIndex(of: "]") else { break }
            let numbers = numbers(inBrackets: text[text.index(after: open)..<close])
            guard !numbers.isEmpty, numbers.allSatisfy(valid.contains) else {
                result += AttributedString(text[index...open])
                index = text.index(after: open)
                continue
            }
            result += AttributedString(text[index..<open])
            for (offset, number) in numbers.enumerated() {
                if offset > 0 { result += AttributedString("\u{2009}") }
                var marker = AttributedString("[\(number)]")
                marker.link = URL(string: "\(scheme)://\(number)")
                marker.font = Font.footnote.weight(.semibold).monospacedDigit()
                result += marker
            }
            index = text.index(after: close)
        }
        result += AttributedString(text[index...])
        return result
    }

    static func citationNumber(in url: URL) -> Int? {
        guard url.scheme == scheme, let host = url.host() else { return nil }
        return Int(host)
    }
}

// MARK: - Belege je Folge

/// Die Belege einer Folge, nach Nummer.
struct CitationGroup: Identifiable {
    let id: EpisodeID
    let items: [(number: Int, evidence: Evidence)]

    /// Folgen in der Reihenfolge ihres ersten Verweises.
    static func grouping(_ numbered: [(number: Int, evidence: Evidence)]) -> [CitationGroup] {
        var order: [EpisodeID] = []
        var byEpisode: [EpisodeID: [(number: Int, evidence: Evidence)]] = [:]
        for item in numbered.sorted(by: { $0.number < $1.number }) {
            let id = item.evidence.episodeID
            if byEpisode[id] == nil { order.append(id) }
            byEpisode[id, default: []].append(item)
        }
        return order.map { CitationGroup(id: $0, items: byEpisode[$0] ?? []) }
    }
}

/// Was eine Belegkarte über ihre Folge zeigt.
struct CitedEpisode: Sendable {
    let podcast: String
    let title: String
    let publishedAt: Date?
    let artworkURL: URL?
}

/// Eine Karte je Folge: Cover, Podcast, Folge und Datum, darunter die
/// Stellen mit Zeitmarke. Mehr als zwei Stellen klappen zu.
private struct CitedEpisodeCard: View {

    let items: [(number: Int, evidence: Evidence)]
    let episode: CitedEpisode?
    /// Innerhalb einer Folge gibt es keinen Kopf und keine eigene Karte.
    let showsHeader: Bool
    @Binding var isExpanded: Bool
    let highlighted: Int?
    let anchor: (Int) -> String
    var focusedCitation: AccessibilityFocusState<Int?>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// So viele Stellen stehen zugeklappt da.
    static let collapsedCount = 2

    private var isCollapsible: Bool { items.count > Self.collapsedCount }

    private var visible: ArraySlice<(number: Int, evidence: Evidence)> {
        isCollapsible && !isExpanded ? items.prefix(Self.collapsedCount) : items[...]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            if showsHeader, let episode {
                header(episode)
            }
            ForEach(visible, id: \.number) { item in
                CitationRow(number: item.number, evidence: item.evidence,
                            highlighted: highlighted == item.number)
                    .id(anchor(item.number))
                    .accessibilityFocused(focusedCitation, equals: item.number)
            }
            if isCollapsible {
                toggle
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsHeader ? Design.Spacing.control : Design.Spacing.none)
        .background {
            if showsHeader {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(.background)
            }
        }
    }

    /// Bei großer Schrift steht das Cover über den Titeln statt daneben.
    private func header(_ episode: CitedEpisode) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Spacing.small))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Design.Spacing.control))
        return layout {
            EpisodeArtwork(url: episode.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                Text(episode.podcast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                if let date = episode.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var toggle: some View {
        Button {
            withAnimation(Design.Motion.respectingReduceMotion(Design.Motion.smooth, reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            Label {
                if isExpanded {
                    Text("Weniger anzeigen")
                } else {
                    Text("^[\(items.count - Self.collapsedCount) weitere Stelle](inflect: true) anzeigen")
                }
            } icon: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }
}

/// Warum nur ein Teil der Folgen durchsucht wurde, in wenigen Sätzen.
private struct CoverageExplanation: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Bei großer Schrift passt der Text nicht ins Popover und scrollt.
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { content }
                .frame(width: 300, height: 420)
        } else {
            content
                .frame(width: 300)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Text("Warum nur Folgen mit Transkript?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("""
                Die App sucht im Transkript, also im mitgeschriebenen Text einer Folge. \
                Folgen ohne Transkript kann sie nicht durchsuchen, auch wenn sie zum Thema passen.
                """)
            Text("""
                Ein Transkript erstellst du in der Folge mit „Transkript erstellen“. \
                Für neue Folgen geht das von selbst, wenn in den Einstellungen \
                „Transkripte für neue Folgen erstellen“ an ist.
                """)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Design.Spacing.standard)
    }
}

extension AppModel {

    /// Podcast, Folge, Datum und Cover je zitierter Folge. Titel und Datum
    /// kommen aus dem Speicher, auch für eine gelöschte Folge. Das Cover ist
    /// das der Folge, sonst das des Podcasts.
    fileprivate func citedEpisodes(for evidence: [Evidence]) async -> [EpisodeID: CitedEpisode] {
        let ids = Array(Set(evidence.map(\.episodeID)))
        guard !ids.isEmpty, let titles = try? await store.titles(forEpisodes: ids) else { return [:] }
        let stored = (try? await store.episodes(ids: ids)) ?? []
        let artwork = Dictionary(stored.map { ($0.id, $0.artworkURL) }, uniquingKeysWith: { first, _ in first })
        var result: [EpisodeID: CitedEpisode] = [:]
        for (id, titles) in titles {
            let sourceID = evidence.first { $0.episodeID == id }?.sourceID
            let podcastArtwork = sources.first { $0.id == sourceID }?.artworkURL
            result[id] = CitedEpisode(
                podcast: titles.source, title: titles.episode, publishedAt: titles.publishedAt,
                artworkURL: artwork[id].flatMap { $0 } ?? podcastArtwork)
        }
        return result
    }
}

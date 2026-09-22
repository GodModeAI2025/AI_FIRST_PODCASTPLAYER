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
    @State private var scope: ChatScope
    @State private var question = ""
    @State private var isAsking = false
    /// Innerhalb einer Folge ist der Bereich fest.
    private let fixedScope: Bool

    init(scope: ChatScope = .allAnalyzed, fixed: Bool = false) {
        _scope = State(initialValue: scope)
        fixedScope = fixed
    }

    private var answers: [ChatAnswer] {
        model.chatAnswers.filter { $0.scope == scope }
    }

    var body: some View {
        VStack(spacing: Design.Spacing.none) {
            if !fixedScope {
                ScopeBar(scope: $scope)
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
    }

    /// Das Eingabefeld schwebt als Bedienelement über dem Inhalt.
    private var askField: some View {
        HStack(spacing: Design.Spacing.small) {
            TextField(fixedScope ? "Frage zu dieser Folge …" : "Frage stellen …",
                      text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
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

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        question = ""
        isAsking = true
        let currentScope = scope
        Task {
            let answer = await model.ask(text, scope: currentScope)
            model.chatAnswers.insert(answer, at: 0)
            isAsking = false
        }
    }
}

/// Eigenständig trägt der Chat den Titel „Fragen“. Innerhalb einer Folge
/// bleibt deren Titel stehen.
private struct ChatTitle: ViewModifier {
    let show: Bool
    func body(content: Content) -> some View {
        if show { content.navigationTitle("Fragen") } else { content }
    }
}

/// Der Bereich steht oben und ist jederzeit änderbar.
struct ScopeBar: View {

    @Binding var scope: ChatScope
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "scope").foregroundStyle(.secondary)
            Picker("Bereich", selection: Binding(
                get: { ScopeChoice(scope) },
                set: { scope = $0.scope(model) }
            )) {
                Text("Alle erschlossenen Inhalte").tag(ScopeChoice.allAnalyzed)
                if let title = currentTitle {
                    Text("Laufende Folge: \(title)").tag(ScopeChoice.currentEpisode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
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

    enum ScopeChoice: Hashable {
        case allAnalyzed, currentEpisode

        init(_ scope: ChatScope) {
            if case .allAnalyzed = scope { self = .allAnalyzed } else { self = .currentEpisode }
        }

        @MainActor func scope(_ model: AppModel) -> ChatScope {
            switch self {
            case .allAnalyzed: .allAnalyzed
            case .currentEpisode:
                if let episode = model.episodePlayer.episode {
                    .episode(episode.id)
                } else if let plan = model.playerPlan, let first = plan.segments.first {
                    .episode(first.episodeID)
                } else {
                    .allAnalyzed
                }
            }
        }
    }
}

extension ModelStatus {
    /// Kurzform für die Anzeige, womit geantwortet wird.
    var resolveLabel: String? {
        switch resolve(.answer) {
        case .success(let tier): tier == .privateCloudCompute ? "Private Cloud Compute" : "Auf dem Gerät"
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
            ["Worum geht es in dieser Folge?",
             "Was sind die wichtigsten Aussagen?",
             "Welche Zahlen und Namen werden genannt?",
             "Wo sind sich die Gesprächspartner uneinig?"]
        default:
            ["Welche Folgen behandeln künstliche Intelligenz?",
             "Was wurde zuletzt über Datenschutz gesagt?",
             "Welche erschlossenen Folgen habe ich noch nicht gehört?",
             "Wo widersprechen sich zwei Podcasts?"]
        }
    }

    var body: some View {
        VStack(spacing: Design.Spacing.control) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(scope.isEpisode ? "Frag diese Folge" : "Frag deine Podcasts")
                .font(.headline)
            Text("Jede Antwort nennt die Stellen, aus denen sie stammt. Ein Tipp auf einen Beleg "
                 + "spielt die Stelle im Original.")
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
                    Label(answer.scope.label, systemImage: "scope")
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
                        CitationRow(number: item.number, evidence: item.evidence)
                    }
                }
                .padding(.top, Design.Spacing.micro / 2)
            }

            if !answer.playableCitations.isEmpty {
                Button {
                    model.playAnswer(answer)
                } label: {
                    Label(
                        answer.playableCitations.count == 1
                            ? "Diese Stelle anhören"
                            : "Alle \(answer.playableCitations.count) Stellen nacheinander anhören",
                        systemImage: "play.circle"
                    )
                    .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Spielt die belegten Originalstellen nacheinander ab")
            }
        }
        .contentCard()
        .sheet(item: Binding(
            get: { exported.map(ExportPreview.init) },
            set: { exported = $0?.text }
        )) { preview in
            ExportPreviewSheet(text: preview.text)
        }
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

struct CitationRow: View {

    var number: Int = 0
    let evidence: Evidence
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            guard let range = evidence.range else { return }
            Task { await model.playEvidenceInEpisode(evidence, at: range.start.seconds) }
        } label: {
            HStack(alignment: .top, spacing: Design.Spacing.small) {
                Text(number > 0 ? "\(number)" : "")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.tint, in: .circle)
                VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                    Text(evidence.quotedText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let range = evidence.range {
                        HStack(spacing: Design.Spacing.micro) {
                            TimecodeLabel(range)
                            Image(systemName: "play.fill").font(.caption2).foregroundStyle(.tint)
                        }
                    } else {
                        Text("ohne Zeitbezug, nicht anhörbar")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Spielt die Folge ab dieser Stelle")
    }
}

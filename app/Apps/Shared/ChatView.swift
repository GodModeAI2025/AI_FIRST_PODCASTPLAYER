//
//  ChatView.swift
//  PodcastAI
//
//  Der Chat als zweite Bedienoberfläche.
//
//  Zwei Dinge machen ihn zu mehr als einem Suchfeld:
//  der **Scope steht sichtbar oben** — man weiß immer, worüber gesprochen
//  wird — und **eine Antwort kann zur Hörsession werden**, statt den Nutzer
//  danach selbst durch die Folge navigieren zu lassen.
//

import SwiftUI
import PodcastAIKit

struct ChatView: View {

    @Environment(AppModel.self) private var model
    @State private var scope: ChatScope = .allAnalyzed
    @State private var question = ""
    @State private var answers: [ChatAnswer] = []
    @State private var isAsking = false

    var body: some View {
        VStack(spacing: Design.Spacing.none) {
            ScopeBar(scope: $scope)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Spacing.section) {
                    if answers.isEmpty {
                        ChatEmptyState(scope: scope)
                            .padding(.top, Design.Spacing.generous)
                    }
                    ForEach(answers) { answer in
                        AnswerCard(answer: answer)
                    }
                }
                .padding()
            }

            askField
        }
        .navigationTitle("Fragen")
    }

    /// Das Eingabefeld liegt auf der Navigationsebene und bekommt deshalb
    /// Glas — es schwebt über dem Inhalt, statt Teil davon zu sein.
    private var askField: some View {
        HStack(spacing: Design.Spacing.small) {
            TextField("Frage stellen …", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit(ask)
                .accessibilityLabel("Frage")

            Button(action: ask) {
                Image(systemName: isAsking ? "ellipsis" : "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolEffect(.pulse, isActive: isAsking)
                    .tappableArea()
            }
            .buttonStyle(.pressable)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
            .accessibilityLabel("Frage senden")
        }
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.vertical, Design.Spacing.small)
        .glassEffect(.regular, in: .capsule)
        .padding(Design.Spacing.control)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        isAsking = true
        Task {
            let answer = await model.ask(text, scope: scope)
            answers.insert(answer, at: 0)
            isAsking = false
        }
    }
}

/// Der Scope steht oben und ist jederzeit änderbar. Nicht in einem
/// Einstellungsmenü versteckt — er verändert die Bedeutung jeder Antwort.
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
                ForEach(ScopeChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal, Design.Spacing.control)
        .padding(.vertical, Design.Spacing.small)
    }

    enum ScopeChoice: CaseIterable, Hashable {
        case allAnalyzed, currentEpisode

        init(_ scope: ChatScope) {
            if case .allAnalyzed = scope { self = .allAnalyzed } else { self = .currentEpisode }
        }

        var label: String {
            switch self {
            case .allAnalyzed: "Alle erschlossenen Inhalte"
            case .currentEpisode: "Was gerade läuft"
            }
        }

        func scope(_ model: AppModel) -> ChatScope {
            switch self {
            case .allAnalyzed: .allAnalyzed
            case .currentEpisode:
                if let plan = model.playerPlan, let first = plan.segments.first {
                    .episode(first.episodeID)
                } else {
                    .allAnalyzed
                }
            }
        }
    }
}

struct ChatEmptyState: View {

    let scope: ChatScope

    var body: some View {
        VStack(spacing: Design.Spacing.control) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Frag über \(scope.label.lowercased())")
                .font(.headline)
            Text("Antworten führen zurück auf die Originalstelle — und du kannst sie "
                 + "dir direkt anhören.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Design.Spacing.large)
    }
}

struct AnswerCard: View {

    let answer: ChatAnswer
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            Text(answer.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(answer.text)
                .font(.body)
                .textSelection(.enabled)

            // Wenn der Bestand keine Vollständigkeitsaussage trägt, steht
            // das hier — nicht im Kleingedruckten.
            if let caveat = answer.coverageCaveat {
                Label(caveat, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !answer.citations.isEmpty {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    ForEach(answer.citations, id: \.id) { evidence in
                        CitationRow(evidence: evidence)
                    }
                }
                .padding(.top, Design.Spacing.micro / 2)
            }

            // Der Übergang, der den Chat vom Suchfeld unterscheidet.
            if !answer.playableCitations.isEmpty {
                Button {
                    model.playAnswer(answer)
                } label: {
                    Label(
                        answer.playableCitations.count == 1
                            ? "Diese Stelle anhören"
                            : "Diese \(answer.playableCitations.count) Stellen anhören",
                        systemImage: "play.circle"
                    )
                    .frame(minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.pressable)
                .buttonBorderShape(.capsule)
                .padding(.top, Design.Spacing.micro)
                .accessibilityHint("Spielt die belegten Originalstellen nacheinander ab")
            }
        }
        .contentCard()
    }
}

struct CitationRow: View {

    let evidence: Evidence

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                Text(evidence.quotedText)
                    .font(.caption)
                    .lineLimit(3)
                if let range = evidence.range {
                    TimecodeLabel(range)
                } else {
                    // Ehrlich statt erfunden.
                    Text("ohne Zeitbezug — nicht anhörbar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

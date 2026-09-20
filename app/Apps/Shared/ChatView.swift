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
        VStack(spacing: 0) {
            ScopeBar(scope: $scope)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if answers.isEmpty {
                        ChatEmptyState(scope: scope)
                            .padding(.top, 40)
                    }
                    ForEach(answers) { answer in
                        AnswerCard(answer: answer)
                    }
                }
                .padding()
            }

            Divider()
            askField
        }
        .navigationTitle("Fragen")
    }

    private var askField: some View {
        HStack(spacing: 8) {
            TextField("Frage stellen …", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit(ask)

            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
        }
        .padding(12)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                if let plan = model.player.activePlan, let first = plan.segments.first {
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
        VStack(spacing: 10) {
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
        .padding(.horizontal, 32)
    }
}

struct AnswerCard: View {

    let answer: ChatAnswer
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(answer.citations, id: \.id) { evidence in
                        CitationRow(evidence: evidence)
                    }
                }
                .padding(.top, 2)
            }

            // Der Übergang, der den Chat vom Suchfeld unterscheidet.
            if !answer.playableCitations.isEmpty {
                Button {
                    model.playAnswer(answer)
                } label: {
                    Label("Diese \(answer.playableCitations.count) Stellen anhören",
                          systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CitationRow: View {

    let evidence: Evidence

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(evidence.quotedText)
                    .font(.caption)
                    .lineLimit(3)
                if let range = evidence.range {
                    Text("\(range.start.timecode)–\(range.end.timecode)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
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

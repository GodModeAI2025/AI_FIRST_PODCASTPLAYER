//
//  ConversationViews.swift
//  PodcastAI
//
//  „Frühere Unterhaltungen“ im Chat „Frag deine Podcasts“: jede
//  Unterhaltung mit ihrer ersten Frage, wann sie zuletzt lief und wie viele
//  Fragen sie hat. Ein Tipp öffnet sie wieder, Wischen oder das
//  Kontextmenü löscht sie auf allen Geräten.
//

import SwiftUI
import PodcastAIKit

struct ConversationListSheet: View {

    /// Die Unterhaltung, die gerade im Chat steht.
    let current: UUID?
    let open: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [ChatConversationSummary] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if loaded && summaries.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine früheren Unterhaltungen", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Mit „Neue Unterhaltung“ bleibt die bisherige hier stehen und lässt sich wieder öffnen.")
                    }
                } else {
                    List {
                        ForEach(summaries) { summary in
                            Button {
                                open(summary.id)
                                dismiss()
                            } label: {
                                row(summary)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { delete(summary) } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { delete(summary) } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                            .accessibilityHint("Öffnet diese Unterhaltung wieder")
                            .accessibilityIdentifier("chat.conversationRow")
                        }
                    }
                }
            }
            .navigationTitle("Frühere Unterhaltungen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityIdentifier("chat.conversationListDone")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .task {
            summaries = await model.conversationSummaries(for: .library)
            loaded = true
        }
    }

    private func row(_ summary: ChatConversationSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.control) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                Text(summary.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(summary.updatedAt.formatted(date: .abbreviated, time: .shortened)) · ^[\(summary.turnCount) Frage](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if summary.id == current {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Geöffnet")
            }
        }
        .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func delete(_ summary: ChatConversationSummary) {
        summaries.removeAll { $0.id == summary.id }
        model.deleteConversation(summary.id)
        AccessibilityNotification.Announcement(String(localized: "Unterhaltung gelöscht")).post()
    }
}

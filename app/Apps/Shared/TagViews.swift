//
//  TagViews.swift
//  PodcastAI
//
//  Tags seit 0.10: die Tag-Wolke in „Kurz gesagt“ und an jedem Kapitel,
//  „Meine Tags“ und die Seite eines Tags. Tags tippt niemand ein. Sie
//  stammen aus dem Inhalt, und jedes Tag hat zwei Knöpfe: Plus heißt
//  folgen, Minus heißt nicht mehr folgen. Nach Minus bleibt das Tag
//  sichtbar und neutral.
//
//  Nichts hier spielt Ton. Ein Kapitel auf der Tag-Seite öffnet die Folge
//  im Reiter „Kapitel“, abgespielt wird dort erst auf Tippen.
//

import SwiftUI
import PodcastAIKit

// MARK: - Tag-Wolke

/// Höchstens zehn Tags, umbrechend. Gefolgte Tags stehen vorn und sind
/// markiert. Ein Tipp auf den Namen öffnet die Tag-Seite, der Knopf daneben
/// folgt oder beendet das Folgen.
struct TagCloud: View {
    let tags: [Tag]
    /// Öffnet die Seite eines Tags. Die Navigation hängt am Elternteil,
    /// nicht in der Zeile einer Liste.
    let open: (InterestID) -> Void

    /// Mehr als zehn liest niemand, und die Liste darunter rückt zu weit weg.
    static let maximumTags = 10

    var body: some View {
        // Kein Zeilenabstand: Jeder Chip ist zum Antippen 44 Punkt hoch,
        // die sichtbare Kapsel kleiner. Der Rest ist schon Luft genug.
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.none) {
            ForEach(tags.prefix(Self.maximumTags)) { tag in
                TagChip(tag: tag, open: { open(tag.id) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
    }

    /// Die Tags zu Kapitel-Tags, wie die Wolke sie zeigt: gefolgte zuerst,
    /// dann nach Zahl der Kapitel, Sicherheit und Name. Kapitel-Tags, deren
    /// Tag es nicht mehr gibt, fallen weg.
    static func tags(for chapterTags: [ChapterTag], profile: InterestProfile) -> [Tag] {
        let known = Dictionary(profile.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chapters: [InterestID: Set<Int>] = [:]
        var confidence: [InterestID: Double] = [:]
        for chapterTag in chapterTags where known[chapterTag.interestID] != nil {
            chapters[chapterTag.interestID, default: []].insert(chapterTag.chapterStartMs)
            confidence[chapterTag.interestID] = max(confidence[chapterTag.interestID] ?? 0, chapterTag.confidence)
        }
        return chapters.keys.compactMap { known[$0] }
            .sorted { lhs, rhs in
                if lhs.isFollowed != rhs.isFollowed { return lhs.isFollowed }
                let left = chapters[lhs.id]?.count ?? 0, right = chapters[rhs.id]?.count ?? 0
                if left != right { return left > right }
                let leftConfidence = confidence[lhs.id] ?? 0, rightConfidence = confidence[rhs.id] ?? 0
                if leftConfidence != rightConfidence { return leftConfidence > rightConfidence }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
            .prefix(maximumTags)
            .map { $0 }
    }
}

/// Die Kennung eines Tags für UI-Tests: die Bezeichnung. Der Schlüssel
/// hängt an den Sprachdaten des Geräts und taugt dafür nicht.
extension Tag {
    var testKey: String { label }
}

/// Ein Tag als Kapsel: Name und Plus oder Minus.
struct TagChip: View {
    let tag: Tag
    let open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: Design.Spacing.micro) {
                    if tag.isFollowed {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                    Text(tag.label)
                }
                .padding(.leading, Design.Spacing.control)
                .padding(.trailing, Design.Spacing.micro)
                .frame(minHeight: Design.minimumTapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tag.isFollowed ? Text("Tag \(tag.label), du folgst") : Text("Tag \(tag.label)"))
            .accessibilityHint("Öffnet die Seite des Tags")
            .accessibilityIdentifier("tag.open.\(tag.testKey)")

            TagFollowButton(tag: tag, style: .compact)
        }
        .font(.caption.weight(.medium))
        .background {
            Capsule()
                .fill(tag.isFollowed ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                .padding(.vertical, (Design.minimumTapTarget - 28) / 2)
        }
        .foregroundStyle(tag.isFollowed ? Color.accentColor : Color.primary)
    }
}

/// Plus oder Minus. Plus folgt dem Tag, Minus beendet das Folgen, das Tag
/// bleibt sichtbar.
struct TagFollowButton: View {
    enum Style { case compact, labeled }

    let tag: Tag
    let style: Style
    @Environment(AppModel.self) private var model

    var body: some View {
        let follows = tag.isFollowed
        Button {
            Task { await model.setTagStance(follows ? .neutral : .follow, for: tag.id) }
        } label: {
            switch style {
            case .compact:
                Image(systemName: follows ? "minus" : "plus")
                    .fontWeight(.semibold)
                    .padding(.leading, Design.Spacing.micro)
                    .padding(.trailing, Design.Spacing.control)
                    .frame(minWidth: 32, minHeight: Design.minimumTapTarget)
                    .contentShape(.rect)
            case .labeled:
                Label(follows ? "Nicht mehr folgen" : "Folgen",
                      systemImage: follows ? "minus.circle" : "plus.circle")
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(follows ? Text("\(tag.label) nicht mehr folgen") : Text("\(tag.label) folgen"))
        .accessibilityIdentifier(follows ? "tag.unfollow.\(tag.testKey)" : "tag.follow.\(tag.testKey)")
    }
}

// MARK: - Meine Tags

/// Alle Tags: gefolgte oben, darunter die neutralen mit der Zahl ihrer
/// Kapitel. Ersetzt die Liste der Interessen mit ihren Eingabefeldern.
struct TagsView: View {

    @Environment(AppModel.self) private var model
    @State private var query = ""

    private func matches(_ tag: Tag) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return tag.label.localizedStandardContains(text)
            || tag.aliases.contains { $0.localizedStandardContains(text) }
    }

    private var followed: [Tag] {
        model.profile.tags.filter { $0.isFollowed && matches($0) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var neutral: [Tag] {
        let counts = model.chapterTagCounts
        return model.profile.tags.filter { !$0.isFollowed && matches($0) }
            .sorted { lhs, rhs in
                let left = counts[lhs.id] ?? 0, right = counts[rhs.id] ?? 0
                if left != right { return left > right }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }

    var body: some View {
        List {
            if model.profile.tags.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Tags", systemImage: "tag")
                } description: {
                    Text("""
                        Tags entstehen aus dem Inhalt deiner Folgen, sobald Transkripte fertig sind. \
                        Mit Plus folgst du einem Tag, dann sammelt „Für dich“ die passenden Kapitel.
                        """)
                }
            } else {
                SwiftUI.Section {
                    if followed.isEmpty {
                        Text(query.isEmpty
                             ? "Du folgst noch keinem Tag. Tippe bei einem Tag auf Plus."
                             : "Kein gefolgtes Tag passt zur Suche.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(followed) { tag in row(tag) }
                } header: {
                    Text("Du folgst")
                } footer: {
                    Text("Gefolgte Tags füllen „Für dich“ und die Themen-Updates. Minus beendet das Folgen, das Tag bleibt.")
                }
                if !neutral.isEmpty {
                    SwiftUI.Section {
                        ForEach(neutral) { tag in row(tag) }
                    } header: {
                        Text("Weitere Tags aus deinen Folgen")
                    }
                }
            }
        }
        .yieldsAIWhileScrolling()
        .searchable(text: $query, prompt: Text("Tags durchsuchen"))
        .navigationTitle("Meine Tags")
        .accessibilityIdentifier("tags.list")
    }

    private func row(_ tag: Tag) -> some View {
        HStack {
            NavigationLink { TagDetailView(tagID: tag.id) } label: {
                VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                    Text(tag.label)
                    let count = model.chapterTagCounts[tag.id] ?? 0
                    Text("^[\(count) Kapitel](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("tags.row.\(tag.testKey)")
            TagFollowButton(tag: tag, style: .compact)
        }
    }
}

// MARK: - Seite eines Tags

/// Ein Tag: wo es vorkommt, andere Schreibweisen, nahe Tags zum
/// Zusammenlegen und Plus oder Minus. Ersetzt die Seite, auf der man
/// Stichworte eines Interesses eintippte.
struct TagDetailView: View {

    let tagID: InterestID
    @Environment(AppModel.self) private var model
    @State private var chapters: [ChapterTag] = []
    @State private var titles: [EpisodeID: LibraryStore.EpisodeTitles] = [:]
    @State private var near: [Tag] = []
    @State private var pendingMerge: Tag?

    private var tag: Tag? { model.profile.tags.first { $0.id == tagID } }

    var body: some View {
        List {
            if let tag {
                SwiftUI.Section {
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        Text(tag.isFollowed ? "Du folgst diesem Tag." : "Du folgst diesem Tag nicht.")
                        Text(tag.origin.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    TagFollowButton(tag: tag, style: .labeled)
                } footer: {
                    Text("Plus: „Für dich“ und die Themen-Updates sammeln Kapitel mit diesem Tag. Minus beendet das, das Tag bleibt sichtbar.")
                }

                SwiftUI.Section {
                    if chapters.isEmpty {
                        Text("Noch in keinem Kapitel.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(chapters) { chapter in chapterRow(chapter) }
                } header: {
                    Text("Wo es vorkommt")
                } footer: {
                    if !chapters.isEmpty {
                        Text("Ein Tipp öffnet die Folge bei ihren Kapiteln. Abgespielt wird erst, wenn du dort ein Kapitel antippst.")
                    }
                }

                if !tag.aliases.isEmpty {
                    SwiftUI.Section {
                        ForEach(tag.aliases, id: \.self) { Text($0) }
                            .onDelete { offsets in removeAliases(at: offsets) }
                    } header: {
                        Text("Andere Schreibweisen")
                    } footer: {
                        Text("Unter diesen Namen erkennt die App dasselbe Tag.")
                    }
                }

                if !near.isEmpty {
                    SwiftUI.Section {
                        ForEach(near) { other in
                            HStack {
                                VStack(alignment: .leading, spacing: Design.Spacing.micro / 2) {
                                    Text(other.label)
                                    Text("^[\(model.chapterTagCounts[other.id] ?? 0) Kapitel](inflect: true)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Zusammenlegen") { pendingMerge = other }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel(Text("\(other.label) hierher zusammenlegen"))
                            }
                        }
                    } header: {
                        Text("Zusammenlegen?")
                    } footer: {
                        Text("Diese Tags sehen ähnlich aus. Zusammengelegt wird nur, wenn du es willst. Der andere Name bleibt als Schreibweise.")
                    }
                }
            } else {
                ContentUnavailableView("Tag nicht gefunden", systemImage: "tag.slash",
                                       description: Text("Vielleicht wurde es auf einem anderen Gerät zusammengelegt."))
            }
        }
        .navigationTitle(tag?.label ?? String(localized: "Tag"))
        .accessibilityIdentifier("tag.page")
        .task(id: model.chapterTagsRevision) {
            let found = await model.chapterTags(forTag: tagID)
            chapters = found
            titles = await model.episodeTitles(Array(Set(found.map(\.episodeID))))
        }
        // Nahe Tags hängen nur an Namen, Schlüsseln und Schreibweisen, nicht
        // an Plus oder Minus. Der Vergleich lädt Sprachdaten und läuft über
        // alle Tags, deshalb abseits des Hauptthreads.
        .task(id: similarityInput) {
            guard let tag else { near = []; return }
            let all = model.profile.tags
            near = await Task.detached(priority: .utility) {
                TagSimilarity.nearTags(to: tag, in: all)
            }.value
        }
        .confirmationDialog(
            pendingMerge.map { Text("„\($0.label)“ mit „\(tag?.label ?? "")“ zusammenlegen?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            titleVisibility: .visible
        ) {
            if let other = pendingMerge {
                Button("Zusammenlegen") {
                    pendingMerge = nil
                    Task { await model.mergeTag(other.id, into: tagID) }
                }
            }
            Button("Abbrechen", role: .cancel) { pendingMerge = nil }
        } message: {
            Text("Die Kapitel beider Tags stehen danach unter einem. Folgst du einem der beiden, folgst du dem zusammengelegten.")
        }
    }

    /// Was die Vorschläge zum Zusammenlegen bestimmt.
    private var similarityInput: [[String]] {
        model.profile.tags.map { [$0.id.rawValue, $0.label, $0.normalizedKey] + $0.aliases }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: ChapterTag) -> some View {
        let title = titles[chapter.episodeID]
        let episode = model.loadedEpisode(chapter.episodeID)
        let content = VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(chapterTitle(chapter, in: episode))
                .font(.headline)
            Text(title?.episode ?? episode?.title ?? String(localized: "Unbekannte Folge"))
                .lineLimit(2)
            HStack(spacing: Design.Spacing.micro) {
                Text(title?.source ?? String(localized: "Unbekannter Podcast")).lineLimit(1)
                if let published = title?.publishedAt ?? chapter.publishedAt {
                    Text(verbatim: "·")
                    Text(published, format: .dateTime.day().month().year())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let episode {
            NavigationLink {
                EpisodeDetailView(episode: episode, initialSection: .chapters)
            } label: {
                content
            }
            .accessibilityIdentifier("tag.chapter")
        } else {
            content
        }
    }

    /// Der Titel des Kapitels aus dem Feed, sonst der Anfang.
    private func chapterTitle(_ chapter: ChapterTag, in episode: Episode?) -> String {
        let start = MediaTime(milliseconds: Int64(chapter.chapterStartMs))
        if let match = episode?.publisherChapters.first(where: { $0.start.milliseconds == start.milliseconds }) {
            return String(localized: "\(match.title) · ab \(start.timecode)")
        }
        return String(localized: "Kapitel ab \(start.timecode)")
    }

    private func removeAliases(at offsets: IndexSet) {
        guard var interest = model.profile.interests.first(where: { $0.id == tagID }) else { return }
        let removed = offsets.compactMap { tag?.aliases.indices.contains($0) == true ? tag?.aliases[$0] : nil }
        interest.keywords.removeAll { removed.contains($0) }
        Task { await model.updateInterest(interest) }
    }
}

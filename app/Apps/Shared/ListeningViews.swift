//
//  ListeningViews.swift
//  PodcastAI
//
//  Ganze Folgen hören: Detailansicht mit Cover, Kapiteln und Shownotes,
//  der Player dazu und die Warteschlange, an der man sieht, was als
//  Nächstes gehört und was als Nächstes erschlossen wird.
//

import SwiftUI
import Translation
import PodcastAIKit

// MARK: - Folge

struct EpisodeDetailView: View {

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Überblick"
        case chapters = "Kapitel"
        case transcript = "Transkript"
        case facts = "Fakten"
        case ask = "Fragen"
        var id: Self { self }
        /// Was im Reiter steht. Der Rohwert bleibt deutsch und dient nur als Kennung.
        var title: LocalizedStringKey {
            switch self {
            case .overview: "Überblick"
            case .chapters: "Kapitel"
            case .transcript: "Transkript"
            case .facts: "Fakten"
            case .ask: "Fragen"
            }
        }
        var symbol: String {
            switch self {
            case .overview: "info.circle"
            case .chapters: "list.bullet"
            case .transcript: "text.alignleft"
            case .facts: "quote.bubble"
            case .ask: "text.bubble"
            }
        }
    }

    let episode: Episode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var section: Section = .overview
    @State private var passages: [Evidence] = []
    @State private var exported: String?
    @State private var confirmDelete = false
    @State private var topicTags: [TopicTag] = []
    /// Links, Termine, Adressen und Namen der Folge, aus Shownotes und Transkript.
    @State private var mentions: EpisodeMentions?

    private var player: EpisodePlayer { model.episodePlayer }
    private var isCurrent: Bool { player.episode?.id == episode.id }
    /// Der Zustand lebt im Speicher. Nach einem Neustart zeigen die
    /// gespeicherten Stellen, dass die Folge schon erschlossen ist.
    private var stage: ProcessingStage? {
        model.stages[episode.id] ?? (passages.isEmpty ? nil : .evidenceExtracted)
    }
    private var chapters: [Chapter] {
        if isCurrent, !player.chapters.isEmpty { return player.chapters }
        if !shown.publisherChapters.isEmpty { return shown.publisherChapters }
        return model.chapterCache[episode.id] ?? []
    }
    /// Die Folge mit den Lücken, die Metadaten über Supadata gefüllt haben.
    /// `metadataRevision` lässt die Ansicht neu zeichnen, sobald sie da sind.
    private var shown: Episode {
        _ = model.metadataRevision
        return model.withSupadataMetadata(episode)
    }
    private var facts: [EpisodeFact] { model.facts[episode.id] ?? [] }
    /// Der tatsächliche Dateistatus, bei jedem Zeichnen neu. Vorher galt
    /// ein gemerkter Wert, und Menü und Überblick konnten auseinanderlaufen.
    private var hasLocalAudio: Bool { model.hasLocalAudio(episode) }
    private var isDownloading: Bool { model.downloading.contains(episode.id) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Bereich", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Design.Spacing.standard)
            .padding(.vertical, Design.Spacing.small)
            .accessibilityIdentifier("episode.sections")

            switch section {
            case .overview: overview
            case .chapters: chapterList
            case .transcript: TranscriptSection(episode: episode)
            case .facts: factList
            case .ask:
                VStack(spacing: 0) {
                    askScopeHeader
                    if passages.isEmpty {
                        EpisodeAnalysisPrompt(episode: episode, style: .banner)
                    }
                    ChatView(scope: .episode(episode.id), fixed: true)
                }
            }
        }
        .navigationTitle(episode.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { actionsMenu } }
        .task(id: model.stages[episode.id]) {
            passages = await model.evidence(forEpisode: episode.id)
            await model.loadFacts(for: episode.id)
            // Neu, sobald das Transkript da ist: dann kommt mehr als die Shownotes dazu.
            mentions = await model.mentions(for: episode)
        }
        .task { await model.loadChapters(for: episode) }
        // Fehlen einem Video Beschreibung, Länge oder Bild, holt die App die
        // Metadaten, falls ein Supadata-Schlüssel eingetragen ist.
        .task { model.requestMetadata(for: episode) }
        .sheet(item: Binding(get: { exported.map(ExportPreview.init) }, set: { exported = $0?.text })) {
            ExportPreviewSheet(text: $0.text, fileName: episode.title).sheetFeedback()
        }
        // „Gemerkt bei 4:00“ und „Kopiert“ aus Transkript, Fakten und Notizen.
        .confirmationBanner()
        .confirmationDialog("Folge löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Folge und alle Daten löschen", role: .destructive) {
                Task {
                    await model.removeEpisode(episode)
                    dismiss()
                }
            }
        } message: {
            Text("""
                Transkript, Fakten, Belege und der Hörstand dieser Folge werden auf allen Geräten gelöscht. \
                Die Folge kommt auch beim Aktualisieren des Podcasts nicht zurück. \
                Deine Notizen bleiben unter Wissen erhalten.
                """)
        }
    }

    /// Im Reiter „Fragen“ ist der Bereich fest und die Bereichsauswahl
    /// fehlt. Diese Zeile sagt, an welche Folge die Fragen gehen.
    private var askScopeHeader: some View {
        Label {
            Text(episode.title)
        } icon: {
            Image(systemName: "scope").accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Spacing.standard)
        .padding(.bottom, Design.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fragen an diese Folge: \(episode.title)")
        .accessibilityIdentifier("episode.ask.scope")
    }

    // MARK: Menü

    private var actionsMenu: some View {
        Menu {
            // Auch hier, nicht nur beim Gedrückthalten von „Als Nächstes“.
            if model.canPlay(episode), !isCurrent {
                Button { queue(.last) } label: {
                    Label("Ans Ende der Warteschlange", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Divider()
            }
            Button {
                Task { exported = await model.exportEpisode(episode) }
            } label: { Label("Exportieren mit Transkript", systemImage: "square.and.arrow.up") }
            Button {
                Task { exported = await model.exportEpisode(episode, includeTranscript: false) }
            } label: { Label("Exportieren ohne Transkript", systemImage: "doc.plaintext") }
            Divider()
            if hasLocalAudio {
                // Von selbst geladen, etwa für das Transkript: so bleibt es da.
                if removesAudioLater {
                    Button {
                        Task { await model.downloadForOffline(episode) }
                    } label: { Label("Auf dem Gerät behalten", systemImage: "pin") }
                }
                Button {
                    Task { await model.removeAudio(for: episode) }
                } label: { Label("Audio entfernen, Daten behalten", systemImage: "arrow.down.circle.dotted") }
            } else if isDownloading {
                Button { model.cancelDownload(episode) } label: {
                    Label("Laden abbrechen", systemImage: "xmark.circle")
                }
            } else if episode.audioURL != nil {
                Button {
                    Task { await model.downloadForOffline(episode) }
                } label: { Label("Laden (offline)", systemImage: "arrow.down.circle") }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Folge löschen", systemImage: "trash")
                Text("Gemerkte Stellen und Notizen bleiben")
            }
        } label: {
            Label("Mehr", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("episode.menu")
    }

    // MARK: Überblick

    private var overview: some View {
        List {
            SwiftUI.Section {
                header
                playControls
            }

            if let stage {
                SwiftUI.Section("Transkript") {
                    Label {
                        if let detail = model.stageDetails[episode.id] {
                            Text("\(stage.label) · \(detail)")
                        } else {
                            Text(stage.label)
                        }
                    } icon: {
                        // Das Symbol wiederholt nur den Text. VoiceOver las
                        // beim Häkchen „Ausgewählt“.
                        // Nur eine Störung trägt Farbe, und nur das Symbol.
                        Image(systemName: stage.symbol)
                            .symbolEffect(.pulse, isActive: stage.isRunning)
                            .foregroundStyle(stage == .failed ? Design.Notice.failure.tint : Color.primary)
                            .accessibilityHidden(true)
                    }
                    if stage == .evidenceExtracted {
                        // „Transkript fertig“ allein führte nirgendwohin.
                        Button { section = .transcript } label: {
                            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                                Label("Transkript ansehen", systemImage: "text.alignleft")
                                Text("Du kannst jetzt in der Folge suchen und Fragen stellen.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .accessibilityIdentifier("episode.showTranscript")
                    }
                    audioStatus
                }
            } else if let detail = model.stageDetails[episode.id] {
                let wait = networkWait
                SwiftUI.Section {
                    Label {
                        Text(detail)
                    } icon: {
                        Image(systemName: wait?.symbol ?? "clock").accessibilityHidden(true)
                    }
                    if let wait {
                        // Der Ton liegt da und trotzdem wartet das Transkript:
                        // sagen, was es noch aus dem Netz braucht.
                        if hasLocalAudio {
                            Text(waitReasonWithLocalAudio)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("episode.waitReason")
                        }
                        TranscriptWaitControls(episode: episode, wait: wait)
                    }
                } header: {
                    Text("Transkript")
                } footer: {
                    if let wait { TranscriptWaitControls.footnote(for: wait, episode: episode, model: model) }
                }
            }
            // Auch ohne Transkript: sagen, dass die neueste Folge noch für
            // unterwegs kommt.
            if stage == nil, hasLocalAudio || isDownloading || model.awaitsPrefetch(episode) {
                SwiftUI.Section { audioStatus }
            }

            if !facts.isEmpty {
                SwiftUI.Section {
                    if !topicTags.isEmpty {
                        TopicTagRow(tags: topicTags) { tag in
                            Task { await model.addInterest(tag.label, kind: .topic) }
                        }
                    }
                    ForEach(digestFacts) { fact in FactRow(fact: fact, episode: episode) }
                    if facts.count > 3 {
                        Button("Alle \(facts.count) Fakten") { section = .facts }
                    }
                } header: {
                    Text("Kurz gesagt")
                } footer: {
                    if topicTags.contains(where: { !$0.isInterest }) {
                        Text("Ein Tipp auf ein Thema mit Plus legt es als Interesse an.")
                    }
                }
            }

            if let mentions, !mentions.mentions.isEmpty {
                MentionsOverviewSection(episode: episode, mentions: mentions)
            }

            let episodeNotes = model.notes(for: episode.id)
            if !episodeNotes.isEmpty {
                SwiftUI.Section("Deine Notizen") {
                    // Antippen der Zeile spielt nichts. Abgespielt wird über
                    // den eigenen Knopf, der die Zeitmarke nennt.
                    ForEach(episodeNotes) { note in
                        HStack(alignment: .top, spacing: Design.Spacing.small) {
                            NoteRow(highlight: note, showsEpisode: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            NotePlayButton(highlight: note)
                            NoteActionsMenu(highlight: note)
                        }
                        .contextMenu { NoteActions(highlight: note) }
                    }
                }
            }

            if !chapters.isEmpty {
                SwiftUI.Section("Kapitel") {
                    ForEach(Array(chapters.prefix(4).enumerated()), id: \.offset) { _, chapter in
                        ChapterRow(chapter: chapter, episode: episode, chapters: chapters)
                    }
                    if chapters.count > 4 {
                        Button("Alle \(chapters.count) Kapitel") { section = .chapters }
                    }
                }
            }

            if let notes = ShownotesText.render(shown.shownotesHTML ?? shown.summary) {
                SwiftUI.Section {
                    ShownotesContent(
                        notes: notes, plain: String(notes.characters),
                        feedLanguage: model.sources.first(where: { $0.id == episode.sourceID })?.language)
                } header: {
                    Text("Shownotes")
                } footer: {
                    // Fremde Daten mit Herkunft: was Supadata ergänzt hat, steht da.
                    if let metadata = model.supadataMetadata(for: episode) {
                        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                            Label("Metadaten über Supadata", systemImage: "info.circle")
                            if !metadata.tags.isEmpty {
                                Text("Stichworte: \(metadata.tags.prefix(12).joined(separator: ", "))")
                            }
                        }
                        .accessibilityIdentifier("episode.supadataMetadata")
                    }
                }
            }
        }
        // Schlagworte aus Fakten, Belegen und Interessen. Neu, sobald sich
        // eines davon ändert, etwa nach dem Anlegen eines Interesses.
        .task(id: TopicTagInput(facts: facts.map(\.id), passages: passages.count,
                                interests: model.profile.confirmed.map(\.id))) {
            // Höchstens zehn, die eigenen Themen zuerst, danach die
            // häufigsten anderen Hauptwörter der Folge.
            topicTags = TopicTagger(maximumTags: TopicTagRow.maximumTags,
                                    maximumInterests: TopicTagRow.maximumTags)
                .tags(statements: facts.map(\.statement), passages: passages, profile: model.profile)
        }
    }

    /// Warum ein Transkript aufs Netz wartet, obwohl Ton auf dem Gerät liegt:
    /// die Datei gehört zu einer früheren Audioadresse, oder die Erkennung
    /// braucht erst das Sprachmodell.
    private var waitReasonWithLocalAudio: LocalizedStringKey {
        model.hasAudioForTranscript(episode)
            ? "Der Ton liegt schon auf dem Gerät. Das Sprachmodell für die Sprache dieser Folge lädt die App noch aus dem Netz."
            : "Der Podcast hat die Audiodatei geändert. Für das Transkript lädt die App die neue Fassung."
    }

    /// Worauf das Transkript dieser Folge im Netz wartet, oder `nil`.
    private var networkWait: AppModel.NetworkLimit? {
        if case .waiting(_, _, let limit?) = model.analysisPhase(for: episode) { return limit }
        return nil
    }

    // MARK: Audio auf dem Gerät

    /// Ob das Audio da ist, wie weit es lädt und warum es auf dem Gerät
    /// liegt: selbst geladen, neueste Folge oder nur bis zum Transkript.
    /// Gesagt wird das dort, wo man nachsieht.
    @ViewBuilder private var audioStatus: some View {
        if isDownloading {
            DownloadProgressRow(progress: model.downloadProgress[episode.id]) {
                model.cancelDownload(episode)
            }
            if audioVerdict == .newest {
                Text("Neueste Folge, wird für unterwegs geladen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if hasLocalAudio {
            Label {
                Text("Audio liegt auf diesem Gerät")
            } icon: {
                Image(systemName: "internaldrive").accessibilityHidden(true)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(Self.audioReason(audioVerdict))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("episode.audioReason")
            if audioVerdict.isTemporary {
                Text("Mit „Auf dem Gerät behalten“ im Menü bleibt es.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if stage?.isRunning != true, model.awaitsPrefetch(episode) {
            Label("Audio nicht auf dem Gerät", systemImage: "wifi")
                .font(.caption).foregroundStyle(.secondary)
            Text(prefetchNote)
                .font(.caption).foregroundStyle(.secondary)
        } else if stage == .evidenceExtracted, episode.audioURL != nil, model.removeAudioAfterAnalysis {
            Label("Audio nicht auf dem Gerät", systemImage: "wifi")
                .font(.caption).foregroundStyle(.secondary)
            Text("""
                Nach dem Transkript nimmt die App das Audio wieder vom Gerät, so ist es in den \
                Einstellungen eingestellt. Abgespielt wird aus dem Netz. Für unterwegs im Menü \
                „Laden (offline)“ wählen, das bleibt.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Was mit dem Audio dieser Folge geschieht, nach `AudioRetention`.
    private var audioVerdict: AudioRetention.Verdict { model.audioVerdict(for: episode) }

    /// Wann die neueste Folge aufs Gerät kommt. Sie lädt wie alles, was die
    /// App von selbst holt, nach der Regel „Nur im WLAN“. Wartet ihr
    /// Transkript, kommt der Ton erst mit ihm.
    private var prefetchNote: LocalizedStringKey {
        switch model.preparationWait {
        case .cellular?, .hotspot?: "Neueste Folge. Die App lädt sie für unterwegs, sobald WLAN da ist."
        case .offline?, .lowDataMode?: "Neueste Folge. Die App lädt sie für unterwegs, sobald das Netz es zulässt."
        case nil:
            model.analysisQueue.contains(where: { $0.id == episode.id })
                ? "Neueste Folge. Die App lädt sie mit dem Transkript und behält sie für unterwegs."
                : "Neueste Folge. Die App lädt sie gleich für unterwegs."
        }
    }

    /// Nimmt die App das Audio später von selbst weg? Dann bietet das Menü
    /// „Auf dem Gerät behalten“ an. Was jemand mit „Laden (offline)“ geholt
    /// hat, bleibt immer.
    private var removesAudioLater: Bool { hasLocalAudio && audioVerdict.isTemporary }

    /// Warum das Audio auf dem Gerät liegt, in einem Satz.
    static func audioReason(_ verdict: AudioRetention.Verdict) -> LocalizedStringKey {
        switch verdict {
        case .keptByUser: "Von dir geladen, bleibt bis „Audio entfernen“."
        case .newest: "Neueste Folge auf dem Gerät, bleibt für unterwegs, bis eine neuere geladen ist."
        case .removeAfterTranscript: "Wird nach dem Transkript entfernt, abgespielt wird dann aus dem Netz."
        case .removeAfterHeard: "Wird einen Tag nach dem Hören entfernt, abgespielt wird dann aus dem Netz."
        case .remove: "Wird bald entfernt, abgespielt wird dann aus dem Netz."
        case .stays: "Bleibt, bis du „Audio entfernen“ wählst."
        }
    }

    private struct TopicTagInput: Equatable {
        let facts: [String]
        let passages: Int
        let interests: [InterestID]
    }

    /// Zwei oder drei Aussagen über die ganze Folge verteilt, nicht nur
    /// die ersten Minuten.
    private var digestFacts: [EpisodeFact] {
        guard facts.count > 3 else { return facts }
        let step = Double(facts.count) / 3
        return (0..<3).map { facts[Int(Double($0) * step)] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.control) {
            EpisodeArtwork(url: episode.artworkURL ?? sourceArtwork, size: 160)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                if let source = model.sources.first(where: { $0.id == episode.sourceID }) {
                    Text(source.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(episode.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(4)
                HStack(spacing: Design.Spacing.small) {
                    if let published = episode.publishedAt { Text(published, style: .date) }
                    if let duration = episode.declaredDuration { Text(duration.shortDescription) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HeardProgress(fraction: model.heardFraction(for: episode))
            }
        }
        .padding(.vertical, Design.Spacing.small)
    }

    private var sourceArtwork: URL? {
        model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL
    }

    /// Der Hauptknopf steht allein über die ganze Breite. Neben zwei
    /// Symbolknöpfen wurde „Pause“ bei großer Schrift mitten im Wort
    /// getrennt. Die Nebenknöpfe darunter tragen ein Wort.
    private var playControls: some View {
        VStack(spacing: Design.Spacing.small) {
            if model.canPlay(episode) {
                Button {
                    if isCurrent { player.togglePlayPause() } else { model.playEpisode(episode) }
                } label: {
                    Label(playLabel, systemImage: isCurrent && player.isPlayingOrStarting ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("episode.play")
            } else if let url = episode.webPageURL {
                // Ohne Audiodatei (YouTube) gibt es hier nichts zu hören.
                // Der Knopf führt dorthin, wo es die Folge gibt.
                Button { openURL(url) } label: {
                    Label(episode.webLinkTitle, systemImage: episode.webLinkSymbol)
                        .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("episode.openWeb")
            }

            if showsUpNextMenu || showsTranscriptButton {
                // Nebeneinander mit dem Wort unter dem Symbol. Passt das nicht
                // mehr, etwa bei großer Schrift, untereinander über die ganze
                // Breite, Symbol und Wort in einer Zeile.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Spacing.small) { secondaryControls }
                        .labelStyle(IconAboveTitleLabelStyle())
                        .buttonBorderShape(.roundedRectangle(radius: Design.Radius.card))
                    VStack(spacing: Design.Spacing.small) { secondaryControls }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                }
            }
        }
    }

    /// Die laufende Folge lässt sich nicht einreihen. Statt eines grauen
    /// Knopfs ohne Erklärung fehlt er dann.
    private var showsUpNextMenu: Bool { model.canPlay(episode) && !isCurrent }

    /// Wartet das Transkript aufs Netz, steht „Jetzt erstellen“ schon in der
    /// Zeile darunter. Ein zweiter Knopf dafür wäre doppelt.
    private var showsTranscriptButton: Bool {
        model.canTranscribe(episode) && (stage == nil || stage == .failed) && networkWait == nil
    }

    @ViewBuilder private var secondaryControls: some View {
        if showsUpNextMenu { upNextMenu }
        if showsTranscriptButton { transcriptButton }
    }

    /// Antippen reiht die Folge direkt hinter der laufenden ein, gedrückt
    /// halten bietet auch „Ans Ende“ an. Steht sie schon in der
    /// Warteschlange, sagt der Knopf das und trägt ein Häkchen.
    private var upNextMenu: some View {
        let position = model.upNext.firstIndex { $0.id == episode.id }
        let title: LocalizedStringKey = switch position {
        case nil: "Als Nächstes"
        case 0: "Kommt als Nächstes"
        default: "In der Warteschlange"
        }
        let symbol = position == nil ? "text.line.first.and.arrowtriangle.forward" : "checkmark"
        let value = position == nil ? Text(verbatim: "") : Text(title)
        return Menu {
            Button { queue(.next) } label: {
                Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { queue(.last) } label: {
                Label("Ans Ende", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            if position != nil {
                Button(role: .destructive) { model.removeFromUpNext(episode.id) } label: {
                    Label("Aus der Warteschlange nehmen", systemImage: "minus.circle")
                }
            }
        } label: {
            // Name und Wert auch innen: ein Menü im Inhalt bringt einen
            // eigenen Knopf für seine Beschriftung mit, der sonst leer blieb.
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Als Nächstes hören")
                .accessibilityValue(value)
        } primaryAction: {
            queue(.next)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Als Nächstes hören")
        .accessibilityValue(value)
        .accessibilityAction(named: "Ans Ende der Warteschlange") { queue(.last) }
    }

    private var transcriptButton: some View {
        Button {
            model.enqueueAnalysis(episode)
        } label: {
            Label(stage == .failed ? "Transkript erneut erstellen" : "Transkript erstellen",
                  systemImage: "waveform.badge.magnifyingglass")
                .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
        }
        .buttonStyle(.bordered)
        // Derselbe Schlüssel wie im AppModel, damit der Vergleich auch
        // in einer Übersetzung trifft.
        .disabled(model.stageDetails[episode.id] == String(localized: "wartet"))
        .accessibilityLabel(stage == .failed ? "Transkript erneut erstellen" : "Transkript erstellen")
    }

    /// Reiht die Folge ein und sagt es VoiceOver, denn sonst ändert sich
    /// auf der Seite nur die Beschriftung des Knopfs.
    private func queue(_ placement: AppModel.UpNextPlacement) {
        model.addToUpNext(episode, placement: placement)
        AccessibilityNotification.Announcement(placement == .next
            ? AttributedString(localized: "Kommt als Nächstes")
            : AttributedString(localized: "Steht am Ende der Warteschlange")).post()
    }

    private var playLabel: LocalizedStringKey {
        if isCurrent { return player.isPlayingOrStarting ? "Pause" : "Weiter" }
        let resume = model.resumePosition(for: episode)
        guard resume > 5 else { return "Abspielen" }
        return "Weiter ab \(MediaTime(milliseconds: Int64(resume * 1000)).timecode)"
    }

    // MARK: Kapitel

    private var chapterList: some View {
        List {
            if chapters.isEmpty {
                ContentUnavailableView("Keine Kapitel", systemImage: "list.bullet",
                                       description: Text("Der Podcast liefert für diese Folge keine Kapitelmarken."))
            }
            ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                ChapterRow(chapter: chapter, episode: episode, chapters: chapters)
            }
        }
    }

    // MARK: Fakten

    private var factList: some View {
        List {
            if facts.isEmpty {
                SwiftUI.Section {
                    if model.factsInProgress.contains(episode.id) {
                        FactsGatheringRow(title: "Fakten werden gesammelt …",
                                          progress: model.factsProgress[episode.id], detail: nil)
                    } else if passages.isEmpty {
                        // Von selbst kommen die Fakten nur, wenn „Fakten automatisch
                        // sammeln“ an ist. Sonst holt sie „Jetzt ermitteln“.
                        EpisodeAnalysisPrompt(episode: episode, style: .inline(model.automaticFacts
                            ? String(localized: """
                                Sobald das Transkript fertig ist, zieht die App überprüfbare Aussagen \
                                mit Zeitmarke heraus.
                                """)
                            : String(localized: """
                                Sobald das Transkript fertig ist, lassen sich hier überprüfbare Aussagen \
                                mit Zeitmarke ermitteln.
                                """)))
                    } else if let position = model.factsQueuePosition(of: episode.id) {
                        // Wartet in der Warteschlange. Der Knopf holt die Folge nur nach vorn.
                        FactsGatheringRow(title: "Fakten werden gesammelt …", progress: nil,
                                          detail: factsQueueDetail(position: position),
                                          paused: model.factsWait != nil)
                        if position > 0, model.factsWait == nil {
                            requestFactsButton
                        }
                    } else if case .failure(let reason) = model.modelStatus.resolve(.extract) {
                        // Ohne Apple Intelligence gibt es keine Fakten. Das steht hier,
                        // statt dass ein Knopf ohne Wirkung angeboten wird.
                        NoticeLabel(reason.message, kind: .info)
                    } else {
                        // Nicht eingereiht: ausgeschaltet, gescheitert oder ohne Ergebnis.
                        if let issue = model.factsIssues[episode.id] {
                            Text(issue).font(.callout).foregroundStyle(.secondary)
                        }
                        requestFactsButton
                    }
                }
            } else {
                let wording = model.factWording(facts, passages: passages)
                SwiftUI.Section {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: Design.Spacing.none) {
                            FactRow(fact: fact, episode: episode)
                                .buttonStyle(.borderless)
                            if let text = wording[fact.id] { FactWording(text: text, fact: fact, episode: episode) }
                        }
                    }
                } footer: {
                    let tier = Self.factAuthor(facts.first?.modelTier)
                    Text("""
                        Aussagen aus der Folge, gesagt, nicht geprüft. Antippen spielt den Satz. \
                        Unter „Wortlaut zeigen“ steht, was genau gesagt wurde. Über „…“ merkst, \
                        kopierst oder teilst du eine Aussage. Formuliert von: \(tier).
                        """)
                }
                SwiftUI.Section {
                    if model.factsInProgress.contains(episode.id) {
                        FactsGatheringRow(title: "Fakten werden neu ermittelt …",
                                          progress: model.factsProgress[episode.id], detail: nil)
                    } else if let position = model.factsQueuePosition(of: episode.id) {
                        FactsGatheringRow(title: "Fakten werden neu ermittelt …", progress: nil,
                                          detail: factsQueueDetail(position: position),
                                          paused: model.factsWait != nil)
                    } else {
                        // Etwa: unvollständig, der Rest kommt bei einem späteren Lauf.
                        if let issue = model.factsIssues[episode.id] {
                            Text(issue).font(.callout).foregroundStyle(.secondary)
                        }
                        Button {
                            model.requestFacts(for: episode)
                        } label: { Label("Neu ermitteln", systemImage: "arrow.clockwise") }
                    }
                }
            }
        }
    }

    /// Holt die Folge in der Warteschlange der Fakten nach vorn.
    private var requestFactsButton: some View {
        Button {
            model.requestFacts(for: episode)
        } label: { Label("Jetzt ermitteln", systemImage: "checkmark.seal") }
        .accessibilityIdentifier("facts.request")
    }

    /// Warum die Folge noch wartet: auf das Modell oder auf die Folgen davor.
    private func factsQueueDetail(position: Int) -> String {
        if let wait = model.factsWait { return wait }
        let ahead = position + (model.gatheringFacts == nil ? 0 : 1)
        guard ahead > 0 else { return String(localized: "startet gleich") }
        return String(AttributedString(localized: "wartet, noch ^[\(ahead) Folge](inflect: true) davor").characters)
    }

    /// Wer die Fakten formuliert hat, in der Sprache der App.
    ///
    /// Gespeichert ist die Kennung der Stufe, etwa `onDevice`. Fakten aus
    /// älteren Versionen tragen noch die Bezeichnung in der Sprache, in der
    /// sie entstanden sind. „Auf dem Gerät“ und nicht „auf diesem Gerät“:
    /// über iCloud kommen auch Fakten, die ein anderes Gerät formuliert hat.
    /// Was keiner Stufe entspricht, steht wörtlich da. Nur „Beispieldaten“
    /// kommt in der Sprache der App, sonst stünde es mitten im englischen Satz.
    static func factAuthor(_ stored: String?) -> String {
        let stored = stored ?? ""
        let tier: ModelTier? = switch stored {
        case "Auf diesem Gerät", "On This Device": .onDevice
        default: ModelTier(rawValue: stored)
        }
        switch tier {
        case .onDevice: return String(localized: "Apple Intelligence auf dem Gerät")
        case .privateCloudCompute: return String(localized: "Apple Intelligence über Private Cloud Compute")
        case nil where stored == "Beispieldaten": return String(localized: "Beispieldaten")
        case nil: return stored.isEmpty ? "Apple Intelligence" : stored
        }
    }
}

private extension View {
    /// Beschriftung von Tempo und Schlaf-Timer: eine Zeile, notfalls etwas
    /// kleiner, nie mitten im Wort getrennt („Schla / f- / Timer“).
    func optionLabel() -> some View {
        font(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Design.Spacing.control)
            .padding(.vertical, Design.Spacing.small)
    }
}

/// Symbol über dem Wort, für die Nebenknöpfe unter „Abspielen“.
private struct IconAboveTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Design.Spacing.micro) {
            configuration.icon
            configuration.title
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
    }
}

/// „Fakten werden gesammelt …“, solange eine Folge in der Warteschlange der
/// Fakten steht oder gerade dran ist. Läuft sie, zeigt ein Balken, wie weit.
/// Fortschritt eines Downloads für unterwegs: Balken, „23 von 70 MB“ und
/// ein Knopf zum Abbrechen. Bei schlechtem Netz sieht man so, ob es läuft.
struct DownloadProgressRow: View {
    let progress: AppModel.DownloadProgress?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Audio wird geladen")
            } else {
                ProgressView()
                    .accessibilityLabel("Audio wird geladen")
            }
            HStack {
                Text(sizeText)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", action: cancel)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Laden abbrechen")
                    .accessibilityIdentifier("episode.download.cancel")
            }
        }
    }

    private var sizeText: String {
        guard let progress, progress.received > 0 || progress.expected != nil else {
            return String(localized: "Audio wird geladen …")
        }
        let received = progress.received.formatted(.byteCount(style: .file))
        guard let expected = progress.expected else {
            return String(localized: "\(received) geladen")
        }
        let total = expected.formatted(.byteCount(style: .file))
        return String(localized: "\(received) von \(total)")
    }
}

private struct FactsGatheringRow: View {
    let title: LocalizedStringKey
    let progress: Double?
    let detail: String?
    /// Die Warteschlange steht, weil das Modell fehlt: eine Uhr statt eines Kreisels.
    var paused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            HStack(spacing: Design.Spacing.small) {
                if paused {
                    Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title)
            }
            if let progress {
                ProgressView(value: progress)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("facts.gathering")
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let episode: Episode
    let chapters: [Chapter]
    @Environment(AppModel.self) private var model

    private var isCurrent: Bool {
        model.episodePlayer.episode?.id == episode.id
            && model.episodePlayer.currentChapter?.start == chapter.start
    }

    var body: some View {
        Button {
            model.playEpisode(episode, at: chapter.start.seconds)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                TimecodeLabel(chapter.start)
                    .frame(minWidth: 56, alignment: .leading)
                Text(chapter.title)
                    .foregroundStyle(.primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer()
                if heard {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("gehört")
                }
            }
        }
    }

    private var heard: Bool {
        guard let id = episode.streamMediaVersionID else { return false }
        let next = chapters.first { $0.start.milliseconds > chapter.start.milliseconds }
        let endMs = next?.start.milliseconds
            ?? episode.declaredDuration.map { Int64($0.seconds * 1000) }
            ?? chapter.start.milliseconds + 60_000
        guard endMs > chapter.start.milliseconds else { return false }
        return model.hasHeard(MediaTimeRange(start: chapter.start, end: MediaTime(milliseconds: endMs)), in: id)
    }
}

struct FactRow: View {
    let fact: EpisodeFact
    let episode: Episode
    @Environment(AppModel.self) private var model
    /// Was in der Folge gesagt wurde: der Satz aus dem Beleg, an dem die
    /// Zeitmarke steht. Nur er wird wörtlich zitiert.
    @State private var quote: String?

    var body: some View {
        // Zwei Knöpfe nebeneinander, beide mit eigenem Stil: in einer Liste
        // löste ein Tipp sonst beide zugleich aus.
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            Button {
                model.playEpisode(episode, at: fact.range.start.seconds)
            } label: {
                HStack(alignment: .top, spacing: Design.Spacing.small) {
                    // Eine Aussage aus der Folge, kein geprüfter Fakt. Ein Siegel
                    // hätte das Gegenteil behauptet. VoiceOver liest nur Aussage und Zeitmarke.
                    Image(systemName: "quote.bubble").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                        Text(fact.statement).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        HStack(spacing: Design.Spacing.micro) {
                            TimecodeLabel(fact.range.start)
                            Image(systemName: "play.fill").font(.caption2).foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            if model.hasNote(in: episode.id, at: fact.range.start) {
                                Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.tint)
                                    .accessibilityLabel("gemerkt")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Spielt die Stelle, aus der die Aussage stammt")

            Menu {
                FactActions(fact: fact, episode: episode, quote: quote)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .tappableArea()
                    .contentShape(.rect)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .accessibilityLabel("Aktionen zur Aussage")
            .accessibilityHint("Merken, mit Quelle kopieren oder teilen")
        }
        .contextMenu {
            FactActions(fact: fact, episode: episode, quote: quote)
        }
        .task(id: fact) { quote = await model.factQuote(fact) }
    }
}

/// Merken, Kopieren und Teilen für einen Fakt. Die Aussage hat das Modell
/// formuliert. Wörtlich zitiert und gemerkt wird deshalb, was in der Folge
/// gesagt wurde: der Satz aus dem Beleg, an dem die Zeitmarke steht, wie
/// unter „Wortlaut zeigen“. Die Aussage steht beim Kopieren als
/// Zusammenfassung daneben.
struct FactActions: View {
    let fact: EpisodeFact
    let episode: Episode
    let quote: String?
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm

    var body: some View {
        Button {
            model.playEpisode(episode, at: fact.range.start.seconds)
        } label: {
            Label("Ab hier abspielen", systemImage: "play.fill")
        }
        Button {
            Self.remember(fact, quote: quote, in: episode, model: model, confirm: confirm)
        } label: {
            Label("Stelle merken", systemImage: "bookmark")
        }
        Button {
            Self.copy(fact, quote: quote, in: episode, model: model, confirm: confirm)
        } label: {
            Label("Mit Quelle kopieren", systemImage: "doc.on.doc")
        }
        ShareLink(item: model.factCitation(fact, quote: quote, in: episode)) {
            Label("Teilen", systemImage: "square.and.arrow.up")
        }
    }

    /// Merkt die Stelle mit ihrem Wortlaut und sagt, wo die Notiz liegt.
    /// Ohne Beleg füllt addNote das Zitat aus dem Transkript.
    static func remember(_ fact: EpisodeFact, quote: String?, in episode: Episode,
                         model: AppModel, confirm: ConfirmAction) {
        Task {
            let saved = await model.addNote(nil, at: fact.range.start.seconds, in: episode, quote: quote,
                                            evidenceID: quote == nil ? nil : fact.evidenceID,
                                            mediaVersionID: fact.mediaVersionID, via: .transcript)
            if let saved { confirm(NoteFeedback.saved(saved), symbol: "bookmark.fill") }
        }
    }

    static func copy(_ fact: EpisodeFact, quote: String?, in episode: Episode,
                     model: AppModel, confirm: ConfirmAction) {
        Clipboard.copy(model.factCitation(fact, quote: quote, in: episode))
        confirm(NoteFeedback.copied)
    }
}

/// Was in der Folge zu einer Aussage wörtlich gesagt wurde, auf Wunsch.
/// Ist der Wortlaut in einer anderen Sprache als die App, zeigt
/// „Übersetzen“ eine Übersetzung darüber. Der Wortlaut selbst bleibt.
struct FactWording: View {
    let text: String
    /// Mit Aussage und Folge stehen unter dem Wortlaut „Zitat kopieren“ und
    /// „Merken“, sichtbar statt nur über langes Drücken.
    var fact: EpisodeFact? = nil
    var episode: Episode? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm
    @State private var shown = false
    @State private var foreign = false
    @State private var translating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            HStack(spacing: Design.Spacing.standard) {
                Button {
                    withAnimation { shown.toggle() }
                } label: {
                    // Das Symbol ist Schmuck. VoiceOver las „Liedtext“.
                    Label {
                        Text(shown ? "Wortlaut ausblenden" : "Wortlaut zeigen")
                    } icon: {
                        Image(systemName: shown ? "chevron.up" : "text.quote").accessibilityHidden(true)
                    }
                    .font(.caption)
                    .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                if shown, foreign {
                    TranslateTextButton(isPresented: $translating)
                        .font(.caption)
                        .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                        .buttonStyle(.borderless)
                }
            }
            if shown {
                Text("„\(text)“")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, fact == nil ? Design.Spacing.small : Design.Spacing.none)
                    .translationPresentation(isPresented: $translating, text: text)
                if let fact, let episode {
                    HStack(spacing: Design.Spacing.standard) {
                        Button {
                            FactActions.copy(fact, quote: text, in: episode, model: model, confirm: confirm)
                        } label: {
                            Label("Zitat kopieren", systemImage: "doc.on.doc")
                        }
                        .accessibilityHint("Kopiert den Wortlaut mit Folge, Podcast, Zeitmarke und Erscheinungsdatum")
                        Button {
                            FactActions.remember(fact, quote: text, in: episode, model: model, confirm: confirm)
                        } label: {
                            Label("Merken", systemImage: "bookmark")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                    .padding(.bottom, Design.Spacing.small)
                }
            }
        }
        // Eingerückt unter den Text der Aussage, neben dem Symbol.
        .padding(.leading, 28)
        .task(id: text) { foreign = AppLanguage.current.isForeign(text) }
    }
}

/// Die Themen einer Folge als Schlagworte. Ein Tipp auf ein neues Thema
/// legt es als Interesse an; bekannte Interessen tragen ein Häkchen.
///
/// Umbrechend statt seitlich gescrollt: Alle Schlagworte sind auf einen
/// Blick da. Deshalb sind es höchstens ``maximumTags``, die eigenen Themen
/// zuerst.
struct TopicTagRow: View {
    let tags: [TopicTag]
    let add: (TopicTag) -> Void

    /// Mehr als zehn liest niemand, und die Liste darunter rückt zu weit weg.
    static let maximumTags = 10

    var body: some View {
        // Kein Zeilenabstand: Jeder Chip ist zum Antippen 44 Punkt hoch,
        // die sichtbare Kapsel kleiner. Der Rest ist schon Luft genug.
        FlowLayout(spacing: Design.Spacing.small, lineSpacing: Design.Spacing.none) {
            ForEach(tags.prefix(Self.maximumTags)) { tag in
                Button {
                    if !tag.isInterest { add(tag) }
                } label: {
                    Label(tag.label, systemImage: tag.isInterest ? "checkmark" : "plus")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Design.Spacing.control)
                        .padding(.vertical, Design.Spacing.micro + 2)
                        .background(Capsule().fill(tag.isInterest
                            ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
                        .frame(minHeight: Design.minimumTapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tag.isInterest ? Text("\(tag.label), schon ein Interesse")
                                                   : Text("Thema \(tag.label)"))
                .accessibilityHint(tag.isInterest ? Text(verbatim: "") : Text("Legt das Thema als Interesse an"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Themen der Folge")
    }
}

/// Merken, Kopieren und Teilen für eine Stelle mit Zeitmarke.
struct PassageActions: View {
    let text: String
    let start: MediaTime
    let episode: Episode
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm

    var body: some View {
        Button {
            model.playEpisode(episode, at: start.seconds)
        } label: {
            Label("Ab hier abspielen", systemImage: "play.fill")
        }
        Button {
            Self.remember(text, at: start, in: episode, model: model, confirm: confirm)
        } label: {
            Label("Stelle merken", systemImage: "bookmark")
        }
        Button {
            Clipboard.copy(model.citation(text, at: start, in: episode))
            confirm(NoteFeedback.copied)
        } label: {
            Label("Mit Quelle kopieren", systemImage: "doc.on.doc")
        }
        ShareLink(item: model.citation(text, at: start, in: episode)) {
            Label("Teilen", systemImage: "square.and.arrow.up")
        }
    }

    /// Merkt genau diese Zeile: ihren Text und ihren Anfang als Zeitmarke.
    static func remember(_ text: String, at start: MediaTime, in episode: Episode,
                         model: AppModel, confirm: ConfirmAction) {
        Task {
            if let saved = await model.addNote(nil, at: start.seconds, in: episode, quote: text) {
                confirm(NoteFeedback.saved(saved), symbol: "bookmark.fill")
            }
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Das Transkript mit Zeitmarken. Antippen springt an die Stelle, die
/// laufende Stelle ist hervorgehoben, Gehörtes ist abgeblendet.
///
/// Ist das Transkript in einer anderen Sprache als die App, lässt es sich
/// auf dem Gerät übersetzen. Merken, Kopieren und Teilen nehmen trotzdem
/// den Originaltext: zitiert wird, was gesagt wurde.
struct TranscriptSection: View {
    let episode: Episode
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm
    @State private var paragraphs: [(start: MediaTime, text: String)] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var translation = ParagraphTranslation()
    /// Die Sprache des Transkripts, wenn sie nicht die der App ist.
    @State private var foreignSource: Locale.Language?
    /// Woher der Text kommt, wenn nicht aus der Spracherkennung, etwa
    /// „Untertitel von YouTube über Supadata“.
    @State private var originLabel: String?

    private var filtered: [(start: MediaTime, text: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return paragraphs }
        // Mit sichtbarer Übersetzung sucht die Suche auch in ihr.
        return paragraphs.filter { paragraph in
            paragraph.text.localizedCaseInsensitiveContains(trimmed)
                || (translation.isShown
                    && translation.texts[paragraph.start.milliseconds]?.localizedCaseInsensitiveContains(trimmed) == true)
        }
    }

    private var keyedParagraphs: [(key: Int64, text: String)] {
        paragraphs.map { (key: $0.start.milliseconds, text: $0.text) }
    }

    /// Was in der Zeile steht: die Übersetzung, sobald es sie gibt und sie
    /// gezeigt wird, sonst das Original.
    private func shownText(_ paragraph: (start: MediaTime, text: String)) -> String {
        guard translation.isShown else { return paragraph.text }
        return translation.texts[paragraph.start.milliseconds] ?? paragraph.text
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Die Suche steht im Inhalt, nicht in der Navigationsleiste.
                // Dort schob sie sich über die Reiter, und alles sprang.
                if !paragraphs.isEmpty {
                    HStack(spacing: Design.Spacing.small) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Im Transkript suchen", text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("transcript.search")
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Suche leeren")
                        }
                    }
                    if foreignSource != nil {
                        TranslationControl(
                            translation: translation, identifier: "transcript.translate",
                            note: "Auf dem Gerät übersetzt. Merken und Kopieren nehmen den Originaltext.",
                            paragraphs: keyedParagraphs
                        )
                    }
                }
                if loaded && paragraphs.isEmpty {
                    let unavailable = model.analysisUnavailableReason(for: episode)
                    ContentUnavailableView {
                        Label(unavailable == nil ? "Noch kein Transkript" : "Kein Transkript",
                              systemImage: "text.alignleft")
                    } description: {
                        if let unavailable {
                            Text(unavailable)
                        } else {
                            Text("Die App erstellt das Transkript auf dem Gerät, mit Zeitmarken.")
                        }
                    } actions: {
                        EpisodeAnalysisPrompt(episode: episode)
                    }
                }
                if let originLabel, !paragraphs.isEmpty {
                    Label(originLabel, systemImage: "captions.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("transcript.origin")
                }
                if !paragraphs.isEmpty {
                    if episode.audioURL == nil && episode.opensInYouTube {
                        Text("Antippen öffnet das Video bei YouTube an dieser Stelle. Über „…“ merkst, kopierst oder teilst du sie.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Antippen spielt ab dieser Zeile. Über „…“ merkst, kopierst oder teilst du sie.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(filtered.enumerated()), id: \.element.start) { _, paragraph in
                    HStack(alignment: .top, spacing: Design.Spacing.small) {
                        Button {
                            model.playEpisode(episode, at: paragraph.start.seconds)
                        } label: {
                            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                                HStack(spacing: Design.Spacing.micro) {
                                    TimecodeLabel(paragraph.start,
                                                  emphasis: isCurrent(paragraph.start) ? .bold : .regular)
                                    if model.hasNote(in: episode.id, at: paragraph.start) {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel("gemerkt")
                                    }
                                }
                                Text(shownText(paragraph))
                                    .font(.callout)
                                    .foregroundStyle(isHeard(paragraph.start) ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, Design.Spacing.micro)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        // Schlicht, damit der Text schwarz bleibt und nicht als Link blau erscheint.
                        .buttonStyle(.plain)
                        .accessibilityHint("Spielt ab dieser Zeile")

                        // Sichtbar an jeder Zeile, nicht nur über langes
                        // Drücken oder Wischen, die niemand errät.
                        Menu {
                            PassageActions(text: paragraph.text, start: paragraph.start, episode: episode)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .imageScale(.large)
                                .foregroundStyle(.tint)
                                .tappableArea()
                                .contentShape(.rect)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Aktionen zur Zeile ab \(TimecodeLabel.spoken(paragraph.start.timecode))")
                        .accessibilityHint("Merken, mit Quelle kopieren oder teilen")
                    }
                    .listRowBackground(isCurrent(paragraph.start) ? Color.accentColor.opacity(0.1) : nil)
                    .swipeActions(edge: .leading) {
                        Button { remember(paragraph) } label: { Label("Merken", systemImage: "bookmark") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        PassageActions(text: paragraph.text, start: paragraph.start, episode: episode)
                    }
                    .id(paragraph.start.milliseconds)
                }
            }
            .onChange(of: currentStart) { _, start in
                guard let start, query.isEmpty else { return }
                withAnimation { proxy.scrollTo(start, anchor: .center) }
            }
        }
        // Mit der Stufe als Schlüssel: endet die Erschließung, während der
        // Reiter offen ist, erscheint das Transkript ohne Umweg.
        .task(id: model.stages[episode.id]) {
            if let transcript = await model.transcript(for: episode) {
                paragraphs = EpisodeDossierExporter.paragraphs(transcript.segments, seconds: 30)
                originLabel = transcript.origin.sourceLabel
                let language = AppLanguage.current
                foreignSource = language.matches(transcript.locale) == false
                    ? AppLanguage.translationSource(transcript.locale) : nil
                if foreignSource != nil {
                    await translation.prepare(
                        source: foreignSource,
                        cacheKey: TranslationCache.Key(
                            episodeID: episode.id, transcriptID: transcript.id, target: language),
                        paragraphs: keyedParagraphs)
                }
            }
            loaded = true
        }
        .translationTask(translation.configuration) { @Sendable [translation] session in
            await ParagraphTranslation.run(session, for: translation)
        }
        // Mit der Ansicht endet die Sitzung, etwa beim Wechsel des Tabs.
        // Kommt sie zurück, geht die Übersetzung dort weiter, wo sie stand.
        .onAppear { translation.viewAppeared() }
        .onDisappear { translation.viewDisappeared() }
    }

    private var currentStart: Int64? {
        guard model.episodePlayer.episode?.id == episode.id else { return nil }
        let now = model.episodePlayer.currentTime
        return paragraphs.last { $0.start.seconds <= now + 0.5 }?.start.milliseconds
    }

    private func isCurrent(_ start: MediaTime) -> Bool { currentStart == start.milliseconds }

    private func remember(_ paragraph: (start: MediaTime, text: String)) {
        PassageActions.remember(paragraph.text, at: paragraph.start, in: episode, model: model, confirm: confirm)
    }

    private func isHeard(_ start: MediaTime) -> Bool {
        guard let id = episode.streamMediaVersionID else { return false }
        let range = MediaTimeRange(start: start, end: MediaTime(milliseconds: start.milliseconds + 20_000))
        return model.hasHeard(range, in: id)
    }
}

private struct PassageRow: View {
    let passage: Evidence
    let range: MediaTimeRange
    let heard: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.small) {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                TimecodeLabel(range, emphasis: .medium)
                Text(passage.quotedText)
                    .font(.callout)
                    .foregroundStyle(heard ? .secondary : .primary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Image(systemName: heard ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(heard ? Color.secondary : Color.accentColor)
                .accessibilityLabel(heard ? "gehört" : "noch nicht gehört")
        }
    }
}

struct HeardProgress: View {
    let fraction: Double

    var body: some View {
        if fraction > 0.01 {
            HStack(spacing: Design.Spacing.small) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 120)
                Text(fraction > 0.97 ? "gehört"
                     : "\(fraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))) gehört")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct EpisodeArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 8))
        .accessibilityHidden(true)
    }
}

// MARK: - Player

/// Der große Player für eine ganze Folge.
struct EpisodePlayerView: View {

    /// Eingebettet statt als Sheet, etwa in der Mac-Seitenleiste unter
    /// „Wiedergabe“. Dann ohne eigenen NavigationStack und ohne „Fertig“,
    /// denn es gibt nichts zu schließen.
    var isEmbedded = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubbing: Double?
    @State private var showingNote = false
    /// Tempo oder Schlaf-Timer als Blatt mit scrollbarer Liste. Nur bei
    /// großer Schrift: dort passte das Menü nicht auf den Bildschirm.
    @State private var choosing: PlayerChoice?

    private enum PlayerChoice: Identifiable {
        case rate, sleep
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .rate: "Geschwindigkeit"
            case .sleep: "Schlaf-Timer"
            }
        }
    }
    /// Folge, Stelle, Zitat und Text aus „Moment merken“. Endet die Folge,
    /// während der Kommentar entsteht, und die nächste beginnt, bleibt die
    /// Notiz bei der Folge, in der sie begonnen wurde.
    @State private var note = MomentNoteDraft()

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        // Nach „Merken“ steht kurz da, bei welcher Zeit und wo die Notiz liegt.
        .confirmationBanner()
    }

    @ViewBuilder private var content: some View {
        Group {
            if let episode = player.episode {
                ScrollView {
                    VStack(spacing: Design.Spacing.control) {
                        EpisodeArtwork(url: episode.artworkURL ?? artwork(for: episode), size: 260)
                            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                            .padding(.top, Design.Spacing.section)
                        VStack(spacing: Design.Spacing.micro) {
                            Text(episode.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if let podcast = model.sources.first(where: { $0.id == episode.sourceID })?.title {
                                Text(podcast)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            if let chapter = player.currentChapter {
                                Text(chapter.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.tint)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        if let error = player.playbackError {
                            NoticeLabel(error, kind: .failure)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("player.error")
                        } else if player.isBuffering {
                            HStack(spacing: Design.Spacing.small) {
                                ProgressView()
                                Text("Audio wird geladen …")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        scrubber
                        transport
                        Button {
                            note.begin(in: episode, at: player.currentTime)
                            showingNote = true
                        } label: {
                            Label("Moment merken", systemImage: "bookmark")
                                .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("player.note")
                        .accessibilityHint("Merkt den Satz, der gerade läuft, auf Wunsch mit Kommentar")
                        optionsRow
                        if !player.chapters.isEmpty { chapterList }
                    }
                    .padding(.horizontal)
                }
                .navigationTitle("Jetzt läuft")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if !isEmbedded {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fertig") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            QueueView()
                        } label: {
                            Label("Warteschlange", systemImage: "list.bullet")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Nichts läuft", systemImage: "play.slash")
                    .toolbar {
                        if !isEmbedded {
                            ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                        }
                    }
            }
        }
        // Außerhalb des `if let`: endet die Folge oder beginnt die nächste,
        // während der Kommentar entsteht, bleibt das Blatt samt Text offen.
        //
        // Wird die Wiedergabe ganz beendet, etwa über Siri, über das Menü auf
        // dem Mac oder weil die Folge auf einem anderen Gerät gelöscht wurde,
        // verschwindet der Player und das Blatt mit ihm. Dann wird der Moment
        // mit dem Text gemerkt, der bis dahin dasteht, statt verloren zu gehen.
        // Nichts gemerkt wird nur nach „Abbrechen“. Deshalb schließt das
        // Blatt nicht durch Wischen: das wäre weder das eine noch das andere.
        .sheet(isPresented: $showingNote) {
            // Hier festgehalten und nicht erst beim Verschwinden gelesen:
            // dann ist der Player womöglich schon abgebaut.
            let draft = note
            let appModel = model
            if draft.episode != nil {
                MomentNoteSheet(draft: draft, model: appModel)
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled()
                    .onDisappear { draft.save(with: appModel) }
                    .sheetFeedback()
                    .environment(appModel)
            }
        }
    }

    private func artwork(for episode: Episode) -> URL? {
        model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL
    }

    private var scrubber: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: Design.Spacing.micro) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...total
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            // Name, Wert und Schritte auch am Regler selbst. Erscheint er
            // trotz der Zusammenfassung unten als eigenes Element, hiess er
            // sonst nur „3 %“, und der Wert blieb über Minuten gleich.
            .accessibilityLabel("Position")
            .accessibilityValue(positionValue)
            .accessibilityAdjustableAction(adjustPosition)
            HStack {
                Text(Self.format(scrubbing ?? player.currentTime))
                Spacer()
                Text(verbatim: "-" + Self.format(max(0, total - (scrubbing ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // Für VoiceOver ein Element mit hörbarem Wert. Wischen nach oben
        // oder unten springt wie die Sprungknöpfe, statt um ein Zehntel der Folge.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(positionValue)
        .accessibilityAdjustableAction(adjustPosition)
    }

    /// „12 Minuten und 5 Sekunden von 53 Minuten“. Die Stelle genau, damit
    /// jeder Sprung hörbar etwas ändert, die Länge in vollen Minuten.
    private var positionValue: Text {
        let now = Self.spoken(scrubbing ?? player.currentTime)
        guard player.duration > 0 else { return Text(now) }
        let total = player.duration < 60 ? Self.spoken(player.duration)
            : Duration.seconds(Int(player.duration)).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return Text("\(now) von \(total)")
    }

    private func adjustPosition(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: player.skipAhead()
        case .decrement: player.skipBack()
        @unknown default: break
        }
    }

    /// Eine Zeitangabe zum Vorlesen, etwa „12 Minuten und 30 Sekunden“.
    /// Einzahl, Mehrzahl und Wortstellung kommen aus der Gerätesprache.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(Int(max(0, seconds)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private var transport: some View {
        // ⏭ springt zum nächsten Kapitel. Kommt keins mehr, startet die
        // nächste Folge aus der Warteschlange, wie mit der Kopfhörertaste.
        // Gibt es beides nicht, ist der Knopf gesperrt und sieht auch so aus.
        let hasNextChapter = player.nextChapterStart != nil
        let hasNextEpisode = !model.upNext.isEmpty
        return HStack(spacing: Design.Spacing.control * 1.5) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill").tappableArea()
            }
            .accessibilityLabel("Vorheriges Kapitel")
            .disabled(player.chapters.isEmpty)
            // Gedrückt halten wählt die Sprungweite.
            Button { player.skipBack() } label: {
                Image(systemName: "gobackward.\(player.skipBackward)").font(.title2).tappableArea()
            }
            .accessibilityLabel("\(player.skipBackward) Sekunden zurück")
            .contextMenu { skipPicker("Sprungweite zurück", value: \.skipBackward) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlayingOrStarting ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlayingOrStarting ? "Pause" : "Abspielen")
            Button { player.skipAhead() } label: {
                Image(systemName: "goforward.\(player.skipForward)").font(.title2).tappableArea()
            }
            .accessibilityLabel("\(player.skipForward) Sekunden vor")
            .contextMenu { skipPicker("Sprungweite vor", value: \.skipForward) }
            Button {
                if hasNextChapter { player.nextChapter() } else { model.playNextInQueue() }
            } label: {
                Image(systemName: "forward.end.fill").tappableArea()
            }
            .accessibilityLabel(hasNextChapter ? "Nächstes Kapitel" : "Nächste Folge")
            .disabled(!hasNextChapter && !hasNextEpisode)
        }
        .buttonStyle(.pressable)
        .padding(.vertical, Design.Spacing.small)
    }

    /// Die Sprungweiten zur Auswahl, mit Häkchen bei der eingestellten.
    private func skipPicker(_ title: LocalizedStringKey,
                            value: ReferenceWritableKeyPath<EpisodePlayer, Int>) -> some View {
        Picker(title, selection: Binding(get: { player[keyPath: value] },
                                         set: { player[keyPath: value] = $0 })) {
            ForEach(EpisodePlayer.skipChoices, id: \.self) { seconds in
                Text("\(seconds) Sekunden").tag(seconds)
            }
        }
        .pickerStyle(.inline)
    }

    // MARK: Tempo, Schlaf-Timer, AirPlay

    /// Nebeneinander, bei großer Schrift untereinander über die ganze
    /// Breite. Dort öffnen Tempo und Schlaf-Timer ein Blatt statt eines
    /// Menüs, denn das Menü lief über den Bildschirmrand und ließ sich
    /// nicht scrollen.
    @ViewBuilder private var optionsRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Design.Spacing.small) {
                Button { choosing = .rate } label: { rateLabel.frame(maxWidth: .infinity) }
                    .accessibilityLabel("Geschwindigkeit")
                    .accessibilityValue(rateValue)
                Button { choosing = .sleep } label: { sleepLabelView.frame(maxWidth: .infinity) }
                    .accessibilityLabel("Schlaf-Timer")
                    .accessibilityValue(sleepValue)
                routePicker
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .sheet(item: $choosing) { choice in
                NavigationStack {
                    List {
                        switch choice {
                        case .rate: ratePicker.labelsHidden()
                        case .sleep: sleepPicker.labelsHidden()
                        }
                    }
                    .navigationTitle(choice.title)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { choosing = nil }
                        }
                    }
                }
                .sheetFeedback()
            }
        } else {
            HStack(spacing: Design.Spacing.control) {
                rateMenu
                sleepMenu
                routePicker
            }
        }
    }

    @ViewBuilder private var routePicker: some View {
        let size: CGFloat = dynamicTypeSize.isAccessibilitySize ? 64 : 44
        #if os(macOS)
        // Auf dem Mac wird ein Player umgeleitet, nicht die Audiositzung.
        RoutePickerButton(player: player.routingPlayer)
            .frame(width: size, height: size)
            .accessibilityLabel("Wiedergabe auf anderem Gerät")
        #else
        RoutePickerButton()
            .frame(width: size, height: size)
            .accessibilityLabel("Wiedergabe auf anderem Gerät")
        #endif
    }

    private static let rates: [Float] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0]

    /// Als Auswahl mit Häkchen und dem Merkmal „ausgewählt“ für VoiceOver.
    private var ratePicker: some View {
        Picker("Geschwindigkeit", selection: Binding(get: { player.rate },
                                                     set: { player.rate = $0; choosing = nil })) {
            ForEach(Self.rates, id: \.self) { rate in
                Text("\(Double(rate).formatted(.number.precision(.fractionLength(1))))×").tag(rate)
            }
        }
        .pickerStyle(.inline)
    }

    /// „Aus“ steht oben und trägt das Häkchen, solange kein Timer läuft.
    /// „Ende des Kapitels“ gibt es nur in Folgen mit Kapiteln. Grau und
    /// ohne Grund verwirrte der Eintrag.
    private var sleepPicker: some View {
        Picker("Schlaf-Timer", selection: Binding(get: { player.sleepTimer },
                                                  set: { player.setSleepTimer($0); choosing = nil })) {
            Text("Aus").tag(EpisodePlayer.SleepTimer?.none)
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Text(Duration.seconds(minutes * 60), format: .units(allowed: [.minutes], width: .wide))
                    .tag(EpisodePlayer.SleepTimer?.some(.minutes(minutes)))
            }
            if !player.chapters.isEmpty {
                Text("Ende des Kapitels").tag(EpisodePlayer.SleepTimer?.some(.endOfChapter))
            }
            Text("Ende der Folge").tag(EpisodePlayer.SleepTimer?.some(.endOfEpisode))
        }
        .pickerStyle(.inline)
    }

    private var rateMenu: some View {
        Menu { ratePicker } label: { rateLabel }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Geschwindigkeit")
            .accessibilityValue(rateValue)
    }

    private var sleepMenu: some View {
        Menu { sleepPicker } label: { sleepLabelView }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Schlaf-Timer")
            .accessibilityValue(sleepValue)
    }

    /// Name und Wert stehen auch an der Beschriftung. Ein Menü im Inhalt
    /// bringt dafür einen eigenen Knopf mit, der sonst leer blieb.
    private var rateLabel: some View {
        Label {
            Text("\(Double(player.rate).formatted(.number.precision(.fractionLength(1))))×")
        } icon: {
            Image(systemName: "speedometer").accessibilityHidden(true)
        }
        .optionLabel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geschwindigkeit")
        .accessibilityValue(rateValue)
    }

    private var sleepLabelView: some View {
        Label {
            Text(sleepLabel)
        } icon: {
            Image(systemName: player.sleepTimer == nil ? "moon" : "moon.fill").accessibilityHidden(true)
        }
        .optionLabel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Schlaf-Timer")
        .accessibilityValue(sleepValue)
    }

    /// „1,0-fach“.
    private var rateValue: Text {
        Text("\(Double(player.rate).formatted(.number.precision(.fractionLength(1))))-fach")
    }

    /// „Aus“, „noch 26 Minuten“ oder „Ende der Folge“.
    private var sleepValue: Text {
        guard let timer = player.sleepTimer else { return Text("Aus") }
        if case .minutes = timer, let remaining = player.sleepRemaining {
            let minutes = max(1, Int(remaining / 60 + 0.5))
            return Text("noch \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide)))")
        }
        return Text(timer.label)
    }

    private var sleepLabel: String {
        // Die Restzeit steht auch in der Pause still, genau wie der Timer.
        if case .minutes = player.sleepTimer, let remaining = player.sleepRemaining {
            let minutes = max(1, Int(remaining / 60 + 0.5))
            return String(localized: "\(minutes) Min")
        }
        return player.sleepTimer?.label ?? String(localized: "Schlaf-Timer")
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Kapitel").font(.headline).padding(.vertical, Design.Spacing.small)
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { _, chapter in
                let isCurrent = player.currentChapter?.start == chapter.start
                Button { player.seek(to: chapter.start.seconds) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        TimecodeLabel(chapter.start).frame(minWidth: 56, alignment: .leading)
                        Text(chapter.title)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .multilineTextAlignment(.leading)
                        Spacer()
                        // Nicht nur Farbe: das laufende Kapitel trägt ein Zeichen,
                        // und VoiceOver sagt „läuft gerade“.
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, Design.Spacing.control)
                    .padding(.horizontal, Design.Spacing.control)
                    .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: Design.Radius.control))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isCurrent ? Text("läuft gerade") : Text(verbatim: ""))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                if !isCurrent { Divider() }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        MediaTime(milliseconds: Int64(max(0, seconds) * 1000)).timecode
    }
}

/// Kompakte Leiste für die laufende Folge.
struct EpisodeMiniBar: View {

    @Environment(AppModel.self) private var model
    @State private var showingPlayer = false

    private var player: EpisodePlayer { model.episodePlayer }

    var body: some View {
        if let episode = player.episode {
            HStack(spacing: Design.Spacing.control) {
                Button { showingPlayer = true } label: {
                    HStack(spacing: Design.Spacing.small) {
                        EpisodeArtwork(url: episode.artworkURL
                                       ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                                       size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(episode.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Player öffnen, \(episode.title)")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlayingOrStarting ? "pause.fill" : "play.fill").tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(player.isPlayingOrStarting ? "Pausieren" : "Fortsetzen")
                .accessibilityShowsLargeContentViewer()

                // Zurück statt vor: wer etwas verpasst hat, will es noch einmal hören.
                Button { player.skipBack() } label: {
                    Image(systemName: "gobackward.\(player.skipBackward)").tappableArea()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(player.skipBackward) Sekunden zurück")
                .accessibilityShowsLargeContentViewer()
            }
            .padding(.horizontal, Design.Spacing.control)
            // Die Leiste über der Tab Bar hat eine feste Höhe. Mit sehr großer
            // Schrift ragte sie über den Inhalt, verdeckte dort „Pause“ und
            // schnitt die eigene Zeit ab. Größer als hier wird sie nicht,
            // die Knöpfe zeigen dann beim Gedrückthalten die große Ansicht.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .sheet(isPresented: $showingPlayer) {
                // „Nächste Folge“ und Abspielen fragen oder melden sich hier,
                // über dem Player.
                EpisodePlayerView()
                    .sheetFeedback()
                    .environment(model)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 560)
                    #endif
            }
        }
    }

    /// Die zweite Zeile: Fehler, Laden, Kapitel oder die Position.
    private var status: String {
        if player.playbackError != nil { return String(localized: "Nicht abspielbar") }
        if player.isBuffering { return String(localized: "lädt …") }
        return player.currentChapter?.title ?? EpisodePlayerView.format(player.currentTime)
    }
}

// MARK: - Warteschlange

/// Ein Ort für alles, was ansteht: was läuft, was als Nächstes gehört wird
/// und was gerade oder demnächst erschlossen wird.
struct QueueView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let episode = model.episodePlayer.episode {
                Section("Jetzt läuft") {
                    NavigationLink { EpisodeDetailView(episode: episode) } label: {
                        QueueRow(episode: episode, detail: model.episodePlayer.currentChapter?.title)
                    }
                }
            }

            Section {
                if model.upNext.isEmpty {
                    Text("Leer. In einer Folge „Als Nächstes“ antippen, dann startet sie, sobald die laufende endet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    playUpNextButton
                }
                ForEach(model.upNext) { episode in
                    NavigationLink { EpisodeDetailView(episode: episode) } label: {
                        QueueRow(episode: episode, detail: nil)
                    }
                    .swipeActions {
                        Button("Entfernen", role: .destructive) { model.removeFromUpNext(episode.id) }
                    }
                    // Auf dem Mac ohne Trackpad gibt es kein Wischen.
                    .contextMenu {
                        Button(role: .destructive) { model.removeFromUpNext(episode.id) } label: {
                            Label("Entfernen", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove { model.moveUpNext(from: $0, to: $1) }
                .onDelete { model.removeFromUpNext(at: $0) }
            } header: {
                Text("Als Nächstes hören")
            }

            // Transkripte erscheinen hier nur, solange welche entstehen. Sonst
            // stand unter den Folgen ein Block, der mit dem Hören nichts zu tun hat.
            if model.analyzing != nil || !model.analysisQueue.isEmpty {
                transcriptSection
            }

            if model.gatheringFacts != nil || !model.factsQueue.isEmpty {
                factsSection
            }
        }
        .navigationTitle("Warteschlange")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private var transcriptSection: some View {
        Section {
            if let current = model.analyzing {
                NavigationLink { EpisodeDetailView(episode: current) } label: {
                    QueueRow(episode: current,
                             detail: model.stages[current.id].map { stage in
                                 model.stageDetails[current.id].map { String(localized: "\(stage.label) · \($0)") }
                                     ?? stage.label
                             } ?? String(localized: "startet"))
                }
            }
            ForEach(model.analysisQueue) { episode in
                // Der echte Grund: auf WLAN, auf einen zweiten Versuch oder einfach der Reihe nach.
                QueueRow(episode: episode, detail: model.stageDetails[episode.id] ?? String(localized: "wartet"))
                    .swipeActions {
                        Button("Entfernen", role: .destructive) { model.removeFromAnalysisQueue(episode.id) }
                    }
                    .contextMenu {
                        Button(role: .destructive) { model.removeFromAnalysisQueue(episode.id) } label: {
                            Label("Entfernen", systemImage: "minus.circle")
                        }
                    }
            }
            .onMove { model.moveAnalysisQueue(from: $0, to: $1) }
            .onDelete { offsets in
                let ids = offsets.map { model.analysisQueue[$0].id }
                ids.forEach(model.removeFromAnalysisQueue)
            }
        } header: {
            Text("Transkripte erstellen")
        } footer: {
            if let unavailable = model.preparationUnavailable {
                Text("Transkripte für neue Folgen erstellt die App gerade nicht. \(unavailable)")
            } else {
                Text("""
                    Die App erstellt ein Transkript nach dem anderen. Auf dem iPhone geht die Arbeit \
                    im Hintergrund weiter, solange die Fortschrittsanzeige des Systems zu sehen ist.
                    """)
            }
        }
    }

    /// Was nach dem Transkript noch Fakten bekommt. Läuft neben den
    /// Transkripten, eine Folge nach der anderen.
    private var factsSection: some View {
        Section {
            if let current = model.gatheringFacts {
                NavigationLink { EpisodeDetailView(episode: current) } label: {
                    QueueRow(episode: current, detail: factsRunningDetail(current.id))
                }
            }
            ForEach(model.factsQueue) { episode in
                NavigationLink { EpisodeDetailView(episode: episode) } label: {
                    QueueRow(episode: episode, detail: model.factsWait ?? String(localized: "wartet"))
                }
            }
        } header: {
            Text(factsHeader)
        } footer: {
            Text("""
                Nach dem Transkript zieht die App mit Apple Intelligence auf dem Gerät überprüfbare \
                Aussagen heraus, eine Folge nach der anderen. Das läuft neben den Transkripten und \
                hält sie nicht auf.
                """)
        }
    }

    /// „Fakten: 2 Folgen“.
    private var factsHeader: String {
        let count = model.factsQueue.count + (model.gatheringFacts == nil ? 0 : 1)
        return String(AttributedString(localized: "Fakten: ^[\(count) Folge](inflect: true)").characters)
    }

    /// „Fakten werden gesammelt · 40 %“.
    private func factsRunningDetail(_ id: EpisodeID) -> String {
        guard let progress = model.factsProgress[id], progress > 0 else {
            return String(localized: "Fakten werden gesammelt …")
        }
        return String(localized: "Fakten werden gesammelt · \(progress.formatted(.percent.precision(.fractionLength(0))))")
    }

    /// Startet „Als Nächstes“ von oben, an der gemerkten Stelle der ersten Folge.
    private var playUpNextButton: some View {
        Button { model.playNextInQueue() } label: {
            HStack(spacing: Design.Spacing.small) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Abspielen").font(.subheadline.weight(.semibold))
                    Text(upNextSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.play")
    }

    /// „3 Folgen · noch 2 Std 5 Min“.
    private var upNextSummary: String {
        let count = model.upNext.count
        let episodes = String(AttributedString(localized: "^[\(count) Folge](inflect: true)").characters)
        let remaining = model.upNextRemaining
        guard remaining >= 60 else { return episodes }
        return String(localized: "\(episodes) · noch \(MediaDuration(seconds: remaining).shortDescription)")
    }
}

private struct QueueRow: View {
    let episode: Episode
    let detail: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            EpisodeArtwork(url: episode.artworkURL
                           ?? model.sources.first(where: { $0.id == episode.sourceID })?.artworkURL,
                           size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Shownotes

/// Macht aus dem HTML der Shownotes lesbaren Text mit anklickbaren Links.
enum ShownotesText {

    /// Nur der Text, ohne Links, für Chat und Export.
    static func plain(_ html: String?) -> String? {
        guard let rendered = render(html) else { return nil }
        let text = String(rendered.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func render(_ html: String?) -> AttributedString? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var text = html
        // Links vor dem Entfernen der Tags als Markdown sichern.
        let linkPattern = #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(text.startIndex..., in: text)
            var result = ""
            var last = text.startIndex
            for match in regex.matches(in: text, range: range) {
                guard let whole = Range(match.range, in: text),
                      let href = Range(match.range(at: 1), in: text),
                      let label = Range(match.range(at: 2), in: text) else { continue }
                result += text[last..<whole.lowerBound]
                let labelText = stripTags(String(text[label])).trimmingCharacters(in: .whitespaces)
                let url = String(text[href])
                if url.hasPrefix("http") {
                    result += "[\(escape(labelText.isEmpty ? url : labelText))](\(url.replacingOccurrences(of: " ", with: "%20")))"
                } else {
                    result += labelText
                }
                last = whole.upperBound
            }
            result += text[last...]
            text = result
        }
        text = text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(p|div|h[1-6]|ul|ol)>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(stripTags(text))
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                     "&apos;": "'", "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—",
                     "&hellip;": "…", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü",
                     "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = result as NSString
            var output = ""
            var cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) {
                    output += String(Character(scalar))
                } else {
                    output += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        return result
    }
}

// MARK: - AirPlay

#if os(iOS)
import AVKit

/// Die Systemauswahl für AirPlay und Bluetooth.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
import AVKit

/// Auf dem Mac gilt die Auswahl nur für den Player, den sie kennt. Ohne ihn
/// blieb die Liste leer, oder die Folge spielte weiter über den Mac.
struct RoutePickerButton: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
#endif

// MARK: - Folgen ohne Ton

extension Episode {
    /// Liegt die Folge bei YouTube? Dann gibt es ein Video, aber keine Audiodatei.
    var opensInYouTube: Bool { webPageURL?.host()?.contains("youtu") ?? false }
    /// Wie der Knopf heißt, der eine Folge ohne Audiodatei öffnet.
    var webLinkTitle: String {
        opensInYouTube ? String(localized: "In YouTube öffnen") : String(localized: "Webseite öffnen")
    }
    var webLinkSymbol: String { opensInYouTube ? "play.rectangle" : "safari" }
}

/// Steht dort, wo sonst „Abspielen“ steht, wenn die Folge keine Audiodatei
/// hat. Ohne Webseite erscheint gar nichts.
struct OpenEpisodeWebButton: View {
    let episode: Episode
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = episode.webPageURL {
            Button { openURL(url) } label: {
                Label(episode.webLinkTitle, systemImage: episode.webLinkSymbol)
            }
        }
    }
}

// MARK: - Notizen

/// Was im Blatt „Moment merken“ im Player entsteht.
///
/// Eine Klasse statt einzelner `@State`-Werte: verschwindet der Player samt
/// Blatt, muss der Stand noch lesbar sein, damit der Moment gemerkt wird.
/// Gespeichert wird höchstens einmal, und nach „Abbrechen“ gar nicht.
@MainActor
@Observable
final class MomentNoteDraft {
    private(set) var episode: Episode?
    private(set) var position: Double = 0
    var quote: String?
    var text = ""
    /// „Merken“ oder „Abbrechen“ ist gewählt, oder es wurde noch nichts
    /// begonnen.
    private var isSettled = true

    /// Hält die Position beim Tippen fest. Was danach läuft, während der
    /// Kommentar entsteht, zählt nicht mehr.
    func begin(in episode: Episode, at position: Double) {
        self.episode = episode
        self.position = position
        quote = nil
        text = ""
        isSettled = false
    }

    /// Sucht den Satz, der beim Tippen lief, und legt die Zeitmarke auf
    /// seinen Anfang. Wer schneller auf „Merken“ tippt, bekommt dasselbe:
    /// `addNote` sucht ihn dann selbst.
    func locate(with model: AppModel) async {
        guard !isSettled, let episode,
              let passage = await model.notePassage(at: position, in: episode),
              !isSettled, self.episode?.id == episode.id else { return }
        position = passage.start.seconds
        quote = passage.text
    }

    func save(with model: AppModel, confirm: ConfirmAction? = nil) {
        guard !isSettled, let episode else { return }
        isSettled = true
        let text = text, position = position, quote = quote
        Task {
            let saved = await model.addNote(text, at: position, in: episode, quote: quote)
            if let saved, let confirm { confirm(NoteFeedback.saved(saved), symbol: "bookmark.fill") }
        }
    }

    func discard() {
        isSettled = true
    }
}

/// „Moment merken“ im Player. Nach „Merken“ sagt der Player kurz, bei
/// welcher Zeit die Stelle gemerkt ist und wo sie liegt.
private struct MomentNoteSheet: View {
    @Bindable var draft: MomentNoteDraft
    let model: AppModel
    @Environment(\.confirm) private var confirm

    var body: some View {
        NoteSheet(position: draft.position, quote: draft.quote, text: $draft.text,
                  save: { draft.save(with: model, confirm: confirm) },
                  cancel: { draft.discard() })
            .task { await draft.locate(with: model) }
    }
}

/// Was nach Merken, Kopieren und Abspielen kurz eingeblendet wird.
enum NoteFeedback {

    static func saved(_ highlight: Highlight) -> String {
        let time = MediaTime(milliseconds: Int64(highlight.positionMs ?? 0)).timecode
        #if os(macOS)
        return String(localized: "Gemerkt bei \(time). Du findest die Stelle unter Gemerkte Stellen.")
        #else
        return String(localized: "Gemerkt bei \(time). Du findest die Stelle unter Wissen › Gemerkte Stellen.")
        #endif
    }

    static var copied: String { String(localized: "Mit Quelle kopiert.") }

    static func playing(from highlight: Highlight) -> String {
        let time = MediaTime(milliseconds: Int64(highlight.positionMs ?? 0)).timecode
        return String(localized: "Spielt ab \(time).")
    }
}

// MARK: - Bestätigung

/// Zeigt kurz eine Bestätigung, etwa „Gemerkt bei 4:00“, und sagt sie für
/// VoiceOver an. Ohne ``ConfirmationBanner`` darüber bleibt die Ansage.
struct ConfirmAction: Sendable {
    let show: @MainActor @Sendable (String, String) -> Void

    @MainActor func callAsFunction(_ message: String, symbol: String = "checkmark.circle.fill") {
        show(message, symbol)
    }
}

extension EnvironmentValues {
    @Entry var confirm: ConfirmAction = ConfirmAction { message, _ in
        AccessibilityNotification.Announcement(message).post()
    }
}

@MainActor
@Observable
private final class ConfirmationState {
    private(set) var message: String?
    private(set) var symbol = "checkmark.circle.fill"
    private var serial = 0

    func show(_ text: String, symbol: String) {
        message = text
        self.symbol = symbol
        serial += 1
        let current = serial
        AccessibilityNotification.Announcement(text).post()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.serial == current else { return }
            self.message = nil
        }
    }
}

/// Die Fläche für ``ConfirmAction``: eine Zeile am unteren Rand, die nach
/// ein paar Sekunden von selbst verschwindet und nichts verdeckt, was man
/// antippen will.
private struct ConfirmationBanner: ViewModifier {
    @State private var state = ConfirmationState()

    func body(content: Content) -> some View {
        content
            .environment(\.confirm, ConfirmAction { [state] message, symbol in
                state.show(message, symbol: symbol)
            })
            .overlay(alignment: .bottom) {
                if let message = state.message {
                    Label(message, systemImage: state.symbol)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, Design.Spacing.standard)
                        .padding(.vertical, Design.Spacing.small)
                        .glassEffect(.regular, in: .rect(cornerRadius: Design.Radius.card))
                        .padding(Design.Spacing.standard)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("confirmation")
                }
            }
            .animation(.default, value: state.message)
    }
}

extension View {
    func confirmationBanner() -> some View { modifier(ConfirmationBanner()) }
}

/// Kommentar zu einem Moment. Die Stelle ist schon gemerkt, der Text ist freiwillig.
struct NoteSheet: View {
    /// Ältere Notizen haben keine Zeitmarke.
    let position: Double?
    /// Was mit der Stelle gespeichert wird, damit man es vorher sieht.
    var quote: String? = nil
    @Binding var text: String
    let save: () -> Void
    /// Für „Abbrechen“, wenn der Aufrufer wissen muss, dass nichts gemerkt
    /// werden soll.
    var cancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was ist dir hier wichtig? (freiwillig)", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        // Der Platzhalter verschwindet beim Tippen. Der Name bleibt.
                        .accessibilityLabel("Notiz")
                        .accessibilityIdentifier("note.text")
                } header: {
                    if let position {
                        Text("Moment bei \(MediaTime(milliseconds: Int64(position * 1000)).timecode)")
                    } else {
                        Text("Gemerkte Stelle")
                    }
                } footer: {
                    Text("Die Notiz hängt an dieser Stelle. Du findest sie in der Folge und unter Wissen › Gemerkte Stellen. Sie bleibt auch, wenn du die Folge löschst.")
                }
                if let quote {
                    Section("Zitat") {
                        Text("„\(quote)“")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Moment merken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merken") { save(); dismiss() }
                        .accessibilityIdentifier("note.save")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { cancel(); dismiss() }
                }
            }
        }
    }
}

/// Eine gemerkte Stelle mit Kommentar, Zitat und Herkunft.
struct NoteRow: View {
    let highlight: Highlight
    var showsEpisode = true
    /// Die Folge ist gelöscht: die Notiz bleibt lesbar, abspielen geht nicht.
    var episodeGone = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            if let note = highlight.note {
                Text(note).font(.body)
            }
            if let quote = highlight.quote {
                Text("„\(quote)“")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if highlight.note == nil && highlight.quote == nil {
                // Ältere Einträge aus Kurzbefehl und Fokus-Player tragen weder
                // Kommentar noch Zitat. Leer bleibt die Zeile trotzdem nicht.
                Text("Gemerkte Stelle \(highlight.capturedVia.label)").font(.body)
            }
            HStack(spacing: Design.Spacing.micro) {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                    .accessibilityHidden(true)
                if let ms = highlight.positionMs {
                    TimecodeLabel(MediaTime(milliseconds: Int64(ms)))
                } else {
                    Text(highlight.capturedAt, format: .dateTime.day().month().year())
                }
                if showsEpisode, let title = highlight.episodeTitle {
                    Text("· \(title)").lineLimit(1)
                }
                if episodeGone {
                    Text("· Folge gelöscht").layoutPriority(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Design.Spacing.micro)
    }
}

/// Spielt eine gemerkte Stelle ab ihrer Zeitmarke. Ein eigener Knopf, der
/// die Zeit nennt: ein Tipp auf die Zeile selbst startet keinen Ton.
struct NotePlayButton: View {
    let highlight: Highlight
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm

    var body: some View {
        if let ms = highlight.positionMs, highlight.episodeID != nil {
            let time = MediaTime(milliseconds: Int64(ms)).timecode
            Button {
                NoteActions.play(highlight, model: model, confirm: confirm)
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .tappableArea()
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Ab \(time) abspielen")
            .accessibilityLabel("Ab \(TimecodeLabel.spoken(time)) abspielen")
        }
    }
}

/// Das Menü „…“ an einer gemerkten Stelle, sichtbar statt nur über langes
/// Drücken.
struct NoteActionsMenu: View {
    let highlight: Highlight
    var playable = true
    var edit: (() -> Void)? = nil
    var deletable = false

    var body: some View {
        Menu {
            NoteActions(highlight: highlight, playable: playable, edit: edit, deletable: deletable)
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .tappableArea()
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .accessibilityLabel("Aktionen zur gemerkten Stelle")
        .accessibilityHint("Abspielen, mit Quelle kopieren oder teilen")
    }
}

/// Abspielen, Kopieren und Teilen für eine gemerkte Stelle. Kopiert wird
/// Klartext mit Zitat, Folge, Podcast, Zeitmarke, Erscheinungsdatum, Link
/// und Kommentar. Bearbeiten und Löschen gibt es dort, wo die Liste sie
/// anbietet.
struct NoteActions: View {
    let highlight: Highlight
    var playable = true
    var edit: (() -> Void)? = nil
    var deletable = false
    @Environment(AppModel.self) private var model
    @Environment(\.confirm) private var confirm

    var body: some View {
        if playable, highlight.episodeID != nil, let ms = highlight.positionMs {
            Button {
                Self.play(highlight, model: model, confirm: confirm)
            } label: {
                Label("Ab \(MediaTime(milliseconds: Int64(ms)).timecode) abspielen", systemImage: "play.fill")
            }
        }
        Button {
            Clipboard.copy(model.noteCitation(highlight))
            confirm(NoteFeedback.copied)
        } label: {
            Label("Mit Quelle kopieren", systemImage: "doc.on.doc")
        }
        ShareLink(item: model.noteCitation(highlight)) {
            Label("Teilen", systemImage: "square.and.arrow.up")
        }
        if let edit {
            Button(action: edit) {
                Label("Kommentar bearbeiten", systemImage: "square.and.pencil")
            }
        }
        if deletable {
            Button(role: .destructive) { model.removeHighlight(highlight.id) } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Spielt ab der Zeitmarke und sagt es, damit der Sprung nicht still
    /// passiert. Scheitert das Abspielen, meldet sich stattdessen der Fehler.
    static func play(_ highlight: Highlight, model: AppModel, confirm: ConfirmAction) {
        Task {
            await model.playHighlight(highlight)
            if model.episodePlayer.episode?.id == highlight.episodeID {
                confirm(NoteFeedback.playing(from: highlight), symbol: "play.fill")
            }
        }
    }
}

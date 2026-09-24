//
//  HelpViews.swift
//  PodcastAI
//
//  Der Einstieg für alle, die die App zum ersten Mal öffnen, und die
//  Hilfe: Themenkarten mit Tipps, gestaffelt nach Erfahrung (erst hören,
//  dann verstehen, dann mit dem Wissen arbeiten), eine Suche über alles
//  und „Zeig es mir“, das an die passende Stelle der App springt.
//

import SwiftUI
import PodcastAIKit

// MARK: - Erster Start

struct OnboardingView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding: String?
    @State private var searching = false

    /// Zwei öffentliche Feeds zum Ausprobieren, einer auf Deutsch, einer auf Englisch.
    /// Der Titel ist ein Name und bleibt, wie er ist. Die Beschreibung wird übersetzt.
    private let samples: [(title: String, detail: LocalizedStringKey, feed: String)] = [
        ("AI to the DNA", "Deutsch · KI in Wissenschaft und Praxis", "https://feeds.transistor.fm/ai-to-the-dna"),
        ("Planet Money", "Englisch · Wirtschaft verständlich erklärt", "https://feeds.npr.org/510289/podcast.xml"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Podcasts hören und verstehen")
                            .font(.largeTitle.weight(.bold))
                        Text("""
                            PodcastAI spielt deine Podcasts wie ein normaler Player. Nebenbei erstellt es \
                            auf dem Gerät Transkripte der neuesten Folgen, mit Zeitmarken. Damit kannst du \
                            Fragen stellen, Fakten nachlesen und dir aus den Originalstellen Themen-Updates \
                            zusammenstellen lassen.
                            """)
                            .foregroundStyle(.secondary)
                    }

                    step(1, "Podcast finden", """
                        Den Namen deiner Sendung eintippen und abonnieren. Links aus Apple Podcasts oder \
                        von YouTube gehen auch.
                        """, symbol: "magnifyingglass")
                    Button {
                        searching = true
                    } label: {
                        Label("Podcast suchen", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: Design.minimumTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("onboarding.search")
                    step(2, "Hören", """
                        Für die neuesten Folgen erstellt die App im WLAN von selbst ein Transkript. \
                        Kapitel, Shownotes und Transkript findest du dann in der Folge.
                        """, symbol: "play.circle")
                    step(3, "Fragen und sammeln", """
                        Im Chat fragst du alle deine Podcasts auf einmal, in einer Folge unter „Fragen“ \
                        nur diese eine. Jede Antwort zeigt die Stelle im Original. Alles lässt sich als \
                        Text exportieren, etwa in deine Notizen.
                        """, symbol: "text.bubble")

                    // Einmal zeigen, wo Hilfe und Einstellungen liegen. Vorher
                    // suchten Einsteiger sie in „Für dich“ und fanden nichts.
                    Label {
                        Text(Self.helpHint)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: Design.Spacing.small) {
                        Text("Oder zum Ausprobieren").font(.headline)
                        ForEach(samples, id: \.feed) { sample in
                            Button {
                                adding = sample.feed
                                Task {
                                    await model.addSource(from: sample.feed)
                                    adding = nil
                                    finish()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(sample.title).font(.body.weight(.semibold))
                                        Text(sample.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if adding == sample.feed { ProgressView() } else {
                                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                .padding(Design.Spacing.control)
                                .background(.background.secondary, in: .rect(cornerRadius: Design.Radius.card))
                            }
                            .buttonStyle(.plain)
                            .disabled(adding != nil)
                        }
                    }
                }
                .padding(Design.Spacing.standard)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Los geht's") { finish() }
                }
            }
            .sheet(isPresented: $searching, onDismiss: {
                if !model.sources.isEmpty { finish() }
            }) {
                AddSourceSheet().sheetFeedback()
            }
        }
        // Auch Wegwischen zählt als gesehen. Sonst käme die Einführung bei
        // jedem Start wieder.
        .onDisappear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ text: LocalizedStringKey,
                      symbol: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.control) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text("\(number). \(Text(title))").font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingView.seenKey)
        dismiss()
    }

    /// Wo Hilfe und Einstellungen liegen. Auf dem Mac anders als auf iOS.
    private static var helpHint: LocalizedStringKey {
        #if os(macOS)
        "Die Hilfe steht links in der Seitenleiste, die Einstellungen findest du im Menü PodcastAI."
        #else
        "Hilfe, Einstellungen und Datenschutz findest du jederzeit über das Zahnrad oben in „Für dich“."
        #endif
    }

    static let seenKey = "onboardingSeen"

    /// Beim ersten Start, nicht in UI-Tests.
    static var shouldShow: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-show-onboarding") { return true }
        guard !arguments.contains("-uitest-fresh"), !arguments.contains("-skip-onboarding") else { return false }
        return !UserDefaults.standard.bool(forKey: seenKey)
    }
}

// MARK: - Hilfe

/// Die Hilfe als Übersicht mit Themenkarten.
///
/// Vorher standen alle Tipps in einer langen Liste untereinander, und wer
/// etwas suchte, musste alles lesen. Jetzt führt jede Karte zu wenigen
/// Tipps, die Stufen blenden aus, was noch nicht dran ist, und die Suche
/// geht über alle Tipps und Begriffe. Der Inhalt ist derselbe geblieben.
struct HelpView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// `nil` heißt: alle Stufen.
    @State private var level: HelpLevel?
    @State private var query = ""
    /// Wächst mit der Schrift. Bei großer Schrift passt nur noch eine Karte
    /// in die Breite, und kein Titel wird abgeschnitten.
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 150

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Bei Schriftgrößen für Bedienungshilfen eine Karte je Zeile, so breit
    /// wie der Bildschirm. Die Mindestbreite wuchs dort über die Breite des
    /// iPhones hinaus, und die Karte ragte über den Rand.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: cardWidth), spacing: Design.Spacing.control)]
    }

    /// Die Begriffe gehören zu keiner Stufe und bleiben immer sichtbar.
    private var visibleTopics: [HelpTopic] {
        HelpTopic.all.filter { topic in
            guard let level else { return true }
            return !topic.terms.isEmpty || topic.tips.contains { $0.level == level }
        }
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                overview
            } else {
                HelpSearchResults(query: trimmedQuery)
            }
        }
        .navigationTitle("So funktioniert's")
        .searchable(text: $query, prompt: Text("Tipps durchsuchen"))
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.standard) {
                Text("""
                    Such dir ein Thema aus. Mit den Stufen blendest du aus, was du noch nicht \
                    brauchst. „Zeig es mir“ bringt dich direkt dorthin.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Spacing.standard)

                VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                    HelpLevelPicker(selection: $level)
                    if let level {
                        Text(level.motto)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Design.Spacing.standard)
                    }
                }

                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: Design.Spacing.control
                ) {
                    ForEach(visibleTopics) { topic in
                        NavigationLink {
                            HelpTopicView(topic: topic, level: level)
                        } label: {
                            HelpTopicCard(topic: topic)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("help.topic.\(topic.kind.rawValue)")
                    }
                }
                .padding(.horizontal, Design.Spacing.standard)
            }
            .padding(.vertical, Design.Spacing.standard)
            .animation(
                Design.Motion.respectingReduceMotion(Design.Motion.smooth, reduceMotion: reduceMotion),
                value: level
            )
        }
    }
}

// MARK: Stufen

/// Wie viel Erfahrung ein Tipp voraussetzt: erst hören, dann verstehen,
/// dann mit dem Wissen arbeiten.
enum HelpLevel: Int, CaseIterable, Identifiable {
    case beginner, advanced, expert

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .beginner: "Einsteiger"
        case .advanced: "Fortgeschrittene"
        case .expert: "Experten"
        }
    }

    /// Worum es auf der Stufe geht.
    var motto: LocalizedStringResource {
        switch self {
        case .beginner: "Einsteiger: hören"
        case .advanced: "Fortgeschrittene: verstehen"
        case .expert: "Experten: mit dem Wissen arbeiten"
        }
    }
}

/// Die Stufen als Knöpfe in einer Reihe. Ein Segmentschalter schnitt
/// „Fortgeschrittene“ auf dem iPhone ab. Die Reihe scrollt stattdessen
/// seitlich, auch bei großer Schrift.
private struct HelpLevelPicker: View {

    @Binding var selection: HelpLevel?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Spacing.small) {
                chip(nil, title: "Alle", identifier: "help.level.all")
                ForEach(HelpLevel.allCases) { level in
                    chip(level, title: level.title, identifier: "help.level.\(level.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Design.Spacing.standard, for: .scrollContent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stufe")
    }

    private func chip(_ level: HelpLevel?, title: LocalizedStringResource, identifier: String) -> some View {
        let isSelected = selection == level
        return Button {
            selection = level
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, Design.Spacing.control)
                .padding(.vertical, Design.Spacing.small)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                // Die Kapsel ist kleiner als 44 Punkt, die Trefffläche nicht.
                .frame(minHeight: Design.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Themen

/// Ein Tipp: Überschrift, ein paar Sätze und die Stufe.
struct HelpTip: Identifiable {
    let title: LocalizedStringResource
    let text: LocalizedStringResource
    let symbol: String
    let level: HelpLevel

    /// Die Überschriften sind eindeutig, der Schlüssel reicht als Kennung.
    var id: String { title.key }

    func matches(_ query: String) -> Bool {
        String(localized: title).localizedStandardContains(query)
            || String(localized: text).localizedStandardContains(query)
    }
}

/// Ein Eintrag im Glossar: das Wort und ein, zwei Sätze dazu.
struct HelpTerm: Identifiable {
    let word: LocalizedStringResource
    let meaning: LocalizedStringResource

    var id: String { word.key }

    func matches(_ query: String) -> Bool {
        String(localized: word).localizedStandardContains(query)
            || String(localized: meaning).localizedStandardContains(query)
    }
}

/// Eine Karte auf der Übersicht und die Seite dahinter.
struct HelpTopic: Identifiable {

    enum Kind: String {
        case listening, finding, transcript, chat, saving, topicUpdates, storage, privacy, mac, glossary
    }

    let kind: Kind
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let symbol: String
    /// Nur Schmuck hinter dem Symbol. Titel und Text tragen die Information.
    let tint: Color
    var tips: [HelpTip] = []
    var terms: [HelpTerm] = []
    /// Wohin „Zeig es mir“ führt.
    var jumps: [HelpJump] = []

    var id: Kind { kind }
}

extension HelpTopic {

    /// Berechnet statt gespeichert: so bleiben Farbe und Texte ohne
    /// `Sendable`-Anforderung, und die Plattformweichen stehen gleich hier.
    static var all: [HelpTopic] {
        [listening, finding, transcript, chat, saving, topicUpdates, storage, privacy, mac, glossary]
    }

    private static var listening: HelpTopic {
        HelpTopic(
            kind: .listening, title: "Hören", summary: "Player und Warteschlange",
            symbol: "headphones", tint: .purple,
            tips: [
                HelpTip(title: "Hören", text: """
                    Folge öffnen und abspielen. Die App merkt sich die Stelle, auch über iPhone, iPad und \
                    Mac hinweg. Im Player: Tempo, Kapitel, Schlaf-Timer, AirPlay.
                    """, symbol: "play.circle", level: .beginner),
                HelpTip(title: "Warteschlange", text: queueText, symbol: "list.bullet", level: .beginner),
            ],
            jumps: [.library, .queue]
        )
    }

    private static var finding: HelpTopic {
        HelpTopic(
            kind: .finding, title: "Podcasts finden", summary: "Abonnieren, auch per Link",
            symbol: "magnifyingglass", tint: .pink,
            tips: [
                HelpTip(title: "Abonnieren", text: subscribeText, symbol: "plus.circle", level: .beginner),
                HelpTip(title: "Angesagt und Kategorien", text: """
                    Ohne Suchbegriff zeigt „Podcast hinzufügen“ den Katalog: die Charts von Apple Podcasts \
                    für die Region deines Geräts und Kategorien von Nachrichten bis Wahre Kriminalfälle. Ein \
                    Tipp auf einen Podcast zeigt Beschreibung und neueste Folgen. Abgespielt wird dort nichts, \
                    erst nach dem Abonnieren.
                    """, symbol: "square.grid.2x2", level: .beginner),
            ],
            jumps: [.addPodcast]
        )
    }

    private static var transcript: HelpTopic {
        HelpTopic(
            kind: .transcript, title: "Transkript und Fakten", summary: "Den Text zur Folge nutzen",
            symbol: "text.alignleft", tint: .indigo,
            tips: [
                HelpTip(title: "Transkript", text: """
                    Die App schreibt Folgen auf dem Gerät mit Zeitmarken mit. Im Reiter „Transkript“ \
                    springt ein Tipp an die Stelle; die Suche findet jedes Wort. Für eine ältere Folge \
                    tippst du in der Folge auf „Transkript erstellen“, für alle älteren eines Podcasts \
                    in seiner Folgenliste auf „Ältere Folgen auch vorbereiten“.
                    """, symbol: "text.alignleft", level: .advanced),
                HelpTip(title: "Übersetzen", text: """
                    Transkripte und Shownotes in einer anderen Sprache übersetzt die App auf dem Gerät, \
                    wenn du auf „Übersetzen“ tippst. Die Sprachen lädt das System beim ersten Mal, danach \
                    geht es auch ohne Netz. Beim Wortlaut eines Fakts und bei Stellen im Chat öffnet \
                    „Übersetzen“ das Übersetzungsfenster von Apple. Merken und Kopieren nehmen immer das \
                    Original.
                    """, symbol: "translate", level: .advanced),
                HelpTip(title: "Fakten",
                        text: "Aussagen aus der Folge, jede mit Zeitmarke zum Nachhören. Die App prüft sie nicht.",
                        symbol: "checkmark.seal", level: .advanced),
                HelpTip(title: "YouTube-Videos", text: """
                    YouTube liefert keinen Ton. Mit einem eigenen Schlüssel von Supadata, einem unabhängigen \
                    Dienst, holt die App Untertitel und Metadaten, die es zum Video schon gibt, und macht \
                    daraus ein Transkript mit Fakten und Chat. Einzelne Beiträge von TikTok, Instagram, X \
                    und Facebook fügst du dann per Link hinzu; Profile lassen sich nicht abonnieren. Den \
                    Schlüssel trägst du in den Einstellungen unter „YouTube-Transkripte“ ein. Ohne ihn kommt \
                    das Transkript aus dem passenden Audio-Podcast, falls du ihn abonnierst. Ein Tipp auf \
                    eine Stelle öffnet das Video dort, wo es liegt. Mit Schlüssel bekommen auch Podcasts mit \
                    Ton ihr Transkript zuerst aus den Untertiteln derselben Folge auf YouTube, an den Ton \
                    angepasst. Passt es nicht sicher, transkribiert die App wie gewohnt auf dem Gerät.
                    """, symbol: "play.rectangle", level: .expert),
            ],
            jumps: [.library]
        )
    }

    private static var chat: HelpTopic {
        HelpTopic(
            kind: .chat, title: "Chat", summary: "Fragen an deine Podcasts",
            symbol: "bubble.left.and.bubble.right.fill", tint: .teal,
            tips: [
                HelpTip(title: "Fragen und Chat", text: askText, symbol: "text.bubble", level: .advanced),
                HelpTip(title: "Gegenpositionen",
                        text: "Zu einer These zeigt die App belegte Stimmen dafür und dagegen.",
                        symbol: "arrow.left.arrow.right", level: .expert),
            ],
            jumps: [.chat, .counterpoints]
        )
    }

    private static var saving: HelpTopic {
        HelpTopic(
            kind: .saving, title: "Merken und sichern", summary: "Was du behalten willst",
            symbol: "bookmark.fill", tint: .orange,
            tips: [
                HelpTip(title: "Stellen merken", text: """
                    Im Player tippst du auf „Moment merken“ und schreibst auf Wunsch eine Notiz dazu. Im \
                    Transkript, bei Fakten und im Chat heißt der Befehl „Stelle merken“. Alles liegt dann \
                    mit Zeitmarke unter Wissen › Gemerkte Stellen.
                    """, symbol: "bookmark", level: .beginner),
                HelpTip(title: "Antworten sichern", text: """
                    Unter einer Antwort im Chat tippst du auf „Antwort sichern“. Sie liegt dann mit ihren \
                    Belegen unter Wissen › Gesicherte Antworten.
                    """, symbol: "map", level: .advanced),
                HelpTip(title: "Export", text: """
                    Folgen mit Shownotes, Kapiteln, Fakten und Transkript, Chat-Antworten mit Belegen und \
                    gemerkte Stellen als Markdown, etwa für Obsidian oder Notion.
                    """, symbol: "square.and.arrow.up", level: .expert),
            ],
            jumps: [.highlights, .trails]
        )
    }

    private static var topicUpdates: HelpTopic {
        HelpTopic(
            kind: .topicUpdates, title: "Themen-Updates", summary: "Eigene Folgen aus deinen Interessen",
            symbol: "waveform", tint: .red,
            tips: [
                HelpTip(title: "Interessen",
                        text: "Deine Themen, jedes mit eigenen Stichworten. Daraus entstehen „Für dich“ und die Themen-Updates.",
                        symbol: "target", level: .advanced),
                HelpTip(title: "Themen-Updates", text: """
                    Eine eigene Folge je Thema aus ungehörten Originalstellen mehrerer Podcasts, mit \
                    Kapiteln, Shownotes und Cover.
                    """, symbol: "waveform.circle", level: .expert),
            ],
            jumps: [.topicUpdates, .interests]
        )
    }

    private static var storage: HelpTopic {
        let storage = HelpTip(title: "Speicher", text: """
                Die neueste Folge jedes Podcasts bleibt auf dem Gerät und spielt ohne Netz. Bei den \
                anderen entfernt die App den Ton nach dem Transkript, abgespielt wird dann aus dem \
                Netz. In einer Folge über „Mehr“: „Laden (offline)“ holt den Ton aufs Gerät und lässt \
                ihn dort, bis du „Audio entfernen“ wählst. „Audio entfernen“ löscht nur den Ton, \
                „Folge löschen“ löscht Ton, Transkript, Fakten und Hörstand. Deine Notizen bleiben \
                unter Wissen. Unter „Audio liegt auf diesem Gerät“ steht in der Folge, warum. Die \
                Regeln lassen sich in den Einstellungen unter Speicher abschalten.
                """, symbol: "internaldrive", level: .beginner)
        #if os(iOS)
        let tips = [storage, HelpTip(title: "Mobilfunk", text: """
            Ob Folgen auch ohne WLAN laden, stellst du über das Zahnrad › Mobilfunk ein. Ist es \
            aus, fragt die App vorher. Was die App von selbst lädt, Transkripte und die neueste \
            Folge, wartet auf WLAN, bis du dort „Neue Folgen auch über Mobilfunk vorbereiten“ \
            einschaltest. Liegt der Ton schon auf dem Gerät, entsteht das Transkript auch ohne Netz.
            """, symbol: "antenna.radiowaves.left.and.right", level: .beginner)]
        #else
        let tips = [storage]
        #endif
        return HelpTopic(
            kind: .storage, title: storageTitle, summary: "Was auf dem Gerät liegt",
            symbol: "internaldrive.fill", tint: .gray,
            tips: tips,
            jumps: [.settings]
        )
    }

    private static var privacy: HelpTopic {
        // Die ersten beiden Tipps sind dieselben Sätze wie auf der Seite
        // „Datenschutz in PodcastAI“. „Zeig es mir“ öffnet sie ganz.
        HelpTopic(
            kind: .privacy, title: "Datenschutz", summary: "Wo deine Daten bleiben",
            symbol: "hand.raised.fill", tint: .blue,
            tips: [
                HelpTip(title: "Kein Konto, kein eigener Server", text: """
                    PodcastAI hat keine Anmeldung, keine Werbung und keine Analyse- oder Tracking-Dienste. \
                    Der Anbieter der App bekommt keine deiner Daten.
                    """, symbol: "person.crop.circle.badge.xmark", level: .beginner),
                HelpTip(title: "Transkripte entstehen auf dem Gerät", text: """
                    Die Spracherkennung von Apple läuft auf deinem iPhone, iPad oder Mac. Der Ton verlässt \
                    dafür das Gerät nicht.
                    """, symbol: "waveform", level: .beginner),
                // Derselbe Text wie auf der Seite „Datenschutz“.
                HelpTip(title: "YouTube-Transkripte über Supadata", text: """
                    Nur wenn du einen eigenen Supadata-Schlüssel einträgst: Für YouTube-Videos und einzelne \
                    Beiträge von TikTok, Instagram, X und Facebook gehen die Links an Supadata (supadata.ai), \
                    einen unabhängigen Dienst, um Untertitel und Metadaten abzurufen. Für Folgen mit Ton ohne \
                    eigenes Transkript sucht die App dort mit den Titeln von Podcast und Folge nach derselben \
                    Folge auf YouTube. Kontodaten, Fragen und \
                    deine übrigen Daten gehen dorthin nicht. Der Schlüssel liegt nur im Schlüsselbund dieses \
                    Geräts.
                    """, symbol: "play.rectangle", level: .expert),
                HelpTip(title: "Podcast-Katalog", text: """
                    Angesagt und Kategorien im Blatt „Podcast hinzufügen“ kommen von Apple Podcasts. Deinen \
                    Suchbegriff schickt die App an Apple und an Podcast Index (podcastindex.org), einen \
                    offenen Podcast-Katalog. Ein Konto brauchst du bei keinem der beiden, beide sehen aber \
                    deine IP-Adresse. Die Cover kommen von Apple oder vom Server des jeweiligen Podcasts.
                    """, symbol: "square.grid.2x2", level: .beginner),
                HelpTip(title: "Apple Intelligence", text: intelligenceText, symbol: "sparkles", level: .expert),
            ],
            jumps: [.privacy]
        )
    }

    private static var mac: HelpTopic {
        HelpTopic(
            kind: .mac, title: "Mac und Agenten", summary: "Siri, Kurzbefehle und MCP",
            symbol: "laptopcomputer", tint: .green,
            tips: [
                HelpTip(title: "Kurzbefehle und Mac", text: """
                    Themen-Updates per Siri. Auf dem Mac kann ein KI-Agent über MCP lesend auf dein \
                    Wissen zugreifen, aber nur mit deiner Freigabe unter PodcastAI › Einstellungen › \
                    Agenten. Dort steht auch der Eintrag für den Agenten.
                    """, symbol: "terminal", level: .expert),
            ],
            jumps: macJumps
        )
    }

    /// Die Wörter, die in der App am häufigsten vorkommen, kurz erklärt.
    private static var glossary: HelpTopic {
        HelpTopic(
            kind: .glossary, title: "Begriffe", summary: "Wörter aus der App erklärt",
            symbol: "character.book.closed.fill", tint: .brown,
            terms: [
                HelpTerm(word: "Transkript", meaning: """
                    Der mitgeschriebene Text einer Folge. Erst damit kannst du in der Folge suchen und \
                    Fragen stellen.
                    """),
                HelpTerm(word: "Themen-Update", meaning: """
                    Eine eigene Folge zu einem Thema. Die App stellt sie aus Stellen deiner Podcasts \
                    zusammen, die du noch nicht gehört hast.
                    """),
                HelpTerm(word: "Gemerkte Stelle", meaning: """
                    Ein Ausschnitt aus einer Folge, den du dir mit Zeitmarke gemerkt hast, auf Wunsch mit \
                    Notiz. Du findest sie unter „Gemerkte Stellen“.
                    """),
                HelpTerm(word: "Chat", meaning: """
                    Hier fragst du alle deine Podcasts auf einmal. Jede Antwort zeigt die Stellen, auf \
                    die sie sich stützt.
                    """),
                HelpTerm(word: "Shownotes", meaning: """
                    Der Text, den der Podcast zu einer Folge mitliefert, oft mit Links. Du findest ihn \
                    in der Folge unter „Überblick“.
                    """),
                HelpTerm(word: "Gesicherte Antwort", meaning: """
                    Eine Antwort aus dem Chat, die du mit ihren Stellen aufbewahrst. Du findest sie unter \
                    „Wissen“.
                    """),
                HelpTerm(word: "Gegenpositionen", meaning: """
                    Du gibst eine Behauptung ein, die App sucht Stellen aus deinen Podcasts, die dafür \
                    oder dagegen sprechen.
                    """),
                HelpTerm(word: "Apple-Server (Private Cloud Compute)", meaning: """
                    Rechner von Apple, auf denen Apple Intelligence Fragen mit mehr Text auf einmal \
                    bearbeitet. Apple speichert die Anfragen nicht. Ist der Schalter dafür aus, antwortet \
                    das Modell auf dem Gerät.
                    """),
            ]
        )
    }

    // Wege, die auf dem Mac anders heißen. Dort gibt es eine Seitenleiste
    // statt Reitern, und die Einstellungen liegen im Programmmenü. Jeder
    // Text steht als ganzer Satz da, damit er sich übersetzen lässt.
    #if os(macOS)
    private static var queueText: LocalizedStringResource {
        """
        „Als Nächstes“ reiht eine Folge direkt hinter der laufenden ein, gedrückt halten bietet \
        „Ans Ende“. Die Warteschlange steht links in der Seitenleiste und in „Meine Podcasts“.
        """
    }
    private static var askText: LocalizedStringResource {
        """
        In einer Folge unter „Fragen“, über alle Podcasts links unter „Chat“. Die Nummern in der \
        Antwort führen zu den Belegen.
        """
    }
    private static var intelligenceText: LocalizedStringResource {
        """
        Auf dem Gerät oder auf Apple-Servern (Private Cloud Compute), einstellbar unter PodcastAI › \
        Einstellungen › Intelligenz. Kein anderer KI-Anbieter.
        """
    }
    private static var subscribeText: LocalizedStringResource {
        """
        Das Plus in der Symbolleiste von „Für dich“ oder „Meine Podcasts“. Namen eintippen, gesucht \
        wird bei Apple Podcasts und bei Podcast Index. Links gehen auch: Apple Podcasts, Feed-Adresse, \
        einzelne MP3 oder YouTube-Kanal. Zu YouTube-Kanälen sucht die App den passenden Audio-Podcast.
        """
    }
    /// Ohne Mobilfunk-Tipp heißt die Karte auf dem Mac nur „Speicher“.
    private static var storageTitle: LocalizedStringResource { "Speicher" }
    /// Der Agentenzugang wird in den Einstellungen freigegeben.
    private static var macJumps: [HelpJump] { [.settings] }
    #else
    private static var queueText: LocalizedStringResource {
        """
        „Als Nächstes“ reiht eine Folge direkt hinter der laufenden ein, gedrückt halten bietet \
        „Ans Ende“. Die Warteschlange liegt in „Meine Podcasts“.
        """
    }
    private static var askText: LocalizedStringResource {
        """
        In einer Folge unter „Fragen“, über alle Podcasts im Reiter „Chat“. Die Nummern in der \
        Antwort führen zu den Belegen.
        """
    }
    private static var intelligenceText: LocalizedStringResource {
        """
        Auf dem Gerät oder auf Apple-Servern (Private Cloud Compute), einstellbar über das Zahnrad \
        › Intelligenz. Kein anderer KI-Anbieter.
        """
    }
    private static var subscribeText: LocalizedStringResource {
        """
        Das Plus oben in „Für dich“ oder „Meine Podcasts“. Namen eintippen, gesucht wird bei Apple \
        Podcasts und bei Podcast Index. Links gehen auch: Apple Podcasts, Feed-Adresse, einzelne MP3 \
        oder YouTube-Kanal. Zu YouTube-Kanälen sucht die App den passenden Audio-Podcast.
        """
    }
    private static var storageTitle: LocalizedStringResource { "Speicher und Mobilfunk" }
    /// Den Agentenzugang gibt es nur auf dem Mac, auf iOS gibt es hier kein Ziel.
    private static var macJumps: [HelpJump] { [] }
    #endif
}

/// Eine Karte auf der Übersicht.
private struct HelpTopicCard: View {

    let topic: HelpTopic
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            Image(systemName: topic.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(topic.tint.gradient, in: .rect(cornerRadius: Design.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(topic.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(topic.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        // Alle Karten einer Reihe gleich hoch, der Inhalt oben.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Design.Spacing.standard)
        .background(.background.secondary, in: .rect(cornerRadius: Design.Radius.card, style: .continuous))
        .contentShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Seite eines Themas

/// Die Tipps eines Themas, nach Stufen geordnet, und darunter „Zeig es mir“.
private struct HelpTopicView: View {

    let topic: HelpTopic
    /// Die Stufe von der Übersicht. `nil` zeigt alles.
    let level: HelpLevel?

    @Environment(\.showInApp) private var showInApp
    @State private var showsAllLevels = false
    @State private var addingSource = false

    private var shownTips: [HelpTip] {
        guard let level, !showsAllLevels else { return topic.tips }
        return topic.tips.filter { $0.level == level }
    }

    /// Nur Ziele, die hier auch erreichbar sind. Ohne Wurzelansicht, die
    /// den Tab wechselt, fällt der Sprung in einen Tab weg.
    private var jumps: [HelpJump] {
        topic.jumps.filter { $0.route != .app || showInApp != nil }
    }

    var body: some View {
        List {
            if !topic.terms.isEmpty {
                Section {
                    ForEach(topic.terms) { HelpTermRow(term: $0) }
                }
            }
            ForEach(HelpLevel.allCases) { stage in
                let tips = shownTips.filter { $0.level == stage }
                if !tips.isEmpty {
                    Section {
                        ForEach(tips) { HelpTipRow(tip: $0) }
                    } header: {
                        Text(stage.title)
                    }
                }
            }
            if shownTips.count < topic.tips.count {
                Section {
                    Button {
                        showsAllLevels = true
                    } label: {
                        Label("Alle Stufen zeigen", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("help.allLevels")
                }
            }
            if !jumps.isEmpty {
                Section {
                    ForEach(jumps, id: \.self) { jump in
                        jumpRow(jump)
                            .accessibilityIdentifier("help.jump.\(jump)")
                    }
                } header: {
                    Text("Zeig es mir")
                }
            }
        }
        .navigationTitle(Text(topic.title))
        .sheet(isPresented: $addingSource) {
            AddSourceSheet().sheetFeedback()
        }
    }

    @ViewBuilder
    private func jumpRow(_ jump: HelpJump) -> some View {
        switch jump.route {
        case .app:
            Button {
                showInApp?.perform(jump)
            } label: {
                jumpLabel(jump)
            }
            .accessibilityHint("Springt in diesen Bereich der App")
        case .push:
            NavigationLink {
                jump.destination
            } label: {
                jumpLabel(jump)
            }
        case .sheet:
            Button {
                addingSource = true
            } label: {
                jumpLabel(jump)
            }
        case .settingsWindow:
            #if os(macOS)
            SettingsLink {
                jumpLabel(jump)
            }
            #else
            EmptyView()
            #endif
        }
    }

    private func jumpLabel(_ jump: HelpJump) -> some View {
        Label {
            Text(jump.title)
        } icon: {
            Image(systemName: jump.symbol)
        }
    }
}

/// Ein Tipp in der Liste: Symbol, Überschrift, Text.
private struct HelpTipRow: View {

    let tip: HelpTip

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Design.Spacing.micro) {
                Text(tip.title).font(.body.weight(.semibold))
                Text(tip.text).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: tip.symbol).foregroundStyle(.tint)
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
    }
}

/// Ein Begriff im Glossar: das Wort und ein, zwei Sätze dazu.
private struct HelpTermRow: View {

    let term: HelpTerm

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Text(term.word).font(.body.weight(.semibold))
            Text(term.meaning).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, Design.Spacing.micro)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Suche

/// Treffer über alle Tipps und Begriffe, nach Thema geordnet. Passt der
/// Name eines Themas, zählt das ganze Thema. Die Suche kennt keine Stufen,
/// sonst fände sie manches nicht.
private struct HelpSearchResults: View {

    let query: String

    private struct Hit: Identifiable {
        let topic: HelpTopic
        let tips: [HelpTip]
        let terms: [HelpTerm]
        var id: HelpTopic.Kind { topic.kind }
    }

    private var hits: [Hit] {
        HelpTopic.all.compactMap { topic in
            let wholeTopic = String(localized: topic.title).localizedStandardContains(query)
            let tips = wholeTopic ? topic.tips : topic.tips.filter { $0.matches(query) }
            let terms = wholeTopic ? topic.terms : topic.terms.filter { $0.matches(query) }
            return tips.isEmpty && terms.isEmpty ? nil : Hit(topic: topic, tips: tips, terms: terms)
        }
    }

    var body: some View {
        let found = hits
        List {
            ForEach(found) { hit in
                Section {
                    ForEach(hit.tips) { tip in
                        NavigationLink {
                            HelpTopicView(topic: hit.topic, level: nil)
                        } label: {
                            HelpTipRow(tip: tip)
                        }
                    }
                    ForEach(hit.terms) { term in
                        NavigationLink {
                            HelpTopicView(topic: hit.topic, level: nil)
                        } label: {
                            HelpTermRow(term: term)
                        }
                    }
                } header: {
                    Text(hit.topic.title)
                }
            }
        }
        .overlay {
            if found.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - „Zeig es mir“

/// Stellen in der App, zu denen die Hilfe springt.
///
/// Die Hilfe öffnet nur Ansichten. Sie spielt nichts ab und legt nichts
/// an: „Podcast hinzufügen“ öffnet das Blatt, abonniert wird dort.
enum HelpJump: Hashable, Sendable {
    case library, queue, chat, topicUpdates
    case highlights, trails, counterpoints, interests
    case addPodcast, settings, privacy

    /// Wie die Hilfe dorthin kommt.
    enum Route {
        /// Tab oder Eintrag in der Seitenleiste, über `showInApp`.
        case app
        /// Die Ansicht kommt auf den Stapel der Hilfe. „Zurück“ führt
        /// wieder in die Hilfe.
        case push
        /// Das Blatt zum Hinzufügen, von der Hilfe aus geöffnet.
        case sheet
        /// Das Einstellungsfenster auf dem Mac.
        case settingsWindow
    }

    var route: Route {
        #if os(macOS)
        // Auf dem Mac hat fast jeder Bereich einen Eintrag in der Seitenleiste.
        switch self {
        case .library, .queue, .chat, .topicUpdates, .highlights, .trails, .counterpoints, .interests: .app
        case .addPodcast: .sheet
        case .settings: .settingsWindow
        case .privacy: .push
        }
        #else
        // Auf iOS sind nur die großen Bereiche Tabs. Was unter „Wissen“
        // oder in den Einstellungen liegt, öffnet die Hilfe selbst.
        switch self {
        case .library, .queue, .chat, .topicUpdates: .app
        case .highlights, .trails, .counterpoints, .interests, .settings, .privacy: .push
        case .addPodcast: .sheet
        }
        #endif
    }

    var title: LocalizedStringResource {
        switch self {
        case .library: "Meine Podcasts"
        case .queue: "Warteschlange"
        case .chat: "Chat"
        case .topicUpdates: "Themen-Updates"
        case .highlights: "Gemerkte Stellen"
        case .trails: "Gesicherte Antworten"
        case .counterpoints: "Gegenpositionen"
        case .interests: "Interessen"
        case .addPodcast: "Podcast hinzufügen"
        case .settings: "Einstellungen"
        case .privacy: "Datenschutz in PodcastAI"
        }
    }

    /// Dieselben Symbole wie in Tab-Leiste, Seitenleiste und „Wissen“.
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .queue: "list.bullet"
        case .chat: "bubble.left.and.bubble.right"
        case .topicUpdates: "waveform.circle"
        case .highlights: "bookmark"
        case .trails: "map"
        case .counterpoints: "arrow.left.arrow.right"
        case .interests: "target"
        case .addPodcast: "plus"
        case .settings: "gearshape"
        case .privacy: "hand.raised"
        }
    }

    /// Die Ansicht für `Route.push`.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .highlights: KnowledgeView()
        case .trails: TrailListView()
        case .counterpoints: CounterpointView()
        case .interests: InterestsView()
        case .privacy: PrivacyOverviewView()
        #if os(iOS)
        case .settings: SettingsView()
        #endif
        default: EmptyView()
        }
    }
}

/// Springt aus der Hilfe in einen Tab (iOS) oder einen Eintrag der
/// Seitenleiste (Mac). Die Wurzelansicht setzt die Aktion, sie allein weiß,
/// wie sie umschaltet.
///
/// Eine Struktur statt einer bloßen Closure: Closures lassen sich nicht
/// vergleichen, und jede neue zeichnete alle lesenden Ansichten neu. Das
/// Ziel bleibt dasselbe, solange die Wurzelansicht lebt, deshalb gelten
/// zwei Werte als gleich.
struct ShowInAppAction: Equatable, Sendable {
    let perform: @MainActor @Sendable (HelpJump) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Ohne Wert bietet die Hilfe die Sprünge in Tabs nicht an.
    @Entry var showInApp: ShowInAppAction? = nil
}

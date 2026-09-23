//
//  HelpViews.swift
//  PodcastAI
//
//  Der Einstieg für alle, die die App zum ersten Mal öffnen, und eine
//  Hilfeseite, die nach Erfahrung gestaffelt ist: erst hören, dann
//  verstehen, dann mit dem Wissen arbeiten.
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
                        Markdown exportieren.
                        """, symbol: "text.bubble")

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
                AddSourceSheet()
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

struct HelpView: View {

    // Wege, die auf dem Mac anders heissen. Dort gibt es eine Seitenleiste
    // statt Reitern, und die Einstellungen liegen im Programmmenü. Jeder
    // Text steht als ganzer Satz da, damit er sich übersetzen lässt.
    #if os(macOS)
    private static var queueText: LocalizedStringKey {
        """
        „Als Nächstes“ reiht eine Folge direkt hinter der laufenden ein, gedrückt halten bietet \
        „Ans Ende“. Die Warteschlange steht links in der Seitenleiste und in „Meine Podcasts“.
        """
    }
    private static var askText: LocalizedStringKey {
        """
        In einer Folge unter „Fragen“, über alle Podcasts links unter „Chat“. Die Nummern in der \
        Antwort führen zu den Belegen.
        """
    }
    private static var intelligenceText: LocalizedStringKey {
        """
        Auf dem Gerät oder auf Private Cloud Compute, einstellbar unter PodcastAI › Einstellungen › \
        Intelligenz. Kein anderer KI-Anbieter.
        """
    }
    #else
    private static var queueText: LocalizedStringKey {
        """
        „Als Nächstes“ reiht eine Folge direkt hinter der laufenden ein, gedrückt halten bietet \
        „Ans Ende“. Die Warteschlange liegt in „Meine Podcasts“.
        """
    }
    private static var askText: LocalizedStringKey {
        """
        In einer Folge unter „Fragen“, über alle Podcasts im Reiter „Chat“. Die Nummern in der \
        Antwort führen zu den Belegen.
        """
    }
    private static var intelligenceText: LocalizedStringKey {
        """
        Auf dem Gerät oder auf Private Cloud Compute, einstellbar unter Wissen › Einstellungen › \
        Intelligenz. Kein anderer KI-Anbieter.
        """
    }
    #endif

    var body: some View {
        List {
            Section {
                tip("Abonnieren", """
                    „Meine Podcasts“ › Plus. Namen eintippen und im Apple-Podcast-Verzeichnis abonnieren. \
                    Links gehen auch: Apple Podcasts, Feed-Adresse, einzelne MP3 oder YouTube-Kanal. Zu \
                    YouTube-Kanälen sucht die App den passenden Audio-Podcast.
                    """, "plus.circle")
                tip("Hören", """
                    Folge öffnen und abspielen. Die App merkt sich die Stelle, auch über iPhone, iPad und \
                    Mac hinweg. Im Player: Tempo, Kapitel, Schlaf-Timer, AirPlay.
                    """, "play.circle")
                tip("Warteschlange", Self.queueText, "list.bullet")
                tip("Speicher", """
                    In einer Folge über „Mehr“: „Laden (offline)“ holt den Ton aufs Gerät, „Audio \
                    entfernen“ löscht nur den Ton, „Folge löschen“ löscht Ton, Transkript, Fakten und \
                    Hörstand. Deine Notizen bleiben unter Wissen. Ist das Transkript fertig, entfernt die \
                    App den Ton von selbst, abschaltbar in den Einstellungen.
                    """, "internaldrive")
            } header: { Text("Einsteiger: hören") }

            Section {
                tip("Transkript", """
                    Die App schreibt Folgen auf dem Gerät mit Zeitmarken mit. Im Reiter „Transkript“ \
                    springt ein Tipp an die Stelle; die Suche findet jedes Wort. Für ältere Folgen \
                    tippst du in der Folge auf „Transkript erstellen“.
                    """, "text.alignleft")
                tip("Fakten", "Überprüfbare Aussagen der Folge, jede mit Zeitmarke zum Nachhören.", "checkmark.seal")
                tip("Fragen und Chat", Self.askText, "text.bubble")
                tip("Interessen", "Themen, aktuelle Vorhaben und offene Fragen. Daraus entsteht „Für dich“.",
                    "target")
            } header: { Text("Fortgeschrittene: verstehen") }

            Section {
                tip("Themen-Updates", """
                    Eine eigene Folge je Thema aus ungehörten Originalstellen mehrerer Podcasts, mit \
                    Kapiteln, Shownotes und Cover.
                    """, "waveform.circle")
                tip("Gegenpositionen", "Zu einer These zeigt die App belegte Stimmen dafür und dagegen.",
                    "arrow.left.arrow.right")
                tip("Export", """
                    Folgen mit Shownotes, Kapiteln, Fakten und Transkript, Chat-Antworten mit Belegen und \
                    gemerkte Stellen als Markdown, etwa für Obsidian oder Notion.
                    """, "square.and.arrow.up")
                tip("Apple Intelligence", Self.intelligenceText, "sparkles")
                tip("Kurzbefehle und Mac", """
                    Themen-Updates per Siri. Auf dem Mac kann ein KI-Agent über MCP lesend auf dein \
                    Wissen zugreifen, aber nur mit deiner Freigabe unter PodcastAI › Einstellungen › \
                    Agenten. Dort steht auch der Eintrag für den Agenten.
                    """, "terminal")
            } header: { Text("Experten: mit dem Wissen arbeiten") }

            // Die Wörter, die in der App am häufigsten vorkommen, kurz erklärt.
            Section {
                term("Transkript", """
                    Der mitgeschriebene Text einer Folge. Erst damit kannst du in der Folge suchen und \
                    Fragen stellen.
                    """)
                term("Themen-Update", """
                    Eine eigene Folge zu einem Thema. Die App stellt sie aus Stellen deiner Podcasts \
                    zusammen, die du noch nicht gehört hast.
                    """)
                term("Gemerkte Stelle", """
                    Ein Ausschnitt aus einer Folge, den du dir mit Zeitmarke gemerkt hast, auf Wunsch mit \
                    Notiz. Du findest sie unter „Gemerkte Stellen“.
                    """)
                term("Chat", """
                    Hier fragst du alle deine Podcasts auf einmal. Jede Antwort zeigt die Stellen, auf \
                    die sie sich stützt.
                    """)
            } header: { Text("Begriffe") }
        }
        .navigationTitle("So funktioniert's")
    }

    private func tip(_ title: LocalizedStringKey, _ text: LocalizedStringKey, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }

    /// Ein Eintrag im Glossar: das Wort und ein, zwei Sätze dazu.
    private func term(_ word: LocalizedStringKey, _ meaning: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(word).font(.body.weight(.semibold))
            Text(meaning).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

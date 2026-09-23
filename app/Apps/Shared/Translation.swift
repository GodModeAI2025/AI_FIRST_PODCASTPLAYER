//
//  Translation.swift
//  PodcastAI
//
//  Fremdsprachige Podcasts in der Sprache der App lesen.
//
//  Übersetzt wird auf dem Gerät, mit Apples Übersetzung, und nur auf
//  Wunsch: ein Tipp auf „Übersetzen“ im Transkript oder in den Shownotes,
//  „Übersetzen“ beim Wortlaut eines Fakts und bei einem Beleg im Chat.
//  Das Original bleibt die Quelle. Merken, Kopieren und Zitieren nehmen
//  immer den Originaltext, die Übersetzung ist eine Lesehilfe.
//
//  Übersetzte Absätze eines Transkripts liegen als Datei unter Application
//  Support, je Folge ein Ordner, darin je Transkript und Zielsprache eine
//  Datei. Die Datenbank bleibt, wie sie ist. „Folge löschen“ nimmt den
//  Ordner mit, „Audio entfernen“ lässt ihn stehen.
//

import SwiftUI
import Translation
import NaturalLanguage
import PodcastAIKit

// MARK: - Sprache eines Textes

extension AppLanguage {

    /// Die Sprache eines Textes, auf dem Gerät erkannt. `nil`, wenn die
    /// Erkennung unsicher ist, etwa bei sehr kurzem Text.
    static func languageCode(of text: String) -> String? {
        let sample = String(text.prefix(1_000))
        guard sample.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= 0.6 else { return nil }
        return Locale(identifier: language.rawValue).language.languageCode?.identifier
    }

    /// Steht der Text sicher in einer anderen Sprache als die App?
    func isForeign(_ text: String) -> Bool {
        guard let code = Self.languageCode(of: text) else { return false }
        return code != rawValue
    }

    /// Eine Sprachangabe wie „en_US“ als Ausgangssprache einer Übersetzung.
    static func translationSource(_ identifier: String) -> Locale.Language? {
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { return nil }
        return Locale.Language(identifier: code)
    }
}

// MARK: - Ablage

/// Übersetzte Absätze eines Transkripts, als Datei auf diesem Gerät.
enum TranslationCache {

    /// Ein übersetzter Absatz. Der Originaltext steht dabei: ändert sich das
    /// Transkript, passt er nicht mehr, und der Absatz wird neu übersetzt.
    struct Entry: Codable, Sendable {
        let source: String
        let text: String
    }

    struct Key: Sendable, Equatable {
        let episodeID: EpisodeID
        let transcriptID: TranscriptID
        let target: AppLanguage
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PodcastAI/Translations", isDirectory: true)
    }

    static func file(for key: Key) -> URL {
        directory
            .appendingPathComponent(key.episodeID.rawValue, isDirectory: true)
            .appendingPathComponent("\(key.transcriptID.rawValue)-\(key.target.rawValue).json")
    }

    /// Gelesen ausserhalb des Hauptthreads. Die Schlüssel sind Startzeiten
    /// in Millisekunden.
    static func load(_ key: Key) async -> [Int64: Entry] {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file(for: key)),
                  let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
            var result: [Int64: Entry] = [:]
            for (start, entry) in stored {
                if let milliseconds = Int64(start) { result[milliseconds] = entry }
            }
            return result
        }.value
    }

    static func save(_ entries: [Int64: Entry], for key: Key) async {
        await Task.detached(priority: .utility) {
            let url = file(for: key)
            let stored = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Entfernt alles, was zu diesen Folgen übersetzt wurde.
    static func remove(episodes: [EpisodeID]) {
        for id in episodes {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(id.rawValue, isDirectory: true))
        }
    }
}

// MARK: - Absätze übersetzen

/// Übersetzt eine Folge von Absätzen, auf Wunsch und auf dem Gerät.
///
/// Die Arbeit macht eine `TranslationSession`, die SwiftUI über
/// `.translationTask` bereitstellt. Nur so darf das System fragen, ob es ein
/// fehlendes Sprachpaket laden soll. Die Absätze tragen Schlüssel, im
/// Transkript die Startzeit in Millisekunden, in den Shownotes die Nummer.
@MainActor @Observable
final class ParagraphTranslation {

    /// Übersetzte Absätze nach Schlüssel.
    private(set) var texts: [Int64: String] = [:]
    /// Zeigt die Ansicht die Übersetzung?
    var isShown = false
    /// Setzt `.translationTask` in Gang. Bleibt `nil`, bis jemand übersetzt.
    var configuration: TranslationSession.Configuration?
    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    /// Warum nicht übersetzt wird, in einem Satz.
    private(set) var problem: String?
    /// Ein Hinweis, der kein Fehler ist, etwa dass ein Sprachpaket kommt.
    private(set) var notice: String?

    private(set) var source: Locale.Language?
    private let target: AppLanguage
    private var cacheKey: TranslationCache.Key?
    private var cached: [Int64: TranslationCache.Entry] = [:]
    private var pending: [(key: Int64, text: String)] = []

    init(target: AppLanguage = .current) {
        self.target = target
    }

    /// Stellt Ausgangssprache und Ablage ein und liest, was schon übersetzt ist.
    /// Ohne `cacheKey` bleibt die Übersetzung nur im Speicher.
    func prepare(source: Locale.Language?, cacheKey: TranslationCache.Key?,
                 paragraphs: [(key: Int64, text: String)]) async {
        guard self.source != source || self.cacheKey != cacheKey else {
            adopt(paragraphs)
            return
        }
        self.source = source
        self.cacheKey = cacheKey
        // Eine neue Ausgangssprache braucht eine neue Sitzung.
        configuration = nil
        texts = [:]
        cached = [:]
        problem = nil
        notice = nil
        if let cacheKey { cached = await TranslationCache.load(cacheKey) }
        adopt(paragraphs)
    }

    /// Übernimmt Übersetzungen, deren Original noch stimmt. Hat sich ein
    /// Absatz geändert, fällt seine alte Übersetzung weg.
    private func adopt(_ paragraphs: [(key: Int64, text: String)]) {
        var result: [Int64: String] = [:]
        for paragraph in paragraphs {
            if let entry = cached[paragraph.key], entry.source == paragraph.text {
                result[paragraph.key] = entry.text
            }
        }
        texts = result
    }

    /// „Übersetzen“ oder „Original“.
    func toggle(_ paragraphs: [(key: Int64, text: String)]) async {
        if isShown {
            isShown = false
            return
        }
        // Läuft die Übersetzung noch, geht sie weiter. Kein zweiter Lauf.
        if isRunning {
            isShown = true
            return
        }
        problem = nil
        notice = nil
        let missing = paragraphs.filter { texts[$0.key] == nil && !$0.text.isEmpty }
        guard !missing.isEmpty else {
            isShown = true
            return
        }
        let targetLanguage = target.localeLanguage
        if let source {
            switch await LanguageAvailability().status(from: source, to: targetLanguage) {
            case .unsupported:
                problem = Self.unsupported(from: source)
                return
            case .supported:
                notice = String(localized: """
                    Für diese Übersetzung braucht das Gerät ein Sprachpaket. \
                    Das System fragt, ob es geladen werden soll.
                    """)
            case .installed:
                break
            @unknown default:
                break
            }
        }
        pending = missing
        done = 0
        total = missing.count
        isRunning = true
        isShown = true
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: source, target: targetLanguage)
        } else {
            configuration?.invalidate()
        }
    }

    /// Läuft in `.translationTask`. Übersetzt in Portionen, damit die
    /// Absätze nach und nach erscheinen und ein Abbruch nicht alles kostet.
    ///
    /// Ausserhalb des Hauptthreads: die Sitzung ist nicht `Sendable` und
    /// bleibt in dem Aufgabenkontext, in dem SwiftUI sie übergibt. Zum
    /// Hauptthread gehen nur fertige Texte.
    nonisolated static func run(_ session: TranslationSession, for translation: ParagraphTranslation) async {
        let work = await translation.takePending()
        guard !work.isEmpty else { return }
        do {
            // Fehlt ein Sprachpaket, fragt das System hier, ob es geladen werden soll.
            try await session.prepareTranslation()
            for start in stride(from: 0, to: work.count, by: portion) {
                let slice = Array(work[start..<min(start + portion, work.count)])
                let requests = slice.map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.key))
                }
                let responses = try await session.translations(from: requests)
                let results = responses.compactMap { response -> (key: Int64, text: String)? in
                    guard let identifier = response.clientIdentifier, let key = Int64(identifier) else { return nil }
                    return (key: key, text: response.targetText)
                }
                await translation.receive(results, originals: slice)
            }
            await translation.finish(nil)
        } catch {
            await translation.finish(error)
        }
    }

    /// Was zu übersetzen ist, genau einmal je Tipp auf „Übersetzen“.
    private func takePending() -> [(key: Int64, text: String)] {
        guard isRunning else { return [] }
        let work = pending
        pending = []
        if work.isEmpty { isRunning = false }
        return work
    }

    private func receive(_ results: [(key: Int64, text: String)], originals: [(key: Int64, text: String)]) async {
        let sources = Dictionary(originals.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
        for result in results {
            guard let original = sources[result.key] else { continue }
            texts[result.key] = result.text
            cached[result.key] = TranslationCache.Entry(source: original, text: result.text)
            done += 1
        }
        notice = nil
        await store()
    }

    private func finish(_ error: (any Error)?) async {
        isRunning = false
        guard let error else { return }
        await store()
        if error is CancellationError || Task.isCancelled { return }
        problem = Self.describe(error)
        notice = nil
        // Ohne einen einzigen übersetzten Absatz bleibt das Original stehen.
        if texts.isEmpty { isShown = false }
    }

    private func store() async {
        guard let cacheKey, !cached.isEmpty else { return }
        await TranslationCache.save(cached, for: cacheKey)
    }

    /// So viele Absätze je Aufruf.
    nonisolated private static let portion = 12

    // MARK: Meldungen

    /// „Von Englisch nach Deutsch …“, mit den Namen in der Sprache der App.
    static func unsupported(from source: Locale.Language) -> String {
        let names = Locale(identifier: AppLanguage.current.rawValue)
        let from = source.languageCode.flatMap { names.localizedString(forLanguageCode: $0.identifier) }
            ?? source.minimalIdentifier
        let to = names.localizedString(forLanguageCode: AppLanguage.current.rawValue)
            ?? AppLanguage.current.rawValue
        return String(localized: "Von \(from) nach \(to) kann dieses Gerät nicht übersetzen.")
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case TranslationError.notInstalled:
            String(localized: """
                Das Sprachpaket für diese Übersetzung fehlt auf diesem Gerät. \
                Beim nächsten Tippen auf „Übersetzen“ fragt das System wieder, ob es geladen werden soll.
                """)
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            String(localized: "Diese Sprache kann dieses Gerät nicht übersetzen.")
        case TranslationError.unableToIdentifyLanguage:
            String(localized: "Die Sprache dieses Textes lässt sich nicht erkennen.")
        default:
            String(localized: "Die Übersetzung hat nicht geklappt. Später noch einmal versuchen.")
        }
    }
}

// MARK: - Bedienung

/// Der Knopf „Übersetzen“ oder „Original“ mit Fortschritt und Meldungen.
struct TranslationControl: View {
    let translation: ParagraphTranslation
    let identifier: String
    /// Steht unter der fertigen Übersetzung: was davon im Original bleibt.
    let note: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.micro) {
            Button(action: action) {
                Label(translation.isShown ? "Original" : "Übersetzen",
                      systemImage: translation.isShown ? "text.quote" : "translate")
                    .frame(minHeight: Design.minimumTapTarget, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(translation.isShown
                ? Text("Zeigt wieder den Originaltext")
                : Text("Übersetzt den Text auf dem Gerät in die Sprache der App"))
            .accessibilityIdentifier(identifier)

            if translation.isRunning {
                HStack(spacing: Design.Spacing.small) {
                    ProgressView()
                    Text("Wird übersetzt: \(translation.done) von \(translation.total)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let problem = translation.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let notice = translation.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if translation.isShown, !translation.isRunning {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Die Shownotes einer Folge, auf Wunsch übersetzt.
///
/// Übersetzt wird der reine Text. Die Links bleiben im Original, ein Tipp
/// auf „Original“ bringt sie zurück.
struct ShownotesContent: View {
    let notes: AttributedString
    let plain: String
    /// Sprache laut Feed, falls der Text selbst keine sichere Auskunft gibt.
    let feedLanguage: String?
    @State private var translation = ParagraphTranslation()
    /// Die Sprache der Shownotes, wenn sie nicht die der App ist.
    @State private var source: Locale.Language?

    private var paragraphs: [(key: Int64, text: String)] {
        plain.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated()
            .map { (key: Int64($0.offset), text: $0.element) }
    }

    /// Zuerst der Text selbst, erst ohne sichere Auskunft die Angabe im Feed.
    /// Viele Feeds nennen eine Sprache, in der sie gar nicht schreiben.
    private static func foreignSource(of plain: String, feedLanguage: String?) -> Locale.Language? {
        let language = AppLanguage.current
        if let code = AppLanguage.languageCode(of: plain) {
            return code == language.rawValue ? nil : Locale.Language(identifier: code)
        }
        guard let feedLanguage, language.matches(feedLanguage) == false else { return nil }
        return AppLanguage.translationSource(feedLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            if translation.isShown {
                Text(paragraphs.map { translation.texts[$0.key] ?? $0.text }.joined(separator: "\n"))
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text(notes)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if source != nil {
                TranslationControl(translation: translation, identifier: "shownotes.translate",
                                   note: "Auf dem Gerät übersetzt. Die Links stehen unter „Original“.") {
                    let list = paragraphs
                    Task { await translation.toggle(list) }
                }
            }
        }
        .task(id: plain) {
            source = Self.foreignSource(of: plain, feedLanguage: feedLanguage)
            await translation.prepare(source: source, cacheKey: nil, paragraphs: paragraphs)
        }
        .translationTask(translation.configuration) { @Sendable [translation] session in
            await ParagraphTranslation.run(session, for: translation)
        }
    }
}

/// „Übersetzen“ für einen einzelnen Text: der Wortlaut eines Fakts, ein
/// Beleg im Chat. Das System zeigt die Übersetzung über dem Text, der Text
/// selbst bleibt, wie er ist.
struct TranslateTextButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Übersetzen", systemImage: "translate")
        }
        .accessibilityHint("Zeigt eine Übersetzung in die Sprache der App")
    }
}

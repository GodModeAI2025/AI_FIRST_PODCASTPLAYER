//
//  TimedTranscriptionEngine.swift
//  PodcastAITranscription
//
//  Sprachanalyse **mit Medienzeit**.
//
//  Die Vorlage ist BrainSpeaks `TranscriptionEngine` — dort erprobter Code
//  gegen SpeechAnalyzer/SpeechTranscriber. Der eine entscheidende
//  Unterschied steht in `makeTranscriber()`:
//
//      BrainSpeak:  attributeOptions: []
//      PodcastAI:   attributeOptions: [.audioTimeRange]
//
//  BrainSpeak diktiert — dort ist Medienzeit bedeutungslos. Für einen
//  Wissensplayer ist sie die Grundlage von allem: ohne sie gibt es keinen
//  Beleg, keinen Sprung zur Originalstelle und keine persönliche Ausgabe.
//
//  Ebenso bewusst: die Zeit kommt aus dem Attribut des Analyseergebnisses,
//  niemals aus `Date()`. Eine 90-Minuten-Folge wird in wenigen Minuten
//  analysiert; eine Wanduhrzeit ergäbe plausible, aber falsche Timecodes.
//

#if canImport(Speech)
import Foundation
import AVFoundation
import Speech
import PodcastAICore
import PodcastAIMedia

/// Ein finalisiertes Analyseergebnis mit Bezug auf die Medienzeit.
public struct TimedTranscriptionResult: Sendable, Equatable {
    public let text: String
    /// Bereich in der Medienfassung. `nil`, wenn das Ergebnis vorläufig ist
    /// oder die API für dieses Stück keinen Zeitbereich geliefert hat.
    public let range: MediaTimeRange?
    public let isFinal: Bool

    public init(text: String, range: MediaTimeRange?, isFinal: Bool) {
        self.text = text; self.range = range; self.isFinal = isFinal
    }
}

/// Wiederaufnahmepunkt einer unterbrochenen Analyse.
///
/// Der modellinterne Zustand von `SpeechAnalyzer` ist nicht als dauerhaft
/// serialisierbar vorausgesetzt. Wiederaufnahme heißt deshalb: ab einer
/// bekannten Medienposition neu analysieren, mit kleinem Überlappungsbereich,
/// und die Überlappung anschließend deduplizieren.
public struct TranscriptionCheckpoint: Codable, Sendable, Equatable {
    public let mediaVersionID: MediaVersionID
    /// Bis hierhin liegen finalisierte Ergebnisse vor.
    public let committedThrough: MediaTime
    public let locale: String
    /// Fassung der Analysekonfiguration. Ändert sie sich, ist eine
    /// Wiederaufnahme nicht mehr mit dem Bestehenden vergleichbar.
    public let configurationRevision: Revision
    public let textRevision: Revision

    public init(
        mediaVersionID: MediaVersionID, committedThrough: MediaTime, locale: String,
        configurationRevision: Revision, textRevision: Revision
    ) {
        self.mediaVersionID = mediaVersionID; self.committedThrough = committedThrough
        self.locale = locale; self.configurationRevision = configurationRevision
        self.textRevision = textRevision
    }

    /// Wie weit vor dem Wiederaufnahmepunkt erneut analysiert wird. Ein
    /// harter Schnitt zerreißt ein Wort oder einen Satz.
    public static let overlap = MediaDuration(seconds: 5)

    public var resumeFrom: MediaTime {
        MediaTime(milliseconds: committedThrough.milliseconds - Self.overlap.milliseconds)
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case alreadyRunning
    case localeNotSupported(String)
    case speechUnavailableOnDevice
    case modelUnavailable(String)
    case noCompatibleAudioFormat
    case fileUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: String(localized: "Es wird bereits ein Transkript erstellt.", bundle: .module)
        case .localeNotSupported(let locale):
            String(localized: "Für \(locale) ist kein Sprachmodell verfügbar.", bundle: .module)
        case .speechUnavailableOnDevice:
            String(localized: """
                Auf diesem Gerät gibt es keine Spracherkennung. Im Simulator ist das normal. \
                Auf einem iPhone, iPad oder Mac mit aktueller Software funktioniert es.
                """, bundle: .module)
        case .modelUnavailable(let reason):
            String(localized: "Das Sprachmodell ist nicht bereit: \(reason)", bundle: .module)
        case .noCompatibleAudioFormat: String(localized: "Kein kompatibles Audioformat gefunden.", bundle: .module)
        case .fileUnreadable(let path):
            String(localized: "Die Datei konnte nicht gelesen werden: \(path)", bundle: .module)
        }
    }
}

public actor TimedTranscriptionEngine {

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var isRunning = false

    public init() {}

    /// Analysiert eine lokale Mediendatei vollständig.
    ///
    /// Der Zeitbezug entsteht aus zwei unabhängigen Quellen, die
    /// gegeneinander geprüft werden:
    ///   1. dem `audioTimeRange`-Attribut des Analyseergebnisses,
    ///   2. der Sampleposition des eingespeisten Puffers.
    /// Fehlt das Attribut, dient die Sampleposition als Rückfall — sie ist
    /// weniger genau, aber immer noch Medienzeit und nie Wanduhrzeit.
    public func transcribeFile(
        at url: URL,
        mediaVersionID: MediaVersionID,
        locale requestedLocale: Locale,
        startingAt offset: MediaTime = .zero
    ) async throws -> AsyncThrowingStream<TimedTranscriptionResult, Error> {

        guard !isRunning else { throw TranscriptionError.alreadyRunning }
        isRunning = true

        let locale: Locale
        do {
            locale = try await ensureModel(for: requestedLocale)
        } catch {
            // Sonst bliebe die Engine gesperrt und jeder weitere Versuch
            // meldete „läuft bereits“.
            isRunning = false
            throw error
        }

        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            isRunning = false
            throw TranscriptionError.noCompatibleAudioFormat
        }

        // Begrenzte Warteschlange statt der unbegrenzten Voreinstellung.
        // Der Leser ist schneller als die Erkennung; unbegrenzt gepuffert
        // sammelt sich eine Stunde Audio als PCM im Speicher an.
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.inputBufferCount))
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: inputSequence)

        // Puffer einspeisen. Die Sampleposition wird mitgeführt, damit auch
        // ohne Zeitattribut ein Medienbezug vorliegt.
        let feeding = Task { [weak self] in
            do {
                let converter = BufferConverter()
                var framesFed: AVAudioFramePosition = 0
                for try await buffer in AudioFileReader.stream(from: url, startingAt: offset) {
                    let converted = try converter.convert(buffer, to: analyzerFormat)
                    await Self.feed(AnalyzerInput(buffer: converted), into: continuation)
                    framesFed += AVAudioFramePosition(buffer.frameLength)
                    await self?.recordFedPosition(
                        frames: framesFed, sampleRate: buffer.format.sampleRate, offset: offset
                    )
                }
                continuation.finish()
                // Eingabe ist zu Ende: jetzt abschließen. Erst danach endet
                // `transcriber.results`. Stünde dieser Aufruf hinter der
                // Ergebnisschleife, warteten beide aufeinander.
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
            }
        }

        return AsyncThrowingStream { outer in
            Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let range = Self.mediaRange(from: result, fallbackOffset: offset)
                        outer.yield(TimedTranscriptionResult(
                            text: String(result.text.characters),
                            range: range,
                            isFinal: result.isFinal
                        ))
                    }
                    outer.finish()
                } catch {
                    outer.finish(throwing: error)
                }
                feeding.cancel()
                await self?.markStopped()
            }
        }
    }

    /// Wie viele Blöcke höchstens auf die Erkennung warten dürfen.
    /// 64 Blöcke zu 4096 Frames sind bei 16 kHz gut 16 Sekunden Vorlauf und
    /// wenige Megabyte — genug, damit die Erkennung nie auf die Platte
    /// warten muss, und wenig genug, dass die Länge der Folge keine Rolle
    /// spielt.
    static let inputBufferCount = 64

    /// Speist einen Block ein und **wartet**, wenn die Warteschlange voll ist.
    ///
    /// `AsyncStream` kennt keinen Gegendruck: es kann puffern oder
    /// verwerfen, nicht bremsen. Unbegrenzt puffern heißt, dass der Leser
    /// der Erkennung davonläuft und der Speicher mit ihm. Verwerfen hieße
    /// stumm fehlendes Transkript — ein Loch, das niemand bemerkt, weil an
    /// der Stelle einfach kein Satz steht. Also: begrenzt puffern und bei
    /// Rückstau kurz warten, bis wieder Platz ist.
    ///
    /// `.bufferingOldest` ist dafür die richtige Wahl: bei vollem Puffer
    /// wird der *neue* Block abgewiesen und zurückgegeben, statt einen
    /// bereits angenommenen zu verdrängen. Damit geht kein Block verloren.
    static func feed(
        _ input: AnalyzerInput, into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        var pending = input
        while !Task.isCancelled {
            switch continuation.yield(pending) {
            case .enqueued:
                return
            case .dropped(let rejected):
                pending = rejected
                try? await Task.sleep(for: .milliseconds(20))
            case .terminated:
                return
            @unknown default:
                return
            }
        }
    }

    /// **Die entscheidende Zeile dieses Moduls.**
    ///
    /// `attributeOptions: [.audioTimeRange]` fordert die Zeitbereiche an.
    /// Ohne diese Option liefert `SpeechTranscriber` Text ohne Medienbezug —
    /// genau der Zustand, in dem sich der BrainSpeak-Bestandscode befindet.
    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Liest den Medienzeitbereich aus den Attributen des Ergebnisses.
    ///
    /// `result.text` ist ein `AttributedString`; der Zeitbereich hängt an
    /// seinen Runs. Genommen wird die Spanne vom frühesten Anfang bis zum
    /// spätesten Ende über alle Runs mit Zeitattribut.
    private static func mediaRange(
        from result: SpeechTranscriber.Result,
        fallbackOffset: MediaTime
    ) -> MediaTimeRange? {
        var earliest: CMTime?
        var latest: CMTime?

        for run in result.text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            if earliest == nil || timeRange.start < earliest! { earliest = timeRange.start }
            let end = timeRange.end
            if latest == nil || end > latest! { latest = end }
        }

        guard let start = earliest, let end = latest,
              start.isValid, end.isValid, start.isNumeric, end.isNumeric else {
            return nil
        }

        let startMs = Int64((start.seconds * 1000).rounded()) + fallbackOffset.milliseconds
        let endMs = Int64((end.seconds * 1000).rounded()) + fallbackOffset.milliseconds
        return MediaTimeRange(
            start: MediaTime(milliseconds: startMs),
            end: MediaTime(milliseconds: endMs)
        )
    }

    // MARK: - Zustand

    private var fedThrough: MediaTime = .zero

    private func recordFedPosition(frames: AVAudioFramePosition, sampleRate: Double, offset: MediaTime) {
        guard sampleRate > 0 else { return }
        let ms = Int64((Double(frames) / sampleRate * 1000).rounded()) + offset.milliseconds
        fedThrough = MediaTime(milliseconds: ms)
    }

    /// Bis wohin Audio eingespeist wurde — die Obergrenze für einen Checkpoint.
    public func fedPosition() -> MediaTime { fedThrough }

    private func markStopped() {
        isRunning = false
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
    }

    public func cancel() async {
        inputContinuation?.finish()
        try? await analyzer?.cancelAndFinishNow()
        markStopped()
    }

    // MARK: - Sprachmodelle

    /// Bestimmt das tatsächlich nutzbare Sprachmodell und lädt es bei Bedarf.
    ///
    /// Feeds geben oft nur die Sprache an („en“), das Modell braucht eine
    /// Region. Gesucht wird in dieser Reihenfolge: genau die Angabe, die
    /// Sprache mit der Region des Geräts, eine übliche Standardregion,
    /// zuletzt was das System als gleichwertig ansieht.
    private func ensureModel(for requested: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechUnavailableOnDevice
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { throw TranscriptionError.speechUnavailableOnDevice }

        let byID = Dictionary(supported.map { ($0.identifier(.bcp47), $0) },
                              uniquingKeysWith: { first, _ in first })
        let language = requested.language.languageCode?.identifier ?? requested.identifier
        var candidates = [requested.identifier(.bcp47)]
        if let region = Locale.current.region?.identifier {
            candidates.append("\(language)-\(region)")
        }
        if let preferred = Self.defaultRegion[language] {
            candidates.append("\(language)-\(preferred)")
        }
        var resolved = candidates.lazy.compactMap { byID[$0] }.first
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        }
        guard let locale = resolved else {
            throw TranscriptionError.localeNotSupported(requested.identifier(.bcp47))
        }
        let identifier = locale.identifier(.bcp47)

        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == identifier }) else { return locale }

        // Modell herunterladen. Rund 300 MB je Sprache — das ist eine
        // Nutzerentscheidung und wird in der Oberfläche angekündigt, nicht
        // stillschweigend im Hintergrund erledigt.
        let transcriber = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return locale
    }

    /// Region, wenn der Feed nur die Sprache nennt und die Geräteregion
    /// nicht passt.
    static let defaultRegion: [String: String] = [
        "en": "US", "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
        "pt": "BR", "ja": "JP", "ko": "KR", "zh": "CN",
    ]
}
#endif

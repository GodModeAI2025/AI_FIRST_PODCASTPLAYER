//
//  AudioFileReader.swift
//  PodcastAIMedia
//
//  Liest eine lokale Mediendatei blockweise als PCM-Strom.
//
//  Übernommen aus BrainSpeaks `AudioFileReader` — dort bereits richtig
//  gelöst: 4096 Frames je Block, damit der Speicherbedarf unabhängig von der
//  Dateilänge bleibt. Eine 90-Minuten-Folge darf nicht als `Data` im
//  Speicher landen.
//
//  Neu gegenüber der Vorlage ist `startingAt:` — die Wiederaufnahme einer
//  unterbrochenen Analyse braucht einen Einstieg mitten in der Datei.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation

public enum AudioFileReader {

    public static let defaultFrameCount: AVAudioFrameCount = 4_096

    public enum ReaderError: Error, LocalizedError {
        case unreadable(String)
        case allocationFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Die Audiodatei konnte nicht geöffnet werden: \(path)"
            case .allocationFailed: "Der Audiopuffer konnte nicht angelegt werden."
            }
        }
    }

    /// Liefert PCM-Puffer im nativen Format der Datei bis zum Ende.
    ///
    /// Die Formatanpassung übernimmt der `BufferConverter` weiter oben in der
    /// Kette — hier wird bewusst nicht konvertiert, damit keine doppelte
    /// Umrechnung entsteht.
    ///
    /// **Warum kein `AsyncThrowingStream`.** Die vorige Fassung las die
    /// Datei in einer eigenen Task, so schnell die Platte hergab, und legte
    /// jeden Puffer in einen Strom mit `bufferingPolicy: .unbounded` — der
    /// Voreinstellung. Der Verbraucher ist die Spracherkennung und damit um
    /// Größenordnungen langsamer. Bei 44,1 kHz in Stereo und 32 Bit sind
    /// 4096 Frames rund 32 KB; eine Stunde Material ergibt gut 1,2 GB, die
    /// sich im Strom sammeln, bis das System die App beendet. Das ist kein
    /// theoretischer Fall — es ist der Normalfall jeder längeren Folge.
    ///
    /// Eine kleinere Puffergrenze wäre die falsche Antwort: `AsyncStream`
    /// kann nur *verwerfen*, und verworfene Frames sind stumm fehlendes
    /// Transkript. Deshalb wird hier gezogen statt geschoben — der nächste
    /// Block wird gelesen, wenn er gebraucht wird, und nie früher.
    public static func stream(
        from url: URL,
        startingAt offset: PodcastAIMediaTime = .zero,
        frameCount: AVAudioFrameCount = defaultFrameCount
    ) -> BufferSequence {
        BufferSequence(url: url, offset: offset, frameCount: frameCount)
    }

    /// Ein Strom von PCM-Blöcken, der genau einen Block auf einmal hält.
    public struct BufferSequence: AsyncSequence, Sendable {

        public typealias Element = AVAudioPCMBuffer

        let url: URL
        let offset: PodcastAIMediaTime
        let frameCount: AVAudioFrameCount

        public func makeAsyncIterator() -> Iterator {
            Iterator(url: url, offset: offset, frameCount: frameCount)
        }

        public struct Iterator: AsyncIteratorProtocol {

            private let url: URL
            private let offset: PodcastAIMediaTime
            private let frameCount: AVAudioFrameCount
            /// Erst beim ersten `next()` geöffnet: eine Sequenz, über die
            /// niemand läuft, soll auch keine Datei offen halten.
            private var file: AVAudioFile?
            private var finished = false

            init(url: URL, offset: PodcastAIMediaTime, frameCount: AVAudioFrameCount) {
                self.url = url
                self.offset = offset
                self.frameCount = frameCount
            }

            public mutating func next() async throws -> AVAudioPCMBuffer? {
                if finished { return nil }
                try Task.checkCancellation()

                let file = try openIfNeeded()
                let format = file.processingFormat

                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: frameCount
                ) else {
                    finished = true
                    throw ReaderError.allocationFailed
                }
                do {
                    try file.read(into: buffer, frameCount: frameCount)
                } catch {
                    finished = true
                    throw error
                }
                if buffer.frameLength == 0 {
                    finished = true
                    return nil
                }
                return buffer
            }

            private mutating func openIfNeeded() throws -> AVAudioFile {
                if let file { return file }
                let opened: AVAudioFile
                do {
                    opened = try AVAudioFile(forReading: url)
                } catch {
                    finished = true
                    throw ReaderError.unreadable(url.lastPathComponent)
                }
                // Einstieg mitten in der Datei für die Wiederaufnahme.
                if offset.milliseconds > 0 {
                    let frame = AVAudioFramePosition(
                        (Double(offset.milliseconds) / 1000) * opened.processingFormat.sampleRate
                    )
                    opened.framePosition = min(max(0, frame), opened.length)
                }
                file = opened
                return opened
            }
        }
    }

    /// Länge der Datei, ohne sie einzulesen.
    public static func duration(of url: URL) throws -> PodcastAIMediaDuration {
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return PodcastAIMediaDuration(seconds: seconds)
    }
}
#endif

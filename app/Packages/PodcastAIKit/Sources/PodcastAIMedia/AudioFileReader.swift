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
    public static func stream(
        from url: URL,
        startingAt offset: PodcastAIMediaTime = .zero,
        frameCount: AVAudioFrameCount = defaultFrameCount
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {

        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat

                    // Einstieg mitten in der Datei für die Wiederaufnahme.
                    if offset.milliseconds > 0 {
                        let frame = AVAudioFramePosition(
                            (Double(offset.milliseconds) / 1000) * format.sampleRate
                        )
                        file.framePosition = min(frame, file.length)
                    }

                    while !Task.isCancelled {
                        guard let buffer = AVAudioPCMBuffer(
                            pcmFormat: format, frameCapacity: frameCount
                        ) else {
                            throw ReaderError.allocationFailed
                        }
                        try file.read(into: buffer, frameCount: frameCount)
                        if buffer.frameLength == 0 { break }
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

//
//  BufferConverter.swift
//  PodcastAIMedia
//
//  Wandelt beliebige PCM-Puffer in das Format, das der Analyzer erwartet.
//  Übernommen aus BrainSpeak; der Konverter wird wiederverwendet, statt je
//  Puffer einen neuen anzulegen — bei 4096-Frame-Blöcken sind das sonst
//  tausende Allokationen je Folge.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation

public final class BufferConverter: @unchecked Sendable {

    public enum ConversionError: Error, LocalizedError {
        case formatMismatch
        case allocationFailed
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .formatMismatch: String(localized: "Das Audioformat ist nicht umwandelbar.", bundle: .module)
            case .allocationFailed: String(localized: "Der Zielpuffer konnte nicht angelegt werden.", bundle: .module)
            case .failed(let message):
                String(localized: "Die Umwandlung ist fehlgeschlagen: \(message)", bundle: .module)
            }
        }
    }

    private var converter: AVAudioConverter?

    public init() {}

    public func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.outputFormat != format
            || converter?.inputFormat != buffer.format {
            guard let new = AVAudioConverter(from: buffer.format, to: format) else {
                throw ConversionError.formatMismatch
            }
            new.primeMethod = .none  // Keine eingefügte Stille: sie würde die Zeitachse verschieben.
            converter = new
        }
        guard let converter else { throw ConversionError.formatMismatch }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            throw ConversionError.allocationFailed
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw ConversionError.failed(conversionError?.localizedDescription
                                         ?? String(localized: "unbekannt", bundle: .module))
        }
        return output
    }
}
#endif

//
//  PlaybackSpeed.swift
//  PodcastAICore
//
//  Die Stufen des Wiedergabetempos.
//
//  Sie stehen in Core, damit jede Oberfläche dieselbe Liste nimmt, vom
//  iPhone über CarPlay bis zu Uhr und Fernseher. Mit einer eigenen Liste je
//  Oberfläche fände die Tempotaste im Auto eine Stufe nicht, die nur der
//  Player des iPhones kennt, und spränge zurück auf 1,0.
//

import Foundation

public enum PlaybackSpeed {
    public static let options: [Float] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0]

    /// Die nächste Stufe, nach der letzten wieder die erste.
    public static func next(after rate: Float) -> Float {
        guard let index = options.firstIndex(where: { abs($0 - rate) < 0.01 }) else { return 1.0 }
        return options[(index + 1) % options.count]
    }

    public static func label(_ rate: Float) -> String {
        let text = rate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text)×"
    }
}

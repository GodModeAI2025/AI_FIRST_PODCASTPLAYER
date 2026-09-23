//
//  AppLanguage.swift
//  PodcastAICore
//
//  Die Sprache, in der die App mit dem Nutzer spricht.
//
//  Es gibt genau eine Quelle dafür: die Lokalisierung, in der die App
//  gerade läuft. Was Apple Intelligence formuliert, erscheint in derselben
//  Sprache wie die Knöpfe daneben, egal in welcher Sprache der Podcast ist.
//  Die Sprache des Geräts allein reicht dafür nicht: ein Gerät auf
//  Französisch zeigt die App in einer Sprache, die sie mitbringt, und in
//  genau der sollen auch Fakten und Antworten stehen.
//

import Foundation

public enum AppLanguage: String, Sendable, CaseIterable, Codable {
    case german = "de"
    case english = "en"

    /// Die Sprache der laufenden App, aus `Bundle.main.preferredLocalizations`.
    ///
    /// Im Test ist `Bundle.main` der Testlauf und nicht die App. Tests geben
    /// die Sprache deshalb ausdrücklich an.
    public static var current: AppLanguage {
        resolve(Bundle.main.preferredLocalizations.first)
    }

    /// Macht aus einer Lokalisierung wie „en“, „en-GB“ oder „de_DE“ eine
    /// Sprache der App. Unbekanntes wird Deutsch, die Quellsprache.
    public static func resolve(_ identifier: String?) -> AppLanguage {
        guard let identifier, !identifier.isEmpty else { return .german }
        let code = Locale(identifier: identifier).language.languageCode?.identifier
            ?? String(identifier.prefix(2))
        return AppLanguage(rawValue: code.lowercased()) ?? .german
    }

    /// Zum Übersetzen und Vergleichen.
    public var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Ist Text in dieser Sprache geschrieben? `identifier` ist eine
    /// Sprachangabe wie „en_US“ aus einem Transkript oder „de-DE“ aus einem
    /// Feed. Ohne Angabe lässt sich das nicht sagen, dann `nil`.
    public func matches(_ identifier: String?) -> Bool? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let code = Locale(identifier: identifier).language.languageCode?.identifier
            ?? String(identifier.prefix(2))
        return code.lowercased() == rawValue
    }
}

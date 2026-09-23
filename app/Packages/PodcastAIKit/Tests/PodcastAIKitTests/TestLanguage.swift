//
//  TestLanguage.swift
//  PodcastAIKitTests
//
//  Der Prozess von `swift test` meldet als Sprache Englisch, die App auf
//  einem deutschen Gerät Deutsch. Texte aus dem Paket kommen deshalb je nach
//  Umgebung in der einen oder anderen Sprache. Die Tests prüfen die Sprache,
//  in der das Paket gerade antwortet, und damit beide Kataloge.
//

import Foundation

enum TestLanguage {
    static var isGerman: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true }
    static func pick(de: String, en: String) -> String { isGerman ? de : en }
}

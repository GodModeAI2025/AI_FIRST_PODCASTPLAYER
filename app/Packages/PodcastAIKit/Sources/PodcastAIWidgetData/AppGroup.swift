//
//  AppGroup.swift
//  PodcastAIWidgetData
//
//  Der gemeinsame Ordner von App und Erweiterungen. Die App schreibt dort,
//  das Widget liest. Beide brauchen dafür die Berechtigung
//  `com.apple.security.application-groups` mit derselben Kennung.
//

import Foundation

public enum AppGroup {

    /// Dieselbe Kennung in allen Entitlements von App und Erweiterungen.
    public static let identifier = "group.com.godmodeai.podcastai"

    /// Der Ordner der App Group. `nil`, wenn die Berechtigung fehlt, etwa
    /// in einem Build ohne Signatur.
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Die Arten von Widgets. App und Widget müssen dieselbe Zeichenkette
/// benutzen, sonst lädt `reloadTimelines(ofKind:)` nichts neu.
public enum WidgetKind {
    public static let whatsNew = "com.godmodeai.podcastai.whatsnew"
}

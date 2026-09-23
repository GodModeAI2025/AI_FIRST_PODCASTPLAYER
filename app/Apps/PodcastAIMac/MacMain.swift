//
//  MacMain.swift
//  PodcastAI (macOS)
//
//  Der Einstieg der Mac-App.
//
//  Ohne Argument startet die App wie gewohnt. Mit `--mcp` startet ein
//  anderes Programm, etwa ein KI-Agent, PodcastAI als MCP-Server: ohne
//  Fenster, ohne Dock-Symbol, nur Standardein- und -ausgabe. Die Weiche
//  steht vor SwiftUI, damit in diesem Fall weder AppKit noch das App-Modell
//  hochfahren und kein zweiter Prozess die Mediathek abgleicht.
//

import SwiftUI

@main
@MainActor
enum MacMain {

    static func main() {
        if MCPHost.isRequested {
            MCPHost.runAndExit()
        }
        PodcastAIMacApp.main()
    }
}

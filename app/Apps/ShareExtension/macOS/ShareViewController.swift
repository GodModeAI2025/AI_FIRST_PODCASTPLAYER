//
//  ShareViewController.swift
//  „An PodcastAI senden“ (macOS)
//
//  Hauptklasse der Erweiterung (`NSExtensionPrincipalClass`). Auf dem Mac
//  öffnet sie PodcastAI nach der Übergabe; gelingt das nicht, bleibt der
//  Satz stehen, dass der Link in der App wartet.
//

import AppKit
import SwiftUI

final class ShareViewController: NSViewController {

    override func loadView() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let intake = ShareIntake(
            items: items,
            openApp: { [weak self] url in
                if let context = self?.extensionContext, await context.open(url) { return true }
                return NSWorkspace.shared.open(url)
            },
            complete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            })
        let host = NSHostingView(rootView: ShareView(intake: intake))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        view = host
        preferredContentSize = NSSize(width: 360, height: 240)
    }
}

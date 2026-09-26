//
//  ShareViewController.swift
//  „An PodcastAI senden“ (iOS)
//
//  Hauptklasse der Erweiterung (`NSExtensionPrincipalClass`). Sie hält nur
//  die SwiftUI-Ansicht. Die App zu öffnen ist einer Share Extension unter
//  iOS nicht erlaubt; der Versuch bleibt drin, falls ein System es künftig
//  zulässt, und sonst erscheint der Satz, dass der Link in PodcastAI wartet.
//

import UIKit
import SwiftUI

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let intake = ShareIntake(
            items: items,
            openApp: { [weak self] url in
                guard let context = self?.extensionContext else { return false }
                return await context.open(url)
            },
            complete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            })

        let host = UIHostingController(rootView: ShareView(intake: intake))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

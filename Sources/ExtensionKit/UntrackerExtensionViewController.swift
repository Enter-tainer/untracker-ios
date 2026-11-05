//
//  UntrackerExtensionViewController.swift
//  ExtensionKit
//
//  Hosts the SwiftUI extension UI and wires it to the extension context. Shared by
//  both the Share Extension (Apps row) and the Action Extension (Actions row, and
//  Safari's action menu for selected text — the iOS equivalent of Android's
//  "select text → Untrack").
//
//  Note on sizing: iOS controls the height of an extension sheet and ignores
//  `preferredContentSize`, so this controller deliberately does not try to size
//  itself — the hosted view is pinned to all edges and fills whatever the host
//  gives us. (Earlier attempts with `preferredContentSize` made the view occupy
//  only part of the sheet, which left the action buttons stranded mid-panel.)
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

class UntrackerExtensionViewController: UIViewController {
    private let model = UntrackExtensionViewModel()
    private var hostingController: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installSwiftUI()
        loadSharedContent()
    }

    // MARK: SwiftUI

    private func installSwiftUI() {
        let rootView = UntrackExtensionRootView(
            model: model,
            onCopy: { [weak self] in self?.copyAndFinish() },
            onShare: { [weak self] in self?.presentShareSheet() },
            onCancel: { [weak self] in self?.cancelExtension() }
        )
        let controller = UIHostingController(rootView: rootView)
        // UIHostingController self-sizes by default, which froze the container at the
        // height of the first (loading) layout and left the action buttons stranded
        // mid-panel. Let Auto Layout drive the size instead.
        if #available(iOS 16.0, *) {
            controller.sizingOptions = []
        }
        controller.view.backgroundColor = .systemBackground
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        hostingController = controller
    }

    // MARK: Content

    private func loadSharedContent() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        // Action extensions can also be invoked on a text selection that the host
        // hands over as `NSExtensionItem.attributedContentText`.
        if providers.isEmpty {
            let text = (extensionContext?.inputItems as? [NSExtensionItem])?
                .compactMap { $0.attributedContentText?.string }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let text = text {
                model.load(from: [NSItemProvider(object: text as NSString)])
                return
            }
            model.load(from: [])
            return
        }

        model.load(from: providers)
    }

    // MARK: Actions

    private func copyAndFinish() {
        guard model.hasResult, !model.cleanedText.isEmpty else { return }
        UIPasteboard.general.string = model.cleanedText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func presentShareSheet() {
        guard model.hasResult, !model.cleanedText.isEmpty else { return }
        let controller = UIActivityViewController(
            activityItems: [model.cleanedText],
            applicationActivities: nil
        )
        controller.popoverPresentationController?.sourceView = view
        present(controller, animated: true)
    }

    private func cancelExtension() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "moe.mgt.untracker.extension", code: 0)
        )
    }
}

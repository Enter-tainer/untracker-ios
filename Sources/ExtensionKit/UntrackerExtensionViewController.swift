//
//  UntrackerExtensionViewController.swift
//  ExtensionKit
//
//  Hosts the SwiftUI extension UI and wires it to the extension context. Shared by
//  both the Share Extension (Apps row) and the Action Extension (Actions row, and
//  Safari's action menu for selected text — the iOS equivalent of Android's
//  "select text → Untrack").
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

    /// Roughly half the screen: enough for a link plus the two actions, without the
    /// sheet swallowing the whole page.
    private var sheetHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        return min(380, max(300, screenHeight * 0.45))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferredContentSize = CGSize(width: 0, height: sheetHeight)
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
        controller.view.backgroundColor = .systemBackground
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        // Pin an explicit height: a hosted SwiftUI view otherwise reports an
        // intrinsic size that makes the share sheet grow towards full screen.
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.heightAnchor.constraint(equalToConstant: sheetHeight)
        ])
        preferredContentSize = CGSize(width: 0, height: sheetHeight)
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
                let item = NSExtensionItem()
                let provider = NSItemProvider(object: text as NSString)
                item.attachments = [provider]
                model.load(from: [provider])
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

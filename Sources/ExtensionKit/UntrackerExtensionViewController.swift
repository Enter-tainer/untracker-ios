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

    /// When true the extension does the work and closes immediately: tapping it in the
    /// share sheet's Actions row copies the clean link without showing a panel. iOS
    /// presents extension sheets large and the height cannot be controlled from the
    /// extension, so this is the only way to offer a genuinely quick action.
    var copiesImmediately: Bool { false }
    private var hostingController: UIViewController?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        preferredContentSize = CGSize(width: 0, height: Self.compactSheetHeight())
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        preferredContentSize = CGSize(width: 0, height: Self.compactSheetHeight())
    }

    /// Roughly half the screen — enough for a link plus the two actions.
    private static func compactSheetHeight() -> CGFloat {
        min(380, max(300, UIScreen.main.bounds.height * 0.45))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if !copiesImmediately {
            installSwiftUI()
        }
        preferredContentSize = CGSize(width: 0, height: sheetHeight)
        loadSharedContent()

        // The host reads the preferred size after the first layout pass; set it again
        // so a compact sheet is not replaced by the full-height default.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.preferredContentSize = CGSize(width: 0, height: self.sheetHeight)
        }
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
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The host derives the sheet height from this view's fitting size, not from
        // preferredContentSize, so give the view itself a definite height.
        let compactHeight = view.heightAnchor.constraint(equalToConstant: sheetHeight)
        compactHeight.priority = .required
        compactHeight.isActive = true
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

        model.onResult = { [weak self] _ in
            guard let self = self, self.copiesImmediately else { return }
            guard self.model.hasResult, !self.model.cleanedText.isEmpty else {
                self.extensionContext?.cancelRequest(
                    withError: NSError(domain: "moe.mgt.untracker.extension", code: 1))
                return
            }
            UIPasteboard.general.string = self.model.cleanedText
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
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

//
//  UntrackerExtensionViewController.swift
//  ExtensionKit
//
//  Hosts the SwiftUI extension UI and wires it to the extension context. Shared by
//  both the Share Extension (apps row) and the Action Extension (bottom quick action,
//  and Safari's action menu).
//
//  The two entries differ in one respect: the Share Extension (app row) is a silent
//  one-tap copy — no UI at all, just a success haptic before the sheet closes itself
//  (`copiesImmediately`); the Action Extension (bottom quick action / Safari action menu)
//  shows the review panel (cleaned link, removed parameters, matched rules, Copy and Share).
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
    private var hasAppeared = false
    private var hasCompleted = false
    private var pendingCompletion = false
    private var watchdog: DispatchWorkItem?

    /// Quick entries copy the clean link and dismiss themselves without showing anything.
    /// The Share Extension (share sheet app row) overrides this to `true`; the Action
    /// Extension keeps the review panel.
    var copiesImmediately: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        ExtensionLog.line("loaded quick=\(copiesImmediately)")
        if copiesImmediately {
            // No UI at all: the system page gets no content, it is only the container in
            // which the copy happens. Background stays clear so the flash is minimal.
            view.backgroundColor = .clear
            // Never leave the share sheet stuck, whatever the payload does.
            scheduleWatchdog()
        } else {
            view.backgroundColor = .systemBackground
            installSwiftUI()
        }
        loadSharedContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if pendingCompletion {
            // The early completeRequest was ignored (only happens on some hosts); ask again
            // now that the container is definitely up.
            pendingCompletion = false
            completeRequest(reason: "retry-after-appear")
        }
    }

    // MARK: SwiftUI

    private func installSwiftUI() {
        guard hostingController == nil else { return }
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
        // Quick and panel paths must produce the same result — including short-link
        // expansion. Skipping the network rules here used to hand b23.tv / t.cn style
        // shares back untouched (TECH-65).
        let rules = RuleStore.shared.enabledRules
        if copiesImmediately {
            // The quick action is invisible; the extension context exists purely to receive
            // the payload, copy the clean link and complete the request.
            model.onResult = { [weak self] _ in self?.finishQuickCopy() }
        }

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        ExtensionLog.line("providers=\(providers.count) rules=\(rules.count)")

        // Action extensions can also be invoked on a text selection that the host
        // hands over as `NSExtensionItem.attributedContentText`.
        if providers.isEmpty {
            let text = (extensionContext?.inputItems as? [NSExtensionItem])?
                .compactMap { $0.attributedContentText?.string }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let text = text {
                ExtensionLog.line("attributedContentText length=\(text.count)")
                model.load(from: [NSItemProvider(object: text as NSString)], rules: rules)
                return
            }
            model.load(from: [], rules: rules)
            return
        }

        model.load(from: providers, rules: rules)
    }

    // MARK: Actions

    /// Quick action: put the clean link on the clipboard, buzz, and get out of the way.
    ///
    /// No UI is involved at all. Text that contains no link is still copied unchanged
    /// (there is simply nothing to strip).
    private func finishQuickCopy() {
        guard model.hasResult, !model.cleanedText.isEmpty else {
            // Nothing to copy — close instead of leaving an empty system page up.
            ExtensionLog.line("nothing to copy; completing")
            completeRequest(reason: "nothing-to-copy")
            return
        }
        UIPasteboard.general.string = model.cleanedText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ExtensionLog.line("copied")
        // Complete immediately: by the time the system would draw the extension page the
        // request is already finished, so the share sheet simply closes instead of showing
        // an empty panel. If a host ignores the early completion, viewDidAppear retries it.
        completeRequest(reason: "quick-copy")
        pendingCompletion = true
    }

    private func completeRequest(reason: String) {
        hasCompleted = true
        watchdog?.cancel()
        watchdog = nil
        ExtensionLog.line("complete (\(reason))")
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// Quick action must never hang: if the payload cannot be resolved, close the sheet.
    private func scheduleWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.hasCompleted else { return }
            ExtensionLog.line("watchdog fired")
            self.completeRequest(reason: "watchdog")
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    private func copyAndFinish() {
        guard model.hasResult, !model.cleanedText.isEmpty else { return }
        UIPasteboard.general.string = model.cleanedText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        completeRequest(reason: "panel-copy")
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
        ExtensionLog.line("cancelled by user")
        hasCompleted = true
        watchdog?.cancel()
        watchdog = nil
        extensionContext?.cancelRequest(
            withError: NSError(domain: "moe.mgt.untracker.extension", code: 0)
        )
    }
}

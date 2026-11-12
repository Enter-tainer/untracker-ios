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
    private let feedback = UINotificationFeedbackGenerator()
    /// Rules resolved once at load time: the quick path uses them twice (local pass and
    /// the network upgrade), the panel path only once.
    private var quickRules: [Rule] = []
    /// Work that must only run once the extension is really on screen.
    private var pendingQuickAction: (() -> Void)?
    private var pendingQuickFallback: DispatchWorkItem?
    /// When the extension view started loading — used to measure how long the system
    /// took to present us (cold vs warm start), which is what triggers TECH-72.
    private var loadedAt = Date()

    /// Quick entries copy the clean link and dismiss themselves without showing anything.
    /// The Share Extension (share sheet app row) overrides this to `true`; the Action
    /// Extension keeps the review panel.
    var copiesImmediately: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadedAt = Date()
        ExtensionLog.line("loaded quick=\(copiesImmediately)")
        if copiesImmediately {
            // No UI at all: the system page gets no content, it is only the container in
            // which the copy happens. Background stays clear so the flash is minimal.
            view.backgroundColor = .clear
            feedback.prepare()
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
        flushPendingQuickAction()
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
        // shares back untouched (TECH-65). The quick path now runs them as a second,
        // optional pass instead of making the copy wait on them (TECH-72).
        let rules = RuleStore.shared.enabledRules
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        // Action extensions can also be invoked on a text selection that the host hands
        // over as `attributedContentText` — with or without attachments.
        let attributedText = items
            .compactMap { $0.attributedContentText?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if copiesImmediately {
            // The quick action is invisible; the extension context exists purely to receive
            // the payload, copy the clean link and complete the request.
            quickRules = rules
            model.onPayload = { [weak self] payload in self?.quickCopy(payload: payload) }
            model.onFailure = { [weak self] reason in self?.quickFail(reason: reason) }
        }

        ExtensionLog.line(
            "providers=\(providers.count) rules=\(rules.count) attributed=\(attributedText?.count ?? 0) quick=\(copiesImmediately)"
        )
        model.load(from: providers, attributedText: attributedText, rules: rules)
    }

    // MARK: Actions

    /// Quick action: put a clean link on the clipboard immediately, then optionally
    /// upgrade it — no UI is involved at all.
    ///
    /// The pasteboard write must not happen before the extension is actually presented:
    /// a warm start resolves the payload in ~10 ms, and iOS then drops the write (and the
    /// haptic), which looked exactly like "first share works, every following one doesn't"
    /// (TECH-72). So the copy runs from `viewDidAppear`; a fallback covers hosts that
    /// never present the extension view.
    private func quickCopy(payload: String) {
        whenVisible { [weak self] in self?.performQuickCopy(payload: payload) }
    }

    private func performQuickCopy(payload: String) {
        let rules = quickRules

        // ① Local pass — offline, must always produce something to copy.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, payload, rules] in
            let local = UntrackService.untrack(text: payload, rules: rules, allowNetwork: false).output

            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.performQuickFail(reason: "local pass produced nothing")
                    return
                }
                self.writeToClipboard(local)
                self.feedback.notificationOccurred(.success)
                ExtensionLog.line("quick copied(local) \(local.prefix(240))")

                // ② Network upgrade — optional. Whatever happens here, ① stays on the
                // clipboard, so a slow network can no longer cost the user the copy.
                guard rules.contains(where: { $0.enabled && $0.requiresNetwork }) else {
                    self.completeQuickCopy(reason: "quick-copy")
                    return
                }
                self.upgradeInBackground(payload: payload, rules: rules, current: local)
            }
        }
    }

    /// Writes the pasteboard and proves whether the write registered, so a device log can
    /// tell "we never copied" apart from "iOS dropped the write".
    private func writeToClipboard(_ text: String) {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = text
        let after = pasteboard.changeCount
        if after > before {
            ExtensionLog.line("pasteboard ok delta=\(after - before) len=\(text.count)")
        } else {
            ExtensionLog.line("pasteboard WRITE LOST before=\(before) after=\(after)")
        }
    }

    private func upgradeInBackground(payload: String, rules: [Rule], current: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let upgraded = UntrackService.untrack(text: payload, rules: rules).output
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !upgraded.isEmpty, upgraded != current {
                    self.writeToClipboard(upgraded)
                    ExtensionLog.line("quick upgraded \(upgraded.prefix(240))")
                } else {
                    ExtensionLog.line("quick upgrade no change")
                }
                self.completeQuickCopy(reason: "quick-copy")
            }
        }
    }

    /// Failure must be perceptible: a silent close would leave the previous clipboard
    /// content in place, which looks exactly like a successful copy (TECH-72).
    private func quickFail(reason: String) {
        ExtensionLog.line("quick failed reason=\(reason)")
        whenVisible { [weak self] in self?.performQuickFail(reason: reason) }
    }

    private func performQuickFail(reason: String) {
        feedback.notificationOccurred(.error)
        completeQuickCopy(reason: "failed:\(reason)")
    }

    /// Runs `action` once the extension view has appeared — or after a short grace period
    /// when the host never presents it, so the quick path still works headless.
    private func whenVisible(_ action: @escaping () -> Void) {
        if hasAppeared {
            action()
            return
        }
        pendingQuickAction = action
        let fallback = DispatchWorkItem { [weak self] in
            guard let self = self, let action = self.pendingQuickAction else { return }
            self.pendingQuickAction = nil
            ExtensionLog.line("quick: view never appeared, acting anyway")
            action()
        }
        pendingQuickFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: fallback)
    }

    private func flushPendingQuickAction() {
        guard let action = pendingQuickAction else { return }
        pendingQuickAction = nil
        pendingQuickFallback?.cancel()
        pendingQuickFallback = nil
        ExtensionLog.line("quick: view appeared after \(Int(Date().timeIntervalSince(loadedAt) * 1000))ms")
        action()
    }

    private func completeQuickCopy(reason: String) {
        // Small grace period: the pasteboard and the haptic are committed by other
        // processes, and completing the request tears this process down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, !self.hasCompleted else { return }
            self.completeRequest(reason: reason)
            // If a host ignores the early completion, viewDidAppear retries it.
            self.pendingCompletion = true
        }
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

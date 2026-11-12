//
//  UntrackExtensionViewModel.swift
//  ExtensionKit
//
//  Shared logic for the Share Extension and the Action Extension: load whatever
//  the host app handed us, run the rules, publish the result for the UI.
//
//  Loading contract (TECH-72): resolving the payload is a *fallible* step. The host
//  hands over an `NSItemProvider`, not the link itself, and its callback can come late
//  or never. So loading has three outcomes — payload / empty / failed — and a failure
//  is never silently reported as "nothing was shared".
//

import Foundation
import UIKit
import UniformTypeIdentifiers

final class UntrackExtensionViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case cleaned
        case unchanged
        case empty(String)
    }

    /// How long the host gets to hand the shared item over before the fallback sources
    /// are used. Hosts normally answer in milliseconds; this only matters when the host
    /// app is wedged. It is a *degradation* point, not a point of giving up.
    private static let loadTimeout: TimeInterval = 2.0

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var originalText = ""
    @Published private(set) var cleanedText = ""
    @Published private(set) var removedParameters: [String] = []
    @Published private(set) var appliedRules: [String] = []

    var hasResult: Bool { phase == .cleaned || phase == .unchanged }

    /// Quick-copy entry point, called on the main queue with the raw payload as soon as
    /// it is resolved. When set, the view model does not run the rules itself: the quick
    /// path copies a locally cleaned link first and upgrades it with the network rules
    /// afterwards (see `UntrackerExtensionViewController.quickCopy`).
    var onPayload: ((String) -> Void)?

    /// Quick-copy entry point, called on the main queue when no payload could be read
    /// (host did not answer, or there was nothing to share). The quick path uses this to
    /// surface a failure instead of closing silently onto a stale clipboard.
    var onFailure: ((String) -> Void)?

    // MARK: Loading

    /// Resolves the payload the host shared, then either hands it to the quick path or
    /// runs the rules for the review panel.
    ///
    /// Many Chinese apps (Bilibili, Xiaohongshu, Douyin …) share a title *and* a link,
    /// sometimes as several attachments. The order of preference is:
    /// URL attachment → text attachment → `NSExtensionItem.attributedContentText`.
    /// Every conforming representation is attempted per provider (not just the first),
    /// and a late answer is still used until the timeout fires.
    func load(from providers: [NSItemProvider], attributedText: String?, rules: [Rule]) {
        let attributed = attributedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !providers.isEmpty || !attributed.isEmpty else {
            ExtensionLog.line("load: nothing handed over (providers=0, no attributedContentText)")
            fail(reason: "Nothing was shared with Untracker.")
            return
        }

        let started = Date()
        let group = DispatchGroup()
        let lock = NSLock()
        var urlString: String?
        var textString: String?
        var settled = false

        ExtensionLog.line("load: providers=\(providers.count) attributedText=\(attributed.count)")
        if !attributed.isEmpty {
            ExtensionLog.line("attributedContentText length=\(attributed.count)")
        }

        /// Runs exactly once: either every provider answered or the timeout fired first.
        func settle(reason: String) {
            lock.lock()
            if settled {
                lock.unlock()
                return
            }
            settled = true
            let url = urlString
            let text = textString
            lock.unlock()

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            ExtensionLog.line(
                "load settled reason=\(reason) elapsed=\(elapsed)ms url=\(url != nil) text=\(text != nil)"
            )
            resolvePayload(url: url, text: text, attributedText: attributed, rules: rules, elapsedMS: elapsed)
        }

        let ladder = [
            UTType.url.identifier,
            UTType.text.identifier,
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier
        ]

        var loadRequests = 0

        for (index, provider) in providers.enumerated() {
            let types = ladder.filter { provider.hasItemConformingToTypeIdentifier($0) }
            ExtensionLog.line("provider[\(index)] registered=\(provider.registeredTypeIdentifiers) ladder=\(types)")
            guard !types.isEmpty else { continue }

            for typeIdentifier in types {
                group.enter()
                loadRequests += 1
                provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                    defer { group.leave() }
                    if let error = error {
                        ExtensionLog.line("provider[\(index)] \(typeIdentifier) error=\(error.localizedDescription)")
                    }
                    guard let value = Self.string(from: item)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !value.isEmpty else { return }
                    lock.lock()
                    if typeIdentifier == UTType.url.identifier {
                        if urlString == nil { urlString = value }
                    } else if textString == nil {
                        textString = value
                    }
                    lock.unlock()
                }
            }
        }

        if loadRequests == 0 {
            // providers > 0 but none of them carries a link/text representation: nothing
            // will ever call back, so don't wait for the timeout.
            ExtensionLog.line("load: no provider conforms to any link/text type")
            settle(reason: "no-conforming-provider")
            return
        }

        // Race the providers against the timeout without blocking a thread, so a late
        // answer that arrives after the timeout is still used by the fallback ladder.
        group.notify(queue: .global(qos: .userInitiated)) {
            settle(reason: "all-providers")
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.loadTimeout) {
            settle(reason: "timeout")
        }
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL { return url.absoluteString }
        if let string = item as? String { return string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    // MARK: Resolution

    private func resolvePayload(
        url: String?,
        text: String?,
        attributedText: String,
        rules: [Rule],
        elapsedMS: Int
    ) {
        let candidates = [url, text, attributedText].compactMap { $0 }
        guard let payload = candidates.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            ExtensionLog.line("load failed after \(elapsedMS)ms: url=nil text=nil attributedText=nil")
            fail(reason: "Could not read the shared link.")
            return
        }

        ExtensionLog.line("payload(\(payload.count)) elapsed=\(elapsedMS)ms \(payload.prefix(240))")

        if let onPayload = onPayload {
            // Quick path: the controller owns the clipboard and the timing.
            DispatchQueue.main.async { onPayload(payload) }
        } else {
            process(payload: payload, rules: rules)
        }
    }

    // MARK: Panel path

    private func process(payload: String, rules: [Rule]) {
        ExtensionLog.line("untracking payload=\(payload.prefix(240))")
        let outcome = UntrackService.untrack(text: payload, rules: rules)
        let cleaned = outcome.changed ? outcome.output : payload
        ExtensionLog.line("untracked changed=\(outcome.changed) urls=\(outcome.urls.count) cleaned=\(cleaned.prefix(240))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.originalText = payload
            self.cleanedText = cleaned
            self.removedParameters = outcome.removedParameters
            self.appliedRules = outcome.appliedRuleNames
            self.phase = outcome.changed ? .cleaned : .unchanged
            if outcome.changed {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    /// Terminal failure: publish it for the panel *and* notify the quick path, so a
    /// failed tap can never be mistaken for a successful one.
    private func fail(reason: String) {
        ExtensionLog.line("load failed reason=\(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.hasResult { return }
            self.phase = .empty(reason)
            self.onFailure?(reason)
        }
    }
}

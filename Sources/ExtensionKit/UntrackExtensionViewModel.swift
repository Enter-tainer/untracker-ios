//
//  UntrackExtensionViewModel.swift
//  ExtensionKit
//
//  Shared logic for the Share Extension and the Action Extension: load whatever
//  the host app handed us, run the rules, publish the result for the UI.
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

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var originalText = ""
    @Published private(set) var cleanedText = ""
    @Published private(set) var removedParameters: [String] = []
    @Published private(set) var appliedRules: [String] = []

    var hasResult: Bool { phase == .cleaned || phase == .unchanged }

    /// Called on the main queue once loading/untracking reaches a terminal phase.
    /// `true` when a link was cleaned, `false` for the empty phases. Quick-share entry
    /// points use this to copy the result without waiting for a UI interaction.
    var onResult: ((Bool) -> Void)?


    // MARK: Loading

    /// Loads the first URL (preferred) or text attachment and untracks it.
    ///
    /// Many Chinese apps (Bilibili, Xiaohongshu, Douyin …) share a title *and* a
    /// link, sometimes as several attachments; prefer the URL, fall back to the
    /// text (which may still contain the link).
    func load(from providers: [NSItemProvider], rules: [Rule]) {
        guard !providers.isEmpty else {
            finish(emptyMessage: "Nothing was shared with Untracker.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urlString: String?
        var textString: String?

        func collect(_ value: String?, isURL: Bool) {
            guard let value = value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            lock.lock()
            if isURL, urlString == nil {
                urlString = value
            } else if textString == nil {
                textString = value
            }
            lock.unlock()
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    collect(Self.string(from: item), isURL: true)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    collect(Self.string(from: item), isURL: false)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Never let a misbehaving item provider keep the share sheet open forever.
            if group.wait(timeout: .now() + 4.0) == .timedOut {
                ExtensionLog.line("provider load timed out, using what arrived")
            }
            lock.lock()
            let url = urlString
            let text = textString
            lock.unlock()
            self?.process(url: url, text: text, rules: rules)
        }
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL { return url.absoluteString }
        if let string = item as? String { return string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func process(url: String?, text: String?, rules: [Rule]) {
        let payload: String
        if let url = url, !url.isEmpty {
            payload = url
        } else if let text = text, !text.isEmpty {
            payload = text
        } else {
            ExtensionLog.line("no payload (url=nil text=nil)")
            finish(emptyMessage: "No link found in what was shared.")
            return
        }

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
            self.onResult?(outcome.changed)
        }
    }

    /// Publishes an empty terminal phase on the main queue and notifies the observer.
    private func finish(emptyMessage: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.phase = .empty(emptyMessage)
            self.onResult?(false)
        }
    }
}

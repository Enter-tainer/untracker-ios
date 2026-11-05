//
//  UntrackService.swift
//  Untracker for iOS
//
//  Finds links in arbitrary text (a shared post, a message, a note), runs the
//  rule list over each of them and splices the cleaned links back into the text.
//  This mirrors `Untracker.untrack(text)` upstream.
//

import Foundation

// MARK: - Result types

struct UntrackedURL {
    /// The URL exactly as it appeared in the input text (no scheme added).
    let original: String
    /// The replacement text written back into the text.
    let untracked: String
    /// Names of the rules that changed this URL, in application order.
    let appliedRules: [String]
    /// Decoded query parameter names that disappeared, for the "what was removed" UI.
    let removedParameters: [String]

    var changed: Bool { original != untracked }
}

struct UntrackResult {
    let input: String
    let output: String
    let urls: [UntrackedURL]

    var changed: Bool { input != output }

    /// Unique rule names that fired, preserving order.
    var appliedRuleNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for url in urls {
            for name in url.appliedRules where !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    /// Unique removed parameter names across every URL.
    var removedParameters: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for url in urls {
            for name in url.removedParameters where !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    var anyURLFound: Bool { !urls.isEmpty }
}

// MARK: - Service

enum UntrackService {
    struct FoundURL {
        let range: NSRange
        let original: String
        let processingURL: String
        let hasScheme: Bool
    }

    /// Cleans every link in `text` using `rules` (only enabled rules are applied).
    static func untrack(text: String, rules: [Rule]) -> UntrackResult {
        let found = findURLs(in: text)
        guard !found.isEmpty else {
            return UntrackResult(input: text, output: text, urls: [])
        }

        let nsText = text as NSString
        let enabledRules = rules.filter { $0.enabled }
        var output = ""
        var cursor = 0
        var untrackedURLs: [UntrackedURL] = []

        for item in found {
            guard item.range.location >= cursor else { continue }
            output += nsText.substring(with: NSRange(location: cursor, length: item.range.location - cursor))

            var cleaned = item.processingURL
            var applied: [String] = []
            if !enabledRules.isEmpty {
                let outcome = UntrackEngine.shared.untrack(item.processingURL, rules: enabledRules)
                cleaned = outcome.url
                applied = outcome.appliedRules
            }
            let removed = removedQueryKeys(before: item.processingURL, after: cleaned)

            var replacement = cleaned
            if !item.hasScheme, replacement.lowercased().hasPrefix("http://") {
                replacement = String(replacement.dropFirst("http://".count))
            }

            output += replacement
            cursor = item.range.location + item.range.length
            untrackedURLs.append(
                UntrackedURL(
                    original: item.original,
                    untracked: replacement,
                    appliedRules: applied,
                    removedParameters: removed
                )
            )
        }

        if cursor < nsText.length {
            output += nsText.substring(from: cursor)
        }

        return UntrackResult(input: text, output: output, urls: untrackedURLs)
    }

    /// Convenience for a single URL string.
    static func untrack(url: String, rules: [Rule]) -> String {
        untrack(text: url, rules: rules).output
    }

    // MARK: Removed parameter diff

    static func removedQueryKeys(before: String, after: String) -> [String] {
        guard let beforeURL = UntrackURL(string: before), let afterURL = UntrackURL(string: after) else {
            return []
        }
        var remaining = afterURL.queryParameters.map { $0.key }
        var removed: [String] = []
        for (key, _) in beforeURL.queryParameters {
            if let index = remaining.firstIndex(of: key) {
                remaining.remove(at: index)
            } else {
                removed.append(key)
            }
        }
        return removed
    }

    // MARK: Link detection

    /// Link detection is a port of androidx `PatternsCompat.AUTOLINK_WEB_URL`, which
    /// is what upstream uses (`PatternsCompat.AUTOLINK_WEB_URL.matcher(text)`).
    ///
    /// `NSDataDetector` is *not* a drop-in replacement: it normalises URLs (e.g. a
    /// trailing bare "?" is dropped), applies different trailing-punctuation rules and
    /// is less permissive around CJK text.
    ///
    /// Upstream then, for every match: keeps it only if `Linkify.sUrlMatchFilter`
    /// accepts it (rejects a match preceded by "@", i.e. the domain of an e-mail
    /// address), skips rtsp/ftp, prepends "http://" when there is no scheme, and
    /// normalises the path's dot segments.
    static func findURLs(in text: String) -> [FoundURL] {
        guard !text.isEmpty, let regex = AutolinkWebURL.regex else { return [] }
        let nsText = text as NSString
        var results: [FoundURL] = []
        var location = 0

        while location < nsText.length {
            let searchRange = NSRange(location: location, length: nsText.length - location)
            guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else { break }
            let range = match.range
            guard range.location != NSNotFound, range.length > 0,
                  range.location + range.length <= nsText.length else { break }
            location = range.location + range.length

            let candidate = nsText.substring(with: range)
            let lowercased = candidate.lowercased()

            // Linkify.sUrlMatchFilter: a domain that is part of "user@example.com".
            if range.location > 0, nsText.character(at: range.location - 1) == 0x40 {
                continue
            }
            if lowercased.hasPrefix("rtsp://") || lowercased.hasPrefix("ftp://") {
                continue
            }

            let hasScheme = lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
            let processingRaw = hasScheme ? candidate : "http://" + candidate
            guard let parsed = UntrackURL(string: processingRaw) else { continue }

            results.append(
                FoundURL(
                    range: range,
                    original: candidate,
                    processingURL: parsed.normalized.string,
                    hasScheme: hasScheme
                )
            )
        }
        return results
    }
}

//
//  UntrackBuiltins.swift
//  Untracker for iOS
//
//  The component-level primitives that the JavaScript rule API (`$.*`) is
//  implemented on top of. Semantics follow the upstream Android implementation
//  (see `Untracker.kt` in zhanghai/Untracker).
//

import Foundation

enum UntrackBuiltins {
    /// `$.matches(url, hostPattern, encodedPathPattern, encodedQueryPattern, encodedFragmentPattern)`
    ///
    /// Every pattern must match its *whole* component (case-insensitively).
    /// A missing component never counts as a mismatch: a query pattern is simply
    /// not applied when the URL has no query, matching the upstream behaviour.
    static func matches(
        _ url: UntrackURL,
        hostPattern: String?,
        pathPattern: String?,
        queryPattern: String?,
        fragmentPattern: String?
    ) -> Bool {
        if let hostPattern = hostPattern, !RegexCache.shared.fullMatch(hostPattern, url.host) {
            return false
        }
        if let pathPattern = pathPattern, !RegexCache.shared.fullMatch(pathPattern, url.rawPath) {
            return false
        }
        if let queryPattern = queryPattern, let rawQuery = url.rawQuery,
           !RegexCache.shared.fullMatch(queryPattern, rawQuery) {
            return false
        }
        if let fragmentPattern = fragmentPattern, let rawFragment = url.rawFragment,
           !RegexCache.shared.fullMatch(fragmentPattern, rawFragment) {
            return false
        }
        return true
    }

    /// `$.removeQueryParameters(url, keyPattern, valuePattern)`
    static func removeQueryParameters(
        _ url: UntrackURL,
        keyPattern: String?,
        valuePattern: String?
    ) -> UntrackURL {
        url.filteringQueryParameters(keyPattern: keyPattern, valuePattern: valuePattern, retain: false)
    }

    /// `$.retainQueryParameters(url, keyPattern, valuePattern)`
    static func retainQueryParameters(
        _ url: UntrackURL,
        keyPattern: String?,
        valuePattern: String?
    ) -> UntrackURL {
        url.filteringQueryParameters(keyPattern: keyPattern, valuePattern: valuePattern, retain: true)
    }
}

// MARK: - Path normalisation

extension UntrackURL {
    /// Removes "." and ".." segments from the path, like `java.net.URI.normalize()`.
    var normalized: UntrackURL {
        guard rawPath.contains(".") else { return self }
        var result = self
        result.rawPath = Self.removingDotSegments(rawPath)
        return result
    }

    static func removingDotSegments(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var stack: [String] = []
        for (index, segment) in segments.enumerated() {
            if index == 0 && isAbsolute && segment.isEmpty { continue }
            switch segment {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(segment)
            }
        }
        var result = (isAbsolute ? "/" : "") + stack.joined(separator: "/")
        if path.hasSuffix("/"), !result.hasSuffix("/") {
            result += "/"
        }
        return result
    }
}

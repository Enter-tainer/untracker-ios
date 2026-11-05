//
//  UntrackURL.swift
//  Untracker for iOS
//
//  A minimal hierarchical URL model that mirrors the semantics of Android's
//  `android.net.Uri` as used by the upstream Untracker app, so that the very
//  same JavaScript rules produce the very same output.
//
//  Design notes:
//  * Every component is stored exactly as it appeared in the input string
//    (percent-encoding untouched), so serialising an unmodified URL is a no-op.
//  * Component builders mirror `Uri.Builder`: replacing the query of a URL that
//    has no query and then leaving it empty drops the `?`.
//  * Percent encoding matches `Uri.encode`: ASCII alphanumerics plus
//    `- _ . ! ~ * ' ( )` survive, everything else becomes %XX with upper-case hex.
//

import Foundation

// MARK: - Percent coding

enum PercentCoding {
    static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"):
            return true
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
             UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            return true
        default:
            return false
        }
    }

    /// Equivalent of `Uri.encode(value)` — encodes everything outside the
    /// unreserved set, UTF-8 bytes as %XX.
    static func encode(_ value: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isAllowed(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Equivalent of `Uri.decode(value)`. Malformed escapes are passed through
    /// unchanged (Android would throw; being lenient is friendlier here).
    static func decode(_ value: String, convertPlus: Bool = false) -> String {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                out.append((high << 4) | low)
                index += 3
                continue
            }
            if convertPlus && byte == UInt8(ascii: "+") {
                out.append(UInt8(ascii: " "))
                index += 1
                continue
            }
            out.append(byte)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Regex helpers

/// Cache of anchored, case-insensitive regular expressions.
///
/// `matches()` in the upstream app uses `Regex.matches()`, which requires the
/// *entire* input to match (it is not a substring search). Android patterns are
/// therefore wrapped in a non-capturing group and anchored here.
final class RegexCache {
    static let shared = RegexCache()

    private var cache: [String: NSRegularExpression?] = [:]
    private let lock = NSLock()

    func regex(anchored pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let cached = cache[pattern] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let anchoredPattern = "^(?:" + pattern + ")$"
        let compiled = try? NSRegularExpression(
            pattern: anchoredPattern,
            options: [.caseInsensitive]
        )

        lock.lock()
        cache[pattern] = compiled
        lock.unlock()
        return compiled
    }

    /// Full-string, case-insensitive match — `Regex(pattern, IGNORE_CASE).matches(string)`.
    func fullMatch(_ pattern: String, _ string: String) -> Bool {
        guard let regex = regex(anchored: pattern) else { return false }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
}

// MARK: - URL model

struct UntrackURL: Equatable {
    var scheme: String
    var userInfo: String?
    var host: String
    var port: String?
    /// Raw path, e.g. "/foo/%20bar" — never percent-decoded.
    var rawPath: String
    /// Raw query without the "?".
    var rawQuery: String?
    /// Raw fragment without the "#".
    var rawFragment: String?

    init?(string: String) {
        guard let colonIndex = string.firstIndex(of: ":") else { return nil }
        let scheme = String(string[string.startIndex..<colonIndex])
        guard Self.isValidScheme(scheme) else { return nil }

        let afterScheme = string[string.index(after: colonIndex)...]
        guard afterScheme.hasPrefix("//") else {
            // Opaque URI (mailto:, tel:, data:) — nothing to untrack.
            return nil
        }
        let rest = afterScheme.dropFirst(2)

        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[rest.startIndex..<authorityEnd])
        let tail = String(rest[authorityEnd...])

        var userInfo: String?
        var hostPort = authority
        if let atIndex = authority.lastIndex(of: "@") {
            userInfo = String(authority[authority.startIndex..<atIndex])
            hostPort = String(authority[authority.index(after: atIndex)...])
        }

        var host = hostPort
        var port: String?
        if hostPort.hasPrefix("[") {
            if let closing = hostPort.firstIndex(of: "]") {
                host = String(hostPort[hostPort.startIndex...closing])
                let remainder = hostPort[hostPort.index(after: closing)...]
                if remainder.hasPrefix(":") {
                    port = String(remainder.dropFirst())
                }
            }
        } else if let portColon = hostPort.lastIndex(of: ":") {
            let candidate = String(hostPort[hostPort.index(after: portColon)...])
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isNumber }) {
                host = String(hostPort[hostPort.startIndex..<portColon])
                port = candidate
            }
        }
        guard !host.isEmpty else { return nil }

        var rawPath = ""
        var rawQuery: String?
        var rawFragment: String?
        if !tail.isEmpty {
            var remainder = tail[...]
            if remainder.hasPrefix("/") {
                let pathEnd = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? remainder.endIndex
                rawPath = String(remainder[remainder.startIndex..<pathEnd])
                remainder = remainder[pathEnd...]
            }
            if remainder.hasPrefix("?") {
                remainder = remainder.dropFirst()
                let queryEnd = remainder.firstIndex(of: "#") ?? remainder.endIndex
                rawQuery = String(remainder[remainder.startIndex..<queryEnd])
                remainder = remainder[queryEnd...]
            }
            if remainder.hasPrefix("#") {
                rawFragment = String(remainder.dropFirst())
            }
        }

        self.scheme = scheme
        self.userInfo = userInfo
        self.host = host
        self.port = port
        self.rawPath = rawPath
        self.rawQuery = rawQuery
        self.rawFragment = rawFragment
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else {
            return false
        }
        for scalar in scheme.unicodeScalars {
            let isAlphaNumeric = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            if isAlphaNumeric { continue }
            if scalar == "+" || scalar == "-" || scalar == "." { continue }
            return false
        }
        return true
    }

    /// Serialised form. Round-trips untouched URLs byte for byte.
    var string: String {
        var result = scheme
        result += "://"
        if let userInfo = userInfo {
            result += userInfo
            result += "@"
        }
        result += host
        if let port = port {
            result += ":"
            result += port
        }
        result += rawPath
        if let rawQuery = rawQuery {
            result += "?"
            result += rawQuery
        }
        if let rawFragment = rawFragment {
            result += "#"
            result += rawFragment
        }
        return result
    }

    // MARK: Component setters (Uri.Builder equivalents)

    mutating func setEncodedQuery(_ query: String?) {
        rawQuery = query
    }

    mutating func setEncodedPath(_ path: String) {
        rawPath = path.hasPrefix("/") ? path : "/" + path
    }

    mutating func setEncodedFragment(_ fragment: String?) {
        rawFragment = fragment
    }

    mutating func setHost(_ newHost: String) {
        host = PercentCoding.encode(newHost)
    }
}

// MARK: - Query parameters

extension UntrackURL {
    struct RawParameter {
        var rawKey: String
        var rawValue: String
    }

    /// Splits a raw query string the same way the upstream app does: split on
    /// "&", then each part on the first "=".
    static func split(rawQuery query: String) -> [RawParameter] {
        var parameters: [RawParameter] = []
        var start = query.startIndex
        while true {
            let nextAmpersand = query[start...].firstIndex(of: "&")
            let end = nextAmpersand ?? query.endIndex
            let segment = query[start..<end]
            if let equals = segment.firstIndex(of: "=") {
                parameters.append(
                    RawParameter(
                        rawKey: String(segment[segment.startIndex..<equals]),
                        rawValue: String(segment[segment.index(after: equals)...])
                    )
                )
            } else {
                parameters.append(RawParameter(rawKey: String(segment), rawValue: ""))
            }
            guard let ampersand = nextAmpersand else { break }
            start = query.index(after: ampersand)
        }
        return parameters
    }

    /// All query parameters, decoded (no "+" conversion), preserving duplicates.
    var queryParameters: [(key: String, value: String)] {
        guard let rawQuery = rawQuery else { return [] }
        return Self.split(rawQuery: rawQuery).map {
            (
                PercentCoding.decode($0.rawKey),
                PercentCoding.decode($0.rawValue)
            )
        }
    }

    /// `Uri.getQueryParameter(key)` — "+" is decoded as a space.
    func queryParameter(_ key: String) -> String? {
        guard let rawQuery = rawQuery else { return nil }
        for parameter in Self.split(rawQuery: rawQuery) {
            if PercentCoding.decode(parameter.rawKey, convertPlus: true) == key {
                return PercentCoding.decode(parameter.rawValue, convertPlus: true)
            }
        }
        return nil
    }

    /// Shared implementation of `removeQueryParameters` / `retainQueryParameters`.
    /// Parameters are decoded, matched with a full-string case-insensitive regex,
    /// and the surviving ones are re-encoded (so `+` becomes `%2B` and a space
    /// becomes `%20`, exactly like the upstream app).
    func filteringQueryParameters(
        keyPattern: String?,
        valuePattern: String?,
        retain: Bool
    ) -> UntrackURL {
        var result = self
        guard let rawQuery = rawQuery else {
            result.rawQuery = nil
            return result
        }
        var kept: [String] = []
        for parameter in Self.split(rawQuery: rawQuery) {
            let key = PercentCoding.decode(parameter.rawKey)
            let value = PercentCoding.decode(parameter.rawValue)
            let keyMatches = keyPattern.map { RegexCache.shared.fullMatch($0, key) } ?? true
            let valueMatches = valuePattern.map { RegexCache.shared.fullMatch($0, value) } ?? true
            let matches = keyMatches && valueMatches
            // remove: skip when matched; retain: skip when not matched.
            if matches != retain { continue }
            kept.append(PercentCoding.encode(key) + "=" + PercentCoding.encode(value))
        }
        result.rawQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return result
    }
}

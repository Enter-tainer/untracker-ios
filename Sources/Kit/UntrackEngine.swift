//
//  UntrackEngine.swift
//  Untracker for iOS
//
//  Runs the upstream Untracker JavaScript rules in JavaScriptCore. The rules are
//  byte-for-byte the upstream ones; only the `$` built-ins are reimplemented in
//  Swift (see UntrackBuiltins.swift).
//
//  Bridging strategy: a single native function `__untrackNative.call(json)` takes
//  one JSON string and returns one JSON string. Keeping the ABI to
//  `(String) -> String` avoids every JavaScriptCore ↔ Swift conversion subtlety
//  and makes `null` vs `undefined` handling explicit.
//

import Foundation
import JavaScriptCore

final class UntrackEngine {
    static let shared = UntrackEngine()

    /// All JavaScript execution is serialised on this queue; `JSContext` is not
    /// thread-safe.
    private let queue = DispatchQueue(label: "moe.mgt.untracker.engine", qos: .userInitiated)

    private var context: JSContext?
    private var compiledFunctions: [String: JSValue] = [:]
    private var failedScripts: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Applies every enabled rule, in order, to a single URL.
    ///
    /// - Parameters:
    ///   - allowNetwork: when `false`, rules that call `$.fetch` are skipped, so the
    ///     caller gets a result without touching the network. The share extension uses
    ///     this to copy a locally cleaned link first and upgrade it later (TECH-72).
    ///   - deadline: safety valve — rules that keep making progress past
    ///     this many seconds are abandoned (the upstream `Common short links` rule
    ///     performs network requests, so this guards against a slow network).
    func untrack(
        _ url: String,
        rules: [Rule],
        allowNetwork: Bool = true,
        deadline: TimeInterval = 20
    ) -> (url: String, appliedRules: [String]) {
        queue.sync {
            let start = Date()
            var current = url
            var applied: [String] = []
            for rule in rules where rule.enabled {
                if !allowNetwork && rule.requiresNetwork { continue }
                if Date().timeIntervalSince(start) > deadline { break }
                guard let output = apply(script: rule.script, to: current) else { continue }
                if output != current {
                    current = output
                    applied.append(rule.name)
                }
            }
            return (current, applied)
        }
    }

    /// Compile-checks a rule script. Returns a human readable error, or nil when
    /// the script is syntactically valid.
    func validate(script: String) -> String? {
        queue.sync {
            let context = self.jsContext()
            context.exception = nil
            _ = context.evaluateScript("(function(url) {\n" + script + "\n})")
            if let exception = context.exception {
                let message = exception.toString() ?? "Syntax error"
                context.exception = nil
                return message
            }
            return nil
        }
    }

    /// Drops compiled rule functions (used after a rule is edited).
    func reset() {
        queue.sync {
            compiledFunctions.removeAll()
            failedScripts.removeAll()
        }
    }

    // MARK: - Rule evaluation

    private func apply(script: String, to url: String) -> String? {
        if failedScripts.contains(script) { return nil }
        let context = jsContext()

        let function: JSValue
        if let cached = compiledFunctions[script] {
            function = cached
        } else {
            context.exception = nil
            let compiled = context.evaluateScript("(function(url) {\n" + script + "\n})")
            if context.exception != nil || compiled == nil || compiled!.isUndefined {
                context.exception = nil
                failedScripts.insert(script)
                return nil
            }
            compiledFunctions[script] = compiled
            function = compiled!
        }

        context.exception = nil
        let result = function.call(withArguments: [url])
        if context.exception != nil {
            context.exception = nil
            return nil
        }
        guard let result = result, result.isString else { return nil }
        return result.toString()
    }

    // MARK: - JavaScriptCore setup

    private func jsContext() -> JSContext {
        if let context = context { return context }

        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            NSLog("[Untracker] JavaScript exception: %@", exception?.toString() ?? "nil")
        }

        let native = JSValue(newObjectIn: context)!
        let callBlock: @convention(block) (String) -> String = { payload in
            UntrackNativeBridge.handle(callPayload: payload)
        }
        let fetchBlock: @convention(block) (String) -> String = { payload in
            UntrackFetch.handle(argumentsJSON: payload)
        }
        // `unsafeBitCast` to AnyObject is the reliable way to hand a
        // `@convention(block)` closure to JavaScriptCore — plain `Any` boxing can
        // lose the Objective-C block identity.
        native.setObject(unsafeBitCast(callBlock, to: AnyObject.self), forKeyedSubscript: "call" as NSString)
        native.setObject(unsafeBitCast(fetchBlock, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)
        context.setObject(native, forKeyedSubscript: "__untrackNative" as NSString)
        context.evaluateScript(Self.bootstrapScript)

        self.context = context
        return context
    }

    /// Defines the `$` global that every rule script sees.
    private static let bootstrapScript = #"""
    (function () {
        var native = __untrackNative;

        function invoke(op, args) {
            return JSON.parse(native.call(JSON.stringify({ op: op, args: args })));
        }

        var $ = {};
        var operations = [
            'matches',
            'getHost',
            'getEncodedPath',
            'getEncodedQuery',
            'getQueryParameter',
            'getEncodedFragment',
            'setHost',
            'setEncodedPath',
            'setEncodedQuery',
            'setEncodedFragment',
            'removeQueryParameters',
            'retainQueryParameters'
        ];
        operations.forEach(function (op) {
            $[op] = function () {
                return invoke(op, Array.prototype.slice.call(arguments));
            };
        });

        $.fetch = function () {
            var payload = native.fetch(JSON.stringify(Array.prototype.slice.call(arguments)));
            var parsed = JSON.parse(payload);
            if (parsed && parsed.__error) {
                throw new Error(parsed.__error);
            }
            return parsed;
        };

        globalThis.$ = $;
    })();
    """#
}

// MARK: - Native bridge

enum UntrackNativeBridge {
    /// Handles one `__untrackNative.call(json)` invocation.
    ///
    /// `payload` is `{"op": "<name>", "args": [...]}`; the return value is the
    /// JSON encoding of the result (`null` for a nil result, `true`/`false` for
    /// booleans).
    static func handle(callPayload payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = root["op"] as? String else {
            return "null"
        }
        let args = (root["args"] as? [Any]) ?? []

        func stringArgument(_ index: Int) -> String? {
            guard index < args.count else { return nil }
            let value = args[index]
            if value is NSNull { return nil }
            return value as? String
        }

        func parsedURL(_ index: Int) -> UntrackURL? {
            guard let raw = stringArgument(index) else { return nil }
            return UntrackURL(string: raw)
        }

        switch op {
        case "matches":
            guard let url = parsedURL(0) else { return "false" }
            let matched = UntrackBuiltins.matches(
                url,
                hostPattern: stringArgument(1),
                pathPattern: stringArgument(2),
                queryPattern: stringArgument(3),
                fragmentPattern: stringArgument(4)
            )
            return matched ? "true" : "false"

        case "getHost":
            return quote(parsedURL(0)?.host)

        case "getEncodedPath":
            return quote(parsedURL(0)?.rawPath)

        case "getEncodedQuery":
            return quote(parsedURL(0)?.rawQuery)

        case "getEncodedFragment":
            return quote(parsedURL(0)?.rawFragment)

        case "getQueryParameter":
            guard let url = parsedURL(0), let key = stringArgument(1) else { return "null" }
            return quote(url.queryParameter(key))

        case "setHost":
            guard var url = parsedURL(0), let host = stringArgument(1) else { return "null" }
            url.setHost(host)
            return quote(url.string)

        case "setEncodedPath":
            guard var url = parsedURL(0), let path = stringArgument(1) else { return "null" }
            url.setEncodedPath(path)
            return quote(url.string)

        case "setEncodedQuery":
            guard var url = parsedURL(0) else { return "null" }
            // A missing second argument (or an explicit null) clears the query.
            url.setEncodedQuery(stringArgument(1))
            return quote(url.string)

        case "setEncodedFragment":
            guard var url = parsedURL(0) else { return "null" }
            url.setEncodedFragment(stringArgument(1))
            return quote(url.string)

        case "removeQueryParameters":
            guard let url = parsedURL(0) else { return "null" }
            let result = UntrackBuiltins.removeQueryParameters(
                url,
                keyPattern: stringArgument(1),
                valuePattern: stringArgument(2)
            )
            return quote(result.string)

        case "retainQueryParameters":
            guard let url = parsedURL(0) else { return "null" }
            let result = UntrackBuiltins.retainQueryParameters(
                url,
                keyPattern: stringArgument(1),
                valuePattern: stringArgument(2)
            )
            return quote(result.string)

        default:
            return "null"
        }
    }

    /// Minimal JSON string encoder (JSONSerialization cannot serialise a bare
    /// top-level string, and the payloads here are tiny).
    static func quote(_ value: String?) -> String {
        guard let value = value else { return "null" }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

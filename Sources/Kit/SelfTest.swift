//
//  SelfTest.swift
//  Untracker for iOS
//
//  On-device verification harness. The device build cannot be debugged
//  (`get-task-allow` is false with our Ad Hoc profile), so instead the app can run
//  this suite and write a JSON report that is pulled off the device with
//  `xcrun devicectl device copy from`.
//
//  Triggered by `untracker://selftest` or from the About screen.
//

import Foundation

enum SelfTest {
    struct Case: Codable {
        var name: String
        var input: String
        var expected: String
        var note: String?
        var ruleIds: [String]?
    }

    /// Runs every bundled case and returns a JSON-serialisable report.
    static func run(rules: [Rule]? = nil, bundle: Bundle = .main) -> [String: Any] {
        let allRules = rules ?? RuleStore.shared.allRules
        var report: [String: Any] = [:]
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        report["environment"] = environment(ruleCount: allRules.count)
        report["engineProbe"] = engineProbe()

        guard let url = bundle.url(forResource: "SelfTestCases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            report["error"] = "SelfTestCases.json missing from bundle"
            return report
        }

        var failures: [[String: Any]] = []
        var passed = 0

        for (index, testCase) in cases.enumerated() {
            NSLog("[Untracker] self test: case %d/%d %@", index + 1, cases.count, testCase.name)
            // `ruleIds` means "run ONLY these rules", and it force-enables rules that
            // upstream ships disabled (Bilibili BV, Old Reddit) so that their behaviour
            // can still be pinned down by the suite.
            let selectedRules: [Rule]
            if let ids = testCase.ruleIds, !ids.isEmpty {
                selectedRules = allRules
                    .filter { rule in ids.contains(rule.id) || ids.contains(rule.name) }
                    .map { rule in
                        var rule = rule
                        rule.enabled = true
                        return rule
                    }
                if selectedRules.isEmpty {
                    NSLog("[Untracker] self test: %@ matched no rule for %@", testCase.name, ids.joined(separator: ","))
                }
            } else {
                selectedRules = allRules
            }
            let result = UntrackService.untrack(text: testCase.input, rules: selectedRules)
            if result.output == testCase.expected {
                passed += 1
            } else {
                var failure: [String: Any] = [
                    "name": testCase.name,
                    "input": testCase.input,
                    "expected": testCase.expected,
                    "actual": result.output
                ]
                if let note = testCase.note { failure["note"] = note }
                failures.append(failure)
            }
        }

        report["total"] = cases.count
        report["passed"] = passed
        report["failed"] = failures.count
        report["failures"] = failures
        return report
    }

    /// Runs the suite, writes the report to every reachable container and logs a summary.
    @discardableResult
    static func runAndWriteReport() -> [String: Any] {
        NSLog("[Untracker] self test: begin (bundle=%@)", Bundle.main.bundleIdentifier ?? "?")
        write(["stage": "started", "timestamp": ISO8601DateFormatter().string(from: Date())],
              fileName: "selftest-started.json")

        let report = run()
        NSLog("[Untracker] self test: run() returned")

        write(report, fileName: "selftest-result.json")

        // Link-detection spans, for `tools/rules/verify-findurls.mjs`.
        let findURLsCases = findURLsReport()
        if !findURLsCases.isEmpty {
            write(["cases": findURLsCases], fileName: "findurls-actual.json")
            let spanCount = findURLsCases.reduce(0) { total, item in
                total + ((item["spans"] as? [[String: Any]])?.count ?? 0)
            }
            NSLog("[Untracker] findURLs probe: %d cases, %d spans", findURLsCases.count, spanCount)
        }

        let total = report["total"] as? Int ?? 0
        let passed = report["passed"] as? Int ?? 0
        let failed = report["failed"] as? Int ?? 0
        NSLog("[Untracker] Self test: %d/%d passed, %d failed", passed, total, failed)
        return report
    }

    /// Writes a JSON document into every container the process can reach.
    private static func write(_ report: [String: Any], fileName: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            NSLog("[Untracker] self test: could not encode report")
            return
        }
        for directory in outputDirectories() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            do {
                try data.write(to: url, options: .atomic)
                NSLog("[Untracker] self test: wrote %@", url.path)
            } catch {
                NSLog("[Untracker] self test: write failed %@ (%@)", url.path, error.localizedDescription)
            }
        }
    }

    /// Dumps the link spans this implementation finds for the golden corpus, so the
    /// result can be diffed against `tools/rules/verify-findurls.mjs` (which was
    /// produced by running the real androidx matcher on a JVM).
    ///
    /// Output shape is `{ "cases": [ {name, input, spans:[{location, length,
    /// hasScheme, url, match}]} ] }`; offsets are UTF-16 code units, i.e. the same
    /// units Java's `Matcher.start/end` and `NSRange` use.
    static func findURLsReport(bundle: Bundle = .main) -> [[String: Any]] {
        guard let url = bundle.url(forResource: "FindURLsCases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let cases: [[String: Any]]
        if let array = root as? [[String: Any]] {
            cases = array
        } else if let dictionary = root as? [String: Any],
                  let array = dictionary["cases"] as? [[String: Any]] {
            cases = array
        } else {
            return []
        }

        return cases.map { testCase in
            let name = testCase["name"] as? String ?? ""
            let input = testCase["input"] as? String ?? ""
            let spans: [[String: Any]] = UntrackService.findURLs(in: input).map { found in
                [
                    "location": found.range.location,
                    "length": found.range.length,
                    "hasScheme": found.hasScheme,
                    "url": found.processingURL,
                    "match": found.original
                ]
            }
            return ["name": name, "input": input, "spans": spans]
        }
    }

    static func outputDirectories() -> [URL] {
        var directories: [URL] = []
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            directories.append(documents)
        }
        if let group = SharedStore.appGroupContainerURL {
            directories.append(group)
        }
        if let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directories.append(caches)
        }
        return directories
    }

    static func outputPaths() -> [URL] {
        outputDirectories().map { $0.appendingPathComponent("selftest-result.json") }
    }

    // MARK: Diagnostics

    static func environment(ruleCount: Int) -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "?",
            "appVersion": "\(version) (\(build))",
            "ruleCount": ruleCount,
            "sharedStore": SharedStore.diagnostics()
        ]
    }

    /// End-to-end probe of JavaScriptCore + the `$` built-ins + the URL model.
    static func engineProbe() -> [String: Any] {
        let rules = [
            Rule(
                name: "probe",
                description: "self test probe",
                script: "return $.removeQueryParameters(url, 'utm_.*');"
            )
        ]
        let input = "https://example.com/path?a=1&utm_source=test&b=2"
        let expected = "https://example.com/path?a=1&b=2"
        let output = UntrackEngine.shared.untrack(input, rules: rules).url
        let joiner = UntrackEngine.shared.untrack(
            "https://example.com/x?a=1&utm_source=test&b=2",
            rules: [Rule(name: "probe2", description: "", script: "return url + '&' + $.getQueryParameter(url, 'a');")]
        ).url
        return [
            "input": input,
            "expected": expected,
            "actual": output,
            "ok": output == expected,
            "joinProbe": joiner,
            "autolinkRegexCompiled": AutolinkWebURL.regex != nil,
            "scriptValidation": UntrackEngine.shared.validate(script: "return url;") as Any
        ]
    }
}

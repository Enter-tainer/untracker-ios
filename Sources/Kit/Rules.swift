//
//  Rules.swift
//  Untracker for iOS
//
//  Rule model, persistence and the rule store.
//
//  Storage: the app and the Share Extension are separate processes, so the rule
//  state has to be shared. Preferred channel is the App Group container (the
//  signing profile we use carries app-group entitlements); if the container is
//  unavailable the state is mirrored into a shared Keychain access group, and as
//  a last resort each process falls back to its own storage.
//

import Foundation

// MARK: - Model

struct Rule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var script: String
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String = "", description: String = "", script: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.script = script
        self.enabled = enabled
    }
}

/// Persisted form of the rule state: which built-in rules are enabled, plus the
/// user's own rules. Built-in rule *content* always comes from the app bundle so
/// that it can be updated by shipping a new build.
struct RuleState: Codable {
    var builtinEnabled: [String: Bool]
    var customRules: [Rule]

    init(builtinEnabled: [String: Bool] = [:], customRules: [Rule] = []) {
        self.builtinEnabled = builtinEnabled
        self.customRules = customRules
    }
}

// MARK: - Shared storage

enum SharedStore {
    /// App Group carried by our signing profile.
    static let appGroupIdentifier = "group.a25e582c6c8214ce.1"
    static let stateFileName = "untracker-rule-state.json"

    /// Keychain access group, covered by the `A6XH46TK32.*` wildcard in the profile.
    static let keychainService = "moe.mgt.untracker.rules"
    static let keychainAccessGroup = "A6XH46TK32.untracker"
    static let keychainAccount = "rule-state"

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var appGroupFileURL: URL? {
        appGroupContainerURL?.appendingPathComponent(stateFileName)
    }

    static var hasAppGroup: Bool {
        appGroupContainerURL != nil
    }

    // MARK: Load / save

    static func loadStateData() -> Data? {
        if let url = appGroupFileURL, let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        if let data = keychainRead(), !data.isEmpty {
            return data
        }
        if let data = fallbackDefaultsData() {
            return data
        }
        return nil
    }

    static func saveStateData(_ data: Data) {
        if let url = appGroupFileURL {
            try? data.write(to: url, options: .atomic)
        }
        keychainWrite(data)
        fallbackDefaults()?.set(data, forKey: stateFileName)
    }

    static func clearState() {
        if let url = appGroupFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        keychainDelete()
        fallbackDefaults()?.removeObject(forKey: stateFileName)
    }

    /// `true` when this process really can reach a cross-process channel.
    static var canShareAcrossProcesses: Bool {
        if hasAppGroup { return true }
        // Writing then reading back proves the keychain group is usable.
        let probe = Data("probe".utf8)
        let previous = keychainRead()
        keychainWrite(probe)
        let readable = keychainRead() == probe
        if let previous = previous {
            keychainWrite(previous)
        }
        return readable
    }

    // MARK: Fallbacks

    private static func fallbackDefaults() -> UserDefaults? {
        // Per-process fallback (used on the simulator when no entitlement exists).
        UserDefaults(suiteName: "moe.mgt.untracker.fallback")
    }

    private static func fallbackDefaultsData() -> Data? {
        fallbackDefaults()?.data(forKey: stateFileName)
    }

    // MARK: Keychain

    private static func keychainQuery(includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        if includeAccessGroup {
            query[kSecAttrAccessGroup as String] = keychainAccessGroup
        }
        return query
    }

    private static func keychainRead() -> Data? {
        for includeGroup in [true, false] {
            var query = keychainQuery(includeAccessGroup: includeGroup)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
        }
        return nil
    }

    private static func keychainWrite(_ data: Data) {
        for includeGroup in [true, false] {
            keychainDelete(includeAccessGroup: includeGroup)
            var attributes = keychainQuery(includeAccessGroup: includeGroup)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess { return }
        }
    }

    private static func keychainDelete() {
        keychainDelete(includeAccessGroup: true)
        keychainDelete(includeAccessGroup: false)
    }

    private static func keychainDelete(includeAccessGroup: Bool) {
        let query = keychainQuery(includeAccessGroup: includeAccessGroup)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Diagnostics

    static func diagnostics() -> [String: Any] {
        [
            "appGroupIdentifier": appGroupIdentifier,
            "appGroupContainer": appGroupContainerURL?.path ?? "unavailable",
            "keychainReadable": keychainRead() != nil,
            "stateFileExists": appGroupFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        ]
    }
}

// MARK: - Built-in rules

enum BuiltinRules {
    /// Loaded from `BuiltinRules.json`, which is generated verbatim from
    /// upstream `BuiltinRuleList.kt`.
    static func load(bundle: Bundle = .main) -> [Rule] {
        guard let url = bundle.url(forResource: "BuiltinRules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            NSLog("[Untracker] BuiltinRules.json missing or invalid")
            return []
        }
        return rules
    }
}

// MARK: - Store

final class RuleStore: ObservableObject {
    static let shared = RuleStore()

    @Published private(set) var builtinRules: [Rule] = []
    @Published private(set) var customRules: [Rule] = []

    private var builtinEnabled: [String: Bool] = [:]
    private let bundle: Bundle

    private init() {
        self.bundle = .main
        reload()
    }

    var allRules: [Rule] {
        builtinRules + customRules
    }

    var enabledRules: [Rule] {
        allRules.filter { $0.enabled }
    }

    var enabledCount: Int {
        allRules.filter { $0.enabled }.count
    }

    // MARK: Loading

    func reload() {
        let bundled = BuiltinRules.load(bundle: bundle)
        let state = loadState()
        builtinEnabled = state?.builtinEnabled ?? [:]
        customRules = state?.customRules ?? []
        builtinRules = bundled.map { rule in
            var rule = rule
            if let enabled = builtinEnabled[rule.id] {
                rule.enabled = enabled
            }
            return rule
        }
        objectWillChange.send()
    }

    private func loadState() -> RuleState? {
        if let data = SharedStore.loadStateData(),
           let state = try? JSONDecoder().decode(RuleState.self, from: data) {
            return state
        }
        return nil
    }

    // MARK: Mutating

    func setEnabled(_ enabled: Bool, for ruleID: String) {
        if let index = builtinRules.firstIndex(where: { $0.id == ruleID }) {
            builtinRules[index].enabled = enabled
            builtinEnabled[ruleID] = enabled
        } else if let index = customRules.firstIndex(where: { $0.id == ruleID }) {
            customRules[index].enabled = enabled
        } else {
            return
        }
        persist()
    }

    func add(_ rule: Rule) {
        customRules.append(rule)
        persist()
    }

    func update(_ rule: Rule) {
        if let index = customRules.firstIndex(where: { $0.id == rule.id }) {
            customRules[index] = rule
            persist()
        } else if let index = builtinRules.firstIndex(where: { $0.id == rule.id }) {
            // Built-in rule content is owned by the bundle; only enablement is mutable.
            builtinRules[index].enabled = rule.enabled
            builtinEnabled[rule.id] = rule.enabled
            persist()
        }
    }

    func delete(ruleID: String) {
        customRules.removeAll { $0.id == ruleID }
        persist()
    }

    /// Re-enables every built-in rule and drops stored overrides.
    func resetBuiltinRules() {
        builtinEnabled = [:]
        let bundled = BuiltinRules.load(bundle: bundle)
        builtinRules = bundled
        persist()
    }

    /// Restores the shipped default state (built-in rules on, custom rules gone).
    func restoreDefaults() {
        builtinEnabled = [:]
        customRules = []
        builtinRules = BuiltinRules.load(bundle: bundle)
        SharedStore.clearState()
        persist()
    }

    func duplicateAsCustom(_ rule: Rule) -> Rule {
        var copy = rule
        copy.id = UUID().uuidString
        copy.name = rule.name + " (copy)"
        return copy
    }

    private func persist() {
        let state = RuleState(builtinEnabled: builtinEnabled, customRules: customRules)
        guard let data = try? JSONEncoder().encode(state) else { return }
        SharedStore.saveStateData(data)
    }
}

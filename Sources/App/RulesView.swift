//
//  RulesView.swift
//  Untracker for iOS
//
//  Rule management: enable/disable, inspect built-in rules, add and edit custom
//  JavaScript rules.
//

import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var store: RuleStore
    @State private var editingRule: Rule?
    @State private var showingAddRule = false
    @State private var showingResetConfirmation = false
    @State private var showingRestoreConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.builtinRules) { rule in
                        NavigationLink(value: rule) {
                            RuleRow(rule: rule, isBuiltin: true)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                if let index = store.builtinRules.firstIndex(where: { $0.id == rule.id }) {
                                    store.setEnabled(!store.builtinRules[index].enabled, for: rule.id)
                                }
                            } label: {
                                Label(rule.enabled ? "Disable" : "Enable", systemImage: rule.enabled ? "minus.circle" : "checkmark.circle")
                            }
                            .tint(rule.enabled ? .orange : .green)
                        }
                    }
                } header: {
                    Text("Built-in")
                } footer: {
                    Text("Shipped with the app, generated from upstream Untracker. Scripts are read-only; duplicate one to customise it.")
                }

                Section {
                    if store.customRules.isEmpty {
                        Text("No custom rules yet. Add one with “+”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.customRules) { rule in
                            NavigationLink(value: rule) {
                                RuleRow(rule: rule, isBuiltin: false)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(ruleID: rule.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Custom rules are appended after the built-in ones. A rule returns a string to replace the URL, or nothing to leave it unchanged.")
                }
            }
            .navigationTitle("Rules")
            .navigationDestination(for: Rule.self) { rule in
                RuleDetailView(rule: rule, isBuiltin: store.builtinRules.contains(where: { $0.id == rule.id }))
                    .environmentObject(store)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingResetConfirmation = true
                        } label: {
                            Label("Re-enable all built-in rules", systemImage: "arrow.counterclockwise")
                        }
                        Button(role: .destructive) {
                            showingRestoreConfirmation = true
                        } label: {
                            Label("Restore default rules", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingRule = Rule(name: "", description: "", script: defaultScriptTemplate)
                        showingAddRule = true
                    } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddRule) {
                if let rule = editingRule {
                    NavigationStack {
                        RuleEditorView(rule: rule)
                            .environmentObject(store)
                    }
                }
            }
            .confirmationDialog("Re-enable every built-in rule?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button("Re-enable") { store.resetBuiltinRules() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete custom rules and restore defaults?", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
                Button("Restore", role: .destructive) { store.restoreDefaults() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var defaultScriptTemplate: String {
        """
        if ($.matches(url, '(\\w+\\.)?example\\.com')) {
            return $.removeQueryParameters(url, 'utm_.*|fbclid|gclid');
        }
        """
    }
}

// MARK: - Row

private struct RuleRow: View {
    @EnvironmentObject private var store: RuleStore
    let rule: Rule
    let isBuiltin: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.body)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    if !isBuiltin {
                        Text("custom")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.15), in: Capsule())
                            .foregroundStyle(.indigo)
                    }
                }
                if !rule.description.isEmpty {
                    Text(rule.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { store.setEnabled($0, for: rule.id) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail (built-in: read-only)

struct RuleDetailView: View {
    @EnvironmentObject private var store: RuleStore
    @Environment(\.dismiss) private var dismiss

    let rule: Rule
    let isBuiltin: Bool

    @State private var draft: Rule
    @State private var validationMessage: String?
    @State private var validationSucceeded = false
    @State private var showingDuplicateSheet = false

    init(rule: Rule, isBuiltin: Bool) {
        self.rule = rule
        self.isBuiltin = isBuiltin
        _draft = State(initialValue: rule)
    }

    var body: some View {
        Form {
            Section {
                if isBuiltin {
                    LabeledContent("Name", value: rule.name)
                    if !rule.description.isEmpty {
                        LabeledContent("Description", value: rule.description)
                    }
                    Toggle("Enabled", isOn: Binding(
                        get: { draft.enabled },
                        set: { newValue in
                            draft.enabled = newValue
                            store.setEnabled(newValue, for: rule.id)
                        }
                    ))
                } else {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
            }

            Section {
                TextEditor(text: isBuiltin ? .constant(rule.script) : $draft.script)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isBuiltin)
            } header: {
                Text("Script")
            } footer: {
                Text("Available: url, $.matches(url, host, path, query, fragment), $.getHost, $.getEncodedPath, $.getEncodedQuery, $.getQueryParameter, $.setHost, $.setEncodedPath, $.setEncodedQuery, $.removeQueryParameters, $.retainQueryParameters, $.fetch. Return the new URL, or nothing to keep it.")
            }

            Section {
                Button {
                    validate()
                } label: {
                    Label("Check script", systemImage: "checkmark.circle")
                }
                if let message = validationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(validationSucceeded ? .green : .red)
                }
                if isBuiltin {
                    Button {
                        let copy = store.duplicateAsCustom(rule)
                        draft = copy
                        showingDuplicateSheet = true
                    } label: {
                        Label("Duplicate as custom rule", systemImage: "plus.square.on.square")
                    }
                }
            }
        }
        .navigationTitle(isBuiltin ? rule.name : (draft.name.isEmpty ? "New rule" : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isBuiltin {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            saved.name = "Untitled rule"
                        }
                        store.update(saved)
                        UntrackEngine.shared.reset()
                        dismiss()
                    }
                    .disabled(draft.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingDuplicateSheet) {
            NavigationStack {
                RuleEditorView(rule: draft)
                    .environmentObject(store)
            }
        }
    }

    private func validate() {
        let script = isBuiltin ? rule.script : draft.script
        if let error = UntrackEngine.shared.validate(script: script) {
            validationSucceeded = false
            validationMessage = "Syntax error: \(error)"
        } else {
            validationSucceeded = true
            validationMessage = "Script is valid."
        }
    }
}

// MARK: - Editor (custom rules)

struct RuleEditorView: View {
    @EnvironmentObject private var store: RuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Rule
    @State private var validationMessage: String?
    @State private var validationSucceeded = false
    @State private var previewInput = "https://www.example.com/article?utm_source=newsletter&fbclid=abc123&id=42"
    @State private var previewOutput: String?

    init(rule: Rule) {
        _draft = State(initialValue: rule)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.description)
                Toggle("Enabled", isOn: $draft.enabled)
            }

            Section {
                TextEditor(text: $draft.script)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Script")
            } footer: {
                Text("Example: return $.removeQueryParameters(url, 'utm_.*|fbclid');")
            }

            Section {
                Button {
                    validate()
                } label: {
                    Label("Check script", systemImage: "checkmark.circle")
                }
                if let message = validationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(validationSucceeded ? .green : .red)
                }
                Button {
                    runPreview()
                } label: {
                    Label("Preview on a sample link", systemImage: "eye")
                }
                if let output = previewOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input").font(.caption2).foregroundStyle(.secondary)
                        Text(previewInput).font(.system(.caption2, design: .monospaced))
                        Text("Output").font(.caption2).foregroundStyle(.secondary)
                        Text(output).font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "New rule" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        saved.name = "Untitled rule"
                    }
                    let isExisting = store.customRules.contains(where: { $0.id == saved.id })
                    if isExisting {
                        store.update(saved)
                    } else {
                        store.add(saved)
                    }
                    UntrackEngine.shared.reset()
                    dismiss()
                }
                .disabled(draft.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func validate() {
        if let error = UntrackEngine.shared.validate(script: draft.script) {
            validationSucceeded = false
            validationMessage = "Syntax error: \(error)"
        } else {
            validationSucceeded = true
            validationMessage = "Script is valid."
        }
    }

    private func runPreview() {
        let output = UntrackEngine.shared.untrack(previewInput, rules: [draft])
        previewOutput = output.url
    }
}

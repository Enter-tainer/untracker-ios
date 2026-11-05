//
//  AboutView.swift
//  Untracker for iOS
//

import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var store: RuleStore
    @EnvironmentObject private var appState: AppState

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [.indigo, .teal],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Image(systemName: "link.badge.plus")
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(.white)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Untracker")
                                    .font(.title3.weight(.semibold))
                                Text("Version \(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Remove tracking information from links before you share them — on your device, with rules you can read and edit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Status") {
                    LabeledContent("Rules", value: "\(store.enabledCount) of \(store.allRules.count) enabled")
                    LabeledContent("Rule engine", value: "JavaScriptCore")
                    LabeledContent("Shared storage") {
                        Text(SharedStore.canShareAcrossProcesses ? "App Group" : "Local only")
                            .foregroundStyle(SharedStore.canShareAcrossProcesses ? .green : .orange)
                    }
                    if !SharedStore.hasAppGroup {
                        Text("Custom rules may not reach the Share Extension in this build.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        appState.runSelfTest()
                    } label: {
                        Label("Run self test", systemImage: "testtube.2")
                    }
                    .disabled(appState.isRunningSelfTest)
                    if let summary = appState.selfTestSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Runs the bundled rule test cases through the JavaScript engine and writes a JSON report into the app container, so the build can be verified without a debugger.")
                }

                Section("Usage") {
                    Label("Share a link from any app → choose Untracker → Copy.", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                    Label("Paste a link in the Untrack tab to preview what would be removed.", systemImage: "doc.on.clipboard")
                        .font(.footnote)
                }

                Section("Credits") {
                    Link(destination: URL(string: "https://github.com/zhanghai/Untracker")!) {
                        LabeledContent("Upstream Untracker (Android)", value: "zhanghai/Untracker")
                    }
                    Text("Built-in rules are taken verbatim from the upstream project, Copyright 2023 Google LLC, licensed under the Apache License 2.0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Text("Everything runs locally. The only network access is the optional “expand short links” rule, which follows a redirect to reveal the real destination.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }
}

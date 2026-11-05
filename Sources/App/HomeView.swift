//
//  HomeView.swift
//  Untracker for iOS
//
//  Paste (or type) text containing links, see exactly what tracking is removed,
//  then copy / share / open the clean link.
//

import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var store: RuleStore
    @EnvironmentObject private var appState: AppState

    @State private var input = ""
    @State private var result: UntrackResult?
    @State private var isWorking = false
    @State private var untrackTask: Task<Void, Never>?
    @State private var didHandlePendingInput = false
    @State private var copiedFlag = false

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if trimmedInput.isEmpty {
                        welcomeCard
                    }
                    inputCard
                    if isWorking {
                        workingRow
                    }
                    if let result = result, !trimmedInput.isEmpty {
                        resultCard(result)
                    }
                    privacyFootnote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Theme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Untracker")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasStrings)
                }
            }
        }
        .onAppear(perform: handlePendingInput)
        .onChange(of: appState.pendingInput) { _ in handlePendingInput() }
        .onChange(of: input) { _ in scheduleUntrack() }
        .onChange(of: store.enabledCount) { _ in scheduleUntrack(immediately: true) }
    }

    // MARK: - Welcome

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean the link before you share it")
                        .font(.headline)
                    Text("Tracking parameters are removed on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!UIPasteboard.general.hasStrings)
        }
        .cardSurface()
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Link or text", systemImage: "text.cursor")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !input.isEmpty {
                    Button {
                        input = ""
                        result = nil
                        Haptics.tap()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }

            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("https://example.com/article?utm_source=…&fbclid=…")
                        .font(Theme.monospace)
                        .foregroundStyle(.quaternary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .font(Theme.monospace)
                    .frame(minHeight: 84, maxHeight: 170)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .insetSurface()

            HStack(spacing: 10) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!UIPasteboard.general.hasStrings)

                Button {
                    scheduleUntrack(immediately: true)
                } label: {
                    Label("Untrack", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedInput.isEmpty)
            }
            .font(.subheadline.weight(.medium))
        }
        .cardSurface()
    }

    private var workingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Untracking…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Result

    @ViewBuilder
    private func resultCard(_ result: UntrackResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !result.anyURLFound {
                statusHeader(
                    title: "No links found",
                    systemImage: "questionmark.circle",
                    tint: .secondary,
                    detail: "Paste a link, or a message containing one."
                )
            } else if !result.changed {
                statusHeader(
                    title: "Already clean",
                    systemImage: "checkmark.seal.fill",
                    tint: .green,
                    detail: "No tracking parameters were found."
                )
                cleanedBlock(result.output)
                actionRow(result)
            } else {
                statusHeader(
                    title: "Tracking removed",
                    systemImage: "checkmark.seal.fill",
                    tint: .green,
                    detail: result.removedParameters.isEmpty
                        ? "The link was rewritten by a site rule."
                        : "\(result.removedParameters.count) parameter\(result.removedParameters.count == 1 ? "" : "s") removed."
                )
                cleanedBlock(result.output)
                if !result.removedParameters.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(result.removedParameters, id: \.self) { parameter in
                            ParameterChip(name: parameter)
                        }
                    }
                }
                if !result.appliedRuleNames.isEmpty {
                    Label(result.appliedRuleNames.joined(separator: " · "), systemImage: "text.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                actionRow(result)
                originalDisclosure(result)
            }
        }
        .cardSurface()
    }

    private func statusHeader(title: String, systemImage: String, tint: Color, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusPill(title: title, systemImage: systemImage, tint: tint)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func cleanedBlock(_ text: String) -> some View {
        Text(text)
            .font(Theme.monospace)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetSurface()
    }

    private func actionRow(_ result: UntrackResult) -> some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = result.output
                Haptics.success()
                withAnimation { copiedFlag = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation { copiedFlag = false }
                }
            } label: {
                Label(copiedFlag ? "Copied" : "Copy", systemImage: copiedFlag ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            ShareLink(item: result.output) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let url = openableURL(from: result) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    private func originalDisclosure(_ result: UntrackResult) -> some View {
        DisclosureGroup {
            Text(result.input)
                .font(Theme.monospaceSmall)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text("Original")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.caption)
            Text("Rules are JavaScript that runs on this device. Only the “expand short links” rule uses the network, and only to follow a redirect.")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func openableURL(from result: UntrackResult) -> URL? {
        if result.urls.count == 1 {
            let candidate = result.urls[0].untracked
            if let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: { $0 == " " || $0 == "\n" }),
           let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            return url
        }
        return nil
    }

    private func pasteFromClipboard() {
        guard let string = UIPasteboard.general.string, !string.isEmpty else { return }
        input = string
        Haptics.tap()
        scheduleUntrack(immediately: true)
    }

    private func handlePendingInput() {
        guard !didHandlePendingInput, let pending = appState.pendingInput else { return }
        didHandlePendingInput = true
        input = pending
        appState.pendingInput = nil
        scheduleUntrack(immediately: true)
    }

    @MainActor
    private func scheduleUntrack(immediately: Bool = false) {
        untrackTask?.cancel()
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = nil
            isWorking = false
            return
        }
        let rules = store.enabledRules
        isWorking = true
        untrackTask = Task { [text, rules] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            if Task.isCancelled { return }
            let computed = await Task.detached(priority: .userInitiated) {
                UntrackService.untrack(text: text, rules: rules)
            }.value
            if Task.isCancelled { return }
            result = computed
            isWorking = false
        }
    }
}

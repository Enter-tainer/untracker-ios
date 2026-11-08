//
//  UntrackExtensionRootView.swift
//  ExtensionKit
//
//  The review panel, in SwiftUI: a header with the app mark, the cleaned link in a
//  rounded block, the parameters that were removed, and one clear primary action.
//
//  Only the Share Extension (share sheet app row) shows this. The Action Extension's
//  bottom quick action copies silently and dismisses itself, so it has no UI at all.
//

import SwiftUI

struct UntrackExtensionRootView: View {
    @ObservedObject var model: UntrackExtensionViewModel
    let onCopy: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            // The host decides the sheet height (iOS presents extension sheets large and
            // ignores preferredContentSize), so keep the result near the header and pin the
            // actions to the bottom.
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.indigo, .teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                )

            Text("Untracker")
                .font(.headline)

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cancelButton")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Removing tracking parameters…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .empty(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .cleaned:
            VStack(alignment: .leading, spacing: 10) {
                statusPill(
                    title: "Tracking removed",
                    systemImage: "checkmark.seal.fill",
                    tint: .green
                )

                Text(model.cleanedText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("cleanedURL")
                .padding(12)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

                if !model.removedParameters.isEmpty {
                    Text("Removed: " + model.removedParameters.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("removedParameters")
                }
                if !model.appliedRules.isEmpty {
                    Text("Rules: " + model.appliedRules.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if model.originalText != model.cleanedText, !model.originalText.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Original")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(model.originalText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("originalLink")
                    }
                    .padding(.top, 2)
                }
            }

        case .unchanged:
            VStack(alignment: .leading, spacing: 10) {
                statusPill(title: "Already clean", systemImage: "checkmark.circle", tint: .secondary)
                Text(model.cleanedText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .accessibilityIdentifier("cleanedURL")
            }
        }
    }

    private func statusPill(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityIdentifier("statusLabel")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.hasResult)
            .accessibilityIdentifier("shareButton")

            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.hasResult)
            .accessibilityIdentifier("copyButton")
        }
        .font(.body.weight(.medium))
    }
}

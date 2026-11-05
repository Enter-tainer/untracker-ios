//
//  Theme.swift
//  Untracker for iOS
//
//  Small design system so the screens look like a regular iOS app: grouped
//  background, rounded "card" surfaces, status pills and one accent gradient.
//

import SwiftUI
import UIKit

enum Theme {
    static let cardRadius: CGFloat = 20
    static let innerRadius: CGFloat = 14

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let insetBackground = Color(uiColor: .tertiarySystemGroupedBackground)

    static let accent = Color.indigo
    static let accentGradient = LinearGradient(
        colors: [Color.indigo, Color.teal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let monospace = Font.system(.body, design: .monospaced)
    static let monospaceSmall = Font.system(.footnote, design: .monospaced)
}

extension View {
    /// Rounded card used for every grouped block on a page.
    func cardSurface(padding: CGFloat = 16, radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .padding(padding)
            .background(
                Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }

    /// Inset field used inside cards.
    func insetSurface(padding: CGFloat = 12, radius: CGFloat = Theme.innerRadius) -> some View {
        self
            .padding(padding)
            .background(
                Theme.insetBackground,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
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
    }
}

// MARK: - Wrapping chips

/// Flow layout so removed-parameter chips wrap onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Removed query-parameter chip.
struct ParameterChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.12), in: Capsule())
            .foregroundStyle(.red)
    }
}

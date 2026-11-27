import AppKit
import ArinCore
import SwiftUI

enum Theme {
    /// Arin's signature color: a deep teal, a little brighter in dark mode, still dark enough for white text.
    static let signature = Color(nsColor: NSColor(name: "ArinSignature") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.10, green: 0.56, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.00, green: 0.47, blue: 0.49, alpha: 1)
    })

    /// Disk space that isn't one of Arin's findings.
    static let usedSpace = Color.primary.opacity(0.28)

    /// The soft wash behind hero areas.
    static var heroWash: LinearGradient {
        LinearGradient(
            colors: [signature.opacity(0.20), signature.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension CleanupCategory {
    /// Each category keeps one color everywhere. Green, orange and red are reserved for risk.
    var color: Color {
        switch self {
        case .devCaches: .purple
        case .xcode: .blue
        case .temp: .mint
        case .toolVersions: .indigo
        case .projects: .cyan
        case .worktrees: .brown
        case .containers: .pink
        case .appCaches: .yellow.mix(with: .brown, by: 0.35)
        case .agentData: .teal
        case .unclassified: .gray
        }
    }
}

extension Int64 {
    /// "38.2 GB" split into its number and unit, for large numbers with small units.
    var byteParts: (number: String, unit: String) {
        let text = formattedBytes
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

/// A size as a large number with a small unit.
struct SizeText: View {
    var bytes: Int64
    var size: CGFloat = 34
    var weight: Font.Weight = .semibold

    var body: some View {
        let parts = bytes.byteParts
        HStack(alignment: .firstTextBaseline, spacing: size * 0.12) {
            Text(parts.number)
                .font(.system(size: size, weight: weight, design: .rounded))
                .contentTransition(.numericText(value: Double(bytes)))
            Text(parts.unit)
                .font(.system(size: max(size * 0.42, 11), weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .animation(.smooth, value: bytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bytes.formattedBytes)
    }
}

/// A horizontal bar split into colored segments; whatever is left of `total` shows as the empty track.
struct SpaceBar: View {
    struct Segment: Identifiable {
        var id: String
        var bytes: Int64
        var color: Color
    }

    var total: Int64
    var segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let widths = layout(width: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(Array(zip(segments, widths)), id: \.0.id) { segment, width in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: width)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(Capsule())
            .animation(.smooth, value: widths)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Clamps segments to the total; small but non-zero segments stay visible.
    private func layout(width: CGFloat) -> [CGFloat] {
        guard total > 0 else { return segments.map { _ in 0 } }
        var remaining = total
        return segments.map { segment in
            let bytes = Swift.min(Swift.max(segment.bytes, 0), remaining)
            remaining -= bytes
            guard bytes > 0 else { return 0 }
            return Swift.max(width * CGFloat(bytes) / CGFloat(total), 2)
        }
    }
}

/// A colored rounded square holding a category's symbol.
struct CategoryIcon: View {
    var category: CleanupCategory
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(category.color)
            .frame(width: size, height: size)
            .background(category.color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small uppercase label with an icon, used at the top of cards.
struct CardLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        Label(title.uppercased(), systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A rounded panel for card layouts.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary.opacity(0.6)))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardBackground(padding: padding)) }
}

/// A small capsule of secondary text, like a tag.
struct Chip: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

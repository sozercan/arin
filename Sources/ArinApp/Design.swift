import AppKit
import SwiftUI

private struct CardStyle: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.8), lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

struct SolidButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(Color.primary.opacity(configuration.isPressed ? 0.7 : 0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == SolidButtonStyle {
    static var solid: SolidButtonStyle { SolidButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

struct StatusPill: View {
    var text: String
    var symbol: String?
    var tint: Color
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            } else if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1).truncationMode(.middle).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct StatTile: Identifiable {
    var label: String
    var value: String
    var tint: Color?

    var id: String { label }
}

struct StatRow: View {
    var tiles: [StatTile]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                if index > 0 {
                    Divider().padding(.horizontal, 14)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(tile.value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tile.tint ?? .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct Segment: Identifiable {
    var label: String
    var bytes: Int64
    var color: Color

    var id: String { label }
}

struct SplitBar: View {
    var segments: [Segment]

    var body: some View {
        let shown = segments.filter { $0.bytes > 0 }
        let total = max(shown.reduce(0) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let room = geo.size.width - CGFloat(max(shown.count - 1, 0)) * 4
                HStack(spacing: 4) {
                    if shown.isEmpty {
                        Capsule().fill(.quaternary)
                    }
                    ForEach(shown) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: max(4, room * CGFloat(segment.bytes) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    LegendDot(color: segment.color, text: "\(segment.label) \(segment.bytes > 0 ? segment.bytes.formattedBytes : "–")")
                }
            }
        }
    }
}

struct LegendDot: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text).lineLimit(1).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct Hatch: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

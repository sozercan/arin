import ArinCore
import SwiftUI

struct DiskGauge: View {
    var disk: DiskStatus
    var threshold: Int64
    var compact = false

    private var tint: Color {
        if disk.freeBytes < threshold { return .red }
        if disk.usedFraction > 0.85 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(disk.freeBytes.formattedBytes)
                    .font(compact ? .headline : .title2.weight(.semibold))
                    .monospacedDigit()
                Text("free")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((disk.usedFraction * 100).rounded()))% used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: disk.usedFraction)
                .tint(tint)
            Text("of \(disk.totalBytes.formattedBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RiskBadge: View {
    var risk: Risk
    var fromAgent: Bool

    var color: Color {
        switch risk {
        case .safe: .green
        case .review: .orange
        case .keep: .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if fromAgent { Image(systemName: "sparkles").imageScale(.small) }
            Text(risk.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .help(fromAgent ? "Includes your agent's verdict" : "Rule verdict")
    }
}

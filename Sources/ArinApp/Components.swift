import ArinCore
import SwiftUI

/// Free space as a large number over a bar of the whole disk. With findings, the bar shows them by category.
struct DiskGauge: View {
    var disk: DiskStatus
    var threshold: Int64
    var findings: [(category: CleanupCategory, bytes: Int64)] = []
    var compact = false

    private var isLow: Bool { disk.freeBytes < threshold }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                SizeText(bytes: disk.freeBytes, size: compact ? 22 : 26)
                Text("free")
                    .foregroundStyle(.secondary)
                Spacer()
                if isLow {
                    Chip(text: "Low", color: .red)
                }
            }
            SpaceBar(total: disk.totalBytes, segments: segments, height: compact ? 8 : 10)
            Text("\(Int((disk.usedFraction * 100).rounded()))% used of \(disk.totalBytes.formattedBytes)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(disk.freeBytes.formattedBytes) free of \(disk.totalBytes.formattedBytes)\(isLow ? ", below your alert threshold" : "")")
    }

    private var segments: [SpaceBar.Segment] {
        let used = disk.totalBytes - disk.freeBytes
        let found = min(findings.reduce(0) { $0 + $1.bytes }, used)
        let other = SpaceBar.Segment(id: "used", bytes: used - found, color: isLow ? .red.opacity(0.55) : Theme.usedSpace)
        return [other] + findings.map { SpaceBar.Segment(id: $0.category.rawValue, bytes: $0.bytes, color: $0.category.color) }
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

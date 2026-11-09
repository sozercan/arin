import ArinCore
import Charts
import SwiftUI

/// What grew back since the previous scan, free space over time, and past cleanups with Put Back.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanups = model.cleanupRecords.reversed()
        List {
            Section("Since the previous scan") {
                if let growth = model.growthSinceLastScan {
                    if growth.items.isEmpty {
                        Text("Nothing grew by more than 256 MB since \(growth.since.formatted(.relative(presentation: .named))).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(growth.items.prefix(12), id: \.ruleID) { item in
                        HStack {
                            Text(item.label)
                            Spacer()
                            Text("+\(item.bytes.formattedBytes)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Scan again later to see what grows back between scans.")
                        .foregroundStyle(.secondary)
                }
            }

            if model.scanRecords.count >= 2 {
                Section("Free space at each scan") {
                    FreeSpaceChart(scans: Array(model.scanRecords.suffix(60)))
                        .frame(height: 160)
                        .padding(.vertical, 6)
                }
            }

            Section("Cleanups") {
                if cleanups.isEmpty {
                    Text("No cleanups yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(cleanups.enumerated()), id: \.offset) { _, record in
                    CleanupRecordRow(record: record)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("History")
    }
}

private struct FreeSpaceChart: View {
    var scans: [ScanRecord]
    @State private var hovered: Date?

    private var nearest: ScanRecord? {
        guard let hovered else { return nil }
        return scans.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    var body: some View {
        Chart {
            ForEach(scans, id: \.date) { scan in
                LineMark(x: .value("Scanned", scan.date), y: .value("Free", Double(scan.freeBytes) / 1e9))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Scanned", scan.date), y: .value("Free", Double(scan.freeBytes) / 1e9))
                    .symbolSize(30)
            }
            if let nearest {
                RuleMark(x: .value("Scanned", nearest.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("Scanned", nearest.date), y: .value("Free", Double(nearest.freeBytes) / 1e9))
                    .symbolSize(64)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(nearest.freeBytes.formattedBytes).font(.caption.weight(.semibold)).monospacedDigit()
                            Text(nearest.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartYAxisLabel("GB free")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartXSelection(value: $hovered)
        .accessibilityLabel("Free space at each scan")
    }
}

private struct CleanupRecordRow: View {
    @Environment(AppModel.self) private var model
    var record: CleanupRecord

    var body: some View {
        let cleaned = record.items.filter { $0.status == .cleaned }
        DisclosureGroup {
            ForEach(record.items) { item in
                HStack(alignment: .top) {
                    Image(systemName: item.status == .cleaned ? "checkmark.circle" : item.status == .failed ? "xmark.octagon" : "minus.circle")
                        .foregroundStyle(item.status == .cleaned ? .green : item.status == .failed ? .red : .secondary)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let trashed = item.trashedPaths, trashed.contains(where: \.canPutBack) {
                        Button("Put Back") {
                            for path in trashed where path.canPutBack { model.putBack(path) }
                        }
                        .help("Move it from the Trash back to where it was")
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    Text("\(cleaned.count) of \(record.items.count) items\(record.auto ? " · Auto mode" : "") · folder sizes \(record.estimatedBytes.formattedBytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.measuredBytes > 0 ? "Freed \(record.measuredBytes.formattedBytes)" : "No measured gain")
                    .monospacedDigit()
            }
        }
    }
}

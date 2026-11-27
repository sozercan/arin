import ArinCore
import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanups = Array(model.cleanupRecords.reversed())
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What grows back").font(.headline)
                    if model.scanRecords.count >= 2 {
                        let strata = Strata(scans: Array(model.scanRecords.suffix(60)), cleanups: model.cleanupRecords)
                        StrataChart(strata: strata)
                            .frame(height: 220)
                            .padding(.vertical, 6)
                        RegrowthRows(strata: strata)
                    } else {
                        Text("Scan again later to see what grows back between scans.")
                            .foregroundStyle(.secondary)
                    }
                }
                .card()
                if model.scanRecords.count >= 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Free space at each scan").font(.headline)
                        FreeSpaceChart(scans: Array(model.scanRecords.suffix(60)))
                            .frame(height: 160)
                            .padding(.vertical, 6)
                    }
                    .card()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cleanups").font(.headline)
                    if cleanups.isEmpty {
                        Text("No cleanups yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(cleanups.enumerated()), id: \.offset) { index, record in
                        if index > 0 { Divider() }
                        CleanupRecordRow(record: record)
                    }
                }
                .card()
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
                    Image(systemName: item.status.symbol)
                        .foregroundStyle(item.status.color)
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
                    Text("\(record.remoteHost.map { "\($0) · " } ?? "")\(record.uninstalled.map { "Uninstall of \($0) · " } ?? "")\(cleaned.count) of \(record.items.count) items\(record.auto ? " · Auto mode" : "") · folder sizes \(record.estimatedBytes.formattedBytes)")
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

struct Strata {
    struct Point: Identifiable {
        var date: Date
        var series: String
        var bytes: Int64
        var id: String { "\(series)|\(date.timeIntervalSince1970)" }
    }

    struct Cut: Identifiable {
        var date: Date
        var bytes: Int64
        var items: Int
        var uninstalled: String?
        var removedApp = false
        var id: Date { date }
    }

    struct Regrowth: Identifiable {
        var ruleID: String
        var label: String
        var bytes: Int64
        var perWeek: Int64
        var id: String { ruleID }
    }

    static let otherSeries = "Everything else"

    var points: [Point] = []
    var series: [String] = []
    var cuts: [Cut] = []
    var regrowth: [Regrowth] = []
    var since: Date?

    init(scans: [ScanRecord], cleanups: [CleanupRecord], minimum: Int64 = 256 * 1024 * 1024) {
        guard let first = scans.first, let latest = scans.last else { return }
        var peaks: [String: Int64] = [:]
        var labels: [String: String] = [:]
        for scan in scans {
            for (rule, bytes) in scan.bytesByRule where bytes > 0 {
                peaks[rule] = max(peaks[rule] ?? 0, bytes)
                labels[rule] = scan.labels[rule] ?? labels[rule]
            }
        }
        let top = peaks.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        var names: [String: String] = [:]
        for rule in top {
            let label = labels[rule] ?? rule
            names[rule] = names.values.contains(label) ? "\(label) (\(rule))" : label
        }
        let hasOther = scans.contains { scan in scan.bytesByRule.contains { !top.contains($0.key) && $0.value > 0 } }
        series = top.compactMap { names[$0] } + (hasOther ? [Self.otherSeries] : [])
        for scan in scans {
            for rule in top {
                points.append(Point(date: scan.date, series: names[rule] ?? rule, bytes: scan.bytesByRule[rule] ?? 0))
            }
            if hasOther {
                let rest = scan.bytesByRule.filter { !top.contains($0.key) }.values.reduce(0, +)
                points.append(Point(date: scan.date, series: Self.otherSeries, bytes: rest))
            }
        }
        let removals = cleanups
            .compactMap { record -> Cut? in
                let removed = record.items.filter { $0.status == .cleaned || $0.status == .partial }.count
                let removedApp = record.items.contains { $0.id.hasSuffix(".app") && $0.status == .cleaned }
                return removed > 0 ? Cut(date: record.date, bytes: record.measuredBytes, items: removed, uninstalled: record.uninstalled, removedApp: removedApp) : nil
            }
            .sorted { $0.date < $1.date }
        cuts = removals.filter { $0.date >= first.date && $0.date <= latest.date }

        let baseline: ScanRecord
        if let lastCut = removals.last?.date {
            guard let after = scans.first(where: { $0.date > lastCut }) else { return }
            baseline = after
        } else {
            baseline = first
        }
        let interval = latest.date.timeIntervalSince(baseline.date)
        guard baseline.date < latest.date, interval >= 86_400 else { return }
        since = baseline.date
        regrowth = latest.bytesByRule.compactMap { rule, bytes in
            let delta = bytes - (baseline.bytesByRule[rule] ?? 0)
            guard delta >= minimum else { return nil }
            return Regrowth(ruleID: rule, label: latest.labels[rule] ?? rule, bytes: delta, perWeek: Int64(Double(delta) * 604_800 / interval))
        }
        .sorted { $0.perWeek > $1.perWeek }
        .prefix(4)
        .map { $0 }
    }
}

extension Strata.Cut {
    var label: String {
        if let uninstalled { return removedApp ? "Uninstalled \(uninstalled)" : "Removed \(uninstalled) files" }
        return bytes > 0 ? "Cleaned \(bytes.formattedBytes)" : "Cleaned \(items) \(items == 1 ? "item" : "items")"
    }
}

private struct StrataChart: View {
    var strata: Strata

    private static let palette: [Color] = [
        Color(red: 0.26, green: 0.38, blue: 0.56),
        Color(red: 0.37, green: 0.57, blue: 0.56),
        Color(red: 0.50, green: 0.66, blue: 0.74),
        Color(red: 0.78, green: 0.70, blue: 0.49),
        Color(red: 0.62, green: 0.68, blue: 0.48),
        Color(red: 0.55, green: 0.50, blue: 0.66),
        Color(red: 0.62, green: 0.64, blue: 0.66),
    ]

    var body: some View {
        Chart {
            ForEach(strata.points) { point in
                AreaMark(
                    x: .value("Scanned", point.date),
                    y: .value("GB", Double(point.bytes) / 1e9),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Item", point.series))
                .interpolationMethod(.monotone)
            }
            ForEach(strata.cuts) { cut in
                RuleMark(x: .value("Cleaned", cut.date))
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(cut.label)
                            .font(.caption.weight(.semibold))
                    }
            }
        }
        .chartForegroundStyleScale(domain: strata.series, range: Array(Self.palette.prefix(strata.series.count)))
        .chartYAxisLabel("GB Arin could clean")
        .chartLegend(position: .trailing, alignment: .top, spacing: 16)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .accessibilityLabel("What Arin found at each scan, stacked by item")
    }
}

private struct RegrowthRows: View {
    @Environment(AppModel.self) private var model
    var strata: Strata

    var body: some View {
        if let since = strata.since {
            if strata.regrowth.isEmpty {
                Text("Nothing grew back by more than 256 MB since \(since.formatted(date: .abbreviated, time: .omitted)).")
                    .foregroundStyle(.secondary)
            }
            ForEach(strata.regrowth) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                        Text("+\(item.bytes.formattedBytes) since \(since.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("+\(item.perWeek.formattedBytes) a week")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if !strata.regrowth.isEmpty, !model.autoMode, !model.target.isRemote {
                HStack {
                    Text("Auto mode cleans quick caches on its own when you run low on space.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Text("Settings…") }
                }
            }
        }
    }
}

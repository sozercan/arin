import AppKit
import ArinCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var bucket: AppModel.Bucket = .review
    @State private var focus: Candidate.ID?
    @State private var width: CGFloat = 1000

    var body: some View {
        let columns = width > 940
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(spacing: 18))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OverviewHeader()
                SpaceLanes(focus: focus, open: open)
                columns {
                    ItemsCard(bucket: $bucket, focus: $focus)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        DiskCard()
                        DiskGrid()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .navigationTitle(model.target.displayName)
    }

    private func open(_ id: Candidate.ID) {
        guard let item = model.candidates.first(where: { $0.id == id }) else { return }
        bucket = model.bucket(of: item)
        focus = id
    }
}

enum ItemState {
    case safe, review, blocked, kept

    init(_ candidate: Candidate, bucket: AppModel.Bucket) {
        if bucket == .kept {
            self = .kept
        } else if !candidate.blockers.isEmpty || !candidate.isActionable {
            self = .blocked
        } else {
            self = bucket == .safe ? .safe : .review
        }
    }
}

enum Volume {
    static let localName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Startup disk"

    static func name(for target: CleanupTarget) -> String {
        target.isRemote ? "Home volume" : localName
    }

    static func symbol(for target: CleanupTarget) -> String {
        target.isRemote ? "server.rack" : "internaldrive"
    }
}

private struct OverviewHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let safe = model.candidates(in: .safe).dedupedBytes
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(model.target.displayName)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                if model.phase.isBusy {
                    StatusPill(text: model.phase.label, tint: .secondary, busy: true)
                } else if safe > 0 {
                    StatusPill(text: "\(safe.formattedBytes) safe to clean", symbol: "checkmark", tint: .green)
                } else {
                    StatusPill(text: "Nothing safe to clean at \(model.level.label)", symbol: "checkmark", tint: .secondary)
                }
            }
            HStack(spacing: 22) {
                Label(diskLine, systemImage: Volume.symbol(for: model.target))
                if let report = model.report {
                    Label("Scanned \(report.finishedAt.formatted(.relative(presentation: .named)))", systemImage: "clock")
                }
                Label("\(model.candidates.count) items", systemImage: "list.bullet")
                Label("\(model.candidates.dedupedBytes.formattedBytes) found", systemImage: "arrow.down.to.line")
                if let review = model.lastReview {
                    Label("Checked by \(review.agent)", systemImage: "sparkles")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var diskLine: String {
        let name = Volume.name(for: model.target)
        guard model.disk.totalBytes > 0 else { return name }
        return "\(name) · \(model.disk.freeBytes.formattedBytes) free of \(model.disk.totalBytes.formattedBytes)"
    }
}

private struct Lane: Identifiable {
    var category: CleanupCategory
    var items: [Candidate]
    var bytes: Int64

    var id: CleanupCategory { category }

    static func build(_ candidates: [Candidate]) -> [Lane] {
        Dictionary(grouping: candidates.filter { $0.bytes > 0 }.outermost, by: \.category)
            .map { category, items in
                Lane(category: category, items: items.sorted { $0.bytes > $1.bytes }, bytes: items.reduce(0) { $0 + $1.bytes })
            }
            .sorted { $0.bytes > $1.bytes }
    }
}

private struct AxisScale {
    var step: Int64
    var max: Int64

    init(max bytes: Int64) {
        let steps: [Int64] = [100, 200, 500].map { $0 << 20 } + [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000].map { $0 << 30 }
        step = steps.first { bytes <= $0 * 6 } ?? steps[steps.count - 1]
        max = Swift.max(step, ((bytes + step - 1) / step) * step)
    }

    var ticks: [Int64] { Array(stride(from: 0, through: max, by: Int(step))) }
}

private struct SpaceLanes: View {
    @Environment(AppModel.self) private var model
    var focus: Candidate.ID?
    var open: (Candidate.ID) -> Void

    private let labelWidth: CGFloat = 160

    var body: some View {
        let lanes = Lane.build(model.candidates)
        let scale = AxisScale(max: lanes.map(\.bytes).max() ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Text("Where the space is").font(.headline)
                Spacer()
                ForEach([ItemState.review, .safe, .blocked, .kept], id: \.self) { state in
                    HStack(spacing: 6) {
                        StateSwatch(state: state, color: .secondary)
                            .frame(width: 18, height: 11)
                        Text(state.title)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if lanes.isEmpty {
                Text("Nothing found at the \(model.level.label) level.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(lanes) { lane in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(lane.category.color).frame(width: 8, height: 8)
                                Text(lane.category.label).lineLimit(1)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                            GeometryReader { geo in
                                LaneTrack(lane: lane, unit: geo.size.width / CGFloat(scale.max), focus: focus, open: open)
                            }
                            .frame(height: 26)
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .top) {
                            if lane.id != lanes.first?.id { Divider() }
                        }
                    }
                    axis(scale)
                }
            }
        }
        .card()
    }

    private func axis(_ scale: AxisScale) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                ForEach(scale.ticks, id: \.self) { tick in
                    Text(tick == 0 ? "0" : tick.formattedBytes)
                        .fixedSize()
                        .position(x: geo.size.width * CGFloat(tick) / CGFloat(scale.max), y: 8)
                }
            }
            .frame(height: 16)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 6)
        .padding(.trailing, 14)
        .accessibilityHidden(true)
    }
}

private struct LaneTrack: View {
    @Environment(AppModel.self) private var model
    var lane: Lane
    var unit: CGFloat
    var focus: Candidate.ID?
    var open: (Candidate.ID) -> Void

    var body: some View {
        let big = lane.items.filter { CGFloat($0.bytes) * unit >= 8 }
        let rest = lane.items.filter { CGFloat($0.bytes) * unit < 8 }
        let restBytes = rest.reduce(0) { $0 + $1.bytes }
        HStack(spacing: 3) {
            ForEach(big) { item in
                Button {
                    open(item.id)
                } label: {
                    Bar(candidate: item, state: ItemState(item, bucket: model.bucket(of: item)), color: lane.category.color, width: CGFloat(item.bytes) * unit - 3, focused: focus == item.id)
                }
                .buttonStyle(.plain)
            }
            if !rest.isEmpty {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(lane.category.color.opacity(0.3))
                    .frame(width: max(3, CGFloat(restBytes) * unit - 3))
                    .help("\(rest.count) smaller \(rest.count == 1 ? "item" : "items"), \(restBytes.formattedBytes)")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Bar: View {
    var candidate: Candidate
    var state: ItemState
    var color: Color
    var width: CGFloat
    var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        StateSwatch(state: state, color: color)
            .overlay(alignment: .leading) {
                if width > 60 {
                    Text(candidate.title)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .foregroundStyle(state == .safe ? Color.black.opacity(0.8) : Color.primary)
                }
            }
            .overlay {
                if focused { shape.strokeBorder(Color.primary, lineWidth: 2) }
            }
            .frame(width: max(width, 3))
            .contentShape(shape)
            .help("\(candidate.title) · \(candidate.bytes.formattedBytes) · \(state.title)")
            .accessibilityElement()
            .accessibilityLabel("\(candidate.title), \(candidate.bytes.formattedBytes), \(state.title)")
    }
}

private struct StateSwatch: View {
    var state: ItemState
    var color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        switch state {
        case .safe:
            shape.fill(color)
        case .review:
            shape.fill(color.opacity(0.25)).overlay(shape.strokeBorder(color.opacity(0.6), lineWidth: 1))
        case .blocked:
            Hatch(color: Color.secondary.opacity(0.55)).clipShape(shape).overlay(shape.strokeBorder(.separator, lineWidth: 1))
        case .kept:
            shape.strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

extension ItemState {
    var title: String {
        switch self {
        case .safe: "Safe"
        case .review: "Needs a look"
        case .blocked: "Blocked"
        case .kept: "Kept"
        }
    }
}

private struct ItemsCard: View {
    @Environment(AppModel.self) private var model
    @Binding var bucket: AppModel.Bucket
    @Binding var focus: Candidate.ID?
    @State private var showAll = false

    private let limit = 8

    var body: some View {
        let items = model.candidates(in: bucket)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(bucket.title).font(.headline)
                Spacer()
                Picker("Show", selection: $bucket) {
                    ForEach(AppModel.Bucket.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(lead(items))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ForEach(shown(items)) { item in
                Divider()
                ItemRow(candidate: item, expanded: focus == item.id) {
                    withAnimation(.snappy(duration: 0.2)) { focus = focus == item.id ? nil : item.id }
                }
            }
            if items.count > limit {
                Divider()
                Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .padding(.top, 12)
            }
            if bucket == .safe, !items.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        model.confirmClean(items)
                    } label: {
                        Label("Clean All \(items.dedupedBytes.formattedBytes)…", systemImage: "checkmark")
                    }
                    .buttonStyle(.solid)
                    .disabled(model.phase.isBusy)
                }
                .padding(.top, 14)
            }
        }
        .card()
        .onChange(of: bucket) { showAll = false }
    }

    private func shown(_ items: [Candidate]) -> [Candidate] {
        guard !showAll else { return items }
        var result = Array(items.prefix(limit))
        if let focused = items.first(where: { $0.id == focus }), !result.contains(focused) {
            result.append(focused)
        }
        return result
    }

    private func lead(_ items: [Candidate]) -> String {
        let summary = "\(items.count) \(items.count == 1 ? "item" : "items"), \(items.dedupedBytes.formattedBytes)."
        switch bucket {
        case .review:
            if items.isEmpty { return "Nothing needs a look. Everything found is either safe to clean or kept." }
            return "\(summary) The rules can't settle these alone. Open one to see why."
        case .safe:
            if items.isEmpty { return "Nothing is safe to clean at the \(model.level.label) level. Try a deeper level, or open the items that need a look." }
            return "\(summary) Safe at the \(model.level.label) level. Arin re-checks open files and running apps before each one."
        case .kept:
            if items.isEmpty { return "Nothing kept. Items you always keep, and items your agent says to keep, show up here." }
            return "\(summary) Arin never selects these on its own. Items on your keep list are never cleaned."
        }
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    var candidate: Candidate
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: candidate.category.symbol)
                        .foregroundStyle(candidate.category.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title).lineLimit(1)
                        subtitle
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    meta
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides details" : "Shows details and actions")
            if expanded {
                ItemDetail(candidate: candidate)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let verdict = candidate.agentVerdict {
            Text("\(Image(systemName: "sparkles")) \(verdict.agent): \(verdict.reason)")
        } else if let blocker = candidate.blockers.first {
            Text(blocker)
        } else {
            Text(ruleText: candidate.detail)
        }
    }

    private var meta: some View {
        let size = candidate.bytes > 0 ? candidate.bytes.formattedBytes : "Size unknown"
        let state = ItemState(candidate, bucket: model.bucket(of: candidate))
        return Text(state == .blocked ? "\(size) · \(candidate.isActionable ? "blocked" : "report only")" : size)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(state == .blocked && candidate.isActionable ? Color.red : Color.secondary)
            .lineLimit(1)
    }
}

private struct ItemDetail: View {
    @Environment(AppModel.self) private var model
    var candidate: Candidate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let verdict = candidate.agentVerdict {
                Label {
                    Text("\(verdict.agent): \(verdict.reason)").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                }
            }
            Text(ruleText: candidate.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(candidate.blockers, id: \.self) { blocker in
                Label {
                    Text(blocker).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
            }
            Text(facts)
                .font(.caption)
                .foregroundStyle(.secondary)
            if candidate.isActionable {
                Text(candidate.action.summary)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 1))
            }
            if !candidate.paths.isEmpty {
                locations
            }
            actions
        }
    }

    private var facts: String {
        var parts = [candidate.category.label, "\(candidate.level.label) level"]
        if let modified = candidate.lastModified {
            parts.append("modified \(modified.formatted(.relative(presentation: .named)))")
        }
        if model.target.isRemote { parts.append("on \(model.target.displayName)") }
        return parts.joined(separator: " · ")
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(candidate.paths.prefix(3), id: \.self) { path in
                HStack(spacing: 6) {
                    Text(model.target.isRemote ? path : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    if !model.target.isRemote {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Image(systemName: "arrow.forward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal \(path) in Finder")
                    }
                }
            }
            if candidate.paths.count > 3 {
                Text("and \(candidate.paths.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if candidate.kept {
                Text("On your keep list.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Keeping") { model.setKept(candidate.id, title: candidate.title, paths: candidate.paths, false) }
                    .buttonStyle(.outline)
            } else if !candidate.isActionable {
                Text("Arin reports this but has no command to clean it.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if candidate.effectiveRisk == .keep {
                Text("\(candidate.agentVerdict?.agent ?? "Your agent") says to keep this, so Arin won't select it.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(candidate.bytes > 0 ? "Clean Anyway \(candidate.bytes.formattedBytes)…" : "Clean Anyway…") {
                    model.confirmClean([candidate])
                }
                .buttonStyle(.outline)
                .disabled(model.phase.isBusy)
                .help("Clean it even though your agent advised keeping it")
            } else {
                Spacer()
                Button("Always Keep") { model.setKept(candidate.id, title: candidate.title, paths: candidate.paths, true) }
                    .buttonStyle(.outline)
                    .help("Add it to your keep list so Arin never cleans it")
                Button {
                    model.confirmClean([candidate])
                } label: {
                    Label(candidate.bytes > 0 ? "Clean \(candidate.bytes.formattedBytes)…" : "Clean…", systemImage: "checkmark")
                        .monospacedDigit()
                }
                .buttonStyle(.solid)
                .disabled(model.phase.isBusy)
                .help("Review and confirm cleaning this item")
            }
        }
        .padding(.top, 2)
    }
}

private struct DiskCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let review = model.candidates(in: .review)
        let blocked = review.filter { !$0.blockers.isEmpty || !$0.isActionable }
        let look = review.filter { $0.blockers.isEmpty && $0.isActionable }
        let safe = model.candidates(in: .safe).dedupedBytes
        let known = model.disk.totalBytes > 0
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(Volume.name(for: model.target), systemImage: Volume.symbol(for: model.target))
                    .font(.headline)
                Spacer()
                Text("\(model.level.label) scan").foregroundStyle(.secondary)
            }
            StatRow(tiles: [
                StatTile(label: "Free", value: known ? model.disk.freeBytes.formattedBytes : "–", tint: known && !model.target.isRemote && model.isLowOnSpace ? .red : nil),
                StatTile(label: "Safe", value: Self.size(safe)),
                StatTile(label: "Needs a look", value: Self.size(look.dedupedBytes)),
                StatTile(label: "Blocked", value: Self.size(blocked.dedupedBytes)),
            ])
            SplitBar(segments: [
                Segment(label: "Safe", bytes: safe, color: .green),
                Segment(label: "Look", bytes: look.dedupedBytes, color: .blue),
                Segment(label: "Blocked", bytes: blocked.dedupedBytes, color: .gray),
            ])
        }
        .card()
    }

    private static func size(_ bytes: Int64) -> String {
        bytes > 0 ? bytes.formattedBytes : "–"
    }
}

private struct DiskGrid: View {
    @Environment(AppModel.self) private var model

    private static let columns = 20
    private static let rows = 10

    private struct Part: Identifiable {
        var label: String
        var bytes: Int64
        var color: Color
        var weight: Int64
        var id: String { label }

        init(label: String, bytes: Int64, color: Color) {
            self.label = label
            self.bytes = bytes
            self.color = color
            weight = bytes
        }
    }

    var body: some View {
        let disk = model.disk
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Disk").font(.headline)
                Spacer()
                if disk.totalBytes > 0 {
                    Text("\((disk.totalBytes - disk.freeBytes).formattedBytes) of \(disk.totalBytes.formattedBytes) used")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if disk.totalBytes > 0 {
                let parts = parts(disk)
                HStack(alignment: .top, spacing: 22) {
                    grid(parts, disk: disk)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(parts) { part in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(part.color)
                                    .frame(width: 10, height: 10)
                                Text(part.label).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(part.bytes.formattedBytes)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            } else {
                Text(model.target.isRemote ? "Waiting for the disk size from \(model.target.displayName)." : "The disk size isn't available.")
                    .foregroundStyle(.secondary)
            }
            if !model.target.isRemote {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Alerts below \(model.lowSpaceThresholdGB) GB free")
                    Spacer()
                    SettingsLink { Text("Change") }
                        .buttonStyle(.outline)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func parts(_ disk: DiskStatus) -> [Part] {
        let groups = Dictionary(grouping: model.candidates.filter { $0.bytes > 0 }.outermost, by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }
            .sorted { $0.1 > $1.1 }
        var parts = groups.prefix(5).map { Part(label: $0.0.label, bytes: $0.1, color: $0.0.color) }
        let other = groups.dropFirst(5).reduce(0) { $0 + $1.1 }
        if other > 0 { parts.append(Part(label: "Other found", bytes: other, color: .gray)) }
        let used = max(0, disk.totalBytes - disk.freeBytes)
        let found = parts.reduce(0) { $0 + $1.bytes }
        if found > used, found > 0 {
            let scale = Double(used) / Double(found)
            for index in parts.indices {
                parts[index].weight = Int64(Double(parts[index].bytes) * scale)
            }
        }
        let fitted = parts.reduce(0) { $0 + $1.weight }
        parts.insert(Part(label: "Everything else", bytes: max(0, used - fitted), color: .gray.opacity(0.35)), at: 0)
        parts.append(Part(label: "Free", bytes: disk.freeBytes, color: .primary.opacity(0.08)))
        return parts
    }

    private func cells(_ parts: [Part], total: Int64) -> [Color] {
        let count = Self.columns * Self.rows
        let exact = parts.map { Double($0.weight) / Double(max(total, 1)) * Double(count) }
        var sizes = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { exact[$0] - Double(sizes[$0]) > exact[$1] - Double(sizes[$1]) }
        var missing = count - sizes.reduce(0, +)
        for index in order where missing > 0 {
            sizes[index] += 1
            missing -= 1
        }
        return zip(parts, sizes).flatMap { part, size in Array(repeating: part.color, count: max(0, size)) }
    }

    private func grid(_ parts: [Part], disk: DiskStatus) -> some View {
        let colors = cells(parts, total: parts.reduce(0) { $0 + $1.weight })
        let alertCells = Int((Double(model.lowSpaceThreshold) / Double(disk.totalBytes) * Double(colors.count)).rounded())
        let firstAlert = model.target.isRemote ? colors.count : colors.count - alertCells
        return VStack(spacing: 3) {
            ForEach(0 ..< Self.rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0 ..< Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(index < colors.count ? colors[index] : .clear)
                            .overlay {
                                if index >= firstAlert {
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .strokeBorder(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                                }
                            }
                            .frame(width: 11, height: 11)
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Disk use by category")
    }
}

extension Text {
    init(ruleText: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self.init((try? AttributedString(markdown: ruleText, options: options)) ?? AttributedString(ruleText))
    }
}

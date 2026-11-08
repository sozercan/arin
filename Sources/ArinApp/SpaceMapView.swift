import ArinCore
import SwiftUI

extension CleanupCategory {
    /// One fixed color per category, so a category keeps its color whatever else is on screen.
    var color: Color {
        switch self {
        case .devCaches: .blue
        case .xcode: .indigo
        case .temp: .teal
        case .toolVersions: .purple
        case .projects: .green
        case .worktrees: .orange
        case .containers: .cyan
        case .appCaches: .pink
        case .agentData: .yellow
        case .models: .mint
        case .snapshots: .brown
        case .unclassified: .gray
        }
    }
}

/// Everything the scan found as a treemap: one block per category, one tile per item, sized by
/// folder size. Clicking a tile selects it for cleaning, like its checkbox.
struct SpaceMapView: View {
    @Environment(AppModel.self) private var model

    private var groups: [(category: CleanupCategory, items: [Candidate])] {
        model.categoriesWithResults.compactMap { category in
            let items = model.candidates.filter { $0.category == category && $0.bytes > 0 }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Space map").font(.title3.weight(.semibold))
                Text("Folder sizes; click a tile to select it.")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.selection.count) selected")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if groups.isEmpty {
                ContentUnavailableView("Nothing to map", systemImage: "square.grid.3x3", description: Text("No items with a measured size."))
            } else {
                GeometryReader { proxy in
                    let bounds = CGRect(origin: .zero, size: proxy.size)
                    let blocks = Treemap.layout(groups.map { Double($0.items.reduce(0) { $0 + $1.bytes }) }, in: bounds)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(groups.enumerated()), id: \.element.category) { index, group in
                            CategoryBlock(category: group.category, items: group.items, frame: blocks[index])
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct CategoryBlock: View {
    @Environment(AppModel.self) private var model
    var category: CleanupCategory
    var items: [Candidate]
    var frame: CGRect

    var body: some View {
        let showHeader = frame.height > 60 && frame.width > 90
        let header: CGFloat = showHeader ? 20 : 0
        let inner = CGRect(x: 0, y: header, width: max(frame.width - 4, 0), height: max(frame.height - header - 4, 0))
        let tiles = Treemap.layout(items.map { Double($0.bytes) }, in: inner)
        ZStack(alignment: .topLeading) {
            if showHeader {
                HStack(spacing: 4) {
                    Image(systemName: category.symbol)
                    Text(category.label).lineLimit(1)
                    Text(items.dedupedBytes.formattedBytes).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .padding(.leading, 2)
                .frame(width: inner.width, height: header, alignment: .leading)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = model.selection.contains(item.id)
                Button { model.toggle(item) } label: {
                    Tile(candidate: item, color: category.color, isSelected: selected)
                }
                .buttonStyle(.plain)
                // Same rule as the list's checkbox: kept items can only be deselected.
                .disabled(!item.isActionable || item.kept && !selected)
                .frame(width: max(tiles[index].width - 2, 0), height: max(tiles[index].height - 2, 0))
                .offset(x: tiles[index].minX, y: tiles[index].minY)
            }
        }
        .frame(width: max(frame.width - 2, 0), height: max(frame.height - 2, 0), alignment: .topLeading)
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(category.label), \(items.dedupedBytes.formattedBytes)")
    }
}

private struct Tile: View {
    var candidate: Candidate
    var color: Color
    var isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            let roomy = proxy.size.width > 70 && proxy.size.height > 30
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(isSelected ? 0.75 : candidate.kept ? 0.12 : 0.3))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? color : color.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                if roomy {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            if isSelected { Image(systemName: "checkmark.circle.fill") }
                            if candidate.kept { Image(systemName: "lock.fill") }
                            Text(candidate.title).lineLimit(proxy.size.height > 48 ? 2 : 1)
                        }
                        .font(.caption)
                        Text(candidate.bytes.formattedBytes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(5)
                }
            }
        }
        .contentShape(Rectangle())
        .help("\(candidate.title)\n\(candidate.bytes.formattedBytes) · \(candidate.effectiveRisk.label)\(candidate.kept ? " · always kept" : "")")
        .accessibilityElement()
        .accessibilityLabel("\(candidate.title), \(candidate.bytes.formattedBytes), \(candidate.effectiveRisk.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

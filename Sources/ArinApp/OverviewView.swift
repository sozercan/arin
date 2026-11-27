import ArinCore
import SwiftUI

/// What a scan found, before the item lists: one total, the disk bar, a tile per category, and insights.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                categories
                if let report = model.report, !report.insights.isEmpty || !report.ruleErrors.isEmpty {
                    insights(report)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    private var hero: some View {
        let found = model.candidates.dedupedBytes
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SizeText(bytes: found, size: 52, weight: .bold)
                Text("found")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.safeBytes > 0 {
                    Chip(text: "\(model.safeBytes.formattedBytes) safe at \(model.level.label)", color: .green)
                }
            }
            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            SpaceBar(total: model.disk.totalBytes, segments: diskSegments, height: 14)
            legend

            if !model.candidates.isEmpty {
                Button {
                    model.sidebar = .all
                } label: {
                    Label("Review items", systemImage: "list.bullet")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroWash, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.signature.opacity(0.18)))
    }

    private var summary: String {
        let count = model.candidates.count
        let groups = model.categoriesWithResults.count
        var parts = ["\(count) \(count == 1 ? "item" : "items") in \(groups) \(groups == 1 ? "category" : "categories")"]
        if let report = model.report {
            parts.append("scanned \(report.finishedAt.formatted(.relative(presentation: .named)))")
        }
        if let review = model.lastReview {
            parts.append("checked by \(review.agent)")
        }
        return parts.joined(separator: " · ")
    }

    private var diskSegments: [SpaceBar.Segment] {
        let disk = model.disk
        let used = disk.totalBytes - disk.freeBytes
        let findings = model.findingsByCategory
        let found = min(findings.reduce(0) { $0 + $1.bytes }, used)
        return [SpaceBar.Segment(id: "used", bytes: used - found, color: Theme.usedSpace)]
            + findings.map { SpaceBar.Segment(id: $0.category.rawValue, bytes: $0.bytes, color: $0.category.color) }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(Theme.usedSpace, "Other used space")
            legendItem(Theme.signature, "Arin's findings")
            legendItem(Color.secondary.opacity(0.3), "\(model.disk.freeBytes.formattedBytes) free of \(model.disk.totalBytes.formattedBytes)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    // MARK: Categories

    private var categories: some View {
        let findings = model.findingsByCategory
        let largest = findings.first?.bytes ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("By category")
                .font(.headline)
            if findings.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "checkmark.circle", description: Text("The scan didn't find anything Arin knows how to remove."))
                    .frame(maxWidth: .infinity)
                    .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(findings, id: \.category) { finding in
                        CategoryTile(category: finding.category, bytes: finding.bytes, largest: largest)
                    }
                }
            }
        }
    }

    // MARK: Insights

    private func insights(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worth knowing")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(report.insights) { insight in
                    InsightCard(symbol: "lightbulb.fill", color: .yellow, title: insight.title, detail: insight.detail, bytes: insight.bytes)
                }
                ForEach(report.ruleErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, error in
                    InsightCard(symbol: "exclamationmark.triangle.fill", color: .orange, title: name, detail: error, bytes: nil)
                }
            }
        }
    }
}

private struct CategoryTile: View {
    @Environment(AppModel.self) private var model
    var category: CleanupCategory
    var bytes: Int64
    var largest: Int64

    var body: some View {
        let items = model.candidates.filter { $0.category == category }
        let selected = items.filter { model.selection.contains($0.id) }.count
        Button {
            model.sidebar = .category(category)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CategoryIcon(category: category, size: 32)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    SizeText(bytes: bytes, size: 26)
                        .foregroundStyle(.primary)
                }
                SpaceBar(
                    total: largest,
                    segments: [SpaceBar.Segment(id: category.rawValue, bytes: bytes, color: category.color)],
                    height: 5
                )
                Text("\(items.count) \(items.count == 1 ? "item" : "items") · \(selected) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .card()
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.label), \(bytes.formattedBytes), \(items.count) items, \(selected) selected")
    }
}

private struct InsightCard: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    var bytes: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    if let bytes {
                        Chip(text: bytes.formattedBytes)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

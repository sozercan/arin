import ArinCore
import SwiftUI

struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let items = model.selectedCandidates.sorted { $0.bytes > $1.bytes }
        let review = items.filter { $0.effectiveRisk != .safe || !$0.blockers.isEmpty }
        let safe = items.filter { $0.effectiveRisk == .safe && $0.blockers.isEmpty }

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clean \(items.count) \(items.count == 1 ? "item" : "items")?")
                    .font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("About")
                        .foregroundStyle(.secondary)
                    SizeText(bytes: items.dedupedBytes, size: 30)
                }
                Text("Estimated from folder sizes. APFS shares blocks between copies, so the real gain is often smaller; Arin measures it afterward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                if !review.isEmpty {
                    Section {
                        ForEach(review) { row($0, attention: true) }
                    } header: {
                        Label("Needs a look · \(review.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !safe.isEmpty {
                    Section {
                        ForEach(safe) { row($0, attention: false) }
                    } header: {
                        Label("Safe · \(safe.count)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !review.isEmpty {
                Text("Arin re-checks running apps and open files right before each item.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Move to Trash instead of deleting", isOn: $model.trashInsteadOfDelete)
                Text("Trash is reversible, but frees nothing until you empty it. Tool commands (go clean, git worktree remove, simctl) always run directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.trashInsteadOfDelete ? "Move to Trash" : "Clean", role: .destructive) {
                    dismiss()
                    Task { await model.clean() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 620, height: 600)
        .tint(Theme.signature)
    }

    private func row(_ item: Candidate, attention: Bool) -> some View {
        HStack(spacing: 10) {
            CategoryIcon(category: item.category, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.blockers.first ?? item.action.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(attention && !item.blockers.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(item.bytes.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ResultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shownBytes: Int64 = 0
    @State private var celebrate = false
    @State private var showItems = false

    var body: some View {
        if let report = model.lastCleanup {
            let problems = report.items.filter { $0.status != .cleaned }
            let outcome = outcome(cleaned: report.cleanedCount, problems: problems.count)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: outcome.symbol)
                        .font(.system(size: 44))
                        .foregroundStyle(outcome.color)
                        .symbolEffect(.bounce, value: celebrate)
                    VStack(alignment: .leading, spacing: 0) {
                        if report.measuredBytes > 0 {
                            Text("Freed")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                            SizeText(bytes: shownBytes, size: 44, weight: .bold)
                        } else {
                            Text(outcome.title)
                                .font(.title.weight(.semibold))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SpaceBar(total: model.disk.totalBytes, segments: freeSegments(report), height: 12)
                    HStack {
                        Text("Free space \(report.freeBefore.formattedBytes) → \(report.freeAfter.formattedBytes)")
                        Spacer()
                        Text("Folder sizes added up to \(report.estimatedBytes.formattedBytes)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .card()

                if !report.explanations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.explanations, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showItems) {
                    List(report.items) { item in
                        HStack(alignment: .top) {
                            Image(systemName: icon(item.status))
                                .foregroundStyle(color(item.status))
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                Text(item.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180)
                } label: {
                    Text("\(report.cleanedCount) cleaned · \(problems.count) skipped or failed")
                        .font(.headline)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(24)
            .frame(width: 620, height: 560)
            .tint(Theme.signature)
            .onAppear {
                showItems = !problems.isEmpty
                if report.cleanedCount > 0 { celebrate.toggle() }
                withAnimation(.smooth(duration: 0.9)) { shownBytes = max(report.measuredBytes, 0) }
            }
        }
    }

    /// The header icon and title: a failure must not look like a success.
    private func outcome(cleaned: Int, problems: Int) -> (symbol: String, color: Color, title: String) {
        if cleaned == 0 { return ("xmark.circle.fill", .red, "Nothing was cleaned") }
        if problems > 0 { return ("exclamationmark.circle.fill", .orange, "Cleaned with problems") }
        return ("checkmark.circle.fill", .green, "Cleanup finished")
    }

    /// The disk after cleaning, with what was freed highlighted.
    private func freeSegments(_ report: CleanupReport) -> [SpaceBar.Segment] {
        let total = model.disk.totalBytes
        return [
            SpaceBar.Segment(id: "used", bytes: total - report.freeAfter, color: Theme.usedSpace),
            SpaceBar.Segment(id: "freed", bytes: max(report.measuredBytes, 0), color: .green),
        ]
    }

    private func icon(_ status: CleanupItemResult.Status) -> String {
        switch status {
        case .cleaned: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(_ status: CleanupItemResult.Status) -> Color {
        switch status {
        case .cleaned: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

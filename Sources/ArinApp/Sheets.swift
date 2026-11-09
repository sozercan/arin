import ArinCore
import SwiftUI

struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let items = model.selectedCandidates
        let review = items.filter { $0.effectiveRisk != .safe || !$0.blockers.isEmpty }

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean \(items.count) items?")
                    .font(.title2.weight(.semibold))
                Text("About \(items.dedupedBytes.formattedBytes) by folder size. The real gain is measured afterward and is often smaller, because APFS shares blocks between copies.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List(items) { item in
                HStack {
                    Image(systemName: item.effectiveRisk == .safe ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(item.effectiveRisk == .safe ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.action.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(item.bytes > 0 ? item.bytes.formattedBytes : "Size unknown").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 180)

            if !review.isEmpty {
                Label {
                    Text("\(review.count) selected item(s) are marked Review or have warnings. Arin re-checks running apps and open files right before each one.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Move to Trash instead of deleting", isOn: $model.trashInsteadOfDelete)
            Text("Trash is reversible, but frees nothing until you empty it. Tool commands (go clean, git worktree remove, simctl) always run directly.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 560)
        .presentationSizing(.fitted)
    }
}

struct ResultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let report = model.lastCleanup {
            let problems = report.items.filter { $0.status != .cleaned }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.measuredBytes > 0 ? "Freed \(report.measuredBytes.formattedBytes)" : "Cleanup finished")
                        .font(.title2.weight(.semibold))
                    Text("Free space went from \(report.freeBefore.formattedBytes) to \(report.freeAfter.formattedBytes). Folder sizes of what was cleaned added up to \(report.estimatedBytes.formattedBytes).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !report.explanations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.explanations, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("\(report.cleanedCount) cleaned, \(problems.count) skipped or failed")
                    .font(.headline)
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
                .frame(minHeight: 160)

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 540)
            .presentationSizing(.fitted)
        }
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

import AppKit
import ArinCore
import SwiftUI

struct CandidateList: View {
    @Environment(AppModel.self) private var model
    var items: [Candidate]

    var body: some View {
        @Bindable var model = model
        let items = model.sortOrder.sorted(items)
        if items.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "checkmark.circle", description: Text("No candidates in this group."))
        } else {
            List {
                Section {
                    ForEach(items) { item in
                        CandidateRow(candidate: item, isSelected: model.selection.contains(item.id)) {
                            model.toggle(item)
                        } setKept: { kept in
                            model.setKept(item.id, title: item.title, kept)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(items.count) items · \(items.dedupedBytes.formattedBytes)")
                        Spacer()
                        Picker("Sort", selection: $model.sortOrder) {
                            ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .buttonStyle(.automatic)
                        Button("Select safe") {
                            model.setAll(items, selected: false)
                            model.setAll(items.filter { $0.isDefaultSelected(at: .deep) }, selected: true)
                        }
                        Button("Select none") { model.setAll(items, selected: false) }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct CandidateRow: View {
    var candidate: Candidate
    var isSelected: Bool
    var toggle: () -> Void
    var setKept: (Bool) -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!candidate.isActionable || candidate.kept && !isSelected)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if candidate.level > .quick {
                        Text(candidate.level.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
                    if candidate.kept {
                        Label("Always kept", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("On your keep list. Arin won't pre-select, review, or clean it.")
                    }
                }
                if let path = candidate.paths.first {
                    Text(candidate.paths.count > 1 ? "\(abbreviate(path)) and \(candidate.paths.count - 1) more" : abbreviate(path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let verdict = candidate.agentVerdict {
                    Label(verdict.reason, systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(expanded ? nil : 2)
                }
                ForEach(candidate.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if expanded {
                    Text(candidate.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(candidate.action.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(candidate.bytes > 0 ? candidate.bytes.formattedBytes : "Size unknown")
                    .monospacedDigit()
                    .font(.body.weight(.medium))
                RiskBadge(risk: candidate.effectiveRisk, fromAgent: candidate.agentVerdict != nil)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .contextMenu {
            if candidate.isActionable {
                if candidate.kept {
                    Button("Stop Keeping") { setKept(false) }
                } else {
                    Button("Always Keep") { setKept(true) }
                }
                Divider()
            }
            if let path = candidate.paths.first {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(candidate.paths.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

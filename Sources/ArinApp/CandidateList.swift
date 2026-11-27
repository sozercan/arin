import AppKit
import ArinCore
import SwiftUI

struct CandidateList: View {
    @Environment(AppModel.self) private var model
    var items: [Candidate]

    var body: some View {
        @Bindable var model = model
        let items = model.sortOrder.sorted(items)
        let largest = items.map(\.bytes).max() ?? 0
        if items.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "checkmark.circle", description: Text("No candidates in this group."))
        } else {
            List {
                Section {
                    ForEach(items) { item in
                        CandidateRow(candidate: item, largest: largest, isSelected: model.selection.contains(item.id)) {
                            model.toggle(item)
                        }
                    }
                } header: {
                    HStack(spacing: 12) {
                        Text("\(items.count) items · \(items.dedupedBytes.formattedBytes)")
                            .monospacedDigit()
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
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

struct CandidateRow: View {
    var candidate: Candidate
    var largest: Int64
    var isSelected: Bool
    var toggle: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!candidate.isActionable)
                .padding(.top, 7)

            CategoryIcon(category: candidate.category, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if candidate.level > .quick {
                        Text(candidate.level.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
                }
                Text(metadata)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let verdict = candidate.agentVerdict {
                    Label {
                        Text(verdict.reason)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Theme.signature)
                    }
                    .font(.callout)
                    .lineLimit(expanded ? nil : 2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.signature.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 2)
                }
                ForEach(candidate.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if expanded { details }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text(candidate.bytes.formattedBytes)
                    .font(.body.weight(.semibold).monospacedDigit())
                SpaceBar(
                    total: largest,
                    segments: [SpaceBar.Segment(id: "size", bytes: candidate.bytes, color: candidate.category.color)],
                    height: 4
                )
                .frame(width: 72)
                RiskBadge(risk: candidate.effectiveRisk, fromAgent: candidate.agentVerdict != nil)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .contextMenu {
            if let path = candidate.paths.first {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(candidate.paths.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    /// One monospaced line: where it lives and when it last changed.
    private var metadata: String {
        var parts: [String] = []
        if let path = candidate.paths.first {
            parts.append(candidate.paths.count > 1 ? "\(abbreviate(path)) +\(candidate.paths.count - 1)" : abbreviate(path))
        }
        if let modified = candidate.lastModified {
            parts.append("modified \(modified.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? candidate.category.label : parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidate.paths.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(candidate.paths.prefix(8), id: \.self) { path in
                        Text(abbreviate(path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if candidate.paths.count > 8 {
                        Text("and \(candidate.paths.count - 8) more").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Text(candidate.action.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.top, 4)
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

import AppKit
import ArinCore
import SwiftUI

/// The found items as a sortable table. The checkbox column picks what gets cleaned; row selection
/// only drives the inspector, context menu, and Space-to-toggle.
struct CandidateList: View {
    @Environment(AppModel.self) private var model
    var title: String
    @State private var rows = Set<Candidate.ID>()

    var body: some View {
        @Bindable var model = model
        let sort = model.sortColumn.comparators(ascending: model.sortAscending)
        let items = model.visibleCandidates.sorted(using: sort)
        let focused = items.filter { rows.contains($0.id) }

        Group {
            if items.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("Nothing Here", systemImage: "checkmark.circle", description: Text("No candidates in this group."))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            } else {
                table(items, sort: sort)
            }
        }
        .statusBar()
        .navigationTitle(title)
        .navigationSubtitle("\(items.count) items · \(items.dedupedBytes.formattedBytes)")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search items")
        .inspector(isPresented: $model.showingInspector) {
            CandidateInspector(items: focused)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Select Safe Items") { model.selectSafe(in: items) }
                    Button("Select None") { model.setAll(items, selected: false) }
                } label: {
                    Label("Select", systemImage: "checklist")
                }
                .help("Select the safe items in this list, or none")
            }
            ToolbarItem {
                Button {
                    model.showingInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(model.showingInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    private func table(_ items: [Candidate], sort: [KeyPathComparator<Candidate>]) -> some View {
        Table(items, selection: $rows, sortOrder: Binding(
            get: { sort },
            set: { comparators in
                guard let first = comparators.first, let column = SortColumn(first) else { return }
                model.sortColumn = column
                model.sortAscending = first.order == .forward
            }
        )) {
            TableColumn("") { item in
                CleanCheckbox(candidate: item)
            }
            .width(20)

            TableColumn("Name", value: \.title, comparator: .localizedStandard) { item in
                NameCell(candidate: item)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Size", value: \.bytes) { item in
                Text(item.bytes > 0 ? item.bytes.formattedBytes : "Unknown")
                    .monospacedDigit()
                    .foregroundStyle(item.bytes > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 84, ideal: 92, max: 120)

            TableColumn("Safety", value: \.effectiveRisk) { item in
                RiskBadge(risk: item.effectiveRisk, fromAgent: item.agentVerdict != nil)
            }
            .width(min: 70, ideal: 84, max: 110)

            TableColumn("Level", value: \.level) { item in
                Text(item.level.label).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 72, max: 100)

            TableColumn("Modified", value: \.modifiedSortKey) { item in
                Text(item.lastModified.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Location") { item in
                Text(item.locationSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.paths.joined(separator: "\n"))
            }
            .width(min: 120, ideal: 240)
        }
        .contextMenu(forSelectionType: Candidate.ID.self) { ids in
            menu(items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            reveal(items.filter { ids.contains($0.id) })
        }
        .onKeyPress(.space) {
            let picked = items.filter { rows.contains($0.id) }
            guard !picked.isEmpty else { return .ignored }
            // Like Finder's tag toggle: if any are off, turn them all on; otherwise turn them all off.
            model.setAll(picked, selected: picked.contains { !model.selection.contains($0.id) })
            return .handled
        }
    }

    @ViewBuilder
    private func menu(_ picked: [Candidate]) -> some View {
        let actionable = picked.filter(\.isActionable)
        if !actionable.isEmpty {
            Button("Select for Cleaning") { model.setAll(actionable, selected: true) }
            Button("Deselect") { model.setAll(actionable, selected: false) }
            Divider()
            if actionable.contains(where: { !$0.kept }) {
                Button("Always Keep") {
                    for item in actionable where !item.kept { model.setKept(item.id, title: item.title, paths: item.paths, true) }
                }
            }
            if actionable.contains(where: \.kept) {
                Button("Stop Keeping") {
                    for item in actionable where item.kept { model.setKept(item.id, title: item.title, paths: item.paths, false) }
                }
            }
            Divider()
        }
        if picked.contains(where: { !$0.paths.isEmpty }) {
            Button("Reveal in Finder") { reveal(picked) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(picked.flatMap(\.paths).joined(separator: "\n"), forType: .string)
            }
        }
    }

    private func reveal(_ items: [Candidate]) {
        let urls = items.compactMap(\.paths.first).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

/// Whether the item will be cleaned. Kept items can only be turned off, never on.
struct CleanCheckbox: View {
    @Environment(AppModel.self) private var model
    var candidate: Candidate

    var body: some View {
        let isSelected = model.selection.contains(candidate.id)
        Toggle("Clean \(candidate.title)", isOn: Binding(get: { isSelected }, set: { _ in model.toggle(candidate) }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!candidate.isActionable || candidate.kept && !isSelected)
    }
}

private struct NameCell: View {
    var candidate: Candidate

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: candidate.category.symbol)
                .foregroundStyle(candidate.category.color)
                .frame(width: 16)
            Text(candidate.title).lineLimit(1)
            if candidate.kept {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Always kept: Arin won't pre-select, review, or clean it.")
                    .accessibilityLabel("Always kept")
            }
            if !candidate.blockers.isEmpty {
                Image(systemName: "hand.raised.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .help(candidate.blockers.joined(separator: "\n"))
                    .accessibilityLabel("Warning: \(candidate.blockers.joined(separator: ". "))")
            }
        }
    }
}

/// Everything about the focused row: why it's there, what the agent said, and the exact action.
private struct CandidateInspector: View {
    @Environment(AppModel.self) private var model
    var items: [Candidate]

    var body: some View {
        if items.count == 1, let item = items.first {
            detail(item)
        } else if items.isEmpty {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Select an item to see what it is and exactly what cleaning it runs."))
        } else {
            let actionable = items.filter(\.isActionable)
            Form {
                Section {
                    LabeledContent("Items", value: "\(items.count)")
                    LabeledContent("Folder sizes", value: items.dedupedBytes.formattedBytes)
                }
                if !actionable.isEmpty {
                    Section {
                        Button("Select for Cleaning") { model.setAll(actionable, selected: true) }
                        Button("Deselect") { model.setAll(actionable, selected: false) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func detail(_ item: Candidate) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.category.label, systemImage: item.category.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.bytes > 0 ? item.bytes.formattedBytes : "Size unknown")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        RiskBadge(risk: item.effectiveRisk, fromAgent: item.agentVerdict != nil)
                    }
                }
                .padding(.vertical, 2)
                if item.isActionable {
                    Toggle("Clean this item", isOn: Binding(
                        get: { model.selection.contains(item.id) },
                        set: { _ in model.toggle(item) }
                    ))
                    .disabled(item.kept && !model.selection.contains(item.id))
                    Toggle("Always keep", isOn: Binding(
                        get: { item.kept },
                        set: { model.setKept(item.id, title: item.title, paths: item.paths, $0) }
                    ))
                }
            }

            if !item.blockers.isEmpty {
                Section("Warnings") {
                    ForEach(item.blockers, id: \.self) { blocker in
                        Label {
                            Text(blocker)
                        } icon: {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let verdict = item.agentVerdict {
                Section("\(verdict.agent) says") {
                    Label {
                        Text(verdict.reason).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                    }
                }
            }

            Section("What it is") {
                Text(item.detail)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Level", value: item.level.label)
                if let modified = item.lastModified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if !item.paths.isEmpty {
                Section("Location") {
                    ForEach(item.paths, id: \.self) { path in
                        HStack {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
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
            }

            Section("Cleaning runs") {
                Text(item.action.summary)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

extension Candidate {
    /// "~/Library/Caches/foo and 2 more"
    var locationSummary: String {
        guard let first = paths.first else { return "" }
        let path = (first as NSString).abbreviatingWithTildeInPath
        return paths.count > 1 ? "\(path) and \(paths.count - 1) more" : path
    }
}

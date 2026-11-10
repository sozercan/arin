import AppKit
import ArinCore
import SwiftUI

/// Installed apps, largest first once measured. Pick one (or drop one on the window) to see its
/// files and move them to the Trash.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var rows = Set<AppRow.ID>()
    @State private var sort = [KeyPathComparator(\AppRow.bytes, order: .reverse)]
    @State private var dropTargeted = false

    var body: some View {
        let items = rows(matching: search).sorted(using: sort)

        Group {
            if items.isEmpty {
                if model.loadingApps {
                    ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if search.isEmpty {
                    ContentUnavailableView("No Apps", systemImage: "app.dashed", description: Text("Arin found no apps it can uninstall in /Applications or ~/Applications."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                table(items)
            }
        }
        .safeAreaBar(edge: .bottom) {
            Text("Drop an app here, or double-click one, to see what it keeps on your Mac. Apple's apps aren't listed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "app" else { return false }
            return model.prepareUninstall(url: url)
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Applications")
        .navigationSubtitle(subtitle(items))
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.loadApps() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Look for apps again")
                .disabled(model.loadingApps)
            }
            ToolbarItem {
                Button {
                    if let app = items.first(where: { rows.contains($0.id) })?.app { model.prepareUninstall(app) }
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .help("See the selected app's files and move them to the Trash")
                .disabled(rows.count != 1 || model.phase.isBusy)
            }
        }
        .task {
            if model.apps.isEmpty { await model.loadApps() }
        }
    }

    private func table(_ items: [AppRow]) -> some View {
        Table(items, selection: $rows, sortOrder: $sort) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("Size", value: \.bytes) { row in
                Group {
                    if row.bytes >= 0 {
                        Text(row.bytes.formattedBytes)
                    } else {
                        Text("Measuring…").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 84, ideal: 96, max: 120)

            TableColumn("Version", value: \.version) { row in
                Text(row.version).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90, max: 140)

            TableColumn("Source", value: \.source) { row in
                Text(row.source).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110, max: 180)

            TableColumn("Bundle ID", value: \.app.bundleID) { row in
                Text(row.app.bundleID)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 220)
        }
        .contextMenu(forSelectionType: AppRow.ID.self) { ids in
            if let row = items.first(where: { ids.contains($0.id) }), ids.count == 1 {
                Button("Uninstall…") { model.prepareUninstall(row.app) }
                    .disabled(model.phase.isBusy)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.app.path)]) }
            }
        } primaryAction: { ids in
            if let row = items.first(where: { ids.contains($0.id) }) { model.prepareUninstall(row.app) }
        }
    }

    private func rows(matching query: String) -> [AppRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return model.apps
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.bundleID.localizedStandardContains(query) }
            .map { AppRow(app: $0, bytes: model.appSizes[$0.path] ?? -1) }
    }

    private func subtitle(_ items: [AppRow]) -> String {
        let measured = items.filter { $0.bytes >= 0 }
        let total = measured.reduce(0) { $0 + $1.bytes }
        if measured.count < items.count {
            return "\(items.count) apps · measuring \(items.count - measured.count)…"
        }
        return "\(items.count) apps · \(total.formattedBytes)"
    }
}

/// A table row: the app plus its measured size (-1 until measured), so the table can sort by it.
struct AppRow: Identifiable {
    var app: InstalledApp
    var bytes: Int64

    var id: String { app.path }
    var name: String { app.name }
    var version: String { app.version ?? "" }
    var source: String { app.caskToken != nil ? "Homebrew" : app.fromAppStore ? "App Store" : "" }
}

/// The app's files, checked unless they need a look, and the button that moves them to the Trash.
struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var app: InstalledApp

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \(app.name)?")
                        .font(.title2.weight(.semibold))
                    Text([app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let files = model.uninstallFiles {
                list(files)
                footer(files)
            } else {
                ProgressView("Finding \(app.name)'s files…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    // Closes the sheet by clearing `uninstallApp`, after taking what it needs.
                    model.uninstall(app)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.uninstallFiles == nil || model.uninstallSelection.isEmpty || model.uninstallRefusal != nil)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .presentationSizing(.fitted)
    }

    private func list(_ files: [AppFile]) -> some View {
        @Bindable var model = model
        return List(files) { file in
            HStack(alignment: .top) {
                Toggle(isOn: Binding(
                    get: { model.uninstallSelection.contains(file.id) },
                    set: { on in
                        if on { model.uninstallSelection.insert(file.id) } else { model.uninstallSelection.remove(file.id) }
                    }
                )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.kind == .app ? "\(app.name) app" : file.kind.label)
                    Text((file.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    if let note = file.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(file.needsReview ? .orange : .secondary)
                    }
                }
                Spacer()
                Text(file.bytes.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            }
        }
        .frame(minHeight: 200)
    }

    @ViewBuilder
    private func footer(_ files: [AppFile]) -> some View {
        let picked = files.filter { model.uninstallSelection.contains($0.id) }
        if let refusal = model.uninstallRefusal {
            Label {
                Text(refusal)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        Text("\(picked.count) of \(files.count) items · \(picked.reduce(0) { $0 + $1.bytes }.formattedBytes). Checked items move to the Trash; put them back from History. Unchecked items matched by name or are shared, so look before you check them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

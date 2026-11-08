import ArinCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if model.sidebar == .history {
                    HistoryView()
                } else if model.report == nil {
                    WelcomeView()
                } else if model.sidebar == .insights {
                    InsightsView()
                } else if model.sidebar == .map {
                    SpaceMapView()
                } else {
                    CandidateList(items: model.candidates(for: model.sidebar))
                }
            }
            .safeAreaInset(edge: .bottom) { StatusBar() }
        }
        .toolbar { Toolbar() }
        .sheet(isPresented: $model.showingConfirm) { ConfirmSheet() }
        .sheet(isPresented: $model.showingResult) { ResultSheet() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }
            if model.report == nil {
                Section {
                    Label("Scan", systemImage: "magnifyingglass")
                        .tag(AppModel.SidebarItem.all)
                }
            } else {
                Section("Found") {
                    row(.all, "All", "square.grid.2x2", model.candidates.dedupedBytes)
                    Label("Space map", systemImage: "square.grid.3x1.below.line.grid.1x2")
                        .tag(AppModel.SidebarItem.map)
                    ForEach(model.categoriesWithResults, id: \.self) { category in
                        row(.category(category), category.label, category.symbol, model.bytes(for: category))
                    }
                }
                if let report = model.report, !report.insights.isEmpty || !report.ruleErrors.isEmpty {
                    Section {
                        Label("Insights", systemImage: "lightbulb")
                            .badge(report.insights.count + report.ruleErrors.count)
                            .tag(AppModel.SidebarItem.insights)
                    }
                }
            }
            Section {
                Label("History", systemImage: "clock")
                    .tag(AppModel.SidebarItem.history)
            }
        }
    }

    private func row(_ item: AppModel.SidebarItem, _ title: String, _ symbol: String, _ bytes: Int64) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(bytes.formattedBytes)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(item)
    }
}

private struct Toolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            Picker("Level", selection: $model.level) {
                ForEach(Level.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Quick: caches that refill on their own. Standard: adds build output and merged worktrees. Deep: simulator data, toolchains, app data.")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showingConfirm = true
            } label: {
                Text(model.selection.isEmpty ? "Clean" : "Clean \(model.selectedBytes.formattedBytes)")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase.isBusy || model.selection.isEmpty)
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Before the first scan finishes, the welcome screen shows progress and its own Stop button.
        if model.report != nil {
            HStack(spacing: 10) {
                if model.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if model.canStop {
                        Button("Stop") { model.stop() }
                            .help("Keeps the previous results")
                    }
                } else {
                    Text("\(model.selection.count) selected · \(model.selectedBytes.formattedBytes) estimated")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let report = model.report {
                        Text(summary(report))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Button("Rescan") { model.startScan() }
                    if model.agent != nil, !model.itemsNeedingReview.isEmpty {
                        Button(model.lastReview == nil ? "Review" : "Review again") { model.startReview() }
                            .help("Ask your agent to check the items the rules couldn't settle")
                    }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func summary(_ report: ScanReport) -> String {
        var text = "Scanned \(report.finishedAt.formatted(.relative(presentation: .named)))"
        if let review = model.lastReview {
            text += " · checked by \(review.agent)"
        }
        return text
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Find what's safe to delete")
                    .font(.largeTitle.weight(.semibold))
                Text("Arin knows where developer Macs hide space, checks each item before touching it, and lets your own coding agent weigh in.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(alignment: .top, spacing: 18) {
                step("1", "magnifyingglass", "Scan", "Caches, build output, merged worktrees, simulators, stale temp files. Read-only.")
                step("2", "sparkles", "Review", "Then Claude Code or Codex checks what the rules can't settle, read-only, and marks it safe, review, or keep.")
                step("3", "checkmark.circle", "You choose", "Only what you tick is removed. Arin re-checks open files and running apps first.")
            }
            .frame(maxWidth: 720)
            Group {
                if model.isScanning {
                    Button(role: .cancel) {
                        model.stop()
                    } label: {
                        Label("Stop Scan", systemImage: "stop.fill")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Scan this Mac", systemImage: "magnifyingglass")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase.isBusy)
                }
            }
            .controlSize(.extraLarge)

            if model.phase.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: String, _ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Step \(number): \(title). \(text)")
    }
}

private struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let report = model.report {
                ForEach(report.insights) { insight in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(insight.title, systemImage: "lightbulb").font(.headline)
                            Spacer()
                            if let bytes = insight.bytes { Text(bytes.formattedBytes).foregroundStyle(.secondary) }
                        }
                        Text(insight.detail).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(report.ruleErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, error in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(name, systemImage: "exclamationmark.triangle").font(.headline)
                        Text(error).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

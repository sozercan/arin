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
                    HistoryView().statusBar(model)
                } else if model.sidebar == .apps {
                    AppsView()
                } else if model.report == nil {
                    WelcomeView()
                } else if model.sidebar == .overview || model.sidebar == nil {
                    OverviewView()
                } else if model.sidebar == .insights {
                    InsightsView().statusBar(model)
                } else if model.sidebar == .map {
                    SpaceMapView().statusBar(model)
                } else {
                    CandidateList(title: model.sidebarTitle)
                }
            }
        }
        .toolbar { Toolbar() }
        .sheet(isPresented: $model.showingConfirm, onDismiss: { model.pendingClean = nil }) { ConfirmSheet() }
        .sheet(isPresented: $model.showingResult) { ResultSheet() }
        .sheet(item: $model.uninstallApp) { app in UninstallSheet(app: app) }
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
                if !model.remoteHosts.isEmpty {
                    Picker("Target", selection: Binding(
                        get: { model.target },
                        set: { model.selectTarget($0) }
                    )) {
                        Label("This Mac", systemImage: "laptopcomputer").tag(CleanupTarget.local)
                        ForEach(model.remoteHosts) { host in
                            Label(host.displayName, systemImage: "server.rack").tag(CleanupTarget.remote(host))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.phase.isBusy)
                    .selectionDisabled()
                }
                DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }
            Section {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                    .badge(overviewBadge)
                    .tag(AppModel.SidebarItem.overview)
            }
            if model.report != nil {
                Section("Browse") {
                    row(.all, "All Items", "square.grid.2x2", model.candidates.dedupedBytes)
                    Label("Space Map", systemImage: "square.grid.3x1.below.line.grid.1x2")
                        .tag(AppModel.SidebarItem.map)
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
                if !model.target.isRemote {
                    Label("Applications", systemImage: "xmark.app")
                        .tag(AppModel.SidebarItem.apps)
                }
            }
        }
    }

    private var overviewBadge: Text? {
        guard model.report != nil else { return nil }
        let safe = model.candidates(in: .safe).dedupedBytes
        return safe > 0 ? Text(safe.formattedBytes).monospacedDigit() : nil
    }

    private func row(_ item: AppModel.SidebarItem, _ title: String, _ symbol: String, _ bytes: Int64) -> some View {
        Label(title, systemImage: symbol)
            .badge(Text(bytes.formattedBytes).monospacedDigit())
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
            if model.canStop {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help(model.report == nil ? "Stop scanning" : "Stop; keeps the previous results")
            } else {
                Button { model.startScan() } label: {
                    Label(model.report == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .help(model.report == nil ? "Scan this Mac" : "Scan again")
                .disabled(model.phase.isBusy)
            }
            if model.agent != nil {
                Button { model.startReview() } label: { Label("Review", systemImage: "sparkles") }
                    .help(model.lastReview == nil ? "Ask your agent to check the items the rules couldn't settle" : "Ask your agent to check again")
                    .disabled(!model.canReview)
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showingConfirm = true
            } label: {
                Text(model.selection.isEmpty ? "Clean" : "Clean \(model.selectedBytes.formattedBytes)")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canClean)
        }
    }
}

extension View {
    func statusBar(_ model: AppModel) -> some View {
        safeAreaBar(edge: .bottom) { StatusBar(model: model) }
    }
}

private struct StatusBar: View {
    var model: AppModel

    var body: some View {
        if model.report != nil {
            HStack(spacing: 8) {
                if model.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("\(model.selection.count) selected · \(model.selectedBytes.formattedBytes) estimated")
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    if let report = model.report {
                        Text(summary(report)).lineLimit(1)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
                step("2", "sparkles", "Review", "Then Claude Code, Codex, or GitHub Copilot checks what the rules can't settle, read-only, and marks it safe, review, or keep.")
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
                        Label(model.target.isRemote ? "Scan \(model.target.displayName)" : "Scan this Mac", systemImage: "magnifyingglass")
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
        .navigationTitle("Arin")
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
        .card(padding: 0)
        .accessibilityLabel("Step \(number): \(title). \(text)")
    }
}

private struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report = model.report {
                    ForEach(report.insights) { insight in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(insight.title, systemImage: "lightbulb").font(.headline)
                                Spacer()
                                if let bytes = insight.bytes {
                                    Text(bytes.formattedBytes).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            Text(insight.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                    }
                    ForEach(report.ruleErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, error in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(name, systemImage: "exclamationmark.triangle").font(.headline)
                            Text(error)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Insights")
    }
}

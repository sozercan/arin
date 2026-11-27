import ArinCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            Group {
                if model.report == nil {
                    WelcomeView()
                } else {
                    switch model.sidebar {
                    case .overview, nil: OverviewView()
                    case let item?: CandidateList(items: model.candidates(for: item))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Before the first scan finishes, the welcome screen shows progress and its own Stop button.
                if model.report != nil { ActionBar() }
            }
        }
        .toolbar { Toolbar() }
        .tint(Theme.signature)
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
                DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold, findings: model.findingsByCategory)
                    .padding(.vertical, 8)
                    .selectionDisabled()
            }
            if let report = model.report {
                Section {
                    Label("Overview", systemImage: "circle.grid.2x2")
                        .badge(report.insights.count + report.ruleErrors.count)
                        .tag(AppModel.SidebarItem.overview)
                }
                Section("Found") {
                    row(.all, "All items", Image(systemName: "square.stack"), color: .secondary, model.candidates.dedupedBytes)
                    ForEach(model.categoriesWithResults, id: \.self) { category in
                        row(.category(category), category.label, Image(systemName: category.symbol), color: category.color, model.bytes(for: category))
                    }
                }
            }
        }
    }

    private func row(_ item: AppModel.SidebarItem, _ title: String, _ icon: Image, color: Color, _ bytes: Int64) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(bytes.formattedBytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            icon.foregroundStyle(color)
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
        if model.report != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.agent != nil {
                    Button {
                        model.startReview()
                    } label: {
                        Label(model.lastReview == nil ? "Review" : "Review Again", systemImage: "sparkles")
                    }
                    .disabled(model.phase.isBusy || model.itemsNeedingReview.isEmpty)
                    .help("Ask your agent to check the items the rules couldn't settle")
                }
                if model.canStop {
                    Button {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop and keep the previous results")
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.phase.isBusy)
                    .help("Scan again")
                }
            }
        }
    }
}

/// The selection and the Clean button, or progress while Arin is busy.
private struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.phase.isBusy {
                ProgressView().controlSize(.small)
                Text(model.phase.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.canStop {
                    Button("Stop") { model.stop() }
                        .help("Keeps the previous results")
                }
            } else {
                selectionIcons
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selection.isEmpty ? "Nothing selected" : "\(model.selection.count) \(model.selection.count == 1 ? "item" : "items") selected")
                        .font(.callout.weight(.medium))
                    Text(model.selection.isEmpty ? "Tick items to clean them" : "About \(model.selectedBytes.formattedBytes) by folder size")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !model.selection.isEmpty {
                    Button("Clear") { model.setAll(model.selectedCandidates, selected: false) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Spacer(minLength: 8)
                Button {
                    model.showingConfirm = true
                } label: {
                    Text(model.selection.isEmpty ? "Clean" : "Clean \(model.selectedBytes.formattedBytes)")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.selectedBytes)))
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.selection.isEmpty)
                .animation(.smooth, value: model.selectedBytes)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// Up to four category icons for what's selected.
    private var selectionIcons: some View {
        let categories = CleanupCategory.allCases.filter { c in model.selectedCandidates.contains { $0.category == c } }
        return HStack(spacing: -6) {
            if categories.isEmpty {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            ForEach(categories.prefix(4), id: \.self) { category in
                CategoryIcon(category: category, size: 28)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 18) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Theme.signature.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Theme.signature.opacity(0.35), radius: 14, y: 6)
                        .symbolEffect(.pulse, isActive: model.isScanning)
                    VStack(spacing: 8) {
                        Text("Find what's safe to delete")
                            .font(.largeTitle.weight(.semibold))
                        Text("Arin knows where developer Macs hide space, checks each item before touching it, and lets your own coding agent weigh in.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }

                DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold)
                    .frame(maxWidth: 420)
                    .card(padding: 18)
                    .frame(maxWidth: 420)

                HStack(alignment: .top, spacing: 14) {
                    step(1, "magnifyingglass", "Scan", "Caches, build output, merged worktrees, simulators, stale temp files. Read-only.")
                    step(2, "sparkles", "Review", "Claude Code or Codex checks what the rules can't settle, read-only, and marks it safe, review, or keep.")
                    step(3, "checkmark.circle", "You choose", "Only what you tick is removed. Arin re-checks open files and running apps first.")
                }
                .frame(maxWidth: 760)

                VStack(spacing: 12) {
                    if model.isScanning {
                        Button(role: .cancel) {
                            model.stop()
                        } label: {
                            Label("Stop Scan", systemImage: "stop.fill")
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button {
                            model.startScan()
                        } label: {
                            Label("Scan this Mac", systemImage: "magnifyingglass")
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.phase.isBusy)
                    }
                    if model.phase.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.phase.label).lineLimit(1)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.extraLarge)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            Theme.heroWash
                .frame(height: 360)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
    }

    private func step(_ number: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.signature)
                    .frame(width: 26, height: 26)
                    .background(Theme.signature.opacity(0.14), in: Circle())
                Label(title, systemImage: symbol)
                    .font(.headline)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 110, alignment: .topLeading)
        .card(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(text)")
    }
}

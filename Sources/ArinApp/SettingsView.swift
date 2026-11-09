import ArinCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingFolder = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Open at login")
                    Text("Keeps the menu bar gauge, low-space alerts, and Auto mode running after a restart.")
                }
                if model.launchAtLoginNeedsApproval {
                    Label {
                        Text("Allow Arin in System Settings → General → Login Items.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }

            Section("Alerts") {
                Stepper(value: $model.lowSpaceThresholdGB, in: 5 ... 500, step: 5) {
                    Text("Alert when free space drops below \(model.lowSpaceThresholdGB) GB")
                }
                Toggle(isOn: $model.autoMode) {
                    Text("Auto mode")
                    Text("Below the threshold, clean Quick-level safe caches automatically (at most hourly). Never touches projects, worktrees, or app data.")
                }
            }

            Section("Agent") {
                if model.installedAgents.isEmpty {
                    Text("No supported agent found. Install Claude Code (`claude`), Codex (`codex`), or GitHub Copilot (`copilot`).")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Review with", selection: $model.agent) {
                        ForEach(model.installedAgents) { Text($0.label).tag(Optional($0)) }
                        Text("None").tag(AgentProvider?.none)
                    }
                }
                if model.agent != nil {
                    Toggle("Review automatically after each scan", isOn: $model.autoReview)
                }
                if let agent = model.agent {
                    ReviewSetupRows(agent: agent)
                        .id(agent)
                }
                Text("Reviews are read-only and only return verdicts. Judging caches needs little reasoning, so the recommended setup keeps them cheap; with a Claude plan they count toward your plan's usage limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Worktrees") {
                Toggle("Detect squash merges with GitHub (`gh`)", isOn: $model.checkPullRequests)
                Toggle("Fetch remotes before checking merges", isOn: $model.fetchRemotes)
            }

            Section("Cleaning") {
                Toggle("Move to Trash instead of deleting", isOn: $model.trashInsteadOfDelete)
            }

            Section("Always kept") {
                if let error = model.keepListError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let entries = model.keepList?.entries, !entries.isEmpty {
                    ForEach(entries, id: \.id) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.title).lineLimit(1)
                                Text(entry.id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.setKept(entry.id, title: entry.title, false)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop keeping")
                                .accessibilityLabel("Stop keeping \(entry.title)")
                        }
                    }
                } else {
                    Text("Right-click an item and choose Always Keep to protect it from every cleanup.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Project folders") {
                ForEach(ScanOptions.defaultProjectRoots(home: NSHomeDirectory()), id: \.self) { root in
                    Text((root as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                }
                ForEach(model.extraProjectRoots, id: \.self) { root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button(role: .destructive) {
                            model.extraProjectRoots.removeAll { $0 == root }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { choosingFolder = true }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 640)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls { add(url) }
        }
        .onAppear {
            model.reloadKeepList()
            model.refreshLaunchAtLogin()
        }
    }

    /// Stored with `~` like the defaults above; the scanner expands it.
    private func add(_ url: URL) {
        let root = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        let trimmed = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        guard !model.extraProjectRoots.contains(trimmed) else { return }
        model.extraProjectRoots.append(trimmed)
    }
}

/// Model and effort for the selected agent, as two plain pickers.
private struct ReviewSetupRows: View {
    @Environment(AppModel.self) private var model
    var agent: AgentProvider
    @State private var customModel = false

    private static let useCLI = ""
    private static let custom = "\u{0}custom"

    var body: some View {
        let configured = agent.configuredDefaults()
        let stored = model.reviewModels[agent.rawValue] ?? ""
        let isPreset = agent.modelPresets.contains { $0.id == stored }
        let showCustom = customModel || (!stored.isEmpty && !isPreset)

        Picker("Model", selection: Binding(
            get: { showCustom ? Self.custom : stored },
            set: { choice in
                customModel = choice == Self.custom
                if choice != Self.custom { model.reviewModels[agent.rawValue] = choice }
            }
        )) {
            ForEach(agent.modelPresets, id: \.id) { preset in
                Text(preset.id == agent.defaultModel ? "\(preset.label) (recommended)" : preset.label).tag(preset.id)
            }
            Text(cliLabel(configured.model)).tag(Self.useCLI)
            Text("Custom…").tag(Self.custom)
        }

        if showCustom {
            TextField("Model name", text: Binding(
                get: { isPreset ? "" : stored },
                set: { model.reviewModels[agent.rawValue] = $0 }
            ), prompt: Text("e.g. claude-sonnet-5-5"))
        }

        Picker("Effort", selection: Binding(
            get: { model.reviewEfforts[agent.rawValue] ?? "" },
            set: { model.reviewEfforts[agent.rawValue] = $0 }
        )) {
            ForEach(AgentProvider.efforts, id: \.self) { effort in
                let label = AgentProvider.effortLabel(effort)
                Text(effort == agent.defaultEffort ? "\(label) (recommended)" : label).tag(effort)
            }
            Text(cliLabel(configured.effort.map(AgentProvider.effortLabel))).tag(Self.useCLI)
        }
    }

    private func cliLabel(_ value: String?) -> String {
        "Use \(agent.label)'s setting" + (value.map { " (\($0))" } ?? "")
    }
}

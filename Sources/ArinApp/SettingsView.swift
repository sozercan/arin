import ArinCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newRoot = ""

    var body: some View {
        @Bindable var model = model
        Form {
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
                    Text("No supported agent found. Install Claude Code (`claude`) or Codex (`codex`).")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Review with", selection: $model.agent) {
                        ForEach(model.installedAgents) { Text($0.label).tag(Optional($0)) }
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
                HStack {
                    TextField("Add folder, e.g. ~/work", text: $newRoot)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newRoot.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 560)
    }

    private func add() {
        let root = newRoot.trimmingCharacters(in: .whitespaces)
        guard !root.isEmpty, !model.extraProjectRoots.contains(root) else { return }
        model.extraProjectRoots.append(root)
        newRoot = ""
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

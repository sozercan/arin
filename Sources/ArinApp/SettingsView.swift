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
                ForEach(model.installedAgents) { agent in
                    LabeledContent(agent.label) {
                        HStack {
                            TextField("CLI default", text: Binding(
                                get: { model.reviewModels[agent.rawValue] ?? "" },
                                set: { model.reviewModels[agent.rawValue] = $0 }
                            ))
                            .frame(width: 140)
                            Picker("Effort", selection: Binding(
                                get: { model.reviewEfforts[agent.rawValue] ?? "" },
                                set: { model.reviewEfforts[agent.rawValue] = $0 }
                            )) {
                                Text("CLI default").tag("")
                                ForEach(AgentProvider.efforts, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                    }
                }
                Text("Model and effort for reviews. Judging caches needs little reasoning, so a cheaper setup is enough; signed in with a Claude plan, reviews count toward your plan's usage limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Reviews run read-only (Codex in its read-only sandbox, Claude Code with only read tools and no access to credentials or personal folders). The agent returns verdicts; it never runs cleanup.")
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

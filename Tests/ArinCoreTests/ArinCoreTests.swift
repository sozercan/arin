@testable import ArinCore
import Foundation
import Testing

/// A throwaway home directory so guardrails and the executor can be exercised for real.
struct Sandbox {
    let root: String

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        root = "\(base)/arin-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    var guardrails: Guardrails { Guardrails(home: root, tmpDir: "\(root)/tmp") }

    func mkdir(_ rel: String) throws -> String {
        let path = "\(root)/\(rel)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func write(_ rel: String, _ text: String = "x") throws -> String {
        let path = "\(root)/\(rel)"
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func cleanup() {
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", root]).waitUntilExit()
        try? FileManager.default.removeItem(atPath: root)
    }
}

func git(_ dir: String, _ args: String...) async throws {
    let result = await Shell.run("git", ["-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args, timeout: 30)
    guard result.ok else { throw CLIFailure(message: "git \(args.joined(separator: " ")): \(result.stderr)") }
}

struct CLIFailure: Error { var message: String }

@Suite struct GuardrailTests {
    let g = Guardrails(home: "/Users/test", tmpDir: "/var/folders/ab/cdef/T/")

    @Test func allowsCachesAndTemp() throws {
        try g.check("/Users/test/Library/Caches/go-build")
        try g.check("/Users/test/projects/app/node_modules")
        try g.check("/var/folders/ab/cdef/T/build-cache")
        try g.check("/private/var/folders/ab/cdef/X/com.google.Chrome.code_sign_clone/x")
        try g.check("/private/tmp/scratch")
    }

    @Test func refusesTopLevelAndOutside() {
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/projects") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/System/Library/AssetsV2/x") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/other/Library/Caches") }
        #expect(throws: Guardrails.Violation.self) { try g.check("relative/path") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Caches/../../Documents/x") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/private/tmp") }
    }

    @Test func refusesProtectedAndTheirAncestors() {
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Documents/notes") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Messages/Attachments") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw") }
        // Deleting a parent would take the protected folder with it.
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Application Support") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Metadata") }
    }
}

@Suite struct RiskTests {
    func candidate(_ category: CleanupCategory = .devCaches, risk: Risk = .safe, blockers: [String] = []) -> Candidate {
        Candidate(ruleID: "t", title: "t", detail: "", category: category, level: .quick, risk: risk,
                  bytes: 1, paths: ["/x"], action: .delete(["/x"]), blockers: blockers)
    }

    @Test func agentCanRaiseButNotLowerKnownRules() {
        var c = candidate()
        c.agentVerdict = AgentVerdict(risk: .keep, reason: "", agent: "a")
        #expect(c.effectiveRisk == .keep)

        var r = candidate(risk: .review)
        r.agentVerdict = AgentVerdict(risk: .safe, reason: "", agent: "a")
        #expect(r.effectiveRisk == .review)
    }

    @Test func agentDecidesUnclassified() {
        var c = candidate(.unclassified, risk: .review)
        c.agentVerdict = AgentVerdict(risk: .safe, reason: "", agent: "a")
        #expect(c.effectiveRisk == .safe)
        #expect(c.isDefaultSelected(at: .quick))
    }

    @Test func blockersPreventSelection() {
        let c = candidate(blockers: ["Chrome is running"])
        #expect(c.effectiveRisk == .review)
        #expect(!c.isDefaultSelected(at: .deep))
    }

    @Test func levelGatesSelection() {
        var c = candidate()
        c.level = .deep
        #expect(!c.isDefaultSelected(at: .standard))
        #expect(c.isDefaultSelected(at: .deep))
    }

    @Test func dedupedBytesSkipsNestedPaths() {
        var outer = candidate()
        outer.paths = ["/a/wt"]
        outer.bytes = 100
        var inner = candidate()
        inner.id = "inner"
        inner.paths = ["/a/wt/node_modules"]
        inner.bytes = 60
        #expect([outer, inner].dedupedBytes == 100)
    }
}

@Suite struct ExecutorTests {
    @Test func deletesReadOnlyTrees() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let cache = try box.mkdir("Library/Caches/gomod/pkg@v1")
        _ = try box.write("Library/Caches/gomod/pkg@v1/a.go")
        // Go marks module files and dirs read-only; plain removal fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(cache)/a.go")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache)

        let target = "\(box.root)/Library/Caches/gomod"
        let executor = Executor(guardrails: box.guardrails)
        let errors = await executor.delete([target])
        #expect(errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func refusesGuardedPaths() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let docs = try box.write("Documents/keep.txt")
        let executor = Executor(guardrails: box.guardrails)
        let candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                                  bytes: 1, paths: [docs], action: .delete([docs]))
        let result = await executor.clean(candidate, state: .empty)
        #expect(result.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: docs))
    }

    @Test func refusesUnlistedCommands() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let executor = Executor(guardrails: box.guardrails)
        let candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                                  bytes: 1, paths: [], action: .commands([CommandSpec("rm", ["-rf", box.root])]))
        let result = await executor.clean(candidate, state: .empty)
        #expect(result.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: box.root))
    }

    @Test func skipsWhenBlockingProcessRuns() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let path = try box.mkdir("Library/Caches/Google/Chrome")
        let executor = Executor(guardrails: box.guardrails)
        var candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .appCaches, level: .quick, risk: .safe,
                                  bytes: 1, paths: [path], action: .delete([path]))
        candidate.blockingProcesses = ["Google Chrome"]
        let state = SystemState(processPaths: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"], openPaths: [])
        let result = await executor.clean(candidate, state: state)
        #expect(result.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite struct WorktreeTests {
    /// main repo + three linked worktrees: merged & clean, merged & dirty, unmerged.
    @Test func classifiesAndRemovesWorktrees() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let repo = try box.mkdir("projects/app")
        try await git(repo, "init", "-q", "-b", "main")
        _ = try box.write("projects/app/.gitignore", "bin/\n")
        _ = try box.write("projects/app/README", "hi")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "-q", "-m", "init")

        for name in ["merged", "dirty", "unmerged"] {
            try await git(repo, "worktree", "add", "-q", "-b", name, "\(box.root)/projects/app.\(name)")
        }
        // Unmerged work.
        _ = try box.write("projects/app.unmerged/feature.txt")
        try await git("\(box.root)/projects/app.unmerged", "add", ".")
        try await git("\(box.root)/projects/app.unmerged", "commit", "-q", "-m", "feature")
        // Uncommitted edit on a merged branch.
        _ = try box.write("projects/app.dirty/README", "edited")
        // Read-only ignored tool binaries (envtest) inside the merged worktree.
        let k8s = try box.mkdir("projects/app.merged/bin/k8s")
        _ = try box.write("projects/app.merged/bin/k8s/etcd")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: "\(k8s)/etcd")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: k8s)

        let options = ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: ["\(box.root)/projects"],
                                  checkPullRequests: false, minimumBytes: 0)
        let ctx = ScanContext(options: options, state: .empty, now: Date())
        let found = await WorktreeRule.scanRepo(repo, ctx: ctx)
        let byName = Dictionary(uniqueKeysWithValues: found.map { (($0.paths.first ?? "") as NSString).lastPathComponent }
            .enumerated().map { ($1, found[$0]) })

        #expect(byName["app.merged"]?.effectiveRisk == .safe)
        #expect(byName["app.dirty"]?.effectiveRisk == .review)
        #expect(byName["app.unmerged"] == nil)

        let merged = try #require(byName["app.merged"])
        let result = await Executor(guardrails: box.guardrails).clean(merged, state: .empty)
        #expect(result.status == .cleaned, "\(result.message)")
        #expect(!FileManager.default.fileExists(atPath: "\(box.root)/projects/app.merged"))
        let branches = await Shell.run("git", ["-C", repo, "branch", "--list", "merged"])
        #expect(branches.stdout.contains("merged"), "branch is kept")

        // Dirty worktrees are refused by git even if the user ticks them.
        let dirty = try #require(byName["app.dirty"])
        let refused = await Executor(guardrails: box.guardrails).clean(dirty, state: .empty)
        #expect(refused.status == .failed)
        #expect(FileManager.default.fileExists(atPath: "\(box.root)/projects/app.dirty/README"))
    }

    @Test func parsesPorcelain() {
        let out = """
        worktree /r
        HEAD abc
        branch refs/heads/main

        worktree /r.x
        HEAD def
        branch refs/heads/feat/x
        locked agent

        worktree /gone
        HEAD 123
        detached
        prunable gitdir file points to non-existent location

        """
        let entries = WorktreeEntry.parse(out)
        #expect(entries.count == 3)
        #expect(entries[1].branch == "feat/x")
        #expect(entries[1].locked)
        #expect(entries[2].prunable)
        #expect(entries[2].branch == nil)
    }
}

@Suite struct ParsingTests {
    @Test func parsesVerdictsAroundProse() throws {
        let raw = """
        Here you go:
        ```json
        {"verdicts":[{"id":"a","verdict":"safe","reason":"cache"},{"id":"b","verdict":"maybe","reason":"?"},{"id":"c","verdict":"KEEP","reason":"notes"}]}
        ```
        """
        let verdicts = try AgentReviewer.parseVerdicts(raw, agent: "Test")
        #expect(verdicts["a"]?.risk == .safe)
        #expect(verdicts["b"] == nil)
        #expect(verdicts["c"]?.risk == .keep)
    }

    @Test func rejectsGarbage() {
        #expect(throws: AgentReviewError.self) { try AgentReviewer.parseVerdicts("no json", agent: "Test") }
    }

    @Test func parsesDu() {
        let rows = Size.parseDu("12\t/a b/c\n  4\t/d\nbad line\n")
        #expect(rows.count == 2)
        #expect(rows[0].0 == "/a b/c" && rows[0].1 == 12)
    }

    @Test func parsesDockerSizes() {
        #expect(DockerRule.parseSize("6.1GB") == 6_100_000_000)
        #expect(DockerRule.parseSize("512MB") == 512_000_000)
        #expect(DockerRule.parseSize("1.2kB") == 1200)
        #expect(DockerRule.parseSize("0B") == 0)
        #expect(DockerRule.parseSize("3.6GB (100%)") == 3_600_000_000)
    }

    @Test func detectsOrphanedBuildxVolumes() {
        let builders: Set<String> = ["remote-vm", "default", "desktop-linux"]
        #expect(DockerRule.orphanedBuildxVolume("buildx_buildkit_container-builder0_state", builders: builders))
        #expect(!DockerRule.orphanedBuildxVolume("buildx_buildkit_remote-vm0_state", builders: builders))
        #expect(!DockerRule.orphanedBuildxVolume("postgres-data", builders: builders))
    }

    @Test func prefersReleaseRuntimeOverBeta() {
        let release = SimRuntime(identifier: "r", version: "27.2", build: "24B8117")
        let beta = SimRuntime(identifier: "b", version: "27.2", build: "24B91016s")
        let old = SimRuntime(identifier: "o", version: "27.0", build: "24A100")
        #expect(SimulatorRuntimeRule.isNewer(release, than: beta))
        #expect(!SimulatorRuntimeRule.isNewer(beta, than: release))
        #expect(SimulatorRuntimeRule.isNewer(beta, than: old))
    }

    @Test func runtimeNames() {
        #expect(Simctl.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-2") == "iOS 27.2")
    }

    @Test func appMatchingIsLoose() {
        let state = SystemState(processPaths: ["/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Electron",
                                               "/Users/u/.local/share/claude/versions/2.1"], openPaths: [])
        #expect(state.isAppRunning(matching: "Code - Insiders"))
        #expect(!state.isAppRunning(matching: "Claude"), "CLI binaries outside an .app don't count")
        #expect(state.runningAny(["app:Code - Insiders", "go"]) == ["Code - Insiders"])
    }

    @Test func busyDirectoriesIncludeAncestors() {
        let state = SystemState(processPaths: [], openPaths: ["/tmp/a/b/c.log"])
        #expect(state.isBusy("/tmp/a"))
        #expect(state.isBusy("/tmp/a/b"))
        #expect(!state.isBusy("/tmp/z"))
    }
}

@Suite struct ReviewerArgumentTests {
    @Test func claudeArgsPinModelEffortAndDenyPrivatePaths() {
        let args = AgentReviewer.claudeArguments(model: "sonnet", effort: "low", home: "/Users/test")
        #expect(args.contains("--model") && args[args.firstIndex(of: "--model")! + 1] == "sonnet")
        #expect(args[args.firstIndex(of: "--effort")! + 1] == "low")
        #expect(args.contains("Read(~/.ssh/**)"))
        #expect(args.contains("Read(~/.aws)"))
        #expect(args.contains("Read(~/Library/Keychains/**)"))
        // Nothing that can print file contents or write is pre-approved for Bash.
        let bash = args.filter { $0.hasPrefix("Bash(") }
        #expect(!bash.contains { $0.contains("head") || $0.contains("cat") || $0.contains("find") || $0.contains("rm") })
        let deny = args.firstIndex(of: "--disallowedTools")!
        let allow = args.firstIndex(of: "--allowedTools")!
        #expect(allow < deny)
    }

    @Test func defaultsFallBackToCLIConfig() {
        let reviewer = AgentReviewer(provider: .codex, model: "  ", effort: "")
        #expect(reviewer.model == nil && reviewer.effort == nil)
        let args = AgentReviewer.codexArguments(model: nil, effort: "low", cwd: "/t", schemaPath: "/t/s", outPath: "/t/o")
        #expect(!args.contains("-m"))
        #expect(args.contains("model_reasoning_effort=\"low\""))
        #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
    }

    @Test func copilotArgsExposeOnlyReadToolsAndGivenDirs() {
        let args = AgentReviewer.copilotArguments(model: "claude-sonnet-5.5", effort: "low", dirs: ["/h/go/pkg/mod"])
        #expect(args[args.firstIndex(of: "--model")! + 1] == "claude-sonnet-5.5")
        #expect(args[args.firstIndex(of: "--reasoning-effort")! + 1] == "low")
        #expect(args[args.firstIndex(of: "--add-dir")! + 1] == "/h/go/pkg/mod")
        #expect(!args.contains { $0.hasPrefix("--allow-all") || $0 == "--yolo" })
        let start = args.firstIndex(of: "--available-tools")! + 1
        let tools = args[start...].prefix { !$0.hasPrefix("--") }
        #expect(Set(tools) == ["view", "glob", "grep", "bash", "read_bash"])
        let shell = args.filter { $0.hasPrefix("shell(") }
        #expect(shell.contains("shell(git status)"))
        // Copilot matches git on the first subcommand, so this would also allow `git worktree remove`.
        #expect(!shell.contains { $0.contains("worktree") || $0.contains("cat") || $0.contains("rm") })
        let bare = AgentReviewer.copilotArguments(model: nil, effort: nil, dirs: [])
        #expect(!bare.contains("--model") && !bare.contains("--reasoning-effort") && !bare.contains("--add-dir"))
    }

    @Test func copilotNeverGetsHomeOrPrivateFolders() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("arin-dirs-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        for dir in ["go/pkg/mod", "Library/Caches/foo", "Library/Keychains/x", "Documents/secret", ".ssh"] {
            try fm.createDirectory(atPath: "\(home)/\(dir)", withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: "\(home)/Library/Caches/docs", withDestinationPath: "\(home)/Documents")
        try fm.createSymbolicLink(atPath: "\(home)/Library/Caches/keys", withDestinationPath: "../../.ssh")
        try "x".write(toFile: "\(home)/Library/Caches/file.txt", atomically: true, encoding: .utf8)
        func candidate(_ paths: [String]) -> Candidate {
            Candidate(ruleID: "t", key: paths[0], title: "t", detail: "", category: .unclassified, level: .deep,
                      risk: .review, bytes: 1, paths: paths, action: .delete(paths))
        }
        let dirs = AgentReviewer.copilotDirs(for: [
            candidate(["\(home)/go/pkg/mod", "\(home)/go/pkg/mod/", "\(home)/GO/pkg/mod"]),
            candidate([home, "\(home)/"]),
            candidate(["\(home)/.ssh", "\(home)/Library", "\(home)/Library/Keychains/x"]),
            // Symlinks and case aliases into private folders.
            candidate(["\(home)/Library/Caches/docs/secret", "\(home)/Library/Caches/keys", "\(home)/documents/secret"]),
            candidate(["\(home)/Library/Caches/foo", "\(home)/Library/Caches/file.txt", "\(home)/missing"]),
            candidate(["docker-volume-name", "/"]),
        ], home: home)
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        #expect(dirs.map(real) == ["\(home)/go/pkg/mod", "\(home)/Library/Caches/foo"].map(real))
    }
}

@Suite struct CancellationTests {
    @Test func cancellingKillsTheSubprocess() async {
        let started = Date()
        let task = Task { await Shell.run("sleep", ["30"], timeout: 60) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!result.ok)
    }

    @Test func cancelledTasksDontStartProcesses() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Shell.run("sleep", ["30"])
        }
        let result = await task.value
        #expect(result.stderr == "cancelled")
    }
}

@Suite struct ConfigReadingTests {
    @Test func readsTopLevelTomlOnly() {
        let toml = """
        model = "gpt-x"
        model_reasoning_effort = 'xhigh'
        [profiles.fast]
        model = "other"
        """
        #expect(AgentProvider.tomlTopLevel(toml, key: "model") == "gpt-x")
        #expect(AgentProvider.tomlTopLevel(toml, key: "model_reasoning_effort") == "xhigh")
        #expect(AgentProvider.tomlTopLevel("[a]\nmodel = \"x\"", key: "model") == nil)
    }

    @Test func readsCopilotSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("arin-copilot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        try #"{"model":"gpt-x","effortLevel":"medium"}"#.write(
            to: home.appendingPathComponent(".copilot/settings.json"), atomically: true, encoding: .utf8
        )
        let configured = AgentProvider.copilot.configuredDefaults(home: home.path)
        #expect(configured.model == "gpt-x" && configured.effort == "medium")
    }
}

@Suite struct HomeOverviewTests {
    let gb: Int64 = 1024 * 1024 * 1024

    func pick(_ sizes: [String: Int64], top: String, avoid: [String] = [], skip: [String] = []) -> [String] {
        HomeOverview.pick(top, sizes: sizes, depth: 0, avoid: avoid) { path in
            skip.contains { path == $0 || path.hasPrefix($0 + "/") }
        }.sorted()
    }

    @Test func drillsIntoTheFolderThatHoldsTheSpace() {
        let sizes: [String: Int64] = [
            "/h/.t3": 70 * gb,
            "/h/.t3/worktrees": 5 * gb,
            "/h/.t3/userdata": 65 * gb,
            "/h/.t3/userdata/task-artifacts": 63 * gb,
            "/h/.t3/userdata/task-artifacts/app": 63 * gb,
            "/h/.t3/userdata/task-artifacts/app/perf": 63 * gb,
        ]
        #expect(pick(sizes, top: "/h/.t3", skip: ["/h/.t3/worktrees"]) == ["/h/.t3/userdata/task-artifacts/app/perf"])
    }

    @Test func reportsSiblingsSeparately() {
        let sizes: [String: Int64] = ["/h/.x": 6 * gb, "/h/.x/a": 3 * gb, "/h/.x/b": 2 * gb, "/h/.x/c": gb / 2]
        #expect(pick(sizes, top: "/h/.x") == ["/h/.x/a", "/h/.x/b"])
    }

    @Test func neverReportsClaimedPathsOrTheirParents() {
        let sizes: [String: Int64] = [
            "/h/.codex": 10 * gb,
            "/h/.codex/packages": 4 * gb,
            "/h/.codex/packages/standalone": 4 * gb,
            "/h/.codex/packages/standalone/releases": 4 * gb,
            "/h/.codex/reviews": 3 * gb,
        ]
        let picked = pick(sizes, top: "/h/.codex", avoid: ["/h/.codex/packages/standalone/releases"])
        #expect(picked == ["/h/.codex/reviews"])
    }

    @Test func ignoresSmallFolders() {
        #expect(pick(["/h/.y": gb / 2], top: "/h/.y").isEmpty)
    }
}

@Suite struct CaseTests {
    @Test func resolvesOnDiskSpelling() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("Library/Caches/yarn")
        let resolved = FileInfo.actualCase("\(box.root)/Library/Caches/Yarn")
        #expect(resolved.hasSuffix("/Library/Caches/yarn"))
    }
}

@Suite struct TempRuleTests {
    @Test func detectsNestedCheckouts() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("scratch/wt-verify/.git")
        _ = try box.mkdir("plain/dd/Build")
        #expect(await FileInfo.containsGitCheckout("\(box.root)/scratch"))
        #expect(!(await FileInfo.containsGitCheckout("\(box.root)/plain")))
    }
}

@Suite struct TempRulePackageTests {
    @Test func ignoresPackageCheckouts() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("dd/SourcePackages/checkouts/swift-log/.git")
        #expect(!(await FileInfo.containsGitCheckout("\(box.root)/dd")))
    }
}

@Suite struct CommandOutcomeTests {
    @Test func failingCommandThatEmptiedTargetsCountsAsCleaned() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let cache = try box.mkdir("Library/Caches/tool")
        let emptied = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                                bytes: 100 * 1024 * 1024, paths: [cache], action: .none)
        #expect(await Executor.targetsMostlyGone(emptied))

        _ = try box.write("Library/Caches/tool/blob", String(repeating: "x", count: 200_000))
        var full = emptied
        full.bytes = 100 * 1024
        #expect(!(await Executor.targetsMostlyGone(full)))
    }
}

@Suite struct ReviewFindingRegressionTests {
    @Test func symlinkedAncestorIntoProtectedFolderIsRefused() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let target = try box.mkdir("Documents/Google/Chrome")
        _ = try box.mkdir("Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/Library/Caches/Google", withDestinationPath: "\(box.root)/Documents/Google")
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.check("\(box.root)/Library/Caches/Google/Chrome") }
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test func symlinkLeafIsRemovedWithoutTouchingTarget() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let keep = try box.write("projects/real/keep.txt")
        _ = try box.mkdir("Library/Caches")
        let link = "\(box.root)/Library/Caches/linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "\(box.root)/projects/real")
        let errors = await Executor(guardrails: box.guardrails).delete([link])
        #expect(errors.isEmpty)
        #expect(!FileInfo.isSymlink(link))
        #expect(FileManager.default.fileExists(atPath: keep))
    }

    @Test func nativeCommandsRespectPathGuardrails() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let modcache = try box.mkdir("Documents/gomod")
        let candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                                  bytes: 1, paths: [modcache], action: .commands([CommandSpec("go", ["clean", "-modcache"])]))
        let result = await Executor(guardrails: box.guardrails).clean(candidate, state: .empty)
        #expect(result.status == .skipped)
    }

    @Test func deepRecentWriteBlocksCleanup() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let root = try box.mkdir("Library/Caches/scratch")
        _ = try box.write("Library/Caches/scratch/a/b/c/d/fresh.log")
        // Make the top levels look old so only a deep check sees the write.
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        for rel in ["Library/Caches/scratch/a/b/c/d", "Library/Caches/scratch/a/b/c", "Library/Caches/scratch/a/b", "Library/Caches/scratch/a", "Library/Caches/scratch"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: "\(box.root)/\(rel)")
        }
        var candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .temp, level: .quick, risk: .safe,
                                  bytes: 1, paths: [root], action: .delete([root]))
        candidate.minIdleSeconds = 3 * 3600
        let result = await Executor(guardrails: box.guardrails).clean(candidate, state: .empty)
        #expect(result.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: root))
    }

    @Test func checkoutsAreFoundAtAnyDepthAndUnderGenericNames() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("deep/a/b/c/d/e/repo/.git")
        _ = try box.mkdir("named/checkouts/my-project/.git")
        _ = try box.mkdir("gopkg/pkg/my-project/.git")
        _ = try box.mkdir("dd/SourcePackages/checkouts/swift-log/.git")
        _ = try box.mkdir("gomod/pkg/mod/github.com/x/y/.git")
        #expect(await FileInfo.containsGitCheckout("\(box.root)/deep"))
        #expect(await FileInfo.containsGitCheckout("\(box.root)/named"))
        #expect(await FileInfo.containsGitCheckout("\(box.root)/gopkg"))
        #expect(!(await FileInfo.containsGitCheckout("\(box.root)/dd")))
        #expect(!(await FileInfo.containsGitCheckout("\(box.root)/gomod")))
    }

    @Test func binToolFolderWithCheckoutNeedsReview() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("repo/bin/tools/.git")
        let (generated, note) = ProjectArtifactRule.binLooksGenerated("\(box.root)/repo/bin")
        #expect(!generated)
        #expect(note.contains("git checkout"))
    }

    @Test func overviewNeverEntersCheckouts() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let gb: Int64 = 1024 * 1024 * 1024
        let top = try box.mkdir(".tools")
        let repo = try box.mkdir(".tools/src/app")
        _ = try box.mkdir(".tools/src/app/.git")
        let sizes: [String: Int64] = [top: 5 * gb, "\(top)/src": 5 * gb, repo: 5 * gb, "\(repo)/.git": 4 * gb]
        let picked = HomeOverview.pick(top, sizes: sizes, depth: 0, avoid: []) { _ in false }
        #expect(picked.isEmpty)
    }

    @Test func protectedPathsIgnoreCase() {
        let g = Guardrails(home: "/Users/test", tmpDir: "/var/folders/ab/cdef/T/")
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/messages") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/documents/notes") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/users/TEST/.SSH/id_ed25519") }
    }

    @Test func nativeCommandsCheckSymlinkTargets() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let target = try box.write("Documents/logs.sqlite")
        let link = "\(box.root)/.codex/logs_1.sqlite"
        _ = try box.mkdir(".codex")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let candidate = Candidate(ruleID: "t", title: "t", detail: "", category: .agentData, level: .deep, risk: .review,
                                  bytes: 1, paths: [link], action: .commands([CommandSpec("sqlite3", [link, "VACUUM;"])]))
        let result = await Executor(guardrails: box.guardrails).clean(candidate, state: .empty)
        #expect(result.status == .skipped, "\(result.message)")
        // Deleting the link itself is still fine: delete unlinks, it never follows.
        try box.guardrails.check(link)
    }

    @Test func unreadableSubtreesFailClosed() async throws {
        let box = try Sandbox()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(box.root)/scratch/locked")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(box.root)/repo/bin/tools/locked")
            box.cleanup()
        }
        _ = try box.mkdir("scratch/locked/inner")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(box.root)/scratch/locked")
        #expect(await FileInfo.containsGitCheckout("\(box.root)/scratch"))
        #expect(await FileInfo.hasRecentWrites("\(box.root)/scratch", within: 60))
        #expect(!(await FileInfo.hasRecentWrites("\(box.root)/missing", within: 60)))

        _ = try box.mkdir("repo/bin/tools/locked/inner")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(box.root)/repo/bin/tools/locked")
        let (generated, note) = ProjectArtifactRule.binLooksGenerated("\(box.root)/repo/bin")
        #expect(!generated)
        #expect(note.contains("could not be read"), "\(note)")
    }

    @Test func worktreeWithNewCommitsSinceScanIsKept() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let repo = try box.mkdir("projects/app")
        try await git(repo, "init", "-q", "-b", "main")
        _ = try box.write("projects/app/README", "hi")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "-q", "-m", "init")
        let wt = "\(box.root)/projects/app.feature"
        try await git(repo, "worktree", "add", "-q", "-b", "feature", wt)

        let options = ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: ["\(box.root)/projects"],
                                  checkPullRequests: false, minimumBytes: 0)
        let found = await WorktreeRule.scanRepo(repo, ctx: ScanContext(options: options, state: .empty, now: Date()))
        let candidate = try #require(found.first { (($0.paths.first ?? "") as NSString).lastPathComponent == "app.feature" })
        #expect(candidate.effectiveRisk == .safe)

        // New, committed (so clean) work after the scan.
        _ = try box.write("projects/app.feature/feature.txt")
        try await git(wt, "add", ".")
        try await git(wt, "commit", "-q", "-m", "feature")
        let result = await Executor(guardrails: box.guardrails).clean(candidate, state: .empty)
        #expect(result.status == .skipped, "\(result.message)")
        #expect(FileManager.default.fileExists(atPath: "\(wt)/feature.txt"))
    }

    @Test func reviewerShellAllowlistHasNoWritableOptions() {
        let bash = AgentReviewer.claudeArguments(model: nil, effort: nil, home: "/h").filter { $0.hasPrefix("Bash(") }
        #expect(!bash.contains { $0.contains("file") || $0.contains("git log") })
        #expect(AgentReviewer(provider: .claude, maxCandidates: -1).maxCandidates == 0)
    }
}

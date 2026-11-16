@testable import ArinCore
import Foundation
import Testing

private func run(_ tool: String, _ args: [String], cwd: String? = nil) async throws {
    let result = await Shell.run(tool, args, cwd: cwd, timeout: 60)
    guard result.ok else { throw CLIFailure(message: "\(tool) \(args.joined(separator: " ")): \(result.stderr)") }
}

@Suite struct DiskUsageTests {
    @Test func clonesCountOnlyTheirPrivateBlocksUnlessTheWholeFamilyIsInside() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let data = String(repeating: "0123456789abcdef", count: 64 * 1024) // 1 MiB
        let original = try box.write("store/blob", data)
        _ = try box.mkdir("project")
        _ = try box.mkdir("pair")
        try await run("cp", ["-c", original, "\(box.root)/project/blob"])
        try await run("cp", ["-c", original, "\(box.root)/pair/a"])
        try await run("cp", ["-c", "\(box.root)/pair/a", "\(box.root)/pair/b"])
        _ = try box.write("plain/blob", data)

        let sizes = await Size.allocated(["\(box.root)/project", "\(box.root)/plain", "\(box.root)/pair"])
        let mib: Int64 = 1024 * 1024
        let project = try #require(sizes["\(box.root)/project"])
        let plainSize = try #require(sizes["\(box.root)/plain"])
        // A clone whose source stays behind frees almost nothing.
        #expect(project < mib / 4, "\(project)")
        #expect(plainSize >= mib, "\(plainSize)")
        // `du` sees the clone in full.
        let du = await Shell.run("du", ["-sk", "\(box.root)/project"], timeout: 30)
        #expect((Int64(du.stdout.split(separator: "\t").first ?? "0") ?? 0) * 1024 >= mib)
    }

    @Test func aFamilyWhollyInsideCountsItsSharedBlocksOnce() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let data = String(repeating: "0123456789abcdef", count: 64 * 1024)
        let a = try box.write("family/a", data)
        try await run("cp", ["-c", a, "\(box.root)/family/b"])
        let mib: Int64 = 1024 * 1024
        let size = try #require(await Size.allocated(["\(box.root)/family"])["\(box.root)/family"])
        #expect(size >= mib && size < 2 * mib, "\(size)")
    }

    @Test func hardLinksCountOnce() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let a = try box.write("linked/a", String(repeating: "x", count: 1024 * 1024))
        try FileManager.default.linkItem(atPath: a, toPath: "\(box.root)/linked/b")
        let size = try #require(await Size.allocated(["\(box.root)/linked"])["\(box.root)/linked"])
        #expect(size >= 1024 * 1024 && size < 2 * 1024 * 1024, "\(size)")
    }
}

/// A repo with one commit, tagged 1.0.0.
private func makeRepo(_ box: Sandbox, _ rel: String) async throws -> String {
    let repo = try box.mkdir(rel)
    try await git(repo, "init", "-q", "-b", "main")
    _ = try box.write("\(rel)/README", "hi")
    try await git(repo, "add", ".")
    try await git(repo, "commit", "-q", "-m", "init")
    try await git(repo, "tag", "1.0.0")
    return repo
}

/// SwiftPM's layout in `<folder>`: a bare mirror in `repositories` and a checkout cloned from it,
/// detached at the pinned tag, as `swift package resolve` leaves them.
private func makeSwiftPMClones(_ box: Sandbox, in folder: String, source: String) async throws -> String {
    let mirror = "\(box.root)/\(folder)/repositories/dep-0d6739d0"
    let checkout = "\(box.root)/\(folder)/checkouts/dep"
    _ = try box.mkdir("\(folder)/repositories")
    _ = try box.mkdir("\(folder)/checkouts")
    try await git(box.root, "clone", "-q", "--mirror", source, mirror)
    try await git(box.root, "clone", "-q", mirror, checkout)
    try await git(checkout, "checkout", "-q", "--detach", "1.0.0")
    return checkout
}

private func mergedWorktree(_ box: Sandbox) async throws -> (repo: String, worktree: String) {
    let repo = try await makeRepo(box, "projects/app")
    _ = try box.write("projects/app/.gitignore", "scratch/\n")
    try await git(repo, "add", ".")
    try await git(repo, "commit", "-q", "-m", "ignore scratch")
    let wt = "\(box.root)/projects/app.done"
    try await git(repo, "worktree", "add", "-q", "-b", "done", wt)
    return (repo, wt)
}

private func scanWorktree(_ box: Sandbox, repo: String, path: String) async throws -> Candidate {
    let options = ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: ["\(box.root)/projects"],
                              checkPullRequests: false, minimumBytes: 0, keepListURL: nil)
    let found = await WorktreeRule.scanRepo(repo, ctx: ScanContext(options: options, state: .empty, now: Date()))
    // git reports the real path (/private/var/…), so match by name.
    let name = (path as NSString).lastPathComponent
    return try #require(found.first { (($0.paths.first ?? "") as NSString).lastPathComponent == name }, "\(found.map(\.paths))")
}

@Suite struct RepositoryDetectionTests {
    @Test func findsBareClonesAndBorrowedGitDirectories() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let source = try await makeRepo(box, "src")
        _ = try box.mkdir("scratch")
        try await git(box.root, "clone", "-q", "--bare", source, "\(box.root)/scratch/app.git")
        let bare = await GitSafety.repositoryRefusal(in: "\(box.root)/scratch")
        #expect(bare?.contains("app.git") == true, "\(bare ?? "nil")")

        // A linked worktree's git directory has HEAD and commondir but no objects of its own.
        _ = try box.write("shared/wt/HEAD", "ref: refs/heads/x\n")
        _ = try box.write("shared/wt/commondir", "../..\n")
        #expect(await GitSafety.repositoryRefusal(in: "\(box.root)/shared") != nil)

        // A file that happens to be named HEAD is not a repository.
        _ = try box.write("plain/notes/HEAD", "x")
        #expect(await GitSafety.repositoryRefusal(in: "\(box.root)/plain") == nil)
    }

    @Test func swiftPMClonesPassOnlyWhileTheyHoldNothingNew() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let source = try await makeRepo(box, "dep")
        let checkout = try await makeSwiftPMClones(box, in: "app/.build", source: source)
        let build = "\(box.root)/app/.build"
        #expect(await GitSafety.repositoryRefusal(in: build) == nil)

        _ = try box.write("app/.build/checkouts/dep/README", "edited")
        let edited = await GitSafety.repositoryRefusal(in: build)
        #expect(edited?.contains("checkouts/dep") == true && edited?.contains("changed") == true, "\(edited ?? "nil")")

        try await git(checkout, "checkout", "-q", "README")
        try await git(checkout, "commit", "-q", "--allow-empty", "-m", "local fix")
        let committed = await GitSafety.repositoryRefusal(in: build)
        #expect(committed?.contains("commits its mirror doesn't have") == true, "\(committed ?? "nil")")
    }

    @Test func swiftPMClonesInACustomScratchPathPass() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let source = try await makeRepo(box, "dep")
        // `swift build --scratch-path` and `-clonedSourcePackagesDirPath` put the clones in any folder.
        _ = try box.write("scratch/wbuild/workspace-state.json", "{}")
        _ = try await makeSwiftPMClones(box, in: "scratch/wbuild", source: source)
        #expect(await GitSafety.repositoryRefusal(in: "\(box.root)/scratch") == nil)
    }

    @Test func aCheckoutWhoseOriginIsntTheMirrorBesideItIsRefused() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let source = try await makeRepo(box, "dep")
        let checkout = try await makeSwiftPMClones(box, in: "app/.build", source: source)
        try await git(checkout, "remote", "set-url", "origin", source)
        let refusal = await GitSafety.repositoryRefusal(in: "\(box.root)/app/.build")
        #expect(refusal?.contains("mirror") == true, "\(refusal ?? "nil")")
    }

    @Test func swiftPMClonesOutsideSwiftPMFoldersAreRefused() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let source = try await makeRepo(box, "dep")
        _ = try await makeSwiftPMClones(box, in: "scratch/vendor", source: source)
        #expect(await GitSafety.repositoryRefusal(in: "\(box.root)/scratch") != nil)
    }
}

@Suite struct ProjectArtifactSafetyTests {
    func context(_ box: Sandbox) -> ScanContext {
        ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: ["\(box.root)/projects"],
                                         checkPullRequests: false, keepListURL: nil),
                    state: .empty, now: Date())
    }

    func project(_ box: Sandbox, _ name: String, ignore: String = "node_modules/\n.venv/\n.build/\n") async throws -> String {
        let repo = try await makeRepo(box, "projects/\(name)")
        _ = try box.write("projects/\(name)/.gitignore", ignore)
        try await git(repo, "add", ".gitignore")
        try await git(repo, "commit", "-q", "-m", "ignore")
        return repo
    }

    @Test func buildOutputThatHoldsWorkIsBlockedAndNotDeleted() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        // Committed node_modules (as JavaScript GitHub Actions do), force-added past the ignore rule.
        let committed = try await project(box, "action")
        _ = try box.write("projects/action/package.json", "{}")
        _ = try box.write("projects/action/node_modules/dep/index.js", "x")
        try await git(committed, "add", "-f", ".")
        // And one that git doesn't ignore at all.
        _ = try await project(box, "loose", ignore: "")
        _ = try box.write("projects/loose/package.json", "{}")
        _ = try box.write("projects/loose/node_modules/dep/index.js", "x")
        try await git(committed, "commit", "-q", "-m", "vendor")
        // An editable install's clone (`pip install -e git+…` puts it in <venv>/src).
        let source = try await makeRepo(box, "upstream")
        _ = try await project(box, "py")
        _ = try box.write("projects/py/.venv/pyvenv.cfg", "home = /usr/bin")
        try await git(box.root, "clone", "-q", source, "\(box.root)/projects/py/.venv/src/lib")
        // An edited SwiftPM checkout.
        let dep = try await makeRepo(box, "dep")
        _ = try await project(box, "pkg")
        _ = try box.write("projects/pkg/Package.swift", "// swift-tools-version:5.9")
        _ = try await makeSwiftPMClones(box, in: "projects/pkg/.build", source: dep)
        _ = try box.write("projects/pkg/.build/checkouts/dep/README", "edited")
        // Ordinary ignored build output.
        _ = try await project(box, "web")
        _ = try box.write("projects/web/package.json", "{}")
        _ = try box.write("projects/web/node_modules/dep/index.js", "x")

        let found = try await ProjectArtifactRule().discover(context(box))
        func item(_ rel: String) throws -> Candidate {
            try #require(found.first { $0.paths == ["\(box.root)/projects/\(rel)"] }, "\(rel) not found")
        }
        for rel in ["action/node_modules", "loose/node_modules", "py/.venv", "pkg/.build"] {
            let c = try item(rel)
            #expect(c.blockers.contains { $0.hasPrefix("not cleaned:") }, "\(rel): \(c.blockers)")
            #expect(!c.isDefaultSelected(at: .deep))
            let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
            #expect(result.status == .skipped, "\(rel): \(result.message)")
            #expect(FileInfo.exists("\(box.root)/projects/\(rel)"))
        }
        let action = try item("action/node_modules").blockers
        #expect(action.contains { $0.contains("tracks") }, "\(action)")
        #expect(try item("loose/node_modules").blockers.contains { $0.contains("doesn't ignore") })
        #expect(try item("web/node_modules").blockers.allSatisfy { !$0.hasPrefix("not cleaned:") })
    }

    @Test func aRepositoryThatAppearsAfterTheScanStopsTheDelete() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try await project(box, "web")
        _ = try box.write("projects/web/package.json", "{}")
        _ = try box.write("projects/web/node_modules/dep/index.js", "x")
        let found = try await ProjectArtifactRule().discover(context(box))
        let c = try #require(found.first { $0.paths == ["\(box.root)/projects/web/node_modules"] })
        #expect(c.blockers.allSatisfy { !$0.hasPrefix("not cleaned:") }, "\(c.blockers)")

        let source = try await makeRepo(box, "upstream")
        try await git(box.root, "clone", "-q", source, "\(box.root)/projects/web/node_modules/linked")
        let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
        #expect(result.status == .skipped, "\(result.message)")
        #expect(result.message.contains("node_modules/linked") || result.message.contains("linked"), "\(result.message)")
        #expect(FileInfo.exists("\(box.root)/projects/web/node_modules/linked/README"))
    }
}

@Suite struct WorktreeSafetyTests {
    @Test func anIgnoredCloneWithUnpushedWorkKeepsTheWorktree() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let (repo, wt) = try await mergedWorktree(box)
        let source = try await makeRepo(box, "upstream")
        try await git(box.root, "clone", "-q", source, "\(wt)/scratch/clone")
        try await git("\(wt)/scratch/clone", "commit", "-q", "--allow-empty", "-m", "unpushed")

        let c = try await scanWorktree(box, repo: repo, path: wt)
        #expect(c.blockers.contains { $0.contains("scratch/") }, "\(c.blockers)")
        let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
        #expect(result.status == .skipped, "\(result.message)")
        #expect(FileInfo.exists("\(wt)/scratch/clone/README"))
    }

    @Test func hiddenEditsKeepTheWorktree() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let (repo, wt) = try await mergedWorktree(box)
        try await git(wt, "update-index", "--assume-unchanged", "README")
        _ = try box.write("projects/app.done/README", "edited, but git status won't say")

        let c = try await scanWorktree(box, repo: repo, path: wt)
        #expect(c.blockers.contains { $0.contains("assume-unchanged") }, "\(c.blockers)")
        let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
        #expect(result.status == .skipped, "\(result.message)")
        #expect(try String(contentsOfFile: "\(wt)/README", encoding: .utf8).hasPrefix("edited"))
    }

    @Test func aCleanMergedWorktreeIsStillRemoved() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let (repo, wt) = try await mergedWorktree(box)
        _ = try box.write("projects/app.done/scratch/out.log", "build output")
        let c = try await scanWorktree(box, repo: repo, path: wt)
        #expect(c.blockers.isEmpty, "\(c.blockers)")
        let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
        #expect(result.status == .cleaned, "\(result.message)")
        #expect(!FileInfo.exists(wt))
    }
}

@Suite struct FailClosedTests {
    @Test func unknownOpenFilesStopCleanup() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let path = try box.mkdir("Library/Caches/tool")
        let c = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                          bytes: 1, paths: [path], action: .delete([path]))
        let unknown = SystemState(processPaths: [], busyDirectories: [], openFiles: [], openFilesKnown: false)
        let result = await Executor(guardrails: box.guardrails).clean(c, state: unknown)
        #expect(result.status == .skipped && result.message.contains("open files"), "\(result.message)")
        #expect(FileInfo.exists(path))
    }

    @Test func gitRedirectionFromTheEnvironmentIsDropped() {
        #expect(Shell.redirectingGitVariables.allSatisfy { Shell.environment[$0] == nil || ProcessInfo.processInfo.environment[$0] == nil })
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
            #expect(Shell.redirectingGitVariables.contains(name))
        }
        #expect(Shell.environment["GIT_OPTIONAL_LOCKS"] == "0")
    }

    @Test func extraEnvironmentReachesTheCommand() async {
        let result = await Shell.run("env", [], environment: ["ARIN_TEST_VALUE": "42"], timeout: 10)
        #expect(result.stdout.contains("ARIN_TEST_VALUE=42"))
    }

    @Test func miseConfigsThatMayExistBlockPruning() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let config = try box.write("work/app/mise.toml", "[tools]\nnode = \"22\"")
        let output = """
        mise WARN  error loading tracked config file \(config): failed to parse: expected `=`
        mise WARN  error loading tracked config file \(box.root)/gone/mise.toml: No such file or directory
        mise would remove node@20.1.0
        """
        #expect(MiseRule.unloadableConfigs(in: output) == [config])
        #expect(MiseRule.unloadableConfigs(in: "mise would remove node@20.1.0").isEmpty)
        // A path with ": " in it still resolves.
        let odd = try box.write("odd: name/mise.toml", "x")
        #expect(MiseRule.unloadableConfigs(in: "error loading tracked config file \(odd): bad") == [odd])
    }
}

@Suite struct TempLayoutTests {
    func evaluate(_ box: Sandbox, _ rel: String) async throws -> Candidate {
        let entry = "\(box.root)/tmp/\(rel)"
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        let walker = FileManager.default.enumerator(atPath: entry)
        while let child = walker?.nextObject() as? String {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: "\(entry)/\(child)")
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: entry)
        let ctx = ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [], keepListURL: nil),
                              state: .empty, now: Date())
        return try #require(await TempRule().evaluate(entry, bytes: 100 << 20, root: "\(box.root)/tmp", depth: 0, ctx: ctx).first)
    }

    @Test func onlyKnownCacheLayoutsStartSafe() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.write("tmp/gocache/README", "This directory holds cached build artifacts from the Go build system.\nRun \"go clean -cache\"\n")
        _ = try box.write("tmp/gocache/trim.txt", "1")
        _ = try box.mkdir("tmp/dd/Build/Products")
        _ = try box.write("tmp/dd/info.plist", "<plist/>")
        _ = try box.write("tmp/tagged/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
        _ = try box.write("tmp/agent-scratch/notes.md", "plan")

        for rel in ["gocache", "dd", "tagged"] {
            let c = try await evaluate(box, rel)
            #expect(c.effectiveRisk == .safe && c.isDefaultSelected(at: .quick), "\(rel): \(c.detail) \(c.blockers)")
        }
        let unknown = try await evaluate(box, "agent-scratch")
        #expect(unknown.effectiveRisk == .review && !unknown.isDefaultSelected(at: .deep))
    }
}

@Suite struct CatalogSafetyTests {
    @Test func bunKeepsItsGlobalStore() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.write(".bun/install/cache/links/pkg/index.js", "x")
        _ = try box.write(".bun/install/cache/react@19.0.0@@@1/index.js", "x")
        _ = try box.write(".bun/install/cache/react@19.0.0@@@1.npm", "x")
        let rule = try #require(Catalog.cacheRules.first { $0.id == "bun.cache" } as? KnownPathRule)
        let ctx = ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [], keepListURL: nil),
                              state: .empty, now: Date())
        let c = try #require(try await rule.discover(ctx).first)
        #expect(!c.paths.contains { $0.hasSuffix("/links") || $0.contains("/links/") })
        #expect(c.paths.count == 2)
        let result = await Executor(guardrails: box.guardrails).clean(c, state: .empty)
        #expect(result.status == .cleaned, "\(result.message)")
        #expect(FileInfo.exists("\(box.root)/.bun/install/cache/links/pkg/index.js"))
        #expect(!FileInfo.exists("\(box.root)/.bun/install/cache/react@19.0.0@@@1"))
    }

    @Test func derivedDataForADeletedWorkspaceIsOrphaned() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        func folder(_ name: String, workspace: String) throws -> String {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            let dir = try box.mkdir("DerivedData/\(name)")
            try plist.write(to: URL(fileURLWithPath: "\(dir)/info.plist"))
            return dir
        }
        let live = try box.mkdir("projects/App/App.xcodeproj")
        #expect(DerivedDataRule.workspaceIsGone(try folder("gone", workspace: "\(box.root)/projects/Removed/App.xcodeproj")))
        #expect(!DerivedDataRule.workspaceIsGone(try folder("live", workspace: live)))
        #expect(!DerivedDataRule.workspaceIsGone(try folder("unmounted", workspace: "/Volumes/arin-not-mounted-\(UUID().uuidString)/App.xcodeproj")))
        #expect(!DerivedDataRule.workspaceIsGone(try box.mkdir("DerivedData/noplist")))
    }
}

@Suite struct SignalTests {
    @Test func parsesSizes() {
        let gib: Int64 = 1_073_741_824
        #expect(ByteSize.parse("20GiB") == 20 * gib)
        #expect(ByteSize.parse("20G") == 20 * gib)
        #expect(ByteSize.parse("20GB") == 20_000_000_000)
        #expect(ByteSize.parse("1.5 TiB") == Int64(1.5 * 1_099_511_627_776))
        #expect(ByteSize.parse("512") == 512)
        #expect(ByteSize.parse("lots") == nil)
        #expect(ByteSize.parse("20XB") == nil)
    }

    @Test func claudeSessionsCountAsActivity() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("projects/my.app/.git")
        let project = "\(box.root)/projects/my.app/ui"
        _ = try box.mkdir("projects/my.app/ui")
        let encoded = ProjectActivity.transcriptFolderName("\(box.root)/projects/my.app")
        #expect(!encoded.contains(".") && !encoded.contains("/"))
        let transcripts = try box.mkdir("claude/projects")
        _ = try box.write("claude/projects/\(encoded)/session.jsonl", "{}")
        let found = try #require(ProjectActivity.transcriptActivity(project: project, root: transcripts))
        #expect(Date().timeIntervalSince(found) < 3600)
        #expect(ProjectActivity.transcriptActivity(project: "\(box.root)/projects/other", root: transcripts) == nil)
    }
}

@testable import ArinCore
import Foundation
import Testing

private func age(_ path: String, days: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: path)
}

private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(executable: String, arguments: [String], environment: [String: String])] = []

    var calls: [(executable: String, arguments: [String], environment: [String: String])] { lock.withLock { recorded } }

    func which(_ name: String) -> String? { "/fake/bin/\(name)" }

    func run(_ executable: String, _ arguments: [String], cwd: String?, input: String?,
             environment: [String: String], timeout: TimeInterval) async -> ShellResult {
        lock.withLock { recorded.append((executable, arguments, environment)) }
        guard executable == "sqlite3" else { return ShellResult(status: 0, stdout: "", stderr: "", timedOut: false) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return ShellResult(status: 127, stdout: "", stderr: "\(error)", timedOut: false) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "", timedOut: false)
    }
}

@Suite struct AgentCommandGuardrailTests {
    @Test func codexDeletesOneSessionByUUIDOnly() {
        let id = "01a13dc0-b432-72f3-ad1d-60aeef165bbb"
        #expect(Guardrails.allows(CommandSpec("codex", ["delete", "--force", id])))
        #expect(!Guardrails.allows(CommandSpec("codex", ["delete", id])))
        #expect(!Guardrails.allows(CommandSpec("codex", ["delete", "--force", "my-session"])))
        #expect(!Guardrails.allows(CommandSpec("codex", ["delete", "--force", id, id])))
        #expect(!Guardrails.allows(CommandSpec("codex", ["archive", id])))
        #expect(!Guardrails.allows(CommandSpec("codex", ["exec", "rm -rf ~"])))
    }

    @Test func claudePurgesOneAbsoluteProjectOnly() {
        #expect(Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "/Users/me/.t3/worktrees/app/t3-1"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "--all"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--all", "--yes"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "/Users/me/app"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "relative/app"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "/"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "/Users"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "/Users/me/../other"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["purge", "--yes", "/Users/me/app\n--all"])))
        #expect(!Guardrails.allows(CommandSpec("claude", ["-p", "delete everything"])))
    }

    @Test func longCommandListsAreSummarized() {
        let commands = (0 ..< 500).map { _ in CodexSessionsRule.deleteCommand(UUID().uuidString.lowercased()) }
        let summary = CleanupAction.commands(commands).summary
        #expect(summary.hasSuffix("(500 commands)"))
        #expect(summary.count < 200)
    }
}

@Suite struct ClaudeProjectTests {
    @Test func folderNamesReplaceEveryOtherCharacter() {
        #expect(ClaudeProjects.folderName(for: "/Users/me/.t3/worktrees/a_b") == "-Users-me--t3-worktrees-a-b")
        #expect(ClaudeProjects.folderName(for: "/Users/me/café") == "-Users-me-caf-")
        #expect(ClaudeProjects.folderName(for: "/a/🚀") == "-a---")
    }

    @Test func onlyNoSuchFileCountsAsGone() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let present = try box.mkdir("present")
        #expect(ClaudeProjects.presence(present, mounts: ["/"]) == .present)
        #expect(ClaudeProjects.presence("\(box.root)/gone/deeper", mounts: ["/"]) == .gone)
        #expect(ClaudeProjects.presence("/Volumes/Arin-Not-Mounted/project", mounts: ["/"]) == .unknown)
        #expect(ClaudeProjects.presence("/Volumes/Arin-Not-Mounted/project", mounts: nil) == .unknown)
        let file = try box.write("file")
        #expect(ClaudeProjects.presence("\(file)/project", mounts: ["/"]) == .unknown)
        let locked = try box.mkdir("locked")
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        #expect(ClaudeProjects.presence("\(locked)/project", mounts: ["/"]) == .unknown)
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/link", withDestinationPath: "\(box.root)/nowhere")
        #expect(ClaudeProjects.presence("\(box.root)/link/project", mounts: ["/"]) == .unknown)
    }

    @discardableResult
    private func project(_ box: Sandbox, cwd: String, folder: String? = nil, memory: Bool = false) throws -> String {
        let name = folder ?? ClaudeProjects.folderName(for: cwd)
        let summary = #"{"type":"summary","summary":"x"}"#
        let record = try String(decoding: JSONSerialization.data(withJSONObject: ["type": "user", "cwd": cwd]), as: UTF8.self)
        let transcript = try box.write(".claude/projects/\(name)/\(UUID().uuidString).jsonl", "\(summary)\n\(record)\n")
        try age(transcript, days: 10)
        if memory {
            _ = try box.write(".claude/projects/\(name)/memory/MEMORY.md", "notes")
            try age("\(box.root)/.claude/projects/\(name)/memory", days: 10)
        }
        let dir = "\(box.root)/.claude/projects/\(name)"
        try age(dir, days: 10)
        return dir
    }

    @Test func surveyReadsTheRecordedDirectory() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let live = try box.mkdir("projects/live")
        try project(box, cwd: live)
        let gone = try project(box, cwd: "\(box.root)/.t3/worktrees/app/t3-1")
        try project(box, cwd: "\(box.root)/elsewhere", folder: "-tmp-not-this-one")
        _ = try box.mkdir(".claude/projects/-no-transcripts/memory")

        let survey = ClaudeProjects.survey("\(box.root)/.claude/projects", mounts: ["/"])
        let byFolder = Dictionary(uniqueKeysWithValues: survey.projects.map { (($0.folder as NSString).lastPathComponent, $0) })
        #expect(byFolder[ClaudeProjects.folderName(for: live)]?.presence == .present)
        #expect(byFolder[(gone as NSString).lastPathComponent]?.presence == .gone)
        #expect(byFolder[(gone as NSString).lastPathComponent]?.workingDirectory == "\(box.root)/.t3/worktrees/app/t3-1")
        #expect(byFolder["-tmp-not-this-one"]?.presence == .unknown)
        #expect(byFolder["-no-transcripts"]?.presence == .unknown)
        #expect(!survey.looksLikeWrongHost)
    }

    @Test func nearlyEverythingGoneOffersNothing() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for index in 0 ..< 5 { try project(box, cwd: "\(box.root)/missing/p\(index)") }
        let survey = ClaudeProjects.survey("\(box.root)/.claude/projects", mounts: ["/"])
        #expect(survey.looksLikeWrongHost)

        let ctx = ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [], keepListURL: nil),
                              state: .empty, now: Date())
        let found = try await Shell.$runner.withValue(RecordingRunner()) { try await ClaudeOrphanProjectsRule().discover(ctx) }
        #expect(found.isEmpty)

        for index in 0 ..< 4 { try project(box, cwd: try box.mkdir("projects/p\(index)")) }
        #expect(!ClaudeProjects.survey("\(box.root)/.claude/projects", mounts: ["/"]).looksLikeWrongHost)
    }

    @Test func goneProjectsArePurgedByTheirRecordedPath() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for index in 0 ..< 3 { try project(box, cwd: try box.mkdir("projects/p\(index)")) }
        let plainPath = "\(box.root)/.t3/worktrees/app/t3-1"
        let memoryPath = "\(box.root)/projects/old-app"
        try project(box, cwd: plainPath)
        try project(box, cwd: memoryPath, memory: true)
        let recent = try project(box, cwd: "\(box.root)/projects/just-removed")
        try age(recent, days: 0.04)

        let ctx = ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [], keepListURL: nil),
                              state: .empty, now: Date())
        let found = try await Shell.$runner.withValue(RecordingRunner()) { try await ClaudeOrphanProjectsRule().discover(ctx) }
        let plain = try #require(found.first { $0.id == "\(ClaudeOrphanProjectsRule.ruleID):orphaned" })
        #expect(plain.risk == .safe && plain.level == .deep)
        #expect(plain.action == .commands([ClaudeOrphanProjectsRule.purgeCommand(plainPath)]))
        let withMemory = try #require(found.first { $0.id == "\(ClaudeOrphanProjectsRule.ruleID):orphaned-memory" })
        #expect(withMemory.risk == .review)
        #expect(withMemory.action == .commands([ClaudeOrphanProjectsRule.purgeCommand(memoryPath)]))
        #expect(found.count == 2)
    }

    @Test func executorChecksEachProjectRightBeforePurging() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let gonePath = "\(box.root)/.t3/worktrees/app/t3-1"
        let backPath = "\(box.root)/.t3/worktrees/app/t3-2"
        let goneFolder = try project(box, cwd: gonePath)
        let backFolder = try project(box, cwd: backPath)
        let candidate = Candidate(
            ruleID: ClaudeOrphanProjectsRule.ruleID, key: "orphaned", title: "Claude", detail: "",
            category: .agentData, level: .deep, risk: .safe, bytes: 100, paths: [goneFolder, backFolder],
            action: .commands([ClaudeOrphanProjectsRule.purgeCommand(gonePath), ClaudeOrphanProjectsRule.purgeCommand(backPath)])
        )
        _ = try box.mkdir(".t3/worktrees/app/t3-2")

        let runner = RecordingRunner()
        let executor = Executor(guardrails: box.guardrails, keepListURL: nil)
        let result = await Shell.$runner.withValue(runner) { await executor.clean(candidate, state: .empty) }
        #expect(runner.calls.map(\.arguments) == [["purge", "--yes", gonePath]])
        #expect(result.status == .partial)
        #expect(result.message.contains("removed 1 of 2 projects"))
        #expect(result.message.contains("the folder exists again"))
        #expect(result.estimatedBytes == 0)
    }
}

@Suite struct CodexSessionTests {
    private func sqlite(_ db: String, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func sessionTreesComeFromTheStateDatabase() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let home = "\(box.root)/.codex"
        let old = Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970
        let new = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let ids = (0 ..< 7).map { _ in UUID().uuidString.lowercased() }
        func rollout(_ index: Int, compressed: Bool = false, written: Double = 60) throws -> String {
            let file = try box.write(".codex/sessions/2026/09/01/rollout-2026-09-01T00-00-00-\(ids[index]).jsonl\(compressed ? ".zst" : "")")
            try age(file, days: written)
            return compressed ? String(file.dropLast(4)) : file
        }
        let a = try rollout(0), b = try rollout(1, compressed: true), c = try rollout(2), d = try rollout(3)
        let e = try rollout(4), f = try rollout(5)
        let rows: [(Int, String, Double, Int)] = [
            (0, a, old, 0),
            (1, b, old, 0),
            (2, c, old, 1),
            (3, d, new, 0),
            (4, e, old, 0),
            (5, f, new, 0),
            (6, "/Users/someone/elsewhere/rollout-\(ids[6]).jsonl", old, 0),
        ]
        let values = rows.map { "('\(ids[$0.0])', '\($0.1)', \(Int($0.2)), \(Int($0.2)), 0, \($0.3))" }.joined(separator: ",")
        try sqlite("\(home)/state_5.sqlite", """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER,
          recency_at INTEGER, is_pinned INTEGER, attached_thread_parent_id TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
        INSERT INTO threads (id, rollout_path, created_at, updated_at, recency_at, is_pinned) VALUES \(values);
        INSERT INTO thread_spawn_edges VALUES ('\(ids[0])', '\(ids[1])', 'closed'), ('\(ids[4])', '\(ids[5])', 'closed');
        """)
        try sqlite("\(home)/state_4.sqlite", "CREATE TABLE threads (id TEXT);")

        let sessions = try #require(await CodexSessionsRule.sessions(codexHome: home))
        #expect(sessions.count == 5)
        let idle = CodexSessionsRule.idle(sessions, state: .empty, now: Date())
        #expect(idle.map(\.id) == [ids[0]])
        #expect(Set(idle[0].files) == [Guardrails.canonical(a), Guardrails.canonical(b) + ".zst"])

        let busy = SystemState(processPaths: [], openPaths: [Guardrails.canonical(a)])
        #expect(CodexSessionsRule.idle(sessions, state: busy, now: Date()).isEmpty)

        #expect(await CodexSessionsRule.recheck(ids[0], codexHome: home, state: .empty, now: Date()) == nil)
        #expect(await CodexSessionsRule.recheck(ids[4], codexHome: home, state: .empty, now: Date()) == "used since the scan")
        #expect(await CodexSessionsRule.recheck(ids[2], codexHome: home, state: .empty, now: Date()) == "pinned, attached to another thread, or outside Codex's session folders")
        #expect(await CodexSessionsRule.recheck(UUID().uuidString.lowercased(), codexHome: home, state: .empty, now: Date())
            == "no longer in Codex's session list")
        #expect(await CodexSessionsRule.recheck("x' OR 1=1 --", codexHome: home, state: .empty, now: Date())
            == "couldn't read Codex's session database")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: a)
        #expect(await CodexSessionsRule.recheck(ids[0], codexHome: home, state: .empty, now: Date()) == "written since the scan")
    }

    @Test func aMissingSchemaColumnOffersNothing() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir(".codex")
        try sqlite("\(box.root)/.codex/state_5.sqlite", "CREATE TABLE threads (id TEXT, rollout_path TEXT);")
        #expect(await CodexSessionsRule.sessions(codexHome: "\(box.root)/.codex") == nil)
    }

    @Test func deletesRunOnePerSessionPinnedToTheScannedHome() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let home = "\(box.root)/.codex"
        let idle = UUID().uuidString.lowercased(), resumed = UUID().uuidString.lowercased()
        let old = Int(Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970)
        var files: [String] = []
        for id in [idle, resumed] {
            let file = try box.write(".codex/sessions/2026/09/01/rollout-2026-09-01T00-00-00-\(id).jsonl")
            try age(file, days: 60)
            files.append(file)
        }
        try sqlite("\(home)/state_5.sqlite", """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER,
          recency_at INTEGER, is_pinned INTEGER, attached_thread_parent_id TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
        INSERT INTO threads VALUES ('\(idle)', '\(files[0])', \(old), \(old), 0, 0, NULL),
          ('\(resumed)', '\(files[1])', \(old), \(old), 0, 0, NULL);
        """)
        let candidate = Candidate(
            ruleID: CodexSessionsRule.ruleID, key: "idle", title: "Codex", detail: "",
            category: .agentData, level: .deep, risk: .review, bytes: 100, paths: files,
            action: .commands([CodexSessionsRule.deleteCommand(idle), CodexSessionsRule.deleteCommand(resumed)])
        )
        try sqlite("\(home)/state_5.sqlite", "UPDATE threads SET updated_at = \(Int(Date().timeIntervalSince1970)) WHERE id = '\(resumed)';")

        let runner = RecordingRunner()
        let executor = Executor(guardrails: box.guardrails, keepListURL: nil)
        let result = await Shell.$runner.withValue(runner) { await executor.clean(candidate, state: .empty) }
        let deletes = runner.calls.filter { $0.executable == "codex" }
        #expect(deletes.map(\.arguments) == [["delete", "--force", idle]])
        #expect(deletes.first?.environment["CODEX_HOME"] == Guardrails.canonical(home))
        #expect(result.status == .partial, "\(result.message)")
        #expect(result.message.contains("removed 1 of 2 sessions"))
        #expect(result.message.contains("used since the scan"))

        try FileManager.default.removeItem(atPath: "\(home)/state_5.sqlite")
        let none = RecordingRunner()
        let refused = await Shell.$runner.withValue(none) { await executor.clean(candidate, state: .empty) }
        #expect(!none.calls.contains { $0.executable == "codex" })
        #expect(refused.status == .skipped)
        #expect(refused.message.contains("couldn't read Codex's session database"))
    }
}

@Suite struct CopilotPackageTests {
    @Test func keepsTheNewestPackage() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for version in ["1.0.98", "1.0.99-3", "1.0.100-1"] { _ = try box.write(".copilot/pkg/darwin-arm64/\(version)/app.js") }
        _ = try box.write(".copilot/pkg/tmp/1.0.20-1/app.js")
        let ctx = ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [], keepListURL: nil),
                              state: .empty, now: Date())
        let found = try await CopilotPackagesRule().discover(ctx)
        let candidate = try #require(found.first)
        #expect(Set(candidate.paths) == ["\(box.root)/.copilot/pkg/darwin-arm64/1.0.98", "\(box.root)/.copilot/pkg/darwin-arm64/1.0.99-3"])
    }
}

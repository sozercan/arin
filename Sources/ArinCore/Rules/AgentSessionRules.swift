import Foundation

struct CodexSessionsRule: Rule {
    static let ruleID = "agent.codex-sessions"
    let id = CodexSessionsRule.ruleID
    let name = "Idle Codex sessions"
    static let idleDays = 30

    struct Session: Equatable {
        var id: String
        var lastActivity: Date
        var files: [String]
        var keep: Bool
        var threads = 0
    }

    static let minimumVersion = [0, 170, 0]

    static func versionSupported(_ output: String) -> Bool {
        guard let token = output.split(whereSeparator: \.isWhitespace).last else { return false }
        let parts = token.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { return false }
        return parts.prefix(3).map { $0! }.lexicographicallyPrecedes(minimumVersion) == false
    }

    static func installedVersionSupported(codexHome: String) async -> Bool {
        let result = await Shell.run("codex", ["--version"], environment: ["CODEX_HOME": codexHome], timeout: 20)
        return result.ok && versionSupported(result.stdout)
    }

    static func threadCount(codexHome: String) async -> Int? {
        guard let db = stateDatabase(codexHome: codexHome) else { return nil }
        let result = await Shell.run("sqlite3", ["-readonly", db, "SELECT count(*) FROM threads;"], timeout: 60)
        guard result.ok else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct Row: Decodable {
        var root: String
        var id: String
        var path: String
        var last: Double
        var pinned: Int
        var attached: Int
    }

    static func treeQuery(root: String? = nil) -> String {
        """
    WITH RECURSIVE tree(root, id) AS (
      SELECT id, id FROM threads WHERE id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)\(root.map { " AND id = '\($0)'" } ?? "")
      UNION
      SELECT tree.root, e.child_thread_id FROM thread_spawn_edges e JOIN tree ON e.parent_thread_id = tree.id
    )
    SELECT tree.root AS root, c.id AS id, c.rollout_path AS path,
           MAX(c.updated_at, c.recency_at, c.created_at) AS last, c.is_pinned AS pinned,
           (c.attached_thread_parent_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM threads a WHERE a.attached_thread_parent_id = c.id)) AS attached
    FROM tree JOIN threads c ON c.id = tree.id
    """
    }

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("codex") != nil else { return [] }
        let codexHome = ctx.path(".codex")
        guard await Self.installedVersionSupported(codexHome: codexHome) else { return [] }
        guard let sessions = await Self.sessions(codexHome: codexHome) else { return [] }
        let days = ctx.options.agentHistoryDays ?? Self.idleDays
        let idle = Self.idle(sessions, state: ctx.state, now: ctx.now, days: days)
        guard !idle.isEmpty else { return [] }
        let files = idle.flatMap(\.files)
        let subagents = files.count - idle.count
        return [Candidate(
            ruleID: id,
            key: "idle",
            title: "Codex sessions idle for \(days)+ days (\(idle.count))",
            detail: "Removed with `codex delete`, which also clears their history, index and log entries\(subagents > 0 ? " and \(subagents) subagent threads" : ""). They can't be resumed afterwards. A copy of each session's files goes to the Trash first, so the space is freed once you empty it. Pinned sessions, sessions with attached threads, and any session used since the scan are kept. Codex's thread history database frees its share once it's compacted, which Arin offers when enough of it is free.",
            category: .agentData,
            level: .deep,
            risk: .review,
            bytes: await Size.total(files),
            paths: files,
            action: .commands(idle.map { Self.deleteCommand($0.id) }),
            lastModified: idle.map(\.lastActivity).max()
        )]
    }

    static func idle(_ sessions: [Session], state: SystemState, now: Date, days: Int = idleDays) -> [Session] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return sessions.filter { session in
            !session.keep && !session.files.isEmpty && session.lastActivity < cutoff
                && session.files.allSatisfy { !state.isBusy($0) && (FileInfo.modified($0) ?? .distantFuture) < cutoff }
        }.sorted { $0.lastActivity < $1.lastActivity }
    }

    static func deleteCommand(_ id: String) -> CommandSpec {
        CommandSpec("codex", ["delete", "--force", id])
    }

    static func stateDatabase(codexHome: String) -> String? {
        Glob.expand("\(codexHome)/state_*.sqlite").max { version($0) < version($1) }
    }

    private static func version(_ path: String) -> Int {
        Int((path as NSString).lastPathComponent.dropFirst("state_".count).dropLast(".sqlite".count)) ?? -1
    }

    static func sessions(codexHome: String, only root: String? = nil) async -> [Session]? {
        guard let db = stateDatabase(codexHome: codexHome) else { return nil }
        if let root, !isThreadID(root) { return nil }
        let query = treeQuery(root: root)
        let result = await Shell.run("sqlite3", ["-readonly", "-json", db, query + ";"], timeout: 60)
        guard result.ok else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return root == nil ? nil : [] }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(text.utf8)) else { return nil }
        return group(rows, codexHome: codexHome)
    }

    static func group(_ rows: [Row], codexHome: String) -> [Session] {
        var order: [String] = []
        var byRoot: [String: Session] = [:]
        for row in rows {
            if byRoot[row.root] == nil {
                order.append(row.root)
                byRoot[row.root] = Session(id: row.root, lastActivity: .distantPast, files: [], keep: !isThreadID(row.root))
            }
            var session = byRoot[row.root]!
            session.threads += 1
            session.lastActivity = max(session.lastActivity, Date(timeIntervalSince1970: row.last))
            if row.pinned != 0 || row.attached != 0 || !isThreadID(row.id) { session.keep = true }
            switch rolloutFiles(row.path, id: row.id, codexHome: codexHome) {
            case let files?: session.files += files.filter { !session.files.contains($0) }
            case nil: session.keep = true
            }
            byRoot[row.root] = session
        }
        return order.compactMap { byRoot[$0] }
    }

    static func rolloutFiles(_ recorded: String, id: String, codexHome: String) -> [String]? {
        let path = Guardrails.canonical((recorded as NSString).standardizingPath)
        let home = Guardrails.canonical((codexHome as NSString).standardizingPath)
        let name = (path as NSString).lastPathComponent
        let roots = ["sessions", "archived_sessions"].map { "\(home)/\($0)/" }
        guard roots.contains(where: { path.hasPrefix($0) }), name.hasPrefix("rollout-"), name.contains(id) else { return nil }
        let plain = path.hasSuffix(".zst") ? String(path.dropLast(4)) : path
        return [plain, plain + ".zst"].filter { FileInfo.exists($0) }
    }

    static func isThreadID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    static func recheck(_ id: String, codexHome: String, state: SystemState, now: Date) async -> String? {
        guard let sessions = await sessions(codexHome: codexHome, only: id) else {
            return "couldn't read Codex's session database"
        }
        guard let session = sessions.first else { return "no longer in Codex's session list" }
        let cutoff = now.addingTimeInterval(-Double(idleDays) * 86400)
        if session.keep { return "pinned, attached to another thread, or outside Codex's session folders" }
        if session.lastActivity >= cutoff { return "used since the scan" }
        for file in session.files {
            if state.isBusy(file) { return "its files are open" }
            if (FileInfo.modified(file) ?? .distantFuture) >= cutoff { return "written since the scan" }
        }
        return nil
    }
}

struct ClaudeOrphanProjectsRule: Rule {
    static let ruleID = "agent.claude-orphan-projects"
    let id = ClaudeOrphanProjectsRule.ruleID
    let name = "Claude Code data for deleted folders"
    static let minIdle: TimeInterval = 86400

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("claude") != nil, ClaudeProjects.configDirMatches(home: ctx.home) else { return [] }
        let survey = ClaudeProjects.survey(ctx.path(".claude/projects"), mounts: Guardrails.currentMountPoints())
        guard !survey.looksLikeWrongHost else { return [] }
        let window = ctx.options.agentHistoryDays.map { Double($0) * 86400 } ?? Self.minIdle
        var gone: [ClaudeProjects.Project] = []
        for project in survey.projects where project.presence == .gone && !ctx.state.isBusy(project.folder) {
            if await !FileInfo.hasRecentWrites(project.folder, within: window) { gone.append(project) }
        }
        guard !gone.isEmpty else { return [] }
        let sizes = await Size.allocated(gone.map(\.folder))

        func make(_ group: [ClaudeProjects.Project], key: String, title: String, detail: String, risk: Risk) -> Candidate? {
            guard !group.isEmpty else { return nil }
            let folders = group.map(\.folder)
            return Candidate(
                ruleID: id,
                key: key,
                title: "\(title) (\(group.count))",
                detail: detail,
                category: .agentData,
                level: .deep,
                risk: risk,
                bytes: folders.reduce(0) { $0 + (sizes[$1] ?? 0) },
                paths: folders,
                action: .commands(group.compactMap(\.workingDirectory).map(Self.purgeCommand)),
                lastModified: folders.compactMap(FileInfo.recentActivity).max()
            )
        }
        let purge = "Removed with `claude purge`, which also drops each project's entry in ~/.claude.json and its prompt history. Each project folder goes to the Trash first, so it can be put back, and the space is freed once you empty the Trash. Each folder's path comes from its transcripts, and only folders that are gone (not on an unmounted disk or behind a folder Arin can't read) are listed."
        let age = ctx.options.agentHistoryDays.map { ", untouched for \($0)+ days" } ?? ""
        return [
            make(gone.filter { !$0.hasMemory }, key: "orphaned",
                 title: "Claude Code data for deleted folders\(age)",
                 detail: "Transcripts, file history and tasks of sessions whose working folder no longer exists, often a removed worktree. \(purge)",
                 risk: .safe),
            make(gone.filter(\.hasMemory), key: "orphaned-memory",
                 title: "Claude Code data and memory for deleted folders\(age)",
                 detail: "As above, but these projects also have auto memory: notes Claude kept about the project, which `claude purge` deletes too. Look before removing them if you might recreate the folder. \(purge)",
                 risk: .review),
        ].compactMap { $0 }
    }

    static func dryRunRefusal(_ workingDirectory: String, home: String) async -> String? {
        let output = await Shell.run("claude", ["purge", "--dry-run", workingDirectory], environment: ["HOME": home], timeout: 60)
        guard output.ok else { return "claude purge --dry-run didn't find it" }
        return dryRunMismatch(output.stdout, workingDirectory: workingDirectory, home: home)
    }

    static func dryRunMismatch(_ plan: String, workingDirectory: String, home: String) -> String? {
        let folder = Guardrails.canonical("\(home)/.claude/projects/\(ClaudeProjects.folderName(for: workingDirectory))")
        let entry = "projects[\"\(workingDirectory)\"]"
        var items: [(kind: String, value: String)] = []
        var total: Int?
        for line in plan.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Dry run: ") {
                total = Int(line.dropFirst("Dry run: ".count).prefix { $0.isNumber })
                continue
            }
            guard line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") else { continue }
            let kind = String(line[line.index(line.startIndex, offsetBy: 2) ..< colon])
            guard !kind.isEmpty, kind.allSatisfy(\.isLetter) else { continue }
            items.append((kind, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let expected = items.allSatisfy { item in
            (item.kind == "dir" && Guardrails.canonical(item.value) == folder) || (item.kind == "config" && item.value == entry)
        }
        guard expected, items.filter({ $0.kind == "dir" }).count == 1, total == items.count else {
            return "claude purge --dry-run listed something other than this project"
        }
        return nil
    }

    static func purgeCommand(_ workingDirectory: String) -> CommandSpec {
        CommandSpec("claude", ["purge", "--yes", workingDirectory])
    }

    static func recheck(_ workingDirectory: String, home: String, state: SystemState) async -> String? {
        guard ClaudeProjects.configDirMatches(home: home) else { return "CLAUDE_CONFIG_DIR points somewhere else" }
        let folder = "\(home)/.claude/projects/\(ClaudeProjects.folderName(for: workingDirectory))"
        let mounts = Guardrails.currentMountPoints()
        let recorded = ClaudeProjects.recordedDirectories(in: folder)
        guard recorded.complete else { return "can't tell whether the folder is gone" }
        let matching = recorded.directories.filter { ClaudeProjects.folderName(for: $0) == (folder as NSString).lastPathComponent }
        switch ClaudeProjects.combined(Set(matching + [workingDirectory]).map { ClaudeProjects.presence($0, mounts: mounts) }) {
        case .present: return "the folder exists again"
        case .unknown: return "can't tell whether the folder is gone"
        case .gone: break
        }
        if state.isBusy(folder) { return "its transcripts are open" }
        if await FileInfo.hasRecentWrites(folder, within: minIdle) { return "a session wrote to it within the last day" }
        return nil
    }
}

enum ClaudeProjects {
    enum Presence: Equatable { case present, gone, unknown }

    struct Project: Equatable {
        var folder: String
        var workingDirectory: String?
        var presence: Presence
        var hasMemory: Bool
    }

    struct Survey {
        var projects: [Project]
        var looksLikeWrongHost: Bool {
            let known = projects.filter { $0.presence != .unknown }
            let gone = known.filter { $0.presence == .gone }.count
            return known.count >= 5 && gone * 10 >= known.count * 9
        }
    }

    static func configDirMatches(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty else { return true }
        return (dir as NSString).standardizingPath == ("\(home)/.claude" as NSString).standardizingPath
    }

    static func folderName(for path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        })
    }

    static func survey(_ root: String, mounts: [String]?) -> Survey {
        Survey(projects: FileInfo.children(root).filter { FileInfo.isDirectory($0) && !FileInfo.isSymlink($0) }.map { folder in
            let name = (folder as NSString).lastPathComponent
            let recorded = recordedDirectories(in: folder)
            let matching = recorded.directories.filter { folderName(for: $0) == name }
            let state = recorded.complete ? combined(matching.map { presence($0, mounts: mounts) }) : .unknown
            let memory = "\(folder)/memory"
            let hasMemory = FileInfo.children(memory).contains { !($0 as NSString).lastPathComponent.hasPrefix(".") }
                || (FileInfo.exists(memory) && !FileInfo.isDirectory(memory))
            return Project(folder: folder, workingDirectory: matching.first, presence: state, hasMemory: hasMemory)
        })
    }

    static func combined(_ presences: [Presence]) -> Presence {
        presences.isEmpty ? .unknown
            : presences.contains(.present) ? .present
            : presences.contains(.unknown) ? .unknown : .gone
    }

    struct Recorded: Equatable {
        var directories: [String]
        var complete: Bool
    }

    static func recordedDirectories(in folder: String, maxBytes: Int = 32 * 1024 * 1024) -> Recorded {
        let transcripts = FileInfo.children(folder).filter { $0.hasSuffix(".jsonl") && !FileInfo.isSymlink($0) }
        var found: [String] = []
        var complete = true
        for transcript in transcripts {
            switch firstWorkingDirectory(transcript, maxBytes: maxBytes) {
            case let .found(cwd): if !found.contains(cwd) { found.append(cwd) }
            case .none: break
            case .incomplete: complete = false
            }
        }
        return Recorded(directories: found, complete: complete)
    }

    enum FirstRecord: Equatable { case found(String), none, incomplete }

    static func firstWorkingDirectory(_ transcript: String, maxBytes: Int) -> FirstRecord {
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return .incomplete }
        defer { try? handle.close() }
        var buffer = Data()
        var read = 0
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(256 * 1024, maxBytes - read)) ?? Data() } catch { return .incomplete }
            if chunk.isEmpty, read >= maxBytes { return .incomplete }
            let atEnd = chunk.isEmpty
            read += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) ?? (atEnd && !buffer.isEmpty ? buffer.endIndex : nil) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer = newline < buffer.endIndex ? Data(buffer[buffer.index(after: newline)...]) : Data()
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let cwd = object["cwd"] as? String else { continue }
                return cwd.hasPrefix("/") ? .found(cwd) : .incomplete
            }
            if atEnd { return .none }
        }
    }

    static func presence(_ path: String, mounts: [String]?) -> Presence {
        let path = (path as NSString).standardizingPath
        guard path.hasPrefix("/"), path != "/" else { return .unknown }
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        guard errno == ENOENT else { return .unknown }
        let components = path.split(separator: "/")
        if components.first == "Volumes" {
            guard components.count >= 2, let mounts else { return .unknown }
            let volume = "/Volumes/\(components[1])".lowercased()
            if !mounts.contains(where: { $0.lowercased() == volume }) { return .unknown }
        }
        var parent = (path as NSString).deletingLastPathComponent
        while true {
            if lstat(parent, &info) == 0 {
                var target = stat()
                guard stat(parent, &target) == 0, (target.st_mode & S_IFMT) == S_IFDIR,
                      access(parent, R_OK | X_OK) == 0 else { return .unknown }
                return .gone
            }
            guard errno == ENOENT, parent != "/" else { return .unknown }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
}

struct CopilotPackagesRule: Rule {
    let id = "tools.copilot-packages"
    let name = "Old Copilot CLI packages"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        var versions: [String] = []
        var keep: [String] = []
        for platform in FileInfo.children(ctx.path(".copilot/pkg")) where FileInfo.isDirectory(platform) {
            guard (platform as NSString).lastPathComponent != "tmp" else { continue }
            let installed = FileInfo.children(platform).filter {
                FileInfo.isDirectory($0) && !FileInfo.isSymlink($0) && !($0 as NSString).lastPathComponent.hasPrefix(".")
            }
            guard let newest = installed.max(by: {
                ($0 as NSString).lastPathComponent.compare(($1 as NSString).lastPathComponent, options: .numeric) == .orderedAscending
            }) else { continue }
            versions += installed
            keep.append(newest)
        }
        return await OldVersions.candidates(
            ctx: ctx,
            ruleID: id,
            title: "Old Copilot CLI packages",
            versions: versions,
            keep: keep,
            detail: "Superseded Copilot CLI downloads. The newest package and any version a running session uses are kept."
        )
    }
}

struct AgentHistoryInsightRule: InsightRule {
    func insights(_ ctx: ScanContext) async -> [Insight] {
        var result: [Insight] = []
        let gigabyte: Int64 = 1024 * 1024 * 1024

        for db in Glob.expand(ctx.path(".codex/thread_history_*.sqlite")) {
            let bytes = await Size.allocated(db)
            guard bytes > 2 * gigabyte else { continue }
            result.append(Insight(
                id: "codex-thread-history:\((db as NSString).lastPathComponent)",
                title: "Codex keeps a second copy of its sessions",
                detail: "\((db as NSString).lastPathComponent) holds the same conversations as the session files, so Codex can page through them. Deleting sessions with `codex delete` removes their rows; the file shrinks only after it's compacted, which Arin offers once enough of it is free.",
                bytes: bytes
            ))
        }

        let copilotSessions = ctx.path(".copilot/session-state")
        if FileInfo.isDirectory(copilotSessions) {
            let bytes = await Size.allocated(copilotSessions)
            if bytes > gigabyte {
                result.append(Insight(
                    id: "copilot-sessions",
                    title: "Copilot CLI session history",
                    detail: "Run `/session prune --older-than \(ctx.options.agentHistoryDays ?? 30)` in Copilot CLI (add `--dry-run` first to see the list). It skips sessions open in other windows and keeps its search index in step. Deleting the folders yourself leaves the index out of date until `/chronicle reindex`.",
                    bytes: bytes
                ))
            }
        }

        let coworkVM = ctx.path("Library/Application Support/Claude/vm_bundles/claudevm.bundle")
        if FileInfo.isDirectory(coworkVM) {
            let bytes = await Size.allocated(coworkVM)
            if bytes > gigabyte {
                result.append(Insight(
                    id: "claude-cowork-vm",
                    title: "Claude's Cowork virtual machine",
                    detail: "The Linux VM Claude's desktop app runs Cowork in: its disk, the image it came from, and a session disk that can hold files Cowork sessions left inside it. Arin doesn't remove it, since it hasn't confirmed that Claude rebuilds it cleanly. If you no longer use Cowork, quit Claude before removing it yourself.",
                    bytes: bytes
                ))
            }
        }

        if let insight = await claudeRetention(ctx) { result.append(insight) }

        if Shell.which("claude") != nil, ClaudeProjects.configDirMatches(home: ctx.home) {
            let survey = ClaudeProjects.survey(ctx.path(".claude/projects"), mounts: Guardrails.currentMountPoints())
            if survey.looksLikeWrongHost {
                result.append(Insight(
                    id: "claude-projects-wrong-host",
                    title: "Claude Code's project folders point at missing folders",
                    detail: "Nearly every folder in ~/.claude/projects belongs to a working folder that doesn't exist here, as happens with a home copied from another Mac or projects on a disk that isn't attached. Arin doesn't offer any of them for removal."
                ))
            }
        }

        let dockerRaw = ctx.path("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        if FileInfo.exists(dockerRaw) {
            let bytes = await Size.allocated(dockerRaw)
            if bytes > 5 * gigabyte {
                result.append(Insight(
                    id: "docker-raw",
                    title: "Docker disk image",
                    detail: "Docker.raw holds images, containers and volumes. Never delete it directly. Start Docker so Arin can see what is reclaimable inside it.",
                    bytes: bytes
                ))
            }
        }
        return result
    }

    func claudeRetention(_ ctx: ScanContext) async -> Insight? {
        let settings = ctx.path(".claude/settings.json")
        let values = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings)))) as? [String: Any] ?? [:]
        guard values["desktopSessionCleanupPeriodDays"] == nil else { return nil }
        let days = (values["cleanupPeriodDays"] as? NSNumber)?.intValue ?? 30
        let cutoff = ctx.now.addingTimeInterval(-Double(max(days, 1)) * 86400)
        let old = FileInfo.children(ctx.path(".claude/projects")).flatMap { folder in
            FileInfo.children(folder).filter { $0.hasSuffix(".jsonl") && (FileInfo.modified($0) ?? .distantFuture) < cutoff }
        }
        guard !old.isEmpty else { return nil }
        let bytes = await Size.total(old)
        guard bytes > 200 * 1024 * 1024 else { return nil }
        return Insight(
            id: "claude-desktop-retention",
            title: "Claude Code transcripts outlive the cleanup period",
            detail: "\(old.count) transcripts are older than \(days) days. Claude Code keeps sessions started or continued in Claude's desktop app at any age unless `desktopSessionCleanupPeriodDays` is set in ~/.claude/settings.json.",
            bytes: bytes
        )
    }
}

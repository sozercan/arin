import Foundation

/// Codex sessions nobody has touched for a while, removed with `codex delete`. Codex keeps each
/// conversation in a rollout file, a row in its state database, rows in its paginated thread history,
/// and an entry in its name index; only its own command removes all of them together. Deleting the
/// files directly would leave sessions listed that can't be opened.
struct CodexSessionsRule: Rule {
    static let ruleID = "agent.codex-sessions"
    let id = CodexSessionsRule.ruleID
    let name = "Idle Codex sessions"
    static let idleDays = 30

    /// One session and the subagent threads it spawned, which `codex delete` removes with it.
    struct Session: Equatable {
        var id: String
        var lastActivity: Date
        /// Rollout files of the session and its subagents that are on disk.
        var files: [String]
        /// Pinned, or attached to another thread (Codex refuses those), or a row that isn't sane.
        var keep: Bool
    }

    struct Row: Decodable {
        var root: String
        var id: String
        var path: String
        var last: Double
        var pinned: Int
        var attached: Int
    }

    /// Every session tree with the newest activity anywhere in it. A subagent whose parent row is
    /// missing is never a root, so it's never offered.
    static let treeQuery = """
    WITH RECURSIVE tree(root, id) AS (
      SELECT id, id FROM threads WHERE id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)
      UNION
      SELECT tree.root, e.child_thread_id FROM thread_spawn_edges e JOIN tree ON e.parent_thread_id = tree.id
    )
    SELECT tree.root AS root, c.id AS id, c.rollout_path AS path,
           MAX(c.updated_at, c.recency_at, c.created_at) AS last, c.is_pinned AS pinned,
           (c.attached_thread_parent_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM threads a WHERE a.attached_thread_parent_id = c.id)) AS attached
    FROM tree JOIN threads c ON c.id = tree.id
    """

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("codex") != nil else { return [] }
        let codexHome = ctx.path(".codex")
        guard let sessions = await Self.sessions(codexHome: codexHome) else { return [] }
        let idle = Self.idle(sessions, state: ctx.state, now: ctx.now)
        guard !idle.isEmpty else { return [] }
        let files = idle.flatMap(\.files)
        let subagents = files.count - idle.count
        return [Candidate(
            ruleID: id,
            key: "idle",
            title: "Codex sessions idle for \(Self.idleDays)+ days (\(idle.count))",
            detail: "Removed with `codex delete`, which also clears their history, index and log entries\(subagents > 0 ? " and \(subagents) subagent threads" : ""). They can't be resumed afterwards. Pinned sessions, sessions with attached threads, and any session used since the scan are kept. Codex's thread history database frees its share once it's compacted, which Arin offers when enough of it is free.",
            category: .agentData,
            level: .deep,
            risk: .review,
            bytes: await Size.total(files),
            paths: files,
            action: .commands(idle.map { Self.deleteCommand($0.id) }),
            lastModified: idle.map(\.lastActivity).max()
        )]
    }

    /// Sessions with files on disk, untouched for `idleDays` (rows and files alike), not pinned or
    /// attached, and with nothing open. Oldest first.
    static func idle(_ sessions: [Session], state: SystemState, now: Date) -> [Session] {
        let cutoff = now.addingTimeInterval(-Double(idleDays) * 86400)
        return sessions.filter { session in
            !session.keep && !session.files.isEmpty && session.lastActivity < cutoff
                && session.files.allSatisfy { !state.isBusy($0) && (FileInfo.modified($0) ?? .distantFuture) < cutoff }
        }.sorted { $0.lastActivity < $1.lastActivity }
    }

    static func deleteCommand(_ id: String) -> CommandSpec {
        CommandSpec("codex", ["delete", "--force", id])
    }

    /// The newest `state_<n>.sqlite`, the database the installed Codex reads.
    static func stateDatabase(codexHome: String) -> String? {
        Glob.expand("\(codexHome)/state_*.sqlite").max { version($0) < version($1) }
    }

    private static func version(_ path: String) -> Int {
        Int((path as NSString).lastPathComponent.dropFirst("state_".count).dropLast(".sqlite".count)) ?? -1
    }

    /// Sessions from Codex's state database, or nil when it can't be read. Only session trees whose
    /// root matches `only` when given.
    static func sessions(codexHome: String, only root: String? = nil) async -> [Session]? {
        guard let db = stateDatabase(codexHome: codexHome) else { return nil }
        var query = treeQuery
        if let root {
            guard isThreadID(root) else { return nil }
            query += " WHERE tree.root = '\(root)'"
        }
        let result = await Shell.run("sqlite3", ["-readonly", "-json", db, query + ";"], timeout: 60)
        guard result.ok else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // sqlite3 prints nothing at all for an empty result.
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

    /// The rollout files on disk for a thread: the recorded path and its compressed or uncompressed
    /// twin, since Codex compresses idle rollouts in place. Nil when the recorded path isn't a rollout
    /// of this thread inside Codex's own session folders.
    static func rolloutFiles(_ recorded: String, id: String, codexHome: String) -> [String]? {
        // /var and /tmp are symlinks into /private; compare canonical forms.
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

    /// Right before `codex delete <id>`: why it must not run. The tree is read again, so a subagent
    /// spawned or a session resumed since the scan keeps it.
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

/// Claude Code data for working directories that no longer exist, removed with `claude purge`,
/// which also drops the project's entry in `~/.claude.json` and its lines in the prompt history.
struct ClaudeOrphanProjectsRule: Rule {
    static let ruleID = "agent.claude-orphan-projects"
    let id = ClaudeOrphanProjectsRule.ruleID
    let name = "Claude Code data for deleted folders"
    /// A transcript written this recently may belong to a session still running in a deleted folder.
    static let minIdle: TimeInterval = 86400

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("claude") != nil, ClaudeProjects.configDirMatches(home: ctx.home) else { return [] }
        let survey = ClaudeProjects.survey(ctx.path(".claude/projects"), mounts: Guardrails.currentMountPoints())
        guard !survey.looksLikeWrongHost else { return [] }
        let gone = survey.projects.filter { project in
            guard project.presence == .gone, !ctx.state.isBusy(project.folder) else { return false }
            let recent = FileInfo.recentActivity(project.folder) ?? .distantFuture
            return ctx.now.timeIntervalSince(recent) >= Self.minIdle
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
        let purge = "Removed with `claude purge`, which also drops each project's entry in ~/.claude.json and its prompt history. Each folder's path comes from its transcripts, and only folders that are gone (not on an unmounted disk or behind a folder Arin can't read) are listed."
        return [
            make(gone.filter { !$0.hasMemory }, key: "orphaned",
                 title: "Claude Code data for deleted folders",
                 detail: "Transcripts, file history and tasks of sessions whose working folder no longer exists, often a removed worktree. \(purge)",
                 risk: .safe),
            make(gone.filter(\.hasMemory), key: "orphaned-memory",
                 title: "Claude Code data and memory for deleted folders",
                 detail: "As above, but these projects also have auto memory: notes Claude kept about the project, which `claude purge` deletes too. Look before removing them if you might recreate the folder. \(purge)",
                 risk: .review),
        ].compactMap { $0 }
    }

    static func purgeCommand(_ workingDirectory: String) -> CommandSpec {
        CommandSpec("claude", ["purge", "--yes", workingDirectory])
    }

    /// Right before `claude purge <dir>`: why it must not run.
    static func recheck(_ workingDirectory: String, home: String, state: SystemState, now: Date) -> String? {
        guard ClaudeProjects.configDirMatches(home: home) else { return "CLAUDE_CONFIG_DIR points somewhere else" }
        switch ClaudeProjects.presence(workingDirectory, mounts: Guardrails.currentMountPoints()) {
        case .present: return "the folder exists again"
        case .unknown: return "can't tell whether the folder is gone"
        case .gone: break
        }
        let folder = "\(home)/.claude/projects/\(ClaudeProjects.folderName(for: workingDirectory))"
        if state.isBusy(folder) { return "its transcripts are open" }
        if let recent = FileInfo.recentActivity(folder), now.timeIntervalSince(recent) < minIdle {
            return "a session wrote to it within the last day"
        }
        return nil
    }
}

/// How Claude Code lays out `~/.claude/projects`: one folder per working directory, named by
/// replacing every character other than an ASCII letter or digit with `-`. The name can't be decoded
/// back (`/a/b-c` and `/a/b/c` share one, and `.t3` turns into `-t3`), so the path comes from the
/// `cwd` field the transcripts record, and only a path that encodes to the folder's name counts.
enum ClaudeProjects {
    enum Presence: Equatable { case present, gone, unknown }

    struct Project: Equatable {
        var folder: String
        /// The recorded working directory whose name matches the folder, or nil when none does.
        var workingDirectory: String?
        var presence: Presence
        var hasMemory: Bool
    }

    struct Survey {
        var projects: [Project]
        /// Nearly every project looks gone, as on a home copied from another Mac or one whose disk
        /// isn't attached. Nothing is offered then.
        var looksLikeWrongHost: Bool {
            let known = projects.filter { $0.presence != .unknown }
            let gone = known.filter { $0.presence == .gone }.count
            return known.count >= 5 && gone * 10 >= known.count * 9
        }
    }

    /// Claude Code honours CLAUDE_CONFIG_DIR. When it points somewhere other than `~/.claude`,
    /// `claude purge` would act on a different folder than the one scanned.
    static func configDirMatches(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty else { return true }
        return (dir as NSString).standardizingPath == ("\(home)/.claude" as NSString).standardizingPath
    }

    /// The folder name Claude Code uses for a working directory. It replaces UTF-16 code units, so a
    /// character outside the BMP becomes two dashes.
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
            let matching = recordedDirectories(in: folder).filter { folderName(for: $0) == name }
            let presences = matching.map { presence($0, mounts: mounts) }
            // Two paths can share a folder name; it's gone only if every one of them is.
            let presence: Presence = presences.isEmpty ? .unknown
                : presences.contains(.present) ? .present
                : presences.contains(.unknown) ? .unknown : .gone
            let memory = "\(folder)/memory"
            let hasMemory = FileInfo.children(memory).contains { !($0 as NSString).lastPathComponent.hasPrefix(".") }
                || (FileInfo.exists(memory) && !FileInfo.isDirectory(memory))
            return Project(folder: folder, workingDirectory: matching.first, presence: presence, hasMemory: hasMemory)
        })
    }

    /// Working directories recorded in the folder's newest transcripts. Each transcript is read only
    /// up to its first record with a `cwd`, and at most 64 KB of it.
    static func recordedDirectories(in folder: String, limit: Int = 20) -> [String] {
        let transcripts = FileInfo.children(folder)
            .filter { $0.hasSuffix(".jsonl") && !FileInfo.isSymlink($0) }
            .sorted { (FileInfo.modified($0) ?? .distantPast) > (FileInfo.modified($1) ?? .distantPast) }
            .prefix(limit)
        var found: [String] = []
        for transcript in transcripts {
            guard let handle = FileHandle(forReadingAtPath: transcript) else { continue }
            let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let cwd = object["cwd"] as? String else { continue }
                if cwd.hasPrefix("/"), !found.contains(cwd) { found.append(cwd) }
                break
            }
        }
        return found
    }

    /// Whether a directory is really gone. Only "no such file" counts, and only when the nearest
    /// existing parent is a folder Arin can search and the path isn't on a volume that's not mounted.
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

/// Old Copilot CLI packages its updater downloaded. The newest is kept, since the CLI may launch it
/// in place of the version it shipped with, and so is any version a running process uses.
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

/// Agent history Arin reports but doesn't act on: settings that leave it to grow, copies it can't
/// remove on its own, and tools whose cleanup only runs inside the tool.
struct AgentHistoryInsightRule: InsightRule {
    func insights(_ ctx: ScanContext) async -> [Insight] {
        var result: [Insight] = []
        let gigabyte: Int64 = 1024 * 1024 * 1024

        for db in Glob.expand(ctx.path(".codex/thread_history_*.sqlite")) {
            let bytes = await Size.allocated(db)
            guard bytes > 2 * gigabyte else { continue }
            result.append(Insight(
                id: "codex-thread-history",
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
                    detail: "Run `/session prune --older-than 30` in Copilot CLI (add `--dry-run` first to see the list). It skips sessions open in other windows and keeps its search index in step. Deleting the folders yourself leaves the index out of date until `/chronicle reindex`.",
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

    /// Claude Code deletes transcripts older than `cleanupPeriodDays` (30 by default), except those of
    /// sessions started or continued in Claude's desktop app, which it keeps at any age unless
    /// `desktopSessionCleanupPeriodDays` is set. Old transcripts still on disk are most likely those.
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

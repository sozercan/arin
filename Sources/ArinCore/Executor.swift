import Foundation

public struct CleanupItemResult: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case cleaned, partial, skipped, failed
    }

    public var id: String
    public var title: String
    public var status: Status
    public var message: String
    public var estimatedBytes: Int64
    public var trashed: Bool
    public var trashedPaths: [TrashedPath]?
}

public struct CleanupReport: Codable, Sendable {
    public var items: [CleanupItemResult]
    public var freeBefore: Int64
    public var freeAfter: Int64
    public var estimatedBytes: Int64
    public var explanations: [String]

    public var measuredBytes: Int64 { freeAfter - freeBefore }
    public var cleanedCount: Int { items.filter { $0.status == .cleaned }.count }
    public var hasFailures: Bool { items.contains { $0.status == .failed || $0.status == .partial } }
}

public enum CleanupEvent: Sendable {
    case started(total: Int)
    case item(index: Int, title: String)
    case finished(CleanupItemResult)
}

public struct Executor: Sendable {
    public var guardrails: Guardrails
    public var trashInsteadOfDelete: Bool
    public var commandTimeout: TimeInterval
    public var keepListURL: URL?
    var stateMaxAge: TimeInterval = 5
    var backupDirectory: String?

    public init(
        guardrails: Guardrails = Guardrails(),
        trashInsteadOfDelete: Bool = false,
        commandTimeout: TimeInterval = 1800,
        keepListURL: URL? = KeepList.defaultURL
    ) {
        self.guardrails = guardrails
        self.trashInsteadOfDelete = trashInsteadOfDelete
        self.commandTimeout = commandTimeout
        self.keepListURL = keepListURL
    }

    public func run(_ candidates: [Candidate], progress: (@Sendable (CleanupEvent) -> Void)? = nil) async -> CleanupReport {
        let before = Disk.status(path: guardrails.home).freeBytes
        progress?(.started(total: candidates.count))

        var results: [CleanupItemResult] = []
        for (index, candidate) in candidates.enumerated() {
            progress?(.item(index: index, title: candidate.title))
            let state = await SystemState.capture()
            let keep: Result<KeepList, any Error> = keepListURL.map { url in Result { try KeepList.load(from: url) } }
                ?? .success(KeepList())
            let result: CleanupItemResult
            switch keep {
            case let .failure(error):
                result = Self.skipped(candidate, "\(error)")
            case let .success(list) where list.contains(candidate.id) || candidate.kept:
                result = Self.skipped(candidate, "on your keep list")
            case .success where !candidate.keepBlockers.isEmpty:
                result = Self.skipped(candidate, candidate.keepBlockers.joined(separator: "; "))
            case let .success(list):
                let kept = KeptPaths(list.entries)
                if let inside = Self.targets(of: candidate).lazy.compactMap({ kept.insideOrAt($0) }).first {
                    result = Self.skipped(candidate, "contains \(inside.title)\(KeepList.keptBlockerSuffix)")
                } else {
                    result = await clean(candidate, state: state)
                }
            }
            results.append(result)
            progress?(.finished(result))
        }

        let after = Disk.status(path: guardrails.home).freeBytes
        let cleaned = results.filter { $0.status == .cleaned || $0.status == .partial }
        let estimated = cleaned.reduce(0) { $0 + $1.estimatedBytes }
        let report = CleanupReport(
            items: results,
            freeBefore: before,
            freeAfter: after,
            estimatedBytes: estimated,
            explanations: []
        )
        var withNotes = report
        withNotes.explanations = await Self.explain(report, cleaned: candidates.filter { c in cleaned.contains { $0.id == c.id } })
        return withNotes
    }

    static func targets(of candidate: Candidate) -> [String] {
        switch candidate.action {
        case let .delete(paths), let .trash(paths): paths
        case let .removeWorktree(_, path, _): [path] + candidate.paths
        case .commands, .none: candidate.paths
        }
    }

    static func preflight(_ command: CommandSpec) async -> String? {
        if command.executable == "mise", command.arguments.first == "prune", let tool = command.arguments.last,
           let reason = await MiseRule.unloadableConfigs(tool: tool) {
            return reason
        }
        if command.executable == "ollama", command.arguments.first == "rm", let model = command.arguments.last {
            let loaded = await Shell.run("ollama", ["ps"], timeout: 20)
            guard loaded.ok else { return "couldn't check whether \(model) is loaded in Ollama" }
            if OllamaModelRule.parseTable(loaded.stdout).contains(where: { $0.name == model }) {
                return "\(model) is loaded in Ollama right now"
            }
        }
        return nil
    }

    static func recheck(_ candidate: Candidate) async -> String? {
        let paths: [String]
        switch candidate.action {
        case let .delete(list), let .trash(list): paths = list
        default: return nil
        }
        for path in paths {
            let reason: String?
            switch candidate.ruleID {
            case ProjectArtifactRule.ruleID:
                reason = await ProjectArtifactRule.recheck(path)
            case "xcode.derived-data" where candidate.id == "xcode.derived-data:orphaned" && !DerivedDataRule.workspaceIsGone(path):
                reason = "its project or workspace is back; scan again"
            case "temp.stale", "unclassified", "unclassified.home", "xcode.derived-data":
                reason = FileInfo.isDirectory(path) && !FileInfo.isSymlink(path)
                    ? await GitSafety.repositoryRefusal(in: path, skipPackageCaches: candidate.ruleID != "xcode.derived-data").map { "it \($0)" }
                    : nil
            default:
                reason = nil
            }
            if let reason { return "\((path as NSString).abbreviatingWithTildeInPath): \(reason)" }
        }
        return nil
    }

    static func skipped(_ candidate: Candidate, _ message: String) -> CleanupItemResult {
        CleanupItemResult(id: candidate.id, title: candidate.title, status: .skipped, message: message,
                          estimatedBytes: 0, trashed: false, trashedPaths: nil)
    }

    func clean(_ candidate: Candidate, state: SystemState) async -> CleanupItemResult {
        func result(_ status: CleanupItemResult.Status, _ message: String, trashed: Bool = false) -> CleanupItemResult {
            CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                status: status,
                message: message,
                estimatedBytes: status == .cleaned ? candidate.bytes : 0,
                trashed: trashed,
                trashedPaths: nil
            )
        }
        func trashResult(_ paths: [String]) async -> CleanupItemResult {
            let (errors, moved) = await trash(paths)
            guard errors.isEmpty else {
                var failed = result(.failed, errors.joined(separator: "; "))
                failed.trashedPaths = moved.isEmpty ? nil : moved
                return failed
            }
            var done = result(.cleaned, "moved to Trash", trashed: true)
            done.trashedPaths = moved
            return done
        }

        guard candidate.isActionable else { return result(.skipped, "informational only") }
        do {
            try guardrails.check(candidate.action)
            for path in candidate.paths {
                if case .commands = candidate.action { try guardrails.checkTarget(path) } else { try guardrails.check(path) }
            }
        } catch {
            return result(.skipped, error.description)
        }

        if !state.openFilesKnown, !candidate.paths.isEmpty {
            return result(.skipped, "couldn't check for open files (lsof returned nothing); try again")
        }
        let perItem: [CommandSpec]? = {
            guard case let .commands(commands) = candidate.action, !commands.isEmpty,
                  commands.allSatisfy(Self.isPerItem) else { return nil }
            return commands
        }()
        let live = state.blockers(
            paths: perItem == nil ? candidate.paths : [],
            processes: candidate.blockingProcesses,
            minIdle: perItem == nil ? candidate.minIdleSeconds : nil
        )
        if !live.isEmpty { return result(.skipped, live.joined(separator: "; ")) }
        if perItem == nil, let idle = candidate.minIdleSeconds {
            for path in candidate.paths where await FileInfo.hasRecentWrites(path, within: idle) {
                return result(.skipped, "\((path as NSString).abbreviatingWithTildeInPath) was written recently (may be in use)")
            }
        }

        if let reason = await Self.recheck(candidate) {
            return result(.skipped, "not cleaned: \(reason)")
        }

        switch candidate.action {
        case .none:
            return result(.skipped, "informational only")

        case let .delete(paths):
            if trashInsteadOfDelete { return await trashResult(paths) }
            return await Self.deleteResult(candidate, await delete(paths), paths: paths, done: "deleted")

        case let .trash(paths):
            return await trashResult(paths)

        case let .commands(commands) where perItem != nil:
            return await runPerItem(candidate, commands, state: state)

        case let .commands(commands):
            var warnings: [String] = []
            for command in commands {
                guard Guardrails.allows(command) else {
                    return result(.skipped, "refusing to run \(command.display)")
                }
                if let reason = await Self.preflight(command) { return result(.skipped, reason) }
                let output = await Shell.run(command.executable, command.arguments, cwd: command.cwd, timeout: commandTimeout)
                if !output.ok {
                    let tail = String((output.stderr.isEmpty ? output.stdout : output.stderr).suffix(400))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if output.timedOut { return result(.failed, "\(command.display) timed out") }
                    if await Self.targetsMostlyGone(candidate) {
                        warnings.append(tail)
                        continue
                    }
                    return result(.failed, "\(command.display): \(tail)")
                }
            }
            let done = commands.map(\.display).joined(separator: " && ")
            if warnings.isEmpty { return result(.cleaned, done) }
            return result(.cleaned, "\(done) finished with warnings: \(warnings.joined(separator: "; ").prefix(300))")

        case let .removeWorktree(repo, path, head):
            return await removeWorktree(candidate, repo: repo, path: path, head: head, result: result)
        }
    }

    static func isPerItem(_ command: CommandSpec) -> Bool {
        switch (command.executable, command.arguments.first) {
        case ("codex", "delete"), ("claude", "purge"): true
        default: false
        }
    }

    struct PerItem {
        var backup: [String]
        var backupName: String
        var restoreTo: String?
        var threadsBefore = 0
        var treeSize = 0
    }

    enum PerItemCheck {
        case refused(String)
        case ready(PerItem)
    }

    func prepare(_ command: CommandSpec, state: SystemState) async -> PerItemCheck {
        guard Guardrails.allows(command), let target = command.arguments.last else { return .refused("refusing to run \(command.display)") }
        switch command.executable {
        case "codex":
            let codexHome = "\(guardrails.home)/.codex"
            if let reason = await CodexSessionsRule.recheck(target, codexHome: codexHome, state: state, now: Date()) { return .refused(reason) }
            guard let session = await CodexSessionsRule.sessions(codexHome: codexHome, only: target)?.first,
                  let before = await CodexSessionsRule.threadCount(codexHome: codexHome)
            else { return .refused("couldn't read Codex's session database") }
            return .ready(PerItem(backup: session.files, backupName: "Codex session \(target)", restoreTo: nil,
                                  threadsBefore: before, treeSize: session.threads))
        case "claude":
            if let reason = await ClaudeOrphanProjectsRule.recheck(target, home: guardrails.home, state: state) { return .refused(reason) }
            if let reason = await ClaudeOrphanProjectsRule.dryRunRefusal(target, home: guardrails.home) { return .refused(reason) }
            let folder = "\(guardrails.home)/.claude/projects/\(ClaudeProjects.folderName(for: target))"
            return .ready(PerItem(backup: [folder], backupName: ClaudeProjects.folderName(for: target), restoreTo: folder))
        default:
            return .refused("refusing to run \(command.display)")
        }
    }

    enum BackedUp {
        case done(TrashedPath?)
        case failed(String)
    }

    func backUp(_ item: PerItem) -> BackedUp {
        let fm = FileManager.default
        let staging = (NSTemporaryDirectory() as NSString).appendingPathComponent("arin-backup-\(UUID().uuidString)")
        let copy = (staging as NSString).appendingPathComponent(item.backupName)
        defer { try? fm.removeItem(atPath: staging) }
        do {
            if let original = item.restoreTo {
                try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
                try fm.copyItem(atPath: original, toPath: copy)
            } else {
                try fm.createDirectory(atPath: copy, withIntermediateDirectories: true)
                for file in item.backup {
                    try fm.copyItem(atPath: file, toPath: (copy as NSString).appendingPathComponent((file as NSString).lastPathComponent))
                }
            }
            if let backupDirectory {
                let destination = (backupDirectory as NSString).appendingPathComponent("\(item.backupName)-\(UUID().uuidString)")
                try fm.moveItem(atPath: copy, toPath: destination)
                return .done(item.restoreTo.map { TrashedPath(original: $0, location: destination) })
            }
            var location: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: copy), resultingItemURL: &location)
            guard let path = location?.path else { return .failed("couldn't copy it to the Trash first") }
            return .done(item.restoreTo.map { TrashedPath(original: $0, location: path) })
        } catch {
            return .failed("couldn't copy it to the Trash first")
        }
    }

    func verify(_ command: CommandSpec, _ item: PerItem) async -> (failure: String?, stop: String?) {
        guard let target = command.arguments.last else { return ("refusing to run \(command.display)", nil) }
        switch command.executable {
        case "codex":
            let codexHome = "\(guardrails.home)/.codex"
            guard let after = await CodexSessionsRule.threadCount(codexHome: codexHome),
                  let left = await CodexSessionsRule.sessions(codexHome: codexHome, only: target)
            else { return (nil, "couldn't read Codex's session database after a delete") }
            if after < item.threadsBefore - item.treeSize {
                return (nil, "codex delete removed \(item.threadsBefore - after) threads instead of \(item.treeSize)")
            }
            return (left.isEmpty ? nil : "\(target): still listed after codex delete", nil)
        case "claude":
            return (item.restoreTo.map(FileInfo.exists) == true ? "\(target): still there after claude purge" : nil, nil)
        default:
            return ("refusing to run \(command.display)", nil)
        }
    }

    func runPerItem(_ candidate: Candidate, _ commands: [CommandSpec], state: SystemState) async -> CleanupItemResult {
        var done = 0
        var skipped: [String: Int] = [:]
        var failures: [String] = []
        var backups: [TrashedPath] = []
        var stopped: String?
        var state = state
        var captured = Date()
        let codexSupported = commands.first?.executable == "codex"
            ? await CodexSessionsRule.installedVersionSupported(codexHome: "\(guardrails.home)/.codex") : true
        for command in commands {
            if Task.isCancelled {
                skipped["cancelled", default: 0] += 1
                continue
            }
            if stopped != nil {
                skipped["stopped after an unexpected result", default: 0] += 1
                continue
            }
            if !codexSupported {
                skipped["this Codex version hasn't been checked with Arin", default: 0] += 1
                continue
            }
            if Date().timeIntervalSince(captured) >= stateMaxAge {
                state = await SystemState.capture()
                captured = Date()
            }
            if !state.openFilesKnown {
                skipped["couldn't check for open files", default: 0] += 1
                continue
            }
            let item: PerItem
            switch await prepare(command, state: state) {
            case let .refused(reason):
                skipped[reason, default: 0] += 1
                continue
            case let .ready(ready):
                item = ready
            }
            switch backUp(item) {
            case let .failed(reason):
                skipped[reason, default: 0] += 1
                continue
            case let .done(trashed):
                if let trashed { backups.append(trashed) }
            }
            let environment = command.executable == "codex" ? ["CODEX_HOME": "\(guardrails.home)/.codex"] : ["HOME": guardrails.home]
            let output = await Shell.run(command.executable, command.arguments, cwd: command.cwd,
                                         environment: environment, timeout: min(commandTimeout, 300))
            guard output.ok else {
                let tail = (output.timedOut ? "timed out" : (output.stderr.isEmpty ? output.stdout : output.stderr))
                    .trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
                failures.append("\(command.arguments.last ?? command.display): \(tail)")
                continue
            }
            let check = await verify(command, item)
            if let failure = check.failure { failures.append(failure) } else { done += 1 }
            if let stop = check.stop { stopped = stop }
        }
        let noun = commands.first?.executable == "codex" ? "sessions" : "projects"
        var parts = ["removed \(done) of \(commands.count) \(noun)"]
        if done > 0 { parts.append("copies are in the Trash") }
        if let stopped { parts.append("stopped: \(stopped)") }
        if !skipped.isEmpty {
            parts.append("skipped " + skipped.sorted { $0.value > $1.value }.map { "\($0.value) (\($0.key))" }.joined(separator: ", "))
        }
        if let first = failures.first {
            parts.append("\(failures.count) failed, first: \(first)")
        }
        var item = CleanupItemResult(id: candidate.id, title: candidate.title, status: .cleaned,
                                     message: parts.joined(separator: "; "), estimatedBytes: candidate.bytes,
                                     trashed: done > 0, trashedPaths: backups.isEmpty ? nil : backups)
        if done == commands.count { return item }
        if done == 0 {
            item.status = failures.isEmpty && stopped == nil ? .skipped : .failed
            item.estimatedBytes = 0
            return item
        }
        item.status = .partial
        let left = await Size.total(candidate.paths)
        item.estimatedBytes = max(0, candidate.bytes - left)
        return item
    }

    static func targetsMostlyGone(_ candidate: Candidate) async -> Bool {
        guard !candidate.paths.isEmpty, candidate.bytes > 0 else { return false }
        let remaining = await Size.total(candidate.paths)
        return remaining * 4 < candidate.bytes
    }

    func removeWorktree(
        _ candidate: Candidate,
        repo: String,
        path: String,
        head: String?,
        result: (CleanupItemResult.Status, String, Bool) -> CleanupItemResult
    ) async -> CleanupItemResult {
        guard FileInfo.exists(path) else {
            _ = await Shell.run("git", ["-C", repo, "worktree", "prune"], timeout: 30)
            return result(.cleaned, "already gone; pruned entry", false)
        }
        if let head {
            let current = await Shell.run("git", ["-C", path, "rev-parse", "HEAD"], timeout: 20)
            guard current.ok, current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
                return result(.skipped, "HEAD moved since the scan; rescan to recheck whether it's merged", false)
            }
        }
        if let reason = await GitSafety.worktreeRefusal(path) {
            return result(.skipped, "not removed: \(reason)", false)
        }
        let remove = await Shell.run("git", ["-C", repo, "worktree", "remove", path], timeout: 600)
        if remove.ok, !FileInfo.exists(path) { return result(.cleaned, "git worktree remove", false) }
        let message = remove.stderr + remove.stdout
        let permissionFailure = message.contains("Permission denied") || message.contains("Directory not empty")
        guard permissionFailure else {
            return result(.failed, message.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        let list = await Shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 30)
        let stillRegistered = WorktreeEntry.parse(list.stdout).contains { $0.path == path && !$0.prunable }
        guard list.ok, !stillRegistered else {
            return result(.failed, "git could not remove it and it is still registered: \(message.prefix(300))", false)
        }
        let removal = await delete([path])
        _ = await Shell.run("git", ["-C", repo, "worktree", "prune"], timeout: 30)
        return await Self.deleteResult(candidate, removal, paths: [path], done: "git worktree remove (fixed read-only files)")
    }

    static func deleteResult(_ candidate: Candidate, _ removal: TreeRemoval, paths: [String], done: String) async -> CleanupItemResult {
        var item = CleanupItemResult(id: candidate.id, title: candidate.title, status: .cleaned, message: done,
                                     estimatedBytes: candidate.bytes, trashed: false, trashedPaths: nil)
        guard !removal.isComplete else { return item }
        if removal.removedEntries == 0 {
            item.status = .failed
            item.message = "couldn't remove \(removal.problems)"
            item.estimatedBytes = 0
        } else {
            item.status = .partial
            item.message = "removed \(removal.removedEntries) entries, left \(removal.problems)"
            let left = await Size.allocated(paths)
            let measured = paths.allSatisfy { path in
                var st = stat()
                return left[path] != nil || (lstat(path, &st) != 0 && errno == ENOENT)
            }
            if removal.unreadFolders > 0 || !measured {
                item.estimatedBytes = 0
                item.message += " (the size of what's left is unknown)"
            } else {
                item.estimatedBytes = max(0, candidate.bytes - left.values.reduce(0, +))
            }
        }
        return item
    }

    func delete(_ paths: [String]) async -> TreeRemoval {
        var removal = TreeRemoval()
        for path in paths {
            do { try guardrails.check(path) } catch {
                removal.record(path, EPERM, advice: error.description)
                continue
            }
            removal.merge(await TreeRemover.remove(path))
        }
        return removal
    }

    func trash(_ paths: [String]) async -> (errors: [String], moved: [TrashedPath]) {
        var errors: [String] = []
        var moved: [TrashedPath] = []
        for path in paths {
            do { try guardrails.check(path) } catch { errors.append(error.description); continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                var location: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &location)
                if let location = location?.path { moved.append(TrashedPath(original: path, location: location)) }
            } catch {
                errors.append("\((path as NSString).abbreviatingWithTildeInPath): \(RemovalAdvice.advice(for: error, path: path))")
            }
        }
        return (errors, moved)
    }

    static func explain(_ report: CleanupReport, cleaned: [Candidate]) async -> [String] {
        var notes: [String] = []
        let trashedBytes = report.items.filter(\.trashed).reduce(0) { $0 + $1.estimatedBytes }
        if trashedBytes > 0 {
            notes.append("\(trashedBytes.formattedBytes) went to the Trash. Empty the Trash to free it.")
        }
        guard report.estimatedBytes > 512 * 1024 * 1024,
              Double(report.measuredBytes) < Double(report.estimatedBytes - trashedBytes) * 0.6
        else { return notes }

        let snapshots = await Disk.localSnapshots()
        if !snapshots.isEmpty {
            notes.append("\(snapshots.count) local snapshot(s) still reference deleted files. The space returns once they're removed, typically after a pending macOS update installs and you restart.")
        }
        notes.append("Estimates leave out blocks shared with files elsewhere, but snapshots and clones changed after they were copied can still hold blocks a deleted item used.")
        if cleaned.contains(where: { $0.category == .containers }) {
            notes.append("Docker's disk image hands space back to macOS gradually.")
        }
        if cleaned.contains(where: { $0.ruleID == "xcode.sim-runtimes" }) {
            notes.append("A deleted simulator runtime's image can stay mounted until you reboot.")
        }
        notes.append("Other apps may have written to disk during the cleanup.")
        return notes
    }
}

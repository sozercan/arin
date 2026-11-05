import Foundation

public struct CleanupItemResult: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case cleaned, skipped, failed
    }

    public var id: String
    public var title: String
    public var status: Status
    public var message: String
    public var estimatedBytes: Int64
    public var trashed: Bool
}

public struct CleanupReport: Codable, Sendable {
    public var items: [CleanupItemResult]
    public var freeBefore: Int64
    public var freeAfter: Int64
    /// What `du` said the cleaned items used. Not the same as space freed.
    public var estimatedBytes: Int64
    public var explanations: [String]

    /// Net change in free space, measured on the volume.
    public var measuredBytes: Int64 { freeAfter - freeBefore }
    public var cleanedCount: Int { items.filter { $0.status == .cleaned }.count }
}

public enum CleanupEvent: Sendable {
    case started(total: Int)
    case item(index: Int, title: String)
    case finished(CleanupItemResult)
}

public struct Executor: Sendable {
    public var guardrails: Guardrails
    /// Move deleted paths to the Trash instead. Reversible, but frees nothing until the Trash is emptied.
    public var trashInsteadOfDelete: Bool
    public var commandTimeout: TimeInterval

    public init(guardrails: Guardrails = Guardrails(), trashInsteadOfDelete: Bool = false, commandTimeout: TimeInterval = 1800) {
        self.guardrails = guardrails
        self.trashInsteadOfDelete = trashInsteadOfDelete
        self.commandTimeout = commandTimeout
    }

    public func run(_ candidates: [Candidate], progress: (@Sendable (CleanupEvent) -> Void)? = nil) async -> CleanupReport {
        let before = Disk.status(path: guardrails.home).freeBytes
        let state = await SystemState.capture()
        progress?(.started(total: candidates.count))

        var results: [CleanupItemResult] = []
        for (index, candidate) in candidates.enumerated() {
            progress?(.item(index: index, title: candidate.title))
            let result = await clean(candidate, state: state)
            results.append(result)
            progress?(.finished(result))
        }

        let after = Disk.status(path: guardrails.home).freeBytes
        let cleaned = results.filter { $0.status == .cleaned }
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

    func clean(_ candidate: Candidate, state: SystemState) async -> CleanupItemResult {
        func result(_ status: CleanupItemResult.Status, _ message: String, trashed: Bool = false) -> CleanupItemResult {
            CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                status: status,
                message: message,
                estimatedBytes: status == .cleaned ? candidate.bytes : 0,
                trashed: trashed
            )
        }

        guard candidate.isActionable else { return result(.skipped, "informational only") }
        do { try guardrails.check(candidate.action) } catch { return result(.skipped, error.description) }

        // Re-check right before acting: things change between scan and clean.
        let live = state.blockers(
            paths: candidate.paths,
            processes: candidate.blockingProcesses,
            minIdle: candidate.minIdleSeconds
        )
        if !live.isEmpty { return result(.skipped, live.joined(separator: "; ")) }

        switch candidate.action {
        case .none:
            return result(.skipped, "informational only")

        case let .delete(paths):
            if trashInsteadOfDelete {
                let errors = await trash(paths)
                return errors.isEmpty ? result(.cleaned, "moved to Trash", trashed: true) : result(.failed, errors.joined(separator: "; "))
            }
            let errors = await delete(paths)
            return errors.isEmpty ? result(.cleaned, "deleted") : result(.failed, errors.joined(separator: "; "))

        case let .trash(paths):
            let errors = await trash(paths)
            return errors.isEmpty ? result(.cleaned, "moved to Trash", trashed: true) : result(.failed, errors.joined(separator: "; "))

        case let .commands(commands):
            var warnings: [String] = []
            for command in commands {
                guard Guardrails.allowedExecutables.contains(command.executable) else {
                    return result(.skipped, "refusing to run \(command.executable)")
                }
                let output = await Shell.run(command.executable, command.arguments, cwd: command.cwd, timeout: commandTimeout)
                if !output.ok {
                    let tail = String((output.stderr.isEmpty ? output.stdout : output.stderr).suffix(400))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if output.timedOut { return result(.failed, "\(command.display) timed out") }
                    // Tools like `brew cleanup` exit non-zero over one bad formula after cleaning
                    // everything else. Judge by what's left on disk, not the exit code.
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

        case let .removeWorktree(repo, path):
            return await removeWorktree(repo: repo, path: path, result: result)
        }
    }

    /// True when the candidate's folders now use under a quarter of their scanned size.
    static func targetsMostlyGone(_ candidate: Candidate) async -> Bool {
        guard !candidate.paths.isEmpty, candidate.bytes > 0 else { return false }
        let remaining = await Size.total(candidate.paths)
        return remaining * 4 < candidate.bytes
    }

    func removeWorktree(
        repo: String,
        path: String,
        result: (CleanupItemResult.Status, String, Bool) -> CleanupItemResult
    ) async -> CleanupItemResult {
        guard FileInfo.exists(path) else {
            _ = await Shell.run("git", ["-C", repo, "worktree", "prune"], timeout: 30)
            return result(.cleaned, "already gone; pruned entry", false)
        }
        // No --force: git refuses if there are uncommitted or untracked files.
        let remove = await Shell.run("git", ["-C", repo, "worktree", "remove", path], timeout: 600)
        if remove.ok, !FileInfo.exists(path) { return result(.cleaned, "git worktree remove", false) }
        let message = remove.stderr + remove.stdout
        // Read-only files (Go module caches, envtest binaries) make git's own removal fail midway,
        // after it has already verified the tree is clean. Only that failure gets a manual finish;
        // anything else (dirty, locked, not a worktree) is reported and the folder is left alone.
        let permissionFailure = message.contains("Permission denied") || message.contains("Directory not empty")
        guard permissionFailure else {
            return result(.failed, message.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        let list = await Shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 30)
        let stillRegistered = WorktreeEntry.parse(list.stdout).contains { $0.path == path && !$0.prunable }
        guard list.ok, !stillRegistered else {
            return result(.failed, "git could not remove it and it is still registered: \(message.prefix(300))", false)
        }
        let errors = await delete([path])
        _ = await Shell.run("git", ["-C", repo, "worktree", "prune"], timeout: 30)
        if errors.isEmpty { return result(.cleaned, "git worktree remove (fixed read-only files)", false) }
        return result(.failed, errors.joined(separator: "; "), false)
    }

    /// Deletes paths, retrying once after `chmod -R u+w` for read-only trees.
    func delete(_ paths: [String]) async -> [String] {
        var errors: [String] = []
        for path in paths {
            do { try guardrails.check(path) } catch { errors.append(error.description); continue }
            guard FileManager.default.fileExists(atPath: path) || FileInfo.resolveSymlink(path) != nil else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { continue }
            _ = await Shell.run("chmod", ["-R", "u+w", path], timeout: 300)
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                // removeItem stops at the first failure; rm reports what's actually stuck.
                let rm = await Shell.run("rm", ["-rf", path], timeout: 900)
                if FileManager.default.fileExists(atPath: path) {
                    errors.append("\((path as NSString).abbreviatingWithTildeInPath): \(rm.stderr.isEmpty ? error.localizedDescription : String(rm.stderr.prefix(300)))")
                }
            }
        }
        return errors
    }

    func trash(_ paths: [String]) async -> [String] {
        var errors: [String] = []
        for path in paths {
            do { try guardrails.check(path) } catch { errors.append(error.description); continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                errors.append("\((path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
            }
        }
        return errors
    }

    /// When the measured gain falls short of the estimate, say why instead of reporting the estimate.
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
        notes.append("du counts APFS clones and shared blocks in full, so the folder totals overstate what deleting frees.")
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

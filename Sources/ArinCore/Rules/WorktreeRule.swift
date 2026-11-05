import Foundation

struct WorktreeEntry: Equatable {
    var path: String
    var head: String?
    var branch: String?
    var locked = false
    var prunable = false
    var bare = false

    /// Parses `git worktree list --porcelain`.
    static func parse(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            } else if line == "bare" {
                current?.bare = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }
}

/// Linked git worktrees whose work is already merged, plus worktrunk trash and stale entries.
/// "Merged" means HEAD is in the default branch, or a merged PR has the same (or a later) head,
/// which catches squash merges.
struct WorktreeRule: Rule {
    let id = "git.worktrees"
    let name = "Merged git worktrees"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let repos = await Self.repositories(roots: ctx.options.projectRoots)
        let perRepo = await concurrentMap(repos, limit: 4) { repo in
            await Self.scanRepo(repo, ctx: ctx)
        }
        return perRepo.flatMap { $0 }
    }

    /// Main checkouts (a real `.git` directory) under the roots.
    static func repositories(roots: [String]) async -> [String] {
        var repos: [String] = []
        for root in roots {
            let result = await Shell.run(
                "find",
                [root, "-maxdepth", "5", "-name", "node_modules", "-prune", "-o", "-type", "d", "-name", ".git", "-prune", "-print"],
                timeout: 120
            )
            for gitDir in result.lines {
                let repo = (gitDir as NSString).deletingLastPathComponent
                if !repos.contains(repo) { repos.append(repo) }
            }
        }
        return repos
    }

    static func scanRepo(_ repo: String, ctx: ScanContext) async -> [Candidate] {
        var result: [Candidate] = []
        let repoName = (repo as NSString).abbreviatingWithTildeInPath

        // worktrunk (`wt`) keeps removed worktrees in .git/wt/trash until emptied.
        let trash = "\(repo)/.git/wt/trash"
        let trashed = FileInfo.children(trash)
        if !trashed.isEmpty {
            result.append(Candidate(
                ruleID: "git.wt-trash",
                key: trash,
                title: "worktrunk trash · \(repoName) (\(trashed.count))",
                detail: "Worktrees `wt` already removed but never emptied from its trash. Nothing registered points at them.",
                category: .worktrees,
                level: .quick,
                risk: .safe,
                bytes: await Size.total(trashed),
                paths: trashed,
                action: .delete(trashed)
            ))
        }

        let list = await Shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 30)
        guard list.ok else { return result }
        let entries = WorktreeEntry.parse(list.stdout)
        let linked = entries.dropFirst().filter { !$0.bare }
        guard !linked.isEmpty else { return result }

        let prunable = linked.filter(\.prunable)
        if !prunable.isEmpty {
            result.append(Candidate(
                ruleID: "git.worktree-prune",
                key: repo,
                title: "Stale worktree entries · \(repoName) (\(prunable.count))",
                detail: "Git still lists worktrees whose folders are gone. `git worktree prune` tidies the list; it frees no space.",
                category: .worktrees,
                level: .quick,
                risk: .safe,
                bytes: 0,
                paths: [],
                action: .commands([CommandSpec("git", ["-C", repo, "worktree", "prune"])])
            ))
        }

        if ctx.options.fetchRemotes {
            _ = await Shell.run("git", ["-C", repo, "fetch", "--prune", "--quiet", "origin"], timeout: 120)
        }
        guard let base = await defaultBranch(repo) else { return result }
        let prs = ctx.options.checkPullRequests ? await mergedPRs(repo) : [:]

        let live = linked.filter { !$0.prunable && !$0.locked && FileInfo.isDirectory($0.path) }
        let classified = await concurrentMap(Array(live), limit: 6) { entry -> Candidate? in
            await classify(entry, repo: repo, base: base, prs: prs, ctx: ctx)
        }
        result += classified.compactMap { $0 }
        return result
    }

    static func classify(
        _ entry: WorktreeEntry,
        repo: String,
        base: String,
        prs: [String: [(oid: String, number: Int)]],
        ctx: ScanContext
    ) async -> Candidate? {
        guard let head = entry.head else { return nil }
        var mergedBy: String?
        let ancestor = await Shell.run("git", ["-C", repo, "merge-base", "--is-ancestor", head, base], timeout: 20)
        if ancestor.status == 0 {
            mergedBy = "already in \(base)"
        } else if let branch = entry.branch, let matches = prs[branch] {
            for pr in matches {
                if pr.oid == head {
                    mergedBy = "PR #\(pr.number) merged at this commit"
                    break
                }
                let behind = await Shell.run("git", ["-C", repo, "merge-base", "--is-ancestor", head, pr.oid], timeout: 20)
                if behind.status == 0 {
                    mergedBy = "PR #\(pr.number) merged; this branch is behind its final commit"
                    break
                }
            }
        }
        guard let mergedBy else { return nil }

        let status = await Shell.run("git", ["-C", entry.path, "status", "--porcelain"], timeout: 60)
        guard status.ok else { return nil }
        let dirty = status.lines.count
        var risk: Risk = dirty == 0 ? .safe : .review
        var notes: [String] = [mergedBy.prefix(1).uppercased() + mergedBy.dropFirst() + "."]
        if dirty > 0 { notes.append("Has \(dirty) uncommitted or untracked files; `git worktree remove` will refuse until you look.") }
        var blockers: [String] = []
        if ctx.state.isBusy(entry.path) { blockers.append("a process is working inside it") }
        if entry.path.contains("/.t3/worktrees/") {
            risk = max(risk, .review)
            notes.append("Created by T3; a live thread may still use it and recreate it.")
        }
        notes.append("The branch is kept.")

        let bytes = await Size.allocated(entry.path)
        let label = entry.branch ?? String(head.prefix(8))
        return Candidate(
            ruleID: "git.worktree",
            key: entry.path,
            title: "\((entry.path as NSString).lastPathComponent) · \(label)",
            detail: notes.joined(separator: " "),
            category: .worktrees,
            level: .standard,
            risk: risk,
            bytes: bytes,
            paths: [entry.path],
            action: .removeWorktree(repo: repo, path: entry.path),
            lastModified: FileInfo.modified(entry.path),
            blockers: blockers
        )
    }

    static func defaultBranch(_ repo: String) async -> String? {
        let head = await Shell.run("git", ["-C", repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], timeout: 10)
        if head.ok, let ref = head.lines.first { return ref }
        for ref in ["origin/main", "origin/master", "main", "master"] {
            let verify = await Shell.run("git", ["-C", repo, "rev-parse", "--verify", "-q", ref], timeout: 10)
            if verify.ok { return ref }
        }
        return nil
    }

    struct PR: Decodable {
        var number: Int
        var headRefName: String
        var headRefOid: String
    }

    static func mergedPRs(_ repo: String) async -> [String: [(oid: String, number: Int)]] {
        guard Shell.which("gh") != nil else { return [:] }
        let remote = await Shell.run("git", ["-C", repo, "remote", "get-url", "origin"], timeout: 10)
        guard remote.ok, remote.stdout.contains("github.com") else { return [:] }
        let result = await Shell.run(
            "gh",
            ["pr", "list", "--state", "merged", "--limit", "1000", "--json", "number,headRefName,headRefOid"],
            cwd: repo,
            timeout: 90
        )
        guard result.ok, let prs = try? JSONDecoder().decode([PR].self, from: Data(result.stdout.utf8)) else { return [:] }
        var map: [String: [(oid: String, number: Int)]] = [:]
        for pr in prs { map[pr.headRefName, default: []].append((pr.headRefOid, pr.number)) }
        return map
    }
}

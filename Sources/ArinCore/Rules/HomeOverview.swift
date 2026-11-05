import Foundation

/// Finds large folders anywhere in the home folder that no rule explains, so space a fixed
/// list of locations would miss (agent task artifacts, app logs, VM disks) still shows up.
///
/// One `du -k -d 5` per top-level folder gives every directory size in a single walk. A folder
/// is reported as specifically as possible: when one subfolder holds most of it, or it contains
/// something a rule already handles, Arin descends instead of reporting the parent.
enum HomeOverview {
    static let minimum: Int64 = 1024 * 1024 * 1024
    static let maxDepth = 5

    /// Home-relative folders the overview never reports or enters: personal data, things other
    /// rules or insights handle, and data with its own deletion tools.
    static let skipped = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
        ".Trash", ".codex/sessions", "Library/Caches", "Library/Application Support", "Library/Developer",
        ".cache", "Library/Mobile Documents", "Library/CloudStorage",
        // Claude Code history and memory; agent history has its own retention tools.
        ".claude/projects",
    ]

    static func discover(_ ctx: ScanContext, claimed: [String]) async -> [Candidate] {
        let home = ctx.home
        let guardrails = Guardrails(home: home, tmpDir: ctx.options.tmpDir)
        let skip = skipped.map { "\(home)/\($0)" } + guardrails.protectedPaths + ctx.options.projectRoots

        let appleContainers = "\(home)/Library/Containers/com.apple."
        func isSkipped(_ path: String) -> Bool {
            path.hasPrefix(appleContainers) || skip.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // Top-level folders in home, plus ~/Library's children (Library itself is too broad).
        var tops = FileInfo.children(home).filter { FileInfo.isDirectory($0) && !isSkipped($0) }
        tops.removeAll { $0 == "\(home)/Library" }
        tops += FileInfo.children("\(home)/Library").filter { FileInfo.isDirectory($0) && !isSkipped($0) }

        let walks = await concurrentMap(tops, limit: 4) { top -> [String: Int64] in
            let result = await Shell.run("du", ["-k", "-d", String(maxDepth), top], timeout: 300)
            var sizes: [String: Int64] = [:]
            for (path, kb) in Size.parseDu(result.stdout) { sizes[path] = kb * 1024 }
            return sizes
        }
        var sizes: [String: Int64] = [:]
        for walk in walks { sizes.merge(walk) { a, _ in a } }

        // Things a reported folder must not contain: claimed paths, skipped paths, project roots.
        let avoid = claimed + skip
        let picked = tops.flatMap { top in
            pick(top, sizes: sizes, depth: 0, avoid: avoid, isSkipped: isSkipped)
        }

        return picked.compactMap { path -> Candidate? in
            guard let bytes = sizes[path], (try? guardrails.check(path)) != nil else { return nil }
            // A git checkout holds work that may not be pushed; worktree rules handle those.
            if FileInfo.exists("\(path)/.git") { return nil }
            let display = (path as NSString).abbreviatingWithTildeInPath
            return Candidate(
                ruleID: "unclassified.home",
                key: path,
                title: display,
                detail: "A large folder no rule explains. It may be leftover output from tools or agents, or data an app still needs. Your agent checks what's inside; if removed, it goes to the Trash.",
                category: .unclassified,
                level: .deep,
                risk: .review,
                bytes: bytes,
                paths: [path],
                action: .trash([path]),
                lastModified: FileInfo.modified(path),
                blockers: ctx.state.isBusy(path) ? ["files are open by a running process"] : []
            )
        }
    }

    /// Picks the most specific folders worth reporting under `dir`.
    static func pick(
        _ dir: String,
        sizes: [String: Int64],
        depth: Int,
        avoid: [String],
        isSkipped: (String) -> Bool
    ) -> [String] {
        guard let size = sizes[dir], size >= minimum, !isSkipped(dir) else { return [] }
        // Already handled by a rule (or inside something that is).
        if avoid.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { return [] }
        let prefix = dir + "/"
        let big = sizes.filter { path, bytes in
            bytes >= minimum && path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")
        }.map(\.key).sorted()

        let containsAvoided = avoid.contains { $0.hasPrefix(prefix) }
        let dominated = big.count == 1 && Double(sizes[big[0]] ?? 0) >= Double(size) * 0.6
        // depth 0 is a top-level folder like ~/.t3: too broad to remove as a whole.
        let mustDescend = depth == 0 || containsAvoided || dominated || big.count > 1

        if mustDescend, depth < maxDepth, !big.isEmpty {
            return big.flatMap { pick($0, sizes: sizes, depth: depth + 1, avoid: avoid, isSkipped: isSkipped) }
        }
        if depth == 0 || containsAvoided { return [] }
        return [dir]
    }
}

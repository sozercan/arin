import Foundation

enum HomeOverview {
    static let minimum: Int64 = 1024 * 1024 * 1024
    static let maxDepth = 5

    static let skipped = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
        ".Trash", ".codex/sessions", "Library/Caches", "Library/Application Support", "Library/Developer",
        ".cache", "Library/Mobile Documents", "Library/CloudStorage",
        ".claude/projects", ".codex/archived_sessions", ".copilot/session-state",
    ]

    static func discover(_ ctx: ScanContext, claimed: [String]) async -> [Candidate] {
        let home = ctx.home
        let guardrails = Guardrails(home: home, tmpDir: ctx.options.tmpDir)
        let skip = skipped.map { "\(home)/\($0)" } + guardrails.protectedPaths + ctx.options.projectRoots

        let appleContainers = "\(home)/Library/Containers/com.apple."
        func isSkipped(_ path: String) -> Bool {
            path.hasPrefix(appleContainers) || skip.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

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

        let avoid = claimed + skip
        let picked = tops.flatMap { top in
            pick(top, sizes: sizes, depth: 0, avoid: avoid, isSkipped: isSkipped)
        }

        var reportable: [String] = []
        for path in picked where await GitSafety.repositoryRefusal(in: path, skipPackageCaches: true) == nil { reportable.append(path) }

        let measured = await Size.allocated(reportable)
        return reportable.compactMap { path -> Candidate? in
            guard let bytes = measured[path] ?? sizes[path], bytes >= minimum, (try? guardrails.check(path)) != nil else { return nil }
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

    static func pick(
        _ dir: String,
        sizes: [String: Int64],
        depth: Int,
        avoid: [String],
        isSkipped: (String) -> Bool
    ) -> [String] {
        guard let size = sizes[dir], size >= minimum, !isSkipped(dir) else { return [] }
        if avoid.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { return [] }
        if (dir as NSString).lastPathComponent == ".git" || FileInfo.exists("\(dir)/.git") { return [] }
        let prefix = dir + "/"
        let big = sizes.filter { path, bytes in
            bytes >= minimum && path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")
        }.map(\.key).sorted()

        let containsAvoided = avoid.contains { $0.hasPrefix(prefix) }
        let dominated = big.count == 1 && Double(sizes[big[0]] ?? 0) >= Double(size) * 0.6
        let mustDescend = depth == 0 || containsAvoided || dominated || big.count > 1

        if mustDescend, depth < maxDepth, !big.isEmpty {
            return big.flatMap { pick($0, sizes: sizes, depth: depth + 1, avoid: avoid, isSkipped: isSkipped) }
        }
        if depth == 0 || containsAvoided { return [] }
        return [dir]
    }
}

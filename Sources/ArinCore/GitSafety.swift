import Foundation

public enum GitSafety {
    public static func repositoryRefusal(in dir: String, skipPackageCaches: Bool = false) async -> String? {
        if (dir as NSString).lastPathComponent == ".git" { return "is a git repository" }
        if isGitDirectory(dir) { return "is a git repository" }
        var args = [dir, "-mindepth", "1"]
        if skipPackageCaches {
            args += ["(", "-path", "*/pkg/mod", "-o", "-name", "node_modules", ")", "-prune", "-o"]
        }
        args += ["(", "-name", ".git", "-print0", "-prune", ")", "-o", "(", "(", "-type", "f", "-o", "-type", "l", ")", "-name", "HEAD", "-print0", ")"]
        let found = await Shell.run("find", args, timeout: 180)
        guard found.ok else {
            return found.timedOut ? "too large to search for git repositories in time" : "parts of it couldn't be read to check for git repositories"
        }

        var checkouts: [String] = []
        var mirrors: [String] = []
        for line in found.stdout.split(separator: "\0").map(String.init) {
            let name = (line as NSString).lastPathComponent
            let parent = (line as NSString).deletingLastPathComponent
            if name == ".git" {
                if isSwiftPMSlot(parent, "checkouts"), FileInfo.isDirectory(line), !FileInfo.isSymlink(line) {
                    checkouts.append(parent)
                    continue
                }
                return "contains a git repository at \(relative(parent, to: dir))"
            }
            guard isGitDirectory(parent) else { continue }
            if !sharesGitDirectory(parent), isSwiftPMSlot(parent, "repositories") {
                mirrors.append(parent)
                continue
            }
            return "contains a git repository at \(relative(parent, to: dir))"
        }
        for mirror in mirrors {
            if let problem = await swiftPMMirrorProblem(mirror) {
                return "contains a git repository at \(relative(mirror, to: dir)) that \(problem)"
            }
        }
        for checkout in checkouts {
            if let problem = await swiftPMCheckoutProblem(checkout) {
                return "contains a git repository at \(relative(checkout, to: dir)) that \(problem)"
            }
        }
        return nil
    }

    public static func trackingRefusal(_ path: String) async -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let inside = await git(parent, ["rev-parse", "--is-inside-work-tree"])
        guard inside.ok else {
            if !inside.timedOut, !hasGitEntry(above: parent) { return nil }
            return "git couldn't tell whether it's ignored"
        }
        guard inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return "it's inside a git directory"
        }
        let tracked = await git(parent, ["ls-files", "-z", "--", name], literal: true)
        guard tracked.ok else { return "git couldn't list the files it tracks there" }
        if !tracked.stdout.isEmpty { return "git tracks files inside it" }
        let ignored = await git(parent, ["check-ignore", "-q", "--", name])
        switch ignored.status {
        case 0 where !ignored.timedOut: return nil
        case 1: return "git doesn't ignore it, so it may hold work"
        default: return "git couldn't tell whether it's ignored"
        }
    }

    public static func worktreeRefusal(_ worktree: String) async -> String? {
        let flags = await git(worktree, ["ls-files", "-v", "-z"])
        guard flags.ok else { return "git couldn't list its files" }
        let hidden = flags.stdout.split(separator: "\0").compactMap { entry -> String? in
            guard let tag = entry.first, tag.isLowercase || tag == "S", entry.count > 2 else { return nil }
            let file = String(entry.dropFirst(2))
            return FileInfo.exists((worktree as NSString).appendingPathComponent(file)) || FileInfo.isSymlink((worktree as NSString).appendingPathComponent(file)) ? file : nil
        }
        if let first = hidden.first {
            let more = hidden.count > 1 ? " and \(hidden.count - 1) more" : ""
            return "\(first)\(more) is marked assume-unchanged or skip-worktree, so git status can't show edits to it"
        }

        let ignored = await git(worktree, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        guard ignored.ok else { return "git couldn't list its ignored files" }
        let entries = ignored.stdout.split(separator: "\0").map(String.init)
        for entry in entries {
            let parent = ((worktree as NSString).appendingPathComponent(entry) as NSString).deletingLastPathComponent
            guard realPath(parent) != realPath(worktree) else { continue }
            let dotGit = (parent as NSString).appendingPathComponent(".git")
            if isGitDirectory(parent) || FileInfo.exists(dotGit) || FileInfo.isSymlink(dotGit) {
                return "the ignored files in \(relative(parent, to: worktree))/ are in a git repository"
            }
        }
        for entry in entries where entry.hasSuffix("/") {
            let path = (worktree as NSString).appendingPathComponent(String(entry.dropLast()))
            guard !FileInfo.isSymlink(path) else { continue }
            if let reason = await repositoryRefusal(in: path, skipPackageCaches: true) {
                return "the ignored folder \(entry) \(reason)"
            }
        }
        return nil
    }


    static func swiftPMCheckoutProblem(_ checkout: String) async -> String? {
        let status = await git(checkout, ["status", "--porcelain", "--ignored", "--untracked-files=all", "--ignore-submodules=none"])
        guard status.ok else { return "git couldn't check" }
        if !status.stdout.isEmpty { return "has changed, untracked, or ignored files" }

        let stash = await git(checkout, ["stash", "list"])
        guard stash.ok else { return "git couldn't check" }
        if !stash.stdout.isEmpty { return "has stashed changes" }

        let worktrees = await git(checkout, ["worktree", "list", "--porcelain"])
        guard worktrees.ok else { return "git couldn't check" }
        if worktrees.lines.filter({ $0.hasPrefix("worktree ") }).count > 1 { return "has linked worktrees" }

        let flags = await git(checkout, ["ls-files", "-v", "-z"])
        guard flags.ok else { return "git couldn't check" }
        if flags.stdout.split(separator: "\0").contains(where: { $0.first.map { $0.isLowercase || $0 == "S" } ?? false }) {
            return "has files marked assume-unchanged or skip-worktree"
        }

        let url = await git(checkout, ["remote", "get-url", "origin"])
        let origin = url.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositories = (((checkout as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("repositories")
        guard url.ok, origin.hasPrefix("/"), FileInfo.isDirectory(origin),
              realPath((origin as NSString).deletingLastPathComponent) == realPath(repositories)
        else {
            return "doesn't come from SwiftPM's mirror beside it"
        }
        let refs = await git(checkout, ["ls-remote", origin])
        guard refs.ok else { return "git couldn't read its mirror" }
        let mirrored = Set(refs.lines.compactMap { $0.split(separator: "\t").first.map(String.init) })
        let unique = await git(checkout, ["rev-list", "--ignore-missing", "--max-count=1", "HEAD", "--exclude=refs/remotes/*", "--all", "--not"]
            + mirrored.sorted())
        guard unique.ok else { return "git couldn't check" }
        if !unique.stdout.isEmpty { return "has commits its mirror doesn't have" }
        return nil
    }

    static func swiftPMMirrorProblem(_ mirror: String) async -> String? {
        let bare = await git(mirror, ["rev-parse", "--is-bare-repository"])
        guard bare.ok, bare.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return "isn't a bare SwiftPM mirror"
        }
        let worktrees = (mirror as NSString).appendingPathComponent("worktrees")
        if FileInfo.isSymlink(worktrees) || !FileInfo.children(worktrees).isEmpty { return "has linked worktrees" }
        let stash = await git(mirror, ["rev-parse", "--verify", "-q", "refs/stash"])
        switch stash.status {
        case 1 where !stash.timedOut: return nil
        case 0: return "has stashed changes"
        default: return "git couldn't check"
        }
    }


    static func hasGitEntry(above path: String) -> Bool {
        var dir = path
        while true {
            var info = stat()
            if lstat((dir as NSString).appendingPathComponent(".git"), &info) == 0 || errno != ENOENT { return true }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return false }
            dir = parent
        }
    }

    static func isGitDirectory(_ dir: String) -> Bool {
        let head = (dir as NSString).appendingPathComponent("HEAD")
        guard FileInfo.exists(head) || FileInfo.isSymlink(head) else { return false }
        if sharesGitDirectory(dir) { return true }
        return FileInfo.isDirectory((dir as NSString).appendingPathComponent("objects"))
            && FileInfo.isDirectory((dir as NSString).appendingPathComponent("refs"))
    }

    static func sharesGitDirectory(_ dir: String) -> Bool {
        ["commondir", "gitdir"].contains { name in
            let path = (dir as NSString).appendingPathComponent(name)
            return FileInfo.exists(path) || FileInfo.isSymlink(path)
        }
    }

    static func isSwiftPMSlot(_ path: String, _ slot: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == slot else { return false }
        let scratch = (parent as NSString).deletingLastPathComponent
        return [".build", "SourcePackages"].contains((scratch as NSString).lastPathComponent)
            || FileInfo.exists((scratch as NSString).appendingPathComponent("workspace-state.json"))
    }

    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func relative(_ path: String, to dir: String) -> String {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).abbreviatingWithTildeInPath
    }

    static func git(_ dir: String, _ args: [String], literal: Bool = false) async -> ShellResult {
        await Shell.run("git", ["-C", dir] + args, environment: literal ? ["GIT_LITERAL_PATHSPECS": "1"] : [:], timeout: 30)
    }
}

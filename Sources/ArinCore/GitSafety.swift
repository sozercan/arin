import Foundation

/// Checks that a folder holds no git work that deleting it would lose. Ignored folders are invisible
/// to the enclosing repository, so its `git status` can't vouch for them: a clone inside one can carry
/// commits that exist nowhere else. Every answer that isn't a clear "nothing here" is a refusal.
public enum GitSafety {
    /// Why `dir` must not be deleted because it is, or holds, a git repository, or nil when it holds none.
    ///
    /// A repository is a `.git` entry of any type, a bare repository (`HEAD` beside `objects/` and
    /// `refs/`), or a git directory that borrows another's objects (`commondir` or `gitdir`, as a linked
    /// worktree's has). SwiftPM's clones in `.build` and `SourcePackages` pass only when they hold
    /// nothing SwiftPM can't fetch again. With `skipPackageCaches`, the Go module cache and
    /// `node_modules` aren't searched: their tools strip or own any repositories inside.
    /// An unreadable folder, or a search that doesn't finish, counts as holding a repository.
    public static func repositoryRefusal(in dir: String, skipPackageCaches: Bool = false) async -> String? {
        if (dir as NSString).lastPathComponent == ".git" { return "is a git repository" }
        if isGitDirectory(dir) { return "is a git repository" }
        var args = [dir, "-mindepth", "1"]
        if skipPackageCaches {
            args += ["(", "-path", "*/pkg/mod", "-o", "-name", "node_modules", ")", "-prune", "-o"]
        }
        args += ["(", "-name", ".git", "-print", "-prune", ")", "-o", "(", "-type", "f", "-name", "HEAD", "-print", ")"]
        let found = await Shell.run("find", args, timeout: 180)
        guard found.ok else {
            return found.timedOut ? "too large to search for git repositories in time" : "parts of it couldn't be read to check for git repositories"
        }

        var checkouts: [String] = []
        var mirrors: [String] = []
        for line in found.lines {
            let name = (line as NSString).lastPathComponent
            let parent = (line as NSString).deletingLastPathComponent
            if name == ".git" {
                // A .git file or symlink can point at a repository anywhere; only a real directory in a
                // SwiftPM checkout is SwiftPM's own.
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
            let bare = await git(mirror, ["rev-parse", "--is-bare-repository"])
            guard bare.ok, bare.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return "contains a git repository at \(relative(mirror, to: dir)) that isn't a bare SwiftPM mirror"
            }
        }
        for checkout in checkouts {
            if let problem = await swiftPMCheckoutProblem(checkout) {
                return "contains a git repository at \(relative(checkout, to: dir)) that \(problem)"
            }
        }
        return nil
    }

    /// Why a folder in a project must not be deleted as build output: it isn't ignored by git, or git
    /// tracks files inside it. Nil when it is ignored and untracked, or when no repository holds it.
    public static func trackingRefusal(_ path: String) async -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let inside = await git(parent, ["rev-parse", "--is-inside-work-tree"])
        guard inside.ok else {
            // No repository anywhere above: nothing for git to protect. A .git that git can't use is
            // not the same as no repository.
            if !inside.timedOut, ProjectActivity.gitDirectory(above: parent) == nil { return nil }
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

    /// Why removing a clean worktree would still lose work, or nil. `git worktree remove` checks only
    /// what `git status` shows: it deletes ignored folders, clones inside them included, and edits to
    /// files marked assume-unchanged or skip-worktree.
    public static func worktreeRefusal(_ worktree: String) async -> String? {
        let flags = await git(worktree, ["ls-files", "-v", "-z"])
        guard flags.ok else { return "git couldn't list its files" }
        let hidden = flags.stdout.split(separator: "\0").compactMap { entry -> String? in
            guard let tag = entry.first, tag.isLowercase || tag == "S", entry.count > 2 else { return nil }
            let file = String(entry.dropFirst(2))
            // Sparse checkouts mark files they leave off disk; only a file that's there can hold edits.
            return FileInfo.exists((worktree as NSString).appendingPathComponent(file)) || FileInfo.isSymlink((worktree as NSString).appendingPathComponent(file)) ? file : nil
        }
        if let first = hidden.first {
            let more = hidden.count > 1 ? " and \(hidden.count - 1) more" : ""
            return "\(first)\(more) is marked assume-unchanged or skip-worktree, so git status can't show edits to it"
        }

        let ignored = await git(worktree, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        guard ignored.ok else { return "git couldn't list its ignored files" }
        for entry in ignored.stdout.split(separator: "\0").map(String.init) where entry.hasSuffix("/") {
            let path = (worktree as NSString).appendingPathComponent(String(entry.dropLast()))
            guard !FileInfo.isSymlink(path) else { continue }
            if let reason = await repositoryRefusal(in: path, skipPackageCaches: true) {
                return "the ignored folder \(entry) \(reason)"
            }
        }
        return nil
    }

    // MARK: SwiftPM

    /// Why a SwiftPM checkout holds work `swift package resolve` can't restore, or nil. SwiftPM clones
    /// each dependency from its bare mirror in `repositories` and checks out a pinned commit; such a
    /// checkout has no changes, no stash, no other worktrees, and no commit its origin lacks.
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

        // Its origin must be the local mirror SwiftPM cloned it from; asking a network remote would
        // make a scan slow and depend on the network.
        let url = await git(checkout, ["remote", "get-url", "origin"])
        let origin = url.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let repositories = (((checkout as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("repositories")
        guard url.ok, origin.hasPrefix("/"), FileInfo.isDirectory(origin),
              realPath((origin as NSString).deletingLastPathComponent) == realPath(repositories)
        else {
            return "doesn't come from SwiftPM's mirror beside it"
        }
        // Commits the origin holds: its branches (as remote-tracking refs) and its tags. A tag only
        // the checkout has doesn't count.
        let tags = await git(checkout, ["ls-remote", "--tags", origin])
        guard tags.ok else { return "git couldn't read its mirror" }
        let tagged = Set(tags.lines.compactMap { $0.split(separator: "\t").first.map(String.init) })
        let unique = await git(checkout, ["rev-list", "--max-count=1", "HEAD", "--branches", "--not", "--remotes"] + tagged.sorted())
        guard unique.ok else { return "git couldn't check" }
        if !unique.stdout.isEmpty { return "has commits its mirror doesn't have" }
        return nil
    }

    // MARK: Helpers

    /// `HEAD` beside `objects/` and `refs/`, or beside `commondir` or `gitdir`.
    static func isGitDirectory(_ dir: String) -> Bool {
        guard FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("HEAD")) else { return false }
        if sharesGitDirectory(dir) { return true }
        return FileInfo.isDirectory((dir as NSString).appendingPathComponent("objects"))
            && FileInfo.isDirectory((dir as NSString).appendingPathComponent("refs"))
    }

    /// A git directory that uses another repository's objects and refs (a linked worktree's).
    static func sharesGitDirectory(_ dir: String) -> Bool {
        ["commondir", "gitdir"].contains { name in
            let path = (dir as NSString).appendingPathComponent(name)
            return FileInfo.exists(path) || FileInfo.isSymlink(path)
        }
    }

    /// `<scratch>/<slot>/<name>`, where `<scratch>` is a SwiftPM scratch folder: `.build`, Xcode's
    /// `SourcePackages`, or any folder with SwiftPM's `workspace-state.json` (`--scratch-path`,
    /// `-clonedSourcePackagesDirPath`).
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

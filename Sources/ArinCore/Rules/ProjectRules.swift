import Foundation

/// Regenerable build output inside project checkouts: dependency folders, build directories,
/// tool caches marked with CACHEDIR.TAG, and git-ignored bin/ folders full of downloaded tools.
struct ProjectArtifactRule: Rule {
    static let ruleID = "projects.artifacts"
    let id = ProjectArtifactRule.ruleID
    let name = "Project build output"

    enum Kind: String {
        case nodeModules = "node_modules"
        case swiftBuild = ".build"
        case venv = "venv"
        case cargoTarget = "target"
        case bin
        case nextBuild = ".next"
        case gradleBuild = "build"
        case dartTool = ".dart_tool"
        case zigCache = ".zig-cache"
        case terraform = ".terraform"
        case taggedCache = "cache"
    }

    /// Folders whose contents are never searched further once matched.
    static let prunedNames = [
        "node_modules", ".build", ".venv", "venv", "target", "bin", ".next", ".dart_tool", ".zig-cache", "zig-cache", ".terraform",
    ]

    /// A project touched within this window is someone's current work: its build output is listed
    /// but not pre-selected, since deleting it means a reinstall or full rebuild in the middle of work.
    static let activeWindow: TimeInterval = 7 * 24 * 3600

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        var found: [(String, Kind)] = []
        for root in ctx.options.projectRoots {
            var names: [String] = []
            for name in Self.prunedNames { names += (names.isEmpty ? [] : ["-o"]) + ["-name", name] }
            let args = [
                root, "-maxdepth", "8",
                "(", "-name", ".git", "-o", "-name", "Library", "-o", "-name", "Pods", ")", "-prune",
                "-o", "-type", "d", "("] + names + [")", "-prune", "-print",
                // `build` is too common a name to stop at; nested projects inside one are still found.
                "-o", "-type", "d", "-name", "build", "-print",
                "-o", "-type", "f", "-name", "CACHEDIR.TAG", "-print",
            ]
            let result = await Shell.run("find", args, timeout: 180)
            for line in result.lines {
                let path = (line as NSString).lastPathComponent == "CACHEDIR.TAG" ? (line as NSString).deletingLastPathComponent : line
                guard path != root, !found.contains(where: { $0.0 == path }) else { continue }
                if let kind = await Self.classify(path) { found.append((path, kind)) }
            }
        }
        guard !found.isEmpty else { return [] }
        let sizes = await Size.allocated(found.map(\.0), timeout: 600)

        return await concurrentMap(found, limit: 8) { path, kind -> Candidate? in
            guard let bytes = sizes[path] else { return nil }
            let project = (path as NSString).deletingLastPathComponent
            var risk = Risk.safe
            var detail = Self.detail(kind)
            if kind == .bin {
                let (ok, note) = Self.binLooksGenerated(path)
                if !ok {
                    risk = .review
                    detail += " " + note
                }
            }
            if kind == .terraform { risk = .review }
            var blockers = ctx.state.isBusy(path) ? ["files inside are open by a running process"] : []
            // Name and marker files say what a folder is, not that nothing in it is someone's work.
            if let refusal = await Self.refusal(path) {
                blockers.append("not cleaned: \(refusal)")
            }
            if let active = ProjectActivity.lastActivity(project: project, artifact: path),
               ctx.now.timeIntervalSince(active) < Self.activeWindow {
                blockers.append("project changed \(ProjectActivity.describe(active, now: ctx.now)), so it's not pre-selected")
            }
            return Candidate(
                ruleID: id,
                key: path,
                title: "\((path as NSString).lastPathComponent) · \(Self.shortName(project, roots: ctx.options.projectRoots))",
                detail: detail,
                category: .projects,
                level: .standard,
                risk: risk,
                bytes: bytes,
                paths: [path],
                action: .delete([path]),
                lastModified: FileInfo.modified(path),
                blockers: blockers
            )
        }.compactMap { $0 }
    }

    /// Why the folder must not be deleted even though it looks like build output: git doesn't ignore
    /// it, tracks files in it, or a repository inside holds work (an editable install's clone in
    /// `.venv/src`, an edited SwiftPM checkout). Checked at scan time and again right before deleting.
    static func refusal(_ path: String) async -> String? {
        if let reason = await GitSafety.trackingRefusal(path) { return reason }
        return await GitSafety.repositoryRefusal(in: path)
    }

    /// Re-checks a scanned folder right before it's deleted.
    static func recheck(_ path: String) async -> String? {
        guard !FileInfo.isSymlink(path) else { return "it's now a symlink" }
        guard FileInfo.exists(path) else { return nil }
        guard FileInfo.isDirectory(path) else { return "it's no longer a folder" }
        guard await classify(path) != nil else { return "it no longer looks like build output" }
        return await refusal(path)
    }

    static func classify(_ path: String) async -> Kind? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        func has(_ file: String, in dir: String = parent) -> Bool {
            FileInfo.exists((dir as NSString).appendingPathComponent(file))
        }
        switch name {
        case "node_modules":
            return has("package.json") ? .nodeModules : nil
        case ".build":
            // Require SwiftPM output markers: a `.build` holding vendored frameworks or logs is not build output.
            guard has("Package.swift") else { return nil }
            let markers = ["debug", "release", "checkouts", "repositories", "workspace-state.json"]
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            let isBuild = children.contains { child in markers.contains(child) || child.contains("-apple-macosx") }
            return isBuild ? .swiftBuild : nil
        case ".venv", "venv":
            return has("pyvenv.cfg", in: path) ? .venv : nil
        case "target":
            return has("Cargo.toml") && has("CACHEDIR.TAG", in: path) ? .cargoTarget : nil
        case ".next":
            let configs = ["next.config.js", "next.config.mjs", "next.config.cjs", "next.config.ts"]
            return has("package.json") && configs.contains { has($0) } ? .nextBuild : nil
        case "build":
            // Gradle always writes build/tmp; a `build` folder without Gradle's layout may be anything.
            let scripts = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
            guard scripts.contains(where: { has($0) }), has("tmp", in: path) else { return nil }
            return .gradleBuild
        case ".dart_tool":
            return has("pubspec.yaml") ? .dartTool : nil
        case ".zig-cache", "zig-cache":
            return has("build.zig") ? .zigCache : nil
        case ".terraform":
            let files = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            return files.contains { $0.hasSuffix(".tf") } ? .terraform : nil
        case "bin":
            // Only repo-root bin/ folders that git ignores and tracks nothing in.
            guard has(".git"), has("go.mod") || has("Makefile") else { return nil }
            let ignored = await Shell.run("git", ["-C", parent, "check-ignore", "-q", "bin"], timeout: 10)
            guard ignored.status == 0 else { return nil }
            let tracked = await Shell.run("git", ["-C", parent, "ls-files", "--", "bin"], timeout: 10)
            return tracked.ok && tracked.stdout.isEmpty ? .bin : nil
        default:
            return isTaggedCache(path) ? .taggedCache : nil
        }
    }

    /// A folder a tool marked as a cache with a valid CACHEDIR.TAG (pytest, mypy, ruff and others).
    /// Only cache-named folders count, and never one that is itself a project. A checkout inside blocks
    /// it like any other build output (see `refusal`).
    static func isTaggedCache(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix(".") || name.lowercased().contains("cache") else { return false }
        guard let handle = FileHandle(forReadingAtPath: (path as NSString).appendingPathComponent("CACHEDIR.TAG")),
              let head = try? handle.read(upToCount: 43)
        else { return false }
        try? handle.close()
        guard String(decoding: head, as: UTF8.self) == "Signature: 8a477f597d28d172789f06886806bc55" else { return false }
        let projectMarkers = [".git", "package.json", "Package.swift", "go.mod", "Cargo.toml", "pyproject.toml", "Makefile"]
        return !projectMarkers.contains(where: { FileInfo.exists((path as NSString).appendingPathComponent($0)) })
    }

    /// bin/ is safe when it holds only executables and tool trees (envtest's k8s/, Python envs).
    /// Notes or scratch source make it a review item; a checkout inside blocks it (see `refusal`).
    static func binLooksGenerated(_ path: String) -> (Bool, String) {
        var odd: [String] = []
        for child in FileInfo.children(path) {
            let name = (child as NSString).lastPathComponent
            if name.hasPrefix(".") { odd.append(name); continue }
            if FileInfo.isDirectory(child) {
                if ["k8s", "tools", "venv", ".venv"].contains(name) || FileInfo.exists("\(child)/pyvenv.cfg") { continue }
                odd.append("\(name)/")
            } else if !FileManager.default.isExecutableFile(atPath: child) {
                odd.append(name)
            }
        }
        if odd.isEmpty { return (true, "") }
        return (false, "Contains non-binary entries worth checking: \(odd.prefix(5).joined(separator: ", "))\(odd.count > 5 ? ", …" : "").")
    }

    static func detail(_ kind: Kind) -> String {
        switch kind {
        case .nodeModules: "Installed npm/bun/pnpm dependencies. Reinstall before the next run."
        case .swiftBuild: "SwiftPM build output next to Package.swift. The next build starts from scratch."
        case .venv: "Python virtual environment. Recreate it with your project's setup command."
        case .cargoTarget: "Cargo build output. The next build starts from scratch."
        case .bin: "Git-ignored bin/ with downloaded tools and compiled binaries (linters, controller-gen, envtest). `make` re-downloads them."
        case .nextBuild: "Next.js build output and cache. The next `next build` or `next dev` recreates it."
        case .gradleBuild: "Gradle build output. The next build recompiles from scratch."
        case .dartTool: "Dart and Flutter tool state. `dart pub get` or `flutter pub get` recreates it."
        case .zigCache: "Zig build cache. The next `zig build` recreates it."
        case .terraform: "Providers and modules downloaded by `terraform init`. State files live outside this folder, but `.terraform/environment` records the selected workspace, and running init again may need registry access or credentials."
        case .taggedCache: "A tool cache marked with CACHEDIR.TAG, the standard tag for folders that are safe to delete. The tool rebuilds it on the next run."
        }
    }

    static func shortName(_ path: String, roots: [String]) -> String {
        for root in roots where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let index = next
            let item = items[index]
            group.addTask { (index, await transform(item)) }
            next += 1
        }
        for _ in 0 ..< min(limit, items.count) { addNext() }
        for await (index, value) in group {
            results[index] = value
            addNext()
        }
    }
    return results.compactMap { $0 }
}

/// When a project was last worked on, from cheap signals: git's index, HEAD and reflog for the
/// enclosing repository (following a linked worktree's `.git` file), the project's own files two
/// levels down, and Claude Code sessions in the repository. Build output is skipped, since installs
/// and builds rewrite it on their own.
enum ProjectActivity {
    static func lastActivity(project: String, artifact: String, transcripts: String? = transcriptsRoot) -> Date? {
        var dates: [Date] = []
        if let transcripts, let date = transcriptActivity(project: project, root: transcripts) { dates.append(date) }
        if let gitDir = gitDirectory(above: project) {
            for name in ["index", "HEAD", "logs/HEAD"] {
                if let date = FileInfo.modified((gitDir as NSString).appendingPathComponent(name)) { dates.append(date) }
            }
        }
        let skip = Set(ProjectArtifactRule.prunedNames + ["build", ".git", ".DS_Store"])
        var seen = 0
        for child in FileInfo.children(project) where child != artifact {
            let name = (child as NSString).lastPathComponent
            guard !skip.contains(name), !FileInfo.isSymlink(child) else { continue }
            if let date = FileInfo.modified(child) { dates.append(date) }
            seen += 1
            if FileInfo.isDirectory(child) {
                for grandchild in FileInfo.children(child).prefix(200) {
                    guard !skip.contains((grandchild as NSString).lastPathComponent) else { continue }
                    if let date = FileInfo.modified(grandchild) { dates.append(date) }
                    seen += 1
                }
            }
            if seen > 2000 { break }
        }
        return dates.max()
    }

    /// Where Claude Code keeps its session transcripts, one folder per working directory.
    static var transcriptsRoot: String {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return (config as NSString).appendingPathComponent("projects")
    }

    /// Claude Code names a transcript folder after the session's working directory, with every
    /// character other than an ASCII letter or digit replaced by `-`.
    static func transcriptFolderName(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The newest Claude Code transcript written in the project's repository or below it. An agent
    /// session that only reads files or runs tests changes nothing else a scan can see. The match is by
    /// name prefix, so a sibling such as `app-two` can count for `app`; that only makes a project look
    /// more active.
    static func transcriptActivity(project: String, root: String) -> Date? {
        let base = transcriptFolderName(workTreeRoot(above: project) ?? project)
        var newest: Date?
        for folder in FileInfo.children(root) {
            let name = (folder as NSString).lastPathComponent
            guard name == base || name.hasPrefix(base + "-") else { continue }
            for file in FileInfo.children(folder) where file.hasSuffix(".jsonl") {
                if let date = FileInfo.modified(file), date > (newest ?? .distantPast) { newest = date }
            }
        }
        return newest
    }

    /// The nearest folder at or above `path` that holds a `.git` entry.
    static func workTreeRoot(above path: String) -> String? {
        var dir = path
        for _ in 0 ..< 8 {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            if FileInfo.exists(dotGit) || FileInfo.isSymlink(dotGit) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    /// The git directory for `path` or its nearest ancestor that has one.
    static func gitDirectory(above path: String) -> String? {
        var dir = path
        for _ in 0 ..< 8 {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            if FileInfo.isDirectory(dotGit) { return dotGit }
            if let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
                let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return target.hasPrefix("/") ? target : ((dir as NSString).appendingPathComponent(target) as NSString).standardizingPath
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    static func describe(_ date: Date, now: Date) -> String {
        switch Int(max(now.timeIntervalSince(date), 0) / 86400) {
        case 0: "today"
        case 1: "yesterday"
        case let days: "\(days) days ago"
        }
    }
}

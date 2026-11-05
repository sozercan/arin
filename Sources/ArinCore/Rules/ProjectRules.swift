import Foundation

/// Regenerable build output inside project checkouts: node_modules, SwiftPM .build, venvs,
/// Cargo target, and git-ignored bin/ folders full of downloaded tools.
struct ProjectArtifactRule: Rule {
    let id = "projects.artifacts"
    let name = "Project build output"

    enum Kind: String {
        case nodeModules = "node_modules"
        case swiftBuild = ".build"
        case venv = "venv"
        case cargoTarget = "target"
        case bin
    }

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        var found: [(String, Kind)] = []
        for root in ctx.options.projectRoots {
            let args = [
                root, "-maxdepth", "8",
                "(", "-name", ".git", "-o", "-name", "Library", "-o", "-name", "Pods", ")", "-prune",
                "-o", "-type", "d",
                "(", "-name", "node_modules", "-o", "-name", ".build", "-o", "-name", ".venv", "-o", "-name", "venv",
                "-o", "-name", "target", "-o", "-name", "bin", ")",
                "-prune", "-print",
            ]
            let result = await Shell.run("find", args, timeout: 180)
            for path in result.lines {
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
            let blockers = ctx.state.isBusy(path) ? ["files inside are open by a running process"] : []
            return Candidate(
                ruleID: id,
                key: path,
                title: "\(kind.rawValue) · \(Self.shortName(project, roots: ctx.options.projectRoots))",
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
        case "bin":
            // Only repo-root bin/ folders that git ignores and tracks nothing in.
            guard has(".git"), has("go.mod") || has("Makefile") else { return nil }
            let ignored = await Shell.run("git", ["-C", parent, "check-ignore", "-q", "bin"], timeout: 10)
            guard ignored.status == 0 else { return nil }
            let tracked = await Shell.run("git", ["-C", parent, "ls-files", "--", "bin"], timeout: 10)
            return tracked.ok && tracked.stdout.isEmpty ? .bin : nil
        default:
            return nil
        }
    }

    /// bin/ is safe when it holds only executables and tool trees (envtest's k8s/, Python envs).
    /// Notes, scratch source, or nested checkouts make it a review item.
    static func binLooksGenerated(_ path: String) -> (Bool, String) {
        var odd: [String] = []
        if let checkout = nestedCheckout(in: path) {
            odd.append("\(checkout) (git checkout)")
        }
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

    /// First `.git` anywhere under `dir`, relative to it. Tool trees are small; a tree too large
    /// to finish walking is reported as possibly holding a checkout.
    static func nestedCheckout(in dir: String) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: dir) else { return nil }
        var seen = 0
        while let relative = walker.nextObject() as? String {
            if (relative as NSString).lastPathComponent == ".git" { return (relative as NSString).deletingLastPathComponent + "/" }
            seen += 1
            if seen > 100_000 { return "contents too large to check" }
        }
        return nil
    }

    static func detail(_ kind: Kind) -> String {
        switch kind {
        case .nodeModules: "Installed npm/bun/pnpm dependencies. Reinstall before the next run."
        case .swiftBuild: "SwiftPM build output next to Package.swift. The next build starts from scratch."
        case .venv: "Python virtual environment. Recreate it with your project's setup command."
        case .cargoTarget: "Cargo build output. The next build starts from scratch."
        case .bin: "Git-ignored bin/ with downloaded tools and compiled binaries (linters, controller-gen, envtest). `make` re-downloads them."
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

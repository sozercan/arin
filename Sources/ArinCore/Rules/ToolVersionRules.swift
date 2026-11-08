import Foundation

/// Old Codex standalone releases. Keeps `current` and any release a running session still uses.
struct CodexReleasesRule: Rule {
    let id = "tools.codex-releases"
    let name = "Old Codex releases"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let base = ctx.path(".codex/packages/standalone")
        let current = FileInfo.resolveSymlink("\(base)/current")
        return await OldVersions.candidates(
            ctx: ctx,
            ruleID: id,
            title: "Old Codex releases",
            versions: FileInfo.children("\(base)/releases"),
            keep: [current].compactMap { $0 },
            detail: "Superseded Codex installs. The current release and any release a running session uses are kept."
        )
    }
}

/// Old Claude Code versions. Keeps the one `~/.local/bin/claude` points at and any running one.
struct ClaudeVersionsRule: Rule {
    let id = "tools.claude-versions"
    let name = "Old Claude Code versions"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let current = FileInfo.resolveSymlink(ctx.path(".local/bin/claude"))
        return await OldVersions.candidates(
            ctx: ctx,
            ruleID: id,
            title: "Old Claude Code versions",
            versions: FileInfo.children(ctx.path(".local/share/claude/versions")),
            keep: [current].compactMap { $0 },
            detail: "Superseded Claude Code binaries. The linked version and any running version are kept."
        )
    }
}

enum OldVersions {
    static func candidates(
        ctx: ScanContext,
        ruleID: String,
        title: String,
        versions: [String],
        keep: [String],
        detail: String
    ) async -> [Candidate] {
        let removable = versions.filter { version in
            let name = (version as NSString).lastPathComponent
            if name.hasPrefix(".") { return false }
            if keep.contains(where: { $0 == version || $0.hasPrefix(version + "/") }) { return false }
            if ctx.state.hasExecutable(under: version) || ctx.state.processPaths.contains(version) { return false }
            if ctx.state.isBusy(version) { return false }
            return true
        }
        guard !removable.isEmpty else { return [] }
        let bytes = await Size.total(removable)
        let names = removable.map { ($0 as NSString).lastPathComponent }
        return [Candidate(
            ruleID: ruleID,
            key: ruleID,
            title: "\(title) (\(removable.count))",
            detail: "\(detail) Removing: \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? ", …" : "").",
            category: .toolVersions,
            level: .quick,
            risk: .safe,
            bytes: bytes,
            paths: removable,
            action: .delete(removable)
        )]
    }
}

/// Rust toolchains other than the default. Some projects pin versions, so these need a look.
struct RustToolchainRule: Rule {
    let id = "tools.rust-toolchains"
    let name = "Extra Rust toolchains"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("rustup") != nil else { return [] }
        let list = await Shell.run("rustup", ["toolchain", "list"], timeout: 20)
        guard list.ok else { return [] }
        var result: [Candidate] = []
        for line in list.lines {
            if line.contains("(default)") || line.contains("active") { continue }
            guard let name = line.split(separator: " ").first.map(String.init) else { continue }
            if name.hasPrefix("stable") { continue }
            let dir = ctx.path(".rustup/toolchains/\(name)")
            let bytes = await Size.allocated(dir)
            result.append(Candidate(
                ruleID: id,
                key: name,
                title: "Rust toolchain \(name)",
                detail: "Not the default toolchain. A project's rust-toolchain file may pin it; rustup reinstalls it on demand.",
                category: .toolVersions,
                level: .deep,
                risk: .review,
                bytes: bytes,
                paths: [dir],
                action: .commands([CommandSpec("rustup", ["toolchain", "uninstall", name])]),
                blockingProcesses: ["cargo", "rustc"]
            ))
        }
        return result
    }
}

/// Tool versions mise installed that no tracked config or tool stub selects. `mise prune` makes
/// that call itself at cleanup time and keeps versions a running process uses.
struct MiseRule: Rule {
    let id = "tools.mise"
    let name = "Unused mise tool versions"

    struct Entry: Decodable {
        var version: String
        var install_path: String?
    }

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("mise") != nil else { return [] }
        let result = await Shell.run("mise", ["ls", "--prunable", "--json"], timeout: 30)
        guard result.ok, let tools = try? JSONDecoder().decode([String: [Entry]].self, from: Data(result.stdout.utf8)) else {
            return []
        }
        let env = ProcessInfo.processInfo.environment
        let dataDir = env["MISE_DATA_DIR"] ?? env["XDG_DATA_HOME"].map { "\($0)/mise" } ?? ctx.path(".local/share/mise")
        var found: [Candidate] = []
        for (tool, entries) in tools.sorted(by: { $0.key < $1.key }) where !entries.isEmpty {
            let command = CommandSpec("mise", ["prune", "--tools", "--yes", tool])
            guard Guardrails.allows(command) else { continue }
            let paths = entries.map { $0.install_path ?? "\(dataDir)/installs/\(tool)/\($0.version)" }.filter(FileInfo.exists)
            guard !paths.isEmpty else { continue }
            let versions = entries.map(\.version)
            found.append(Candidate(
                ruleID: id,
                key: tool,
                title: "Unused \(tool) versions (\(versions.count))",
                detail: "Installed by mise but selected by no config it tracks. `mise prune` keeps any version a running process uses. Removing: \(versions.prefix(6).joined(separator: ", "))\(versions.count > 6 ? ", …" : "").",
                category: .toolVersions,
                level: .standard,
                risk: .safe,
                bytes: await Size.total(paths),
                paths: paths,
                action: .commands([command])
            ))
        }
        return found
    }
}

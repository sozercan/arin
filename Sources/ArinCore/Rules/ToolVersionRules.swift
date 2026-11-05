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

import Foundation

/// Large, idle items in $TMPDIR and /private/tmp: agent build caches, test homes, DerivedData copies.
struct TempRule: Rule {
    let id = "temp.stale"
    let name = "Stale temporary files"
    let idle: TimeInterval = 3 * 3600
    let minimum: Int64 = 50 * 1024 * 1024

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let uid = getuid()
        let tmp = Guardrails.canonical(ctx.options.tmpDir)
        var entries: [String] = []
        for root in [tmp, "/private/tmp"] {
            for child in FileInfo.children(root) {
                let name = (child as NSString).lastPathComponent
                if name.hasPrefix("com.apple.") || name.hasPrefix("arin-") || name == "TemporaryItems" { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: child)
                guard (attrs?[.ownerAccountID] as? NSNumber)?.uint32Value == uid else { continue }
                guard attrs?[.type] as? FileAttributeType != .typeSymbolicLink else { continue }
                entries.append(child)
            }
        }
        let sizes = await Size.allocated(entries)
        var result: [Candidate] = []
        for entry in entries {
            guard let bytes = sizes[entry], bytes >= minimum else { continue }
            let root = (entry as NSString).deletingLastPathComponent
            result += await evaluate(entry, bytes: bytes, root: root, depth: 0, ctx: ctx)
        }
        return result
    }

    /// A busy folder (e.g. /tmp/claude-501 holding the current session) is split into its
    /// children so idle siblings can still be cleaned.
    func evaluate(_ entry: String, bytes: Int64, root: String, depth: Int, ctx: ScanContext) async -> [Candidate] {
        let busy = ctx.state.isBusy(entry)
        if busy, bytes >= 1024 * 1024 * 1024, depth < 3, FileInfo.isDirectory(entry) {
            let children = FileInfo.children(entry)
            let sizes = await Size.allocated(children)
            var result: [Candidate] = []
            for child in children {
                guard let size = sizes[child], size >= minimum else { continue }
                result += await evaluate(child, bytes: size, root: root, depth: depth + 1, ctx: ctx)
            }
            return result
        }
        var blockers: [String] = []
        if busy {
            blockers.append("files are open by a running process")
        } else if await Self.hasRecentWrites(entry, within: idle) {
            blockers.append("written in the last 3 hours (may be in use)")
        }
        let name = String(entry.dropFirst(root.count + 1))
        // Agent scratch folders sometimes hold a git checkout with unpushed work, not just build output.
        let checkout = await Self.containsGitCheckout(entry)
        return [Candidate(
            ruleID: id,
            key: entry,
            title: "Temp: \(name)",
            detail: (entry.hasPrefix("/private/tmp")
                ? "Scratch data in /tmp, idle for 3+ hours. Usually build caches or test output left by tools and agents."
                : "Scratch data in your per-user temp folder, idle for 3+ hours. macOS rarely cleans this on its own.")
                + (checkout ? " It contains a git checkout, which may hold work that isn't pushed." : ""),
            category: .temp,
            level: .quick,
            risk: checkout ? .review : .safe,
            bytes: bytes,
            paths: [entry],
            action: .delete([entry]),
            lastModified: FileInfo.modified(entry),
            blockers: blockers,
            minIdleSeconds: idle
        )]
    }

    static func containsGitCheckout(_ path: String) async -> Bool {
        // Package-manager checkouts (SwiftPM in DerivedData, Go modules, node_modules) are re-downloadable.
        let result = await Shell.run("find", [
            path, "-maxdepth", "4",
            "(", "-name", "SourcePackages", "-o", "-name", "checkouts", "-o", "-name", ".build",
            "-o", "-name", "node_modules", "-o", "-name", "pkg", ")", "-prune",
            "-o", "-name", ".git", "-print", "-quit",
        ], timeout: 60)
        return result.timedOut || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Any file under `path` modified within the window. Stops at the first hit.
    static func hasRecentWrites(_ path: String, within window: TimeInterval) async -> Bool {
        let minutes = String(Int(window / 60))
        let result = await Shell.run("find", [path, "-mmin", "-\(minutes)", "-print", "-quit"], timeout: 60)
        if result.timedOut { return true }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Code-signing clones macOS makes of running app bundles. Stale copies pile up (Chrome, Edge, Teams).
struct CodeSignCloneRule: Rule {
    let id = "temp.code-sign-clones"
    let name = "Stale code-signing clones"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let perUser = (Guardrails.canonical(ctx.options.tmpDir) as NSString).deletingLastPathComponent
        let xDir = (perUser as NSString).appendingPathComponent("X")
        var result: [Candidate] = []
        for appDir in FileInfo.children(xDir) where appDir.hasSuffix(".code_sign_clone") {
            let clones = FileInfo.children(appDir)
            let idle = clones.filter { !ctx.state.isBusy($0) }
            guard !idle.isEmpty else { continue }
            let bundle = ((appDir as NSString).lastPathComponent as NSString).deletingPathExtension
            let bytes = await Size.total(idle)
            result.append(Candidate(
                ruleID: id,
                key: appDir,
                title: "Code-signing clones: \(bundle) (\(idle.count))",
                detail: "Copies of an app bundle macOS made while checking its signature. Clones in use are excluded. Sizes are overstated: APFS shares blocks with the real app, so the actual gain is often a small fraction. Quitting the app and rebooting also clears them.",
                category: .temp,
                level: .standard,
                risk: .review,
                bytes: bytes,
                paths: idle,
                action: .delete(idle),
                lastModified: idle.compactMap(FileInfo.modified).max()
            ))
        }
        return result
    }
}

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
        } else if await FileInfo.hasRecentWrites(entry, within: idle) {
            blockers.append("written in the last 3 hours (may be in use)")
        }
        let name = String(entry.dropFirst(root.count + 1))
        // Agent scratch folders sometimes hold a git checkout with unpushed work, not just build output.
        let refusal = await GitSafety.repositoryRefusal(in: entry, skipPackageCaches: true)
        // Being idle and holding no repository doesn't make a folder regenerable. Only a layout a tool
        // is known to rebuild starts as Safe; anything else is for the user (or their agent) to judge.
        let cache = Self.recognizedCache(entry)
        var detail = entry.hasPrefix("/private/tmp")
            ? "Scratch data in /tmp, idle for 3+ hours."
            : "Scratch data in your per-user temp folder, idle for 3+ hours. macOS rarely cleans this on its own."
        if let cache {
            detail += " It's \(cache), which the tool rebuilds when it needs it."
        } else {
            detail += " Arin doesn't recognize what's inside; tools and agents usually leave build caches or test output here, but it may hold work."
        }
        if let refusal { blockers.append("not cleaned: it \(refusal)") }
        return [Candidate(
            ruleID: id,
            key: entry,
            title: "Temp: \(name)",
            detail: detail,
            category: .temp,
            level: .quick,
            risk: cache == nil || refusal != nil ? .review : .safe,
            bytes: bytes,
            paths: [entry],
            action: .delete([entry]),
            lastModified: FileInfo.modified(entry),
            blockers: blockers,
            minIdleSeconds: idle
        )]
    }
}

extension TempRule {
    static let cacheTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// What a temp folder is, when its layout says a tool will rebuild it: a Go build cache (one-off
    /// `GOCACHE` runs), an Xcode DerivedData folder (`-derivedDataPath` runs), or a folder that carries
    /// the standard `CACHEDIR.TAG`. Nil for anything else.
    static func recognizedCache(_ path: String) -> String? {
        func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }
        if let readme = FileManager.default.contents(atPath: file("README")),
           String(decoding: readme.prefix(80), as: UTF8.self).hasPrefix("This directory holds cached build artifacts from the Go build system."),
           FileInfo.exists(file("trim.txt")) {
            return "a Go build cache"
        }
        if FileInfo.isDirectory(file("Build")),
           FileInfo.exists(file("info.plist")) || FileInfo.isDirectory(file("ModuleCache.noindex")) || FileInfo.isDirectory(file("Index.noindex")) {
            return "Xcode build output (DerivedData)"
        }
        if let handle = FileHandle(forReadingAtPath: file("CACHEDIR.TAG")) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: cacheTagSignature.utf8.count),
               String(decoding: head, as: UTF8.self) == cacheTagSignature {
                return "a folder its tool tagged as a cache (CACHEDIR.TAG)"
            }
        }
        return nil
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

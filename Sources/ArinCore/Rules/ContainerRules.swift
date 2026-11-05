import Foundation

/// Docker build cache, unused images, and dangling volumes, via Docker's own commands.
/// Docker's CLI can hang when Desktop is wedged, so every call has a short timeout.
struct DockerRule: Rule {
    let id = "docker"
    let name = "Docker"

    struct DockerUnavailable: Error, CustomStringConvertible {
        var description: String { "Docker is running but not responding; skipped (don't delete Docker.raw directly)." }
    }

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("docker") != nil else { return [] }
        let info = await Shell.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 10)
        if info.timedOut { throw DockerUnavailable() }
        guard info.ok else { return [] } // daemon not running

        var result: [Candidate] = []
        let df = await Shell.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 60)
        for line in df.lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["Type"] as? String,
                  let reclaimable = (row["Reclaimable"] as? String).flatMap(Self.parseSize), reclaimable > 0
            else { continue }
            switch type {
            case "Build Cache":
                result.append(Candidate(
                    ruleID: "docker.build-cache",
                    key: "build-cache",
                    title: "Docker build cache",
                    detail: "BuildKit layers for the current builder. Builds are slower once. Docker.raw gives space back to macOS gradually.",
                    category: .containers,
                    level: .standard,
                    risk: .safe,
                    bytes: reclaimable,
                    paths: [],
                    action: .commands([CommandSpec("docker", ["builder", "prune", "-af"])])
                ))
            case "Images":
                result.append(Candidate(
                    ruleID: "docker.images",
                    key: "images",
                    title: "Unused Docker images",
                    detail: "Images no container uses. They'll be pulled or rebuilt when needed.",
                    category: .containers,
                    level: .standard,
                    risk: .review,
                    bytes: reclaimable,
                    paths: [],
                    action: .commands([CommandSpec("docker", ["image", "prune", "-af"])])
                ))
            default:
                break
            }
        }

        // `buildx ls` lists builders and their nodes. If it fails, owners are unknown: nothing is an orphan.
        let listing = await Shell.run("docker", ["buildx", "ls", "--format", "{{.Name}}"], timeout: 15)
        let builders: Set<String>? = listing.ok ? Set(listing.lines.map { $0.trimmingCharacters(in: .whitespaces) }) : nil
        let dangling = await Shell.run("docker", ["volume", "ls", "-q", "--filter", "dangling=true"], timeout: 20).lines
        guard !dangling.isEmpty else { return result }
        let volumeSizes = await Self.volumeSizes()
        for volume in dangling {
            let orphanedBuilder = builders.map { Self.orphanedBuildxVolume(volume, builders: $0) } ?? false
            result.append(Candidate(
                ruleID: "docker.volume",
                key: volume,
                title: "Docker volume \(volume)",
                detail: orphanedBuilder
                    ? "BuildKit state for a buildx builder that no longer exists. Nothing uses it."
                    : "Not attached to any container. Volumes can hold databases or other state, so check the name before removing.",
                category: .containers,
                level: .standard,
                risk: orphanedBuilder ? .safe : .review,
                bytes: volumeSizes[volume] ?? 0,
                paths: [],
                action: .commands([CommandSpec("docker", ["volume", "rm", volume])])
            ))
        }
        return result
    }

    static func volumeSizes() async -> [String: Int64] {
        let result = await Shell.run("docker", ["system", "df", "-v", "--format", "{{json .Volumes}}"], timeout: 90)
        guard result.ok,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        else { return [:] }
        var sizes: [String: Int64] = [:]
        for row in rows {
            if let name = row["Name"] as? String, let size = (row["Size"] as? String).flatMap(parseSize) {
                sizes[name] = size
            }
        }
        return sizes
    }

    /// `buildx_buildkit_<builder>0_state` where `<builder>` is gone.
    static func orphanedBuildxVolume(_ volume: String, builders: Set<String>) -> Bool {
        guard volume.hasPrefix("buildx_buildkit_"), volume.hasSuffix("_state") else { return false }
        let node = String(volume.dropFirst("buildx_buildkit_".count).dropLast("_state".count))
        let builder = node.hasSuffix("0") ? String(node.dropLast()) : node
        return !builders.contains(builder) && !builders.contains(node)
    }

    /// Parses Docker's human sizes: "6.1GB", "512MB", "1.2kB", "0B", "3.6GB (100%)".
    static func parseSize(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where token.hasSuffix(unit) {
            guard let value = Double(token.dropLast(unit.count)) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }
}

/// SQLite databases with lots of free pages inside (Codex's log DB has shown 16 of 17 GB free).
struct SQLiteFreePagesRule: Rule {
    let id = "agent.sqlite-free-pages"
    let name = "Bloated agent databases"
    let minimumFree: Int64 = 1024 * 1024 * 1024

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("sqlite3") != nil else { return [] }
        var result: [Candidate] = []
        for db in Glob.expand(ctx.path(".codex/logs_*.sqlite")) {
            let pragma = await Shell.run("sqlite3", ["-readonly", db, "PRAGMA page_size; PRAGMA freelist_count;"], timeout: 30)
            let numbers = pragma.lines.compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 2 else { continue }
            let free = numbers[0] * numbers[1]
            guard free >= minimumFree else { continue }
            result.append(Candidate(
                ruleID: id,
                key: db,
                title: "Compact \((db as NSString).lastPathComponent)",
                detail: "\(free.formattedBytes) of this database is unused pages. VACUUM rewrites it smaller and keeps every row. This is generic SQLite maintenance, not a documented Codex procedure, and it must not run while Codex is writing, so quit every Codex session first.",
                category: .agentData,
                level: .deep,
                risk: .review,
                bytes: free,
                paths: [db],
                action: .commands([CommandSpec("sqlite3", [db, "VACUUM;"])]),
                blockers: ctx.state.blockers(paths: [db], processes: ["codex", "Codex"], minIdle: nil),
                blockingProcesses: ["codex", "Codex"]
            ))
        }
        return result
    }
}

/// Electron app caches (Slack, Notion, VS Code, Discord…): Cache, Code Cache, GPUCache, CacheStorage.
struct ElectronCacheRule: Rule {
    let id = "apps.electron-cache"
    let name = "Electron app caches"
    let cacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage", "CachedData"]

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let support = ctx.path("Library/Application Support")
        var groups: [(app: String, paths: [String])] = []
        for appDir in FileInfo.children(support) {
            let app = (appDir as NSString).lastPathComponent
            if app.hasPrefix("com.apple.") || app == "Google" { continue }
            // Notion and some others nest a partition per workspace.
            var roots = [appDir]
            roots += FileInfo.children("\(appDir)/Partitions")
            var found: [String] = []
            for root in roots {
                for dir in cacheDirs where FileInfo.isDirectory("\(root)/\(dir)") {
                    found.append("\(root)/\(dir)")
                }
            }
            // Require at least two Chromium cache dirs so plain "Cache" folders of other apps aren't matched.
            if found.count >= 2 { groups.append((app, found)) }
        }
        guard !groups.isEmpty else { return [] }
        let sizes = await Size.allocated(groups.flatMap(\.paths))
        return groups.map { group in
            let processName = group.app == "Code" ? "Visual Studio Code" : group.app
            let processes = [processName, "app:\(group.app)"]
            let blockers = ctx.state.blockers(paths: group.paths, processes: processes, minIdle: nil)
            return Candidate(
                ruleID: id,
                key: group.app,
                title: "\(group.app) cache",
                detail: "Web and code caches of an Electron app. Sign-in, settings and local data stay. The app must be quit.",
                category: .appCaches,
                level: .standard,
                risk: .safe,
                bytes: group.paths.reduce(0) { $0 + (sizes[$1] ?? 0) },
                paths: group.paths,
                action: .delete(group.paths),
                blockers: blockers,
                blockingProcesses: processes
            )
        }
    }
}

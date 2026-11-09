import Foundation

/// Large directories no specific rule explains. These are what the agent review is for:
/// the rules don't know them, so they start as "review" and the agent may mark them safe.
public struct UnclassifiedRule: Rule {
    public let id = "unclassified"
    public let name = "Unclassified large folders"

    struct Root {
        var relative: String
        var minimum: Int64
        var trash: Bool
    }

    let roots: [Root] = [
        Root(relative: "Library/Caches", minimum: 300 * 1024 * 1024, trash: false),
        Root(relative: ".cache", minimum: 300 * 1024 * 1024, trash: false),
        Root(relative: "Library/Application Support", minimum: 1024 * 1024 * 1024, trash: true),
        Root(relative: "Library/Developer", minimum: 1024 * 1024 * 1024, trash: true),
    ]

    public init() {}

    public func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        await discover(ctx, excluding: [])
    }

    public func discover(_ ctx: ScanContext, excluding claimed: [String]) async -> [Candidate] {
        let guardrails = Guardrails(home: ctx.home, tmpDir: ctx.options.tmpDir)
        var result: [Candidate] = []
        for root in roots {
            let base = ctx.path(root.relative)
            let children = FileInfo.children(base).filter { child in
                let name = (child as NSString).lastPathComponent
                if name.hasPrefix("com.apple.") || name.hasPrefix(".") && root.relative != ".cache" { return false }
                if (try? guardrails.check(child)) == nil { return false }
                // Skip anything that overlaps a path a specific rule already handles.
                return !claimed.contains { $0 == child || $0.hasPrefix(child + "/") || child.hasPrefix($0 + "/") }
            }
            let sizes = await Size.allocated(children)
            for child in children {
                guard let bytes = sizes[child], bytes >= root.minimum else { continue }
                let name = (child as NSString).lastPathComponent
                result.append(Candidate(
                    ruleID: id,
                    key: child,
                    title: "\(name) (\(root.relative))",
                    detail: root.trash
                        ? "No rule recognizes this app data. It may hold settings, downloads or local databases. Ask your agent to review it; if removed, it goes to the Trash."
                        : "A cache no rule recognizes. Caches are normally regenerable, but ask your agent to confirm.",
                    category: .unclassified,
                    level: root.trash ? .deep : .standard,
                    risk: .review,
                    bytes: bytes,
                    paths: [child],
                    action: root.trash ? .trash([child]) : .delete([child]),
                    lastModified: FileInfo.modified(child),
                    blockers: ctx.state.isBusy(child) ? ["files are open by a running process"] : []
                ))
            }
        }
        result += await HomeOverview.discover(ctx, claimed: claimed + result.flatMap(\.paths))
        return result
    }
}

/// APFS snapshots and staged macOS updates hold deleted files' space.
struct SnapshotInsightRule: InsightRule {
    func insights(_ ctx: ScanContext) async -> [Insight] {
        let snapshots = await Disk.localSnapshots()
        guard !snapshots.isEmpty else { return [] }
        let update = snapshots.contains { $0.contains("os.update") || $0.contains("MSUPrepareUpdate") }
        return [Insight(
            id: "snapshots",
            title: update ? "A macOS update is holding space" : "Local snapshots are holding space",
            detail: update
                ? "\(snapshots.count) update snapshot(s) exist. Until the update installs and you restart, deleted files can keep using disk space. Don't remove these by hand."
                : "\(snapshots.count) local snapshot(s) exist. Deleted files stay on disk until macOS thins them. Time Machine's own snapshots are listed at the Deep level."
        )]
    }
}

/// Agent history that Arin won't delete itself: it's conversation data with its own deletion tools.
struct AgentHistoryInsightRule: InsightRule {
    func insights(_ ctx: ScanContext) async -> [Insight] {
        var result: [Insight] = []
        let codexSessions = ctx.path(".codex/sessions")
        if FileInfo.isDirectory(codexSessions) {
            let bytes = await Size.allocated(codexSessions)
            if bytes > 2 * 1024 * 1024 * 1024 {
                result.append(Insight(
                    id: "codex-sessions",
                    title: "Codex session history",
                    detail: "Use `codex delete <SESSION>` so database and index entries go with the transcripts. Deleting files directly leaves stale records, and the measured gain is often much smaller than the file total.",
                    bytes: bytes
                ))
            }
        }
        let dockerRaw = ctx.path("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        if FileInfo.exists(dockerRaw) {
            let bytes = await Size.allocated(dockerRaw)
            if bytes > 5 * 1024 * 1024 * 1024 {
                result.append(Insight(
                    id: "docker-raw",
                    title: "Docker disk image",
                    detail: "Docker.raw holds images, containers and volumes. Never delete it directly. Start Docker so Arin can see what is reclaimable inside it.",
                    bytes: bytes
                ))
            }
        }
        return result
    }
}

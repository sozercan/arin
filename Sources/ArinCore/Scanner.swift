import Foundation

public struct ScanOptions: Sendable {
    public var home: String
    public var tmpDir: String
    /// Where to look for repositories, worktrees, and build output.
    public var projectRoots: [String]
    /// Ask GitHub (via `gh`) whether branches were squash-merged.
    public var checkPullRequests: Bool
    /// Run `git fetch --prune` first so `origin/<default>` is current. Changes remote refs only.
    public var fetchRemotes: Bool
    /// Ignore candidates smaller than this.
    public var minimumBytes: Int64
    /// The user's keep list. Nil skips it (tests); an unreadable file blocks every pre-selection.
    public var keepListURL: URL?

    public init(
        home: String = NSHomeDirectory(),
        tmpDir: String = NSTemporaryDirectory(),
        projectRoots: [String]? = nil,
        checkPullRequests: Bool = true,
        fetchRemotes: Bool = false,
        minimumBytes: Int64 = 20 * 1024 * 1024,
        keepListURL: URL? = KeepList.defaultURL
    ) {
        self.home = home
        self.tmpDir = (tmpDir as NSString).standardizingPath
        self.projectRoots = projectRoots.map(Self.uniqueDirectories) ?? Self.defaultProjectRoots(home: home)
        self.checkPullRequests = checkPullRequests
        self.fetchRemotes = fetchRemotes
        self.minimumBytes = minimumBytes
        self.keepListURL = keepListURL
    }

    public static func defaultProjectRoots(home: String) -> [String] {
        let candidates = ["projects", "go/src", "Developer", "src", "code", "dev", "repos", "work", ".t3/worktrees"]
            .map { "\(home)/\($0)" }
            .filter { FileInfo.isDirectory($0) }
        return uniqueDirectories(candidates)
    }

    /// Drops duplicates that name the same directory (APFS is usually case-insensitive,
    /// so ~/projects and ~/Projects are one folder) and roots nested inside another root.
    public static func uniqueDirectories(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0, seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            result.append(path)
        }
        let real = result.map { (URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.lowercased(), $0) }
        return real.filter { path, _ in
            !real.contains { other, _ in other != path && path.hasPrefix(other + "/") }
        }.map(\.1)
    }
}

public struct ScanContext: Sendable {
    public var options: ScanOptions
    public var state: SystemState
    public var now: Date

    public var home: String { options.home }
    public func path(_ relative: String) -> String { "\(options.home)/\(relative)" }
}

public protocol Rule: Sendable {
    var id: String { get }
    var name: String { get }
    func discover(_ ctx: ScanContext) async throws -> [Candidate]
}

/// Rules that report facts the app won't act on.
public protocol InsightRule: Sendable {
    func insights(_ ctx: ScanContext) async -> [Insight]
}

public enum ScanEvent: Sendable {
    case started(rules: Int)
    case ruleFinished(name: String, found: Int)
}

public struct Scanner: Sendable {
    public var options: ScanOptions
    public var rules: [any Rule]
    public var insightRules: [any InsightRule]

    public init(options: ScanOptions = ScanOptions(), rules: [any Rule]? = nil, insightRules: [any InsightRule]? = nil) {
        self.options = options
        self.rules = rules ?? Catalog.rules
        self.insightRules = insightRules ?? Catalog.insightRules
    }

    public func scan(progress: (@Sendable (ScanEvent) -> Void)? = nil) async -> ScanReport {
        let started = Date()
        let state = await SystemState.capture()
        let ctx = ScanContext(options: options, state: state, now: started)
        progress?(.started(rules: rules.count))

        var candidates: [Candidate] = []
        var errors: [String: String] = [:]
        let known = rules.filter { !($0 is UnclassifiedRule) }
        let fallback = rules.compactMap { $0 as? UnclassifiedRule }

        await withTaskGroup(of: (String, Result<[Candidate], any Error>).self) { group in
            for rule in known {
                group.addTask {
                    do { return (rule.name, .success(try await rule.discover(ctx))) }
                    catch { return (rule.name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case let .success(found):
                    candidates += found
                    progress?(.ruleFinished(name: name, found: found.count))
                case let .failure(error):
                    errors[name] = "\(error)"
                    progress?(.ruleFinished(name: name, found: 0))
                }
            }
        }

        // Unclassified runs last so it can skip anything a specific rule already claimed.
        let claimed = candidates.flatMap(\.paths)
        for rule in fallback {
            let found = await rule.discover(ctx, excluding: claimed)
            candidates += found
            progress?(.ruleFinished(name: rule.name, found: found.count))
        }

        var insights: [Insight] = []
        for rule in insightRules { insights += await rule.insights(ctx) }
        if !state.openFilesKnown {
            insights.append(Insight(
                id: "lsof-unavailable",
                title: "Open-file check unavailable",
                detail: "lsof did not return results, so items can't be checked for open files. Quit busy apps before cleaning."
            ))
        }

        // Save what kept items cover now, from every finding (before dedupe and the size filter, so
        // a small kept cache inside a worktree still protects itself).
        let found = Dictionary(candidates.map { ($0.id, $0.paths) }, uniquingKeysWith: { first, _ in first })
        let keep: Result<KeepList, any Error> = options.keepListURL.map { KeepList.load(from: $0, recording: found) }
            ?? .success(KeepList())
        if case let .failure(error) = keep { errors["Keep list"] = "\(error)" }
        let keptIDs = Set(((try? keep.get())?.entries ?? []).map(\.id))
        let filtered = Self.dedupe(candidates)
            .applying(keep: keep)
            .filter { $0.bytes >= options.minimumBytes || Self.sizeUnknownRules.contains($0.ruleID) }
            .sorted { $0.bytes > $1.bytes }
        return ScanReport(
            startedAt: started,
            finishedAt: Date(),
            disk: Disk.status(path: options.home),
            candidates: filtered,
            insights: insights,
            ruleErrors: errors,
            keptPaths: found.filter { keptIDs.contains($0.key) }
        )
    }

    /// Rules whose candidates have no measurable size but are still worth listing.
    static let sizeUnknownRules: Set<String> = ["git.worktree-prune", "snapshots.time-machine"]

    /// Drop candidates whose paths are already covered by an earlier (larger) candidate.
    /// Worktrees don't claim their contents: their build output stays listable on its own,
    /// since a dirty or unmerged worktree is kept while its `node_modules` can still go.
    static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var seenIDs = Set<String>()
        var claimed: [String] = []
        var result: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.bytes > $1.bytes }) {
            guard seenIDs.insert(candidate.id).inserted else { continue }
            let overlaps = candidate.paths.contains { path in
                claimed.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            if overlaps, !candidate.paths.isEmpty { continue }
            if case .removeWorktree = candidate.action {} else { claimed += candidate.paths }
            result.append(candidate)
        }
        return result
    }
}

public extension Collection<Candidate> {
    /// Total bytes without double-counting paths nested inside other selected paths.
    var dedupedBytes: Int64 {
        let paths = Set(flatMap(\.paths))
        var total: Int64 = 0
        var countedPathless = Set<String>()
        for candidate in self {
            if candidate.paths.isEmpty {
                if countedPathless.insert(candidate.id).inserted { total += candidate.bytes }
                continue
            }
            let nested = candidate.paths.allSatisfy { path in
                paths.contains { other in other != path && path.hasPrefix(other + "/") }
            }
            if !nested { total += candidate.bytes }
        }
        return total
    }
}

import Foundation

/// A cache or leftover at a known location, cleaned with the tool's own command when the tool
/// is installed, or by deleting the directory otherwise.
public struct KnownPathRule: Rule {
    public var id: String
    public var name: String
    public var detail: String
    public var category: CleanupCategory
    public var level: Level
    public var risk: Risk
    /// Paths relative to home, absolute paths, or globs in the last component (`*.ShipIt`).
    public var paths: [String]
    /// Optional resolver that asks the tool where its cache lives (`go env GOCACHE`).
    public var resolve: (@Sendable (ScanContext) async -> [String])?
    /// Native cleanup commands, used when `commands.first.executable` is installed.
    public var commands: [CommandSpec]?
    public var blockingProcesses: [String]
    public var minIdleSeconds: TimeInterval?
    /// One candidate per matched path instead of one for the whole rule.
    public var perPath: Bool
    /// Move to Trash instead of deleting (for things the user may want back).
    public var useTrash: Bool
    public var titleForPath: (@Sendable (String) -> String)?

    public init(
        id: String,
        name: String,
        detail: String,
        category: CleanupCategory = .devCaches,
        level: Level = .quick,
        risk: Risk = .safe,
        paths: [String] = [],
        resolve: (@Sendable (ScanContext) async -> [String])? = nil,
        commands: [CommandSpec]? = nil,
        blockingProcesses: [String] = [],
        minIdleSeconds: TimeInterval? = nil,
        perPath: Bool = false,
        useTrash: Bool = false,
        titleForPath: (@Sendable (String) -> String)? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.category = category
        self.level = level
        self.risk = risk
        self.paths = paths
        self.resolve = resolve
        self.commands = commands
        self.blockingProcesses = blockingProcesses
        self.minIdleSeconds = minIdleSeconds
        self.perPath = perPath
        self.useTrash = useTrash
        self.titleForPath = titleForPath
    }

    public func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        var resolved: [String] = []
        if let resolve { resolved += await resolve(ctx) }
        for pattern in paths {
            let absolute = pattern.hasPrefix("/") ? pattern : ctx.path(pattern)
            resolved += Glob.expand(absolute)
        }
        var unique: [String] = []
        for raw in resolved.map({ ($0 as NSString).standardizingPath }) where FileInfo.exists(raw) {
            let path = FileInfo.actualCase(raw)
            if !unique.contains(path) { unique.append(path) }
        }
        guard !unique.isEmpty else { return [] }

        let sizes = await Size.allocated(unique)
        let native = commands.flatMap { cmds in
            cmds.allSatisfy { Shell.which($0.executable) != nil } ? cmds : nil
        }

        func make(_ group: [String], key: String?, title: String) -> Candidate {
            let bytes = group.reduce(0) { $0 + (sizes[$1] ?? 0) }
            return Candidate(
                ruleID: id,
                key: key,
                title: title,
                detail: detail,
                category: category,
                level: level,
                risk: risk,
                bytes: bytes,
                paths: group,
                action: native.map { .commands($0) } ?? (useTrash ? .trash(group) : .delete(group)),
                lastModified: group.compactMap(FileInfo.modified).max(),
                blockers: ctx.state.blockers(paths: group, processes: blockingProcesses, minIdle: minIdleSeconds, now: ctx.now),
                blockingProcesses: blockingProcesses,
                minIdleSeconds: minIdleSeconds
            )
        }

        if perPath {
            return unique.map { path in
                make([path], key: path, title: titleForPath?(path) ?? name)
            }
        }
        return [make(unique, key: id, title: name)]
    }
}

public enum Glob {
    /// Expands `*` and `?` in the last path component only.
    public static func expand(_ pattern: String) -> [String] {
        let last = (pattern as NSString).lastPathComponent
        guard last.contains("*") || last.contains("?") else { return [pattern] }
        let dir = (pattern as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted()
            .filter { fnmatch(last, $0, 0) == 0 }
            .map { (dir as NSString).appendingPathComponent($0) }
    }
}

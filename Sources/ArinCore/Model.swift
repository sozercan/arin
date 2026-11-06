import Foundation

/// How cautious to be with a candidate. Ordered: a higher value is more cautious.
public enum Risk: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Regenerable, no unique user data. Pre-selected.
    case safe = 0
    /// The user (or their agent) should look before removing it.
    case review = 1
    /// Holds unique work or is in active use. Never pre-selected.
    case keep = 2

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .keep: "Keep"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "safe": self = .safe
        case "review": self = .review
        case "keep": self = .keep
        default: return nil
        }
    }
}

/// Cleanup depth. Quick = caches that refill on their own; Standard = rebuild cost;
/// Deep = loses state you might miss (simulator data, toolchains, history).
public enum Level: Int, Codable, Sendable, Comparable, CaseIterable {
    case quick = 0
    case standard = 1
    case deep = 2

    public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .quick: "Quick"
        case .standard: "Standard"
        case .deep: "Deep"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "quick": self = .quick
        case "standard": self = .standard
        case "deep": self = .deep
        default: return nil
        }
    }
}

public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case devCaches
    case xcode
    case temp
    case toolVersions
    case projects
    case worktrees
    case containers
    case appCaches
    case agentData
    case unclassified

    public var label: String {
        switch self {
        case .devCaches: "Developer caches"
        case .xcode: "Xcode & Simulators"
        case .temp: "Temporary files"
        case .toolVersions: "Old tool versions"
        case .projects: "Project build output"
        case .worktrees: "Git worktrees"
        case .containers: "Containers"
        case .appCaches: "App caches"
        case .agentData: "Agent data"
        case .unclassified: "Unclassified"
        }
    }

    public var symbol: String {
        switch self {
        case .devCaches: "shippingbox"
        case .xcode: "hammer"
        case .temp: "clock.arrow.circlepath"
        case .toolVersions: "square.stack.3d.up"
        case .projects: "folder.badge.gearshape"
        case .worktrees: "arrow.triangle.branch"
        case .containers: "cube"
        case .appCaches: "app.badge"
        case .agentData: "sparkles"
        case .unclassified: "questionmark.folder"
        }
    }
}

public struct CommandSpec: Codable, Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String?

    public init(_ executable: String, _ arguments: [String], cwd: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
    }

    public var display: String {
        ([executable] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
    }
}

/// What the executor does. Actions only ever come from rules, never from agent output.
public enum CleanupAction: Codable, Sendable, Hashable {
    /// Permanently remove these paths (with a `chmod -R u+w` retry for read-only trees).
    case delete([String])
    /// Move these paths to the Trash. Space is freed only when the Trash is emptied.
    case trash([String])
    /// Run the tool's own cleanup commands, in order.
    case commands([CommandSpec])
    /// `git worktree remove` (refuses dirty trees), falling back to a permission fix. `head` is the
    /// commit that was judged merged; removal is refused if the worktree has moved since.
    case removeWorktree(repo: String, path: String, head: String? = nil)
    /// Informational only.
    case none

    public var summary: String {
        switch self {
        case let .delete(paths): "Delete \(paths.count == 1 ? "1 item" : "\(paths.count) items")"
        case let .trash(paths): "Move \(paths.count == 1 ? "1 item" : "\(paths.count) items") to Trash"
        case let .commands(cmds): cmds.map(\.display).joined(separator: " && ")
        case let .removeWorktree(repo, path, _): "git -C \(repo) worktree remove \(path)"
        case .none: "No action"
        }
    }

    public var isDestructive: Bool {
        if case .none = self { return false }
        return true
    }
}

public struct AgentVerdict: Codable, Sendable, Hashable {
    public var risk: Risk
    public var reason: String
    public var agent: String

    public init(risk: Risk, reason: String, agent: String) {
        self.risk = risk
        self.reason = reason
        self.agent = agent
    }
}

public struct Candidate: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var ruleID: String
    public var title: String
    /// Why it is (or isn't) safe, and what you lose.
    public var detail: String
    public var category: CleanupCategory
    public var level: Level
    public var risk: Risk
    /// Allocated bytes as `du` reports them. APFS clones and snapshots can make the real gain smaller.
    public var bytes: Int64
    public var paths: [String]
    public var action: CleanupAction
    public var lastModified: Date?
    /// Reasons this can't be cleaned right now (app running, files open, recently written).
    public var blockers: [String]
    /// Processes whose presence blocks the action; re-checked right before execution.
    public var blockingProcesses: [String]
    /// Skip if anything under the paths was written more recently than this many seconds ago.
    public var minIdleSeconds: TimeInterval?
    public var agentVerdict: AgentVerdict?

    public init(
        ruleID: String,
        key: String? = nil,
        title: String,
        detail: String,
        category: CleanupCategory,
        level: Level,
        risk: Risk,
        bytes: Int64,
        paths: [String],
        action: CleanupAction,
        lastModified: Date? = nil,
        blockers: [String] = [],
        blockingProcesses: [String] = [],
        minIdleSeconds: TimeInterval? = nil
    ) {
        self.id = "\(ruleID):\(key ?? paths.first ?? title)"
        self.ruleID = ruleID
        self.title = title
        self.detail = detail
        self.category = category
        self.level = level
        self.risk = risk
        self.bytes = bytes
        self.paths = paths
        self.action = action
        self.lastModified = lastModified
        self.blockers = blockers
        self.blockingProcesses = blockingProcesses
        self.minIdleSeconds = minIdleSeconds
        self.agentVerdict = nil
    }

    /// The agent can always raise caution. It can lower it only for items the rules
    /// couldn't classify, and never below what a blocker implies.
    public var effectiveRisk: Risk {
        var result = risk
        if let verdict = agentVerdict {
            if verdict.risk > result {
                result = verdict.risk
            } else if category == .unclassified, result == .review {
                result = verdict.risk
            }
        }
        if !blockers.isEmpty { result = max(result, .review) }
        return result
    }

    public var isActionable: Bool { action.isDestructive }

    /// Pre-select only safe, unblocked items at or below the chosen level.
    public func isDefaultSelected(at level: Level) -> Bool {
        isActionable && blockers.isEmpty && effectiveRisk == .safe && self.level <= level
    }
}

/// Something worth knowing that Arin won't act on (snapshots, pending updates, personal data).
public struct Insight: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var bytes: Int64?

    public init(id: String, title: String, detail: String, bytes: Int64? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.bytes = bytes
    }
}

public struct ScanReport: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var disk: DiskStatus
    public var candidates: [Candidate]
    public var insights: [Insight]
    public var ruleErrors: [String: String]

    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

public extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
    }
}

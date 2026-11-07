import Foundation

/// Hard limits on what the executor may touch, regardless of rules or agent output.
public struct Guardrails: Sendable {
    public var home: String
    public var allowedRoots: [String]
    public var protectedPaths: [String]

    public init(home: String = NSHomeDirectory(), tmpDir: String = NSTemporaryDirectory()) {
        let home = Self.canonical((home as NSString).standardizingPath)
        self.home = home
        // $TMPDIR is /var/folders/xx/yyyy/T; its parent also holds C (cache) and X (code-sign clones).
        let tmp = Self.canonical((tmpDir as NSString).standardizingPath)
        let perUser = (tmp as NSString).deletingLastPathComponent
        allowedRoots = [home, "/private/tmp", perUser]
        protectedPaths = [
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Messages", "Library/Mail",
            "Library/Photos", "Library/Keychains", "Library/Accounts", "Library/Preferences",
            "Library/Metadata/CoreSpotlight", "Library/Application Support/MobileSync",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Containers/com.docker.docker", "Library/Group Containers",
            ".ssh", ".gnupg", ".aws", ".kube/config", ".config/gh", ".netrc",
        ].map { "\(home)/\($0)" }
    }

    public enum Violation: Error, CustomStringConvertible, Equatable {
        case notAbsolute(String)
        case outsideAllowedRoots(String)
        case protected(String)
        case tooShallow(String)

        public var description: String {
            switch self {
            case let .notAbsolute(p): "refusing relative path \(p)"
            case let .outsideAllowedRoots(p): "refusing path outside home and temp: \(p)"
            case let .protected(p): "refusing protected path \(p)"
            case let .tooShallow(p): "refusing top-level path \(p)"
            }
        }
    }

    /// Validates a path for deletion or trashing. Symlinked ancestors are resolved and the real
    /// location is checked too, so `~/Library/Caches/X -> ~/Documents/X` can't smuggle a delete
    /// into a protected folder.
    public func check(_ rawPath: String) throws(Violation) {
        guard rawPath.hasPrefix("/") else { throw .notAbsolute(rawPath) }
        let path = Self.canonical((rawPath as NSString).standardizingPath)
        try checkCanonical(path)
        let parent = (path as NSString).deletingLastPathComponent
        let realParent = Self.canonical(URL(fileURLWithPath: parent).resolvingSymlinksInPath().path)
        if realParent != parent {
            try checkCanonical((realParent as NSString).appendingPathComponent((path as NSString).lastPathComponent))
        }
    }

    /// Validates a path a native command will operate on. Commands follow a symlink at the leaf
    /// (unlike delete, which only unlinks it), so the fully resolved target must pass too.
    public func checkTarget(_ rawPath: String) throws(Violation) {
        try check(rawPath)
        let resolved = Self.canonical(URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path)
        if resolved != Self.canonical((rawPath as NSString).standardizingPath) {
            try check(resolved)
        }
    }

    private func checkCanonical(_ path: String) throws(Violation) {
        // macOS volumes are usually case-insensitive: ~/Library/messages is ~/Library/Messages.
        let folded = path.lowercased()
        guard let root = allowedRoots.first(where: { folded == $0.lowercased() || folded.hasPrefix($0.lowercased() + "/") }) else {
            throw .outsideAllowedRoots(path)
        }
        // At least two components below home (no ~/Library, ~/projects); one below temp roots.
        let depth = path.dropFirst(root.count).split(separator: "/").count
        if depth < (root == home ? 2 : 1) { throw .tooShallow(path) }
        for protected in protectedPaths.map({ $0.lowercased() }) {
            // Inside a protected path, or an ancestor of one.
            if folded == protected || folded.hasPrefix(protected + "/") || protected.hasPrefix(folded + "/") {
                throw .protected(path)
            }
        }
    }

    public func check(_ action: CleanupAction) throws(Violation) {
        switch action {
        case let .delete(paths), let .trash(paths):
            for path in paths { try check(path) }
        case let .removeWorktree(_, path, _):
            try check(path)
        case .commands, .none:
            break
        }
    }

    /// Only these tools may be run by an action.
    public static let allowedExecutables: Set<String> = [
        "go", "npm", "uv", "brew", "yarn", "pnpm", "xcrun", "git", "docker", "rustup", "sqlite3", "podman",
    ]

    /// /var and /tmp are symlinks into /private; compare canonical forms.
    static func canonical(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        if path == "/tmp" || path == "/var" { return "/private" + path }
        return path
    }
}

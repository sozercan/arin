import Foundation

/// Hard limits on what the executor may touch, regardless of rules or agent output.
public struct Guardrails: Sendable {
    public var home: String
    public var allowedRoots: [String]
    public var protectedPaths: [String]
    /// Where an uninstall may take an app bundle from. Cleanups never touch these.
    public var applicationRoots: [String]

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
        applicationRoots = ["/Applications", "\(home)/Applications"]
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

    // MARK: Uninstall

    /// The ~/Library folders an uninstall may take an app's own files from, one item deep.
    public static let uninstallFolders = [
        "Application Scripts", "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
        "HTTPStorages", "LaunchAgents", "Logs", "Logs/DiagnosticReports", "Preferences", "Preferences/ByHost",
        "Saved Application State", "WebKit",
    ]

    /// Protected folders an uninstall may take one item from: apps, their preferences and their group
    /// containers live there. The rest of `protectedPaths` stays off limits to uninstalls too.
    static let uninstallExceptions = ["Applications", "Library/Preferences", "Library/Group Containers"]

    /// Validates a path an uninstall moves to the Trash, or puts back: an app bundle in an
    /// Applications folder (or one folder below it), or one item directly inside a per-app folder of
    /// ~/Library. Whether the item belongs to the app is the uninstaller's check; this is the shape
    /// every such path must have. Symlinked ancestors are resolved and checked too.
    public func checkUninstall(_ rawPath: String) throws(Violation) {
        guard rawPath.hasPrefix("/") else { throw .notAbsolute(rawPath) }
        let path = Self.canonical((rawPath as NSString).standardizingPath)
        try checkUninstallCanonical(path)
        let parent = (path as NSString).deletingLastPathComponent
        let realParent = Self.canonical(URL(fileURLWithPath: parent).resolvingSymlinksInPath().path)
        if realParent != parent {
            try checkUninstallCanonical((realParent as NSString).appendingPathComponent((path as NSString).lastPathComponent))
        }
    }

    private func checkUninstallCanonical(_ path: String) throws(Violation) {
        let folded = path.lowercased()
        let name = (folded as NSString).lastPathComponent
        let parent = (folded as NSString).deletingLastPathComponent
        // Apple's own files and dotfiles (.GlobalPreferences.plist) are never an app's leftovers.
        guard !name.hasPrefix("."), !name.contains("com.apple.") else { throw .protected(path) }

        if name.hasSuffix(".app"), let root = applicationRoots.first(where: { folded.hasPrefix($0.lowercased() + "/") }) {
            // `/Applications/Foo.app` or `/Applications/Vendor/Foo.app`, never a bundle inside another.
            let below = folded.dropFirst(root.count + 1).split(separator: "/")
            guard below.count <= 2, !below.dropLast().contains(where: { $0.hasSuffix(".app") }) else {
                throw .protected(path)
            }
            // Apple's apps (and Arin) are refused by bundle ID while the bundle is there to read.
            if FileInfo.exists(path), !AppCatalog.isUninstallable(AppCatalog.bundleID(at: path) ?? "") {
                throw .protected(path)
            }
            return
        }

        let library = "\(home)/Library/".lowercased()
        guard Self.uninstallFolders.contains(where: { parent == library + $0.lowercased() }) else {
            throw .outsideAllowedRoots(path)
        }
        let exceptions = Self.uninstallExceptions.map { "\(home)/\($0)".lowercased() }
        for protected in protectedPaths.map({ $0.lowercased() }) where !exceptions.contains(protected) {
            if folded == protected || folded.hasPrefix(protected + "/") || protected.hasPrefix(folded + "/") {
                throw .protected(path)
            }
        }
    }

    /// A Homebrew cask token such as `visual-studio-code` or `ghostty@tip`. Never an option or a path.
    public static func isCaskToken(_ value: String) -> Bool {
        value.wholeMatch(of: /[a-z0-9][a-z0-9@._+-]*/) != nil && !value.contains("..")
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
        "tmutil", "ollama", "mise",
    ]

    /// Whether an action may run this command. Tools whose other subcommands could do real damage
    /// (turn off backups, delete every model, uninstall runtimes in use) are limited to one exact shape.
    public static func allows(_ command: CommandSpec) -> Bool {
        guard allowedExecutables.contains(command.executable) else { return false }
        let args = command.arguments
        // A model or tool name such as `llama3.2:latest`, `hf.co/org/model:q4`, `npm:prettier`. Never an option.
        func isName(_ value: String) -> Bool {
            value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/@+-]*/) != nil && !value.contains("..")
        }
        switch command.executable {
        case "tmutil":
            // One Time Machine snapshot, by date. Never a volume, never update snapshots.
            return args.count == 2 && args[0] == "deletelocalsnapshots"
                && args[1].wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) != nil
        case "ollama":
            return args.count == 2 && args[0] == "rm" && isName(args[1])
        case "mise":
            // mise decides what's unused; Arin only names the tool.
            return args.count == 4 && Array(args.prefix(3)) == ["prune", "--tools", "--yes"] && isName(args[3])
        default:
            return true
        }
    }

    /// /var and /tmp are symlinks into /private; compare canonical forms.
    static func canonical(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        if path == "/tmp" || path == "/var" { return "/private" + path }
        return path
    }
}

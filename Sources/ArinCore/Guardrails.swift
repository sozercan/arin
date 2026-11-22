import Foundation

public struct Guardrails: Sendable {
    public var home: String
    public var allowedRoots: [String]
    public var protectedPaths: [String]
    public var applicationRoots: [String]
    public var mountPoints: @Sendable () -> [String]? = Guardrails.currentMountPoints

    public init(home: String = NSHomeDirectory(), tmpDir: String = NSTemporaryDirectory()) {
        let home = Self.canonical((home as NSString).standardizingPath)
        self.home = home
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
        case mountInside(String)

        public var description: String {
            switch self {
            case let .notAbsolute(p): "refusing relative path \(p)"
            case let .outsideAllowedRoots(p): "refusing path outside home and temp: \(p)"
            case let .protected(p): "refusing protected path \(p)"
            case let .tooShallow(p): "refusing top-level path \(p)"
            case let .mountInside(p): "refusing \(p): a volume is mounted there or inside it (eject it first)"
            }
        }
    }

    public func check(_ rawPath: String) throws(Violation) {
        guard rawPath.hasPrefix("/") else { throw .notAbsolute(rawPath) }
        let path = Self.canonical((rawPath as NSString).standardizingPath)
        try checkCanonical(path)
        let parent = (path as NSString).deletingLastPathComponent
        let realParent = Self.canonical(URL(fileURLWithPath: parent).resolvingSymlinksInPath().path)
        let real = (realParent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        if realParent != parent { try checkCanonical(real) }
        try checkNoMount(path, real: real)
    }

    func checkNoMount(_ path: String, real: String) throws(Violation) {
        guard let mounts = mountPoints() else { throw .mountInside(path) }
        let targets = Set([path, real].flatMap { [$0, "/System/Volumes/Data" + $0] }.map { $0.lowercased() })
        for mount in mounts.map({ Self.canonical($0).lowercased() }) where mount != "/" {
            if targets.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) { throw .mountInside(path) }
        }
    }

    public static func currentMountPoints() -> [String]? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 16)
        let got = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return nil }
        return buffer.prefix(Int(got)).map { entry in
            withUnsafeBytes(of: entry.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    public func checkTarget(_ rawPath: String) throws(Violation) {
        try check(rawPath)
        let resolved = Self.canonical(URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path)
        if resolved != Self.canonical((rawPath as NSString).standardizingPath) {
            try check(resolved)
        }
    }

    private func checkCanonical(_ path: String) throws(Violation) {
        let folded = path.lowercased()
        guard let root = allowedRoots.first(where: { folded == $0.lowercased() || folded.hasPrefix($0.lowercased() + "/") }) else {
            throw .outsideAllowedRoots(path)
        }
        let depth = path.dropFirst(root.count).split(separator: "/").count
        if depth < (root == home ? 2 : 1) { throw .tooShallow(path) }
        for protected in protectedPaths.map({ $0.lowercased() }) {
            if folded == protected || folded.hasPrefix(protected + "/") || protected.hasPrefix(folded + "/") {
                throw .protected(path)
            }
        }
    }


    public static let uninstallFolders = [
        "Application Scripts", "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
        "HTTPStorages", "LaunchAgents", "Logs", "Logs/DiagnosticReports", "Preferences", "Preferences/ByHost",
        "Saved Application State", "WebKit",
    ]

    static let uninstallExceptions = ["Applications", "Library/Preferences", "Library/Group Containers"]

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
        guard !name.hasPrefix("."), !name.contains("com.apple.") else { throw .protected(path) }

        if name.hasSuffix(".app"), let root = applicationRoots.first(where: { folded.hasPrefix($0.lowercased() + "/") }) {
            let below = folded.dropFirst(root.count + 1).split(separator: "/")
            guard below.count <= 2, !below.dropLast().contains(where: { $0.hasSuffix(".app") }) else {
                throw .protected(path)
            }
            if FileInfo.exists(path), !AppCatalog.isUninstallable(AppCatalog.bundleID(at: path) ?? "") {
                throw .protected(path)
            }
            return
        }

        let library = "\(home)/Library/".lowercased()
        guard Self.uninstallFolders.contains(where: { parent == library + $0.lowercased() }) else {
            throw .outsideAllowedRoots(path)
        }
        if Self.uninstallFolders.contains(where: { folded == library + $0.lowercased() }) { throw .protected(path) }
        let exceptions = Self.uninstallExceptions.map { "\(home)/\($0)".lowercased() }
        for protected in protectedPaths.map({ $0.lowercased() }) where !exceptions.contains(protected) {
            if folded == protected || folded.hasPrefix(protected + "/") || protected.hasPrefix(folded + "/") {
                throw .protected(path)
            }
        }
    }

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

    public static let allowedExecutables: Set<String> = [
        "go", "npm", "uv", "brew", "yarn", "pnpm", "xcrun", "git", "docker", "rustup", "sqlite3", "podman",
        "tmutil", "ollama", "mise",
    ]

    public static func allows(_ command: CommandSpec) -> Bool {
        guard allowedExecutables.contains(command.executable) else { return false }
        let args = command.arguments
        func isName(_ value: String) -> Bool {
            value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/@+-]*/) != nil && !value.contains("..")
        }
        switch command.executable {
        case "tmutil":
            return args.count == 2 && args[0] == "deletelocalsnapshots"
                && args[1].wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{6}/) != nil
        case "ollama":
            return args.count == 2 && args[0] == "rm" && isName(args[1])
        case "mise":
            return args.count == 4 && Array(args.prefix(3)) == ["prune", "--tools", "--yes"] && isName(args[3])
        default:
            return true
        }
    }

    static func canonical(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        if path == "/tmp" || path == "/var" { return "/private" + path }
        return path
    }
}

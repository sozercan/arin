import Foundation

/// An app the user can uninstall, as its Info.plist describes it.
public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String?
    /// Names the app's folders may use instead of its bundle ID: file, bundle and display names.
    public var names: [String]
    /// The executable's name, which its crash reports start with.
    public var executable: String?
    public var fromAppStore: Bool
    /// The Homebrew cask that installed it. Its bundle is removed with `brew uninstall --cask`.
    public var caskToken: String?

    public var id: String { path }
}

public enum AppCatalog {
    /// Apps in the Applications folders and one folder below them (`/Applications/Utilities`, vendor
    /// folders), without Apple's apps or Arin. Symlinks and bundles inside bundles are skipped.
    public static func installed(roots: [String] = Guardrails().applicationRoots) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for root in roots {
            for entry in FileInfo.children(root) where !FileInfo.isSymlink(entry) {
                let name = (entry as NSString).lastPathComponent
                if name.lowercased().hasSuffix(".app") {
                    if let app = app(at: entry) { apps.append(app) }
                } else if !name.hasPrefix("."), FileInfo.isDirectory(entry) {
                    for inner in FileInfo.children(entry) where inner.lowercased().hasSuffix(".app") && !FileInfo.isSymlink(inner) {
                        if let app = app(at: inner) { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The app at `path`, or nil if it isn't an app Arin may uninstall.
    public static func app(at path: String) -> InstalledApp? {
        guard FileInfo.isDirectory(path), !FileInfo.isSymlink(path),
              let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist") as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, isUninstallable(bundleID)
        else { return nil }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let display = info["CFBundleDisplayName"] as? String
        var names: [String] = []
        for candidate in [file, info["CFBundleName"] as? String, display].compactMap({ $0 }) {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            // Short names ("Go", "QQ") would match unrelated folders.
            if trimmed.count >= 3, !trimmed.contains("/"), !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                names.append(trimmed)
            }
        }
        return InstalledApp(
            path: path,
            name: display.flatMap { $0.isEmpty ? nil : $0 } ?? file,
            bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            names: names,
            executable: info["CFBundleExecutable"] as? String,
            fromAppStore: FileInfo.exists("\(path)/Contents/_MASReceipt/receipt"),
            caskToken: nil
        )
    }

    public static func bundleID(at path: String) -> String? {
        (NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist") as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    /// A bundle ID Arin may uninstall: reverse-DNS shaped, so it can't match unrelated files,
    /// and not one of Apple's apps or Arin itself.
    public static func isUninstallable(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return bundleID.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+/) != nil
            && !lower.hasPrefix("com.apple.") && !lower.hasPrefix(ArinStore.releaseBundleID.lowercased())
    }

    /// The Homebrew cask that installed each app, keyed by the app's lowercased path.
    public static func caskTokens() async -> [String: String] {
        guard Shell.which("brew") != nil else { return [:] }
        let result = await Shell.run("brew", ["info", "--cask", "--json=v2", "--installed"], timeout: 60)
        guard result.ok else { return [:] }
        return parseCasks(Data(result.stdout.utf8))
    }

    static func parseCasks(_ data: Data, appDir: String = "/Applications") -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]]
        else { return [:] }
        var tokens: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, Guardrails.isCaskToken(token) else { continue }
            for case let artifact as [String: Any] in cask["artifacts"] as? [Any] ?? [] {
                guard let apps = artifact["app"] as? [Any] else { continue }
                // `app "Foo.app", target: "Bar.app"` installs Bar.app; the target may be absolute.
                let targets = ([artifact["target"]] + apps.map { ($0 as? [String: Any])?["target"] })
                    .compactMap { $0 as? String }
                let names = targets.isEmpty ? apps.compactMap { $0 as? String } : targets
                for name in names {
                    let path = name.hasPrefix("/") ? name : (appDir as NSString).appendingPathComponent(name)
                    tokens[path.lowercased()] = token
                }
            }
        }
        return tokens
    }
}

/// One thing an uninstall moves to the Trash: the app bundle, or a file the app keeps in ~/Library.
public struct AppFile: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case app, applicationSupport, applicationScripts, caches, containers, groupContainers, preferences
        case savedState, httpStorage, webKit, cookies, launchAgents, logs, crashReports

        /// Where these live, relative to ~/Library. Only items directly inside are considered.
        public var folders: [String] {
            switch self {
            case .app: []
            case .applicationSupport: ["Application Support"]
            case .applicationScripts: ["Application Scripts"]
            case .caches: ["Caches"]
            case .containers: ["Containers"]
            case .groupContainers: ["Group Containers"]
            case .preferences: ["Preferences", "Preferences/ByHost"]
            case .savedState: ["Saved Application State"]
            case .httpStorage: ["HTTPStorages"]
            case .webKit: ["WebKit"]
            case .cookies: ["Cookies"]
            case .launchAgents: ["LaunchAgents"]
            case .logs: ["Logs"]
            case .crashReports: ["Logs/DiagnosticReports"]
            }
        }

        public var label: String {
            switch self {
            case .app: "Application"
            case .applicationSupport: "Application Support"
            case .applicationScripts: "Application Scripts"
            case .caches: "Cache"
            case .containers: "Container"
            case .groupContainers: "Group Container"
            case .preferences: "Preferences"
            case .savedState: "Saved State"
            case .httpStorage: "HTTP Storage"
            case .webKit: "WebKit Data"
            case .cookies: "Cookies"
            case .launchAgents: "Launch Agent"
            case .logs: "Logs"
            case .crashReports: "Crash Report"
            }
        }

        /// Folders where apps often use their name instead of their bundle ID.
        var matchesNames: Bool { [.applicationSupport, .caches, .logs].contains(self) }
    }

    public var path: String
    public var kind: Kind
    public var bytes: Int64
    /// Matched by the app's name rather than its bundle ID, or shared with the developer's other
    /// apps. Listed, but not checked until the user checks it.
    public var needsReview: Bool
    public var note: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum AppFiles {
    /// The app bundle and everything in ~/Library that belongs to the app, by bundle ID or, in
    /// folders where apps use their name, by name. `others` are the other installed apps: files
    /// that belong to one of them (`com.foo.app.pro` for `com.foo.app`, or a shared name) are left out.
    public static func find(for app: InstalledApp, others: [InstalledApp], guardrails: Guardrails = Guardrails()) async -> [AppFile] {
        // Another copy of the same app (one in ~/Applications too) uses the same files.
        let copy = others.first { $0.bundleID.lowercased() == app.bundleID.lowercased() && Uninstaller.canonical($0.path) != Uninstaller.canonical(app.path) }
        var files: [AppFile] = []
        if FileInfo.exists(app.path), (try? guardrails.checkUninstall(app.path)) != nil {
            files.append(AppFile(path: app.path, kind: .app, bytes: 0, needsReview: false,
                                 note: app.caskToken.map { "Removed with brew uninstall --cask \($0), not moved to the Trash" }))
        }
        for kind in AppFile.Kind.allCases {
            for folder in kind.folders {
                for path in FileInfo.children("\(guardrails.home)/Library/\(folder)") {
                    guard let review = match((path as NSString).lastPathComponent, kind: kind, app: app, others: others),
                          (try? guardrails.checkUninstall(path)) != nil
                    else { continue }
                    let note: String? = if let copy {
                        "Also used by the copy at \((copy.path as NSString).abbreviatingWithTildeInPath)"
                    } else {
                        switch (review, kind) {
                        case (true, .groupContainers): "Shared with the developer's other apps"
                        case (true, _): "Matched by name, not bundle ID"
                        case (false, .launchAgents): "Stays loaded until you log out"
                        default: nil
                        }
                    }
                    files.append(AppFile(path: path, kind: kind, bytes: 0, needsReview: review || copy != nil, note: note))
                }
            }
        }
        let sizes = await Size.allocated(files.map(\.path))
        return files.map { file in
            var sized = file
            sized.bytes = sizes[file.path] ?? 0
            return sized
        }
    }

    /// Whether the item called `name` in `kind`'s folder belongs to `app`: nil if it doesn't,
    /// otherwise whether the user should look before it goes.
    static func match(_ name: String, kind: AppFile.Kind, app: InstalledApp, others: [InstalledApp]) -> Bool? {
        let lower = name.lowercased()
        let id = app.bundleID.lowercased()
        let otherIDs = others.map { $0.bundleID.lowercased() }.filter { $0 != id }

        if kind == .crashReports {
            // `<executable>-<date>.ips`. Another app with the same executable name can't be told apart.
            guard let exe = app.executable?.lowercased(), exe.count >= 3,
                  !others.contains(where: { $0.executable?.lowercased() == exe }),
                  lower.hasPrefix(exe + "-"),
                  [".ips", ".crash", ".diag", ".spin", ".hang"].contains(where: { lower.hasSuffix($0) })
            else { return nil }
            return false
        }

        var stem = lower
        for suffix in [".plist", ".savedstate", ".binarycookies"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        if kind == .groupContainers {
            // `group.<id>` or `<TEAMID>.<id>`.
            if stem.hasPrefix("group.") {
                stem.removeFirst("group.".count)
            } else if let dot = stem.firstIndex(of: "."), stem.distance(from: stem.startIndex, to: dot) == 10 {
                stem = String(stem[stem.index(after: dot)...])
            }
        }
        func belongs(_ value: String, to bundleID: String) -> Bool { value == bundleID || value.hasPrefix(bundleID + ".") }

        if belongs(stem, to: id) {
            // `com.foo.app.pro` is its own app when it's installed, not an extension of `com.foo.app`.
            if otherIDs.contains(where: { $0.hasPrefix(id + ".") && belongs(stem, to: $0) }) { return nil }
            return kind == .groupContainers
        }
        guard kind.matchesNames, app.names.contains(where: { $0.lowercased() == lower }) else { return nil }
        // A name another installed app also goes by can't be told apart.
        if others.contains(where: { $0.bundleID.lowercased() != id && $0.names.contains { $0.lowercased() == lower } }) { return nil }
        return true
    }
}

/// Moves an app and the files it keeps in ~/Library to the Trash. Separate from the executor:
/// it's started by the user for one app, never from a scan, and it may reach places cleanups
/// can't (app bundles, preferences, group containers), so every file is matched to the app again here.
public struct Uninstaller: Sendable {
    public var guardrails: Guardrails
    /// Kept paths are refused here too. If the file exists but can't be read, nothing is removed.
    public var keepListURL: URL?
    public var captureState: @Sendable () async -> SystemState

    public init(
        guardrails: Guardrails = Guardrails(),
        keepListURL: URL? = KeepList.defaultURL,
        captureState: @escaping @Sendable () async -> SystemState = { await SystemState.capture(includeOpenFiles: false) }
    ) {
        self.guardrails = guardrails
        self.keepListURL = keepListURL
        self.captureState = captureState
    }

    /// Why the app can't be uninstalled right now, or nil.
    public func refusal(for app: InstalledApp, state: SystemState? = nil) async -> String? {
        do { try guardrails.checkUninstall(app.path) } catch { return error.description }
        if FileInfo.exists(app.path), AppCatalog.app(at: app.path)?.bundleID != app.bundleID {
            return "\((app.path as NSString).lastPathComponent) changed since it was checked; look it up again"
        }
        let state = if let state { state } else { await captureState() }
        if state.hasExecutable(under: app.path) { return "\(app.name) is running. Quit it first." }
        return nil
    }

    public func run(_ app: InstalledApp, files: [AppFile], progress: (@Sendable (CleanupEvent) -> Void)? = nil) async -> CleanupReport {
        let before = Disk.status(path: guardrails.home).freeBytes
        // The bundle goes first: if it can't be removed, the app stays usable with its files.
        let ordered = files.filter { $0.kind == .app } + files.filter { $0.kind != .app }
        progress?(.started(total: ordered.count))
        let state = await captureState()
        let others = AppCatalog.installed(roots: guardrails.applicationRoots).filter { Self.canonical($0.path) != Self.canonical(app.path) }
        let keep: Result<KeepList, any Error> = keepListURL.map { url in Result { try KeepList.load(from: url) } }
            ?? .success(KeepList())
        var stop = await refusal(for: app, state: state)

        var results: [CleanupItemResult] = []
        for (index, file) in ordered.enumerated() {
            progress?(.item(index: index, title: Self.title(file, app: app)))
            let result = if let stop { Self.result(file, app: app, .skipped, stop) }
                else { await remove(file, app: app, others: others, keep: keep, state: state) }
            if file.kind == .app, result.status != .cleaned, stop == nil {
                stop = "left in place because \(app.name) itself wasn't removed"
            }
            results.append(result)
            progress?(.finished(result))
        }

        let cleaned = results.filter { $0.status == .cleaned }
        var notes: [String] = []
        let trashedBytes = cleaned.filter(\.trashed).reduce(0) { $0 + $1.estimatedBytes }
        if trashedBytes > 0 { notes.append("\(trashedBytes.formattedBytes) went to the Trash. Empty the Trash to free it.") }
        if ordered.contains(where: { $0.kind == .launchAgents && cleaned.map(\.id).contains($0.id) }) {
            notes.append("Removed launch agents stay loaded until you log out.")
        }
        return CleanupReport(
            items: results,
            freeBefore: before,
            freeAfter: Disk.status(path: guardrails.home).freeBytes,
            estimatedBytes: cleaned.reduce(0) { $0 + $1.estimatedBytes },
            explanations: notes
        )
    }

    func remove(_ file: AppFile, app: InstalledApp, others: [InstalledApp], keep: Result<KeepList, any Error>, state: SystemState) async -> CleanupItemResult {
        func result(_ status: CleanupItemResult.Status, _ message: String) -> CleanupItemResult {
            Self.result(file, app: app, status, message)
        }
        // The file list comes from the caller; match each path to the app again, by where it is.
        guard belongs(file, to: app, others: others) else { return result(.skipped, "not one of \(app.name)'s files") }
        do { try guardrails.checkUninstall(file.path) } catch { return result(.skipped, error.description) }
        switch keep {
        case let .failure(error):
            return result(.skipped, "\(error)")
        case let .success(list):
            if let kept = KeptPaths(list.entries).insideOrAt(file.path) {
                return result(.skipped, "contains \(kept.title)\(KeepList.keptBlockerSuffix)")
            }
        }
        guard FileInfo.exists(file.path) || FileInfo.isSymlink(file.path) else { return result(.skipped, "already gone") }
        if state.hasExecutable(under: file.path) { return result(.skipped, "a program inside it is running") }

        if file.kind == .app, let token = app.caskToken, Guardrails.isCaskToken(token), Shell.which("brew") != nil {
            let command = CommandSpec("brew", ["uninstall", "--cask", token])
            let output = await Shell.run(command.executable, command.arguments, timeout: 600)
            if !FileInfo.exists(file.path) { return result(.cleaned, command.display) }
            let tail = String((output.stderr.isEmpty ? output.stdout : output.stderr).suffix(300))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return result(.failed, "\(command.display): \(output.timedOut ? "timed out" : tail)")
        }

        do {
            var location: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: &location)
            var done = result(.cleaned, "moved to Trash")
            done.trashed = true
            done.trashedPaths = location?.path.map { [TrashedPath(original: file.path, location: $0)] }
            return done
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            return result(.failed, file.kind == .app
                ? "macOS didn't let Arin move it. App Store and installer apps belong to the system: drag it to the Trash in Finder, or allow Arin under System Settings → Privacy & Security → App Management."
                : error.localizedDescription)
        } catch {
            return result(.failed, error.localizedDescription)
        }
    }

    /// The bundle itself, or an item directly in one of `file.kind`'s folders that matches the app.
    func belongs(_ file: AppFile, to app: InstalledApp, others: [InstalledApp]) -> Bool {
        let path = Self.canonical(file.path)
        if file.kind == .app { return path == Self.canonical(app.path) }
        let parent = (path as NSString).deletingLastPathComponent.lowercased()
        let library = "\(guardrails.home)/Library/".lowercased()
        guard file.kind.folders.contains(where: { parent == library + $0.lowercased() }) else { return false }
        return AppFiles.match((path as NSString).lastPathComponent, kind: file.kind, app: app, others: others) != nil
    }

    /// `standardizingPath` turns /private/var into /var; compare the form the guardrails use.
    static func canonical(_ path: String) -> String {
        Guardrails.canonical((path as NSString).standardizingPath)
    }

    static func title(_ file: AppFile, app: InstalledApp) -> String {
        file.kind == .app ? "\(app.name) app" : "\(file.kind.label): \(file.name)"
    }

    static func result(_ file: AppFile, app: InstalledApp, _ status: CleanupItemResult.Status, _ message: String) -> CleanupItemResult {
        CleanupItemResult(id: file.path, title: title(file, app: app), status: status, message: message,
                          estimatedBytes: status == .cleaned ? file.bytes : 0, trashed: false, trashedPaths: nil)
    }
}

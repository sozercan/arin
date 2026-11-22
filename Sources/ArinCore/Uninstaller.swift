import Foundation

public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var bundleID: String
    public var version: String?
    public var names: [String]
    public var executable: String?
    public var fromAppStore: Bool
    public var caskToken: String?

    public var id: String { path }
}

public enum AppCatalog {
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

    public static func isUninstallable(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return bundleID.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+/) != nil
            && !lower.hasPrefix("com.apple.") && !lower.hasPrefix(ArinStore.releaseBundleID.lowercased())
    }

    public static func caskTokens() async -> [String: String] {
        await installedCasks() ?? [:]
    }

    public static func installedCasks() async -> [String: String]? {
        guard Shell.which("brew") != nil else { return [:] }
        let result = await Shell.run("brew", ["info", "--cask", "--json=v2", "--installed"], timeout: 60)
        guard result.ok else { return nil }
        return parseCasks(Data(result.stdout.utf8))
    }

    public static func caskroom() -> String? {
        guard let brew = Shell.which("brew") else { return nil }
        let real = URL(fileURLWithPath: brew).resolvingSymlinksInPath().path
        let candidates = [brew, real].map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }
            .flatMap { [$0, ($0 as NSString).deletingLastPathComponent] }
            .map { "\($0)/Caskroom" }
        return candidates.first { FileInfo.isDirectory($0) }
    }

    static func caskroomApps(_ token: String, in caskroom: String) -> [String] {
        guard Guardrails.isCaskToken(token) else { return [] }
        return FileInfo.children("\(caskroom)/\(token)").flatMap { version in
            FileInfo.children(version).compactMap { entry -> String? in
                guard entry.lowercased().hasSuffix(".app"), FileInfo.isSymlink(entry),
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry)
                else { return nil }
                return target.hasPrefix("/") ? target : ((version as NSString).appendingPathComponent(target) as NSString).standardizingPath
            }
        }
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

public struct AppFile: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case app, applicationSupport, applicationScripts, caches, containers, groupContainers, preferences
        case savedState, httpStorage, webKit, cookies, launchAgents, logs, crashReports

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

        var matchesNames: Bool { [.applicationSupport, .caches, .logs].contains(self) }
    }

    public var path: String
    public var kind: Kind
    public var bytes: Int64
    public var needsReview: Bool
    public var note: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum AppFiles {
    public static func find(for app: InstalledApp, others: [InstalledApp], guardrails: Guardrails = Guardrails()) async -> [AppFile] {
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

    static func match(_ name: String, kind: AppFile.Kind, app: InstalledApp, others: [InstalledApp]) -> Bool? {
        let lower = name.lowercased()
        let id = app.bundleID.lowercased()
        let otherIDs = others.map { $0.bundleID.lowercased() }.filter { $0 != id }

        if kind == .crashReports {
            guard let exe = app.executable?.lowercased(), exe.count >= 3,
                  !others.contains(where: { $0.executable?.lowercased() == exe }),
                  lower.hasPrefix(exe + "-"),
                  lower.dropFirst(exe.count + 1).prefixMatch(of: /\d{4}-\d{2}-\d{2}/) != nil,
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
            if stem.hasPrefix("group.") {
                stem.removeFirst("group.".count)
            } else if let dot = stem.firstIndex(of: "."), stem.distance(from: stem.startIndex, to: dot) == 10 {
                stem = String(stem[stem.index(after: dot)...])
            }
        }
        func belongs(_ value: String, to bundleID: String) -> Bool { value == bundleID || value.hasPrefix(bundleID + ".") }

        if belongs(stem, to: id) {
            if otherIDs.contains(where: { $0.hasPrefix(id + ".") && belongs(stem, to: $0) }) { return nil }
            return kind == .groupContainers
        }
        guard kind.matchesNames, app.names.contains(where: { $0.lowercased() == lower }) else { return nil }
        if others.contains(where: { $0.bundleID.lowercased() != id && $0.names.contains { $0.lowercased() == lower } }) { return nil }
        return true
    }
}

public struct Uninstaller: Sendable {
    public var guardrails: Guardrails
    public var keepListURL: URL?
    public var captureState: @Sendable () async -> SystemState
    public var casks: @Sendable () async -> [String: String]?
    public var caskroom: String?

    public init(
        guardrails: Guardrails = Guardrails(),
        keepListURL: URL? = KeepList.defaultURL,
        casks: @escaping @Sendable () async -> [String: String]? = { await AppCatalog.installedCasks() },
        caskroom: String? = AppCatalog.caskroom(),
        captureState: @escaping @Sendable () async -> SystemState = { await SystemState.capture(includeOpenFiles: false) }
    ) {
        self.guardrails = guardrails
        self.keepListURL = keepListURL
        self.casks = casks
        self.caskroom = caskroom
        self.captureState = captureState
    }

    public static func caskRefusal(for app: InstalledApp, casks: [String: String]) -> String? {
        guard let token = app.caskToken else { return nil }
        let casks = canonicalKeys(casks)
        let own: Set = [canonical(app.path).lowercased(), real(app.path).lowercased()]
        let siblings = casks.filter { $0.value == token && !own.contains($0.key) }.keys
            .map { FileInfo.actualCase($0) }
            .filter { FileInfo.exists($0) }
            .sorted()
        guard !siblings.isEmpty else { return nil }
        let names = siblings.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return "Homebrew's \(token) cask also installs \(names). Run brew uninstall --cask \(token) to remove them together."
    }

    public static func isRunning(under path: String, in state: SystemState) -> Bool {
        func real(_ path: String) -> String { Self.real(path).lowercased() }
        let targets = Set([canonical(path).lowercased(), real(path)]).map { $0 + "/" }
        return state.processPaths.contains { process in
            guard process.hasPrefix("/") else { return false }
            let raw = canonical(process).lowercased()
            return targets.contains { raw.hasPrefix($0) } || targets.contains { real(process).hasPrefix($0) }
        }
    }

    public func refusal(for app: InstalledApp, state: SystemState? = nil) async -> String? {
        do { try guardrails.checkUninstall(app.path) } catch { return error.description }
        if FileInfo.exists(app.path), AppCatalog.app(at: app.path)?.bundleID != app.bundleID {
            return "\((app.path as NSString).lastPathComponent) changed since it was checked; look it up again"
        }
        let state = if let state { state } else { await captureState() }
        if state.processPaths.isEmpty { return "Arin couldn't list running apps, so it can't tell whether \(app.name) is running. Try again." }
        if Self.isRunning(under: app.path, in: state) { return "\(app.name) is running. Quit it first." }
        return nil
    }

    public func run(_ app: InstalledApp, files: [AppFile], progress: (@Sendable (CleanupEvent) -> Void)? = nil) async -> CleanupReport {
        let before = Disk.status(path: guardrails.home).freeBytes
        let ordered = files.filter { $0.kind == .app } + files.filter { $0.kind != .app }
        progress?(.started(total: ordered.count))
        var app = app
        var stop: String?
        if ordered.first?.kind == .app {
            if let casks = await casks().map(Self.canonicalKeys) {
                app.caskToken = [Self.canonical(app.path), Self.real(app.path)].lazy.compactMap { casks[$0.lowercased()] }.first
                stop = Self.caskRefusal(for: app, casks: casks)
            } else if let token = app.caskToken {
                stop = "Homebrew didn't answer, so Arin can't tell what brew uninstall --cask \(token) would remove. Try again."
            }
        }

        var results: [CleanupItemResult] = []
        for (index, file) in ordered.enumerated() {
            progress?(.item(index: index, title: Self.title(file, app: app)))
            let state = await captureState()
            let keep: Result<KeepList, any Error> = keepListURL.map { url in Result { try KeepList.load(from: url) } }
                ?? .success(KeepList())
            let others = otherApps(than: app)
            let refused = if let stop { stop } else { await refusal(for: app, state: state) }
            let result = if let refused { Self.result(file, app: app, .skipped, refused) }
                else { await remove(file, app: app, others: others, keep: keep, state: state) }
            if file.kind == .app, result.status != .cleaned, stop == nil {
                stop = refused ?? "left in place because \(app.name) itself wasn't removed"
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
        guard belongs(file, to: app, others: others) else { return result(.skipped, "not one of \(app.name)'s files") }
        do { try guardrails.checkUninstall(file.path) } catch { return result(.skipped, error.description) }
        switch keep {
        case let .failure(error):
            return result(.skipped, "\(error)")
        case let .success(list):
            let kept = KeptPaths(list.entries)
            if let entry = kept.insideOrAt(file.path) {
                return result(.skipped, "contains \(entry.title)\(KeepList.keptBlockerSuffix)")
            }
            if let entry = kept.around(file.path) {
                return result(.skipped, "inside \(entry.title)\(KeepList.keptBlockerSuffix)")
            }
        }
        guard FileInfo.exists(file.path) || FileInfo.isSymlink(file.path) else { return result(.skipped, "already gone") }
        if Self.isRunning(under: file.path, in: state) { return result(.skipped, "a program inside it is running") }
        let id = app.bundleID.lowercased()
        if file.kind != .app, let copy = others.first(where: { $0.bundleID.lowercased() == id && Self.isRunning(under: $0.path, in: state) }) {
            return result(.skipped, "the copy at \((copy.path as NSString).abbreviatingWithTildeInPath) is running and uses it")
        }

        if file.kind == .app, let token = app.caskToken, Guardrails.isCaskToken(token) {
            let linked = caskroom.map { AppCatalog.caskroomApps(token, in: $0) } ?? []
            guard linked.contains(where: { Self.real($0).lowercased() == Self.real(file.path).lowercased() }) else {
                return result(.skipped, "Homebrew's \(token) cask doesn't point at this copy. If it's Homebrew's, run brew uninstall --cask \(token).")
            }
            guard Shell.which("brew") != nil else { return result(.skipped, "brew isn't on PATH, and \(token) is a Homebrew cask") }
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

    func belongs(_ file: AppFile, to app: InstalledApp, others: [InstalledApp]) -> Bool {
        let path = Self.canonical(file.path)
        if file.kind == .app { return path == Self.canonical(app.path) }
        let parent = (path as NSString).deletingLastPathComponent.lowercased()
        let library = "\(guardrails.home)/Library/".lowercased()
        guard file.kind.folders.contains(where: { parent == library + $0.lowercased() }) else { return false }
        return AppFiles.match((path as NSString).lastPathComponent, kind: file.kind, app: app, others: others) != nil
    }

    func otherApps(than app: InstalledApp) -> [InstalledApp] {
        let own: Set = [Self.canonical(app.path).lowercased(), Self.real(app.path).lowercased()]
        return AppCatalog.installed(roots: guardrails.applicationRoots)
            .filter { !own.contains(Self.canonical($0.path).lowercased()) && !own.contains(Self.real($0.path).lowercased()) }
    }

    static func canonicalKeys(_ casks: [String: String]) -> [String: String] {
        Dictionary(casks.map { (Guardrails.canonical($0.key), $0.value) }) { first, _ in first }
    }

    static func real(_ path: String) -> String {
        Guardrails.canonical(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    static func canonical(_ path: String) -> String {
        Guardrails.canonical((path as NSString).standardizingPath)
    }

    public static func title(_ file: AppFile, app: InstalledApp) -> String {
        file.kind == .app ? "\(app.name) app" : "\(file.kind.label): \(file.name)"
    }

    static func result(_ file: AppFile, app: InstalledApp, _ status: CleanupItemResult.Status, _ message: String) -> CleanupItemResult {
        CleanupItemResult(id: file.path, title: title(file, app: app), status: status, message: message,
                          estimatedBytes: status == .cleaned ? file.bytes : 0, trashed: false, trashedPaths: nil)
    }
}

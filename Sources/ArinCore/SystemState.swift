import Foundation

/// A snapshot of what's running and which files are open, used for preflight checks.
public struct SystemState: Sendable {
    /// Executable paths of running processes.
    public var processPaths: [String]
    /// Every directory that contains (at any depth) an open file or a process cwd.
    public var busyDirectories: Set<String>
    /// Open file paths themselves.
    public var openFiles: Set<String>
    /// Whether the open-file snapshot succeeded; when false, open-file checks are skipped and reported.
    public var openFilesKnown: Bool

    public static let empty = SystemState(processPaths: [], busyDirectories: [], openFiles: [], openFilesKnown: false)

    public init(processPaths: [String], busyDirectories: Set<String>, openFiles: Set<String>, openFilesKnown: Bool) {
        self.processPaths = processPaths
        self.busyDirectories = busyDirectories
        self.openFiles = openFiles
        self.openFilesKnown = openFilesKnown
    }

    public init(processPaths: [String], openPaths: [String], openFilesKnown: Bool = true) {
        var busy = Set<String>()
        var files = Set<String>()
        for path in openPaths where path.hasPrefix("/") {
            files.insert(path)
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count > 1, busy.insert(dir).inserted {
                dir = (dir as NSString).deletingLastPathComponent
            }
            // A process cwd is reported as a directory path; treat it as busy itself.
            busy.insert(path)
        }
        self.init(processPaths: processPaths, busyDirectories: busy, openFiles: files, openFilesKnown: openFilesKnown)
    }

    public static func capture(includeOpenFiles: Bool = true) async -> SystemState {
        let ps = await Shell.run("ps", ["-axww", "-o", "comm="], timeout: 20)
        let processes = ps.lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard includeOpenFiles else {
            return SystemState(processPaths: processes, openPaths: [], openFilesKnown: false)
        }
        let uid = String(getuid())
        let lsof = await Shell.run("lsof", ["-n", "-P", "-w", "-u", uid, "-Fn"], timeout: 90)
        let open = lsof.stdout.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("n/") else { return nil }
            return String(line.dropFirst())
        }
        return SystemState(processPaths: processes, openPaths: open, openFilesKnown: !lsof.timedOut && !open.isEmpty)
    }

    /// True if a process named `name` runs, matching the executable's basename or an app bundle name.
    public func isRunning(_ name: String) -> Bool {
        let bundle = "/\(name).app/"
        return processPaths.contains { path in
            (path as NSString).lastPathComponent == name || path.contains(bundle)
        }
    }

    /// Loose match for apps whose data folder name differs from the executable
    /// ("Code - Insiders" -> "Visual Studio Code - Insiders.app"). Errs toward reporting running.
    public func isAppRunning(matching folderName: String) -> Bool {
        let needle = folderName.lowercased().replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return false }
        return processPaths.contains { path in
            path.split(separator: "/").contains { component in
                component.hasSuffix(".app")
                    && component.lowercased().replacingOccurrences(of: " ", with: "").contains(needle)
            }
        }
    }

    /// Names prefixed with `app:` use the loose app-bundle match; others match exactly.
    public func runningAny(_ names: [String]) -> [String] {
        names.compactMap { name in
            if name.hasPrefix("app:") {
                let app = String(name.dropFirst(4))
                return isAppRunning(matching: app) ? app : nil
            }
            return isRunning(name) ? name : nil
        }
    }

    /// True if a file under `path` is open or a process works inside it.
    public func isBusy(_ path: String) -> Bool {
        busyDirectories.contains(path) || openFiles.contains(path)
    }

    /// True if a running process's executable lives under `path`.
    public func hasExecutable(under path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return processPaths.contains { $0.hasPrefix(prefix) }
    }

    /// Preflight blockers for a set of paths.
    public func blockers(paths: [String], processes: [String], minIdle: TimeInterval?, now: Date = Date()) -> [String] {
        var reasons: [String] = []
        let running = runningAny(processes)
        if !running.isEmpty {
            reasons.append("\(running.joined(separator: ", ")) is running")
        }
        let busy = paths.filter { isBusy($0) }
        if !busy.isEmpty {
            reasons.append(busy.count == paths.count && paths.count == 1
                ? "files are open by a running process"
                : "\(busy.count) of \(paths.count) paths have open files")
        }
        if let minIdle {
            let recent = paths.compactMap { FileInfo.recentActivity($0) }.max()
            if let recent, now.timeIntervalSince(recent) < minIdle {
                let minutes = Int(now.timeIntervalSince(recent) / 60)
                reasons.append("written \(minutes) min ago (may be in use)")
            }
        }
        return reasons
    }
}

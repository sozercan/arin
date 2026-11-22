import Foundation

public struct SystemState: Sendable {
    public var processPaths: [String]
    public var busyDirectories: Set<String>
    public var openFiles: Set<String>
    public var openFilesKnown: Bool

    public static let empty = SystemState(processPaths: [], busyDirectories: [], openFiles: [], openFilesKnown: true)

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

    public func isRunning(_ name: String) -> Bool {
        let bundle = "/\(name).app/"
        return processPaths.contains { path in
            (path as NSString).lastPathComponent == name || path.contains(bundle)
        }
    }

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

    public func runningAny(_ names: [String]) -> [String] {
        names.compactMap { name in
            if name.hasPrefix("app:") {
                let app = String(name.dropFirst(4))
                return isAppRunning(matching: app) ? app : nil
            }
            return isRunning(name) ? name : nil
        }
    }

    public func isBusy(_ path: String) -> Bool {
        busyDirectories.contains(path) || openFiles.contains(path)
    }

    public func hasExecutable(under path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return processPaths.contains { $0.hasPrefix(prefix) }
    }

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

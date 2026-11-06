import Foundation

public enum Size {
    /// Allocated bytes per path via `du -sk`. Missing paths are omitted.
    /// `du` counts APFS clones in full, so totals can overstate what deleting frees.
    public static func allocated(_ paths: [String], timeout: TimeInterval = 180) async -> [String: Int64] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [:] }
        var sizes: [String: Int64] = [:]
        for chunk in existing.chunked(64) {
            let result = await Shell.run("du", ["-sk"] + chunk, timeout: timeout)
            for (path, kb) in parseDu(result.stdout) {
                sizes[path, default: 0] += kb * 1024
            }
        }
        return sizes
    }

    public static func allocated(_ path: String, timeout: TimeInterval = 180) async -> Int64 {
        await allocated([path], timeout: timeout)[path] ?? 0
    }

    public static func total(_ paths: [String], timeout: TimeInterval = 180) async -> Int64 {
        await allocated(paths, timeout: timeout).values.reduce(0, +)
    }

    /// Immediate children of `dir` with their allocated size.
    public static func children(of dir: String, timeout: TimeInterval = 180) async -> [(path: String, bytes: Int64)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let paths = names.map { (dir as NSString).appendingPathComponent($0) }
        let sizes = await allocated(paths, timeout: timeout)
        return sizes.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    static func parseDu(_ output: String) -> [(String, Int64)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            return (String(parts[1]), kb)
        }
    }
}

public enum FileInfo {
    public static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    /// Newest modification time among the path and its direct children. Cheap recency signal
    /// that catches most active build/cache directories without a full walk.
    public static func recentActivity(_ path: String) -> Date? {
        var newest = modified(path)
        for child in children(path).prefix(500) {
            if let date = modified(child), date > (newest ?? .distantPast) { newest = date }
        }
        return newest
    }

    public static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Any file under `path` modified within the window. Stops at the first hit; a walk that
    /// can't finish (timeout, unreadable subtree) counts as recently written.
    public static func hasRecentWrites(_ path: String, within window: TimeInterval) async -> Bool {
        guard exists(path) || isSymlink(path) else { return false }
        let minutes = String(max(Int(window / 60), 1))
        let result = await Shell.run("find", [path, "-mmin", "-\(minutes)", "-print", "-quit"], timeout: 120)
        return !result.ok || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the tree holds a git checkout outside package-manager layouts. Searches the whole
    /// tree; a walk that can't finish (timeout, unreadable subtree) counts as "yes".
    public static func containsGitCheckout(_ path: String) async -> Bool {
        // Only recognized package-manager output is skipped, by layout, not by a bare folder name:
        // a real project under scratch/checkouts/ or scratch/pkg/ must still be found.
        let result = await Shell.run("find", [
            path,
            "(", "-path", "*/SourcePackages/checkouts", "-o", "-path", "*/.build/checkouts",
            "-o", "-path", "*/pkg/mod", "-o", "-name", "node_modules", ")", "-prune",
            "-o", "-name", ".git", "-print", "-quit",
        ], timeout: 120)
        return !result.ok || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The path with each component spelled as it is on disk. APFS is usually case-insensitive,
    /// so `Caches/Yarn` finds `Caches/yarn`; comparisons need the real spelling.
    public static func actualCase(_ path: String) -> String {
        var result = "/"
        for component in path.split(separator: "/").map(String.init) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: result)) ?? []
            let match = names.first { $0 == component } ?? names.first { $0.caseInsensitiveCompare(component) == .orderedSame }
            result = (result as NSString).appendingPathComponent(match ?? component)
        }
        return result
    }

    public static func resolveSymlink(_ path: String) -> String? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        if dest.hasPrefix("/") { return (dest as NSString).standardizingPath }
        return (((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest) as NSString)
            .standardizingPath
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

import Foundation

public enum Size {
    public static func allocated(_ paths: [String], timeout: TimeInterval = 180) async -> [String: Int64] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) || FileInfo.isSymlink($0) }
        guard !existing.isEmpty else { return [:] }
        let deadline = Date().addingTimeInterval(timeout)
        let measured = await concurrentMap(existing, limit: 4) { path -> (String, Int64?) in
            (path, await measure(path, deadline: deadline))
        }
        var sizes: [String: Int64] = [:]
        for (path, bytes) in measured { if let bytes { sizes[path] = bytes } }
        return sizes
    }

    static func measure(_ path: String, deadline: Date) async -> Int64? {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: DiskUsage.measure(path, deadline: deadline, cancelled: flag))
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    public static func allocated(_ path: String, timeout: TimeInterval = 180) async -> Int64 {
        await allocated([path], timeout: timeout)[path] ?? 0
    }

    public static func total(_ paths: [String], timeout: TimeInterval = 180) async -> Int64 {
        await allocated(paths, timeout: timeout).values.reduce(0, +)
    }

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

    public static func hasRecentWrites(_ path: String, within window: TimeInterval) async -> Bool {
        guard exists(path) || isSymlink(path) else { return false }
        let minutes = String(window.isNaN ? 1 : Int(min(max(window / 60, 1), 100 * 365 * 24 * 60)))
        let result = await Shell.run("find", [path, "-mmin", "-\(minutes)", "-print", "-quit"], timeout: 120)
        return !result.ok || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

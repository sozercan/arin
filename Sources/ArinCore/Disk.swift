import Foundation

public struct DiskStatus: Codable, Sendable, Hashable {
    public var totalBytes: Int64
    /// Space that is free right now.
    public var freeBytes: Int64
    /// Free plus purgeable space macOS says it can reclaim on demand.
    public var availableForImportantUsage: Int64

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return 1 - Double(freeBytes) / Double(totalBytes)
    }

    public static let zero = DiskStatus(totalBytes: 0, freeBytes: 0, availableForImportantUsage: 0)
}

public enum Disk {
    public static func status(path: String = NSHomeDirectory()) -> DiskStatus {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .zero }
        return DiskStatus(
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    /// Local APFS snapshots. While one exists, deleted files keep occupying space.
    public static func localSnapshots() async -> [String] {
        var names = Set<String>()
        for volume in ["/", "/System/Volumes/Data"] {
            let result = await Shell.run("tmutil", ["listlocalsnapshots", volume], timeout: 15)
            for line in result.lines where line.hasPrefix("com.apple.") {
                names.insert(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return names.sorted()
    }
}

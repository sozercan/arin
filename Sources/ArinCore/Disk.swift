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

public enum ByteSize {
    /// Parses sizes such as `20GiB`, `20G`, `500MB`, or `1.5 TiB`. `KiB`/`MiB`/`GiB`/`TiB` and the bare
    /// letters are powers of 1024; `KB`/`MB`/`GB`/`TB` are powers of 1000. A plain number is bytes.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)/),
              let number = Double(match.1)
        else { return nil }
        let units: [String: Double] = [
            "": 1, "b": 1,
            "k": 1024, "kib": 1024, "m": 1_048_576, "mib": 1_048_576,
            "g": 1_073_741_824, "gib": 1_073_741_824, "t": 1_099_511_627_776, "tib": 1_099_511_627_776,
            "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
        ]
        guard let unit = units[String(match.2).lowercased()] else { return nil }
        let bytes = number * unit
        guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }
}

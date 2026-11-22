import Foundation

public struct DiskStatus: Codable, Sendable, Hashable {
    public var totalBytes: Int64
    public var freeBytes: Int64
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

public enum LowSpacePolicy {
    public static func rearmMargin(threshold: Int64) -> Int64 { max(2_000_000_000, threshold / 10) }

    public static func evaluate(free: Int64, threshold: Int64, alerted: Bool) -> (notify: Bool, alerted: Bool) {
        if free < threshold { return (!alerted, true) }
        if alerted, free < threshold + rearmMargin(threshold: threshold) { return (false, true) }
        return (false, false)
    }
}

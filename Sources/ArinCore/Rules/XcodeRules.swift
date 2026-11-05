import Foundation

struct DerivedDataRule: Rule {
    let id = "xcode.derived-data"
    let name = "Xcode DerivedData"
    /// Builds touched within this window are treated as active.
    let activeWindow: TimeInterval = 3 * 3600

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let root = ctx.path("Library/Developer/Xcode/DerivedData")
        let entries = FileInfo.children(root)
        guard !entries.isEmpty else { return [] }
        let sizes = await Size.allocated(entries)
        var stale: [String] = []
        var recent: [String] = []
        for entry in entries {
            let activity = FileInfo.recentActivity(entry) ?? .distantPast
            let active = ctx.now.timeIntervalSince(activity) < activeWindow || ctx.state.isBusy(entry)
            if active { recent.append(entry) } else { stale.append(entry) }
        }
        var result: [Candidate] = []
        if !stale.isEmpty {
            result.append(Candidate(
                ruleID: id,
                key: "stale",
                title: "Xcode DerivedData (\(stale.count) idle builds)",
                detail: "Build output and indexes not touched in the last 3 hours. Each project rebuilds from scratch next time.",
                category: .xcode,
                level: .quick,
                risk: .safe,
                bytes: stale.reduce(0) { $0 + (sizes[$1] ?? 0) },
                paths: stale,
                action: .delete(stale),
                lastModified: stale.compactMap(FileInfo.modified).max(),
                blockingProcesses: [],
                minIdleSeconds: activeWindow
            ))
        }
        if !recent.isEmpty {
            result.append(Candidate(
                ruleID: id,
                key: "recent",
                title: "Xcode DerivedData (\(recent.count) recent builds)",
                detail: "Built within the last 3 hours, likely by active work. Deleting forces a full rebuild.",
                category: .xcode,
                level: .standard,
                risk: .review,
                bytes: recent.reduce(0) { $0 + (sizes[$1] ?? 0) },
                paths: recent,
                action: .delete(recent),
                lastModified: recent.compactMap(FileInfo.modified).max(),
                blockers: ["built within the last 3 hours"],
                blockingProcesses: ["xcodebuild"]
            ))
        }
        return result
    }
}

struct SimDevice: Decodable {
    var udid: String
    var name: String
    var state: String
    var isAvailable: Bool
    var dataPath: String?
    var lastUsedAt: String?
}

struct SimDeviceList: Decodable {
    var devices: [String: [SimDevice]]
}

enum Simctl {
    static func devices() async -> [(runtime: String, device: SimDevice)] {
        guard Shell.which("xcrun") != nil else { return [] }
        let result = await Shell.run("xcrun", ["simctl", "list", "devices", "-j"], timeout: 30)
        guard result.ok, let list = try? JSONDecoder().decode(SimDeviceList.self, from: Data(result.stdout.utf8)) else {
            return []
        }
        return list.devices.flatMap { runtime, devices in devices.map { (runtime, $0) } }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2" -> "iOS 27.2"
    static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return tail }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}

struct SimulatorRule: Rule {
    let id = "xcode.simulators"
    let name = "Simulators"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let all = await Simctl.devices()
        guard !all.isEmpty else { return [] }
        var result: [Candidate] = []

        // Devices whose runtime is gone. Xcode leaves them behind after every runtime upgrade.
        let unavailable = all.filter { !$0.device.isAvailable }
        let unavailableDirs = unavailable.compactMap { $0.device.dataPath.map { ($0 as NSString).deletingLastPathComponent } }
        if !unavailable.isEmpty {
            let bytes = await Size.total(unavailableDirs)
            result.append(Candidate(
                ruleID: id,
                key: "unavailable",
                title: "Unavailable simulators (\(unavailable.count))",
                detail: "Simulators for runtimes that are no longer installed. They can't boot, but their data stays on disk. Worth repeating after every Xcode upgrade.",
                category: .xcode,
                level: .quick,
                risk: .safe,
                bytes: bytes,
                paths: unavailableDirs,
                action: .commands([CommandSpec("xcrun", ["simctl", "delete", "unavailable"])])
            ))
        }

        // Data inside working simulators: installed apps, app data, downloaded assets.
        let available = all.filter { $0.device.isAvailable }
        let dataPaths = available.compactMap(\.device.dataPath)
        let sizes = await Size.allocated(dataPaths)
        for (runtime, device) in available {
            guard let dataPath = device.dataPath, let bytes = sizes[dataPath], bytes > 50 * 1024 * 1024 else { continue }
            let booted = device.state != "Shutdown"
            result.append(Candidate(
                ruleID: id,
                key: device.udid,
                title: "Simulator data: \(device.name) (\(Simctl.runtimeName(runtime)))",
                detail: "Erasing resets the simulator to factory state: installed apps and their data are removed, the device itself stays.",
                category: .xcode,
                level: .deep,
                risk: .review,
                bytes: bytes,
                paths: [dataPath],
                action: .commands([CommandSpec("xcrun", ["simctl", "erase", device.udid])]),
                lastModified: FileInfo.modified(dataPath),
                blockers: booted ? ["simulator is booted"] : []
            ))
        }
        return result
    }
}

struct SimRuntime: Decodable {
    var identifier: String
    var version: String?
    var build: String?
    var platformIdentifier: String?
    var deletable: Bool?
    var sizeBytes: Int64?
    var lastUsedAt: String?
    var state: String?
}

struct SimulatorRuntimeRule: Rule {
    let id = "xcode.sim-runtimes"
    let name = "Simulator runtimes"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("xcrun") != nil else { return [] }
        let result = await Shell.run("xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard result.ok,
              let runtimes = try? JSONDecoder().decode([String: SimRuntime].self, from: Data(result.stdout.utf8))
        else { return [] }

        let byPlatform = Dictionary(grouping: runtimes.values) { $0.platformIdentifier ?? "unknown" }
        var candidates: [Candidate] = []
        for (_, group) in byPlatform {
            // Keep the newest runtime per platform; offer older ones and duplicate builds.
            let sorted = group.sorted { Self.isNewer($0, than: $1) }
            for runtime in sorted.dropFirst() where runtime.deletable ?? false {
                let label = "\(Self.platformName(runtime.platformIdentifier)) \(runtime.version ?? "") (\(runtime.build ?? "?"))"
                candidates.append(Candidate(
                    ruleID: id,
                    key: runtime.identifier,
                    title: "Simulator runtime: \(label)",
                    detail: "An older or duplicate runtime; a newer one for this platform is installed. Removed with `simctl runtime delete`. The disk image can stay mounted until the next reboot, so the space may only come back then.",
                    category: .xcode,
                    level: .deep,
                    risk: .review,
                    bytes: runtime.sizeBytes ?? 0,
                    paths: [],
                    action: .commands([CommandSpec("xcrun", ["simctl", "runtime", "delete", runtime.identifier])]),
                    blockingProcesses: ["Simulator"]
                ))
            }
        }
        return candidates
    }

    static func platformName(_ id: String?) -> String {
        switch id {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: id ?? "Unknown"
        }
    }

    static func isNewer(_ a: SimRuntime, than b: SimRuntime) -> Bool {
        let va = (a.version ?? "").split(separator: ".").compactMap { Int($0) }
        let vb = (b.version ?? "").split(separator: ".").compactMap { Int($0) }
        if va != vb { return va.lexicographicallyPrecedes(vb) == false }
        // Same version: a release build (no trailing letter) beats a beta build like 24B91016s.
        let betaA = a.build?.last?.isLetter ?? false
        let betaB = b.build?.last?.isLetter ?? false
        if betaA != betaB { return !betaA }
        return (a.lastUsedAt ?? "") > (b.lastUsedAt ?? "")
    }
}

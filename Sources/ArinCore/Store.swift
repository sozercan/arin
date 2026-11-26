import Foundation

public enum ArinStore {
    public static let releaseBundleID = "com.sertacozercan.Arin"

    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ARIN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let id = Bundle.main.bundleIdentifier.flatMap { $0.hasPrefix(releaseBundleID) ? $0 : nil } ?? releaseBundleID
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(id)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let lockPath = url.path + ".lock"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError("can't open \(lockPath): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError("can't lock \(lockPath): \(String(cString: strerror(errno)))") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static var trashDirectory: String {
        let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        return url.resolvingSymlinksInPath().path
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}


public struct KeepList: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var added: Date
        public var paths: [String]?
        public var remoteHost: String?
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static var defaultURL: URL { ArinStore.directory.appendingPathComponent("keep.json") }

    public func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

    public func keptEntry(insideOrAt target: String, remoteHost: String? = nil) -> Entry? {
        KeptPaths(entries, remoteHost: remoteHost).insideOrAt(target)
    }

    @discardableResult
    public mutating func recordPaths(_ found: [String: [String]], remoteHost: String? = nil) -> Bool {
        var changed = false
        for index in entries.indices {
            guard let paths = found[entries[index].id] else { continue }
            if let remoteHost, entries[index].remoteHost == nil {
                entries[index].remoteHost = remoteHost
                changed = true
            }
            let known = entries[index].paths ?? []
            let added = paths.filter { !known.contains($0) }
            guard !added.isEmpty else { continue }
            entries[index].paths = known + added
            changed = true
        }
        return changed
    }

    static func canonical(_ path: String) -> String {
        var head = (path as NSString).standardizingPath
        var tail: [String] = []
        while head.count > 1 {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(head, &buffer) != nil {
                return ([String(cString: buffer)] + tail.reversed()).joined(separator: "/")
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return path
    }

    public mutating func add(id: String, title: String, paths: [String] = [], remoteHost: String? = nil, now: Date = Date()) {
        guard !contains(id) else { return }
        entries.append(Entry(id: id, title: title, added: now, paths: paths.isEmpty ? nil : paths, remoteHost: remoteHost))
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    public static func load(from url: URL = defaultURL) throws -> KeepList {
        do {
            let data = try Data(contentsOf: url)
            return try ArinStore.decoder.decode(KeepList.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return KeepList()
        } catch {
            throw StoreError("keep list at \((url.path as NSString).abbreviatingWithTildeInPath) can't be read (\(error.localizedDescription)); fix or delete it")
        }
    }

    public static func load(from url: URL = defaultURL, recording found: [String: [String]], remoteHost: String? = nil) -> Result<KeepList, any Error> {
        Result {
            var list = try load(from: url)
            guard list.recordPaths(found, remoteHost: remoteHost) else { return list }
            do {
                return try update(at: url) { $0.recordPaths(found, remoteHost: remoteHost) }
            } catch {
                throw StoreError("the folders that kept items cover couldn't be saved to the keep list (\(error)); nothing can be cleaned until it can be")
            }
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try ArinStore.write(ArinStore.encoder.encode(self), to: url)
    }

    @discardableResult
    public static func update(at url: URL = defaultURL, _ change: (inout KeepList) -> Void) throws -> KeepList {
        try ArinStore.withLock(url) {
            var list = try load(from: url)
            change(&list)
            try list.save(to: url)
            return list
        }
    }

    static let unreadableBlocker = "keep list can't be read"
    static let keptBlockerSuffix = ", which you chose to keep"
}

struct KeptPaths {
    private let items: [(path: String, entry: KeepList.Entry)]
    private let isRemote: Bool

    init(_ entries: [KeepList.Entry], remoteHost: String? = nil, extraRemotePaths: [String: [String]] = [:]) {
        isRemote = remoteHost != nil
        let matching = entries.filter { $0.remoteHost == remoteHost }
        items = matching.flatMap { entry in
            let allPaths = (entry.paths ?? []) + (extraRemotePaths[entry.id] ?? [])
            return allPaths.map { path in
                let normalized = remoteHost != nil ? (path as NSString).standardizingPath : KeepList.canonical(path)
                return (normalized, entry)
            }
        }
    }

    private func normalize(_ target: String) -> String {
        isRemote ? (target as NSString).standardizingPath : KeepList.canonical(target)
    }

    func insideOrAt(_ target: String) -> KeepList.Entry? {
        let target = normalize(target)
        let prefix = target.hasSuffix("/") ? target : target + "/"
        return items.first { $0.path == target || $0.path.hasPrefix(prefix) }?.entry
    }

    func around(_ target: String) -> KeepList.Entry? {
        let target = normalize(target)
        return items.first { target.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }?.entry
    }
}

extension Candidate {
    var keepBlockers: [String] {
        blockers.filter { $0 == KeepList.unreadableBlocker || $0.hasSuffix(KeepList.keptBlockerSuffix) }
    }
}

public extension [Candidate] {
    func applying(keep: Result<KeepList, any Error>, remoteHost: String? = nil) -> [Candidate] {
        let kept = (try? keep.get()).map { KeptPaths($0.entries, remoteHost: remoteHost) }
        return map { candidate in
            var copy = candidate
            let previous = copy.keepBlockers
            copy.blockers.removeAll { previous.contains($0) }
            switch keep {
            case let .success(list):
                copy.kept = list.contains(candidate.id)
                if !copy.kept, let inside = candidate.paths.lazy.compactMap({ kept?.insideOrAt($0) }).first {
                    copy.blockers.append("contains \(inside.title)\(KeepList.keptBlockerSuffix)")
                }
            case .failure:
                copy.blockers.append(KeepList.unreadableBlocker)
            }
            return copy
        }
    }
}


public struct TrashedPath: Codable, Sendable, Hashable {
    public var original: String
    public var location: String

    public var canPutBack: Bool {
        (try? checkLocation()) != nil
            && FileManager.default.fileExists(atPath: location) && !FileManager.default.fileExists(atPath: original)
    }

    func checkLocation(trash: String = ArinStore.trashDirectory) throws {
        let parent = URL(fileURLWithPath: (location as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        let name = (location as NSString).lastPathComponent
        guard parent == trash, !["", ".", ".."].contains(name), !FileInfo.isSymlink(location) else {
            throw StoreError("\((location as NSString).abbreviatingWithTildeInPath) is not an item in the Trash")
        }
    }

    public func putBack(guardrails: Guardrails = Guardrails()) throws {
        do { try guardrails.check(original) } catch { try guardrails.checkUninstall(original) }
        try checkLocation()
        guard FileManager.default.fileExists(atPath: location) else {
            throw StoreError("\((location as NSString).lastPathComponent) is no longer in the Trash")
        }
        guard !FileManager.default.fileExists(atPath: original) else {
            throw StoreError("something already exists at \((original as NSString).abbreviatingWithTildeInPath)")
        }
        try FileManager.default.createDirectory(
            atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        do {
            try FileManager.default.moveItem(atPath: location, toPath: original)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission {
            throw StoreError("macOS didn't let Arin take it out of the Trash. Give Arin Full Disk Access in System Settings → Privacy & Security, or drag \((location as NSString).lastPathComponent) back from the Trash in Finder.")
        }
    }
}

public struct ScanRecord: Codable, Sendable, Hashable {
    public var date: Date
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var bytesByRule: [String: Int64]
    public var labels: [String: String]
    public var remoteHost: String?

    public init(_ report: ScanReport, ruleNames: [String: String] = [:]) {
        date = report.finishedAt
        freeBytes = report.disk.freeBytes
        totalBytes = report.disk.totalBytes
        remoteHost = report.remoteHost
        var bytes: [String: Int64] = [:]
        var titles: [String: [String]] = [:]
        for candidate in report.candidates {
            bytes[candidate.ruleID, default: 0] += candidate.bytes
            titles[candidate.ruleID, default: []].append(candidate.title)
        }
        bytesByRule = bytes
        labels = titles.mapValues { $0.count == 1 ? $0[0] : "" }
        for (rule, label) in labels where label.isEmpty {
            labels[rule] = ruleNames[rule] ?? rule
        }
    }
}

public struct CleanupRecord: Codable, Sendable, Hashable {
    public var date: Date
    public var auto: Bool
    public var freeBefore: Int64
    public var freeAfter: Int64
    public var estimatedBytes: Int64
    public var items: [CleanupItemResult]
    public var uninstalled: String?
    public var remoteHost: String?

    public var measuredBytes: Int64 { freeAfter - freeBefore }

    public init(_ report: CleanupReport, auto: Bool, uninstalled: String? = nil, remoteHost: String? = nil, date: Date = Date()) {
        self.date = date
        self.auto = auto
        self.uninstalled = uninstalled
        self.remoteHost = remoteHost
        freeBefore = report.freeBefore
        freeAfter = report.freeAfter
        estimatedBytes = report.estimatedBytes
        items = report.items
    }
}

public enum HistoryEntry: Codable, Sendable, Hashable {
    case scan(ScanRecord)
    case cleanup(CleanupRecord)

    public var date: Date {
        switch self {
        case let .scan(record): record.date
        case let .cleanup(record): record.date
        }
    }
}

public struct Growth: Sendable, Hashable {
    public var ruleID: String
    public var label: String
    public var bytes: Int64
}

public struct History: Sendable {
    public var url: URL
    public var maxBytes: Int

    public init(url: URL = ArinStore.directory.appendingPathComponent("history.jsonl"), maxBytes: Int = 4 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func append(_ entry: HistoryEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try ArinStore.withLock(url) {
            if let handle = try? FileHandle(forUpdating: url) {
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
            try trimIfNeeded()
        }
    }

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = ArinStore.decoder
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
    }

    func trimIfNeeded() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        var kept = Data()
        for line in lines.suffix(lines.count / 2) {
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        try kept.write(to: url, options: .atomic)
    }

    public static func scans(_ entries: [HistoryEntry]) -> [ScanRecord] {
        entries.compactMap { if case let .scan(record) = $0 { record } else { nil } }
    }

    public static func cleanups(_ entries: [HistoryEntry]) -> [CleanupRecord] {
        entries.compactMap { if case let .cleanup(record) = $0 { record } else { nil } }
    }

    public static func growth(from previous: ScanRecord, to current: ScanRecord, minimum: Int64 = 256 * 1024 * 1024) -> [Growth] {
        current.bytesByRule.compactMap { rule, bytes in
            let delta = bytes - (previous.bytesByRule[rule] ?? 0)
            guard delta >= minimum else { return nil }
            return Growth(ruleID: rule, label: current.labels[rule] ?? rule, bytes: delta)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}


public struct CleanupPlan: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var bytes: Int64
        public var risk: Risk
        public var action: CleanupAction
        public var paths: [String]
    }

    public var version: Int
    public var createdAt: Date
    public var remoteHost: String?
    public var remoteIdentity: String?
    public var items: [Item]

    public init(_ candidates: [Candidate], remoteHost: String? = nil, remoteIdentity: String? = nil, now: Date = Date()) {
        version = 1
        createdAt = now
        self.remoteHost = remoteHost
        self.remoteIdentity = remoteIdentity
        items = candidates.map {
            Item(id: $0.id, title: $0.title, bytes: $0.bytes, risk: $0.effectiveRisk, action: $0.action, paths: $0.paths)
        }
    }

    public static func load(from url: URL) throws -> CleanupPlan {
        try load(fromData: Data(contentsOf: url))
    }

    public static func load(fromData data: Data) throws -> CleanupPlan {
        let plan = try ArinStore.decoder.decode(CleanupPlan.self, from: data)
        guard plan.version == 1 else { throw StoreError("unsupported plan version \(plan.version)") }
        return plan
    }

    public func encoded() throws -> Data { try ArinStore.encoder.encode(self) }

    public func resolve(against candidates: [Candidate]) -> (ready: [Candidate], refused: [(item: Item, reason: String)]) {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ready: [Candidate] = []
        var refused: [(Item, String)] = []
        for item in items {
            guard let current = byID[item.id] else {
                refused.append((item, "no longer found"))
                continue
            }
            if current.kept {
                refused.append((item, "on your keep list"))
            } else if current.action != item.action {
                refused.append((item, "its action changed since the plan was made; make a new plan"))
            } else if Set(current.paths) != Set(item.paths) {
                refused.append((item, "its folders changed since the plan was made; make a new plan"))
            } else if current.effectiveRisk > item.risk {
                refused.append((item, "now marked \(current.effectiveRisk.label)"))
            } else if !current.blockers.isEmpty {
                refused.append((item, current.blockers.joined(separator: "; ")))
            } else {
                ready.append(current)
            }
        }
        return (ready, refused)
    }
}

import Foundation

/// Where Arin keeps its own state: the keep list and the history. The app and the CLI share it.
public enum ArinStore {
    public static let releaseBundleID = "com.sertacozercan.Arin"

    /// `~/Library/Application Support/<bundle ID>`. Debug app builds get their own folder, like their
    /// settings. `ARIN_SUPPORT_DIR` overrides it for tests and scripted runs.
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

    /// Runs `body` while holding an exclusive lock shared by every Arin process (app and CLI),
    /// so read-modify-write updates and appends from both can't interleave.
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

    /// The Trash that `FileManager.trashItem` uses for items in the home folder and temp folders.
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

// MARK: - Keep list

/// Items the user never wants cleaned, by candidate ID.
public struct KeepList: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var added: Date
        /// What the item covered when it was kept. A cleanup whose target contains one of these is
        /// refused too, so removing a worktree can't take a kept `node_modules` with it.
        public var paths: [String]?
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static var defaultURL: URL { ArinStore.directory.appendingPathComponent("keep.json") }

    public func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

    /// The first kept item that deleting `target` would take with it.
    public func keptEntry(insideOrAt target: String) -> Entry? {
        KeptPaths(entries).insideOrAt(target)
    }

    /// Records where kept items are now, from a scan. Entries added by ID alone (the CLI, logical
    /// IDs like `go.build-cache:go.build-cache`) get the paths they cover, so a parent's cleanup
    /// can't take them along. Returns whether anything changed.
    @discardableResult
    public mutating func recordPaths(_ found: [String: [String]]) -> Bool {
        var changed = false
        for index in entries.indices {
            guard let paths = found[entries[index].id] else { continue }
            let known = entries[index].paths ?? []
            let added = paths.filter { !known.contains($0) }
            guard !added.isEmpty else { continue }
            entries[index].paths = known + added
            changed = true
        }
        return changed
    }

    /// `path` with symlinks resolved and each name spelled as it is on disk, so a case change or
    /// a symlinked folder can't hide a kept path. Resolves the longest part that exists.
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

    public mutating func add(id: String, title: String, paths: [String] = [], now: Date = Date()) {
        guard !contains(id) else { return }
        entries.append(Entry(id: id, title: title, added: now, paths: paths.isEmpty ? nil : paths))
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// A missing file is an empty list. A file that exists but can't be read or parsed throws:
    /// cleaning without the user's protections would be worse than not cleaning.
    public static func load(from url: URL = defaultURL) throws -> KeepList {
        do {
            let data = try Data(contentsOf: url)
            return try ArinStore.decoder.decode(KeepList.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only a file that is really absent counts as an empty list; a folder that can't be
            // searched reports a permission error instead, which blocks cleaning below.
            return KeepList()
        } catch {
            throw StoreError("keep list at \((url.path as NSString).abbreviatingWithTildeInPath) can't be read (\(error.localizedDescription)); fix or delete it")
        }
    }

    /// Loads the list and saves the paths `found` for kept IDs (see `recordPaths`). Fails if they
    /// can't be saved: the executor re-reads the file, so protections held only in memory wouldn't
    /// reach it.
    public static func load(from url: URL = defaultURL, recording found: [String: [String]]) -> Result<KeepList, any Error> {
        Result {
            var list = try load(from: url)
            guard list.recordPaths(found) else { return list }
            do {
                return try update(at: url) { $0.recordPaths(found) }
            } catch {
                throw StoreError("the folders that kept items cover couldn't be saved to the keep list (\(error)); nothing can be cleaned until it can be")
            }
        }
    }

    public func save(to url: URL = defaultURL) throws {
        try ArinStore.write(ArinStore.encoder.encode(self), to: url)
    }

    /// Loads, changes and saves the list under the shared lock, so the app and the CLI can't
    /// drop each other's additions.
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

/// Kept paths resolved once, for matching many targets.
struct KeptPaths {
    private let items: [(path: String, entry: KeepList.Entry)]

    init(_ entries: [KeepList.Entry]) {
        items = entries.flatMap { entry in (entry.paths ?? []).map { (KeepList.canonical($0), entry) } }
    }

    /// The kept item at `target` or inside it, compared by real path. A target that is a symlink
    /// resolves too, which refuses more than deleting the link would need; that errs safe.
    func insideOrAt(_ target: String) -> KeepList.Entry? {
        let target = KeepList.canonical(target)
        let prefix = target.hasSuffix("/") ? target : target + "/"
        return items.first { $0.path == target || $0.path.hasPrefix(prefix) }?.entry
    }
}

extension Candidate {
    /// Blockers the keep list added. Unlike the others, nothing overrides these.
    var keepBlockers: [String] {
        blockers.filter { $0 == KeepList.unreadableBlocker || $0.hasSuffix(KeepList.keptBlockerSuffix) }
    }
}

public extension [Candidate] {
    /// Marks kept items. If the list couldn't be read, nothing may be pre-selected.
    /// Safe to call again on the same candidates: blockers it added before are replaced.
    func applying(keep: Result<KeepList, any Error>) -> [Candidate] {
        let kept = (try? keep.get()).map { KeptPaths($0.entries) }
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

// MARK: - History

/// A file the executor moved to the Trash, and where it went.
public struct TrashedPath: Codable, Sendable, Hashable {
    public var original: String
    public var location: String

    /// Still in the Trash, and nothing has taken its old place.
    public var canPutBack: Bool {
        (try? checkLocation()) != nil
            && FileManager.default.fileExists(atPath: location) && !FileManager.default.fileExists(atPath: original)
    }

    /// The history file is ordinary user-writable data, so a record can't be trusted to name a
    /// Trash item: the source must sit directly in the Trash and not be a symlink.
    func checkLocation(trash: String = ArinStore.trashDirectory) throws {
        let parent = URL(fileURLWithPath: (location as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        let name = (location as NSString).lastPathComponent
        guard parent == trash, !["", ".", ".."].contains(name), !FileInfo.isSymlink(location) else {
            throw StoreError("\((location as NSString).abbreviatingWithTildeInPath) is not an item in the Trash")
        }
    }

    /// Moves the item back to where it was.
    public func putBack(guardrails: Guardrails = Guardrails()) throws {
        try guardrails.check(original)
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
            // Reading the Trash is privacy-protected.
            throw StoreError("macOS didn't let Arin take it out of the Trash. Give Arin Full Disk Access in System Settings → Privacy & Security, or drag \((location as NSString).lastPathComponent) back from the Trash in Finder.")
        }
    }
}

/// What one scan found, by rule, so growth between scans can be shown.
public struct ScanRecord: Codable, Sendable, Hashable {
    public var date: Date
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var bytesByRule: [String: Int64]
    public var labels: [String: String]

    public init(_ report: ScanReport, ruleNames: [String: String] = [:]) {
        date = report.finishedAt
        freeBytes = report.disk.freeBytes
        totalBytes = report.disk.totalBytes
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

    public var measuredBytes: Int64 { freeAfter - freeBefore }

    public init(_ report: CleanupReport, auto: Bool, date: Date = Date()) {
        self.date = date
        self.auto = auto
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

/// How much one rule's findings grew between two scans.
public struct Growth: Sendable, Hashable {
    public var ruleID: String
    public var label: String
    public var bytes: Int64
}

/// An append-only log of scans and cleanups, one JSON object per line.
public struct History: Sendable {
    public var url: URL
    /// Past this size the oldest half is dropped.
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
                    // A torn earlier write leaves no newline; start a fresh line so this record survives.
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

    /// Oldest first. Lines that don't parse (a newer format, a torn write) are skipped.
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

    /// Rules whose findings grew by at least `minimum` from `previous` to `current`, largest first.
    public static func growth(from previous: ScanRecord, to current: ScanRecord, minimum: Int64 = 256 * 1024 * 1024) -> [Growth] {
        current.bytesByRule.compactMap { rule, bytes in
            let delta = bytes - (previous.bytesByRule[rule] ?? 0)
            guard delta >= minimum else { return nil }
            return Growth(ruleID: rule, label: current.labels[rule] ?? rule, bytes: delta)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - Saved plans

/// A reviewed list of candidates to clean later, by ID. Running a plan rescans first and cleans
/// only items whose action is unchanged and which have not become more cautious.
public struct CleanupPlan: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var bytes: Int64
        public var risk: Risk
        public var action: CleanupAction
        /// What the item covered when it was reviewed. A native command can keep its arguments
        /// while its target moves (a changed npm cache folder), so this is compared too.
        public var paths: [String]
    }

    public var version: Int
    public var createdAt: Date
    public var items: [Item]

    public init(_ candidates: [Candidate], now: Date = Date()) {
        version = 1
        createdAt = now
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

    /// Splits the plan into fresh candidates that may run and items refused with a reason.
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

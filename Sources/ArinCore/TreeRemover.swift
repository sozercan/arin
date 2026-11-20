import Darwin
import Foundation

/// An entry a delete couldn't remove, with what the user can do about it.
public struct LeftBehind: Codable, Sendable, Hashable {
    public var path: String
    public var errno: Int32
    public var advice: String
}

/// What a delete did. Sizes are allocated blocks and only describe the attempt; the cleanup result
/// is the measured change in free space.
public struct TreeRemoval: Sendable {
    public var removedEntries = 0
    public var removedBytes: Int64 = 0
    /// The deepest cause of each failure (a folder kept because a child failed isn't listed again),
    /// capped at `TreeRemover.maxReported`. `leftCount` is the full count.
    public var leftBehind: [LeftBehind] = []
    public var leftCount = 0
    public var leftBytes: Int64 = 0
    /// Folders left without being read, so the size of what's left is unknown.
    public var unreadFolders = 0

    public var isComplete: Bool { leftCount == 0 }

    mutating func record(_ path: String, _ code: Int32, bytes: Int64 = 0, advice: String? = nil) {
        leftCount += 1
        leftBytes += bytes
        guard leftBehind.count < TreeRemover.maxReported else { return }
        leftBehind.append(LeftBehind(path: path, errno: code, advice: advice ?? RemovalAdvice.advice(path: path, errno: code)))
    }

    mutating func merge(_ other: TreeRemoval) {
        removedEntries += other.removedEntries
        removedBytes += other.removedBytes
        leftCount += other.leftCount
        leftBytes += other.leftBytes
        unreadFolders += other.unreadFolders
        leftBehind += other.leftBehind.prefix(max(0, TreeRemover.maxReported - leftBehind.count))
    }

    /// "what was left: why", one line per distinct reason.
    public var problems: String {
        var reasons: [String] = []
        for entry in leftBehind where !reasons.contains(entry.advice) { reasons.append(entry.advice) }
        let first = leftBehind.first.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "?"
        let what = leftCount == 1 ? first : "\(leftCount) entries (e.g. \(first))"
        return "\(what): \(reasons.prefix(3).joined(separator: "; "))"
    }
}

/// Deletes a file, link or folder entry by entry and carries on past anything it can't remove.
///
/// - Symlinks are never followed: folders are opened relative to their parent with `O_NOFOLLOW` and
///   entries are removed with `unlinkat`, so a link is removed as a link.
/// - It never deletes into another volume, including one mounted after the guardrails checked the path.
/// - Read-only folders the user owns (Go module caches, envtest binaries) are made writable just
///   before they're emptied, through the descriptor that was checked to be on the same volume.
///   Files aren't: removing a file only needs its folder to be writable. A folder that can't be
///   opened at all is left alone, since nothing could pin what a chmod by name would change.
/// - A folder that a running process refills while it's being emptied is emptied again before it's
///   reported.
public enum TreeRemover {
    public static let maxReported = 20
    static let refillRetries = 2
    static let maxDepth = 512
    /// Each level holds a folder open and a few KB of stack; the thread gets room for `maxDepth`.
    static let stackSize = 32 << 20

    public static func remove(_ path: String) async -> TreeRemoval {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: removeSync(path)) }
            thread.stackSize = stackSize
            thread.start()
        }
    }

    static func removeSync(_ path: String) -> TreeRemoval {
        var r = TreeRemoval()
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            r.record(path, EINVAL)
            return r
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno != ENOENT { r.record(path, errno) }
            return r
        }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            if unlink(path) == 0 || errno == ENOENT {
                r.removedEntries += 1
                r.removedBytes += allocated(st)
            } else {
                r.record(path, errno, bytes: allocated(st))
            }
            return r
        }
        let parent = (path as NSString).deletingLastPathComponent
        let pfd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard pfd >= 0 else {
            r.record(path, errno)
            return r
        }
        defer { close(pfd) }
        var pst = stat()
        guard fstat(pfd, &pst) == 0, pst.st_dev == st.st_dev else {
            r.record(path, EXDEV)  // the item itself is a mount point
            return r
        }
        let name = Array((path as NSString).lastPathComponent.utf8CString)
        _ = removeDirectory(parent: pfd, name: name, path: path, device: st.st_dev, depth: 0, into: &r)
        return r
    }

    /// Empties and removes the folder `name` inside `parent`. True when nothing was left behind.
    private static func removeDirectory(parent: Int32, name: [CChar], path: String, device: dev_t, depth: Int,
                                        into r: inout TreeRemoval) -> Bool {
        for attempt in 0...refillRetries {
            guard clearContents(parent: parent, name: name, path: path, device: device, depth: depth, into: &r) else {
                return false
            }
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
                r.removedEntries += 1
                return true
            }
            let code = errno
            if code == ENOENT { return true }
            if code == ENOTEMPTY, attempt < refillRetries { continue }
            r.record(path, code)
            return false
        }
        return false
    }

    /// Removes everything inside the folder. True when nothing was left behind.
    private static func clearContents(parent: Int32, name: [CChar], path: String, device: dev_t, depth: Int,
                                      into r: inout TreeRemoval) -> Bool {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return true }
            r.record(path, code)
            r.unreadFolders += 1
            return false
        }
        var dst = stat()
        guard fstat(fd, &dst) == 0, dst.st_dev == device else {
            close(fd)
            r.record(path, EXDEV)
            return false
        }
        // Entries can only be unlinked from a folder that is writable and searchable.
        if dst.st_uid == getuid(), dst.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmod(fd, (dst.st_mode & 0o7777) | S_IRWXU)
        }
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            r.record(path, code)
            r.unreadFolders += 1
            return false
        }
        defer { closedir(dir) }
        let dfd = dirfd(dir)

        // Byte-exact names, whatever their encoding.
        var names: [[CChar]] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)).map { CChar(bitPattern: $0) } }
            if bytes == [46] || bytes == [46, 46] { continue }
            names.append(bytes + [0])
        }

        var ok = true
        for child in names {
            let display = path + "/" + String(decoding: child.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
            var cst = stat()
            guard fstatat(dfd, child, &cst, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { r.record(display, errno); ok = false }
                continue
            }
            if cst.st_mode & S_IFMT == S_IFDIR {
                if cst.st_dev != device {
                    r.record(display, EXDEV)
                    ok = false
                } else if depth + 1 > maxDepth {
                    r.record(display, ELOOP)
                    r.unreadFolders += 1
                    ok = false
                } else if !removeDirectory(parent: dfd, name: child, path: display, device: device, depth: depth + 1, into: &r) {
                    ok = false
                }
            } else if unlinkat(dfd, child, 0) == 0 {
                r.removedEntries += 1
                r.removedBytes += allocated(cst)
            } else if errno != ENOENT {
                r.record(display, errno, bytes: allocated(cst))
                ok = false
            }
        }
        return ok
    }

    private static func allocated(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }
}

/// Turns a failed removal into something the user can act on.
public enum RemovalAdvice {
    public static func advice(path: String, errno code: Int32) -> String {
        switch code {
        case ENOTEMPTY:
            let who = holders(under: path)
            return who.isEmpty
                ? "kept being refilled while it was deleted; quit the app that writes there and try again"
                : "kept being refilled by \(who.joined(separator: ", ")); quit it and try again"
        case EBUSY, ETXTBSY:
            let who = holders(under: path)
            return "in use\(who.isEmpty ? "" : " by \(who.joined(separator: ", "))"); quit it and try again"
        case EXDEV:
            return "a volume is mounted here; eject it first (Arin never deletes across volumes)"
        case EROFS:
            return "on a read-only volume"
        case ELOOP:
            return "nested more than \(TreeRemover.maxDepth) folders deep; Arin stops there"
        case EINVAL:
            return "refused: not a plain absolute path"
        case EPERM, EACCES:
            return permissionAdvice(path)
        default:
            return String(cString: strerror(code))
        }
    }

    /// Advice for an error Foundation threw (a move to the Trash), from its POSIX cause when it has one.
    public static func advice(for error: any Error, path: String) -> String {
        let ns = error as NSError
        var code: Int32?
        if ns.domain == NSPOSIXErrorDomain { code = Int32(ns.code) }
        if code == nil, let inner = ns.userInfo[NSUnderlyingErrorKey] as? NSError, inner.domain == NSPOSIXErrorDomain {
            code = Int32(inner.code)
        }
        return code.map { advice(path: path, errno: $0) } ?? ns.localizedDescription
    }

    static func permissionAdvice(_ path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let uid = getuid()
        var st = stat()
        if lstat(path, &st) == 0 {
            if st.st_flags & UInt32(SF_RESTRICTED) != 0 { return "protected by System Integrity Protection; leave it" }
            if st.st_flags & UInt32(SF_IMMUTABLE | SF_APPEND) != 0 {
                return "locked by the system (schg flag); Arin never uses admin rights, so it stays"
            }
            if st.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                return "locked in Finder (uchg flag); unlock it with `chflags -R nouchg \(quoted)` and try again"
            }
            if st.st_uid != uid {
                return "owned by \(userName(st.st_uid)); Arin never uses admin rights, so it stays"
            }
        }
        let parent = (path as NSString).deletingLastPathComponent
        var pst = stat()
        if lstat(parent, &pst) == 0 {
            if pst.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                return "its folder is locked in Finder (uchg flag); unlock it and try again"
            }
            if pst.st_uid != uid { return "its folder is owned by \(userName(pst.st_uid)); Arin never uses admin rights, so it stays" }
            if access(parent, W_OK) != 0 { return "its folder is read-only" }
        }
        if st.st_mode & S_IFMT == S_IFDIR, st.st_uid == uid, access(path, R_OK | X_OK) != 0 {
            return "you can't read this folder; run `chmod -R u+rwx \(quoted)` and try again"
        }
        return "macOS blocked access; give Arin Full Disk Access in System Settings › Privacy & Security, then try again"
    }

    /// Names of processes with files open at or just below `path` (a bounded look).
    static func holders(under path: String, limit: Int = 32) -> [String] {
        var files = [path]
        if let walker = FileManager.default.enumerator(atPath: path) {
            while files.count < limit, let rel = walker.nextObject() as? String { files.append(path + "/" + rel) }
        }
        var seen = Set<pid_t>()
        var names: [String] = []
        for file in files {
            let flags = UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
            let size = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file, flags, nil, 0)
            guard size > 0 else { continue }
            var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 8)
            let got = pids.withUnsafeMutableBytes {
                proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file, flags, $0.baseAddress, Int32($0.count))
            }
            guard got > 0 else { continue }
            for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 && seen.insert(pid).inserted {
                var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
                let exe = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
                let name = exe.isEmpty ? "process \(pid)" : (exe as NSString).lastPathComponent
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private static func userName(_ uid: uid_t) -> String {
        if uid == 0 { return "root" }
        if let entry = getpwuid(uid) { return String(cString: entry.pointee.pw_name) }
        return "user \(uid)"
    }
}

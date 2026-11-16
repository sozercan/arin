import Darwin
import Foundation

/// What deleting a folder would free, as well as the file system can say. `du` counts every block a
/// file uses, but on APFS a clone shares its blocks with other files, so deleting it frees only the
/// blocks nothing else uses. APFS reports those per file as its private size.
///
/// A folder's size is the sum of its files' private sizes, plus the blocks a family of clones shares
/// when every clone in the family is inside the folder (deleting all of them frees those blocks too).
/// A hard-linked file counts once, and only when all its links are inside: a link left elsewhere keeps
/// its data. Compressed files, and volumes that don't report a private size,
/// use allocated blocks. Snapshots and clones changed after they were made can still keep blocks, so
/// the measured change in free space stays the reported result.
enum DiskUsage {
    /// Bytes for `path`, or nil when the walk didn't finish before `deadline` or was cancelled.
    static func measure(_ path: String, deadline: Date, cancelled: CancelFlag) -> Int64? {
        guard let root = strdup(path) else { return nil }
        defer { free(root) }
        var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        var tally = Tally()
        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited % 2048 == 0, cancelled.isSet || Date() > deadline { return nil }
            let info = Int32(entry.pointee.fts_info)
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            switch info {
            case FTS_F:
                tally.add(file(entry.pointee.fts_accpath, stat: stat))
            case FTS_D, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                tally.add(FileSize(stat: stat))
            default:
                // FTS_DP (a directory again, after its contents), unreadable entries: nothing to add.
                continue
            }
        }
        return tally.sum
    }

    struct FileSize {
        var bytes: Int64
        var device: UInt64
        var inode: UInt64
        /// Hard links to the file, 1 when it has no others.
        var links: UInt32
        /// Clone family and how many files are in it; nil when the file shares no blocks.
        var family: Family?
        var clones: UInt32 = 0
        var shared: Int64 = 0

        init(stat: stat) {
            bytes = Int64(stat.st_blocks) * 512
            device = UInt64(bitPattern: Int64(stat.st_dev))
            inode = UInt64(stat.st_ino)
            links = (stat.st_mode & S_IFMT) == S_IFDIR ? 1 : UInt32(stat.st_nlink)
        }
    }

    struct Family: Hashable {
        var device: UInt64
        var id: UInt64
    }

    struct Tally {
        var total: Int64 = 0
        /// Hard-linked files by device and inode, with how many of their links were found.
        var linked: [[UInt64]: UInt32] = [:]
        var families: [Family: (found: UInt32, clones: UInt32, shared: Int64)] = [:]

        mutating func add(_ file: FileSize) {
            if file.links > 1 {
                let key = [file.device, file.inode]
                let found = (linked[key] ?? 0) + 1
                linked[key] = found
                guard found == file.links else { return }
            }
            total += file.bytes
            guard let family = file.family, file.clones > 1, file.shared > 0 else { return }
            var entry = families[family] ?? (0, file.clones, 0)
            entry.found += 1
            entry.shared = max(entry.shared, file.shared)
            families[family] = entry
        }

        var sum: Int64 {
            total + families.values.reduce(0) { $0 + ($1.found >= $1.clones ? $1.shared : 0) }
        }
    }

    // getattrlist(2) constants from <sys/attr.h>.
    private static let attrBitMapCount: UInt16 = 5
    private static let commonRequested: UInt32 = 0x8000_0000 /* RETURNED_ATTRS */ | 0x0000_0002 /* DEVID */
        | 0x0000_0008 /* OBJTYPE */ | 0x0004_0000 /* FLAGS */ | 0x0200_0000 /* FILEID */
    private static let commonRequired: UInt32 = 0x0000_0002 | 0x0000_0008 | 0x0200_0000
    private static let fileRequested: UInt32 = 0x0000_0001 /* LINKCOUNT */ | 0x0000_0004 /* ALLOCSIZE */
    private static let privateSize: UInt32 = 0x0000_0008 // ATTR_CMNEXT_PRIVATESIZE
    private static let cloneID: UInt32 = 0x0000_0100 // ATTR_CMNEXT_CLONEID
    private static let cloneRefCount: UInt32 = 0x0000_1000 // ATTR_CMNEXT_CLONE_REFCNT
    private static let options = UInt32(0x0000_0001 /* NOFOLLOW */ | 0x0000_0008 /* PACK_INVAL_ATTRS */ | 0x0000_0020 /* ATTR_CMN_EXTENDED */)
    private static let regularFile: UInt32 = 1 // VREG
    private static let compressed: UInt32 = 0x20 // UF_COMPRESSED

    /// A regular file's private size and clone family, falling back to its allocated blocks.
    static func file(_ path: UnsafeMutablePointer<CChar>, stat: stat) -> FileSize {
        var size = FileSize(stat: stat)
        var request = attrlist()
        request.bitmapcount = attrBitMapCount
        request.commonattr = commonRequested
        request.fileattr = fileRequested
        request.forkattr = privateSize | cloneID | cloneRefCount
        var buffer = [UInt8](repeating: 0, count: 128)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard status == 0 else { return size }
        return buffer.withUnsafeBytes { raw -> FileSize in
            func u32(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func u64(_ offset: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            guard Int(u32(0)) <= raw.count else { return size }
            // After the length: the returned attribute_set_t (common, vol, dir, file, fork), then the
            // values in bit order, each 4-byte aligned.
            let common = u32(4), file = u32(16), fork = u32(20)
            guard common & commonRequired == commonRequired, file & fileRequested == fileRequested else { return size }
            let values = 24
            let objectType = u32(values + 4)
            let flags = common & 0x0004_0000 != 0 ? u32(values + 8) : 0
            let fileID = u64(values + 12)
            let links = u32(values + 20)
            let allocated = Int64(bitPattern: u64(values + 24))
            let privateBytes = Int64(bitPattern: u64(values + 32))
            let family = u64(values + 40)
            let clones = u32(values + 48)
            guard objectType == regularFile, allocated >= 0 else { return size }
            size.inode = fileID
            size.links = max(links, 1)
            size.bytes = allocated
            // APFS leaves a compressed file's data out of its private size.
            guard fork & privateSize != 0, flags & compressed == 0, privateBytes >= 0, privateBytes <= allocated else {
                return size
            }
            size.bytes = privateBytes
            if fork & cloneID != 0, fork & cloneRefCount != 0, clones > 1 {
                size.family = Family(device: size.device, id: family)
                size.clones = clones
                size.shared = allocated - privateBytes
            }
            return size
        }
    }
}

/// Lets a cancelled task stop a walk running on a dispatch queue.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

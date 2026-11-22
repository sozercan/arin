# 0003: Distinguish reclaimable estimates from measured gains

**Status:** Accepted

## Context

`du` counts shared APFS blocks in each clone's size, and snapshots can retain blocks after all visible files are removed. A nominal size, purgeable capacity, or a tool's exit status is not proof that space was freed.

## Decision

- Estimate per-file private blocks on APFS and count shared clone blocks only when the whole family is inside the candidate. Count hard-linked data once and only if all links are inside. Use allocated blocks when private size is unavailable or the file is compressed: APFS excludes the data of compressed files from private size. Form the actual result from the change in free space, not the estimate or purgeable capacity.
- `DiskUsage.file` reads `getattrlist(2)` in packed-invalid-attributes mode. The length precedes five returned masks, then values in bit order on 4-byte boundaries. Keep the read offsets in sync with requested masks and this SDK mapping:

  | Field | Darwin attributes or flags |
  | --- | --- |
  | Common | `ATTR_CMN_RETURNED_ATTRS`, `ATTR_CMN_DEVID`, `ATTR_CMN_OBJTYPE`, `ATTR_CMN_FLAGS`, `ATTR_CMN_FILEID` |
  | File | `ATTR_FILE_LINKCOUNT`, `ATTR_FILE_ALLOCSIZE` |
  | Extended | `ATTR_CMNEXT_PRIVATESIZE`, `ATTR_CMNEXT_CLONEID`, `ATTR_CMNEXT_CLONE_REFCNT` |
  | Options | `FSOPT_NOFOLLOW`, `FSOPT_PACK_INVAL_ATTRS`, `FSOPT_ATTR_CMN_EXTENDED` |
  | Type and compression | `VREG`, `UF_COMPRESSED` |

- Report partial removals with causes. Size what remains using the same accounting so a retry doesn't count freed bytes again. Only `ENOENT` is evidence that an unmeasured path is gone. An unread or unmeasured remainder that the executor detects is unknown, not an estimate of zero bytes left. A native command can exit nonzero after removing much of its target, so inspect what is left as well as the exit status.
- Alert once per drop below the threshold; re-arm only above a recovery margin so hovering around the threshold does not spam alerts. Bare size suffixes (`K`, `M`, `G`, `T`) and IEC units use base 1024, SI units use base 1000, and bare numbers are bytes. CLI hook mode reports problems to stderr without failing the caller. Report staged update snapshots rather than offering to delete them. Offer local Time Machine snapshots separately, one date at a time, because their individual reclaimable sizes are not known in advance.

## Consequences

APFS snapshots, changes to clones, compression, and unrelated disk activity can still make results diverge from estimates. Explain the difference instead of substituting one number for the other. See [cleanup learnings](../learnings.md) for observed examples.

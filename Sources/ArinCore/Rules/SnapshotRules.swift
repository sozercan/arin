import Foundation

/// Local Time Machine snapshots, deleted one by one with `tmutil deletelocalsnapshots <date>`.
/// macOS update snapshots are never offered: they must go through the update itself.
struct TimeMachineSnapshotRule: Rule {
    let id = "snapshots.time-machine"
    let name = "Time Machine local snapshots"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        let dates = Self.dates(await Disk.localSnapshots())
        guard !dates.isEmpty else { return [] }
        return [Candidate(
            ruleID: id,
            key: id,
            title: "Time Machine local snapshots (\(dates.count))",
            detail: "Copies Time Machine keeps on this disk between backups. Deleted files keep using space while a snapshot references them. Backups on your backup disk are not affected. The space they hold can't be measured beforehand; Arin reports the change in free space afterward.",
            category: .snapshots,
            level: .deep,
            risk: .review,
            bytes: 0,
            paths: [],
            action: .commands(dates.map { CommandSpec("tmutil", ["deletelocalsnapshots", $0]) })
        )]
    }

    /// `com.apple.TimeMachine.2026-11-08-101500.local` -> `2026-11-08-101500`. Anything else is skipped.
    static func dates(_ snapshots: [String]) -> [String] {
        snapshots.compactMap { name in
            name.wholeMatch(of: /com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})\.local/).map { String($0.1) }
        }
    }
}

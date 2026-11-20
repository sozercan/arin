@testable import ArinCore
import Darwin
import Foundation
import Testing

private func candidate(_ path: String, bytes: Int64 = 1) -> Candidate {
    Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
              bytes: bytes, paths: [path], action: .delete([path]))
}

private func unlock(_ box: Sandbox) {
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/chflags"), arguments: ["-R", "nouchg", box.root]).waitUntilExit()
}

@Suite struct TreeRemoverTests {
    @Test func neverFollowsSymlinksInsideTheTree() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let outside = try box.write("projects/real/keep.txt")
        _ = try box.write("Library/Caches/tool/a/file")
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/Library/Caches/tool/a/link",
                                                   withDestinationPath: "\(box.root)/projects/real")
        let removal = await TreeRemover.remove("\(box.root)/Library/Caches/tool")
        #expect(removal.isComplete)
        #expect(!FileInfo.exists("\(box.root)/Library/Caches/tool"))
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test func refusesRelativeAndDottedPaths() async {
        #expect(await TreeRemover.remove("relative/path").leftBehind.first?.errno == EINVAL)
        #expect(await TreeRemover.remove("/tmp/a/../b").leftBehind.first?.errno == EINVAL)
    }

    @Test func missingPathIsNothingToDo() async {
        let removal = await TreeRemover.remove("/private/tmp/arin-missing-\(UUID().uuidString)")
        #expect(removal.isComplete)
        #expect(removal.removedEntries == 0)
    }

    @Test func handlesUnreadableFoldersTheUserOwns() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let locked = try box.mkdir("Library/Caches/tool/locked")
        _ = try box.write("Library/Caches/tool/locked/inner/file")
        #expect(chmod(locked, 0o000) == 0)
        let removal = await TreeRemover.remove("\(box.root)/Library/Caches/tool")
        #expect(removal.isComplete, "\(removal.problems)")
        #expect(!FileInfo.exists("\(box.root)/Library/Caches/tool"))
    }

    @Test func lockedFilesLeaveAPartialResultWithAdvice() async throws {
        let box = try Sandbox()
        defer { unlock(box); box.cleanup() }
        let target = try box.mkdir("Library/Caches/tool")
        _ = try box.write("Library/Caches/tool/a")
        _ = try box.write("Library/Caches/tool/b")
        let locked = try box.write("Library/Caches/tool/locked")
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)

        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(target, bytes: 1000), state: .empty)
        #expect(item.status == .partial)
        #expect(item.message.contains("uchg"), "\(item.message)")
        #expect(FileManager.default.fileExists(atPath: locked))
        #expect(!FileManager.default.fileExists(atPath: "\(target)/a"))
    }

    @Test func nothingRemovedIsAFailure() async throws {
        let box = try Sandbox()
        defer { unlock(box); box.cleanup() }
        let locked = try box.write("Library/Caches/locked.bin")
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(locked), state: .empty)
        #expect(item.status == .failed)
        #expect(item.estimatedBytes == 0)
    }

    @Test func adviceNamesTheCause() {
        #expect(RemovalAdvice.advice(path: "/x", errno: EXDEV).contains("mounted"))
        #expect(RemovalAdvice.advice(path: "/x", errno: ENOTEMPTY).contains("refilled"))
        #expect(RemovalAdvice.advice(path: "/x", errno: EROFS).contains("read-only"))
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))])
        #expect(RemovalAdvice.advice(for: error, path: "/x").contains("mounted"))
    }
}

/// A real disk image mounted inside the sandbox: deleting the folder around it must not reach into it.
@Suite(.serialized) struct MountTests {
    @Test func neverDeletesIntoAMountedVolume() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let tree = try box.mkdir("Library/Caches/tool")
        let mount = try box.mkdir("Library/Caches/tool/mnt")
        _ = try box.write("Library/Caches/tool/other.txt")
        let image = "\(box.root)/image.dmg"
        let create = await Shell.run("hdiutil", ["create", "-size", "4m", "-fs", "APFS", "-volname", "ArinTest", "-quiet", image], timeout: 60)
        let attach = await Shell.run("hdiutil", ["attach", "-nobrowse", "-mountpoint", mount, "-quiet", image], timeout: 60)
        guard create.ok, attach.ok else {
            Issue.record("couldn't mount a test image: \(create.stderr)\(attach.stderr)")
            return
        }
        defer { _ = Process.run2("/usr/bin/hdiutil", ["detach", "-force", mount]) }
        let victim = "\(mount)/victim.txt"
        try "keep".write(toFile: victim, atomically: true, encoding: .utf8)

        // The guardrails refuse the folder and the mount point itself.
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.check(tree) }
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.check(mount) }
        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(tree), state: .empty)
        #expect(item.status == .skipped)

        // Even past the guardrails, the remover stops at the volume boundary.
        let removal = await TreeRemover.remove(tree)
        #expect(removal.leftBehind.contains { $0.errno == EXDEV })
        #expect(FileManager.default.fileExists(atPath: victim))
        #expect(!FileManager.default.fileExists(atPath: "\(tree)/other.txt"))
    }
}

private extension Process {
    static func run2(_ path: String, _ arguments: [String]) -> Int32 {
        guard let process = try? Process.run(URL(fileURLWithPath: path), arguments: arguments) else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@Suite struct MountGuardrailTests {
    func guardrails(_ mounts: [String]?) -> Guardrails {
        var g = Guardrails(home: "/Users/test", tmpDir: "/var/folders/ab/cdef/T/")
        g.mountPoints = { mounts }
        return g
    }

    @Test func refusesPathsWithAMountAtOrBelowThem() {
        let g = guardrails(["/", "/System/Volumes/Data", "/Users/test/Library/Caches/x/mnt", "/private/tmp/share"])
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Caches/x") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Caches/x/mnt") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/library/caches/X") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/tmp/share") }
        #expect(throws: Guardrails.Violation.self) { try g.checkTarget("/Users/test/Library/Caches/x") }
        #expect(throws: Never.self) { try g.check("/Users/test/Library/Caches/y") }
        #expect(throws: Never.self) { try g.check("/Users/test/Library/Caches/x/mntz") }
    }

    @Test func seesMountsReportedThroughTheDataVolume() {
        let g = guardrails(["/System/Volumes/Data/Users/test/projects/app/remote"])
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/projects/app") }
    }

    @Test func refusesEverythingWhenMountsCantBeListed() {
        #expect(throws: Guardrails.Violation.self) { try guardrails(nil).check("/Users/test/Library/Caches/y") }
    }

    @Test func listsTheRootVolume() {
        #expect(Guardrails.currentMountPoints()?.contains("/") == true)
    }
}

@Suite struct LowSpacePolicyTests {
    let threshold: Int64 = 20_000_000_000

    @Test func alertsOncePerDropAndRearmsAboveTheMargin() {
        var alerted = false
        func step(_ free: Int64) -> Bool {
            let decision = LowSpacePolicy.evaluate(free: free, threshold: threshold, alerted: alerted)
            alerted = decision.alerted
            return decision.notify
        }
        #expect(!step(30_000_000_000))
        #expect(step(19_000_000_000))
        #expect(!step(18_000_000_000))
        // Back just above the line, then below again: still the same drop.
        #expect(!step(20_500_000_000))
        #expect(!step(19_500_000_000))
        // Clear of the margin (2 GB here), then below: a new alert.
        #expect(!step(22_000_000_000))
        #expect(step(19_000_000_000))
    }

    @Test func marginIsTenPercentWithAFloor() {
        #expect(LowSpacePolicy.rearmMargin(threshold: 5_000_000_000) == 2_000_000_000)
        #expect(LowSpacePolicy.rearmMargin(threshold: 100_000_000_000) == 10_000_000_000)
    }
}

@Suite struct CandidateSelectionTests {
    @Test func reportsEveryUnmatchedID() {
        let a = candidate("/a"), b = candidate("/b")
        let (picked, unmatched) = CandidateSelection.pick([a.id, "t:/typo", "t:/typo", b.id], from: [a, b])
        #expect(picked.map(\.id) == [a.id, b.id])
        #expect(unmatched == ["t:/typo"])
    }
}

@Suite struct DeveloperToolsTests {
    @Test func onlySystemStubsCount() {
        #expect(DeveloperTools.isStub("/usr/bin/git"))
        #expect(DeveloperTools.isStub("/usr/bin/xcrun"))
        #expect(!DeveloperTools.isStub("/opt/homebrew/bin/git"))
        #expect(!DeveloperTools.isStub("/usr/bin/tmutil"))
    }

    @Test func honorsDeveloperDir() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let dir = try box.mkdir("Developer")
        _ = try box.mkdir("Developer/usr/bin")
        #expect(DeveloperTools.installed(environment: ["DEVELOPER_DIR": dir]))
    }
}

/// Every tool missing, failing, printing nothing, or hanging. Records what was asked of it.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    enum Mode { case missing, failing, silent, hanging }
    let mode: Mode
    private let lock = NSLock()
    private var calls: [String] = []

    init(_ mode: Mode) { self.mode = mode }

    var executables: Set<String> { lock.withLock { Set(calls) } }

    func which(_ name: String) -> String? { mode == .missing ? nil : "/fake/bin/\(name)" }

    func run(_ executable: String, _ arguments: [String], cwd: String?, input: String?,
             environment: [String: String], timeout: TimeInterval) async -> ShellResult {
        lock.withLock { calls.append(executable) }
        switch mode {
        case .missing: return ShellResult(status: 127, stdout: "", stderr: "\(executable): not found", timedOut: false)
        case .failing: return ShellResult(status: 1, stdout: "garbage {", stderr: "error: boom", timedOut: false)
        case .silent: return ShellResult(status: 0, stdout: "", stderr: "", timedOut: false)
        case .hanging: return ShellResult(status: 15, stdout: "", stderr: "", timedOut: true)
        }
    }
}

@Suite struct PortabilityTests {
    /// A fresh Mac: an empty home, empty temp folders, and tools that are missing or misbehave.
    /// Every rule must find nothing, throw nothing, and never fall back to the real machine.
    @Test(arguments: [FakeRunner.Mode.missing, .failing, .silent, .hanging])
    func everyRuleFindsNothingInAnEmptyHome(_ mode: FakeRunner.Mode) async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.mkdir("tmp")
        _ = try box.mkdir("shared-tmp")
        var options = ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: [],
                                  checkPullRequests: false, minimumBytes: 0, keepListURL: nil)
        options.sharedTmpDir = "\(box.root)/shared-tmp"
        let runner = FakeRunner(mode)
        let report = await Shell.$runner.withValue(runner) { await Scanner(options: options).scan() }
        #expect(report.candidates.isEmpty, "\(report.candidates.map(\.id))")
        #expect(report.ruleErrors.isEmpty, "\(report.ruleErrors)")
        if mode != .missing { #expect(!runner.executables.isEmpty, "the scan should have asked for tools") }
    }
}

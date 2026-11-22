@testable import ArinCore
import Darwin
import Foundation
import Testing

private func candidate(_ path: String, bytes: Int64 = 1) -> Candidate {
    Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
              bytes: bytes, paths: [path], action: .delete([path]))
}

private func unlock(_ box: Sandbox) {
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/chflags"), arguments: ["-R", "nouchg,nouappnd", box.root]).waitUntilExit()
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

    @Test func makesReadOnlyFoldersWritableThroughTheirDescriptor() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let inner = try box.mkdir("Library/Caches/tool/pkg/inner")
        _ = try box.write("Library/Caches/tool/pkg/inner/file")
        #expect(chmod(inner, 0o555) == 0)
        #expect(chmod("\(box.root)/Library/Caches/tool/pkg", 0o555) == 0)
        let removal = await TreeRemover.remove("\(box.root)/Library/Caches/tool")
        #expect(removal.isComplete, "\(removal.problems)")
        #expect(!FileInfo.exists("\(box.root)/Library/Caches/tool"))
    }

    @Test func leavesFoldersItCantOpenAndCreditsNothing() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let target = try box.mkdir("Library/Caches/tool")
        _ = try box.write("Library/Caches/tool/small")
        let unreadable = try box.mkdir("Library/Caches/tool/unreadable")
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: "\(unreadable)/big"))
        #expect(chmod(unreadable, 0o000) == 0)
        defer { _ = chmod(unreadable, 0o700) }

        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(target, bytes: 2_100_000), state: .empty)
        #expect(item.status == .partial)
        #expect(item.estimatedBytes == 0)
        #expect(item.message.contains("chmod -R u+rwx"), "\(item.message)")
        #expect(item.message.contains("unknown"))
        var mode = stat()
        #expect(stat(unreadable, &mode) == 0 && mode.st_mode & 0o777 == 0, "left untouched")
    }

    @Test func unreachablePathsLeaveTheSizeUnknown() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let first = try box.mkdir("Library/Caches/one")
        _ = try box.write("Library/Caches/one/file")
        let fence = try box.mkdir("Library/Caches/fence")
        let second = try box.mkdir("Library/Caches/fence/two")
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: "\(second)/big"))
        #expect(chmod(fence, 0o000) == 0)
        defer { _ = chmod(fence, 0o700) }

        let item = Candidate(ruleID: "t", title: "t", detail: "", category: .devCaches, level: .quick, risk: .safe,
                             bytes: 2_100_000, paths: [first, second], action: .delete([first, second]))
        let result = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(item, state: .empty)
        #expect(result.status == .partial)
        #expect(result.estimatedBytes == 0)
        #expect(result.message.contains("unknown"), "\(result.message)")
    }

    @Test func partialEstimateIsTheScannedSizeLessWhatsLeft() async throws {
        let box = try Sandbox()
        defer { unlock(box); box.cleanup() }
        let target = try box.mkdir("Library/Caches/tool")
        try Data(count: 1_000_000).write(to: URL(fileURLWithPath: "\(target)/gone"))
        let locked = "\(target)/locked"
        try Data(count: 3_000_000).write(to: URL(fileURLWithPath: locked))
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        let scanned = await Size.total([target])

        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(target, bytes: scanned), state: .empty)
        #expect(item.status == .partial)
        let left = await Size.total([target])
        #expect(item.estimatedBytes == scanned - left)
        #expect(item.estimatedBytes < 1_500_000)
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
        #expect(item.message.contains("nouchg"), "\(item.message)")
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

    @Test func appendOnlyAdviceClearsBothUserFlags() throws {
        let box = try Sandbox()
        defer { unlock(box); box.cleanup() }
        let file = try box.write("Library/Caches/appendonly")
        #expect(chflags(file, UInt32(UF_APPEND)) == 0)
        let advice = RemovalAdvice.advice(path: file, errno: EPERM)
        #expect(advice.contains("nouchg,nouappnd"), "\(advice)")
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

        #expect(throws: Guardrails.Violation.self) { try box.guardrails.check(tree) }
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.check(mount) }
        let item = await Executor(guardrails: box.guardrails, keepListURL: nil).clean(candidate(tree), state: .empty)
        #expect(item.status == .skipped)

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
        #expect(!step(20_500_000_000))
        #expect(!step(19_500_000_000))
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
    @Test func skipsAStubAndFindsALaterRealTool() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for dir in ["stub", "real"] {
            let path = try box.write("\(dir)/git", "#!/bin/sh\n")
            #expect(chmod(path, 0o755) == 0)
        }
        let stubDir = "\(box.root)/stub"
        let found = Shell.locate("git", in: [stubDir, "\(box.root)/real"]) { !$0.hasPrefix(stubDir + "/") }
        #expect(found == "\(box.root)/real/git")
        #expect(Shell.locate("git", in: [stubDir]) { !$0.hasPrefix(stubDir + "/") } == nil)
    }

    @Test func onlySystemStubsCount() {
        #expect(DeveloperTools.isStub("/usr/bin/git"))
        #expect(DeveloperTools.isStub("/usr/bin/xcrun"))
        #expect(!DeveloperTools.isStub("/opt/homebrew/bin/git"))
        #expect(!DeveloperTools.isStub("/usr/bin/tmutil"))
    }

    @Test func acceptsAnXcodeBundleAsTheSelection() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let app = try box.mkdir("Xcode-beta.app")
        _ = try box.mkdir("Xcode-beta.app/Contents/Developer/usr/bin")
        let none = "\(box.root)/no-link"
        #expect(DeveloperTools.installed(environment: ["DEVELOPER_DIR": app], selectLink: none, defaults: []))
        #expect(!DeveloperTools.installed(environment: [:], selectLink: none, defaults: []))
        #expect(!DeveloperTools.installed(environment: ["DEVELOPER_DIR": "\(box.root)/missing.app"], selectLink: none, defaults: []))
    }

    @Test func honorsDeveloperDir() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let dir = try box.mkdir("Developer")
        _ = try box.mkdir("Developer/usr/bin")
        #expect(DeveloperTools.installed(environment: ["DEVELOPER_DIR": dir]))
    }
}

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

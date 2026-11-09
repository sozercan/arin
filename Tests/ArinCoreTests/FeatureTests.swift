@testable import ArinCore
import CoreGraphics
import Foundation
import Testing

private func candidate(_ id: String = "/x", risk: Risk = .safe, action: CleanupAction? = nil, paths: [String]? = nil) -> Candidate {
    let paths = paths ?? [id]
    return Candidate(ruleID: "t", key: id, title: id, detail: "", category: .devCaches, level: .quick, risk: risk,
                     bytes: 1, paths: paths, action: action ?? .delete(paths))
}

private func setModified(_ path: String, daysAgo: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: path)
}

@Suite struct KeepListTests {
    @Test func missingFileIsEmptyAndRoundTrips() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let url = URL(fileURLWithPath: "\(box.root)/state/keep.json")
        var list = try KeepList.load(from: url)
        #expect(list.entries.isEmpty)
        list.add(id: "t:/a", title: "A")
        list.add(id: "t:/a", title: "A again")
        try list.save(to: url)
        let loaded = try KeepList.load(from: url)
        #expect(loaded.entries.map(\.id) == ["t:/a"])
        var removed = loaded
        removed.remove(id: "t:/a")
        #expect(!removed.contains("t:/a"))
    }

    @Test func unreadableListFailsClosed() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let path = try box.write("keep.json", "{ not json")
        #expect(throws: StoreError.self) { try KeepList.load(from: URL(fileURLWithPath: path)) }

        let marked = [candidate("/a"), candidate("/b")].applying(keep: Result { try KeepList.load(from: URL(fileURLWithPath: path)) })
        #expect(marked.allSatisfy { !$0.blockers.isEmpty && !$0.isDefaultSelected(at: .deep) })
    }

    @Test func keptItemsAreNeverSelectedOrReviewed() {
        var list = KeepList()
        list.add(id: "t:/a", title: "a")
        let marked = [candidate("/a"), candidate("/b")].applying(keep: .success(list))
        #expect(marked[0].kept && marked[0].effectiveRisk == .keep && !marked[0].isDefaultSelected(at: .deep))
        #expect(!marked[1].kept && marked[1].isDefaultSelected(at: .quick))
    }

    @Test func executorRefusesKeptItemsAndEverythingWhenTheListIsUnreadable() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let kept = try box.mkdir("Library/Caches/kept")
        let other = try box.mkdir("Library/Caches/other")
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        var list = KeepList()
        list.add(id: "t:\(kept)", title: "kept")
        try list.save(to: url)

        let executor = Executor(guardrails: box.guardrails, keepListURL: url)
        let report = await executor.run([candidate(kept), candidate(other)])
        #expect(report.items.map(\.status) == [.skipped, .cleaned])
        #expect(FileInfo.exists(kept) && !FileInfo.exists(other))

        let again = try box.mkdir("Library/Caches/again")
        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        let refused = await executor.run([candidate(again)])
        #expect(refused.items.map(\.status) == [.skipped])
        #expect(FileInfo.exists(again))
    }
}

@Suite struct HistoryTests {
    func report(_ bytes: [String: Int64], date: Date) -> ScanReport {
        let candidates = bytes.map { rule, size in
            Candidate(ruleID: rule, key: rule, title: "\(rule) title", detail: "", category: .devCaches, level: .quick,
                      risk: .safe, bytes: size, paths: ["/\(rule)"], action: .delete(["/\(rule)"]))
        }
        return ScanReport(startedAt: date, finishedAt: date, disk: .zero, candidates: candidates, insights: [], ruleErrors: [:])
    }

    @Test func recordsScansAndCleanupsAndShowsGrowth() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let history = History(url: URL(fileURLWithPath: "\(box.root)/history.jsonl"))
        let gb: Int64 = 1 << 30
        try history.append(.scan(ScanRecord(report(["go": 2 * gb, "npm": gb], date: Date(timeIntervalSince1970: 1000)))))
        let cleanup = CleanupReport(items: [], freeBefore: 10, freeAfter: 30, estimatedBytes: 40, explanations: [])
        try history.append(.cleanup(CleanupRecord(cleanup, auto: true)))
        try history.append(.scan(ScanRecord(report(["go": 20 * gb, "npm": gb, "uv": 3 * gb], date: Date(timeIntervalSince1970: 2000)))))

        let entries = history.load()
        #expect(entries.count == 3)
        let scans = History.scans(entries)
        #expect(History.cleanups(entries).first?.measuredBytes == 20)
        let growth = History.growth(from: scans[0], to: scans[1])
        #expect(growth.map(\.ruleID) == ["go", "uv"])
        #expect(growth.first?.bytes == 18 * gb)
        #expect(growth.first?.label == "go title")
    }

    @Test func trimsTheOldestHalfAndSkipsTornLines() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let url = URL(fileURLWithPath: "\(box.root)/history.jsonl")
        let history = History(url: url, maxBytes: 2000)
        for i in 0 ..< 40 {
            try history.append(.scan(ScanRecord(report(["r": Int64(i)], date: Date(timeIntervalSince1970: Double(i))))))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"scan\":".utf8))
        try handle.close()
        let scans = History.scans(history.load())
        #expect(!scans.isEmpty && scans.count < 40)
        #expect(scans.last?.bytesByRule["r"] == 39)
    }

    @Test func trashedItemsCanBePutBack() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let name = "arin-put-back-test-\(UUID().uuidString)"
        let dir = try box.mkdir("Library/Caches/\(name)")
        _ = try box.write("Library/Caches/\(name)/file", "data")
        let executor = Executor(guardrails: box.guardrails, trashInsteadOfDelete: true, keepListURL: nil)
        let report = await executor.run([candidate(dir)])
        let trashed = try #require(report.items.first?.trashedPaths?.first)
        #expect(!FileInfo.exists(dir) && trashed.canPutBack)
        try trashed.putBack(guardrails: box.guardrails)
        #expect(FileInfo.exists("\(dir)/file") && !trashed.canPutBack)
    }
}

@Suite struct PlanTests {
    @Test func runsOnlyUnchangedItems() throws {
        let same = candidate("/same")
        let moved = candidate("/moved", action: .removeWorktree(repo: "/r", path: "/moved", head: "abc"))
        let riskier = candidate("/riskier")
        let gone = candidate("/gone")
        let keptLater = candidate("/kept")
        let plan = try CleanupPlan.load(fromData: CleanupPlan([same, moved, riskier, gone, keptLater]).encoded())

        var nowMoved = candidate("/moved", action: .removeWorktree(repo: "/r", path: "/moved", head: "def"))
        nowMoved.id = moved.id
        var nowRiskier = riskier
        nowRiskier.risk = .review
        var nowKept = keptLater
        nowKept.kept = true
        let (ready, refused) = plan.resolve(against: [same, nowMoved, nowRiskier, nowKept])
        #expect(ready.map(\.id) == [same.id])
        #expect(refused.map(\.item.id) == [moved.id, riskier.id, gone.id, keptLater.id])
    }
}

@Suite struct CommandShapeTests {
    @Test func dangerousToolsAreLimitedToOneShape() {
        #expect(Guardrails.allows(CommandSpec("tmutil", ["deletelocalsnapshots", "2026-11-08-101500"])))
        #expect(!Guardrails.allows(CommandSpec("tmutil", ["deletelocalsnapshots", "/"])))
        #expect(!Guardrails.allows(CommandSpec("tmutil", ["disable"])))
        #expect(!Guardrails.allows(CommandSpec("tmutil", ["delete", "-d", "/Volumes/Backup"])))
        #expect(Guardrails.allows(CommandSpec("ollama", ["rm", "llama3.2:latest"])))
        #expect(Guardrails.allows(CommandSpec("ollama", ["rm", "hf.co/org/model:Q4_K_M"])))
        #expect(!Guardrails.allows(CommandSpec("ollama", ["rm", "--all"])))
        #expect(!Guardrails.allows(CommandSpec("ollama", ["rm", "a", "b"])))
        #expect(!Guardrails.allows(CommandSpec("ollama", ["serve"])))
        #expect(Guardrails.allows(CommandSpec("mise", ["prune", "--tools", "--yes", "node"])))
        #expect(!Guardrails.allows(CommandSpec("mise", ["prune", "--yes"])))
        #expect(!Guardrails.allows(CommandSpec("mise", ["uninstall", "--all"])))
        #expect(!Guardrails.allows(CommandSpec("mise", ["prune", "--tools", "--yes", "--configs"])))
        #expect(!Guardrails.allows(CommandSpec("rm", ["-rf", "/"])))
        #expect(Guardrails.allows(CommandSpec("go", ["clean", "-cache"])))
    }

    @Test func executorRefusesOtherShapes() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let executor = Executor(guardrails: box.guardrails, keepListURL: nil)
        let report = await executor.run([candidate("tm", action: .commands([CommandSpec("tmutil", ["disable"])]), paths: [])])
        #expect(report.items.first?.status == .skipped)
    }
}

@Suite struct ProjectRuleTests {
    func context(_ box: Sandbox) -> ScanContext {
        ScanContext(options: ScanOptions(home: box.root, tmpDir: "\(box.root)/tmp", projectRoots: ["\(box.root)/projects"],
                                         checkPullRequests: false, keepListURL: nil),
                    state: .empty, now: Date())
    }

    @Test func recentlyActiveProjectsAreListedButNotPreselected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for name in ["idle", "active"] {
            _ = try box.write("projects/\(name)/package.json", "{}")
            _ = try box.write("projects/\(name)/node_modules/dep/index.js", "x")
            _ = try box.write("projects/\(name)/src/main.js", "x")
        }
        for path in ["idle", "idle/package.json", "idle/src", "idle/src/main.js", "idle/node_modules"] {
            try setModified("\(box.root)/projects/\(path)", daysAgo: 30)
        }
        let found = try await ProjectArtifactRule().discover(context(box))
        let idle = try #require(found.first { $0.paths == ["\(box.root)/projects/idle/node_modules"] })
        let active = try #require(found.first { $0.paths == ["\(box.root)/projects/active/node_modules"] })
        #expect(idle.blockers.isEmpty && idle.isDefaultSelected(at: .standard))
        #expect(active.blockers.contains { $0.contains("project changed today") })
        #expect(!active.isDefaultSelected(at: .deep))
    }

    @Test func gitActivityInALinkedWorktreeCounts() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let gitDir = try box.mkdir("repo/.git/worktrees/wt")
        _ = try box.write("repo/.git/worktrees/wt/index", "i")
        _ = try box.write("wt/.git", "gitdir: \(gitDir)\n")
        _ = try box.write("wt/package.json", "{}")
        for path in ["wt/.git", "wt/package.json"] { try setModified("\(box.root)/\(path)", daysAgo: 60) }
        #expect(ProjectActivity.gitDirectory(above: "\(box.root)/wt") == gitDir)
        let last = try #require(ProjectActivity.lastActivity(project: "\(box.root)/wt", artifact: "\(box.root)/wt/node_modules"))
        #expect(Date().timeIntervalSince(last) < 3600)
    }

    @Test func classifiesNewBuildOutputOnlyWithItsMarkers() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let p = "\(box.root)/projects"
        _ = try box.write("projects/web/package.json", "{}")
        _ = try box.write("projects/web/next.config.mjs", "")
        _ = try box.mkdir("projects/web/.next/cache")
        _ = try box.mkdir("projects/plain/.next")
        _ = try box.write("projects/android/build.gradle.kts", "")
        _ = try box.mkdir("projects/android/build/tmp")
        _ = try box.mkdir("projects/notgradle/build/tmp")
        _ = try box.write("projects/infra/main.tf", "")
        _ = try box.mkdir("projects/infra/.terraform/providers")
        let tag = "Signature: 8a477f597d28d172789f06886806bc55\n# a cache"
        _ = try box.write("projects/py/.pytest_cache/CACHEDIR.TAG", tag)
        _ = try box.write("projects/py/.fake_cache/CACHEDIR.TAG", "Signature: nope")
        _ = try box.write("projects/py/data/CACHEDIR.TAG", tag)
        _ = try box.write("projects/py/.mypy_cache/CACHEDIR.TAG", tag)
        _ = try box.mkdir("projects/py/.mypy_cache/vendored/.git")

        #expect(await ProjectArtifactRule.classify("\(p)/web/.next") == .nextBuild)
        #expect(await ProjectArtifactRule.classify("\(p)/plain/.next") == nil)
        #expect(await ProjectArtifactRule.classify("\(p)/android/build") == .gradleBuild)
        #expect(await ProjectArtifactRule.classify("\(p)/notgradle/build") == nil)
        #expect(await ProjectArtifactRule.classify("\(p)/infra/.terraform") == .terraform)
        #expect(await ProjectArtifactRule.classify("\(p)/py/.pytest_cache") == .taggedCache)
        #expect(await ProjectArtifactRule.classify("\(p)/py/.fake_cache") == nil)
        #expect(await ProjectArtifactRule.classify("\(p)/py/data") == nil)
        #expect(await ProjectArtifactRule.classify("\(p)/py/.mypy_cache") == nil)

        let found = try await ProjectArtifactRule().discover(context(box))
        let names = Set(found.map { ($0.paths[0] as NSString).lastPathComponent + "@" + (($0.paths[0] as NSString).deletingLastPathComponent as NSString).lastPathComponent })
        #expect(names == [".next@web", "build@android", ".terraform@infra", ".pytest_cache@py"])
        #expect(found.first { $0.paths[0].hasSuffix(".terraform") }?.risk == .review)
    }
}

@Suite struct NewRuleParsingTests {
    @Test func timeMachineDatesOnly() {
        let names = [
            "com.apple.TimeMachine.2026-11-08-101500.local",
            "com.apple.os.update-ABCDEF",
            "com.apple.TimeMachine.2026-11-08-111500.local; rm -rf",
        ]
        #expect(TimeMachineSnapshotRule.dates(names) == ["2026-11-08-101500"])
    }

    @Test func ollamaTables() {
        let list = """
        NAME                       ID              SIZE      MODIFIED
        llama3.2:latest            a80c4f17acd5    2.0 GB    3 weeks ago
        nomic-embed-text:latest    0a109f422b47    274 MB    2 months ago
        """
        let rows = OllamaModelRule.parseTable(list)
        #expect(rows.map(\.name) == ["llama3.2:latest", "nomic-embed-text:latest"])
        #expect(rows.map(\.bytes) == [2_000_000_000, 274_000_000])
        #expect(OllamaModelRule.parseSize("1.5 TB") == 1_500_000_000_000)
        #expect(OllamaModelRule.parseSize("lots") == nil)
    }
}

@Suite struct TreemapTests {
    @Test func tilesFillTheRectProportionally() {
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let values: [Double] = [6, 0, 6, 4, 3, 2, 2, 1]
        let tiles = Treemap.layout(values, in: rect)
        #expect(tiles.count == values.count)
        #expect(tiles[1] == .zero)
        let total = values.reduce(0, +)
        for (value, tile) in zip(values, tiles) where value > 0 {
            #expect(abs(Double(tile.width * tile.height) - value / total * 240_000) < 1)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile))
        }
        for i in tiles.indices {
            for j in tiles.indices where i < j && values[i] > 0 && values[j] > 0 {
                #expect(tiles[i].intersection(tiles[j]).width * tiles[i].intersection(tiles[j]).height < 0.01)
            }
        }
    }
}

@Suite struct ReviewFixTests {
    @Test func cleanupsThatWouldRemoveAKeptPathAreRefused() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let worktree = try box.mkdir("projects/wt")
        let modules = try box.mkdir("projects/wt/node_modules")
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        try KeepList.update(at: url) { $0.add(id: "projects.artifacts:\(modules)", title: "node_modules · wt", paths: [modules]) }

        let parent = candidate(worktree)
        let marked = [parent].applying(keep: Result { try KeepList.load(from: url) })
        #expect(marked[0].blockers == ["contains node_modules · wt, which you chose to keep"])
        // Applying again replaces its own blockers instead of piling them up.
        #expect(marked.applying(keep: Result { try KeepList.load(from: url) })[0].blockers.count == 1)

        let report = await Executor(guardrails: box.guardrails, keepListURL: url).run([parent])
        #expect(report.items.first?.status == .skipped)
        #expect(FileInfo.exists(modules))
    }

    @Test func aKeepListThatCantBeReachedBlocksCleaning() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let dir = try box.mkdir("locked")
        _ = try box.write("locked/keep.json", #"{"entries":[]}"#)
        #expect(chmod(dir, 0o000) == 0)
        defer { chmod(dir, 0o755) }
        #expect(throws: StoreError.self) { try KeepList.load(from: URL(fileURLWithPath: "\(dir)/keep.json")) }
        #expect(try KeepList.load(from: URL(fileURLWithPath: "\(box.root)/missing/keep.json")).entries.isEmpty)
    }

    @Test func concurrentKeepUpdatesAreNotLost() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            _ = try? KeepList.update(at: url) { $0.add(id: "t:/\(i)", title: "\(i)") }
        }
        #expect(try KeepList.load(from: url).entries.count == 24)
    }

    @Test func putBackOnlyTakesItemsFromTheTrash() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let outside = try box.write("Documents/report", "precious")
        let forged = TrashedPath(original: "\(box.root)/Library/Caches/x", location: outside)
        #expect(!forged.canPutBack)
        #expect(throws: StoreError.self) { try forged.putBack(guardrails: box.guardrails) }
        #expect(FileInfo.exists(outside))
        let sneaky = TrashedPath(original: "\(box.root)/Library/Caches/x", location: "\(ArinStore.trashDirectory)/../Documents")
        #expect(throws: StoreError.self) { try sneaky.checkLocation() }
    }

    @Test func aTornLineDoesNotSwallowTheNextRecord() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let url = URL(fileURLWithPath: "\(box.root)/history.jsonl")
        try Data("{\"scan\":".utf8).write(to: url)
        let cleanup = CleanupReport(items: [], freeBefore: 1, freeAfter: 5, estimatedBytes: 0, explanations: [])
        try History(url: url).append(.cleanup(CleanupRecord(cleanup, auto: false)))
        #expect(History.cleanups(History(url: url).load()).map(\.measuredBytes) == [4])
    }

    @Test func ollamaRemovalIsRefusedWhenLoadedModelsCantBeChecked() async throws {
        // Without a reachable Ollama, `ollama ps` fails and removal must not run.
        if await Shell.run("ollama", ["ps"], timeout: 10).ok { return }
        let reason = await Executor.preflight(CommandSpec("ollama", ["rm", "arin-test-model"]))
        #expect(reason?.contains("couldn't check") == true)
    }
}

private struct FixedRule: Rule {
    var id = "fixed"
    var name = "Fixed"
    var found: [Candidate]
    func discover(_ ctx: ScanContext) async throws -> [Candidate] { found }
}

@Suite struct KeepPathTests {
    @Test func anotherSpellingOfAKeptFolderIsStillKept() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let modules = try box.mkdir("Projects/app/node_modules")
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/link", withDestinationPath: "\(box.root)/Projects")
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        try KeepList.update(at: url) { $0.add(id: "t:\(modules)", title: "node_modules", paths: [modules]) }

        // Different case, and through a symlinked folder: different IDs, same directory.
        let aliases = [candidate("\(box.root)/projects/APP/node_modules"), candidate("\(box.root)/link/app"), candidate("\(box.root)/link/app/node_modules/")]
        let marked = aliases.applying(keep: Result { try KeepList.load(from: url) })
        #expect(marked.allSatisfy { $0.blockers == ["contains node_modules, which you chose to keep"] })

        let report = await Executor(guardrails: box.guardrails, keepListURL: url).run(aliases)
        #expect(report.items.allSatisfy { $0.status == .skipped })
        #expect(FileInfo.exists(modules))
    }

    @Test func keepingByIDAloneProtectsWhatTheScanFindsForIt() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let worktree = try box.mkdir("projects/wt")
        let cache = try box.mkdir("projects/wt/.gocache")
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        // What `arin keep go.build-cache:go.build-cache` records: no paths.
        try KeepList.update(at: url) { $0.add(id: "go:go", title: "Go build cache") }

        var goCache = candidate("go", paths: [cache])
        goCache.ruleID = "go"
        goCache.id = "go:go"
        goCache.bytes = 1 // under the size filter, so it isn't listed but must still protect itself
        var parent = candidate(worktree)
        parent.bytes = 100
        let options = ScanOptions(home: box.root, tmpDir: box.root, projectRoots: [], minimumBytes: 10, keepListURL: url)
        let report = await Scanner(options: options, rules: [FixedRule(found: [goCache, parent])], insightRules: []).scan()
        #expect(report.candidates.map(\.id) == [parent.id])
        #expect(report.candidates[0].blockers == ["contains Go build cache, which you chose to keep"])
        #expect(try KeepList.load(from: url).entries[0].paths == [cache])

        // The executor re-reads the saved paths, so the worktree is refused there too.
        let result = await Executor(guardrails: box.guardrails, keepListURL: url).run([parent])
        #expect(result.items.first?.status == .skipped)
        #expect(FileInfo.exists(cache))
    }

    @Test func planRefusesAnItemWhoseFoldersChanged() throws {
        let npm = candidate("npm", action: .commands([CommandSpec("npm", ["cache", "clean", "--force"])]), paths: ["/old/npm"])
        let plan = try CleanupPlan.load(fromData: CleanupPlan([npm]).encoded())
        var moved = npm
        moved.paths = ["/new/npm"]
        #expect(plan.resolve(against: [npm]).ready.count == 1)
        let (ready, refused) = plan.resolve(against: [moved])
        #expect(ready.isEmpty)
        #expect(refused.first?.reason == "its folders changed since the plan was made; make a new plan")
    }
}

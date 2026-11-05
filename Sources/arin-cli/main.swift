import ArinCore
import Foundation

let usage = """
usage: arin <command> [options]

commands:
  scan                 Find cleanup candidates (read-only)
  review               Scan, then ask your agent to judge each candidate (read-only)
  clean                Clean pre-selected candidates (dry run unless --yes)

options:
  --level quick|standard|deep   Cleanup depth (default: standard)
  --agent claude|codex          Agent for review (default: first installed)
  --limit N                     Max candidates sent to the agent (default: 150)
  --roots a,b                   Project roots to search (default: ~/projects, ~/go/src, …)
  --ids a,b                     clean: exactly these candidate ids instead of the pre-selection
  --no-pr                       Skip GitHub merged-PR lookups for worktrees
  --fetch                       git fetch --prune before classifying worktrees
  --trash                       clean: move to Trash instead of deleting
  --yes                         clean: actually do it
  --json                        Machine-readable output
"""

struct Args {
    var command = ""
    var level = Level.standard
    var agent: AgentProvider?
    var limit = 150
    var roots: [String]?
    var ids: [String]?
    var checkPRs = true
    var fetch = false
    var trash = false
    var yes = false
    var json = false

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw CLIError("\(flag) needs a value") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--level":
                let v = try value(arg)
                guard let l = Level(name: v) else { throw CLIError("unknown level \(v)") }
                level = l
            case "--agent":
                let v = try value(arg)
                guard let a = AgentProvider(rawValue: v) else { throw CLIError("unknown agent \(v)") }
                agent = a
            case "--limit": limit = Int(try value(arg)) ?? 150
            case "--roots": roots = try value(arg).split(separator: ",").map { (String($0) as NSString).expandingTildeInPath }
            case "--ids": ids = try value(arg).split(separator: ",").map(String.init)
            case "--no-pr": checkPRs = false
            case "--fetch": fetch = true
            case "--trash": trash = true
            case "--yes", "-y": yes = true
            case "--json": json = true
            case "-h", "--help": command = "help"
            default:
                if command.isEmpty, !arg.hasPrefix("-") { command = arg } else { throw CLIError("unknown argument \(arg)") }
            }
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

func printTable(_ candidates: [Candidate], level: Level) {
    for category in CleanupCategory.allCases {
        let items = candidates.filter { $0.category == category }
        guard !items.isEmpty else { continue }
        print("\n\(category.label) — \(items.dedupedBytes.formattedBytes)")
        for c in items {
            let mark = c.isDefaultSelected(at: level) ? "[x]" : "[ ]"
            let risk = c.effectiveRisk.label + (c.agentVerdict != nil ? "*" : "")
            print("  \(mark) \(pad(c.bytes.formattedBytes, 10)) \(pad(risk, 7)) L\(c.level.rawValue) \(c.title)")
            if let v = c.agentVerdict { print("        agent: \(v.reason)") }
            if !c.blockers.isEmpty { print("        blocked: \(c.blockers.joined(separator: "; "))") }
        }
    }
}

func scan(_ args: Args) async -> ScanReport {
    let options = ScanOptions(projectRoots: args.roots, checkPullRequests: args.checkPRs, fetchRemotes: args.fetch)
    let scanner = Scanner(options: options)
    if !args.json { eprint("Scanning \(scanner.rules.count) rule groups…") }
    return await scanner.scan { event in
        if args.json { return }
        if case let .ruleFinished(name, found) = event, found > 0 { eprint("  \(name): \(found)") }
    }
}

func summarize(_ report: ScanReport, level: Level) {
    let disk = report.disk
    print("Disk: \(disk.freeBytes.formattedBytes) free of \(disk.totalBytes.formattedBytes) (\(Int(disk.usedFraction * 100))% used)")
    printTable(report.candidates, level: level)
    let selected = report.candidates.filter { $0.isDefaultSelected(at: level) }
    print("\nPre-selected at \(level.label): \(selected.count) items, \(selected.dedupedBytes.formattedBytes) (du estimate)")
    for insight in report.insights {
        print("\nⓘ \(insight.title)\(insight.bytes.map { " — \($0.formattedBytes)" } ?? "")\n  \(insight.detail)")
    }
    for (rule, error) in report.ruleErrors.sorted(by: { $0.key < $1.key }) {
        print("\n⚠︎ \(rule): \(error)")
    }
    print(String(format: "\nScan took %.0fs. Nothing was changed.", report.finishedAt.timeIntervalSince(report.startedAt)))
}

func main() async -> Int32 {
    let args: Args
    do { args = try Args(Array(CommandLine.arguments.dropFirst())) } catch {
        eprint("\(error)\n\n\(usage)")
        return 2
    }
    switch args.command {
    case "scan":
        let report = await scan(args)
        if args.json { printJSON(report) } else { summarize(report, level: args.level) }
        return 0

    case "review":
        guard let agent = args.agent ?? AgentProvider.installed.first else {
            eprint("No supported agent CLI found (claude or codex).")
            return 1
        }
        var report = await scan(args)
        if !args.json { eprint("Asking \(agent.label) to review up to \(args.limit) candidates (read-only)…") }
        do {
            let verdicts = try await AgentReviewer(provider: agent, maxCandidates: args.limit).review(report.candidates)
            report.candidates = report.candidates.applying(verdicts)
            if !args.json { eprint("  \(verdicts.count) verdicts") }
        } catch {
            eprint("Review failed: \(error)")
            return 1
        }
        if args.json { printJSON(report) } else { summarize(report, level: args.level) }
        return 0

    case "clean":
        let report = await scan(args)
        let chosen: [Candidate] = if let ids = args.ids {
            report.candidates.filter { ids.contains($0.id) }
        } else {
            report.candidates.filter { $0.isDefaultSelected(at: args.level) }
        }
        guard !chosen.isEmpty else {
            print("Nothing to clean.")
            return 0
        }
        guard args.yes else {
            print("Dry run. Would clean \(chosen.count) items (\(chosen.dedupedBytes.formattedBytes) du estimate):")
            for c in chosen { print("  \(pad(c.bytes.formattedBytes, 10)) \(c.title)\n             \(c.action.summary)") }
            print("\nRe-run with --yes to clean.")
            return 0
        }
        let executor = Executor(trashInsteadOfDelete: args.trash)
        let result = await executor.run(chosen) { event in
            guard !args.json, case let .finished(item) = event else { return }
            eprint("  \(item.status.rawValue): \(item.title) — \(item.message)")
        }
        if args.json {
            printJSON(result)
        } else {
            print("\nCleaned \(result.cleanedCount)/\(result.items.count). du estimate \(result.estimatedBytes.formattedBytes); free space changed by \(result.measuredBytes.formattedBytes) (\(result.freeBefore.formattedBytes) → \(result.freeAfter.formattedBytes)).")
            for note in result.explanations { print("  • \(note)") }
        }
        return result.items.contains { $0.status == .failed } ? 1 : 0

    default:
        print(usage)
        return args.command == "help" ? 0 : 2
    }
}

exit(await main())

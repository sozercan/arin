import ArinCore
import Foundation

let usage = """
usage: arin <command> [options]

commands:
  scan                 Find cleanup candidates (read-only)
  review               Scan, then ask your agent to judge each candidate (read-only)
  clean                Clean pre-selected candidates (dry run unless --yes)
  plan                 Save the candidates clean would pick to a plan file (read-only)
  keep [ID…]           Never clean these candidates; with no IDs, list the keep list
  history              Past cleanups and what grew since the previous scan
  apps                 List apps that can be uninstalled (read-only)
  uninstall APP        Move an app and the files it keeps in ~/Library to the Trash
                       (dry run unless --yes). APP is a name, bundle ID, or path.
  skill                Print instructions that teach a coding agent to use arin
  disk                 Free space on your home folder's volume. With --warn-below SIZE, print
                       only when it's lower, and always exit 0 (for an agent's session hook)

options:
  --level quick|standard|deep   Cleanup depth (default: standard)
  --agent claude|codex|copilot  Agent for review (default: first installed)
  --limit N                     Max candidates sent to the agent (default: 150)
  --model NAME                  Review model (default: sonnet for claude, CLI default for codex and copilot; "" = CLI default)
  --effort low|medium|high|xhigh  Review effort (default: low; "" = CLI default)
  --roots a,b                   Project roots to search (default: ~/projects, ~/go/src, …)
  --ids a,b                     clean/plan: exactly these candidate ids instead of the pre-selection;
                                with --plan, only these items from the plan
  --plan FILE                   clean: run a saved plan; items that changed since are refused
  --out FILE                    plan: write here instead of stdout
  --remove                      keep: take the IDs off the keep list
  --no-pr                       Skip GitHub merged-PR lookups for worktrees
  --fetch                       git fetch --prune before classifying worktrees
  --trash                       clean: move to Trash instead of deleting
  --all                         uninstall: also take files matched only by name or shared with other apps
  --warn-below SIZE             disk: warn only below this much free space (20GiB, 500GB, …)
  --yes                         clean: actually do it
  --json                        Machine-readable output
"""

struct Args {
    var command = ""
    var level = Level.standard
    var agent: AgentProvider?
    var limit = 150
    var model: String?
    var effort: String?
    var roots: [String]?
    var ids: [String]?
    var plan: String?
    var out: String?
    var remove = false
    var warnBelow: String?
    var positional: [String] = []
    var checkPRs = true
    var fetch = false
    var trash = false
    var all = false
    var yes = false
    var json = false

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        var given = Set<String>()
        func value(_ flag: String) throws -> String {
            guard given.insert(flag).inserted else { throw CLIError("\(flag) given more than once") }
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
            case "--limit":
                let v = try value(arg)
                guard let n = Int(v), n > 0 else { throw CLIError("--limit needs a positive integer, got \(v)") }
                limit = n
            case "--model": model = try value(arg)
            case "--effort": effort = try value(arg)
            case "--roots": roots = try value(arg).split(separator: ",").map { (String($0) as NSString).expandingTildeInPath }
            case "--ids":
                ids = try value(arg).split(separator: ",").map(String.init)
                if ids?.isEmpty == true { throw CLIError("--ids needs at least one candidate id") }
            case "--plan": plan = (try value(arg) as NSString).expandingTildeInPath
            case "--out": out = (try value(arg) as NSString).expandingTildeInPath
            case "--remove": remove = true
            case "--warn-below": warnBelow = try value(arg)
            case "--no-pr": checkPRs = false
            case "--fetch": fetch = true
            case "--trash": trash = true
            case "--all": all = true
            case "--yes", "-y": yes = true
            case "--json": json = true
            case "-h", "--help": command = "help"
            default:
                if arg.hasPrefix("-") { throw CLIError("unknown argument \(arg)") }
                if command.isEmpty { command = arg } else { positional.append(arg) }
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
    let report = await scanner.scan { event in
        if args.json { return }
        if case let .ruleFinished(name, found) = event, found > 0 { eprint("  \(name): \(found)") }
    }
    record(.scan(ScanRecord(report, ruleNames: Catalog.ruleNames)))
    return report
}

func record(_ entry: HistoryEntry) {
    do { try History().append(entry) } catch { eprint("warning: could not write history: \(error.localizedDescription)") }
}

func chosen(_ report: ScanReport, _ args: Args) -> [Candidate]? {
    guard let ids = args.ids else { return report.candidates.filter { $0.isDefaultSelected(at: args.level) } }
    let (picked, unmatched) = CandidateSelection.pick(ids, from: report.candidates)
    guard unmatched.isEmpty else {
        for id in unmatched { eprint("  no candidate \(id) in this scan (gone, or under the size cutoff)") }
        return nil
    }
    return picked
}

func printHistory(json: Bool) {
    let entries = History().load()
    let scans = History.scans(entries)
    let cleanups = History.cleanups(entries)
    let growth = scans.count >= 2 ? History.growth(from: scans[scans.count - 2], to: scans[scans.count - 1]) : []
    if json {
        struct Output: Encodable {
            var cleanups: [CleanupRecord]
            var growth: [[String: String]]
        }
        printJSON(Output(
            cleanups: cleanups,
            growth: growth.map { ["rule": $0.ruleID, "label": $0.label, "bytes": String($0.bytes)] }
        ))
        return
    }
    if scans.count >= 2 {
        let previous = scans[scans.count - 2]
        print("Since the scan \(previous.date.formatted(.relative(presentation: .named))):")
        if growth.isEmpty { print("  nothing grew by more than 256 MB") }
        for item in growth.prefix(10) { print("  +\(pad(item.bytes.formattedBytes, 10)) \(item.label)") }
        print("")
    }
    if cleanups.isEmpty { print("No cleanups yet.") }
    for cleanup in cleanups.suffix(20).reversed() {
        let cleaned = cleanup.items.filter { $0.status == .cleaned }.count
        print("\(cleanup.date.formatted(date: .abbreviated, time: .shortened))\(cleanup.auto ? " (auto)" : ""): freed \(max(cleanup.measuredBytes, 0).formattedBytes), \(cleaned)/\(cleanup.items.count) items, estimate \(cleanup.estimatedBytes.formattedBytes)")
    }
}

func runKeep(_ args: Args) -> Int32 {
    if args.positional.isEmpty {
        let list: KeepList
        do { list = try KeepList.load() } catch {
            eprint("\(error)")
            return 1
        }
        if args.json { printJSON(list) } else if list.entries.isEmpty { print("The keep list is empty.") }
        else { for entry in list.entries { print("\(entry.id)\(entry.title == entry.id ? "" : "  (\(entry.title))")") } }
        return 0
    }
    do {
        try KeepList.update { list in
            for id in args.positional {
                let key = id.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                if args.remove { list.remove(id: id) } else { list.add(id: id, title: id, paths: key.hasPrefix("/") ? [key] : []) }
            }
        }
    } catch {
        eprint("Could not save the keep list: \(error)")
        return 1
    }
    print(args.remove ? "Removed \(args.positional.count) from the keep list." : "Arin will never clean \(args.positional.count == 1 ? "this item" : "these items").")
    return 0
}

func installedApps() async -> [InstalledApp] {
    let casks = await AppCatalog.caskTokens()
    return AppCatalog.installed().map { app in
        var app = app
        app.caskToken = casks[app.path.lowercased()]
        return app
    }
}

func findApps(_ query: String, in apps: [InstalledApp]) -> [InstalledApp] {
    if query.contains("/") {
        let path = ((query as NSString).expandingTildeInPath as NSString).standardizingPath.lowercased()
        return apps.filter { ($0.path as NSString).standardizingPath.lowercased() == path }
    }
    let query = query.lowercased()
    let bare = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
    return apps.filter { app in
        let file = (((app.path as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased()
        return app.bundleID.lowercased() == query || app.name.lowercased() == bare || file == bare
    }
}

func runUninstall(_ args: Args) async -> Int32 {
    guard let query = args.positional.first else {
        eprint("uninstall needs an app: a name, bundle ID, or path\n\n\(usage)")
        return 2
    }
    let apps = await installedApps()
    let matches = findApps(query, in: apps)
    guard matches.count == 1, let app = matches.first else {
        if matches.isEmpty {
            eprint("No app matching \(query) in /Applications or ~/Applications. Apple's apps can't be uninstalled with Arin. Run arin apps to list the rest.")
        } else {
            eprint("\(query) matches \(matches.count) apps; name one by path:")
            for match in matches { eprint("  \(match.path)") }
        }
        return 1
    }
    let files = await AppFiles.find(for: app, others: apps.filter { $0.path != app.path })
    let picked = files.filter { args.all || !$0.needsReview }
    let uninstaller = Uninstaller()

    guard args.yes else {
        if args.json {
            struct Output: Encodable {
                var app: InstalledApp
                var files: [AppFile]
            }
            printJSON(Output(app: app, files: files))
            return 0
        }
        print("\(app.name) \(app.version ?? "") (\(app.bundleID))\(app.caskToken.map { " — Homebrew cask \($0)" } ?? "")")
        for file in files {
            let mark = picked.contains(file) ? "[x]" : "[ ]"
            print("  \(mark) \(pad(file.bytes.formattedBytes, 10)) \(pad(file.kind.label, 20)) \((file.path as NSString).abbreviatingWithTildeInPath)")
            if let note = file.note { print("        \(note)") }
        }
        let casks = Dictionary(apps.compactMap { app in app.caskToken.map { (app.path.lowercased(), $0) } }) { first, _ in first }
        if let refusal = await uninstaller.refusal(for: app) ?? Uninstaller.caskRefusal(for: app, casks: casks) {
            print("\n⚠︎ \(refusal)")
        }
        print("\nDry run. Would move \(picked.count) items (\(picked.reduce(0) { $0 + $1.bytes }.formattedBytes)) to the Trash.")
        print("Re-run with --yes to uninstall\(picked.count < files.count ? ", or add --all to include the unchecked items" : "").")
        return 0
    }

    let result = await uninstaller.run(app, files: picked) { event in
        guard !args.json, case let .finished(item) = event else { return }
        eprint("  \(item.status.rawValue): \(item.title) — \(item.message)")
    }
    record(.cleanup(CleanupRecord(result, auto: false, uninstalled: app.name)))
    if args.json {
        printJSON(result)
    } else {
        print("\nRemoved \(result.cleanedCount)/\(result.items.count) items of \(app.name). Free space changed by \(result.measuredBytes.formattedBytes).")
        for note in result.explanations { print("  • \(note)") }
        if result.items.contains(where: { $0.trashedPaths != nil }) { print("  • Put them back from the Trash, or from History in the app.") }
    }
    return result.hasFailures ? 1 : 0
}

func summarize(_ report: ScanReport, level: Level) {
    let disk = report.disk
    print("Disk: \(disk.freeBytes.formattedBytes) free of \(disk.totalBytes.formattedBytes) (\(Int(disk.usedFraction * 100))% used)")
    printTable(report.candidates, level: level)
    let selected = report.candidates.filter { $0.isDefaultSelected(at: level) }
    print("\nPre-selected at \(level.label): \(selected.count) items, \(selected.dedupedBytes.formattedBytes) (estimate)")
    for insight in report.insights {
        print("\nⓘ \(insight.title)\(insight.bytes.map { " — \($0.formattedBytes)" } ?? "")\n  \(insight.detail)")
    }
    for (rule, error) in report.ruleErrors.sorted(by: { $0.key < $1.key }) {
        print("\n⚠︎ \(rule): \(error)")
    }
    print(String(format: "\nScan took %.0fs. Nothing was changed.", report.finishedAt.timeIntervalSince(report.startedAt)))
}

func runDisk(_ args: Args) -> Int32 {
    let hook = args.warnBelow != nil
    var threshold: Int64?
    if let raw = args.warnBelow {
        guard let parsed = ByteSize.parse(raw) else {
            eprint("arin disk: can't read the size \(raw); use a value such as 20GiB or 500GB")
            return 0
        }
        threshold = parsed
    }
    let status = Disk.status()
    guard status.totalBytes > 0 else {
        eprint("arin disk: couldn't read free space on your home folder's volume")
        return hook ? 0 : 1
    }
    if let threshold {
        if status.freeBytes < threshold {
            print("Low disk space: \(status.freeBytes.formattedBytes) free on the volume that holds your home folder, below \(threshold.formattedBytes). Run `arin scan` to see what can be reclaimed safely.")
        }
        return 0
    }
    if args.json {
        printJSON(status)
    } else {
        print("\(status.freeBytes.formattedBytes) free of \(status.totalBytes.formattedBytes) (\(Int(status.usedFraction * 100))% used)")
    }
    return 0
}

func main() async -> Int32 {
    let args: Args
    do { args = try Args(Array(CommandLine.arguments.dropFirst())) } catch {
        eprint("\(error)\n\n\(usage)")
        return 2
    }
    if args.command != "keep", let extra = args.positional.dropFirst(args.command == "uninstall" ? 1 : 0).first {
        eprint("unknown argument \(extra)\n\n\(usage)")
        return 2
    }
    switch args.command {
    case "scan":
        let report = await scan(args)
        if args.json { printJSON(report) } else { summarize(report, level: args.level) }
        return 0

    case "review":
        guard let agent = args.agent ?? AgentProvider.installed.first else {
            eprint("No supported agent CLI found (claude, codex, or copilot).")
            return 1
        }
        var report = await scan(args)
        if !args.json {
            let setup = [args.model ?? agent.defaultModel, args.effort ?? agent.defaultEffort].compactMap { $0 }.filter { !$0.isEmpty }
            eprint("Asking \(agent.label)\(setup.isEmpty ? "" : " (\(setup.joined(separator: ", ")))") to review up to \(args.limit) candidates (read-only)…")
        }
        do {
            let reviewer = AgentReviewer(
                provider: agent,
                model: args.model ?? agent.defaultModel,
                effort: args.effort ?? agent.defaultEffort,
                maxCandidates: args.limit
            )
            let verdicts = try await reviewer.review(report.candidates)
            report.candidates = report.candidates.applying(verdicts)
            if !args.json { eprint("  \(verdicts.count) verdicts") }
        } catch {
            eprint("Review failed: \(error)")
            return 1
        }
        if args.json { printJSON(report) } else { summarize(report, level: args.level) }
        return 0

    case "plan":
        let report = await scan(args)
        guard let items = chosen(report, args) else {
            eprint("No plan was written.")
            return 2
        }
        do {
            let data = try CleanupPlan(items).encoded()
            if let out = args.out {
                try data.write(to: URL(fileURLWithPath: out), options: .atomic)
                print("Saved a plan of \(items.count) items (\(items.dedupedBytes.formattedBytes) estimate) to \(out).")
                print("Run it with: arin clean --plan \(out) --yes")
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
        } catch {
            eprint("Could not write the plan: \(error.localizedDescription)")
            return 1
        }
        return 0

    case "keep":
        return runKeep(args)

    case "history":
        printHistory(json: args.json)
        return 0

    case "skill":
        print(agentSkill)
        return 0

    case "disk":
        return runDisk(args)

    case "apps":
        let apps = await installedApps()
        if args.json {
            printJSON(apps)
        } else {
            for app in apps {
                let source = app.caskToken.map { "brew: \($0)" } ?? (app.fromAppStore ? "App Store" : "")
                print("\(pad(app.name, 32)) \(pad(app.version ?? "", 14)) \(pad(source, 22)) \(app.bundleID)")
            }
            print("\n\(apps.count) apps. Apple's apps aren't listed. Uninstall one with: arin uninstall NAME")
        }
        return 0

    case "uninstall":
        return await runUninstall(args)

    case "clean":
        var plan: CleanupPlan?
        if let path = args.plan {
            do { plan = try CleanupPlan.load(from: URL(fileURLWithPath: path)) } catch {
                eprint("Could not read the plan: \(error)")
                return 1
            }
        }
        let report = await scan(args)
        var picked: [Candidate]
        if let plan {
            let resolved = plan.resolve(against: report.candidates)
            if let ids = args.ids {
                let planned = Set(plan.items.map(\.id))
                let ready = Set(resolved.ready.map(\.id))
                let unplanned = ids.filter { !planned.contains($0) }
                let notReady = ids.filter { planned.contains($0) && !ready.contains($0) }
                guard unplanned.isEmpty, notReady.isEmpty else {
                    for id in unplanned { eprint("  not in the plan: \(id)") }
                    for (item, reason) in resolved.refused where notReady.contains(item.id) {
                        eprint("  refused: \(item.title) — \(reason)")
                    }
                    eprint("Nothing was cleaned.")
                    return 2
                }
                picked = resolved.ready.filter { ids.contains($0.id) }
            } else {
                picked = resolved.ready
            }
            for (item, reason) in resolved.refused where args.ids?.contains(item.id) ?? true {
                eprint("  refused: \(item.title) — \(reason)")
            }
        } else if let selection = chosen(report, args) {
            picked = selection
        } else {
            eprint("Nothing was cleaned.")
            return 2
        }
        guard !picked.isEmpty else {
            print("Nothing to clean.")
            return 0
        }
        guard args.yes else {
            print("Dry run. Would clean \(picked.count) items (\(picked.dedupedBytes.formattedBytes) estimate):")
            for c in picked { print("  \(pad(c.bytes.formattedBytes, 10)) \(c.title)\n             \(c.action.summary)") }
            print("\nRe-run with --yes to clean.")
            return 0
        }
        let executor = Executor(trashInsteadOfDelete: args.trash)
        let result = await executor.run(picked) { event in
            guard !args.json, case let .finished(item) = event else { return }
            eprint("  \(item.status.rawValue): \(item.title) — \(item.message)")
        }
        record(.cleanup(CleanupRecord(result, auto: false)))
        if args.json {
            printJSON(result)
        } else {
            print("\nCleaned \(result.cleanedCount)/\(result.items.count). Estimated \(result.estimatedBytes.formattedBytes); free space changed by \(result.measuredBytes.formattedBytes) (\(result.freeBefore.formattedBytes) → \(result.freeAfter.formattedBytes)).")
            for note in result.explanations { print("  • \(note)") }
        }
        return result.hasFailures ? 1 : 0

    default:
        print(usage)
        return args.command == "help" ? 0 : 2
    }
}

exit(await main())

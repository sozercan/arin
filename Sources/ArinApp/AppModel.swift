import ArinCore
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning(String)
        case reviewing(String)
        case cleaning(done: Int, total: Int, current: String)

        var isBusy: Bool { self != .idle }

        var label: String {
            switch self {
            case .idle: ""
            case let .scanning(s): "Scanning… \(s)"
            case let .reviewing(s): s
            case let .cleaning(done, total, current): "Cleaning \(done + 1) of \(total): \(current)"
            }
        }
    }

    enum SidebarItem: Hashable {
        case all
        case category(CleanupCategory)
        case map
        case insights
        case history
    }

    // MARK: State

    var disk = Disk.status()
    var report: ScanReport?
    var candidates: [Candidate] = []
    var selection = Set<String>()
    var phase = Phase.idle
    var sidebar: SidebarItem? = .all
    var lastCleanup: CleanupReport?
    var showingConfirm = false
    var showingResult = false
    var errorMessage: String?
    /// Items the user never wants cleaned. Nil when the file can't be read; see `keepListError`.
    var keepList: KeepList?
    var keepListError: String?
    var historyEntries: [HistoryEntry] = []
    var launchAtLogin = false
    var launchAtLoginNeedsApproval = false
    private let history = History()

    // MARK: Settings

    var level: Level {
        didSet {
            defaults.set(level.rawValue, forKey: "level")
            resetSelection()
        }
    }

    var agent: AgentProvider? {
        didSet { defaults.set(agent?.rawValue, forKey: "agent") }
    }

    var lowSpaceThresholdGB: Int {
        didSet { defaults.set(lowSpaceThresholdGB, forKey: "lowSpaceThresholdGB") }
    }

    var autoMode: Bool {
        didSet { defaults.set(autoMode, forKey: "autoMode") }
    }

    /// Run the agent review right after each manual scan.
    var autoReview: Bool {
        didSet { defaults.set(autoReview, forKey: "autoReview") }
    }

    var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") }
    }

    var trashInsteadOfDelete: Bool {
        didSet { defaults.set(trashInsteadOfDelete, forKey: "trashInsteadOfDelete") }
    }

    var checkPullRequests: Bool {
        didSet { defaults.set(checkPullRequests, forKey: "checkPullRequests") }
    }

    var fetchRemotes: Bool {
        didSet { defaults.set(fetchRemotes, forKey: "fetchRemotes") }
    }

    var extraProjectRoots: [String] {
        didSet { defaults.set(extraProjectRoots, forKey: "extraProjectRoots") }
    }

    /// Per agent; an empty model means the CLI's own default.
    var reviewModels: [String: String] {
        didSet { defaults.set(reviewModels, forKey: "reviewModels") }
    }

    var reviewEfforts: [String: String] {
        didSet { defaults.set(reviewEfforts, forKey: "reviewEfforts") }
    }

    let installedAgents = AgentProvider.installed
    private let defaults = UserDefaults.standard
    private var monitor: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var editedDuringReview = Set<String>()
    var lastReview: (agent: String, date: Date)?
    private var notifiedLowSpace = false
    private var lastAutoClean: Date?

    init() {
        level = Level(rawValue: defaults.object(forKey: "level") as? Int ?? 1) ?? .standard
        agent = (defaults.string(forKey: "agent").flatMap(AgentProvider.init(rawValue:))) ?? AgentProvider.installed.first
        lowSpaceThresholdGB = defaults.object(forKey: "lowSpaceThresholdGB") as? Int ?? 25
        autoMode = defaults.bool(forKey: "autoMode")
        autoReview = defaults.object(forKey: "autoReview") as? Bool ?? true
        sortOrder = defaults.string(forKey: "sortOrder").flatMap(SortOrder.init(rawValue:)) ?? .size
        trashInsteadOfDelete = defaults.bool(forKey: "trashInsteadOfDelete")
        checkPullRequests = defaults.object(forKey: "checkPullRequests") as? Bool ?? true
        fetchRemotes = defaults.bool(forKey: "fetchRemotes")
        extraProjectRoots = defaults.stringArray(forKey: "extraProjectRoots") ?? []
        var models = defaults.dictionary(forKey: "reviewModels") as? [String: String] ?? [:]
        var efforts = defaults.dictionary(forKey: "reviewEfforts") as? [String: String] ?? [:]
        for provider in AgentProvider.allCases {
            if models[provider.rawValue] == nil { models[provider.rawValue] = provider.defaultModel ?? "" }
            if efforts[provider.rawValue] == nil { efforts[provider.rawValue] = provider.defaultEffort }
        }
        reviewModels = models
        reviewEfforts = efforts
        reloadKeepList()
        historyEntries = history.load()
        refreshLaunchAtLogin()
        requestNotificationPermission()
        startMonitor()
        // `open Arin.app --args -ScanOnLaunch YES` starts a scan right away.
        if defaults.bool(forKey: "ScanOnLaunch") {
            startScan()
        }
    }

    // MARK: Derived

    var lowSpaceThreshold: Int64 { Int64(lowSpaceThresholdGB) * 1_000_000_000 }
    var isLowOnSpace: Bool { disk.freeBytes < lowSpaceThreshold }

    var selectedCandidates: [Candidate] { candidates.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.dedupedBytes }

    func candidates(for item: SidebarItem?) -> [Candidate] {
        switch item {
        case .all, nil: candidates
        case let .category(category): candidates.filter { $0.category == category }
        case .map, .insights, .history: []
        }
    }

    func bytes(for category: CleanupCategory) -> Int64 {
        candidates.filter { $0.category == category }.dedupedBytes
    }

    var categoriesWithResults: [CleanupCategory] {
        CleanupCategory.allCases.filter { c in candidates.contains { $0.category == c } }
    }

    var scanOptions: ScanOptions {
        let defaultsRoots = ScanOptions.defaultProjectRoots(home: NSHomeDirectory())
        let extra = extraProjectRoots.map { ($0 as NSString).expandingTildeInPath }.filter { FileManager.default.fileExists(atPath: $0) }
        return ScanOptions(
            projectRoots: defaultsRoots + extra,
            checkPullRequests: checkPullRequests,
            fetchRemotes: fetchRemotes
        )
    }

    // MARK: Actions

    func refreshDisk() {
        disk = Disk.status()
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var isReviewing: Bool {
        if case .reviewing = phase { return true }
        return false
    }

    /// Scans and reviews can be stopped; cleaning runs to completion.
    var canStop: Bool { isScanning || isReviewing }

    func startScan() {
        guard !phase.isBusy else { return }
        work = Task {
            await scan()
            if autoReview, !Task.isCancelled { await review() }
        }
    }

    func startReview() {
        guard !phase.isBusy else { return }
        work = Task { await review() }
    }

    /// Cancels the scan or review and its subprocesses; previous results stay as they were.
    func stop() {
        work?.cancel()
    }

    func scan() async {
        guard !phase.isBusy else { return }
        phase = .scanning("starting")
        let scanner = Scanner(options: scanOptions)
        let report = await scanner.scan { [weak self] event in
            guard case let .ruleFinished(name, _) = event else { return }
            Task { @MainActor in
                if case .scanning = self?.phase { self?.phase = .scanning(name) }
            }
        }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        // A verdict judged a folder's contents at review time, and contents change. Carry over only
        // verdicts that add caution; a stale "safe" must never pre-select new data.
        let previous = Dictionary(uniqueKeysWithValues: candidates.compactMap { c in
            c.agentVerdict.flatMap { $0.risk > c.risk ? (c.id, $0) : nil }
        })
        self.report = report
        lastReview = nil
        candidates = report.candidates.applying(previous)
        disk = report.disk
        reloadKeepList()
        resetSelection()
        appendHistory(.scan(ScanRecord(report, ruleNames: Catalog.ruleNames)))
        phase = .idle
    }

    /// Items the rules couldn't settle: anything not rule-safe, and everything unclassified.
    /// Rule-safe caches don't need an agent, which keeps reviews quick and cheap.
    var itemsNeedingReview: [Candidate] {
        candidates.filter { $0.isActionable && !$0.kept && ($0.risk != .safe || $0.category == .unclassified) }
    }

    func review() async {
        guard let agent, !phase.isBusy else { return }
        let items = itemsNeedingReview
        guard !items.isEmpty else { return }
        editedDuringReview = []
        phase = .reviewing("\(agent.label) is checking \(min(items.count, 150)) items (read-only)…")
        do {
            let reviewer = AgentReviewer(
                provider: agent,
                model: reviewModels[agent.rawValue],
                effort: reviewEfforts[agent.rawValue]
            )
            let verdicts = try await reviewer.review(items)
            if !Task.isCancelled {
                candidates = candidates.applying(verdicts)
                // Only reviewed items change selection, and never ones the user changed meanwhile.
                for candidate in candidates where verdicts[candidate.id] != nil && !editedDuringReview.contains(candidate.id) {
                    if candidate.isDefaultSelected(at: level) {
                        selection.insert(candidate.id)
                    } else {
                        selection.remove(candidate.id)
                    }
                }
                lastReview = (agent.label, Date())
            }
        } catch {
            if !Task.isCancelled { errorMessage = "\(error)" }
        }
        phase = .idle
    }

    func resetSelection() {
        selection = Set(candidates.filter { $0.isDefaultSelected(at: level) }.map(\.id))
    }

    func toggle(_ candidate: Candidate) {
        guard !candidate.kept || selection.contains(candidate.id) else { return }
        if selection.contains(candidate.id) { selection.remove(candidate.id) } else { selection.insert(candidate.id) }
        if isReviewing { editedDuringReview.insert(candidate.id) }
    }

    func setAll(_ items: [Candidate], selected: Bool) {
        for item in items where item.isActionable && (!item.kept || !selected) {
            if selected { selection.insert(item.id) } else { selection.remove(item.id) }
            if isReviewing { editedDuringReview.insert(item.id) }
        }
    }

    func clean() async {
        await clean(selectedCandidates, auto: false)
    }

    private func clean(_ items: [Candidate], auto: Bool) async {
        guard !items.isEmpty, !phase.isBusy else { return }
        let total = items.count
        phase = .cleaning(done: 0, total: total, current: items[0].title)
        let executor = Executor(trashInsteadOfDelete: trashInsteadOfDelete)
        let result = await executor.run(items) { [weak self] event in
            guard case let .item(index, title) = event else { return }
            Task { @MainActor in self?.phase = .cleaning(done: index, total: total, current: title) }
        }
        lastCleanup = result
        appendHistory(.cleanup(CleanupRecord(result, auto: auto)))
        let cleanedIDs = Set(result.items.filter { $0.status == .cleaned }.map(\.id))
        candidates.removeAll { cleanedIDs.contains($0.id) }
        selection.subtract(cleanedIDs)
        refreshDisk()
        phase = .idle
        if auto {
            notify(
                title: "Arin freed \(max(result.measuredBytes, 0).formattedBytes)",
                body: "Auto mode cleaned \(result.cleanedCount) cache items. \(disk.freeBytes.formattedBytes) free."
            )
        } else {
            showingResult = true
        }
    }

    // MARK: Keep list

    func reloadKeepList() {
        do {
            keepList = try KeepList.load()
            keepListError = nil
        } catch {
            keepList = nil
            keepListError = "\(error)"
        }
    }

    func isKept(_ id: String) -> Bool { keepList?.contains(id) ?? false }

    /// Adds or removes an item from the keep list, and updates the current results to match.
    func setKept(_ id: String, title: String, _ kept: Bool) {
        reloadKeepList()
        guard var list = keepList else {
            errorMessage = keepListError
            return
        }
        if kept { list.add(id: id, title: title) } else { list.remove(id: id) }
        do {
            try list.save()
            keepList = list
        } catch {
            errorMessage = "Could not save the keep list: \(error.localizedDescription)"
            return
        }
        for index in candidates.indices where candidates[index].id == id {
            candidates[index].kept = kept
        }
        if kept { selection.remove(id) }
    }

    // MARK: History

    private func appendHistory(_ entry: HistoryEntry) {
        do {
            try history.append(entry)
        } catch {
            // History is a convenience; a write failure never blocks scanning or cleaning.
        }
        historyEntries = history.load()
    }

    var scanRecords: [ScanRecord] { History.scans(historyEntries) }
    var cleanupRecords: [CleanupRecord] { History.cleanups(historyEntries) }

    /// Growth from the previous scan to the latest one.
    var growthSinceLastScan: (since: Date, items: [Growth])? {
        let scans = scanRecords
        guard scans.count >= 2 else { return nil }
        return (scans[scans.count - 2].date, History.growth(from: scans[scans.count - 2], to: scans[scans.count - 1]))
    }

    func putBack(_ item: TrashedPath) {
        do {
            try item.putBack()
        } catch {
            errorMessage = (error as? StoreError)?.description ?? "Could not put it back: \(error.localizedDescription)"
        }
        // Re-render so the button disappears.
        historyEntries = history.load()
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        guard canNotify else { return }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard canNotify else {
            errorMessage = "Launch at login needs the app bundle. Build it with Scripts/build-app.sh."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    // MARK: Monitoring

    private func startMonitor() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func tick() async {
        refreshDisk()
        guard isLowOnSpace else {
            notifiedLowSpace = false
            return
        }
        if autoMode, !phase.isBusy, lastAutoClean.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            lastAutoClean = Date()
            // Tracked as `work` so Stop cancels it; cancellation and Auto mode are rechecked before cleaning.
            let task = Task {
                await scan()
                guard !Task.isCancelled, autoMode, isLowOnSpace else { return }
                // Auto mode only touches caches that refill on their own, never projects or worktrees.
                let autoCategories: Set<CleanupCategory> = [.devCaches, .temp, .xcode, .toolVersions]
                let items = candidates.filter {
                    $0.isDefaultSelected(at: .quick) && autoCategories.contains($0.category) && $0.level == .quick
                }
                await clean(items, auto: true)
            }
            work = task
            await task.value
            return
        }
        if !notifiedLowSpace {
            notifiedLowSpace = true
            notify(
                title: "Your disk is almost full",
                body: "\(disk.freeBytes.formattedBytes) free. Open Arin to see what's safe to remove."
            )
        }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case size, name, safety, modified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .safety: "Safety"
        case .modified: "Last Modified"
        }
    }

    func sorted(_ items: [Candidate]) -> [Candidate] {
        switch self {
        case .size:
            items.sorted { $0.bytes > $1.bytes }
        case .name:
            items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .safety:
            items.sorted { ($0.effectiveRisk, -$0.bytes) < ($1.effectiveRisk, -$1.bytes) }
        case .modified:
            items.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        }
    }
}

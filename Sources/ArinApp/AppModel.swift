import ArinCore
import Foundation
import Observation
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
        case insights
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
    private var scanTask: Task<Void, Never>?
    private var notifiedLowSpace = false
    private var lastAutoClean: Date?

    init() {
        level = Level(rawValue: defaults.object(forKey: "level") as? Int ?? 1) ?? .standard
        agent = (defaults.string(forKey: "agent").flatMap(AgentProvider.init(rawValue:))) ?? AgentProvider.installed.first
        lowSpaceThresholdGB = defaults.object(forKey: "lowSpaceThresholdGB") as? Int ?? 25
        autoMode = defaults.bool(forKey: "autoMode")
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
        case .insights: []
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

    func startScan() {
        guard !phase.isBusy else { return }
        scanTask = Task { await scan() }
    }

    /// Cancels the scan and its subprocesses; previous results stay as they were.
    func stopScan() {
        scanTask?.cancel()
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
        // Keep agent verdicts from a previous review for items that still exist.
        let previous = Dictionary(uniqueKeysWithValues: candidates.compactMap { c in c.agentVerdict.map { (c.id, $0) } })
        self.report = report
        candidates = report.candidates.applying(previous)
        disk = report.disk
        resetSelection()
        phase = .idle
    }

    func review() async {
        guard let agent, !phase.isBusy else { return }
        if candidates.isEmpty { await scan() }
        phase = .reviewing("\(agent.label) is reviewing \(min(candidates.count, 150)) items (read-only)…")
        do {
            let reviewer = AgentReviewer(
                provider: agent,
                model: reviewModels[agent.rawValue],
                effort: reviewEfforts[agent.rawValue]
            )
            let verdicts = try await reviewer.review(candidates)
            candidates = candidates.applying(verdicts)
            resetSelection()
        } catch {
            errorMessage = "\(error)"
        }
        phase = .idle
    }

    func resetSelection() {
        selection = Set(candidates.filter { $0.isDefaultSelected(at: level) }.map(\.id))
    }

    func toggle(_ candidate: Candidate) {
        if selection.contains(candidate.id) { selection.remove(candidate.id) } else { selection.insert(candidate.id) }
    }

    func setAll(_ items: [Candidate], selected: Bool) {
        for item in items where item.isActionable {
            if selected { selection.insert(item.id) } else { selection.remove(item.id) }
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
            await scan()
            // Auto mode only touches caches that refill on their own, never projects or worktrees.
            let autoCategories: Set<CleanupCategory> = [.devCaches, .temp, .xcode, .toolVersions]
            let items = candidates.filter {
                $0.isDefaultSelected(at: .quick) && autoCategories.contains($0.category) && $0.level == .quick
            }
            await clean(items, auto: true)
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

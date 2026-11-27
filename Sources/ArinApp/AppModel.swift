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
        case uninstalling(String)

        var isBusy: Bool { self != .idle }

        var label: String {
            switch self {
            case .idle: ""
            case let .scanning(s): "Scanning… \(s)"
            case let .reviewing(s): s
            case let .cleaning(done, total, current): "Cleaning \(done + 1) of \(total): \(current)"
            case let .uninstalling(name): "Uninstalling \(name)…"
            }
        }
    }

    enum Mailbox: String, CaseIterable, Hashable {
        case review, safe, kept

        var title: String {
            switch self {
            case .review: "Needs a Look"
            case .safe: "Safe to Clean"
            case .kept: "Kept"
            }
        }

        var symbol: String {
            switch self {
            case .review: "tray.full"
            case .safe: "checkmark.seal"
            case .kept: "lock"
            }
        }
    }

    enum SidebarItem: Hashable {
        case inbox(Mailbox)
        case all
        case map
        case insights
        case history
        case apps
    }


    var disk = Disk.status()
    var target: CleanupTarget = .local
    var remoteHosts: [RemoteHost] = [] {
        didSet { saveRemoteHosts() }
    }
    var report: ScanReport?
    var candidates: [Candidate] = []
    var selection = Set<String>()
    var phase = Phase.idle
    var sidebar: SidebarItem? = .inbox(.review)
    var openedIDs = Set<String>()
    var pendingClean: Set<String>?
    var lastCleanup: CleanupReport?
    var lastCleanupTitle: String?
    var showingConfirm = false
    var showingResult = false
    var errorMessage: String?
    var searchText = ""
    var keepList: KeepList?
    var keepListError: String?
    var historyEntries: [HistoryEntry] = []
    var launchAtLogin = false
    var launchAtLoginNeedsApproval = false
    private let history = History()


    var level: Level {
        didSet {
            defaults.set(level.rawValue, forKey: "level")
            resetSelection()
        }
    }

    var agent: AgentProvider? {
        didSet { defaults.set(agent?.rawValue ?? Self.noAgent, forKey: "agent") }
    }

    private static let noAgent = "none"

    var lowSpaceThresholdGB: Int {
        didSet { defaults.set(lowSpaceThresholdGB, forKey: "lowSpaceThresholdGB") }
    }

    var autoMode: Bool {
        didSet { defaults.set(autoMode, forKey: "autoMode") }
    }

    var autoReview: Bool {
        didSet { defaults.set(autoReview, forKey: "autoReview") }
    }

    var sortColumn: SortColumn {
        didSet { defaults.set(sortColumn.rawValue, forKey: "sortOrder") }
    }

    var sortAscending: Bool {
        didSet { defaults.set(sortAscending, forKey: "sortAscending") }
    }

    var showingInspector: Bool {
        didSet { defaults.set(showingInspector, forKey: "showingInspector") }
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

    var agentHistoryDays: Int {
        didSet { defaults.set(agentHistoryDays, forKey: "agentHistoryDays") }
    }

    var extraProjectRoots: [String] {
        didSet { defaults.set(extraProjectRoots, forKey: "extraProjectRoots") }
    }

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
        let savedAgent = defaults.string(forKey: "agent")
        agent = savedAgent == Self.noAgent ? nil : savedAgent.flatMap(AgentProvider.init(rawValue:)) ?? AgentProvider.installed.first
        lowSpaceThresholdGB = defaults.object(forKey: "lowSpaceThresholdGB") as? Int ?? 25
        autoMode = defaults.bool(forKey: "autoMode")
        autoReview = defaults.object(forKey: "autoReview") as? Bool ?? true
        let column = defaults.string(forKey: "sortOrder").flatMap(SortColumn.init(rawValue:)) ?? .size
        sortColumn = column
        showingInspector = defaults.bool(forKey: "showingInspector")
        sortAscending = defaults.object(forKey: "sortAscending") as? Bool ?? [.name, .safety].contains(column)
        trashInsteadOfDelete = defaults.bool(forKey: "trashInsteadOfDelete")
        checkPullRequests = defaults.object(forKey: "checkPullRequests") as? Bool ?? true
        fetchRemotes = defaults.bool(forKey: "fetchRemotes")
        let savedDays = defaults.integer(forKey: "agentHistoryDays")
        agentHistoryDays = ScanOptions.agentHistoryDayChoices.contains(savedDays) ? savedDays : 0
        extraProjectRoots = defaults.stringArray(forKey: "extraProjectRoots") ?? []
        if let data = defaults.data(forKey: "remoteHosts"),
           let saved = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            remoteHosts = saved
        }
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
        if defaults.bool(forKey: "ScanOnLaunch") {
            startScan()
        }
    }


    var lowSpaceThreshold: Int64 { Int64(lowSpaceThresholdGB) * 1_000_000_000 }
    var isLowOnSpace: Bool { disk.freeBytes < lowSpaceThreshold }

    var selectedCandidates: [Candidate] { candidates.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedCandidates.dedupedBytes }

    func candidates(for item: SidebarItem?) -> [Candidate] {
        switch item {
        case .all, nil: candidates
        case let .inbox(box): candidates(in: box)
        case .map, .insights, .history, .apps: []
        }
    }

    func mailbox(of candidate: Candidate) -> Mailbox {
        if candidate.effectiveRisk == .keep { return .kept }
        return candidate.isDefaultSelected(at: level) ? .safe : .review
    }

    func candidates(in box: Mailbox) -> [Candidate] {
        candidates.filter { mailbox(of: $0) == box }.sorted { $0.bytes > $1.bytes }
    }

    var unreadCount: Int {
        candidates(in: .review).filter { !openedIDs.contains($0.id) }.count
    }

    func confirmClean(_ items: [Candidate]) {
        let ids = Set(items.filter { $0.isActionable && !$0.kept }.map(\.id))
        guard !ids.isEmpty, !phase.isBusy else { return }
        pendingClean = ids
        showingConfirm = true
    }

    var itemsToClean: [Candidate] {
        guard let ids = pendingClean else { return selectedCandidates }
        return candidates.filter { ids.contains($0.id) }
    }

    func bytes(for category: CleanupCategory) -> Int64 {
        candidates.filter { $0.category == category }.dedupedBytes
    }

    var sidebarTitle: String {
        switch sidebar {
        case .all, nil: "All Items"
        case let .inbox(box): box.title
        case .map: "Space Map"
        case .insights: "Insights"
        case .history: "History"
        case .apps: "Applications"
        }
    }

    var visibleCandidates: [Candidate] {
        if sidebar == .map { return candidates }
        let items = candidates(for: sidebar)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedStandardContains(query)
                || item.category.label.localizedStandardContains(query)
                || item.paths.contains { $0.localizedStandardContains(query) }
        }
    }

    var canReview: Bool { !target.isRemote && agent != nil && !phase.isBusy && !itemsNeedingReview.isEmpty }
    var canClean: Bool { !phase.isBusy && !selection.isEmpty }

    var categoriesWithResults: [CleanupCategory] {
        CleanupCategory.allCases.filter { c in candidates.contains { $0.category == c } }
    }

    var scanOptions: ScanOptions {
        let defaultsRoots = ScanOptions.defaultProjectRoots(home: NSHomeDirectory())
        let extra = extraProjectRoots.map { ($0 as NSString).expandingTildeInPath }.filter { FileManager.default.fileExists(atPath: $0) }
        return ScanOptions(
            projectRoots: defaultsRoots + extra,
            checkPullRequests: checkPullRequests,
            fetchRemotes: fetchRemotes,
            agentHistoryDays: agentHistoryDays > 0 ? agentHistoryDays : nil
        )
    }


    private func saveRemoteHosts() {
        if let data = try? JSONEncoder().encode(remoteHosts) {
            defaults.set(data, forKey: "remoteHosts")
        }
    }

    var allTargets: [CleanupTarget] {
        [.local] + remoteHosts.map { .remote($0) }
    }

    func selectTarget(_ newTarget: CleanupTarget) {
        guard newTarget != target, !phase.isBusy else { return }
        target = newTarget
        report = nil
        candidates = []
        selection = []
        lastReview = nil
        openedIDs = []
        if sidebar == .apps && newTarget.isRemote {
            sidebar = .inbox(.review)
        }
        if newTarget.isRemote {
            disk = .zero
            if let host = newTarget.remoteHost {
                Task {
                    let status = await RemoteEnvironment.diskStatus(transport: SSHTransport(host: host), home: ".")
                    if target == newTarget { disk = status }
                }
            }
        } else {
            refreshDisk()
        }
    }

    func addRemoteHost(target raw: String, label: String? = nil) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteHost.isValidTarget(trimmed), !remoteHosts.contains(where: { $0.target == trimmed }) else { return }
        let host = RemoteHost(target: trimmed, label: label)
        remoteHosts.append(host)
    }

    func removeRemoteHost(_ host: RemoteHost) {
        guard !phase.isBusy || target != .remote(host) else { return }
        remoteHosts.removeAll { $0.target == host.target }
        if target == .remote(host) {
            selectTarget(.local)
        }
    }

    func refreshDisk() {
        if case let .remote(host) = target {
            Task {
                let status = await RemoteEnvironment.diskStatus(transport: SSHTransport(host: host), home: ".")
                if target == .remote(host) { disk = status }
            }
        } else {
            disk = Disk.status()
        }
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var isReviewing: Bool {
        if case .reviewing = phase { return true }
        return false
    }

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

    func stop() {
        work?.cancel()
    }

    func scan() async {
        guard !phase.isBusy else { return }
        let activeTarget = target
        phase = .scanning(activeTarget.isRemote ? "connecting to \(activeTarget.displayName)" : "starting")
        let report: ScanReport
        if case let .remote(host) = activeTarget {
            let scanner = RemoteScanner(host: host)
            report = await scanner.scan { [weak self] event in
                guard case let .ruleFinished(name, _) = event else { return }
                Task { @MainActor in
                    if case .scanning = self?.phase { self?.phase = .scanning(name) }
                }
            }
        } else {
            let scanner = Scanner(options: scanOptions)
            report = await scanner.scan { [weak self] event in
                guard case let .ruleFinished(name, _) = event else { return }
                Task { @MainActor in
                    if case .scanning = self?.phase { self?.phase = .scanning(name) }
                }
            }
        }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }
        let previous = Dictionary(uniqueKeysWithValues: candidates.compactMap { c in
            c.agentVerdict.flatMap { $0.risk > c.risk ? (c.id, $0) : nil }
        })
        self.report = report
        lastReview = nil
        openedIDs = []
        candidates = report.candidates.applying(previous)
        disk = report.disk
        reloadKeepList()
        resetSelection()
        appendHistory(.scan(ScanRecord(report, ruleNames: Catalog.ruleNames)))
        phase = .idle
    }

    var itemsNeedingReview: [Candidate] {
        candidates.filter { $0.isActionable && !$0.kept && ($0.risk != .safe || $0.category == .unclassified) }
    }

    func review() async {
        guard !target.isRemote, let agent, !phase.isBusy else { return }
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

    func selectSafe(in items: [Candidate]) {
        setAll(items, selected: false)
        setAll(items.filter { $0.isDefaultSelected(at: .deep) }, selected: true)
    }

    func clean(_ items: [Candidate]) async {
        await clean(items, auto: false)
    }

    private func clean(_ items: [Candidate], auto: Bool) async {
        guard !items.isEmpty, !phase.isBusy else { return }
        let total = items.count
        let activeTarget = target
        phase = .cleaning(done: 0, total: total, current: items[0].title)
        let result: CleanupReport
        if case let .remote(host) = activeTarget {
            let executor = RemoteExecutor(host: host, expectedIdentity: report?.remoteIdentity)
            result = await executor.run(items) { [weak self] event in
                guard case let .item(index, title) = event else { return }
                Task { @MainActor in self?.phase = .cleaning(done: index, total: total, current: title) }
            }
        } else {
            let executor = Executor(trashInsteadOfDelete: trashInsteadOfDelete)
            result = await executor.run(items) { [weak self] event in
                guard case let .item(index, title) = event else { return }
                Task { @MainActor in self?.phase = .cleaning(done: index, total: total, current: title) }
            }
        }
        lastCleanup = result
        lastCleanupTitle = nil
        appendHistory(.cleanup(CleanupRecord(result, auto: auto, remoteHost: activeTarget.storageKey)))
        let cleanedIDs = Set(result.items.filter { $0.status == .cleaned }.map(\.id))
        candidates.removeAll { cleanedIDs.contains($0.id) }
        selection.subtract(cleanedIDs)
        for item in result.items where item.status == .partial {
            if let index = candidates.firstIndex(where: { $0.id == item.id }) {
                candidates[index].bytes = max(0, candidates[index].bytes - item.estimatedBytes)
            }
        }
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


    var apps: [InstalledApp] = []
    var appSizes: [String: Int64] = [:]
    var loadingApps = false
    private var sizeTask: Task<Void, Never>?
    var uninstallApp: InstalledApp?
    var uninstallFiles: [AppFile]?
    var uninstallSelection = Set<String>()
    var uninstallRefusal: String?
    private var uninstallRequest = UUID()

    func loadApps() async {
        guard !loadingApps else { return }
        loadingApps = true
        sizeTask?.cancel()
        appSizes = [:]
        let found = await Task.detached { AppCatalog.installed() }.value
        let casks = await AppCatalog.caskTokens()
        apps = found.map { app in
            var app = app
            app.caskToken = casks[app.path.lowercased()]
            return app
        }
        loadingApps = false
        measureApps()
    }

    private func measureApps() {
        sizeTask?.cancel()
        let pending = apps.map(\.path).filter { appSizes[$0] == nil }
        sizeTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int64).self) { group in
                var queue = pending.makeIterator()
                for _ in 0 ..< 4 {
                    guard let path = queue.next() else { break }
                    group.addTask { (path, await Size.allocated(path, timeout: 600)) }
                }
                for await (path, bytes) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    self?.appSizes[path] = bytes
                    if let next = queue.next() { group.addTask { (next, await Size.allocated(next, timeout: 600)) } }
                }
            }
        }
    }

    func prepareUninstall(_ app: InstalledApp) {
        guard !target.isRemote, !phase.isBusy else { return }
        uninstallApp = app
        uninstallFiles = nil
        uninstallSelection = []
        uninstallRefusal = nil
        let request = UUID()
        uninstallRequest = request
        let casks = Dictionary(apps.compactMap { app in app.caskToken.map { (app.path.lowercased(), $0) } }) { first, _ in first }
        Task {
            async let refusal = Uninstaller().refusal(for: app)
            let path = (app.path as NSString).standardizingPath
            let others = await Task.detached { AppCatalog.installed() }.value
                .filter { ($0.path as NSString).standardizingPath != path }
            let files = await AppFiles.find(for: app, others: others)
            let reason = await refusal
            guard uninstallRequest == request else { return }
            uninstallFiles = files
            uninstallSelection = Set(files.filter { !$0.needsReview }.map(\.id))
            uninstallRefusal = reason ?? Uninstaller.caskRefusal(for: app, casks: casks)
        }
    }

    @discardableResult
    func prepareUninstall(url: URL) -> Bool {
        guard !target.isRemote else { return false }
        let path = (url.path as NSString).standardizingPath
        let app = apps.first { ($0.path as NSString).standardizingPath == path }
            ?? (Guardrails().applicationRoots.contains { path.lowercased().hasPrefix($0.lowercased() + "/") } ? AppCatalog.app(at: path) : nil)
        guard let app else {
            errorMessage = "Arin can uninstall apps in /Applications or ~/Applications, except Apple's own apps."
            return false
        }
        prepareUninstall(app)
        return true
    }

    func uninstall(_ app: InstalledApp) {
        guard !target.isRemote, uninstallApp?.path == app.path, let files = uninstallFiles, uninstallRefusal == nil, !phase.isBusy else { return }
        let picked = files.filter { uninstallSelection.contains($0.id) }
        uninstallApp = nil
        guard !picked.isEmpty else { return }
        phase = .uninstalling(app.name)
        Task { await uninstall(app, files: picked) }
    }

    private func uninstall(_ app: InstalledApp, files picked: [AppFile]) async {
        let result = await Uninstaller().run(app, files: picked)
        lastCleanup = result
        let removed = result.items.contains { $0.id == app.path && $0.status == .cleaned }
        lastCleanupTitle = removed ? "Uninstalled \(app.name)" : "\(app.name) wasn't uninstalled"
        appendHistory(.cleanup(CleanupRecord(result, auto: false, uninstalled: app.name)))
        if removed { apps.removeAll { $0.path == app.path } }
        refreshDisk()
        phase = .idle
        showingResult = true
    }


    func reloadKeepList() {
        apply(KeepList.load(recording: report?.keptPaths ?? [:], remoteHost: target.storageKey))
    }

    private func apply(_ result: Result<KeepList, any Error>) {
        switch result {
        case let .success(list):
            keepList = list
            keepListError = nil
        case let .failure(error):
            keepList = nil
            keepListError = "\(error)"
        }
        candidates = candidates.applying(keep: result, remoteHost: target.storageKey)
        if keepList == nil {
            selection = []
        } else {
            let blocked = Set(candidates.filter { $0.kept || $0.blockers.contains { $0.hasSuffix("which you chose to keep") } }.map(\.id))
            selection.subtract(blocked)
        }
    }

    func isKept(_ id: String) -> Bool { keepList?.contains(id) ?? false }

    func setKept(_ id: String, title: String, paths: [String] = [], _ kept: Bool) {
        do {
            let hostKey = target.storageKey
            try KeepList.update { list in
                if kept { list.add(id: id, title: title, paths: paths, remoteHost: hostKey) } else { list.remove(id: id) }
            }
            reloadKeepList()
        } catch {
            errorMessage = "Could not save the keep list: \(error)"
            reloadKeepList()
        }
    }


    private func appendHistory(_ entry: HistoryEntry) {
        do {
            try history.append(entry)
        } catch {
        }
        historyEntries = history.load()
    }

    var scanRecords: [ScanRecord] {
        History.scans(historyEntries).filter { $0.remoteHost == target.storageKey }
    }
    var cleanupRecords: [CleanupRecord] {
        History.cleanups(historyEntries).filter { $0.remoteHost == target.storageKey }
    }

    func putBack(_ item: TrashedPath) {
        do {
            try item.putBack()
        } catch {
            errorMessage = (error as? StoreError)?.description ?? "Could not put it back: \(error.localizedDescription)"
        }
        historyEntries = history.load()
    }


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


    private func startMonitor() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func tick() async {
        guard !target.isRemote else { return }
        refreshDisk()
        let alert = LowSpacePolicy.evaluate(free: disk.freeBytes, threshold: lowSpaceThreshold, alerted: notifiedLowSpace)
        guard isLowOnSpace else {
            notifiedLowSpace = alert.alerted
            return
        }
        if autoMode, !phase.isBusy, lastAutoClean.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            lastAutoClean = Date()
            let task = Task {
                await scan()
                guard !Task.isCancelled, autoMode, isLowOnSpace else { return }
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
        notifiedLowSpace = alert.alerted
        if alert.notify {
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

enum SortColumn: String, CaseIterable {
    case size, name, safety, level, modified

    func comparators(ascending: Bool) -> [KeyPathComparator<Candidate>] {
        let order: SortOrder = ascending ? .forward : .reverse
        let bySize = KeyPathComparator(\Candidate.bytes, order: .reverse)
        switch self {
        case .size: return [KeyPathComparator(\Candidate.bytes, order: order)]
        case .name: return [KeyPathComparator(\Candidate.title, comparator: .localizedStandard, order: order)]
        case .safety: return [KeyPathComparator(\Candidate.effectiveRisk, order: order), bySize]
        case .level: return [KeyPathComparator(\Candidate.level, order: order), bySize]
        case .modified: return [KeyPathComparator(\Candidate.modifiedSortKey, order: order), bySize]
        }
    }

    init?(_ comparator: KeyPathComparator<Candidate>) {
        switch comparator.keyPath {
        case \Candidate.bytes: self = .size
        case \Candidate.title: self = .name
        case \Candidate.effectiveRisk: self = .safety
        case \Candidate.level: self = .level
        case \Candidate.modifiedSortKey: self = .modified
        default: return nil
        }
    }
}

extension Candidate {
    var modifiedSortKey: Date { lastModified ?? .distantPast }
}

import Foundation

/// The rule set. Each entry encodes something learned from real cleanups on developer Macs;
/// see docs/learnings.md for the evidence behind the choices.
public enum Catalog {
    public static var rules: [any Rule] {
        cacheRules + appCacheRules + xcodeRules + [
            TempRule(),
            CodeSignCloneRule(),
            CodexReleasesRule(),
            ClaudeVersionsRule(),
            RustToolchainRule(),
            ProjectArtifactRule(),
            WorktreeRule(),
            DockerRule(),
            SQLiteFreePagesRule(),
            UnclassifiedRule(),
        ]
    }

    public static var insightRules: [any InsightRule] {
        [SnapshotInsightRule(), AgentHistoryInsightRule()]
    }

    static func toolOutput(_ tool: String, _ args: [String]) -> @Sendable (ScanContext) async -> [String] {
        { _ in
            guard Shell.which(tool) != nil else { return [] }
            let result = await Shell.run(tool, args, timeout: 20)
            guard result.ok else { return [] }
            return result.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
        }
    }

    static let cacheRules: [any Rule] = [
        KnownPathRule(
            id: "go.build-cache",
            name: "Go build cache",
            detail: "Compiled packages and test results. Go trims entries unused for ~5 days but has no size cap, so parallel agent worktrees can add 20 GB a day. Next builds are slower once.",
            paths: ["Library/Caches/go-build"],
            resolve: toolOutput("go", ["env", "GOCACHE"]),
            commands: [CommandSpec("go", ["clean", "-cache"])],
            blockingProcesses: ["go"]
        ),
        KnownPathRule(
            id: "go.build-cache-extra",
            name: "Extra Go build cache",
            detail: "A separate GOCACHE created by a one-off run (lint, CI script). Nothing points at it by default.",
            paths: ["Library/Caches/go-build-*"],
            minIdleSeconds: 3 * 3600,
            perPath: true,
            titleForPath: { "Go cache: \(($0 as NSString).lastPathComponent)" }
        ),
        KnownPathRule(
            id: "go.mod-cache",
            name: "Go module cache",
            detail: "Downloaded module sources. Files are read-only, so plain rm fails; `go clean -modcache` handles it. Modules re-download on next build.",
            level: .standard,
            paths: ["go/pkg/mod"],
            resolve: toolOutput("go", ["env", "GOMODCACHE"]),
            commands: [CommandSpec("go", ["clean", "-modcache"])],
            blockingProcesses: ["go", "gopls"]
        ),
        KnownPathRule(
            id: "npm.cache",
            name: "npm cache",
            detail: "Package tarballs npm can re-download.",
            // `npm cache clean` empties npm's configured cache (`cache=` in .npmrc), so that is the
            // path the guardrails must see. If npm can't say where it is, offer nothing.
            resolve: { ctx in
                guard Shell.which("npm") != nil else { return [ctx.path(".npm/_cacache")] }
                let result = await Shell.run("npm", ["config", "get", "cache"], timeout: 20)
                guard result.ok, let dir = result.lines.first?.trimmingCharacters(in: .whitespaces), dir.hasPrefix("/")
                else { return [] }
                return [(dir as NSString).appendingPathComponent("_cacache")]
            },
            commands: [CommandSpec("npm", ["cache", "clean", "--force"])],
            blockingProcesses: ["npm"]
        ),
        KnownPathRule(
            id: "uv.cache",
            name: "uv cache",
            detail: "Python wheels and builds. `uv cache clean` removes everything; uv refills on demand.",
            paths: ["Library/Caches/uv", ".cache/uv"],
            resolve: toolOutput("uv", ["cache", "dir"]),
            commands: [CommandSpec("uv", ["cache", "clean"])],
            blockingProcesses: ["uv"]
        ),
        KnownPathRule(
            id: "brew.cache",
            name: "Homebrew downloads and old versions",
            detail: "`brew cleanup --prune=all` removes downloads and outdated kegs. Installed formulae stay.",
            paths: ["Library/Caches/Homebrew"],
            resolve: toolOutput("brew", ["--cache"]),
            commands: [CommandSpec("brew", ["cleanup", "--prune=all"])],
            blockingProcesses: ["brew"]
        ),
        KnownPathRule(
            id: "pnpm.store",
            name: "pnpm store",
            detail: "`pnpm store prune` frees nothing while deleted projects are still registered, so the store is deleted directly. On APFS pnpm clones files into node_modules, so existing installs keep working.",
            paths: ["Library/pnpm/store"],
            blockingProcesses: ["pnpm"]
        ),
        KnownPathRule(
            id: "bun.cache",
            name: "Bun cache",
            detail: "`bun pm cache rm` only works inside a project, so the cache directories are deleted directly.",
            paths: [".bun/install/cache", "Library/Caches/.bun"],
            blockingProcesses: ["bun"]
        ),
        KnownPathRule(
            id: "yarn.cache",
            name: "Yarn cache",
            detail: "Package archives Yarn can re-download.",
            paths: ["Library/Caches/Yarn", ".yarn/berry/cache"],
            blockingProcesses: ["yarn"]
        ),
        KnownPathRule(
            id: "golangci-lint.cache",
            name: "golangci-lint cache",
            detail: "Lint analysis results; rebuilt on the next lint run.",
            paths: ["Library/Caches/golangci-lint"],
            blockingProcesses: ["golangci-lint"]
        ),
        KnownPathRule(
            id: "trivy.cache",
            name: "Trivy vulnerability database",
            detail: "Re-downloaded on the next scan.",
            paths: ["Library/Caches/trivy", ".cache/trivy"],
            blockingProcesses: ["trivy"]
        ),
        KnownPathRule(
            id: "swiftpm.cache",
            name: "SwiftPM cache",
            detail: "Cloned package repositories. Packages re-download on the next resolve.",
            paths: ["Library/Caches/org.swift.swiftpm"],
            blockingProcesses: ["swift-build", "swift-package"]
        ),
        KnownPathRule(
            id: "pip.cache",
            name: "pip cache",
            detail: "Downloaded wheels.",
            paths: ["Library/Caches/pip"],
            blockingProcesses: ["pip", "pip3"]
        ),
        KnownPathRule(
            id: "cocoapods.cache",
            name: "CocoaPods cache",
            detail: "Downloaded pods.",
            paths: ["Library/Caches/CocoaPods"],
            blockingProcesses: ["pod"]
        ),
        KnownPathRule(
            id: "cargo.registry-cache",
            name: "Cargo registry cache",
            detail: "Downloaded crate archives. Re-downloaded on the next build.",
            level: .standard,
            paths: [".cargo/registry/cache"],
            blockingProcesses: ["cargo"]
        ),
        KnownPathRule(
            id: "gradle.cache",
            name: "Gradle caches",
            detail: "Dependency and build caches. The next build re-downloads.",
            level: .standard,
            paths: [".gradle/caches"],
            blockingProcesses: ["java"]
        ),
        KnownPathRule(
            id: "codex.runtime-installs",
            name: "Leftover Codex runtime installs",
            detail: "Partial install folders. The active `codex-primary-runtime` is not touched.",
            paths: [".cache/codex-runtimes/codex-runtime-install-*"],
            minIdleSeconds: 3600,
            perPath: true,
            titleForPath: { "Codex runtime install: \(($0 as NSString).lastPathComponent)" }
        ),
        KnownPathRule(
            id: "podman.vm-cache",
            name: "Podman VM image caches",
            detail: "Downloaded machine images. Podman re-downloads them when you create a machine.",
            category: .containers,
            paths: [
                ".local/share/containers/podman/machine/applehv/cache",
                ".local/share/containers/podman/machine/libkrun/cache",
                ".local/share/containers/podman/machine/qemu/cache",
            ],
            blockingProcesses: ["podman", "vfkit", "krunkit", "gvproxy"]
        ),
        KnownPathRule(
            id: "playwright.browsers",
            name: "Playwright browsers",
            detail: "You'd need `npx playwright install` before running browser tests again.",
            level: .deep,
            risk: .review,
            paths: ["Library/Caches/ms-playwright"]
        ),
        KnownPathRule(
            id: "huggingface.cache",
            name: "Hugging Face model cache",
            detail: "Downloaded models. Large to re-download.",
            level: .deep,
            risk: .review,
            paths: [".cache/huggingface"]
        ),
    ]

    static let appCacheRules: [any Rule] = [
        KnownPathRule(
            id: "updater.shipit",
            name: "Updater leftovers",
            detail: "Staged app updates (Squirrel ShipIt). Safe once the updater isn't running; it clears itself after an update.",
            category: .appCaches,
            paths: ["Library/Caches/*.ShipIt"],
            blockingProcesses: ["ShipIt"],
            perPath: true,
            titleForPath: { path in
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return "Updater leftovers: \(name)"
            }
        ),
        KnownPathRule(
            id: "browser.chrome",
            name: "Chrome cache",
            detail: "Web cache only. Profiles, cookies, history and passwords are elsewhere. Chrome must be quit.",
            category: .appCaches,
            paths: ["Library/Caches/Google/Chrome"],
            blockingProcesses: ["Google Chrome"]
        ),
        KnownPathRule(
            id: "browser.chrome-canary",
            name: "Chrome Canary cache",
            detail: "Web cache only. Chrome Canary must be quit.",
            category: .appCaches,
            paths: ["Library/Caches/Google/Chrome Canary"],
            blockingProcesses: ["Google Chrome Canary"]
        ),
        KnownPathRule(
            id: "browser.edge",
            name: "Edge cache",
            detail: "Web cache only. Edge must be quit.",
            category: .appCaches,
            paths: ["Library/Caches/Microsoft Edge"],
            blockingProcesses: ["Microsoft Edge"]
        ),
        ElectronCacheRule(),
    ]

    static let xcodeRules: [any Rule] = [
        DerivedDataRule(),
        KnownPathRule(
            id: "xcode.device-support",
            name: "Device support files",
            detail: "Symbols copied from a connected device. Xcode copies them again the next time that device connects.",
            category: .xcode,
            level: .standard,
            paths: [
                "Library/Developer/Xcode/iOS DeviceSupport/*",
                "Library/Developer/Xcode/watchOS DeviceSupport/*",
                "Library/Developer/Xcode/tvOS DeviceSupport/*",
                "Library/Developer/Xcode/visionOS DeviceSupport/*",
            ],
            blockingProcesses: ["Xcode"],
            perPath: true,
            titleForPath: { path in
                let platform = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return "\(platform): \((path as NSString).lastPathComponent)"
            }
        ),
        KnownPathRule(
            id: "xcode.cache",
            name: "Xcode cache",
            detail: "Xcode's own cache. Rebuilt on launch.",
            category: .xcode,
            paths: ["Library/Caches/com.apple.dt.Xcode"],
            blockingProcesses: ["Xcode"]
        ),
        KnownPathRule(
            id: "xcode.archives",
            name: "Xcode archives",
            detail: "Archived builds with their dSYMs. You may need these to symbolicate crash reports from shipped versions.",
            category: .xcode,
            level: .deep,
            risk: .review,
            paths: ["Library/Developer/Xcode/Archives"],
            useTrash: true
        ),
        SimulatorRule(),
        SimulatorRuntimeRule(),
    ]
}

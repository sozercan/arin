import Foundation

public struct RemoteScanner: Sendable {
    public var host: RemoteHost
    public var minimumBytes: Int64
    public var keepListURL: URL?

    public init(
        host: RemoteHost,
        minimumBytes: Int64 = 20 * 1024 * 1024,
        keepListURL: URL? = KeepList.defaultURL
    ) {
        self.host = host
        self.minimumBytes = minimumBytes
        self.keepListURL = keepListURL
    }

    public func scan(progress: (@Sendable (ScanEvent) -> Void)? = nil) async -> ScanReport {
        let started = Date()
        let transport = SSHTransport(host: host)
        progress?(.started(rules: 4))

        let env: RemoteEnvironment
        do {
            env = try await RemoteEnvironment.probe(transport: transport)
        } catch {
            return ScanReport(
                startedAt: started,
                finishedAt: Date(),
                disk: .zero,
                candidates: [],
                insights: [],
                ruleErrors: ["SSH (\(host.target))": "\(error)"],
                keptPaths: [:],
                remoteHost: host.target
            )
        }

        var candidates: [Candidate] = []
        var errors: [String: String] = [:]
        var insights: [Insight] = []

        async let cacheTask = scanKnownCaches(transport: transport, env: env)
        async let dockerTask = scanDocker(transport: transport, env: env)
        async let kindTask = scanKind(transport: transport, env: env)
        async let systemTask = scanSystemInsights(transport: transport, env: env)

        let cacheResult = await cacheTask
        candidates += cacheResult.candidates
        errors.merge(cacheResult.errors) { first, _ in first }
        progress?(.ruleFinished(name: "Remote caches", found: cacheResult.candidates.count))

        let dockerResult = await dockerTask
        candidates += dockerResult.candidates
        errors.merge(dockerResult.errors) { first, _ in first }
        insights += dockerResult.insights
        progress?(.ruleFinished(name: "Remote Docker", found: dockerResult.candidates.count))

        let kindResult = await kindTask
        candidates += kindResult.candidates
        errors.merge(kindResult.errors) { first, _ in first }
        progress?(.ruleFinished(name: "Remote kind clusters", found: kindResult.candidates.count))

        let sysInsights = await systemTask
        insights += sysInsights
        progress?(.ruleFinished(name: "Remote system", found: sysInsights.count))

        if !env.openFilesKnown {
            insights.append(Insight(
                id: "remote-lsof-unavailable",
                title: "Remote open-file check unavailable",
                detail: "lsof did not return results on \(host.target), so path-based items can't be checked for open files. Cleaning skips items with paths until lsof works."
            ))
        }

        let found = Dictionary(candidates.map { ($0.id, $0.paths) }, uniquingKeysWith: { first, _ in first })
        let keep: Result<KeepList, any Error> = keepListURL.map { KeepList.load(from: $0, recording: found) }
            ?? .success(KeepList())
        if case let .failure(error) = keep { errors["Keep list"] = "\(error)" }
        let keptIDs = Set((keepListURL.flatMap { try? KeepList.load(from: $0) }?.entries ?? []).map(\.id))

        let filtered = Scanner.dedupe(candidates)
            .applying(keep: keep)
            .filter { $0.bytes >= minimumBytes || Self.sizeUnknownRules.contains($0.ruleID) }
            .sorted { $0.bytes > $1.bytes }

        return ScanReport(
            startedAt: started,
            finishedAt: Date(),
            disk: env.disk,
            candidates: filtered,
            insights: insights,
            ruleErrors: errors,
            keptPaths: found.filter { keptIDs.contains($0.key) },
            remoteHost: host.target,
            remoteIdentity: env.identity
        )
    }

    static let sizeUnknownRules: Set<String> = ["remote.kind.cluster", "remote.docker.volume"]

    struct RuleOutput: Sendable {
        var candidates: [Candidate] = []
        var errors: [String: String] = [:]
        var insights: [Insight] = []
    }

    struct RemoteCacheSpec: Sendable {
        var id: String
        var title: String
        var detail: String
        var category: CleanupCategory = .devCaches
        var level: Level = .quick
        var risk: Risk = .safe
        var relativePaths: [String]
        var resolveExpr: String?
        var nativeCommand: CommandSpec?
        var blockingProcesses: [String] = []
        var keepNames: [String] = []
    }

    static let cacheSpecs: [RemoteCacheSpec] = [
        RemoteCacheSpec(
            id: "remote.go.build-cache",
            title: "Go build cache",
            detail: "Compiled packages and test results on the remote host. Next builds are slower once.",
            relativePaths: [".cache/go-build"],
            resolveExpr: "go env GOCACHE 2>/dev/null",
            nativeCommand: CommandSpec("go", ["clean", "-cache"]),
            blockingProcesses: ["go"]
        ),
        RemoteCacheSpec(
            id: "remote.go.mod-cache",
            title: "Go module cache",
            detail: "Downloaded module sources. `go clean -modcache` handles read-only module files; modules re-download on next build.",
            level: .standard,
            relativePaths: ["go/pkg/mod"],
            resolveExpr: "go env GOMODCACHE 2>/dev/null",
            nativeCommand: CommandSpec("go", ["clean", "-modcache"]),
            blockingProcesses: ["go", "gopls"]
        ),
        RemoteCacheSpec(
            id: "remote.npm.cache",
            title: "npm cache",
            detail: "Package tarballs npm can re-download.",
            relativePaths: [".npm/_cacache"],
            resolveExpr: "d=$(npm config get cache 2>/dev/null); [ -n \"$d\" ] && echo \"$d/_cacache\"",
            nativeCommand: CommandSpec("npm", ["cache", "clean", "--force"]),
            blockingProcesses: ["npm"]
        ),
        RemoteCacheSpec(
            id: "remote.pip.cache",
            title: "pip cache",
            detail: "Downloaded Python wheels and HTTP cache.",
            relativePaths: [".cache/pip"],
            resolveExpr: "pip cache dir 2>/dev/null",
            nativeCommand: CommandSpec("pip", ["cache", "purge"]),
            blockingProcesses: ["pip", "pip3"]
        ),
        RemoteCacheSpec(
            id: "remote.uv.cache",
            title: "uv cache",
            detail: "Python wheels and builds. `uv cache clean` removes everything; uv refills on demand.",
            relativePaths: [".cache/uv"],
            resolveExpr: "uv cache dir 2>/dev/null",
            nativeCommand: CommandSpec("uv", ["cache", "clean"]),
            blockingProcesses: ["uv"]
        ),
        RemoteCacheSpec(
            id: "remote.yarn.cache",
            title: "Yarn cache",
            detail: "Package archives Yarn can re-download.",
            relativePaths: [".cache/yarn", ".yarn/berry/cache"],
            blockingProcesses: ["yarn"]
        ),
        RemoteCacheSpec(
            id: "remote.pnpm.store",
            title: "pnpm store",
            detail: "Global pnpm content-addressable store. Rebuilt on install.",
            relativePaths: [".local/share/pnpm/store"],
            blockingProcesses: ["pnpm"]
        ),
        RemoteCacheSpec(
            id: "remote.bun.cache",
            title: "Bun cache",
            detail: "Downloaded Bun packages. Keeps `links/` for projects using the global store.",
            relativePaths: [".bun/install/cache"],
            blockingProcesses: ["bun"],
            keepNames: ["links"]
        ),
        RemoteCacheSpec(
            id: "remote.cargo.registry-cache",
            title: "Cargo registry cache",
            detail: "Downloaded crate archives. Re-downloaded on the next build.",
            level: .standard,
            relativePaths: [".cargo/registry/cache"],
            blockingProcesses: ["cargo"]
        ),
        RemoteCacheSpec(
            id: "remote.brew.cache",
            title: "Homebrew downloads and old versions",
            detail: "`brew cleanup --prune=all` removes downloads and outdated kegs. Installed formulae stay.",
            relativePaths: [".cache/Homebrew"],
            resolveExpr: "brew --cache 2>/dev/null",
            nativeCommand: CommandSpec("brew", ["cleanup", "--prune=all"]),
            blockingProcesses: ["brew"]
        ),
        RemoteCacheSpec(
            id: "remote.golangci-lint.cache",
            title: "golangci-lint cache",
            detail: "Lint analysis results; rebuilt on the next lint run.",
            relativePaths: [".cache/golangci-lint"],
            blockingProcesses: ["golangci-lint"]
        ),
        RemoteCacheSpec(
            id: "remote.trivy.cache",
            title: "Trivy vulnerability database",
            detail: "Re-downloaded on the next scan.",
            relativePaths: [".cache/trivy"],
            blockingProcesses: ["trivy"]
        ),
        RemoteCacheSpec(
            id: "remote.gradle.cache",
            title: "Gradle caches",
            detail: "Dependency and build caches. The next build re-downloads.",
            level: .standard,
            relativePaths: [".gradle/caches"],
            blockingProcesses: ["java"]
        ),
        RemoteCacheSpec(
            id: "remote.huggingface.cache",
            title: "Hugging Face model cache",
            detail: "Downloaded models under ~/.cache/huggingface/hub. Saved Hugging Face login tokens are kept. Large to re-download.",
            level: .deep,
            risk: .review,
            relativePaths: [".cache/huggingface/hub"]
        ),
        RemoteCacheSpec(
            id: "remote.playwright.browsers",
            title: "Playwright browsers",
            detail: "You'd need `npx playwright install` before running browser tests again.",
            level: .deep,
            risk: .review,
            relativePaths: [".cache/ms-playwright"]
        ),
    ]

    func scanKnownCaches(transport: SSHTransport, env: RemoteEnvironment) async -> RuleOutput {
        var lines: [String] = []
        for spec in Self.cacheSpecs {
            let block: String
            if let expr = spec.resolveExpr, let cmd = spec.nativeCommand, env.tools.contains(cmd.executable) {
                let dedicatedCheck: String
                if spec.id == "remote.go.mod-cache" {
                    dedicatedCheck = "[ -d \"$p/cache/download\" ] && [ ! -e \"$p/.git\" ] && ! find \"$p\" -maxdepth 1 -mindepth 1 \\( ! -type d -o \\( ! -name cache ! -name '*.*' \\) \\) -print -quit 2>/dev/null | grep -q ."
                } else {
                    dedicatedCheck = "true"
                }
                block = """
                p=$(\(expr) | head -n 1)
                if [ -n "$p" ] && [ -e "$p" ] && \(dedicatedCheck); then
                  sz=$(timeout 12 du -sk -- "$p" 2>/dev/null | awk '{print $1}')
                  mt=$(stat -c %Y -- "$p" 2>/dev/null || stat -f %m -- "$p" 2>/dev/null || echo 0)
                  [ -n "$sz" ] && printf '%s\\t%s\\t%s\\t%s\\n' \(SSHTransport.shellQuote(spec.id)) "$sz" "$mt" "$p"
                fi
                """
            } else {
                var checks: [String] = []
                for rel in spec.relativePaths {
                    let abs = "\(env.home)/\(rel)"
                    checks.append("[ -e \(SSHTransport.shellQuote(abs)) ] && printf '%s\\n' \(SSHTransport.shellQuote(abs))")
                }
                block = """
                { \(checks.joined(separator: "; ")); } | awk '!seen[$0]++' | while IFS= read -r p; do
                  sz=$(timeout 12 du -sk -- "$p" 2>/dev/null | awk '{print $1}')
                  mt=$(stat -c %Y -- "$p" 2>/dev/null || stat -f %m -- "$p" 2>/dev/null || echo 0)
                  [ -n "$sz" ] && printf '%s\\t%s\\t%s\\t%s\\n' \(SSHTransport.shellQuote(spec.id)) "$sz" "$mt" "$p"
                done
                """
            }
            lines.append(block)
        }

        let script = lines.joined(separator: "\n")
        let result = await transport.runScript(script, timeout: 60)
        guard result.ok || !result.stdout.isEmpty else {
            return RuleOutput(errors: ["Remote caches": result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
        }

        let parsed = Self.parseCacheMeasurements(result.stdout)
        let state = env.systemState
        var candidates: [Candidate] = []
        for spec in Self.cacheSpecs {
            guard let items = parsed[spec.id], !items.isEmpty else { continue }
            let paths = items.map(\.path)
            let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
            let modified = items.compactMap(\.modified).max()
            let native: CommandSpec? = spec.nativeCommand.flatMap { cmd in
                env.tools.contains(cmd.executable) ? cmd : nil
            }
            let action: CleanupAction
            if let native {
                action = .commands([native])
            } else {
                action = .delete(paths)
            }
            let blockers = state.blockers(paths: paths, processes: spec.blockingProcesses, minIdle: nil)
            candidates.append(Candidate(
                ruleID: spec.id,
                key: "\(host.target):\(spec.id)",
                title: spec.title,
                detail: spec.detail,
                category: spec.category,
                level: spec.level,
                risk: spec.risk,
                bytes: bytes,
                paths: paths,
                action: action,
                lastModified: modified,
                blockers: blockers,
                blockingProcesses: spec.blockingProcesses
            ))
        }
        return RuleOutput(candidates: candidates)
    }

    struct CacheMeasurement: Sendable {
        var path: String
        var bytes: Int64
        var modified: Date?
    }

    static func parseCacheMeasurements(_ stdout: String) -> [String: [CacheMeasurement]] {
        var result: [String: [CacheMeasurement]] = [:]
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard parts.count == 4,
                  let kb = Int64(parts[1]),
                  parts[3].hasPrefix("/")
            else { continue }
            let ts = TimeInterval(parts[2]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            result[parts[0], default: []].append(CacheMeasurement(path: parts[3], bytes: kb * 1024, modified: ts))
        }
        return result
    }

    func scanDocker(transport: SSHTransport, env: RemoteEnvironment) async -> RuleOutput {
        guard env.tools.contains("docker") else { return RuleOutput() }
        let script = """
        ctx=$(timeout 8 docker context show 2>/dev/null | head -n 1)
        echo "__DOCKER_CONTEXT__=$ctx"
        [ -n "$ctx" ] || exit 0
        ep=$(timeout 8 docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
        echo "__DOCKER_ENDPOINT__=$ep"
        case "$ep" in
          ""|unix://*) ;;
          *) exit 0 ;;
        esac
        echo "__DOCKER_INFO__"
        timeout 8 docker --context "$ctx" info --format '{{.ID}}' 2>&1 || echo "__ERR__"
        echo "__DOCKER_BUILDX_DU__"
        timeout 12 docker --context "$ctx" buildx du --builder default 2>/dev/null || true
        echo "__DOCKER_BUILDX_LS__"
        timeout 8 docker --context "$ctx" buildx ls --format '{{.Name}}' 2>/dev/null || true
        echo "__DOCKER_DF__"
        timeout 15 docker --context "$ctx" system df --format '{{json .}}' 2>/dev/null || echo "__DF_TIMEOUT__"
        echo "__DOCKER_VOLUMES__"
        vols=$(timeout 10 docker --context "$ctx" volume ls -q --filter dangling=true 2>/dev/null || true)
        if [ -n "$vols" ]; then
          printf '%s\n' "$vols" | xargs timeout 10 docker --context "$ctx" volume inspect --format '{{.Name}}	{{.CreatedAt}}' 2>/dev/null || true
        fi
        echo "__DOCKER_EXITED__"
        timeout 8 docker --context "$ctx" ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l
        """
        let res = await transport.runScript(script, timeout: 45)
        guard res.ok || !res.stdout.isEmpty else {
            return RuleOutput(errors: ["Remote Docker": res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return Self.parseDockerScan(res.stdout, host: host)
    }

    static func isLocalDockerEndpoint(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("unix://")
    }

    static func parseDockerScan(_ stdout: String, host: RemoteHost) -> RuleOutput {
        var section = ""
        var context = ""
        var endpoint = ""
        var infoLines: [String] = []
        var buildxDuLines: [String] = []
        var buildxLsLines: [String] = []
        var dfLines: [String] = []
        var volumeLines: [String] = []
        var exitedCount = 0

        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("__DOCKER_CONTEXT__=") {
                context = String(line.dropFirst("__DOCKER_CONTEXT__=".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("__DOCKER_ENDPOINT__=") {
                endpoint = String(line.dropFirst("__DOCKER_ENDPOINT__=".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("__DOCKER_") && line.hasSuffix("__") {
                section = line
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            switch section {
            case "__DOCKER_INFO__": infoLines.append(trimmed)
            case "__DOCKER_BUILDX_DU__": buildxDuLines.append(trimmed)
            case "__DOCKER_BUILDX_LS__": buildxLsLines.append(trimmed)
            case "__DOCKER_DF__": dfLines.append(trimmed)
            case "__DOCKER_VOLUMES__": volumeLines.append(trimmed)
            case "__DOCKER_EXITED__": exitedCount = Int(trimmed) ?? 0
            default: break
            }
        }

        guard !context.isEmpty else { return RuleOutput() }
        guard isLocalDockerEndpoint(endpoint) else {
            return RuleOutput(insights: [Insight(
                id: "remote-docker-nonlocal-context",
                title: "Docker context on \(host.displayName) points elsewhere",
                detail: "Docker context `\(context)` on \(host.displayName) uses endpoint `\(endpoint)` instead of a local socket, so Arin skipped Docker cleanup to avoid modifying another daemon."
            )])
        }
        guard let daemonID = infoLines.first, !daemonID.isEmpty, !infoLines.contains("__ERR__") else {
            return RuleOutput()
        }

        func dockerArgs(_ args: [String]) -> [String] { ["--context", context] + args }

        var candidates: [Candidate] = []
        var insights: [Insight] = []
        var sawBuildCacheFromDF = false

        let dfTimedOut = dfLines.contains("__DF_TIMEOUT__")
        if !dfTimedOut {
            for line in dfLines {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = row["Type"] as? String,
                      let reclaimable = (row["Reclaimable"] as? String).flatMap(DockerRule.parseSize),
                      reclaimable > 0
                else { continue }
                switch type {
                case "Build Cache":
                    sawBuildCacheFromDF = true
                    candidates.append(Candidate(
                        ruleID: "remote.docker.build-cache",
                        key: "\(host.target):\(context):\(daemonID):build-cache",
                        title: "Docker build cache",
                        detail: "BuildKit layers on \(host.displayName) (Docker context \(context)). Builds are slower once.",
                        category: .containers,
                        level: .standard,
                        risk: .safe,
                        bytes: reclaimable,
                        paths: [],
                        action: .commands([CommandSpec("docker", dockerArgs(["builder", "prune", "-af"]))])
                    ))
                case "Images":
                    candidates.append(Candidate(
                        ruleID: "remote.docker.images",
                        key: "\(host.target):\(context):\(daemonID):images",
                        title: "Unused Docker images",
                        detail: "Images no container uses on \(host.displayName) (Docker context \(context)). They'll be pulled or rebuilt when needed.",
                        category: .containers,
                        level: .standard,
                        risk: .review,
                        bytes: reclaimable,
                        paths: [],
                        action: .commands([CommandSpec("docker", dockerArgs(["image", "prune", "-af"]))])
                    ))
                default:
                    break
                }
            }
        } else {
            insights.append(Insight(
                id: "remote-docker-df-timeout",
                title: "docker system df timed out on \(host.displayName)",
                detail: "Docker (context \(context)) has too many layers or containers for `docker system df` to finish quickly. Build cache was measured with `docker buildx du` instead."
            ))
        }

        if !sawBuildCacheFromDF, let reclaimable = parseBuildxReclaimable(buildxDuLines), reclaimable > 0 {
            candidates.append(Candidate(
                ruleID: "remote.docker.build-cache",
                key: "\(host.target):\(context):\(daemonID):build-cache",
                title: "Docker build cache",
                detail: "BuildKit layers for the default builder on \(host.displayName) (Docker context \(context)). Builds are slower once.",
                category: .containers,
                level: .standard,
                risk: .safe,
                bytes: reclaimable,
                paths: [],
                action: .commands([CommandSpec("docker", dockerArgs(["builder", "prune", "-af"]))])
            ))
        }

        let builders = Set(buildxLsLines)
        for line in volumeLines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let volume = parts[0].trimmingCharacters(in: .whitespaces)
            let createdAt = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard !volume.isEmpty, !createdAt.isEmpty else { continue }
            let orphaned = !builders.isEmpty && DockerRule.orphanedBuildxVolume(volume, builders: builders)
            candidates.append(Candidate(
                ruleID: "remote.docker.volume",
                key: "\(host.target):\(context):\(daemonID):\(createdAt):\(volume)",
                title: "Docker volume \(volume)",
                detail: orphaned
                    ? "BuildKit state for a buildx builder that no longer exists on \(host.displayName) (Docker context \(context))."
                    : "Not attached to any container on \(host.displayName) (Docker context \(context)). Check the name before removing.",
                category: .containers,
                level: .standard,
                risk: orphaned ? .safe : .review,
                bytes: 0,
                paths: [],
                action: .commands([CommandSpec("docker", dockerArgs(["volume", "rm", volume]))])
            ))
        }

        if exitedCount > 0 {
            insights.append(Insight(
                id: "remote-docker-exited",
                title: "\(exitedCount) stopped Docker container(s) on \(host.displayName)",
                detail: "Stopped containers in Docker context \(context) still pin images and writable layers. Run `docker --context \(context) container prune` on \(host.target) if you no longer need them."
            ))
        }

        return RuleOutput(candidates: candidates, insights: insights)
    }

    static func parseBuildxReclaimable(_ lines: [String]) -> Int64? {
        for line in lines {
            guard line.hasPrefix("Reclaimable:") else { continue }
            let rest = line.dropFirst("Reclaimable:".count).trimmingCharacters(in: .whitespaces)
            if let size = DockerRule.parseSize(rest) { return size }
        }
        return nil
    }

    func scanKind(transport: SSHTransport, env: RemoteEnvironment) async -> RuleOutput {
        guard env.tools.contains("kind"), env.tools.contains("docker") else { return RuleOutput() }
        let script = """
        if [ -n "${DOCKER_HOST:-}" ]; then
          case "$DOCKER_HOST" in
            unix://*) ;;
            *) exit 0 ;;
          esac
        fi
        ctx=$(timeout 8 docker context show 2>/dev/null | head -n 1)
        [ -n "$ctx" ] || exit 0
        ep=$(timeout 8 docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
        case "$ep" in
          ""|unix://*) ;;
          *) exit 0 ;;
        esac
        echo "__KIND_CONTEXT__=$ctx"
        did=$(timeout 8 docker --context "$ctx" info --format '{{.ID}}' 2>/dev/null | head -n 1)
        echo "__KIND_DAEMON_ID__=$did"
        [ -n "$did" ] || exit 0
        for name in $(timeout 10 kind get clusters 2>/dev/null || true); do
          nodes=$(timeout 8 docker --context "$ctx" ps -aq --filter "label=io.x-k8s.kind.cluster=$name" 2>/dev/null | sort | paste -sd, -)
          [ -n "$nodes" ] && printf '%s\t%s\n' "$name" "$nodes"
        done
        """
        let res = await transport.runScript(script, timeout: 25)
        guard res.ok else { return RuleOutput() }
        var ctx = ""
        var daemonID = ""
        var clusters: [(name: String, nodes: String)] = []
        for raw in res.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("__KIND_CONTEXT__=") {
                ctx = String(line.dropFirst("__KIND_CONTEXT__=".count))
            } else if line.hasPrefix("__KIND_DAEMON_ID__=") {
                daemonID = String(line.dropFirst("__KIND_DAEMON_ID__=".count))
            } else if !line.isEmpty && !line.hasPrefix("No kind clusters") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                    clusters.append((parts[0], parts[1]))
                }
            }
        }
        guard !ctx.isEmpty, !daemonID.isEmpty else { return RuleOutput() }
        let candidates = clusters.map { cluster in
            Candidate(
                ruleID: "remote.kind.cluster",
                key: "\(host.target):kind:\(ctx):\(daemonID):\(cluster.nodes):\(cluster.name)",
                title: "kind cluster: \(cluster.name)",
                detail: "Local Kubernetes cluster running in Docker on \(host.displayName) (Docker context \(ctx)). Removing it deletes its node containers and images inside the node.",
                category: .containers,
                level: .deep,
                risk: .review,
                bytes: 0,
                paths: [],
                action: .commands([CommandSpec("kind", ["delete", "cluster", "--name", cluster.name])])
            )
        }
        return RuleOutput(candidates: candidates)
    }

    func scanSystemInsights(transport: SSHTransport, env: RemoteEnvironment) async -> [Insight] {
        var script = ""
        if env.tools.contains("journalctl") {
            script += "echo \"__JOURNAL__\"\n/usr/bin/journalctl --disk-usage 2>/dev/null || journalctl --disk-usage 2>/dev/null || true\n"
        }
        if env.tools.contains("apt") {
            script += "echo \"__APT__\"\ndu -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}'\n"
        }
        guard !script.isEmpty else { return [] }
        let res = await transport.runScript(script, timeout: 15)
        guard res.ok else { return [] }

        var insights: [Insight] = []
        var section = ""
        for raw in res.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n "))
            if line == "__JOURNAL__" || line == "__APT__" {
                section = line
                continue
            }
            guard !line.isEmpty else { continue }
            switch section {
            case "__JOURNAL__":
                if let match = line.firstMatch(of: /take up ([0-9.]+[A-Za-z]+)/),
                   let bytes = ByteSize.parse(String(match.1)),
                   bytes >= 256 * 1024 * 1024 {
                    insights.append(Insight(
                        id: "remote-journald",
                        title: "Systemd journal logs on \(host.displayName)",
                        detail: "Systemd journals use \(bytes.formattedBytes). Trim them on the host with `sudo journalctl --vacuum-size=200M`.",
                        bytes: bytes
                    ))
                }
            case "__APT__":
                if let kb = Int64(line), kb * 1024 >= 100 * 1024 * 1024 {
                    let bytes = kb * 1024
                    insights.append(Insight(
                        id: "remote-apt-cache",
                        title: "APT package cache on \(host.displayName)",
                        detail: "Cached `.deb` packages in `/var/cache/apt/archives`. Clear on the host with `sudo apt-get clean`.",
                        bytes: bytes
                    ))
                }
            default:
                break
            }
        }
        return insights
    }
}

import Foundation

public struct RemoteExecutor: Sendable {
    public var host: RemoteHost
    public var expectedIdentity: String?
    public var commandTimeout: TimeInterval
    public var keepListURL: URL?

    public init(
        host: RemoteHost,
        expectedIdentity: String? = nil,
        commandTimeout: TimeInterval = 1800,
        keepListURL: URL? = KeepList.defaultURL
    ) {
        self.host = host
        self.expectedIdentity = expectedIdentity
        self.commandTimeout = commandTimeout
        self.keepListURL = keepListURL
    }

    public func run(_ candidates: [Candidate], progress: (@Sendable (CleanupEvent) -> Void)? = nil) async -> CleanupReport {
        let transport = SSHTransport(host: host)
        progress?(.started(total: candidates.count))

        let initialEnv: RemoteEnvironment
        do {
            initialEnv = try await RemoteEnvironment.probe(transport: transport)
        } catch {
            let items = candidates.map { Executor.skipped($0, "\(error)") }
            return CleanupReport(
                items: items,
                freeBefore: 0,
                freeAfter: 0,
                estimatedBytes: 0,
                explanations: ["Could not connect to \(host.target): \(error)"]
            )
        }

        if let expectedIdentity, initialEnv.identity != expectedIdentity {
            let msg = "SSH destination \(host.target) resolved to \(initialEnv.identity), expected \(expectedIdentity); rescan first"
            return CleanupReport(
                items: candidates.map { Executor.skipped($0, msg) },
                freeBefore: initialEnv.disk.freeBytes,
                freeAfter: initialEnv.disk.freeBytes,
                estimatedBytes: 0,
                explanations: [msg]
            )
        }

        let before = initialEnv.disk.freeBytes
        var results: [CleanupItemResult] = []

        for (index, candidate) in candidates.enumerated() {
            progress?(.item(index: index, title: candidate.title))
            let keep: Result<KeepList, any Error> = keepListURL.map { url in Result { try KeepList.load(from: url) } }
                ?? .success(KeepList())
            let result: CleanupItemResult
            switch keep {
            case let .failure(error):
                result = Executor.skipped(candidate, "\(error)")
            case let .success(list) where list.contains(candidate.id) || candidate.kept:
                result = Executor.skipped(candidate, "on your keep list")
            case .success where !candidate.keepBlockers.isEmpty:
                result = Executor.skipped(candidate, candidate.keepBlockers.joined(separator: "; "))
            case let .success(list):
                switch await resolveRemoteKeptPaths(list, transport: transport) {
                case let .failure(reason):
                    result = Executor.skipped(candidate, reason.description)
                case let .success(kept):
                    if let inside = Executor.targets(of: candidate).lazy.compactMap({ kept.insideOrAt($0) }).first {
                        result = Executor.skipped(candidate, "contains \(inside.title)\(KeepList.keptBlockerSuffix)")
                    } else {
                        do {
                            let env = try await RemoteEnvironment.probe(transport: transport)
                            if let expectedIdentity, env.identity != expectedIdentity {
                                result = Executor.skipped(candidate, "SSH destination changed to \(env.identity); rescan first")
                            } else {
                                result = await clean(candidate, transport: transport, env: env, kept: kept)
                            }
                        } catch {
                            result = Executor.skipped(candidate, "\(error)")
                        }
                    }
                }
            }
            results.append(result)
            progress?(.finished(result))
        }

        let afterStatus = await RemoteEnvironment.diskStatus(transport: transport, home: initialEnv.home)
        let cleaned = results.filter { $0.status == .cleaned || $0.status == .partial }
        let estimated = cleaned.reduce(0) { $0 + $1.estimatedBytes }
        var notes: [String] = []
        let after: Int64
        if afterStatus.totalBytes > 0 {
            after = afterStatus.freeBytes
            if estimated > 512 * 1024 * 1024, Double(after - before) < Double(estimated) * 0.6 {
                notes.append("Measured free space on \(host.displayName) changed by less than the folder estimate. Shared container layers, open unlinked files, or concurrent writes can account for the difference.")
            }
        } else {
            after = before
            notes.append("Could not measure free space on \(host.displayName) after cleanup; free-space change is unavailable.")
        }
        return CleanupReport(
            items: results,
            freeBefore: before,
            freeAfter: after,
            estimatedBytes: estimated,
            explanations: notes
        )
    }

    func clean(_ candidate: Candidate, transport: SSHTransport, env: RemoteEnvironment, kept: KeptPaths) async -> CleanupItemResult {
        func makeResult(_ status: CleanupItemResult.Status, _ message: String) -> CleanupItemResult {
            CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                status: status,
                message: message,
                estimatedBytes: status == .cleaned ? candidate.bytes : 0,
                trashed: false,
                trashedPaths: nil
            )
        }

        guard candidate.isActionable else { return makeResult(.skipped, "informational only") }

        let guardrails = env.guardrails
        do {
            try guardrails.check(candidate.action)
            for path in candidate.paths {
                try guardrails.check(path)
            }
        } catch {
            return makeResult(.skipped, error.description)
        }

        let isCommandAction: Bool
        if case .commands = candidate.action { isCommandAction = true } else { isCommandAction = false }
        var resolvedPaths: [String] = []
        for path in Executor.targets(of: candidate) {
            switch await resolveAndValidateRemotePath(path, resolveLeaf: isCommandAction, transport: transport, guardrails: guardrails) {
            case let .failure(reason):
                return makeResult(.skipped, reason.description)
            case let .success(resolved):
                if let resolved {
                    resolvedPaths.append(resolved)
                }
            }
        }

        let allCheckPaths = Array(Set(candidate.paths + resolvedPaths))
        if let inside = allCheckPaths.lazy.compactMap({ kept.insideOrAt($0) }).first {
            return makeResult(.skipped, "contains \(inside.title)\(KeepList.keptBlockerSuffix)")
        }

        let state = env.systemState
        if !state.openFilesKnown, !allCheckPaths.isEmpty {
            return makeResult(.skipped, "couldn't check for open files on \(host.target) (lsof returned nothing); try again")
        }
        let live = state.blockers(paths: allCheckPaths, processes: candidate.blockingProcesses, minIdle: nil)
        if !live.isEmpty {
            return makeResult(.skipped, live.joined(separator: "; "))
        }

        switch candidate.action {
        case .none:
            return makeResult(.skipped, "informational only")

        case .trash:
            return makeResult(.skipped, "Trash is not supported on remote hosts")

        case .removeWorktree:
            return makeResult(.skipped, "Worktree removal is not supported on remote hosts")

        case let .delete(paths):
            return await deleteRemote(paths, candidate: candidate, transport: transport, env: env, guardrails: guardrails)

        case let .commands(commands):
            for command in commands {
                guard Guardrails.allows(command) else {
                    return makeResult(.skipped, "refusing to run \(command.display)")
                }
                let inlineGuard: String
                switch await preflightRemoteCommand(command, candidate: candidate, transport: transport, env: env, guardrails: guardrails, kept: kept) {
                case let .failure(reason):
                    return makeResult(.skipped, reason.description)
                case let .success(guardSnippet):
                    inlineGuard = guardSnippet
                }
                let joined = ([command.executable] + command.arguments).map(SSHTransport.shellQuote).joined(separator: " ")
                let cmdLine = command.cwd.map { "cd \(SSHTransport.shellQuote($0)) && \(joined)" } ?? joined
                let guardedScript = identityGuardScript(expected: expectedIdentity ?? env.identity)
                    + (inlineGuard.isEmpty ? "" : "\n" + inlineGuard)
                    + "\n" + cmdLine
                let output = await transport.runScript(guardedScript, timeout: commandTimeout)
                if !output.ok {
                    if output.timedOut { return makeResult(.failed, "\(command.display) timed out on \(host.target)") }
                    let tail = String((output.stderr.isEmpty ? output.stdout : output.stderr).suffix(400))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return makeResult(.failed, "\(command.display): \(tail)")
                }
            }
            let done = commands.map(\.display).joined(separator: " && ")
            return makeResult(.cleaned, done)
        }
    }

    struct Refusal: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    func preflightRemoteCommand(
        _ command: CommandSpec,
        candidate: Candidate,
        transport: SSHTransport,
        env: RemoteEnvironment,
        guardrails: Guardrails,
        kept: KeptPaths
    ) async -> Result<String, Refusal> {
        if command.executable == "docker" {
            guard command.arguments.count >= 2, command.arguments[0] == "--context" else {
                return .failure(Refusal("refusing docker command without a pinned --context"))
            }
            let ctx = command.arguments[1]
            let prefix = "\(candidate.ruleID):\(host.target):\(ctx):"
            guard candidate.id.hasPrefix(prefix) else {
                return .failure(Refusal("docker candidate is not bound to a scanned daemon ID on \(host.target)"))
            }
            let rest = String(candidate.id.dropFirst(prefix.count))
            guard let colonIdx = rest.lastIndex(of: ":") else {
                return .failure(Refusal("docker candidate is missing its scanned daemon ID"))
            }
            let head = String(rest[..<colonIdx])
            let scannedDaemonID: String
            let scannedCreatedAt: String?
            if candidate.ruleID == "remote.docker.volume" {
                guard let sep = head.firstIndex(of: "|") else {
                    return .failure(Refusal("docker volume candidate is missing its creation timestamp"))
                }
                scannedDaemonID = String(head[..<sep])
                scannedCreatedAt = String(head[head.index(after: sep)...])
                guard !(scannedCreatedAt ?? "").isEmpty else {
                    return .failure(Refusal("docker volume candidate has an empty creation timestamp"))
                }
            } else {
                scannedDaemonID = head
                scannedCreatedAt = nil
            }
            guard !scannedDaemonID.isEmpty else {
                return .failure(Refusal("docker candidate has an empty daemon ID"))
            }
            let volumeCheck: String
            if let volumeName = command.arguments.last, candidate.ruleID == "remote.docker.volume" {
                volumeCheck = """
                vcreated=$(_arin_timeout 8 docker --context \(SSHTransport.shellQuote(ctx)) volume inspect \(SSHTransport.shellQuote(volumeName)) --format '{{.CreatedAt}}' 2>/dev/null | head -n 1)
                echo "__VCREATED__=$vcreated"
                """
            } else {
                volumeCheck = ""
            }
            let script = """
            ep=$(_arin_timeout 8 docker context inspect \(SSHTransport.shellQuote(ctx)) --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            echo "__EP__=$ep"
            did=$(_arin_timeout 8 docker --context \(SSHTransport.shellQuote(ctx)) info --format '{{.ID}}' 2>/dev/null | head -n 1)
            echo "__ID__=$did"
            \(volumeCheck)
            """
            let res = await transport.runScript(script, timeout: 15)
            guard res.ok else {
                return .failure(Refusal("couldn't verify Docker context \(ctx) on \(host.target)"))
            }
            var endpoint = ""
            var currentDaemonID = ""
            var currentCreatedAt = ""
            for line in res.lines {
                if line.hasPrefix("__EP__=") { endpoint = String(line.dropFirst("__EP__=".count)) }
                else if line.hasPrefix("__ID__=") { currentDaemonID = String(line.dropFirst("__ID__=".count)) }
                else if line.hasPrefix("__VCREATED__=") { currentCreatedAt = String(line.dropFirst("__VCREATED__=".count)) }
            }
            guard RemoteScanner.isLocalDockerEndpoint(endpoint) else {
                return .failure(Refusal("Docker context \(ctx) on \(host.target) points to non-local endpoint \(endpoint)"))
            }
            guard currentDaemonID == scannedDaemonID else {
                return .failure(Refusal("Docker daemon for context \(ctx) on \(host.target) changed since the scan; rescan first"))
            }
            if let scannedCreatedAt, currentCreatedAt != scannedCreatedAt {
                return .failure(Refusal("Docker volume on \(host.target) was recreated since the scan; rescan first"))
            }
            var inline = """
            _arin_ep=$(_arin_timeout 8 docker context inspect \(SSHTransport.shellQuote(ctx)) --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            case "$_arin_ep" in ""|unix://*) ;; *) echo "Docker endpoint changed" >&2; exit 78 ;; esac
            _arin_did=$(_arin_timeout 8 docker --context \(SSHTransport.shellQuote(ctx)) info --format '{{.ID}}' 2>/dev/null | head -n 1)
            [ "$_arin_did" = \(SSHTransport.shellQuote(scannedDaemonID)) ] || { echo "Docker daemon changed" >&2; exit 78; }
            """
            if let scannedCreatedAt, let volumeName = command.arguments.last, candidate.ruleID == "remote.docker.volume" {
                inline += """
                \n_arin_vc=$(_arin_timeout 8 docker --context \(SSHTransport.shellQuote(ctx)) volume inspect \(SSHTransport.shellQuote(volumeName)) --format '{{.CreatedAt}}' 2>/dev/null | head -n 1)
                [ "$_arin_vc" = \(SSHTransport.shellQuote(scannedCreatedAt)) ] || { echo "Docker volume recreated" >&2; exit 78; }
                """
            }
            return .success(inline)
        }

        if command.executable == "kind" {
            let prefix = "remote.kind.cluster:\(host.target):kind:"
            let clusterName = command.arguments.last ?? ""
            let suffix = ":\(clusterName)"
            guard candidate.id.hasPrefix(prefix), candidate.id.hasSuffix(suffix) else {
                return .failure(Refusal("kind candidate is not bound to a scanned Docker daemon on \(host.target)"))
            }
            let middle = String(candidate.id.dropFirst(prefix.count).dropLast(suffix.count))
            guard let firstSep = middle.firstIndex(of: ":"),
                  let lastSep = middle.lastIndex(of: ":"),
                  firstSep < lastSep
            else {
                return .failure(Refusal("kind candidate is missing its scanned Docker context, daemon ID, and node IDs"))
            }
            let scannedCtx = String(middle[..<firstSep])
            let scannedDaemonID = String(middle[middle.index(after: firstSep) ..< lastSep])
            let scannedNodes = String(middle[middle.index(after: lastSep)...])
            guard !scannedCtx.isEmpty, !scannedDaemonID.isEmpty, !scannedNodes.isEmpty else {
                return .failure(Refusal("kind candidate is missing its scanned Docker context, daemon ID, or node IDs"))
            }
            let script = """
            if [ -n "${DOCKER_HOST:-}" ]; then
              echo "__HOST__=$DOCKER_HOST"
            fi
            ctx=$(_arin_timeout 8 docker context show 2>/dev/null | head -n 1)
            echo "__CTX__=$ctx"
            [ -n "$ctx" ] || exit 1
            ep=$(_arin_timeout 8 docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            echo "__EP__=$ep"
            did=$(_arin_timeout 8 docker --context "$ctx" info --format '{{.ID}}' 2>/dev/null | head -n 1)
            echo "__ID__=$did"
            nodes=$(_arin_timeout 8 docker --context "$ctx" ps -aq --filter \(SSHTransport.shellQuote("label=io.x-k8s.kind.cluster=\(clusterName)")) 2>/dev/null | sort | paste -sd+ -)
            echo "__NODES__=$nodes"
            """
            let res = await transport.runScript(script, timeout: 15)
            guard res.ok else {
                return .failure(Refusal("couldn't verify local Docker daemon for kind on \(host.target)"))
            }
            var dockerHost = ""
            var activeCtx = ""
            var endpoint = ""
            var currentDaemonID = ""
            var currentNodes = ""
            for line in res.lines {
                if line.hasPrefix("__HOST__=") { dockerHost = String(line.dropFirst("__HOST__=".count)) }
                else if line.hasPrefix("__CTX__=") { activeCtx = String(line.dropFirst("__CTX__=".count)) }
                else if line.hasPrefix("__EP__=") { endpoint = String(line.dropFirst("__EP__=".count)) }
                else if line.hasPrefix("__ID__=") { currentDaemonID = String(line.dropFirst("__ID__=".count)) }
                else if line.hasPrefix("__NODES__=") { currentNodes = String(line.dropFirst("__NODES__=".count)) }
            }
            guard dockerHost.isEmpty else {
                return .failure(Refusal("DOCKER_HOST override is set on \(host.target); refusing kind cleanup"))
            }
            guard activeCtx == scannedCtx else {
                return .failure(Refusal("active Docker context on \(host.target) changed from \(scannedCtx) to \(activeCtx); rescan first"))
            }
            guard RemoteScanner.isLocalDockerEndpoint(endpoint) else {
                return .failure(Refusal("Docker context \(activeCtx) on \(host.target) points to non-local endpoint \(endpoint)"))
            }
            guard currentDaemonID == scannedDaemonID else {
                return .failure(Refusal("Docker daemon for kind on \(host.target) changed since the scan; rescan first"))
            }
            guard currentNodes == scannedNodes else {
                return .failure(Refusal("kind cluster \(clusterName) on \(host.target) was recreated since the scan; rescan first"))
            }
            let inline = """
            [ -z "${DOCKER_HOST:-}" ] || { echo "DOCKER_HOST override set" >&2; exit 78; }
            _arin_ctx=$(_arin_timeout 8 docker context show 2>/dev/null | head -n 1)
            [ "$_arin_ctx" = \(SSHTransport.shellQuote(scannedCtx)) ] || { echo "Docker context changed" >&2; exit 78; }
            _arin_ep=$(_arin_timeout 8 docker context inspect "$_arin_ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            case "$_arin_ep" in ""|unix://*) ;; *) echo "Docker endpoint changed" >&2; exit 78 ;; esac
            _arin_did=$(_arin_timeout 8 docker --context "$_arin_ctx" info --format '{{.ID}}' 2>/dev/null | head -n 1)
            [ "$_arin_did" = \(SSHTransport.shellQuote(scannedDaemonID)) ] || { echo "Docker daemon changed" >&2; exit 78; }
            _arin_nodes=$(_arin_timeout 8 docker --context "$_arin_ctx" ps -aq --filter \(SSHTransport.shellQuote("label=io.x-k8s.kind.cluster=\(clusterName)")) 2>/dev/null | sort | paste -sd+ -)
            [ "$_arin_nodes" = \(SSHTransport.shellQuote(scannedNodes)) ] || { echo "kind cluster recreated" >&2; exit 78; }
            """
            return .success(inline)
        }

        let resolveExpr: String?
        switch (command.executable, command.arguments) {
        case ("go", ["clean", "-cache"]):
            resolveExpr = "go env GOCACHE 2>/dev/null"
        case ("go", ["clean", "-modcache"]):
            resolveExpr = "go env GOMODCACHE 2>/dev/null"
        case ("npm", ["cache", "clean", "--force"]):
            resolveExpr = "d=$(npm config get cache 2>/dev/null); [ -n \"$d\" ] && printf '%s\\n' \"$d/_cacache\""
        case ("pip", ["cache", "purge"]), ("pip3", ["cache", "purge"]):
            resolveExpr = "\(command.executable) cache dir 2>/dev/null"
        case ("uv", ["cache", "clean"]):
            resolveExpr = "uv cache dir 2>/dev/null"
        case ("brew", ["cleanup", "--prune=all"]):
            resolveExpr = "brew --cache 2>/dev/null"
        default:
            resolveExpr = nil
        }
        guard let resolveExpr else { return .success("") }

        let res = await transport.runScript(resolveExpr, timeout: 15)
        guard res.ok, let target = res.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), target.hasPrefix("/") else {
            return .failure(Refusal("couldn't resolve effective cache directory for \(command.display) on \(host.target)"))
        }
        let cleanTarget = (target as NSString).standardizingPath
        let scannedTargets = Set(candidate.paths.map { ($0 as NSString).standardizingPath })
        guard scannedTargets.contains(cleanTarget) else {
            return .failure(Refusal("\(command.display) now targets \(cleanTarget) instead of the scanned cache; rescan first"))
        }
        do {
            try guardrails.check(cleanTarget)
        } catch {
            return .failure(Refusal(error.description))
        }
        let resolvedTarget: String
        switch await resolveAndValidateRemotePath(cleanTarget, resolveLeaf: true, transport: transport, guardrails: guardrails) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(real):
            resolvedTarget = real ?? cleanTarget
        }
        if command.executable == "go", command.arguments == ["clean", "-modcache"] {
            let check = """
            p=\(SSHTransport.shellQuote(resolvedTarget))
            [ -d "$p/cache/download" ] && [ ! -e "$p/.git" ] && _arin_extra=$(find "$p" -maxdepth 1 -mindepth 1 \\( ! -type d -o \\( ! -name cache ! -name '*.*' \\) \\) -print 2>/dev/null) && [ -z "$_arin_extra" ]
            """
            let dedicated = await transport.runScript(check, timeout: 15)
            guard dedicated.ok else {
                return .failure(Refusal("\(resolvedTarget) does not look like a dedicated Go module cache on \(host.target)"))
            }
        }
        if env.systemState.isBusy(cleanTarget) || env.systemState.isBusy(resolvedTarget) {
            return .failure(Refusal("\(resolvedTarget) has open files on \(host.target)"))
        }
        if let inside = kept.insideOrAt(cleanTarget) ?? kept.insideOrAt(resolvedTarget) {
            return .failure(Refusal("contains \(inside.title)\(KeepList.keptBlockerSuffix)"))
        }
        var inline = """
        _arin_t=$(\(resolveExpr) | head -n 1)
        [ "$_arin_t" = \(SSHTransport.shellQuote(cleanTarget)) ] || { echo "Cache target changed" >&2; exit 78; }
        _arin_rt=$(readlink -f -- "$_arin_t" 2>/dev/null || realpath -- "$_arin_t" 2>/dev/null)
        [ "$_arin_rt" = \(SSHTransport.shellQuote(resolvedTarget)) ] || { echo "Cache real path changed" >&2; exit 78; }
        """
        if command.executable == "go", command.arguments == ["clean", "-modcache"] {
            inline += """
            \n[ -d "$_arin_rt/cache/download" ] && [ ! -e "$_arin_rt/.git" ] && _arin_extra=$(find "$_arin_rt" -maxdepth 1 -mindepth 1 \\( ! -type d -o \\( ! -name cache ! -name '*.*' \\) \\) -print 2>/dev/null) && [ -z "$_arin_extra" ] || { echo "Go modcache layout changed" >&2; exit 78; }
            """
        }
        return .success(inline)
    }

    private func resolveRemoteKeptPaths(_ list: KeepList, transport: SSHTransport) async -> Result<KeptPaths, Refusal> {
        let hostEntries = list.entries.filter { $0.remoteHost == host.target }
        let pairs: [(id: String, path: String)] = hostEntries.flatMap { entry in
            (entry.paths ?? []).map { (entry.id, $0) }
        }
        guard !pairs.isEmpty else { return .success(KeptPaths(list.entries, remoteHost: host.target)) }
        var lines: [String] = []
        for (idx, pair) in pairs.enumerated() {
            let q = SSHTransport.shellQuote(pair.path)
            lines.append("""
            if [ -e \(q) ] || [ -L \(q) ]; then
              _r=$(readlink -f -- \(q) 2>/dev/null || realpath -- \(q) 2>/dev/null) || exit 1
              printf '%d\\t%s\\n' \(idx) "$_r"
            fi
            """)
        }
        let res = await transport.runScript(lines.joined(separator: "\n"), timeout: 20)
        guard res.ok else {
            return .failure(Refusal("couldn't verify kept paths on \(host.target); skipping cleanup"))
        }
        var extra: [String: [String]] = [:]
        for line in res.lines {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let idx = Int(parts[0]), idx >= 0, idx < pairs.count, parts[1].hasPrefix("/") else { continue }
            extra[pairs[idx].id, default: []].append(parts[1])
        }
        return .success(KeptPaths(list.entries, remoteHost: host.target, extraRemotePaths: extra))
    }

    func resolveAndValidateRemotePath(
        _ path: String,
        resolveLeaf: Bool,
        transport: SSHTransport,
        guardrails: Guardrails
    ) async -> Result<String?, Refusal> {
        let parent = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let target = resolveLeaf ? path : parent
        let quoted = SSHTransport.shellQuote(target)
        let script = """
        if [ -e \(quoted) ] || [ -L \(quoted) ]; then
          readlink -f -- \(quoted) 2>/dev/null || realpath -- \(quoted) 2>/dev/null
        else
          echo "__MISSING__"
        fi
        """
        let res = await transport.runScript(script, timeout: 15)
        guard res.ok, let line = res.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return .failure(Refusal("couldn't resolve real path for \(path) on \(host.target)"))
        }
        if line == "__MISSING__" { return .success(nil) }
        let resolved = resolveLeaf ? line : (line as NSString).appendingPathComponent(base)
        do {
            try guardrails.check(resolved)
        } catch {
            return .failure(Refusal(error.description))
        }
        return .success(resolved)
    }

    private func identityGuardScript(expected: String) -> String {
        """
        _arin_h=$(hostname 2>/dev/null || uname -n)
        _arin_m=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)
        if [ -n "$_arin_m" ]; then _arin_hp="$_arin_h:$_arin_m"; else _arin_hp="$_arin_h"; fi
        _arin_id="$(id -u)@${_arin_hp}:$HOME"
        if [ "$_arin_id" != \(SSHTransport.shellQuote(expected)) ]; then
          echo "SSH destination identity mismatch: $_arin_id" >&2
          exit 77
        fi
        """
    }

    private func deleteRemote(
        _ paths: [String],
        candidate: Candidate,
        transport: SSHTransport,
        env: RemoteEnvironment,
        guardrails: Guardrails
    ) async -> CleanupItemResult {
        guard env.tools.contains("python3") else {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                status: .skipped,
                message: "python3 is required on \(host.target) for safe no-follow deletion",
                estimatedBytes: 0,
                trashed: false,
                trashedPaths: nil
            )
        }
        let keepLinks = candidate.ruleID == "remote.bun.cache"
        let guardPrefix = identityGuardScript(expected: expectedIdentity ?? env.identity)
        var errors: [String] = []
        for path in paths {
            do {
                try guardrails.check(path)
            } catch {
                errors.append(error.description)
                continue
            }
            let script = """
            \(guardPrefix)
            python3 - \(SSHTransport.shellQuote(path)) \(keepLinks ? "1" : "0") <<'__ARIN_PY__'
            import errno, os, stat, sys

            target = sys.argv[1]
            keep_links = sys.argv[2] == "1"

            def open_nofollow_dir(parent_fd, name):
                flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
                return os.open(name, flags, dir_fd=parent_fd)

            def open_chain(abs_path):
                parts = [p for p in abs_path.split("/") if p]
                fd = os.open("/", os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
                try:
                    for part in parts[:-1]:
                        nxt = open_nofollow_dir(fd, part)
                        os.close(fd)
                        fd = nxt
                    return fd, parts[-1]
                except Exception:
                    os.close(fd)
                    raise

            def ensure_writable(fd, st):
                if st.st_uid == os.getuid() and (st.st_mode & 0o700) != 0o700:
                    os.fchmod(fd, (st.st_mode & 0o7777) | 0o700)

            def remove_tree(parent_fd, name, root_dev, preserve_names=()):
                st = os.lstat(name, dir_fd=parent_fd)
                if not stat.S_ISDIR(st.st_mode):
                    os.unlink(name, dir_fd=parent_fd)
                    return
                if st.st_dev != root_dev:
                    raise OSError(errno.EXDEV, "refusing to cross mount boundary")
                dir_fd = open_nofollow_dir(parent_fd, name)
                try:
                    dst = os.fstat(dir_fd)
                    if dst.st_dev != root_dev:
                        raise OSError(errno.EXDEV, "refusing to cross mount boundary")
                    ensure_writable(dir_fd, dst)
                    for attempt in range(3):
                        for child in os.listdir(dir_fd):
                            if child in preserve_names:
                                continue
                            try:
                                remove_tree(dir_fd, child, root_dev)
                            except FileNotFoundError:
                                continue
                        if preserve_names:
                            return
                        cur = os.lstat(name, dir_fd=parent_fd)
                        if cur.st_dev != dst.st_dev or cur.st_ino != dst.st_ino:
                            raise OSError(errno.EBUSY, "directory replaced during cleanup")
                        try:
                            os.rmdir(name, dir_fd=parent_fd)
                            return
                        except FileNotFoundError:
                            return
                        except OSError as exc:
                            if exc.errno in (errno.ENOTEMPTY, errno.EEXIST) and attempt < 2:
                                continue
                            raise
                finally:
                    os.close(dir_fd)

            try:
                pfd, leaf = open_chain(target)
            except FileNotFoundError:
                sys.exit(0)
            try:
                pst = os.fstat(pfd)
                st = os.lstat(leaf, dir_fd=pfd)
                if keep_links and stat.S_ISDIR(st.st_mode):
                    remove_tree(pfd, leaf, pst.st_dev, preserve_names=("links",))
                else:
                    ensure_writable(pfd, pst)
                    remove_tree(pfd, leaf, pst.st_dev)
            except FileNotFoundError:
                pass
            finally:
                os.close(pfd)
            __ARIN_PY__
            """
            let res = await transport.runScript(script, timeout: commandTimeout)
            if !res.ok {
                let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                errors.append("\(path): \(msg.isEmpty ? "exit \(res.status)" : msg)")
            }
        }
        if errors.isEmpty {
            return CleanupItemResult(
                id: candidate.id,
                title: candidate.title,
                status: .cleaned,
                message: "deleted on \(host.displayName)",
                estimatedBytes: candidate.bytes,
                trashed: false,
                trashedPaths: nil
            )
        }
        return CleanupItemResult(
            id: candidate.id,
            title: candidate.title,
            status: .failed,
            message: errors.joined(separator: "; "),
            estimatedBytes: 0,
            trashed: false,
            trashedPaths: nil
        )
    }
}

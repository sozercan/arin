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
                let kept = KeptPaths(list.entries)
                if let inside = Executor.targets(of: candidate).lazy.compactMap({ kept.insideOrAt($0) }).first {
                    result = Executor.skipped(candidate, "contains \(inside.title)\(KeepList.keptBlockerSuffix)")
                } else {
                    do {
                        let env = try await RemoteEnvironment.probe(transport: transport)
                        if let expectedIdentity, env.identity != expectedIdentity {
                            result = Executor.skipped(candidate, "SSH destination changed to \(env.identity); rescan first")
                        } else {
                            result = await clean(candidate, transport: transport, env: env)
                        }
                    } catch {
                        result = Executor.skipped(candidate, "\(error)")
                    }
                }
            }
            results.append(result)
            progress?(.finished(result))
        }

        let after = await RemoteEnvironment.diskStatus(transport: transport, home: initialEnv.home).freeBytes
        let cleaned = results.filter { $0.status == .cleaned || $0.status == .partial }
        let estimated = cleaned.reduce(0) { $0 + $1.estimatedBytes }
        var notes: [String] = []
        if estimated > 512 * 1024 * 1024, Double(after - before) < Double(estimated) * 0.6 {
            notes.append("Measured free space on \(host.displayName) changed by less than the folder estimate. Shared container layers, open unlinked files, or concurrent writes can account for the difference.")
        }
        return CleanupReport(
            items: results,
            freeBefore: before,
            freeAfter: after,
            estimatedBytes: estimated,
            explanations: notes
        )
    }

    func clean(_ candidate: Candidate, transport: SSHTransport, env: RemoteEnvironment) async -> CleanupItemResult {
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
        for path in Executor.targets(of: candidate) {
            if let refusal = await validateRemoteRealPath(path, resolveLeaf: isCommandAction, transport: transport, guardrails: guardrails) {
                return makeResult(.skipped, refusal)
            }
        }

        let state = env.systemState
        if !state.openFilesKnown, !candidate.paths.isEmpty {
            return makeResult(.skipped, "couldn't check for open files on \(host.target) (lsof returned nothing); try again")
        }
        let live = state.blockers(paths: candidate.paths, processes: candidate.blockingProcesses, minIdle: nil)
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
                if let refusal = await preflightRemoteCommand(command, candidate: candidate, transport: transport, env: env, guardrails: guardrails) {
                    return makeResult(.skipped, refusal)
                }
                let joined = ([command.executable] + command.arguments).map(SSHTransport.shellQuote).joined(separator: " ")
                let cmdLine = command.cwd.map { "cd \(SSHTransport.shellQuote($0)) && \(joined)" } ?? joined
                let guardedScript = identityGuardScript(expected: expectedIdentity ?? env.identity) + "\n" + cmdLine
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

    func preflightRemoteCommand(
        _ command: CommandSpec,
        candidate: Candidate,
        transport: SSHTransport,
        env: RemoteEnvironment,
        guardrails: Guardrails
    ) async -> String? {
        if command.executable == "docker" {
            guard command.arguments.count >= 2, command.arguments[0] == "--context" else {
                return "refusing docker command without a pinned --context"
            }
            let ctx = command.arguments[1]
            let prefix = "\(candidate.ruleID):\(host.target):\(ctx):"
            guard candidate.id.hasPrefix(prefix) else {
                return "docker candidate is not bound to a scanned daemon ID on \(host.target)"
            }
            let rest = String(candidate.id.dropFirst(prefix.count))
            guard let colonIdx = rest.lastIndex(of: ":") else {
                return "docker candidate is missing its scanned daemon ID"
            }
            let scannedDaemonID = String(rest[..<colonIdx])
            guard !scannedDaemonID.isEmpty else {
                return "docker candidate has an empty daemon ID"
            }
            let script = """
            ep=$(timeout 8 docker context inspect \(SSHTransport.shellQuote(ctx)) --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            echo "__EP__=$ep"
            did=$(timeout 8 docker --context \(SSHTransport.shellQuote(ctx)) info --format '{{.ID}}' 2>/dev/null | head -n 1)
            echo "__ID__=$did"
            """
            let res = await transport.runScript(script, timeout: 15)
            guard res.ok else {
                return "couldn't verify Docker context \(ctx) on \(host.target)"
            }
            var endpoint = ""
            var currentDaemonID = ""
            for line in res.lines {
                if line.hasPrefix("__EP__=") { endpoint = String(line.dropFirst("__EP__=".count)) }
                else if line.hasPrefix("__ID__=") { currentDaemonID = String(line.dropFirst("__ID__=".count)) }
            }
            guard RemoteScanner.isLocalDockerEndpoint(endpoint) else {
                return "Docker context \(ctx) on \(host.target) points to non-local endpoint \(endpoint)"
            }
            guard currentDaemonID == scannedDaemonID else {
                return "Docker daemon for context \(ctx) on \(host.target) changed since the scan; rescan first"
            }
            return nil
        }

        if command.executable == "kind" {
            let prefix = "remote.kind.cluster:\(host.target):kind:"
            let clusterName = command.arguments.last ?? ""
            let suffix = ":\(clusterName)"
            guard candidate.id.hasPrefix(prefix), candidate.id.hasSuffix(suffix) else {
                return "kind candidate is not bound to a scanned Docker daemon on \(host.target)"
            }
            let middle = String(candidate.id.dropFirst(prefix.count).dropLast(suffix.count))
            guard let sep = middle.firstIndex(of: ":") else {
                return "kind candidate is missing its scanned Docker context and daemon ID"
            }
            let scannedCtx = String(middle[..<sep])
            let scannedDaemonID = String(middle[middle.index(after: sep)...])
            guard !scannedCtx.isEmpty, !scannedDaemonID.isEmpty else {
                return "kind candidate is missing its scanned Docker context or daemon ID"
            }
            let script = """
            if [ -n "${DOCKER_HOST:-}" ]; then
              echo "__HOST__=$DOCKER_HOST"
            fi
            ctx=$(timeout 8 docker context show 2>/dev/null | head -n 1)
            echo "__CTX__=$ctx"
            [ -n "$ctx" ] || exit 1
            ep=$(timeout 8 docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1)
            echo "__EP__=$ep"
            did=$(timeout 8 docker --context "$ctx" info --format '{{.ID}}' 2>/dev/null | head -n 1)
            echo "__ID__=$did"
            """
            let res = await transport.runScript(script, timeout: 15)
            guard res.ok else {
                return "couldn't verify local Docker daemon for kind on \(host.target)"
            }
            var dockerHost = ""
            var activeCtx = ""
            var endpoint = ""
            var currentDaemonID = ""
            for line in res.lines {
                if line.hasPrefix("__HOST__=") { dockerHost = String(line.dropFirst("__HOST__=".count)) }
                else if line.hasPrefix("__CTX__=") { activeCtx = String(line.dropFirst("__CTX__=".count)) }
                else if line.hasPrefix("__EP__=") { endpoint = String(line.dropFirst("__EP__=".count)) }
                else if line.hasPrefix("__ID__=") { currentDaemonID = String(line.dropFirst("__ID__=".count)) }
            }
            guard dockerHost.isEmpty || dockerHost.hasPrefix("unix://") else {
                return "DOCKER_HOST on \(host.target) points to non-local endpoint \(dockerHost)"
            }
            guard activeCtx == scannedCtx else {
                return "active Docker context on \(host.target) changed from \(scannedCtx) to \(activeCtx); rescan first"
            }
            guard RemoteScanner.isLocalDockerEndpoint(endpoint) else {
                return "Docker context \(activeCtx) on \(host.target) points to non-local endpoint \(endpoint)"
            }
            guard currentDaemonID == scannedDaemonID else {
                return "Docker daemon for kind on \(host.target) changed since the scan; rescan first"
            }
            return nil
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
        guard let resolveExpr else { return nil }

        let res = await transport.runScript(resolveExpr, timeout: 15)
        guard res.ok, let target = res.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), target.hasPrefix("/") else {
            return "couldn't resolve effective cache directory for \(command.display) on \(host.target)"
        }
        let cleanTarget = (target as NSString).standardizingPath
        let scannedTargets = Set(candidate.paths.map { ($0 as NSString).standardizingPath })
        guard scannedTargets.contains(cleanTarget) else {
            return "\(command.display) now targets \(cleanTarget) instead of the scanned cache; rescan first"
        }
        do {
            try guardrails.check(cleanTarget)
        } catch {
            return error.description
        }
        if let refusal = await validateRemoteRealPath(cleanTarget, resolveLeaf: true, transport: transport, guardrails: guardrails) {
            return refusal
        }
        if env.systemState.isBusy(cleanTarget) {
            return "\(cleanTarget) has open files on \(host.target)"
        }
        if let url = keepListURL, let list = try? KeepList.load(from: url) {
            if let inside = KeptPaths(list.entries).insideOrAt(cleanTarget) {
                return "contains \(inside.title)\(KeepList.keptBlockerSuffix)"
            }
        }
        return nil
    }

    func validateRemoteRealPath(
        _ path: String,
        resolveLeaf: Bool,
        transport: SSHTransport,
        guardrails: Guardrails
    ) async -> String? {
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
            return "couldn't resolve real path for \(path) on \(host.target)"
        }
        if line == "__MISSING__" { return nil }
        let resolved = resolveLeaf ? line : (line as NSString).appendingPathComponent(base)
        do {
            try guardrails.check(resolved)
        } catch {
            return error.description
        }
        return nil
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
            let quoted = SSHTransport.shellQuote(path)
            let script: String
            if keepLinks {
                script = """
                \(guardPrefix)
                if [ -d \(quoted) ] && [ ! -L \(quoted) ]; then
                  for entry in \(quoted)/* \(quoted)/.[!.]* \(quoted)/..?*; do
                    [ -e "$entry" ] || [ -L "$entry" ] || continue
                    base=$(basename "$entry")
                    [ "$base" = "links" ] && continue
                    chmod -R u+w "$entry" 2>/dev/null || true
                    rm -rf -- "$entry"
                  done
                fi
                """
            } else {
                script = """
                \(guardPrefix)
                if [ -L \(quoted) ]; then
                  rm -f -- \(quoted)
                elif [ -e \(quoted) ]; then
                  chmod -R u+w \(quoted) 2>/dev/null || true
                  rm -rf -- \(quoted)
                fi
                """
            }
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

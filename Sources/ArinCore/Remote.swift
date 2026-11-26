import Foundation

public struct RemoteHost: Codable, Sendable, Hashable, Identifiable {
    public var target: String
    public var label: String?

    public var id: String { target }

    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return label
        }
        return target
    }

    public init(target: String, label: String? = nil) {
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValidTarget(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        return trimmed.wholeMatch(of: /[A-Za-z0-9._@:-]+/) != nil
    }
}

public enum CleanupTarget: Codable, Sendable, Hashable {
    case local
    case remote(RemoteHost)

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    public var remoteHost: RemoteHost? {
        if case let .remote(host) = self { return host }
        return nil
    }

    public var displayName: String {
        switch self {
        case .local: "This Mac"
        case let .remote(host): host.displayName
        }
    }

    public var storageKey: String? {
        switch self {
        case .local: nil
        case let .remote(host): host.target
        }
    }
}

public enum SSHConfig {
    public static func hosts(from path: String = "\(NSHomeDirectory())/.ssh/config") -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parseHosts(text)
    }

    public static func parseHosts(_ text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for alias in parts.dropFirst() {
                if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { continue }
                if RemoteHost.isValidTarget(alias), seen.insert(alias).inserted {
                    result.append(alias)
                }
            }
        }
        return result
    }
}

public struct SSHTransport: Sendable {
    public var host: RemoteHost
    public var connectTimeoutSeconds: Int

    public init(host: RemoteHost, connectTimeoutSeconds: Int = 10) {
        self.host = host
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public static let pathExport =
        "export PATH=\"/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.nvm/versions/node/current/bin:$PATH\" LC_ALL=C NO_COLOR=1 GIT_TERMINAL_PROMPT=0 HOMEBREW_NO_AUTO_UPDATE=1; unset KIND_EXPERIMENTAL_PROVIDER"

    public func sshArguments(script: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "--",
            host.target,
            "sh -s",
        ]
    }

    public func runScript(_ script: String, timeout: TimeInterval = 60) async -> ShellResult {
        guard RemoteHost.isValidTarget(host.target) else {
            return ShellResult(status: 2, stdout: "", stderr: "invalid SSH target \(host.target)", timedOut: false)
        }
        let body = Self.pathExport + "\n" + script + "\n"
        return await Shell.run("ssh", sshArguments(script: script), input: body, timeout: timeout)
    }

    public func runCommand(_ command: CommandSpec, timeout: TimeInterval = 600) async -> ShellResult {
        let joined = ([command.executable] + command.arguments).map(Self.shellQuote).joined(separator: " ")
        let line: String
        if let cwd = command.cwd {
            line = "cd \(Self.shellQuote(cwd)) && \(joined)"
        } else {
            line = joined
        }
        return await runScript(line, timeout: timeout)
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct RemoteProbeError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public struct RemoteEnvironment: Sendable {
    public var host: RemoteHost
    public var os: String
    public var hostname: String
    public var machineID: String
    public var home: String
    public var uid: String
    public var disk: DiskStatus
    public var tools: Set<String>
    public var processNames: [String]
    public var openFiles: Set<String>
    public var busyDirectories: Set<String>
    public var openFilesKnown: Bool
    public var mountPoints: [String]?
    public var hasPasswordlessSudo: Bool

    public var systemState: SystemState {
        SystemState(
            processPaths: processNames,
            busyDirectories: busyDirectories,
            openFiles: openFiles,
            openFilesKnown: openFilesKnown
        )
    }

    public var identity: String {
        let hostPart = machineID.isEmpty ? hostname : "\(hostname):\(machineID)"
        return "\(uid)@\(hostPart):\(home)"
    }

    public var guardrails: Guardrails {
        Guardrails.remote(home: home, mountPoints: mountPoints)
    }

    public static func probe(transport: SSHTransport) async throws -> RemoteEnvironment {
        let script = """
        echo "__ARIN_OS__=$(uname -s)"
        echo "__ARIN_HOST__=$(hostname 2>/dev/null || uname -n)"
        mid=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)
        echo "__ARIN_MACHINE_ID__=$mid"
        echo "__ARIN_HOME__=$HOME"
        echo "__ARIN_UID__=$(id -u)"
        echo "__ARIN_DF__"
        df -Pk "$HOME" 2>/dev/null | tail -n 1
        echo "__ARIN_TOOLS__"
        for t in docker podman brew cargo go npm pnpm yarn bun pip pip3 uv apt journalctl kind kubectl helm rustup mise ollama git python3 lsof; do
          command -v "$t" >/dev/null 2>&1 && echo "$t"
        done
        echo "__ARIN_SUDO__"
        sudo -n true >/dev/null 2>&1 && echo "yes" || echo "no"
        echo "__ARIN_MOUNTS__"
        if [ -r /proc/mounts ]; then
          awk '{print $2}' /proc/mounts
        else
          mount | sed -n 's/.* on \\([^ ]*\\) .*/\\1/p'
        fi
        echo "__ARIN_PS__"
        ps -eo comm= 2>/dev/null || ps -axww -o comm= 2>/dev/null || true
        echo "__ARIN_LSOF__"
        if command -v lsof >/dev/null 2>&1; then
          timeout 15 lsof -n -P -w -u "$(id -u)" -Fn 2>/dev/null || true
        fi
        echo "__ARIN_END__"
        """
        let result = await transport.runScript(script, timeout: 30)
        guard result.ok else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteProbeError("Could not connect to \(transport.host.target): \(err.isEmpty ? "exit \(result.status)" : err)")
        }
        return try parse(result.stdout, host: transport.host)
    }

    public static func parse(_ output: String, host: RemoteHost) throws -> RemoteEnvironment {
        var os = ""
        var hostname = host.target
        var machineID = ""
        var home = ""
        var uid = ""
        var section = ""
        var dfLine = ""
        var tools = Set<String>()
        var sudoYes = false
        var mounts: [String] = []
        var sawMountsSection = false
        var processes: [String] = []
        var openPaths: [String] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("__ARIN_OS__=") {
                os = String(line.dropFirst("__ARIN_OS__=".count))
            } else if line.hasPrefix("__ARIN_HOST__=") {
                hostname = String(line.dropFirst("__ARIN_HOST__=".count))
            } else if line.hasPrefix("__ARIN_MACHINE_ID__=") {
                machineID = String(line.dropFirst("__ARIN_MACHINE_ID__=".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("__ARIN_HOME__=") {
                home = String(line.dropFirst("__ARIN_HOME__=".count))
            } else if line.hasPrefix("__ARIN_UID__=") {
                uid = String(line.dropFirst("__ARIN_UID__=".count))
            } else if line.hasPrefix("__ARIN_") && line.hasSuffix("__") {
                section = line
                if section == "__ARIN_MOUNTS__" { sawMountsSection = true }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                switch section {
                case "__ARIN_DF__":
                    dfLine = trimmed
                case "__ARIN_TOOLS__":
                    tools.insert(trimmed)
                case "__ARIN_SUDO__":
                    if trimmed == "yes" { sudoYes = true }
                case "__ARIN_MOUNTS__":
                    let unescaped = trimmed.replacingOccurrences(of: "\\040", with: " ")
                    mounts.append(unescaped)
                case "__ARIN_PS__":
                    processes.append(trimmed)
                case "__ARIN_LSOF__":
                    if line.hasPrefix("n/") {
                        openPaths.append(String(line.dropFirst()))
                    }
                default:
                    break
                }
            }
        }

        guard home.hasPrefix("/") else {
            throw RemoteProbeError("Remote host \(host.target) did not report a valid $HOME path.")
        }
        let disk = parseDfPkLine(dfLine) ?? .zero
        let state = SystemState(processPaths: processes, openPaths: openPaths, openFilesKnown: !openPaths.isEmpty)
        return RemoteEnvironment(
            host: host,
            os: os,
            hostname: hostname,
            machineID: machineID,
            home: home,
            uid: uid,
            disk: disk,
            tools: tools,
            processNames: processes,
            openFiles: state.openFiles,
            busyDirectories: state.busyDirectories,
            openFilesKnown: state.openFilesKnown,
            mountPoints: sawMountsSection && !mounts.isEmpty ? mounts : nil,
            hasPasswordlessSudo: sudoYes
        )
    }

    public static func parseDfPkLine(_ line: String) -> DiskStatus? {
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard cols.count >= 4,
              let totalKB = Int64(cols[1]),
              let availKB = Int64(cols[3])
        else { return nil }
        let total = totalKB * 1024
        let free = availKB * 1024
        return DiskStatus(totalBytes: total, freeBytes: free, availableForImportantUsage: free)
    }

    public static func diskStatus(transport: SSHTransport, home: String) async -> DiskStatus {
        let res = await transport.runScript("df -Pk \(SSHTransport.shellQuote(home)) 2>/dev/null | tail -n 1", timeout: 15)
        guard res.ok, let line = res.lines.last else { return .zero }
        return parseDfPkLine(line) ?? .zero
    }
}

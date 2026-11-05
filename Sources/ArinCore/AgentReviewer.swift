import Foundation

public enum AgentProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    public var isInstalled: Bool { Shell.which(executable) != nil }

    /// Judging caches and build folders needs little reasoning, so reviews default to a cheaper
    /// setup than a coding session. `nil` model means the CLI's own default.
    public var defaultModel: String? {
        switch self {
        case .claude: "sonnet"
        case .codex: nil
        }
    }

    public var defaultEffort: String { "low" }

    public static let efforts = ["low", "medium", "high", "xhigh"]

    public static var installed: [AgentProvider] { allCases.filter(\.isInstalled) }
}

public struct AgentReviewError: Error, CustomStringConvertible {
    public var description: String
}

/// Asks the user's own coding agent to judge candidates. The agent runs read-only and returns
/// verdicts keyed by candidate ID; it cannot add, change, or run cleanup actions.
public struct AgentReviewer: Sendable {
    public var provider: AgentProvider
    /// Model alias or name; `nil` uses the CLI's configured default.
    public var model: String?
    /// low, medium, high, xhigh; `nil` uses the CLI's configured default.
    public var effort: String?
    public var timeout: TimeInterval
    public var maxCandidates: Int

    public init(
        provider: AgentProvider,
        model: String? = nil,
        effort: String? = nil,
        timeout: TimeInterval = 900,
        maxCandidates: Int = 150
    ) {
        self.provider = provider
        self.model = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.effort = effort.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = timeout
        self.maxCandidates = maxCandidates
    }

    /// Credentials and personal data the reviewer must not read. The review never needs them.
    public static let privatePaths = [
        ".ssh", ".gnupg", ".aws", ".azure", ".config/gh", ".config/gcloud", ".docker/config.json",
        ".kube/config", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".codex/auth.json",
        ".claude/.credentials.json", ".local/share/keyrings",
        "Library/Keychains", "Library/Cookies", "Library/Messages", "Library/Mail", "Library/Photos",
        "Library/Mobile Documents", "Documents", "Desktop",
    ]

    /// Commands with no writing flags and that don't print file contents
    /// (no find: -delete; no git branch: -D; no cat/head: they'd bypass the Read deny rules).
    static let readOnlyBash = ["ls", "du", "stat", "file", "lsof", "git status", "git log --oneline", "git worktree list"]

    public static let schema: String = """
    {"type":"object","additionalProperties":false,"required":["verdicts"],"properties":{"verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","verdict","reason"],"properties":{"id":{"type":"string"},"verdict":{"type":"string","enum":["safe","review","keep"]},"reason":{"type":"string"}}}}}}
    """

    /// Reviews the largest actionable candidates and returns verdicts by candidate ID.
    public func review(_ candidates: [Candidate]) async throws -> [String: AgentVerdict] {
        guard provider.isInstalled else {
            throw AgentReviewError(description: "\(provider.label) (`\(provider.executable)`) is not installed")
        }
        let subset = Array(candidates.filter(\.isActionable).sorted { $0.bytes > $1.bytes }.prefix(maxCandidates))
        guard !subset.isEmpty else { return [:] }
        let prompt = Self.prompt(for: subset)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("arin-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let raw: String
        switch provider {
        case .claude:
            raw = try await runClaude(prompt: prompt, cwd: workDir.path)
        case .codex:
            raw = try await runCodex(prompt: prompt, cwd: workDir.path)
        }
        let known = Set(subset.map(\.id))
        return try Self.parseVerdicts(raw, agent: provider.label).filter { known.contains($0.key) }
    }

    static func claudeArguments(model: String?, effort: String?, home: String) -> [String] {
        let deny = privatePaths.flatMap { ["Read(~/\($0))", "Read(~/\($0)/**)"] }
        var args = [
            "-p",
            "--output-format", "json",
            "--json-schema", schema,
            "--tools", "Read,Glob,Grep,Bash",
            "--allowedTools",
        ] + ["Read", "Glob", "Grep"] + readOnlyBash.map { "Bash(\($0):*)" } + [
            "--disallowedTools",
        ] + deny + [
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--add-dir", home,
        ]
        if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        return args
    }

    static func codexArguments(model: String?, effort: String?, cwd: String, schemaPath: String, outPath: String) -> [String] {
        var args = [
            "exec",
            "--sandbox", "read-only",
            "--ephemeral",
            "--skip-git-repo-check",
            "--color", "never",
            "-C", cwd,
            "--output-schema", schemaPath,
            "-o", outPath,
        ]
        if let model { args += ["-m", model] }
        if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        return args
    }

    func runClaude(prompt: String, cwd: String) async throws -> String {
        let args = Self.claudeArguments(model: model, effort: effort, home: NSHomeDirectory())
        let result = await Shell.run("claude", args, cwd: cwd, input: prompt, timeout: timeout)
        if result.timedOut { throw AgentReviewError(description: "Claude Code timed out") }
        guard result.ok else {
            throw AgentReviewError(description: "Claude Code failed: \(String((result.stderr + result.stdout).suffix(400)))")
        }
        // The JSON envelope carries `structured_output` when --json-schema is honored, else `result` text.
        if let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] {
            if let structured = envelope["structured_output"],
               let data = try? JSONSerialization.data(withJSONObject: structured) {
                return String(decoding: data, as: UTF8.self)
            }
            if let text = envelope["result"] as? String { return text }
        }
        return result.stdout
    }

    func runCodex(prompt: String, cwd: String) async throws -> String {
        let schemaURL = URL(fileURLWithPath: cwd).appendingPathComponent("schema.json")
        let outURL = URL(fileURLWithPath: cwd).appendingPathComponent("verdicts.json")
        try Self.schema.write(to: schemaURL, atomically: true, encoding: .utf8)
        let args = Self.codexArguments(model: model, effort: effort, cwd: cwd, schemaPath: schemaURL.path, outPath: outURL.path)
        let result = await Shell.run("codex", args, cwd: cwd, input: prompt, timeout: timeout)
        if result.timedOut { throw AgentReviewError(description: "Codex timed out") }
        guard result.ok, let text = try? String(contentsOf: outURL, encoding: .utf8) else {
            throw AgentReviewError(description: "Codex failed: \(String((result.stderr + result.stdout).suffix(400)))")
        }
        return text
    }

    static func prompt(for candidates: [Candidate]) -> String {
        struct Item: Encodable {
            var id: String
            var title: String
            var category: String
            var size: String
            var paths: [String]
            var lastModified: String?
            var plannedAction: String
            var ruleRisk: String
            var ruleNote: String
            var blockers: [String]
        }
        let iso = ISO8601DateFormatter()
        let items = candidates.map { c in
            Item(
                id: c.id,
                title: c.title,
                category: c.category.label,
                size: c.bytes.formattedBytes,
                paths: Array(c.paths.prefix(5)) + (c.paths.count > 5 ? ["… and \(c.paths.count - 5) more"] : []),
                lastModified: c.lastModified.map { iso.string(from: $0) },
                plannedAction: c.action.summary,
                ruleRisk: c.risk.label.lowercased(),
                ruleNote: c.detail,
                blockers: c.blockers
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = (try? encoder.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
        You are reviewing disk-cleanup candidates on the user's Mac (home: \(NSHomeDirectory())).
        Do not modify, delete, move, or write anything. Inspect read-only only when it changes your verdict
        (ls, du, stat, file, git status/log, reading small text files). Never print file contents in your answer.
        Never open credentials or personal data: ~/.ssh, ~/.gnupg, ~/.aws, keychains, cookies, tokens, .env files,
        Messages, Mail, Photos, Documents, Desktop. Judge those from names and sizes only.

        For every candidate, return exactly one verdict:
        - "safe": regenerable or already-removed work with nothing unique; fine to clean now.
        - "review": the user should look first (possible personal data, notes, unpushed work, pinned versions, slow or costly to recreate).
        - "keep": holds unique work or is in active use; don't clean.

        Ground rules learned from previous cleanups:
        - Package-manager, build, and tool caches are regenerable. Missing a "safe" here only costs a rebuild or re-download.
        - git-ignored bin/ folders usually hold downloaded tools, but can also hold notes, scratch source, or nested git checkouts; those make it "review".
        - Worktrees: "safe" only when clean and already merged; any uncommitted or untracked file means "review".
        - App data under Application Support can hold settings, sign-ins, offline databases, and downloads; default to "review" unless it is clearly a cache.
        - Anything personal (documents, media, messages, photos, mail) is "keep".
        - When unsure, choose "review". Keep each reason under 25 words and specific to what you saw.

        Return JSON matching the schema: {"verdicts":[{"id": "...", "verdict": "safe|review|keep", "reason": "..."}]}.
        Use the candidate ids exactly as given.

        Candidates:
        \(json)
        """
    }

    struct Response: Decodable {
        struct Verdict: Decodable {
            var id: String
            var verdict: String
            var reason: String
        }

        var verdicts: [Verdict]
    }

    static func parseVerdicts(_ raw: String, agent: String) throws -> [String: AgentVerdict] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatesJSON: [String] = {
            var options = [text]
            // Tolerate prose or code fences around the JSON object.
            if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
                options.append(String(text[start ... end]))
            }
            return options
        }()
        for json in candidatesJSON {
            guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else { continue }
            var map: [String: AgentVerdict] = [:]
            for verdict in response.verdicts {
                guard let risk = Risk(name: verdict.verdict) else { continue }
                map[verdict.id] = AgentVerdict(risk: risk, reason: verdict.reason, agent: agent)
            }
            return map
        }
        throw AgentReviewError(description: "\(agent) returned no parseable verdicts: \(text.prefix(300))")
    }
}

public extension Array where Element == Candidate {
    /// Attaches verdicts to matching candidates.
    func applying(_ verdicts: [String: AgentVerdict]) -> [Candidate] {
        map { candidate in
            var copy = candidate
            if let verdict = verdicts[candidate.id] { copy.agentVerdict = verdict }
            return copy
        }
    }
}

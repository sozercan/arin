import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }

    static let cancelled = ShellResult(status: -2, stdout: "", stderr: "cancelled", timedOut: false)

    public var lines: [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Stands in for the tools `Shell` runs, so tests can make every tool missing, failing, silent, or
/// hanging. Set it with `Shell.$runner.withValue(_:operation:)`; it reaches child tasks of the operation.
public protocol CommandRunner: Sendable {
    func which(_ name: String) -> String?
    func run(_ executable: String, _ arguments: [String], cwd: String?, input: String?,
             environment: [String: String], timeout: TimeInterval) async -> ShellResult
}

/// Runs tools with a timeout and a PATH that includes the usual developer bin dirs.
/// GUI apps start with a minimal PATH, so lookups would otherwise miss Homebrew, ~/.local/bin, etc.
public enum Shell {
    /// Replaces real tools for the current task tree. Nil runs them.
    @TaskLocal public static var runner: (any CommandRunner)?

    public static let searchPath: [String] = {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/go/bin", "/usr/local/go/bin", "/opt/homebrew/opt/go/libexec/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm",
            // Docker Desktop's per-user CLI install, its bundled CLI, and OrbStack.
            "\(home)/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.orbstack/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":").map(String.init) where !dirs.contains(dir) {
                dirs.append(dir)
            }
        }
        return dirs
    }()

    /// Variables that point git at another repository, index, or object store, or change how it reads
    /// paths. A parent such as a git hook can set them; every `git -C <dir>` would then inspect the
    /// wrong repository.
    static let redirectingGitVariables = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS",
        "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    ]

    /// Whether a variable passes git configuration on the command line (`git -c` and
    /// `GIT_CONFIG_COUNT` with `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>`). These outrank the
    /// repository's own config, so one could set `core.worktree` and point git at another checkout.
    static func isGitConfigOverride(_ name: String) -> Bool {
        name == "GIT_CONFIG_PARAMETERS" || name == "GIT_CONFIG_COUNT"
            || name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_")
    }

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for name in redirectingGitVariables { env.removeValue(forKey: name) }
        for name in env.keys where isGitConfigOverride(name) { env.removeValue(forKey: name) }
        env["PATH"] = searchPath.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        // `git status` otherwise rewrites the index to refresh it: scans would write to every repo and
        // make each one look recently worked on.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }

    public static func which(_ name: String) -> String? {
        if let runner { return runner.which(name) }
        let usable: (String) -> Bool = { !DeveloperTools.isStub($0) || DeveloperTools.installed() }
        return locate(name, in: searchPath, usable: usable)
    }

    /// The first executable named `name` in `dirs` that `usable` accepts. A stub that would open an
    /// install dialog is skipped, so a real copy later in the path is still found.
    static func locate(_ name: String, in dirs: [String], usable: (String) -> Bool) -> String? {
        let candidates = name.hasPrefix("/") ? [name] : dirs.map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && usable($0) }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        input: String? = nil,
        environment extra: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async -> ShellResult {
        if let runner {
            return await runner.run(executable, arguments, cwd: cwd, input: input, environment: extra, timeout: timeout)
        }
        guard let exe = which(executable) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(executable): not found", timedOut: false)
        }
        if Task.isCancelled { return .cancelled }
        // Cancelling the calling task terminates the subprocess, so a stopped scan stops its du/find/git too.
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(exe, arguments, cwd: cwd, input: input, extra: extra, timeout: timeout, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runBlocking(
        _ exe: String,
        _ arguments: [String],
        cwd: String?,
        input: String?,
        extra: [String: String],
        timeout: TimeInterval,
        handle: ProcessHandle
    ) -> ShellResult {
        // Temp files instead of pipes: no deadlock when a tool writes megabytes (lsof, du).
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outURL = tmp.appendingPathComponent("arin-\(id).out")
        let errURL = tmp.appendingPathComponent("arin-\(id).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            return ShellResult(status: -1, stdout: "", stderr: "could not create output files", timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.environment = environment.merging(extra) { _, new in new }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = outHandle
        process.standardError = errHandle
        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        if !handle.attach(process) { process.terminate() }
        if let input {
            let data = Data(input.utf8)
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}

/// Lets a cancellation handler terminate a process that a background thread started.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Returns false if cancellation already happened; the caller then terminates the process itself.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            self.process = process
            return !cancelled
        }
    }

    func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }
}

/// Whether Xcode or the Command Line Tools are installed, found without running anything. Until one
/// is, `/usr/bin/git`, `xcrun` and similar are stubs that open macOS's install dialog when run.
public enum DeveloperTools {
    static let stubs: Set<String> = ["git", "xcrun", "xcodebuild", "swift", "clang", "make", "python3", "pip3"]

    static func isStub(_ path: String) -> Bool {
        path.hasPrefix("/usr/bin/") && stubs.contains(String(path.dropFirst("/usr/bin/".count)))
    }

    /// The selected developer folder (`DEVELOPER_DIR` or `xcode-select`'s link) or a default one exists.
    public static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        var folders: [String] = []
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty { folders.append(dir) }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            folders.append(link)
        }
        folders += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        return folders.contains { FileManager.default.fileExists(atPath: "\($0)/usr/bin") }
    }
}

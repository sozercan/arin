import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }

    public var lines: [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Runs tools with a timeout and a PATH that includes the usual developer bin dirs.
/// GUI apps start with a minimal PATH, so lookups would otherwise miss Homebrew, ~/.local/bin, etc.
public enum Shell {
    public static let searchPath: [String] = {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/go/bin", "/usr/local/go/bin", "/opt/homebrew/opt/go/libexec/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":").map(String.init) where !dirs.contains(dir) {
                dirs.append(dir)
            }
        }
        return dirs
    }()

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }

    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchPath {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: String? = nil,
        input: String? = nil,
        timeout: TimeInterval = 60
    ) async -> ShellResult {
        guard let exe = which(executable) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(executable): not found", timedOut: false)
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(exe, arguments, cwd: cwd, input: input, timeout: timeout))
            }
        }
    }

    private static func runBlocking(
        _ exe: String,
        _ arguments: [String],
        cwd: String?,
        input: String?,
        timeout: TimeInterval
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
        process.environment = environment
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

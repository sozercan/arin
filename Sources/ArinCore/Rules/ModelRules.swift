import Foundation

/// Models pulled into Ollama, removed with `ollama rm` so its manifests and shared layers stay consistent.
/// Needs the Ollama server running; without it nothing is listed.
struct OllamaModelRule: Rule {
    let id = "ollama.model"
    let name = "Ollama models"

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        guard Shell.which("ollama") != nil else { return [] }
        let list = await Shell.run("ollama", ["list"], timeout: 20)
        guard list.ok else { return [] }
        let loaded = await Shell.run("ollama", ["ps"], timeout: 20)
        let running = Set(Self.parseTable(loaded.ok ? loaded.stdout : "").map(\.name))
        return Self.parseTable(list.stdout).compactMap { model in
            guard Guardrails.allows(CommandSpec("ollama", ["rm", model.name])) else { return nil }
            return Candidate(
                ruleID: id,
                key: model.name,
                title: "Ollama model \(model.name)",
                detail: "`ollama pull \(model.name)` downloads it again. Models share layers, so removing one can free less than its size.",
                category: .models,
                level: .deep,
                risk: .review,
                bytes: model.bytes,
                paths: [],
                action: .commands([CommandSpec("ollama", ["rm", model.name])]),
                blockers: running.contains(model.name) ? ["loaded in Ollama right now"] : []
            )
        }
    }

    /// Rows of `ollama list` / `ollama ps`: columns separated by two or more spaces, header first.
    static func parseTable(_ output: String) -> [(name: String, bytes: Int64)] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: /\s{2,}/).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, !columns[0].isEmpty else { return nil }
            return (columns[0], parseSize(columns[2]) ?? 0)
        }
    }

    /// "4.7 GB", "274 MB". Ollama prints decimal units.
    static func parseSize(_ text: String) -> Int64? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let scale: Double = switch parts[1].uppercased() {
        case "B": 1
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 0
        }
        return scale > 0 ? Int64(value * scale) : nil
    }
}

/// Models downloaded by LM Studio, one folder per model under its models directory.
struct LMStudioModelRule: Rule {
    let id = "lmstudio.model"
    let name = "LM Studio models"
    static let roots = [".lmstudio/models", ".cache/lm-studio/models"]
    static let blocking = ["app:LM Studio", "lms"]

    func discover(_ ctx: ScanContext) async throws -> [Candidate] {
        var models: [String] = []
        for root in Self.roots {
            for publisher in FileInfo.children(ctx.path(root)) where FileInfo.isDirectory(publisher) && !FileInfo.isSymlink(publisher) {
                models += FileInfo.children(publisher).filter { FileInfo.isDirectory($0) && !FileInfo.isSymlink($0) }
            }
        }
        guard !models.isEmpty else { return [] }
        let sizes = await Size.allocated(models)
        return models.compactMap { path in
            guard let bytes = sizes[path] else { return nil }
            let publisher = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return Candidate(
                ruleID: id,
                key: path,
                title: "LM Studio model \(publisher)/\((path as NSString).lastPathComponent)",
                detail: "Downloaded weights. LM Studio can download it again from its model search.",
                category: .models,
                level: .deep,
                risk: .review,
                bytes: bytes,
                paths: [path],
                action: .delete([path]),
                lastModified: FileInfo.modified(path),
                blockers: ctx.state.blockers(paths: [path], processes: Self.blocking, minIdle: nil, now: ctx.now),
                blockingProcesses: Self.blocking
            )
        }
    }
}

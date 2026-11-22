import Foundation
import SwiftParser
import SwiftSyntax

struct Comment: Encodable {
    let path: String
    let line: Int
    let column: Int
    let text: String
}

func swiftComments(_ source: String, path: String) -> [Comment] {
    let tree = Parser.parse(source: source)
    let locations = SourceLocationConverter(fileName: path, tree: tree)
    var comments: [Comment] = []
    func collect(_ trivia: Trivia, at start: AbsolutePosition) {
        var position = start
        for piece in trivia {
            defer { position += piece.sourceLength }
            switch piece {
            case let .lineComment(text), let .blockComment(text), let .docLineComment(text), let .docBlockComment(text):
                let location = locations.location(for: position)
                if path == "Package.swift", location.line == 1, location.column == 1,
                   text.wholeMatch(of: #/// swift-tools-version: [0-9]+\.[0-9]+(?:\.[0-9]+)?/#) != nil {
                    continue
                }
                comments.append(Comment(path: path, line: location.line, column: location.column, text: text))
            default: break
            }
        }
    }
    for token in tree.tokens(viewMode: .sourceAccurate) {
        collect(token.leadingTrivia, at: token.position)
        collect(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
    }
    return comments
}

let shellPieces = try! NSRegularExpression(pattern: #"\$'(?:[^'\\]|\\.)*'|'[^']*'|"(?:[^"\\]|\\.)*"|\\.|\(\([^)]*\)\)|<<<|<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z_0-9]*)\2|(?<![^\s;&|()<>])#.*"#)
let yamlPieces = try! NSRegularExpression(pattern: #"'(?:[^']|'')*'|"(?:[^"\\]|\\.)*"|(?<!\S)#.*"#)
let scalar = #/(?:^|:\s+|^-\s+)[|>](?<indicators>[1-9+-]{0,2})\s*$/#
let actionVersion = #/\s*(?:-\s+)?uses:\s+[^@\s]+@[0-9a-f]{40}\s+# v[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.-]+)?\s*/#

func hashComments(_ source: String, path: String) -> [Comment] {
    let yaml = path.hasSuffix(".yml") || path.hasSuffix(".yaml")
    var block: (parent: Int, body: Int?, shell: Bool)?
    var hereDocs: [(delimiter: String, stripTabs: Bool)] = []
    var comments: [Comment] = []
    for (index, text) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let row = String(text)
        let line = index + 1
        let indent = row.prefix(while: { $0 == " " }).count
        if path == ".gitignore" {
            if row.hasPrefix("#") { comments.append(Comment(path: path, line: line, column: 1, text: row)) }
            continue
        }
        if !yaml, line == 1, row.hasPrefix("#!/") { continue }
        if row.allSatisfy(\.isWhitespace) { continue }
        if let current = block {
            if indent < (current.body ?? current.parent + 1) {
                block = nil
                hereDocs.removeAll()
            } else if current.body == nil {
                block?.body = indent
            }
        }
        let shell = !yaml || block?.shell == true
        if block != nil, !shell { continue }
        if shell, let hereDoc = hereDocs.first {
            let content = row.dropFirst(block?.body ?? 0)
            let delimiter = hereDoc.stripTabs ? content.drop(while: { $0 == "\t" }) : content
            if delimiter == hereDoc.delimiter { hereDocs.removeFirst() }
            continue
        }
        var yamlCode = row[...]
        let pieces = (shell ? shellPieces : yamlPieces).matches(in: row, range: NSRange(row.startIndex..., in: row))
        for piece in pieces {
            guard let range = Range(piece.range, in: row) else { continue }
            let text = row[range]
            if text.hasPrefix("#") {
                yamlCode = row[..<range.lowerBound]
                if shell || !path.hasPrefix(".github/workflows/") || row.wholeMatch(of: actionVersion) == nil {
                    let column = row[..<range.lowerBound].utf8.count + 1
                    comments.append(Comment(path: path, line: line, column: column, text: String(text)))
                }
            } else if shell, let delimiter = Range(piece.range(at: 3), in: row) {
                hereDocs.append((String(row[delimiter]), piece.range(at: 1).length > 0))
            }
        }
        if !shell, let marker = yamlCode.firstMatch(of: scalar) {
            let code = yamlCode.dropFirst(indent)
            let parent = indent + (code.hasPrefix("- ") ? 2 : 0)
            let body = marker.output.indicators.compactMap(\.wholeNumberValue).first.map { parent + $0 }
            block = (parent, body, code.hasPrefix("run:") || code.hasPrefix("- run:"))
        }
    }
    return comments
}

func xmlComments(_ source: String, path: String) -> [Comment] {
    source.matches(of: #/(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->/#).compactMap { match in
        guard match.output.hasPrefix("<!--") else { return nil }
        let lines = source[..<match.range.lowerBound].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return Comment(path: path, line: lines.count, column: (lines.last?.utf8.count ?? 0) + 1, text: String(match.output))
    }
}

typealias Baseline = [String: [String: Int]]

func readBaseline(_ path: String) throws -> Baseline {
    try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let inventory = arguments == ["--inventory"]
    guard arguments.isEmpty || inventory || (arguments.count == 2 && arguments.first == "--base") else {
        print("usage: Scripts/check-comments.sh [--inventory | --base <git-revision>]")
        return 2
    }
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    var comments: [Comment] = []
    for path in Set(input.split(separator: "\0").map(String.init)).sorted() {
        let ext = (path as NSString).pathExtension
        guard ["swift", "sh", "env", "yaml", "yml", "xml", "svg", "plist"].contains(ext) || path == ".gitignore" else { continue }
        let source: String
        do { source = try String(contentsOfFile: path, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        switch ext {
        case "swift": comments += swiftComments(source, path: path)
        case "xml", "svg", "plist": comments += xmlComments(source, path: path)
        default: comments += hashComments(source, path: path)
        }
    }
    if inventory {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(comments), as: UTF8.self))
        return 0
    }

    var allowed = try readBaseline(".comment-baseline.json")
    var failed = false
    if arguments.count == 2 {
        let base = try readBaseline(arguments[1])
        for (path, entries) in allowed {
            for (text, count) in entries where count > base[path, default: [:]][text, default: 0] {
                print("\(path): comment baseline grew: \(text.debugDescription)")
                failed = true
            }
        }
    }
    for comment in comments {
        let count = allowed[comment.path, default: [:]][comment.text, default: 0]
        if count > 0 {
            allowed[comment.path]?[comment.text] = count - 1
        } else {
            print("\(comment.path):\(comment.line):\(comment.column): new comment; delete it or record the decision in docs/adr/")
            failed = true
        }
    }
    for (path, entries) in allowed {
        for (text, count) in entries where count != 0 {
            print("\(path): stale baseline entry; update .comment-baseline.json: \(text.debugDescription)")
            failed = true
        }
    }
    return failed ? 1 : 0
}

do { exit(try run()) }
catch {
    FileHandle.standardError.write(Data("Comment lint: \(error)\n".utf8))
    exit(2)
}

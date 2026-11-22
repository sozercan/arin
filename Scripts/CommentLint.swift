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

let scalar = #/(?:^|:\s+|^-\s+)[|>](?<indicators>[1-9+-]{0,2})\s*$/#
let actionVersion = #/\s*(?:-\s+)?uses:\s+[^@\s]+@[0-9a-f]{40}\s+# v[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.-]+)?\s*/#

enum HashQuote {
    case single, double, ansi

    static func open(_ input: inout Substring, shell: Bool) -> Self? {
        if shell, input.hasPrefix("$'") { input.removeFirst(2); return .ansi }
        if input.first == "'" { input.removeFirst(); return .single }
        if input.first == "\"" { input.removeFirst(); return .double }
        return nil
    }

    func consume(_ input: inout Substring, shell: Bool) -> (text: Character?, closed: Bool) {
        let delimiter: Character = self == .double ? "\"" : "'"
        let head = input.removeFirst()
        if head == delimiter {
            if !shell, self == .single, input.first == "'" { return (input.removeFirst(), false) }
            return (nil, true)
        }
        if head == "\\", self != .single, let next = input.first {
            if self == .double, !shell || "$`\"\\".contains(next) { return (input.removeFirst(), false) }
            if self == .ansi {
                let escaped: [Character: Character] = ["a": "\u{7}", "b": "\u{8}", "e": "\u{1b}", "f": "\u{c}",
                                                       "n": "\n", "r": "\r", "t": "\t", "v": "\u{b}"]
                if let decoded = escaped[next] { input.removeFirst(); return (decoded, false) }
                if "\\'\"?".contains(next) { return (input.removeFirst(), false) }
            }
        }
        return (head, false)
    }
}

struct HereDocument {
    let delimiter: String
    let stripTabs: Bool

    static func parse(_ input: inout Substring) -> Self? {
        var rest = input.dropFirst(2)
        let stripTabs = rest.first == "-"
        if stripTabs { rest.removeFirst() }
        rest = rest.drop(while: \.isWhitespace)
        guard let head = rest.first, head != "#", !HashLexer.wordBoundary(head) else { return nil }
        var delimiter = ""
        while let character = rest.first, !HashLexer.wordBoundary(character) {
            if let quote = HashQuote.open(&rest, shell: true) {
                var closed = false
                while !rest.isEmpty, !closed {
                    let piece = quote.consume(&rest, shell: true)
                    if let text = piece.text { delimiter.append(text) }
                    closed = piece.closed
                }
                guard closed else { return nil }
            } else if rest.removeFirst() == "\\" {
                guard let escaped = rest.popFirst() else { return nil }
                delimiter.append(escaped)
            } else {
                delimiter.append(character)
            }
        }
        input = rest
        return Self(delimiter: delimiter, stripTabs: stripTabs)
    }

    func ends(at row: Substring) -> Bool {
        (stripTabs ? row.drop(while: { $0 == "\t" }) : row) == delimiter
    }
}

struct HashLexer {
    private struct Substitution {
        var depth = 1
        let enclosingQuote: HashQuote?
    }

    let shell: Bool
    private(set) var quote: HashQuote?
    private var arithmeticDepth = 0
    private var substitutions: [Substitution] = []
    private var continuedWordStart: Bool?
    private var pending: [HereDocument] = []
    private var hereDocs: [HereDocument] = []

    init(shell: Bool) {
        self.shell = shell
    }

    var unfinishedHereDoc: HereDocument? { hereDocs.first ?? pending.first }

    static func wordBoundary(_ character: Character) -> Bool {
        character.isWhitespace || ";&|()<>".contains(character)
    }

    mutating func scan(_ row: Substring) -> String.Index? {
        if let hereDoc = hereDocs.first {
            if hereDoc.ends(at: row) { hereDocs.removeFirst() }
            return nil
        }

        var rest = row
        var atWordStart = continuedWordStart ?? true
        var atYAMLScalarStart = true
        continuedWordStart = nil
        defer {
            if quote == nil, continuedWordStart == nil, arithmeticDepth == 0 {
                hereDocs = pending
                pending.removeAll()
            }
        }
        while let character = rest.first {
            if shell, arithmeticDepth > 0 {
                if character == "(" { arithmeticDepth += 1 }
                if character == ")" { arithmeticDepth -= 1 }
                rest.removeFirst()
                continue
            }
            if shell, quote == nil || quote == .double {
                if rest.hasPrefix("$((") || (quote == nil && atWordStart && rest.hasPrefix("((")) {
                    rest.removeFirst(character == "$" ? 3 : 2)
                    arithmeticDepth = 2
                    atWordStart = character != "$"
                    continue
                }
                if rest.hasPrefix("$(") {
                    rest.removeFirst(2)
                    substitutions.append(Substitution(enclosingQuote: quote))
                    quote = nil
                    atWordStart = true
                    continue
                }
            }
            if let active = quote {
                if active.consume(&rest, shell: shell).closed { quote = nil }
                atWordStart = false
                atYAMLScalarStart = false
                continue
            }
            let separated = rest.startIndex == row.startIndex || row[row.index(before: rest.startIndex)].isWhitespace
            if character == "#", shell ? atWordStart : separated { return rest.startIndex }
            if (shell || atYAMLScalarStart), let opened = HashQuote.open(&rest, shell: shell) {
                quote = opened
                atWordStart = false
                atYAMLScalarStart = false
                continue
            }
            if shell {
                if let substitution = substitutions.indices.last {
                    if character == "(" { substitutions[substitution].depth += 1 }
                    if character == ")" {
                        substitutions[substitution].depth -= 1
                        if substitutions[substitution].depth == 0 {
                            quote = substitutions.removeLast().enclosingQuote
                            atWordStart = false
                            rest.removeFirst()
                            continue
                        }
                    }
                }
                if rest.hasPrefix("<<<") {
                    rest.removeFirst(3)
                    atWordStart = true
                    continue
                }
                if rest.hasPrefix("<<"), let hereDoc = HereDocument.parse(&rest) {
                    pending.append(hereDoc)
                    atWordStart = false
                    continue
                }
                if character == "\\" {
                    rest.removeFirst()
                    if rest.popFirst() == nil { continuedWordStart = atWordStart }
                    atWordStart = false
                    continue
                }
                atWordStart = Self.wordBoundary(character)
                rest.removeFirst()
            } else {
                rest.removeFirst()
                let spaceFollows = rest.first?.isWhitespace == true
                if !character.isWhitespace {
                    atYAMLScalarStart = "[{,".contains(character)
                        || (character == ":" && (spaceFollows || rest.first == "\""))
                        || ((character == "-" || character == "?") && atYAMLScalarStart && spaceFollows)
                }
            }
        }
        return nil
    }
}

struct UnfinishedHereDocument: Error, CustomStringConvertible {
    let path: String
    let delimiter: String

    var description: String { "\(path): could not find the end of heredoc \(delimiter.debugDescription)" }
}

func hashComments(_ source: String, path: String) throws -> [Comment] {
    let yaml = path.hasSuffix(".yml") || path.hasSuffix(".yaml")
    var block: (parent: Int, body: Int?, shell: Bool)?
    var shellLexer = HashLexer(shell: true)
    var yamlLexer = HashLexer(shell: false)
    var comments: [Comment] = []
    var rows = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    if source.last?.isNewline == true { rows.removeLast() }
    for (index, text) in rows.enumerated() {
        let row = String(text)
        let line = index + 1
        let indent = row.prefix(while: { $0 == " " }).count
        if path == ".gitignore" {
            if row.hasPrefix("#") { comments.append(Comment(path: path, line: line, column: 1, text: row)) }
            continue
        }
        if !yaml, line == 1, row.hasPrefix("#!/") { continue }
        if let current = block, !row.allSatisfy(\.isWhitespace) {
            if indent < (current.body ?? current.parent + 1) {
                if let hereDoc = shellLexer.unfinishedHereDoc {
                    throw UnfinishedHereDocument(path: path, delimiter: hereDoc.delimiter)
                }
                block = nil
                shellLexer = HashLexer(shell: true)
            } else if current.body == nil {
                block?.body = indent
            }
        }
        let shell = !yaml || block?.shell == true
        if block != nil, !shell { continue }
        let start = shell ? shellLexer.scan(row.dropFirst(block?.body ?? 0)) : yamlLexer.scan(row[...])
        if let start, shell || !path.hasPrefix(".github/workflows/") || row.wholeMatch(of: actionVersion) == nil {
            let column = row[..<start].utf8.count + 1
            comments.append(Comment(path: path, line: line, column: column, text: String(row[start...])))
        }
        let yamlCode = row[..<(start ?? row.endIndex)]
        if !shell, yamlLexer.quote == nil, let marker = yamlCode.firstMatch(of: scalar) {
            let code = yamlCode.dropFirst(indent)
            let parent = indent + (code.hasPrefix("- ") ? 2 : 0)
            let body = marker.output.indicators.compactMap(\.wholeNumberValue).first.map { parent + $0 }
            block = (parent, body, code.hasPrefix("run:") || code.hasPrefix("- run:"))
        }
    }
    if let hereDoc = shellLexer.unfinishedHereDoc {
        throw UnfinishedHereDocument(path: path, delimiter: hereDoc.delimiter)
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
        default: comments += try hashComments(source, path: path)
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

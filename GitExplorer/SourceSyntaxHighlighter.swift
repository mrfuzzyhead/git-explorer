import SwiftUI

enum SourceLanguage: String, CaseIterable, Equatable, Sendable {
    case swift
    case objectiveC
    case cFamily
    case javascript
    case typescript
    case python
    case ruby
    case shell
    case rust
    case go
    case java
    case kotlin
    case html
    case css
    case json
    case yaml

    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["makefile", "dockerfile"].contains(name) {
            self = .shell
            return
        }
        switch ext {
        case "swift": self = .swift
        case "m", "mm": self = .objectiveC
        case "c", "h", "cc", "cpp", "cxx", "hpp": self = .cFamily
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "py", "pyw": self = .python
        case "rb": self = .ruby
        case "sh", "bash", "zsh", "fish": self = .shell
        case "rs": self = .rust
        case "go": self = .go
        case "java": self = .java
        case "kt", "kts": self = .kotlin
        case "html", "htm", "xml", "svg": self = .html
        case "css", "scss", "sass", "less": self = .css
        case "json", "jsonc": self = .json
        case "yml", "yaml": self = .yaml
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .objectiveC: "Objective-C"
        case .cFamily: "C / C++"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .html: "HTML / XML"
        case .json: "JSON"
        case .yaml: "YAML"
        default: rawValue.capitalized
        }
    }

    fileprivate var lineCommentMarkers: [String] {
        switch self {
        case .python, .ruby, .shell, .yaml: ["#"]
        case .html: []
        default: ["//"]
        }
    }

    fileprivate var blockCommentMarkers: (start: String, end: String)? {
        switch self {
        case .html: ("<!--", "-->")
        case .python, .ruby, .shell, .yaml: nil
        default: ("/*", "*/")
        }
    }

    fileprivate var keywords: Set<String> {
        switch self {
        case .swift:
            ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
             "class", "continue", "default", "defer", "do", "else", "enum", "extension",
             "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import",
             "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open",
             "operator", "private", "protocol", "public", "repeat", "return", "self", "some",
             "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
             "try", "typealias", "var", "where", "while"]
        case .javascript, .typescript:
            ["as", "async", "await", "break", "case", "catch", "class", "const", "continue",
             "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
             "false", "finally", "for", "from", "function", "if", "implements", "import",
             "in", "instanceof", "interface", "let", "new", "null", "of", "private",
             "protected", "public", "return", "static", "super", "switch", "this", "throw",
             "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "case", "class", "continue",
             "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
             "global", "if", "import", "in", "is", "lambda", "match", "None", "nonlocal",
             "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .rust:
            ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
             "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
             "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
             "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where",
             "while"]
        case .go:
            ["break", "case", "chan", "const", "continue", "default", "defer", "else",
             "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
             "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .ruby:
            ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do",
             "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
             "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
             "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case .java, .kotlin, .objectiveC, .cFamily:
            ["abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const",
             "continue", "default", "do", "double", "else", "enum", "extends", "false",
             "final", "float", "for", "fun", "if", "implements", "import", "in", "inline",
             "instanceof", "int", "interface", "long", "namespace", "new", "nil", "null",
             "operator", "override", "package", "private", "protected", "protocol", "public",
             "return", "short", "signed", "static", "struct", "super", "switch", "template",
             "this", "throw", "throws", "true", "try", "typedef", "typename", "unsigned",
             "using", "val", "var", "virtual", "void", "volatile", "when", "while"]
        case .shell:
            ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function",
             "if", "in", "local", "readonly", "select", "then", "until", "while"]
        case .html:
            []
        case .css:
            ["and", "from", "important", "media", "not", "only", "or", "supports", "to", "var"]
        case .json:
            ["false", "null", "true"]
        case .yaml:
            ["false", "null", "true", "yes", "no"]
        }
    }
}

struct SourceToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case plain
        case keyword
        case string
        case comment
        case number
    }

    let kind: Kind
    let text: String
}

enum SourceSyntaxHighlighter {
    static func highlight(_ source: String, as language: SourceLanguage) -> AttributedString {
        var result = AttributedString()
        for token in tokens(in: source, as: language) {
            var fragment = AttributedString(token.text)
            switch token.kind {
            case .plain:
                break
            case .keyword:
                fragment.foregroundColor = .purple
            case .string:
                fragment.foregroundColor = .red
            case .comment:
                fragment.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .number:
                fragment.foregroundColor = .blue
            }
            result.append(fragment)
        }
        return result
    }

    static func tokens(in source: String, as language: SourceLanguage) -> [SourceToken] {
        var result: [SourceToken] = []
        var index = source.startIndex

        func append(_ kind: SourceToken.Kind, through end: String.Index) {
            result.append(SourceToken(kind: kind, text: String(source[index..<end])))
            index = end
        }

        while index < source.endIndex {
            if let marker = language.lineCommentMarkers.first(where: {
                source[index...].hasPrefix($0)
            }) {
                let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
                append(.comment, through: lineEnd)
                if index < source.endIndex, source[index] == "\n" {
                    append(.plain, through: source.index(after: index))
                }
                _ = marker
                continue
            }

            if let markers = language.blockCommentMarkers,
               source[index...].hasPrefix(markers.start) {
                let bodyStart = source.index(index, offsetBy: markers.start.count)
                if let closing = source.range(of: markers.end, range: bodyStart..<source.endIndex) {
                    append(.comment, through: closing.upperBound)
                } else {
                    append(.comment, through: source.endIndex)
                }
                continue
            }

            let character = source[index]
            if character == "\"" || character == "'" || character == "`" {
                let quote = character
                var cursor = source.index(after: index)
                var escaped = false
                while cursor < source.endIndex {
                    let current = source[cursor]
                    cursor = source.index(after: cursor)
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == quote {
                        break
                    }
                }
                append(.string, through: cursor)
                continue
            }

            if character.isNumber {
                var cursor = source.index(after: index)
                while cursor < source.endIndex {
                    let current = source[cursor]
                    guard current.isNumber || current == "." || current == "_" else { break }
                    cursor = source.index(after: cursor)
                }
                append(.number, through: cursor)
                continue
            }

            if character.isLetter || character == "_" {
                var cursor = source.index(after: index)
                while cursor < source.endIndex {
                    let current = source[cursor]
                    guard current.isLetter || current.isNumber || current == "_" else { break }
                    cursor = source.index(after: cursor)
                }
                let word = String(source[index..<cursor])
                append(language.keywords.contains(word) ? .keyword : .plain, through: cursor)
                continue
            }

            append(.plain, through: source.index(after: index))
        }

        return coalescing(result)
    }

    private static func coalescing(_ tokens: [SourceToken]) -> [SourceToken] {
        tokens.reduce(into: []) { result, token in
            if let last = result.last, last.kind == token.kind {
                result[result.count - 1] = SourceToken(kind: token.kind, text: last.text + token.text)
            } else {
                result.append(token)
            }
        }
    }
}

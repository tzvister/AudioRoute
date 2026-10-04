import Foundation

/// Deliberately small YAML subset: indentation mappings/sequences, flow collections,
/// UTF-8 strings, finite numbers, true/false/null. No aliases, tags, or executable objects.
enum RestrictedYAML {
    private struct Line { let number: Int; let indent: Int; let text: String }

    static func parse(_ text: String) throws -> Any {
        var lines: [Line] = []
        var ended = false, started = false
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            guard !raw.contains("\t") else { throw ConfigurationError("YAML line \(offset + 1): use spaces instead of tabs.") }
            let stripped = try stripComment(raw).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped == "---" {
                guard !started, lines.isEmpty else { throw ConfigurationError("Only one YAML document is supported.") }
                started = true; continue
            }
            if stripped == "..." { ended = true; continue }
            guard !ended else { throw ConfigurationError("Content after YAML document end is not supported.") }
            let indent = raw.prefix(while: { $0 == " " }).count
            lines.append(Line(number: offset + 1, indent: indent, text: stripped))
        }
        guard !lines.isEmpty else { throw ConfigurationError("Configuration is empty.") }
        guard lines[0].indent == 0 else { throw ConfigurationError("YAML root must start at column one.") }
        let parser = Parser(lines)
        let result = try parser.block(indent: 0, depth: 0)
        guard parser.index == lines.count else { throw ConfigurationError("YAML line \(lines[parser.index].number): inconsistent indentation.") }
        return result
    }

    private final class Parser {
        let lines: [Line]
        var index = 0
        init(_ lines: [Line]) { self.lines = lines }
        func block(indent: Int, depth: Int) throws -> Any {
            guard depth <= 64 else { throw ConfigurationError("YAML nesting exceeds 64 levels.") }
            if lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                var values: [Any] = []
                while index < lines.count, lines[index].indent == indent {
                    let line = lines[index]
                    guard line.text == "-" || line.text.hasPrefix("- ") else { throw ConfigurationError("YAML line \(line.number): cannot mix sequence and mapping entries.") }
                    let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                    index += 1
                    if rest.isEmpty {
                        guard index < lines.count, lines[index].indent > indent else { throw ConfigurationError("YAML line \(line.number): sequence item requires a value.") }
                        values.append(try block(indent: lines[index].indent, depth: depth + 1))
                    } else {
                        values.append(try scalar(rest, depth: depth + 1))
                        if index < lines.count, lines[index].indent > indent { throw ConfigurationError("YAML line \(lines[index].number): inline sequence values cannot have nested content.") }
                    }
                }
                return values
            }
            var values: [String: Any] = [:]
            while index < lines.count, lines[index].indent == indent {
                let line = lines[index]
                guard let colon = try separator(line.text, character: ":", requireWhitespaceAfter: true) else { throw ConfigurationError("YAML line \(line.number): expected key: value.") }
                let rawKey = String(line.text[..<colon]).trimmingCharacters(in: .whitespaces)
                let key = try mappingKey(rawKey)
                guard values[key] == nil else { throw ConfigurationError("YAML line \(line.number): duplicate key '\(key)'.") }
                let rest = String(line.text[line.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                index += 1
                if rest.isEmpty {
                    guard index < lines.count, lines[index].indent > indent else { throw ConfigurationError("YAML line \(line.number): '\(key)' requires a value or nested mapping.") }
                    values[key] = try block(indent: lines[index].indent, depth: depth + 1)
                } else {
                    values[key] = try scalar(rest, depth: depth + 1)
                    if index < lines.count, lines[index].indent > indent { throw ConfigurationError("YAML line \(lines[index].number): unexpected indentation after scalar '\(key)'.") }
                }
            }
            return values
        }
    }

    private static func mappingKey(_ text: String) throws -> String {
        guard !text.isEmpty, text != "<<" else { throw ConfigurationError("YAML empty keys and merge keys are not supported.") }
        if text.first == "\"" || text.first == "'" {
            guard let result = try scalar(text, depth: 0) as? String else { throw ConfigurationError("YAML keys must be strings.") }
            return result
        }
        guard !text.contains(where: { "{}[],&*!".contains($0) }) else { throw ConfigurationError("Unsupported YAML key '\(text)'.") }
        return text
    }

    private static func scalar(_ text: String, depth: Int) throws -> Any {
        guard depth <= 64 else { throw ConfigurationError("YAML nesting exceeds 64 levels.") }
        guard !text.isEmpty else { throw ConfigurationError("Empty YAML scalar.") }
        if text.first == "\"" {
            guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw ConfigurationError("Invalid double-quoted YAML string; use JSON string escapes.") }
            return value
        }
        if text.first == "'" {
            guard text.count >= 2, text.last == "'" else { throw ConfigurationError("Unterminated single-quoted YAML string.") }
            let content = String(text.dropFirst().dropLast())
            var i = content.startIndex, value = ""
            while i < content.endIndex {
                if content[i] == "'" {
                    let next = content.index(after: i)
                    guard next < content.endIndex, content[next] == "'" else { throw ConfigurationError("Escape a single quote by doubling it in YAML.") }
                    value.append("'"); i = content.index(after: next)
                } else { value.append(content[i]); i = content.index(after: i) }
            }
            return value
        }
        if text.first == "[" {
            guard text.last == "]" else { throw ConfigurationError("Unterminated YAML flow sequence.") }
            let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return [Any]() }
            return try splitFlow(inner).map { try scalar($0, depth: depth + 1) }
        }
        if text.first == "{" {
            guard text.last == "}" else { throw ConfigurationError("Unterminated YAML flow mapping.") }
            let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return [String: Any]() }
            var result: [String: Any] = [:]
            for entry in try splitFlow(inner) {
                guard let colon = try separator(entry, character: ":", requireWhitespaceAfter: false) else { throw ConfigurationError("Flow mapping entries require key: value.") }
                let key = try mappingKey(String(entry[..<colon]).trimmingCharacters(in: .whitespaces))
                guard result[key] == nil else { throw ConfigurationError("Duplicate YAML key '\(key)'.") }
                let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result[key] = try scalar(value, depth: depth + 1)
            }
            return result
        }
        if text == "true" { return true }; if text == "false" { return false }
        if text == "null" || text == "~" { return NSNull() }
        if text.range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil {
            guard let integer = Int(text) else { throw ConfigurationError("YAML integer is out of range.") }
            return integer
        }
        if text.range(of: "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil {
            guard let number = Double(text), number.isFinite else { throw ConfigurationError("YAML number must be finite.") }
            return number
        }
        if [".nan", ".inf", "+.inf", "-.inf"].contains(text.lowercased()) { throw ConfigurationError("YAML numbers must be finite.") }
        guard !"&*!|>".contains(text.first!), text.first != "%" else { throw ConfigurationError("YAML aliases, anchors, tags, directives, and multiline scalars are not supported. Use plain or quoted values.") }
        return text
    }

    private static func splitFlow(_ text: String) throws -> [String] {
        var result: [String] = [], start = text.startIndex, cursor = text.startIndex
        while cursor < text.endIndex {
            let tail = String(text[cursor...])
            guard let found = try separator(tail, character: ",", requireWhitespaceAfter: false) else { break }
            let index = text.index(cursor, offsetBy: tail.distance(from: tail.startIndex, to: found))
            let value = String(text[start..<index]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw ConfigurationError("Empty YAML flow item.") }
            result.append(value); cursor = text.index(after: index); start = cursor
        }
        let value = String(text[start...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw ConfigurationError("Trailing YAML flow commas are not supported.") }
        result.append(value)
        return result
    }

    private static func separator(_ text: String, character: Character, requireWhitespaceAfter: Bool) throws -> String.Index? {
        var quote: Character?, escaped = false, depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let active = quote {
                if escaped { escaped = false }
                else if active == "\"" && c == "\\" { escaped = true }
                else if c == active {
                    let next = text.index(after: index)
                    if active == "'", next < text.endIndex, text[next] == "'" { index = next }
                    else { quote = nil }
                }
            } else if (c == "\"" || c == "'"), index == text.startIndex || text[text.index(before: index)].isWhitespace || "[:,{".contains(text[text.index(before: index)]) { quote = c }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" {
                depth -= 1; guard depth >= 0 else { throw ConfigurationError("Unbalanced YAML flow collection.") }
            } else if depth == 0 && c == character {
                let next = text.index(after: index)
                if !requireWhitespaceAfter || next == text.endIndex || text[next].isWhitespace { return index }
            }
            index = text.index(after: index)
        }
        guard quote == nil, depth == 0 else { throw ConfigurationError("Unterminated YAML quote or flow collection.") }
        return nil
    }

    private static func stripComment(_ text: String) throws -> String {
        // YAML comments begin after whitespace, so coreaudio UIDs and strings retain '#'.
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let tail = String(text[cursor...])
            guard let found = try separator(tail, character: "#", requireWhitespaceAfter: false) else { break }
            let hash = text.index(cursor, offsetBy: tail.distance(from: tail.startIndex, to: found))
            if hash == text.startIndex || text[text.index(before: hash)].isWhitespace { return String(text[..<hash]) }
            cursor = text.index(after: hash)
        }
        return text
    }
}

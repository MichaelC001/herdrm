import Foundation

/// Extra CLI arguments appended to an agent's command on `agent.start`, written
/// as one shell-style string (`--auto high`, `'--model' "gpt 5"`).
public enum AgentLaunchArguments {
    /// Flags that put a kind's CLI into YOLO (bypass-permissions) mode. Only kinds
    /// with a flag verified against vendor docs or `--help` are listed; nil = no
    /// known YOLO mode, and the UI hides the YOLO option for that kind.
    public static func yoloArguments(for kind: String) -> String? {
        switch kind {
        case "claude", "agy", "qodercli": return "--dangerously-skip-permissions"
        case "codex": return "--dangerously-bypass-approvals-and-sandbox"
        case "droid": return "--auto high"
        case "grok": return "--always-approve"
        case "gemini", "kimi", "hermes", "muse": return "--yolo"
        case "opencode": return "--auto"
        case "cursor": return "--force"
        case "copilot": return "--allow-all-tools"
        case "devin": return "--permission-mode dangerous"
        case "cline": return "--auto-approve true"
        case "kiro": return "--trust-all-tools"
        case "amp": return "--dangerously-allow-all"
        case "qwen": return "--approval-mode yolo"
        default: return nil
        }
    }

    public enum ParseError: Error, Equatable {
        case unterminatedQuote
    }

    /// Splits like a POSIX shell without expansion: whitespace separates words,
    /// single quotes are literal, double quotes honor `\"` `\\` `\$` `` \` ``,
    /// and a bare backslash escapes the next character.
    public static func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(text).makeIterator()

        while let char = iterator.next() {
            switch char {
            case " ", "\t", "\n", "\r":
                if inWord {
                    tokens.append(current)
                    current = ""
                    inWord = false
                }
            case "'":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "'" { closed = true; break }
                    current.append(next)
                }
                if !closed { throw ParseError.unterminatedQuote }
            case "\"":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "\"" { closed = true; break }
                    if next == "\\" {
                        guard let escaped = iterator.next() else { break }
                        if "\"\\$`".contains(escaped) {
                            current.append(escaped)
                        } else if escaped != "\n" {
                            current.append(next)
                            current.append(escaped)
                        }
                        continue
                    }
                    current.append(next)
                }
                if !closed { throw ParseError.unterminatedQuote }
            case "\\":
                inWord = true
                if let escaped = iterator.next(), escaped != "\n" {
                    current.append(escaped)
                }
            default:
                inWord = true
                current.append(char)
            }
        }
        if inWord { tokens.append(current) }
        return tokens
    }

    /// Joins tokens back into a string `tokenize` round-trips.
    public static func join(_ tokens: [String]) -> String {
        tokens.map(quote).joined(separator: " ")
    }

    static func quote(_ token: String) -> String {
        if token.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=./:,@%+"))
        if token.unicodeScalars.allSatisfy(safe.contains) { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether `text` already carries the kind's YOLO flags as a contiguous run.
    public static func containsYolo(_ text: String, kind: String) -> Bool {
        guard let yolo = yoloArguments(for: kind),
              let yoloTokens = try? tokenize(yolo),
              let tokens = try? tokenize(text)
        else { return false }
        return range(of: yoloTokens, in: tokens) != nil
    }

    /// Adds or removes the kind's YOLO flags, leaving the user's other
    /// arguments untouched. Adding appends textually so custom quoting survives.
    public static func setYolo(_ enabled: Bool, in text: String, kind: String) -> String {
        guard let yolo = yoloArguments(for: kind),
              let yoloTokens = try? tokenize(yolo)
        else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var tokens = try? tokenize(trimmed) else {
            return enabled ? (trimmed.isEmpty ? yolo : "\(trimmed) \(yolo)") : text
        }
        if enabled {
            if range(of: yoloTokens, in: tokens) != nil { return trimmed }
            return trimmed.isEmpty ? yolo : "\(trimmed) \(yolo)"
        }
        guard range(of: yoloTokens, in: tokens) != nil else { return trimmed }
        while let found = range(of: yoloTokens, in: tokens) {
            tokens.removeSubrange(found)
        }
        return join(tokens)
    }

    private static func range(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start..<(start + needle.count)
        }
        return nil
    }
}

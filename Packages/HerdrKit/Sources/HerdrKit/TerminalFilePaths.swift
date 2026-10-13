import Foundation

/// A file path printed in a terminal row, as found under the pointer.
public struct FilePathCandidate: Equatable, Sendable {
    /// Exactly as printed, for copying (`src/index.ts:42:7`, `file:///a%20b`).
    public let text: String
    /// The path part, decoded: `~` and relative forms kept for `resolve`.
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(text: String, path: String, line: Int?, column: Int?) {
        self.text = text
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Finds file paths in terminal text the way an editor's "semantic history"
/// does, without knowing the disk: the caller checks that the resolved path
/// exists before treating it as a link, which is what keeps `README.md` in a
/// sentence from becoming one.
public enum TerminalFilePaths {
    /// Characters that end a path token. Spaces too, since a path with spaces
    /// cannot be told from two tokens without the disk; the caller's existence
    /// check would reject the first half anyway.
    private static let delimiters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'`<>()[]{}|,;"))
    /// Trailing characters that are punctuation of the sentence, not the path.
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    /// The path-looking token under UTF-16 `offset` in `text`, or nil when the
    /// token there is a word, a number, a web address or nothing.
    public static func candidate(in text: String, at offset: Int) -> FilePathCandidate? {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length else { return nil }

        // Expand from the pointer to the delimiters on both sides.
        var start = offset
        while start > 0, !isDelimiter(ns.character(at: start - 1)) { start -= 1 }
        var end = offset
        while end < ns.length, !isDelimiter(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        var token = ns.substring(with: NSRange(location: start, length: end - start))

        // Sentence punctuation after the path (`/tmp/x.log.` or `src/a.rs:`).
        while let last = token.unicodeScalars.last, trailingPunctuation.contains(last) {
            token.removeLast()
        }
        guard !token.isEmpty else { return nil }

        // Web addresses and mail belong to the URL detector.
        let lower = token.lowercased()
        if lower.contains("://"), !lower.hasPrefix("file://") { return nil }
        if token.contains("@"), !token.contains("/") { return nil }

        var path: String
        var rest = ""
        if lower.hasPrefix("file://") {
            guard let url = URL(string: token), url.isFileURL else { return nil }
            path = url.path
            if path.isEmpty { return nil }
        } else {
            // `path:line[:col]`, where line and column are plain integers.
            (path, rest) = splitPosition(token)
        }
        guard looksLikePath(path) else { return nil }

        var line: Int?
        var column: Int?
        if !rest.isEmpty {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            line = parts.first.flatMap(Int.init)
            column = parts.count > 1 ? Int(parts[1]) : nil
        }
        return FilePathCandidate(text: token, path: path, line: line, column: column)
    }

    /// Absolute path for a candidate: `~` expanded, a relative path joined to
    /// `cwd` (nil when there is no cwd to anchor it), `.` and `..` resolved.
    public static func resolve(path: String, cwd: String?, home: String) -> String? {
        var full: String
        if path.hasPrefix("~/") || path == "~" {
            full = home + path.dropFirst(1)
        } else if path.hasPrefix("/") {
            full = path
        } else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            full = (cwd as NSString).appendingPathComponent(path)
        }
        full = (full as NSString).standardizingPath
        return full.hasPrefix("/") ? full : nil
    }

    // MARK: - Helpers

    private static func isDelimiter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return delimiters.contains(scalar)
    }

    /// Peels `:line` and `:line:col` off the end; anything else after a colon
    /// stays part of the path (a colon is legal in a file name).
    private static func splitPosition(_ token: String) -> (path: String, rest: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return (token, "") }
        var pathParts = parts
        var position: [String] = []
        for part in parts.suffix(2).reversed() {
            if !part.isEmpty, part.allSatisfy(\.isNumber), position.count < 2 {
                position.insert(part, at: 0)
                pathParts.removeLast()
            } else {
                break
            }
        }
        guard !position.isEmpty else { return (token, "") }
        return (pathParts.joined(separator: ":"), position.joined(separator: ":"))
    }

    /// Anchored (`/`, `~/`, `./`, `../`), has a directory part, or is a bare
    /// file name with an extension (`README.md`). Numbers (`1.2.3`) and single
    /// letters before a dot (`e.g.`) are not file names.
    private static func looksLikePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") {
            return path.count > 1
        }
        if path.contains("/") { return true }
        let name = path
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex, dot < name.index(before: name.endIndex) else {
            return false
        }
        let stem = name[..<dot]
        let ext = name[name.index(after: dot)...]
        guard stem.count >= 2, ext.count <= 12, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // `1.2` and `e.g` are not files; a stem needs a letter and the extension too.
        return stem.contains(where: \.isLetter) && ext.contains(where: \.isLetter)
    }
}

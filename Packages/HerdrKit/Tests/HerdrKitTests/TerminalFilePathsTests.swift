import Foundation
import XCTest
@testable import HerdrKit

private func candidate(_ text: String, at marker: String = "|") -> FilePathCandidate? {
    // The marker shows where the pointer is; it is removed before matching.
    let offset = (text as NSString).range(of: marker).location
    let stripped = text.replacingOccurrences(of: marker, with: "")
    return TerminalFilePaths.candidate(in: stripped, at: offset)
}

final class TerminalFilePathsTests: XCTestCase {
    func testAbsolutePathUnderThePointer() {
        let found = candidate("see /Users/me/wo|rk/README.md and more")
        XCTAssertEqual(found?.text, "/Users/me/work/README.md")
        XCTAssertEqual(found?.path, "/Users/me/work/README.md")
        XCTAssertNil(found?.line)
    }

    func testRelativePathWithLineAndColumn() {
        let found = candidate("error in src/in|dex.ts:42:7: unexpected token")
        XCTAssertEqual(found?.text, "src/index.ts:42:7")
        XCTAssertEqual(found?.path, "src/index.ts")
        XCTAssertEqual(found?.line, 42)
        XCTAssertEqual(found?.column, 7)
    }

    func testTildeAndDotRelativePaths() {
        XCTAssertEqual(candidate("cat ~/no|tes.txt")?.path, "~/notes.txt")
        XCTAssertEqual(candidate("run ./bin/se|tup")?.path, "./bin/setup")
        XCTAssertEqual(candidate("cd ../pa|rent")?.path, "../parent")
    }

    func testBareFileNameWithExtensionCounts_butPlainWordsDoNot() {
        XCTAssertEqual(candidate("edit READ|ME.md")?.path, "README.md")
        XCTAssertEqual(candidate("edit Pack|age.swift")?.path, "Package.swift")
        XCTAssertNil(candidate("just a wo|rd here"))
        XCTAssertNil(candidate("version 1.2|.3"))   // digits only, not a file
        XCTAssertNil(candidate("e.|g. this"))
    }

    func testFileURLsDecodeToPaths() {
        let found = candidate("open file:///Users/me/a%20b/x.|md now")
        XCTAssertEqual(found?.text, "file:///Users/me/a%20b/x.md")
        XCTAssertEqual(found?.path, "/Users/me/a b/x.md")
    }

    func testSurroundingPunctuationAndQuotesAreDropped() {
        XCTAssertEqual(candidate("(see /tmp/o|ut.log).")?.path, "/tmp/out.log")
        XCTAssertEqual(candidate("'/tmp/o|ut.log',")?.path, "/tmp/out.log")
        XCTAssertEqual(candidate("\"src/a|.rs\":")?.path, "src/a.rs")
        XCTAssertEqual(candidate("<src/a|.rs>")?.path, "src/a.rs")
        XCTAssertEqual(candidate("[/var/l|og/x]")?.path, "/var/log/x")
    }

    func testPointerOutsideTheTokenFindsNothing() {
        XCTAssertNil(candidate("see /tmp/x.log a|nd"))
        XCTAssertNil(candidate("see| /tmp/x.log"))
    }

    func testWebURLsAreNotPaths() {
        XCTAssertNil(candidate("go to https://exa|mple.com/a/b.html"))
        XCTAssertNil(candidate("mail me|@example.com"))
    }

    func testResolveJoinsRelativeToCwdAndExpandsTilde() {
        let home = "/Users/me"
        XCTAssertEqual(TerminalFilePaths.resolve(path: "src/a.rs", cwd: "/repo", home: home), "/repo/src/a.rs")
        XCTAssertEqual(TerminalFilePaths.resolve(path: "./src/../a.rs", cwd: "/repo", home: home), "/repo/a.rs")
        XCTAssertEqual(TerminalFilePaths.resolve(path: "~/x", cwd: "/repo", home: home), "/Users/me/x")
        XCTAssertEqual(TerminalFilePaths.resolve(path: "/abs/x", cwd: "/repo", home: home), "/abs/x")
        XCTAssertEqual(TerminalFilePaths.resolve(path: "/abs/x", cwd: nil, home: home), "/abs/x")
        // A relative path with no cwd to anchor it cannot be resolved.
        XCTAssertNil(TerminalFilePaths.resolve(path: "src/a.rs", cwd: nil, home: home))
    }
}

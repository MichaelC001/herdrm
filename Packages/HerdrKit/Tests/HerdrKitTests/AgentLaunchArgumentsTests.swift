import XCTest
@testable import HerdrKit

final class AgentLaunchArgumentsTests: XCTestCase {
    func testTokenizeHandlesQuotesAndEscapes() throws {
        XCTAssertEqual(try AgentLaunchArguments.tokenize("--auto high"), ["--auto", "high"])
        XCTAssertEqual(
            try AgentLaunchArguments.tokenize("'--dangerously-skip-permissions'"),
            ["--dangerously-skip-permissions"]
        )
        XCTAssertEqual(
            try AgentLaunchArguments.tokenize(#"--model "gpt 5" --x a\ b --y 'it'\''s'"#),
            ["--model", "gpt 5", "--x", "a b", "--y", "it's"]
        )
        XCTAssertEqual(try AgentLaunchArguments.tokenize("  "), [])
        XCTAssertEqual(try AgentLaunchArguments.tokenize("--empty ''"), ["--empty", ""])
    }

    func testTokenizeRejectsUnterminatedQuote() {
        XCTAssertThrowsError(try AgentLaunchArguments.tokenize("--model 'gpt"))
        XCTAssertThrowsError(try AgentLaunchArguments.tokenize(#"--model "gpt"#))
    }

    func testJoinRoundTrips() throws {
        let tokens = ["--model", "gpt 5", "it's", "", "--plain=ok"]
        XCTAssertEqual(try AgentLaunchArguments.tokenize(AgentLaunchArguments.join(tokens)), tokens)
    }

    func testSetYoloAddsOnceAndRemovesMultiTokenFlag() {
        let on = AgentLaunchArguments.setYolo(true, in: "--model x", kind: "droid")
        XCTAssertEqual(on, "--model x --auto high")
        XCTAssertTrue(AgentLaunchArguments.containsYolo(on, kind: "droid"))
        XCTAssertEqual(AgentLaunchArguments.setYolo(true, in: on, kind: "droid"), on)
        XCTAssertEqual(AgentLaunchArguments.setYolo(false, in: on, kind: "droid"), "--model x")
        XCTAssertFalse(AgentLaunchArguments.containsYolo("--auto medium", kind: "droid"))
    }

    func testQuotedYoloFlagCounts() {
        XCTAssertTrue(AgentLaunchArguments.containsYolo("'--dangerously-skip-permissions'", kind: "agy"))
        XCTAssertEqual(AgentLaunchArguments.setYolo(false, in: "'--dangerously-skip-permissions'", kind: "agy"), "")
    }

    func testKindWithoutYoloIsUntouched() {
        XCTAssertNil(AgentLaunchArguments.yoloArguments(for: "pi"))
        XCTAssertEqual(AgentLaunchArguments.setYolo(true, in: "--foo", kind: "pi"), "--foo")
    }
}

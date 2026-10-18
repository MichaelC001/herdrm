#if os(macOS)
import XCTest
@testable import HerdrKit

final class ProjectProbeRunnerTests: XCTestCase {
    func testSafeCwdsDropsBackslashQuoteAndControlCharacters() {
        let input = ["/home/dev/app", "/home/dev/it's", "/home/dev/a\\b", "/home/dev/a\nb", "/home/dev/a\u{7f}b", "/home/dev/ok dir"]
        XCTAssertEqual(DeviceProjectProbeRunner.safeCwds(input), ["/home/dev/app", "/home/dev/ok dir"])
    }
}
#endif

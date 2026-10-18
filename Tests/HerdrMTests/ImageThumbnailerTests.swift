import XCTest
@testable import herdrm

final class ImageThumbnailerTests: XCTestCase {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testLargeImageIsDownscaledToTheBudget() throws {
        let url = try writePNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(ImageThumbnailer.thumbnail(contentsOf: url))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 512)
        XCTAssertEqual(min(rep.pixelsWide, rep.pixelsHigh), 256)
    }

    func testSmallImageIsNotUpscaled() throws {
        let url = try writePNG(width: 40, height: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let rep = try XCTUnwrap(ImageThumbnailer.thumbnail(contentsOf: url)?.representations.first)
        XCTAssertEqual(rep.pixelsWide, 40); XCTAssertEqual(rep.pixelsHigh, 30)
    }

    func testNonImageFileYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).txt")
        try "not an image".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ImageThumbnailer.thumbnail(contentsOf: url))
    }

    func testPasteboardImageIsRead() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        // A bitmap-backed image: a rep-less NSImage declares TIFF on the pasteboard but encodes no data.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let source = NSImage(size: NSSize(width: 8, height: 8))
        source.addRepresentation(rep)
        pasteboard.writeObjects([source])
        XCTAssertNotNil(ImageThumbnailer.thumbnail(from: pasteboard))
        XCTAssertNil(ImageThumbnailer.thumbnail(from: { let p = NSPasteboard.withUniqueName(); p.clearContents(); p.setString("x", forType: .string); return p }()))
    }
}

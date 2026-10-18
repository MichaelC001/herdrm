import AppKit
import ImageIO

/// Decodes images into small, bounded thumbnails for the image boxes drawn over the terminal.
///
/// Every path goes through one ImageIO call, so the size rules live in one place: the longest side
/// is at most `maxPixelSize` pixels, smaller images are never upscaled, and EXIF orientation is applied.
enum ImageThumbnailer {
    /// Longest-side budget, in pixels, for a decoded thumbnail.
    static let maxPixelSize = 512

    /// Decodes the image file at `url`; nil when the file is not a decodable image.
    static func thumbnail(contentsOf url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    /// The first image on `pasteboard`, downscaled; nil when it holds none.
    static func thumbnail(from pasteboard: NSPasteboard) -> NSImage? {
        guard let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first else { return nil }
        return thumbnail(of: image)
    }

    /// `image`, downscaled. For an image read from the pasteboard on the main
    /// thread and handed to a background queue for this step.
    static func thumbnail(of image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil)
        else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> NSImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        // ThumbnailMaxPixelSize alone can upscale small images, so cap it at the source's own size.
        var longestSide = maxPixelSize
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            longestSide = min(maxPixelSize, max(width, height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A bitmap rep (1 pixel per point) rather than `NSImage(cgImage:)`, whose snapshot rep reports
        // pixel counts scaled by the screen's backing factor.
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Captures a live window (including AppKit overlays drawn on top of a Metal
/// layer) so the HUD can be inspected without the real screen saver host.
enum HostShot {

    enum CaptureError: Error, CustomStringConvertible {
        case image
        case write(String)

        var description: String {
            switch self {
            case .image: return "could not capture the window image"
            case .write(let path): return "could not write \(path)"
            }
        }
    }

    @discardableResult
    static func capture(window: NSWindow, to url: URL) throws -> URL {
        let windowID = CGWindowID(window.windowNumber)

        guard let image = CGWindowListCreateImage(.null,
                                                  .optionIncludingWindow,
                                                  windowID,
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            throw CaptureError.image
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.write(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.write(url.path)
        }
        return url
    }
}

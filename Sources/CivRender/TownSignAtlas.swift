import Foundation
import AppKit
import Metal
import MetalKit

/// Renders settlement names into a grid atlas so town signs can show real text.
enum TownSignAtlas {
    static let columns = 8
    static let rows = 8
    static let cellWidth = 256
    static let cellHeight = 64

    struct Result {
        var texture: MTLTexture?
        /// Settlement id -> atlas cell index.
        var cells: [Int32: Int]
    }

    static func make(device: MTLDevice,
                     settlements: [(id: Int32, name: String)]) -> Result {
        guard !settlements.isEmpty else { return Result(texture: nil, cells: [:]) }

        let width = columns * cellWidth
        let height = rows * cellHeight
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        NSColor(calibratedRed: 0.17, green: 0.15, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let fontNames = ["Helvetica-Bold", "Times-Bold", "Menlo-Bold",
                         "AvenirNext-Bold", "Georgia-Bold"]
        let colours: [NSColor] = [
            NSColor(calibratedRed: 0.94, green: 0.88, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.82, green: 0.90, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.72, alpha: 1),
            NSColor(calibratedRed: 0.84, green: 1.00, blue: 0.84, alpha: 1)
        ]

        var cells: [Int32: Int] = [:]
        for (index, settlement) in settlements.prefix(columns * rows).enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column * cellWidth)
            let y = CGFloat(height - (row + 1) * cellHeight)

            // Each town gets a stable typeface and ink colour.
            let seed = Int(settlement.id) &* 2_654_435_761
            let fontName = fontNames[abs(seed) % fontNames.count]
            let colour = colours[abs(seed / 7) % colours.count]
            let font = NSFont(name: fontName, size: 30)
                ?? NSFont.boldSystemFont(ofSize: 30)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: paragraph
            ]
            let rect = NSRect(x: x, y: y + 10,
                              width: CGFloat(cellWidth), height: CGFloat(cellHeight))
            (settlement.name as NSString).draw(in: rect, withAttributes: attributes)
            cells[settlement.id] = index
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            return Result(texture: nil, cells: cells)
        }
        let loader = MTKTextureLoader(device: device)
        let texture = try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: NSNumber(value: true),
            .generateMipmaps: NSNumber(value: true)
        ])
        return Result(texture: texture, cells: cells)
    }
}

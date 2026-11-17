import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd

/// Orthographic mesh evidence with IDs, separate banks, and field outline.
/// The same CPU arrays are uploaded by WorldScene; no diagnostic-only fan.
enum RiverDebugImage {
    static func write(terrain: Terrain, network: [RiverReach], field: RiverChannel.Field,
                      directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let carved = RiverChannel.carvedTerrain(terrain, field: field)
        let banks = WorldScene.riverBankGeometry(carved, network: network, field: field)
        let mesh = field.mesh
        for junction in mesh.junctions {
            let raw = junction.input.map { $0.map { [$0.position.x, $0.position.y, $0.position.z] } }
            let json = try JSONSerialization.data(withJSONObject: raw)
            try json.write(to: directory.appendingPathComponent("junction-\(junction.id)-input.json"))
            let triangles = stride(from: junction.indexRange.lowerBound, to: junction.indexRange.upperBound, by: 3).map { i in
                (0..<3).map { mesh.vertices[Int(mesh.indices[i + $0])] }
            }
            let points = junction.input.flatMap { $0.map { SIMD2($0.position.x, $0.position.z) } }
            guard !points.isEmpty else { continue }
            let lo = points.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude), simd_min)
            let hi = points.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
            let centre = (lo + hi) * 0.5
            let span = max(hi.x - lo.x, hi.y - lo.y) + 16 / RiverChannel.metresPerUnit // 8 m border
            let panel = 600, width = panel * 3, height = panel
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MapImage.ImageError.image }
            context.setFillColor(CGColor(gray: 0.90, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func xy(_ p: SIMD2<Float>, _ panelIndex: Int) -> CGPoint {
                CGPoint(x: Double((p.x - centre.x) / span + 0.5) * Double(panel) + Double(panelIndex * panel),
                        y: Double((p.y - centre.y) / span + 0.5) * Double(panel))
            }
            func draw(_ triangle: [Vertex], panelIndex: Int, fill: CGColor, wire: Bool) {
                let p = triangle.map { xy(SIMD2($0.position.x, $0.position.z), panelIndex) }
                context.beginPath(); context.move(to: p[0]); context.addLine(to: p[1]); context.addLine(to: p[2]); context.closePath()
                context.setFillColor(fill)
                if wire {
                    context.setStrokeColor(CGColor(gray: 0.12, alpha: 1)); context.setLineWidth(0.45)
                    context.drawPath(using: .fillStroke)
                } else { context.fillPath() }
            }
            for triangle in triangles {
                draw(triangle, panelIndex: 0, fill: CGColor(red: 0.2, green: 0.55, blue: 0.9, alpha: 1), wire: true)
            }
            context.saveGState(); context.clip(to: CGRect(x: panel, y: 0, width: panel, height: panel))
            for i in stride(from: 0, to: banks.indices.count, by: 3) {
                let triangle = (0..<3).map { banks.vertices[Int(banks.indices[i + $0])] }
                let p = triangle.map { SIMD2($0.position.x, $0.position.z) }
                guard p.contains(where: { abs($0.x - centre.x) < span && abs($0.y - centre.y) < span }) else { continue }
                draw(triangle, panelIndex: 1, fill: CGColor(red: 0.5, green: 0.35, blue: 0.2, alpha: 1), wire: false)
            }
            context.restoreGState()
            // A regular quarter-metre field raster, independent of triangle
            // drawing, makes wet/dry disagreements visible beside the mesh.
            let cells = Int(ceil(span * RiverChannel.metresPerUnit / 0.25))
            for ix in 0..<cells {
                for iz in 0..<cells {
                    let p = centre + SIMD2((Float(ix) + 0.5) / Float(cells) - 0.5,
                                           (Float(iz) + 0.5) / Float(cells) - 0.5) * span
                    guard let d = field.signedDistance(at: p) else { continue }
                    if d <= 0 || d < 0.25 / RiverChannel.metresPerUnit {
                        let point = xy(p, 2)
                        context.setFillColor(d <= 0 ? CGColor(red: 0.2, green: 0.55, blue: 0.9, alpha: 1) : CGColor(gray: 0.05, alpha: 1))
                        let size = Double(panel) / Double(cells)
                        context.fill(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size + 0.1, height: size + 0.1))
                    }
                }
            }
            for (i, title) in ["water triangles", "banks only", "field / outer outline"].enumerated() {
                let text = String(format: "J%d %@  centre %.5f,%.5f", junction.id, title, centre.x, centre.y)
                let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
                context.textPosition = CGPoint(x: i * panel + 12, y: 16)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
            let url = directory.appendingPathComponent("junction-\(junction.id).png")
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw MapImage.ImageError.write }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw MapImage.ImageError.write }
            print("junction \(junction.id): \(centre.x),\(centre.y), span \(span * 1000) m -> \(url.path)")
        }
    }
}

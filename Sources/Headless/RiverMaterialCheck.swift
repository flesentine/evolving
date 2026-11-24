import Foundation
import CoreGraphics
import ImageIO
import Metal
import simd

/// Metamorphic GPU fixture. One physical water plane and one piecewise-linear
/// terrain field are rendered with opposite legal water diagonals. Production
/// shading must be independent of that choice; legacy vertex-depth shading is
/// required to fail the same comparison, proving the fixture detects the bug.
enum RiverMaterialCheck {
    static func run(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A minimal, fully specified scene isolates material interpolation
        // from world generation. It still uses the production Metal pipeline.
        let side = 64, count = side * side, metres = RiverGraph.metresPerUnit
        var t = Terrain(size: side, seed: 1, height: Array(repeating: -10 / metres, count: count),
            flow: Array(repeating: 0, count: count), river: Array(repeating: 0, count: count),
            moisture: Array(repeating: 0.5, count: count), slope: Array(repeating: 0, count: count),
            biome: Array(repeating: Terrain.Biome.deepWater.rawValue, count: count),
            fertility: Array(repeating: 0, count: count), waterDistance: Array(repeating: 0, count: count),
            ao: Array(repeating: 1, count: count))
        let samples = [-10, 10].map { x in RiverSample(position: SIMD2(Float(x) / metres, 0),
            bed: 100 / metres, width: 4 / metres, tangent: SIMD2(1, 0), channelWidth: 4 / metres,
            along: Float(x + 10), waterOverride: 100.6 / metres) }
        let reach = RiverReach(id: 0, samples: samples, isSource: true, isMouth: true)
        t.riverGraph = RiverGraph(reaches: [reach], diagnostics: RiverDiagnostics())
        let renderer = try Renderer(context: MetalContext(), terrain: t,
            colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
        renderer.weatherOverride = 0; renderer.seasonOverride = 0.3; renderer.riverReviewMode = "water"
        renderer.cameraOverride = Renderer.Camera(eye: SIMD3(0, 0.7, 0.001),
            target: SIMD3(0, 0.1, 0), fov: 48) // world units, 100 m water level
        let texture = renderer.scene.submittedHeightTexture, n = texture.width
        let water: Float = 100 / metres
        func depth(_ x: Float, _ z: Float) -> Float {
            let u = (x + 0.2) / 0.4, v = (z + 0.2) / 0.4 // 400 m fixture square
            return (0.1 + 0.8 * u * v) / metres
        }
        var heights: [Float] = []
        for j in 0..<n { for i in 0..<n {
            let x = Float(i) / Float(n - 1) * 2 - 1, z = Float(j) / Float(n - 1) * 2 - 1
            heights.append(water - depth(x, z))
        }}
        heights.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: n * MemoryLayout<Float>.stride)
        }
        let vertices = [SIMD2<Float>(-0.2, -0.2), SIMD2(0.2, -0.2), SIMD2(0.2, 0.2), SIMD2(-0.2, 0.2)].map { p in
            Vertex(position: SIMD3(p.x, water, p.y), normal: SIMD3(0, 1, 0),
                   color: SIMD4(0.02, 0.09, 0.15, depth(p.x, p.y) / (1.25 / metres)),
                   uv: (p + SIMD2(repeating: 0.2)) / 0.4)
        }
        let diagonals: [[UInt32]] = [[0, 2, 1, 0, 3, 2], [0, 3, 1, 1, 3, 2]]
        func pixels(_ url: URL) throws -> [UInt8] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SnapshotError.image }
            var bytes = [UInt8](repeating: 0, count: 800 * 800 * 4)
            let ok = bytes.withUnsafeMutableBytes { data -> Bool in
                guard let context = CGContext(data: data.baseAddress, width: 800, height: 800,
                    bitsPerComponent: 8, bytesPerRow: 800 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 800, height: 800)); return true
            }
            guard ok else { throw SnapshotError.image }; return bytes
        }
        for hour: Float in [10, 22] {
            renderer.hourOverride = hour
            for legacy in [true, false] {
                renderer.validationLegacyWaterDepth = legacy
                var images: [[UInt8]] = []
                for diagonal in 0..<2 {
                    renderer.validationWaterMesh = try Mesh(device: renderer.context.device, vertices: vertices, indices: diagonals[diagonal])
                    let path = directory.appendingPathComponent("\(legacy ? "legacy" : "exact")-\(Int(hour))-\(diagonal).png")
                    _ = try Snapshot.write(renderer: renderer, width: 800, height: 800, time: 0, to: path)
                    images.append(try pixels(path))
                }
                var maximum = 0, sum = 0
                // Strict interior excludes outer-coverage/antialias differences.
                for y in 240..<560 { for x in 240..<560 { for channel in 0..<3 {
                    let i = (y * 800 + x) * 4 + channel
                    let d = abs(Int(images[0][i]) - Int(images[1][i]))
                    maximum = max(maximum, d); sum += d
                }}}
                print("\(legacy ? "legacy" : "exact") material hour \(hour): max RGB delta \(maximum)/255, total \(sum)")
                if legacy { precondition(maximum > 2, "fixture did not expose legacy triangulation shading") }
                else { precondition(maximum <= 2, "production water shading exposes triangle diagonals") }
            }
        }
        print("PASS GPU water triangulation invariance, daylight and night; legacy failure reproduced")
    }
}

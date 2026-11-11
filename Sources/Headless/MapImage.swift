import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Debug top-down map of the generated world. Used while tuning terrain.
enum MapImage {

    static func write(_ terrain: Terrain, seed: UInt64, to url: URL, scale: Int = 2) throws {
        let n = terrain.size
        let w = n * scale
        let h = n * scale
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        func colour(_ biome: UInt8) -> (Float, Float, Float) {
            switch Terrain.Biome(rawValue: biome) ?? .grass {
            case .deepWater: return (0.09, 0.20, 0.34)
            case .shallow:   return (0.16, 0.38, 0.52)
            case .beach:     return (0.80, 0.74, 0.56)
            case .grass:     return (0.46, 0.60, 0.34)
            case .forest:    return (0.27, 0.42, 0.23)
            case .rock:      return (0.50, 0.48, 0.44)
            case .snow:      return (0.90, 0.93, 0.95)
            }
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = x / scale
                let j = y / scale
                let idx = j * n + i
                var (r, g, b) = colour(terrain.biome[idx])

                // Hill shading.
                let dz = terrain.slope[idx]
                let shade = clamp01(1.0 - dz * 0.45)
                r *= shade; g *= shade; b *= shade

                if terrain.river[idx] > 0 {
                    let strength: Float = terrain.river[idx] == 3 ? 1.0 : (terrain.river[idx] == 2 ? 0.85 : 0.7)
                    r = lerp(r, 0.32, strength)
                    g = lerp(g, 0.55, strength)
                    b = lerp(b, 0.72, strength)
                }

                // Grid ticks every 16 cells for orientation.
                if (x % (16 * scale) == 0) || (y % (16 * scale) == 0) {
                    let dark: Float = 0.82
                    r *= dark; g *= dark; b *= dark
                }

                let o = (y * w + x) * 4
                pixels[o + 0] = UInt8(clamp01(b) * 255)
                pixels[o + 1] = UInt8(clamp01(g) * 255)
                pixels[o + 2] = UInt8(clamp01(r) * 255)
                pixels[o + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { throw ImageError.provider }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: w, height: h,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw ImageError.image
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.write
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.write }
    }

    enum ImageError: Error { case provider, image, write }
}

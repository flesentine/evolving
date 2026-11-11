import Foundation

/// Deterministic 2D value noise. Everything in the world generation pipeline
/// derives from this, so a seed always produces the same valley.
struct ValueNoise {
    let seed: UInt64

    init(seed: UInt64) { self.seed = seed }

    private func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= seed
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Float(h >> 40) * (1.0 / Float(1 << 24))
    }

    /// Smooth value noise in [0, 1].
    func noise(_ x: Float, _ y: Float) -> Float {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        let xi = Int(ix), yi = Int(iy)

        let a = hash(xi, yi)
        let b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1)
        let d = hash(xi + 1, yi + 1)

        let top = a + (b - a) * ux
        let bottom = c + (d - c) * ux
        return top + (bottom - top) * uy
    }

    /// Fractal sum in [0, 1].
    func fbm(_ x: Float, _ y: Float, octaves: Int, lacunarity: Float = 2.03, gain: Float = 0.5) -> Float {
        var amplitude: Float = 1
        var frequency: Float = 1
        var sum: Float = 0
        var norm: Float = 0
        for _ in 0..<octaves {
            sum += amplitude * noise(x * frequency, y * frequency)
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        }
        return norm > 0 ? sum / norm : 0
    }

    /// Ridged fractal sum in [0, 1], good for mountain spines.
    func ridged(_ x: Float, _ y: Float, octaves: Int, lacunarity: Float = 2.11, gain: Float = 0.55) -> Float {
        var amplitude: Float = 1
        var frequency: Float = 1
        var sum: Float = 0
        var norm: Float = 0
        for _ in 0..<octaves {
            let n = 1 - abs(noise(x * frequency, y * frequency) * 2 - 1)
            sum += amplitude * n * n
            norm += amplitude
            amplitude *= gain
            frequency *= lacunarity
        }
        return norm > 0 ? sum / norm : 0
    }
}

func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

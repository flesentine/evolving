import Foundation

/// Terrain is regenerated from the world seed every launch and is never stored
/// in the save file.
struct Terrain {

    enum Biome: UInt8 {
        case deepWater  = 0
        case shallow    = 1
        case beach      = 2
        case grass      = 3
        case forest     = 4
        case rock       = 5
        case snow       = 6
    }

    /// Samples per side. Grid samples span world coordinates -1...1.
    let size: Int
    let seed: UInt64

    /// Elevation in world units. Sea level is exactly 0.
    var height: [Float]
    var flow: [Float]
    var river: [UInt8]
    var moisture: [Float]
    var slope: [Float]
    var biome: [UInt8]
    var fertility: [Float]
    /// Distance to sea or river, in grid cells.
    var waterDistance: [Float]
    /// Baked curvature ambient occlusion, 0.66 (crease) … 1.06 (ridge).
    var ao: [Float] = []

    var maxHeight: Float = 0

    // MARK: - Sampling

    @inline(__always) func index(_ i: Int, _ j: Int) -> Int { j * size + i }

    @inline(__always) func worldX(_ i: Int) -> Float {
        Float(i) / Float(size - 1) * 2 - 1
    }

    @inline(__always) func worldZ(_ j: Int) -> Float {
        Float(j) / Float(size - 1) * 2 - 1
    }

    @inline(__always) func cellX(_ worldX: Float) -> Int {
        Int(((worldX + 1) * 0.5 * Float(size - 1)).rounded())
    }

    @inline(__always) func cellZ(_ worldZ: Float) -> Int {
        Int(((worldZ + 1) * 0.5 * Float(size - 1)).rounded())
    }

    func riverAt(x: Float, z: Float) -> UInt8 {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return river[index(i, j)]
    }

    func heightAt(x: Float, z: Float) -> Float {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return height[index(i, j)]
    }

    /// Height of the rendered terrain surface at an arbitrary point.
    ///
    /// This is a true bilinear patch rather than a two-triangle split: the
    /// surface is continuous across cell edges and its sea-level contour is a
    /// smooth curve instead of a grid staircase. Roads and buildings sample the
    /// same function, so they sit on the surface the player sees.
    func interpolatedHeight(x: Float, z: Float) -> Float {
        let fx = (x + 1) * 0.5 * Float(size - 1)
        let fz = (z + 1) * 0.5 * Float(size - 1)
        let i = min(max(Int(floor(fx)), 0), size - 2)
        let j = min(max(Int(floor(fz)), 0), size - 2)
        let u = min(max(fx - Float(i), 0), 1)
        let v = min(max(fz - Float(j), 0), 1)

        let a = height[index(i, j)]
        let b = height[index(i + 1, j)]
        let c = height[index(i + 1, j + 1)]
        let d = height[index(i, j + 1)]

        let top = a + (b - a) * u
        let bottom = d + (c - d) * u
        return top + (bottom - top) * v
    }

    func fertilityAt(x: Float, z: Float) -> Float {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return fertility[index(i, j)]
    }

    var cellSize: Float { 2 / Float(size - 1) }

    func gradientAt(x: Float, z: Float) -> SIMD2<Float> {
        let d: Float = 0.004
        let hx = heightAt(x: x + d, z: z) - heightAt(x: x - d, z: z)
        let hz = heightAt(x: x, z: z + d) - heightAt(x: x, z: z - d)
        return SIMD2(hx / (2 * d), hz / (2 * d))
    }

    func isWater(x: Float, z: Float) -> Bool {
        heightAt(x: x, z: z) <= 0
    }
}

enum WorldGen {

    static func generate(seed: UInt64, size: Int = 384) -> Terrain {
        let noise = ValueNoise(seed: seed)
        let count = size * size

        var height = [Float](repeating: 0, count: count)
        var moisture = [Float](repeating: 0, count: count)

        // ---------------------------------------------------------------
        // Landmass
        // ---------------------------------------------------------------
        for j in 0..<size {
            for i in 0..<size {
                let x = Float(i) / Float(size - 1) * 2 - 1
                let z = Float(j) / Float(size - 1) * 2 - 1
                let r = sqrt(x * x + z * z)
                let angle = atan2(z, x)

                // A wobbly coastline: radius varies with direction.
                let coastNoise = noise.fbm(cos(angle) * 1.7 + 7.3,
                                           sin(angle) * 1.7 + 3.1, octaves: 3)
                let coastRadius = 0.70 + (coastNoise - 0.5) * 0.26
                let land = 1 - smoothstep(coastRadius - 0.07, coastRadius + 0.02, r)

                // Relief: rolling terrain plus ridged mountains biased to the
                // north-west so the island has a clear high side and a low side.
                // Relief: a central basin ringed by mountains, with one sector
                // lower so a river can escape to the sea.
                let rolling = noise.fbm(x * 2.3 + 1.7, z * 2.3 - 4.1, octaves: 5)
                let ridge = noise.ridged(x * 1.5 + 4.1, z * 1.5 - 2.3, octaves: 4)

                let rim = smoothstep(0.26, 0.46, r) * (1 - smoothstep(0.58, 0.72, r))
                let gap = smoothstep(0.30, 0.78,
                                     noise.fbm(cos(angle) * 2.1 + 31.0,
                                               sin(angle) * 2.1 - 17.0, octaves: 2))
                let mountains = pow(ridge, 1.7) * rim * (1.0 - gap * 0.78)
                let basin = (1 - smoothstep(0.0, 0.44, r)) * rolling * 0.030

                // Lifting the shore curve makes the island rise quickly out of
                // the water instead of trailing a wide, flat sand shelf.
                let shore = pow(land, 0.60)
                var h = shore * (0.012 + basin + mountains * 0.30)

                // Sea floor: negative outside the coast so shallow water reads
                // as a thin turquoise band around a deep blue plate.
                if h <= 0.0005 {
                    let depthNoise = noise.fbm(x * 3.1 + 8.0, z * 3.1 - 2.0, octaves: 2)
                    let openSea = smoothstep(coastRadius - 0.02, 1.15, r)
                    h = -0.030 - 0.075 * openSea - depthNoise * 0.01
                }

                height[j * size + i] = h
                moisture[j * size + i] = noise.fbm(x * 1.9 + 21.3, z * 1.9 - 13.7, octaves: 4)
            }
        }

        // ---------------------------------------------------------------
        // Slope
        // ---------------------------------------------------------------
        var slope = [Float](repeating: 0, count: count)
        let cs = 2 / Float(size - 1)
        for j in 0..<size {
            for i in 0..<size {
                let i0 = max(i - 1, 0), i1 = min(i + 1, size - 1)
                let j0 = max(j - 1, 0), j1 = min(j + 1, size - 1)
                let dx = (height[j * size + i1] - height[j * size + i0]) / (Float(i1 - i0) * cs)
                let dz = (height[j1 * size + i] - height[j0 * size + i]) / (Float(j1 - j0) * cs)
                slope[j * size + i] = sqrt(dx * dx + dz * dz)
            }
        }

        // ---------------------------------------------------------------
        // Flow accumulation → rivers
        // ---------------------------------------------------------------
        let order = (0..<count)
            .filter { height[$0] > 0 }
            .sorted { height[$0] > height[$1] }

        var flow = [Float](repeating: 0, count: count)
        for idx in order {
            let i = idx % size, j = idx / size
            flow[idx] += 1 + moisture[idx] * 2.0

            var lowest = idx
            var lowestH = height[idx]
            for dj in -1...1 {
                for di in -1...1 where !(di == 0 && dj == 0) {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < size, nj >= 0, nj < size else { continue }
                    let n = nj * size + ni
                    if height[n] < lowestH {
                        lowestH = height[n]
                        lowest = n
                    }
                }
            }
            if lowest != idx {
                flow[lowest] += flow[idx]
            }
        }

        var river = [UInt8](repeating: 0, count: count)
        for idx in 0..<count where height[idx] > 0 {
            let f = flow[idx]
            if f > 600 { river[idx] = 3 }
            else if f > 200 { river[idx] = 2 }
            else if f > 60 { river[idx] = 1 }
        }

        // Estuaries: open river mouths into the sea so the rivers visibly
        // reach the coast instead of fading out on the beach.
        for idx in 0..<count where river[idx] > 0 {
            let i = idx % size, j = idx / size
            var nearSea = false
            for dj in -2...2 where !nearSea {
                for di in -2...2 {
                    let ni = min(max(i + di, 0), size - 1)
                    let nj = min(max(j + dj, 0), size - 1)
                    if height[nj * size + ni] <= 0 {
                        nearSea = true
                        break
                    }
                }
            }
            guard nearSea else { continue }

            height[idx] = min(height[idx], -0.006)
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ni = min(max(i + di, 0), size - 1)
                let nj = min(max(j + dj, 0), size - 1)
                let n = nj * size + ni
                if height[n] > 0 { height[n] = min(height[n], 0.002) }
            }
        }

        // ---------------------------------------------------------------
        // Distance to water (sea or river)
        // ---------------------------------------------------------------
        var waterDistance = [Float](repeating: 1e9, count: count)
        var queue = [Int]()
        queue.reserveCapacity(count / 4)
        for idx in 0..<count where height[idx] <= 0 || river[idx] > 0 {
            waterDistance[idx] = 0
            queue.append(idx)
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let i = idx % size, j = idx / size
            let d = waterDistance[idx] + 1
            for dj in -1...1 {
                for di in -1...1 where !(di == 0 && dj == 0) {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < size, nj >= 0, nj < size else { continue }
                    let n = nj * size + ni
                    if waterDistance[n] > d {
                        waterDistance[n] = d
                        queue.append(n)
                    }
                }
            }
        }
        for idx in 0..<count where waterDistance[idx] > 1e8 {
            waterDistance[idx] = Float(size)
        }

        // ---------------------------------------------------------------
        // Biome + settlement suitability
        // ---------------------------------------------------------------
        var biome = [UInt8](repeating: 0, count: count)
        var fertility = [Float](repeating: 0, count: count)
        var maxHeight: Float = 0

        for idx in 0..<count {
            let h = height[idx]
            let s = slope[idx]
            let m = moisture[idx]
            maxHeight = max(maxHeight, h)

            if h <= -0.02 {
                biome[idx] = Terrain.Biome.deepWater.rawValue
            } else if h <= 0 {
                biome[idx] = Terrain.Biome.shallow.rawValue
            } else if h > 0.19 {
                biome[idx] = Terrain.Biome.snow.rawValue
            } else if s > 0.80 || h > 0.135 {
                biome[idx] = Terrain.Biome.rock.rawValue
            } else if h < 0.011 {
                biome[idx] = Terrain.Biome.beach.rawValue
            } else if m > 0.62 && h > 0.02 {
                biome[idx] = Terrain.Biome.forest.rawValue
            } else {
                biome[idx] = Terrain.Biome.grass.rawValue
            }

            // Flat, low, well-watered land is where people settle.
            let flat: Float = smoothstep(0.9, 0.15, s)
            let low: Float = smoothstep(0.20, 0.03, h)
            let wet: Float = 1 / (1 + waterDistance[idx] * 0.22)
            let soil: Float = biome[idx] == Terrain.Biome.beach.rawValue ? 0.35 : 1.0
            let climate: Float = 0.55 + m * 0.65
            fertility[idx] = clamp01(flat * low * wet * soil * climate)
        }

        // Curvature AO: concave ground sits in its own shade, ridges catch a
        // little more sky. Baked once, so it costs nothing at runtime.
        var ao = [Float](repeating: 1, count: count)
        let directions: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1),
                                        (1, 1), (1, -1), (-1, 1), (-1, -1)]
        for j in 0..<size {
            for i in 0..<size {
                let idx = j * size + i
                var sum: Float = 0
                for (di, dj) in directions {
                    let ni = min(max(i + di * 3, 0), size - 1)
                    let nj = min(max(j + dj * 3, 0), size - 1)
                    sum += height[nj * size + ni]
                }
                let average = sum / Float(directions.count)
                let concavity = (average - height[idx]) / 0.030
                ao[idx] = min(max(1.0 - concavity * 0.65, 0.60), 1.08)
            }
        }

        return Terrain(size: size,
                       seed: seed,
                       height: height,
                       flow: flow,
                       river: river,
                       moisture: moisture,
                       slope: slope,
                       biome: biome,
                       fertility: fertility,
                       waterDistance: waterDistance,
                       ao: ao,
                       maxHeight: maxHeight)
    }
}

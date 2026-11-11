import Foundation
import simd
import Metal

/// Stylised palette. Keeping it in one place makes the era shifts easy to tune.
enum Palette {
    static let deepWater  = SIMD3<Float>(0.055, 0.165, 0.255)
    static let shallow    = SIMD3<Float>(0.180, 0.410, 0.455)
    static let beach      = SIMD3<Float>(0.720, 0.655, 0.480)
    static let grass      = SIMD3<Float>(0.360, 0.500, 0.240)
    static let grassDry   = SIMD3<Float>(0.485, 0.520, 0.270)
    static let forest     = SIMD3<Float>(0.180, 0.310, 0.160)
    static let rock       = SIMD3<Float>(0.400, 0.380, 0.355)
    static let snow       = SIMD3<Float>(0.870, 0.905, 0.930)
    static let wetSand    = SIMD3<Float>(0.470, 0.415, 0.325)
    static let river      = SIMD3<Float>(0.040, 0.150, 0.270)
    static let seabed     = SIMD3<Float>(0.155, 0.205, 0.180)
}

/// Builds and owns every mesh derived from the terrain and the simulation.
final class WorldScene {

    let terrain: Terrain

    let terrainMesh: Mesh
    let waterMesh: Mesh
    let riverMesh: Mesh
    let riverBankMesh: Mesh
    /// Water polygons used to keep trees and houses out of the channel.
    let riverField: RiverChannel.Field
    let cubeMesh: Mesh
    let coneMesh: Mesh
    let smokeMesh: Mesh
    let birdMesh: Mesh
    let treeMesh: Mesh
    let treeBroadleafMesh: Mesh
    let gableMesh: Mesh
    let archMesh: Mesh
    let signPlateMesh: Mesh
    let crestMesh: Mesh
    let personBodyMesh: Mesh
    let personHeadMesh: Mesh
    let personHeadBrimMesh: Mesh
    let personLegMesh: Mesh
    let personArmMesh: Mesh
    let animalMesh: Mesh
    let cartMesh: Mesh
    let carMesh: Mesh
    let boatHullMesh: Mesh
    let boatSailMesh: Mesh
    let buildingMeshes: [(path: String, mesh: Mesh)]

    /// Height field uploaded for the water shader, so shallow water and foam
    /// can be evaluated per pixel instead of per coarse water vertex.
    let heightTexture: MTLTexture

    /// Rebuilt whenever the road network changes; nil until then.
    private(set) var roadMesh: Mesh?
    private(set) var streetMesh: Mesh?

    let device: MTLDevice

    private(set) var instances: [InstanceData]

    init(context: MetalContext, terrain: Terrain) throws {
        self.device = context.device

        let heightDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
                                                                 width: terrain.size,
                                                                 height: terrain.size,
                                                                 mipmapped: false)
        heightDesc.usage = [.shaderRead]
        heightDesc.storageMode = .shared
        guard let heightTexture = context.device.makeTexture(descriptor: heightDesc) else {
            throw MetalSetupError.pipeline("terrain height texture")
        }
        self.heightTexture = heightTexture

        // The river graph must exist before the terrain mesh: its channel is
        // cut into the render surface (the simulation grid is left alone) so
        // the bed can never poke through the opaque water sheet.
        let network = RiverNetwork.build(terrain).reaches
        let field = RiverChannel.Field(terrain: terrain, network: network)
        riverField = field

        // One carved copy of the terrain is used for every visible surface
        // and every placement. Otherwise props still use the sim height and
        // float above the valley the renderer cut.
        var carved = terrain
        for j in 0..<carved.size {
            for i in 0..<carved.size {
                let idx = carved.index(i, j)
                carved.height[idx] = RiverChannel.carvedHeight(
                    carved.height[idx], field: field,
                    x: carved.worldX(i), z: carved.worldZ(j))
            }
        }
        self.terrain = carved

        carved.height.withUnsafeBytes { raw in
            heightTexture.replace(region: MTLRegionMake2D(0, 0, carved.size,
                                                          carved.size),
                                  mipmapLevel: 0,
                                  withBytes: raw.baseAddress!,
                                  bytesPerRow: carved.size
                                    * MemoryLayout<Float>.stride)
        }

        terrainMesh = try Mesh(device: context.device,
                               vertices: WorldScene.terrainVertices(carved,
                                                                    detail: 2,
                                                                    riverField: field),
                               indices: WorldScene.terrainIndices(carved,
                                                                  detail: 2))

        let water = WorldScene.waterGeometry(carved)
        waterMesh = try Mesh(device: context.device, vertices: water.vertices, indices: water.indices)
        let rivers = WorldScene.riverGeometry(carved, network: network,
                                               field: field)
        riverMesh = try Mesh(device: context.device,
                             vertices: rivers.vertices, indices: rivers.indices)
        let banks = WorldScene.riverBankGeometry(carved, network: network,
                                                     field: field)
        riverBankMesh = try Mesh(device: context.device,
                                 vertices: banks.vertices, indices: banks.indices)

        cubeMesh = try Mesh(device: context.device, vertices: Geometry.cube())
        coneMesh = try Mesh(device: context.device, vertices: Geometry.cone(radius: 0.5, height: 1, segments: 6))
        smokeMesh = try Mesh(device: context.device,
                             vertices: Geometry.sphere(radius: 0.5, rings: 5, segments: 8))
        birdMesh = try Mesh(device: context.device, vertices: Geometry.bird())
        treeMesh = try Mesh(device: context.device, vertices: Geometry.tree())
        treeBroadleafMesh = try Mesh(device: context.device, vertices: Geometry.treeBroadleaf())
        gableMesh = try Mesh(device: context.device, vertices: Geometry.gable())
        archMesh = try Mesh(device: context.device, vertices: Geometry.arch())
        signPlateMesh = try Mesh(device: context.device, vertices: Geometry.signPlate())
        crestMesh = try Mesh(device: context.device, vertices: Geometry.crest())
        personBodyMesh = try Mesh(device: context.device, vertices: Geometry.personBody())
        personHeadMesh = try Mesh(device: context.device, vertices: Geometry.personHead())
        personHeadBrimMesh = try Mesh(device: context.device, vertices: Geometry.personHeadBrim())
        personLegMesh = try Mesh(device: context.device, vertices: Geometry.personLeg())
        personArmMesh = try Mesh(device: context.device, vertices: Geometry.personArm())
        animalMesh = try Mesh(device: context.device, vertices: Geometry.animal())
        cartMesh = try Mesh(device: context.device, vertices: Geometry.cart())
        carMesh = try Mesh(device: context.device, vertices: Geometry.car())
        boatHullMesh = try Mesh(device: context.device, vertices: Geometry.boatHull())
        boatSailMesh = try Mesh(device: context.device, vertices: Geometry.boatSail())

        var loaded: [(path: String, mesh: Mesh)] = []
        for path in BuildingCatalog.allPaths {
            guard let asset = try? CivMesh.load(named: path + ".civmesh"),
                  let mesh = try? Mesh(device: context.device,
                                       vertices: asset.vertices,
                                       indices: asset.indices) else { continue }
            loaded.append((path, mesh))
        }

        // Procedural landmarks share the building draw path but keep material
        // 0, so they show their authored vertex colours instead of the atlas.
        if let temple = try? Mesh(device: context.device, vertices: Geometry.temple()) {
            loaded.append(("__temple", temple))
        }
        if let church = try? Mesh(device: context.device, vertices: Geometry.church()) {
            loaded.append(("__church", church))
        }
        if let cathedral = try? Mesh(device: context.device,
                                     vertices: Geometry.cathedral()) {
            loaded.append(("__cathedral", cathedral))
        }
        if let glass = try? Mesh(device: context.device,
                                 vertices: Geometry.cathedralGlass()) {
            loaded.append(("__cathedral_glass", glass))
        }
        if let dome = try? Mesh(device: context.device, vertices: Geometry.dome()) {
            loaded.append(("__dome", dome))
        }
        if let dock = try? Mesh(device: context.device, vertices: Geometry.dock()) {
            loaded.append(("__dock", dock))
        }
        buildingMeshes = loaded

        // Instance 0 is always the terrain (identity transform).
        instances = [InstanceData(model: matrix_identity_float4x4,
                                  color: SIMD4<Float>(1, 1, 1, 0),
                                  material: SIMD4<Float>(8, 0, 0, 0))]
    }

    // MARK: - Terrain mesh

    /// Terrain mesh, upsampled above the simulation grid. Sampling the
    /// bilinear height field on a finer grid gives the sea-level contour more
    /// segments to follow, which is what removes the visible stair-steps.
    static func terrainVertices(_ t: Terrain, detail: Int = 1,
                                riverField: RiverChannel.Field? = nil) -> [Vertex] {
        let n = t.size
        let step = max(detail, 1)
        let rn = (n - 1) * step + 1
        var verts = [Vertex]()
        verts.reserveCapacity(rn * rn)

        let cell = t.cellSize
        let eps = cell / Float(step) * 0.5

        for rj in 0..<rn {
            let fj = Float(rj) / Float(step)
            let z = -1 + fj * cell
            for ri in 0..<rn {
                let fi = Float(ri) / Float(step)
                let x = -1 + fi * cell

                func surfaceHeight(_ x: Float, _ z: Float) -> Float {
                    let raw = t.interpolatedHeight(x: x, z: z)
                    guard let riverField else { return raw }
                    return RiverChannel.carvedHeight(raw, field: riverField,
                                                     x: x, z: z)
                }

                let h = surfaceHeight(x, z)
                let hx = surfaceHeight(x + eps, z) - surfaceHeight(x - eps, z)
                let hz = surfaceHeight(x, z + eps) - surfaceHeight(x, z - eps)
                let normal = simd_normalize(SIMD3<Float>(-hx / (2 * eps), 1, -hz / (2 * eps)))

                let i0 = min(max(Int(floor(fi)), 0), n - 2)
                let j0 = min(max(Int(floor(fj)), 0), n - 2)
                let u = min(max(fi - Float(i0), 0), 1)
                let v = min(max(fj - Float(j0), 0), 1)

                let c00 = coarseColour(t, i: i0, j: j0)
                let c10 = coarseColour(t, i: i0 + 1, j: j0)
                let c01 = coarseColour(t, i: i0, j: j0 + 1)
                let c11 = coarseColour(t, i: i0 + 1, j: j0 + 1)

                let top = c00 + (c10 - c00) * u
                let bottom = c01 + (c11 - c01) * u
                var colour = top + (bottom - top) * v

                if h < 0 {
                    // Ease into the seabed colour instead of switching per
                    // vertex; the hard switch showed up as a toothed shoreline.
                    let submerged = clamp01(-h / 0.006)
                    colour = simd_mix(colour, Palette.seabed, SIMD3(repeating: submerged))
                }

                // Alpha carries a "wet" flag so rivers can take a specular
                // sheen in the shader without a separate water mesh.
                let wet: Float = t.river[t.index(i0, j0)] > 0 ? 0.35 : 1.0
                verts.append(Vertex(position: SIMD3(x, h, z),
                                    normal: normal,
                                    color: SIMD4(colour, wet)))
            }
        }
        return verts
    }

    /// Colour of one simulation-grid vertex, before interpolation.
    private static func coarseColour(_ t: Terrain, i: Int, j: Int) -> SIMD3<Float> {
        let idx = t.index(i, j)
        let h = t.height[idx]
        let biome = Terrain.Biome(rawValue: t.biome[idx]) ?? .grass

        var colour: SIMD3<Float>
        switch biome {
        case .deepWater, .shallow: colour = Palette.seabed
        case .beach:               colour = Palette.beach
        case .grass:
            let dryness = clamp01((t.moisture[idx] - 0.42) * 1.8)
            colour = simd_mix(Palette.grass, Palette.grassDry, SIMD3(repeating: dryness))
        case .forest:              colour = Palette.forest
        case .rock:                colour = Palette.rock
        case .snow:                colour = Palette.snow
        }

        // Rivers are painted into the terrain colour; the water plane only
        // covers the sea, so this is what makes the drainage network visible.
        // One-cell dilation closes the gaps between thresholded river cells.
        var riverStrength: Float = 0
        if t.river[idx] > 0 {
            riverStrength = t.river[idx] >= 3 ? 0.32 : (t.river[idx] == 2 ? 0.24 : 0.16)
        } else {
            let i = idx % t.size, j = idx / t.size
            var neighbour: UInt8 = 0
            if i > 0 { neighbour = max(neighbour, t.river[idx - 1]) }
            if i < t.size - 1 { neighbour = max(neighbour, t.river[idx + 1]) }
            if j > 0 { neighbour = max(neighbour, t.river[idx - t.size]) }
            if j < t.size - 1 { neighbour = max(neighbour, t.river[idx + t.size]) }
            if neighbour > 0 { riverStrength = 0.10 }
        }
        if riverStrength > 0 {
            colour = simd_mix(colour, Palette.river, SIMD3(repeating: riverStrength))
        }

        // Wet sand just above the waterline: a darker rim keeps the beach from
        // reading as one uniform pale band.
        if biome == .beach {
            let wet = 1 - clamp01(h / 0.006)
            colour = simd_mix(colour, Palette.wetSand, SIMD3(repeating: wet * 0.8))
        }

        let slope = t.slope[idx]
        let shade = clamp01(1.0 - slope * 0.28)
        let variation = 0.94 + t.fertility[idx] * 0.10
        colour *= shade * variation * t.ao[idx]

        if h < 0 { colour = Palette.seabed }
        return colour
    }

    static func terrainIndices(_ t: Terrain, detail: Int = 1) -> [UInt32] {
        let step = max(detail, 1)
        let rn = (t.size - 1) * step + 1
        var indices = [UInt32]()
        indices.reserveCapacity((rn - 1) * (rn - 1) * 6)
        for j in 0..<(rn - 1) {
            for i in 0..<(rn - 1) {
                let a = UInt32(j * rn + i)
                let b = UInt32(j * rn + i + 1)
                let c = UInt32((j + 1) * rn + i + 1)
                let d = UInt32((j + 1) * rn + i)
                indices.append(contentsOf: [a, c, b, a, d, c])
            }
        }
        return indices
    }

    // MARK: - Water mesh


    /// One continuous water surface: a depth-shaded grid over the island's
    /// coastal shelf, plus a large flat frame that carries the ocean out to the
    /// horizon. Being a single mesh means there is no seam for the eye to find.
    /// A thin water surface following the Phase 1 river network. Five
    /// vertices across give the surface enough shape for depth shading and
    /// shoreline foam, and weld exactly to the bank waterline.
    static func riverGeometry(_ t: Terrain,
                              network: [RiverReach],
                              field: RiverChannel.Field) -> (vertices: [Vertex], indices: [UInt32]) {
        var verts: [Vertex] = []
        var indices: [UInt32] = []
        let up = SIMD3<Float>(0, 1, 0)
        let acrossCount = RiverChannel.across.count
        let metres = RiverChannel.metresPerUnit

        let depthScale = 1.25 / RiverChannel.metresPerUnit
        func depthValue(_ p: SIMD2<Float>, _ lineY: Float,
                        edge: Bool) -> Float {
            if edge { return 0 }
            let ground = t.interpolatedHeight(x: p.x, z: p.y)
            let bed = RiverChannel.carvedHeight(ground, field: field,
                                                x: p.x, z: p.y)
            let water = field.waterLevel(at: p) ?? lineY
            return min(max(water - bed, 0) / depthScale, 1)
        }

        // Trim every reach back from a junction so the ribbons do not overlap.
        // The gap is filled by one Y-shaped polygon built from the actual cut
        // cross-sections. This replaces the round pool overlay.
        var firstKept = [Int](repeating: 0, count: network.count)
        var lastKept = [Int](repeating: 0, count: network.count)
        for reach in network {
            let samples = reach.samples
            guard samples.count >= 2 else { continue }
            let total = samples.last?.along ?? 0
            var startTrim: Float = 0
            if !reach.upstream.isEmpty, let first = samples.first {
                var radius = RiverChannel.halfWidth(first)
                for a in reach.upstream where a < network.count {
                    if let end = network[a].samples.last {
                        radius = max(radius, RiverChannel.halfWidth(end))
                    }
                }
                startTrim = radius * 1.05 * metres
            }
            var endTrim: Float = 0
            if let d = reach.downstream, d < network.count,
               let first = network[d].samples.first, let last = samples.last {
                endTrim = max(RiverChannel.halfWidth(last),
                              RiverChannel.halfWidth(first)) * 1.05 * metres
            }
            var fs = 0
            while fs < samples.count - 1 && samples[fs].along < startTrim {
                fs += 1
            }
            var le = samples.count - 1
            while le > fs && total - samples[le].along < endTrim {
                le -= 1
            }
            firstKept[reach.id] = fs
            lastKept[reach.id] = le
        }

        func tint(_ sample: RiverSample) -> SIMD3<Float> {
            sample.width > 0.026
                ? SIMD3<Float>(0.025, 0.09, 0.16)
                : SIMD3<Float>(0.04, 0.14, 0.20)
        }

        for reach in network {
            let samples = reach.samples
            guard samples.count >= 2 else { continue }
            let fs = firstKept[reach.id]
            let le = lastKept[reach.id]
            guard le > fs else { continue }
            let base = UInt32(verts.count)

            for i in fs...le {
                let sample = samples[i]
                let side = RiverChannel.sideVector(sample)
                let half = RiverChannel.halfWidth(sample)
                let line = RiverChannel.waterLine(t, sample)
                let colour = tint(sample)
                let along = sample.along / max(sample.width * 3.0, 1e-5)
                for (k, f) in RiverChannel.across.enumerated() {
                    let p = sample.position + side * (half * f)
                    let u = Float(k) / Float(acrossCount - 1)
                    let edge = k == 0 || k == acrossCount - 1
                    let depth = depthValue(p, line.y, edge: edge)
                    verts.append(Vertex(position: SIMD3(p.x, line.y, p.y),
                                        normal: up,
                                        color: SIMD4(colour, depth),
                                        uv: SIMD2(u, along)))
                }
            }
            for i in fs..<le {
                let row = UInt32(i - fs)
                for k in 0..<(acrossCount - 1) {
                    let a = base + row * UInt32(acrossCount) + UInt32(k)
                    let b = a + 1
                    let c = a + UInt32(acrossCount)
                    let d = c + 1
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }

            // Caps only at unlinked ends: a source or a tarn/mouth.
            for end in [fs, le] {
                let sample = samples[end]
                let isStart = end == fs && reach.upstream.isEmpty
                let isEnd = end == le && reach.downstream == nil
                guard isStart || isEnd else { continue }
                let side = RiverChannel.sideVector(sample)
                let half = RiverChannel.halfWidth(sample)
                let line = RiverChannel.waterLine(t, sample)
                let colour = tint(sample)
                let along = sample.along / max(sample.width * 3.0, 1e-5)
                let capDepth = depthValue(sample.position, line.y,
                                          edge: false) * 0.7
                let centre = UInt32(verts.count)
                verts.append(Vertex(position: SIMD3(sample.position.x, line.y,
                                                   sample.position.y),
                                    normal: up,
                                    color: SIMD4(colour, capDepth),
                                    uv: SIMD2(0.5, along)))
                var ring: [UInt32] = []
                ring.reserveCapacity(17)
                let segments = 16
                let outward = sample.tangent * (isStart ? -1 : 1)
                for k in 0...segments {
                    let a = Float(k) / Float(segments) * Float.pi
                    let p = sample.position + side * (half * cos(a))
                        + outward * (half * 0.62 * sin(a))
                    ring.append(UInt32(verts.count))
                    verts.append(Vertex(position: SIMD3(p.x, line.y, p.y),
                                        normal: up,
                                        color: SIMD4(colour, 0),
                                        uv: SIMD2(0.5, along)))
                }
                for k in 0..<segments {
                    indices.append(contentsOf: [centre, ring[k], ring[k + 1]])
                    indices.append(contentsOf: [centre, ring[k + 1], ring[k]])
                }
            }
        }

        // One Y-shaped junction polygon, built from the five cut vertices of
        // every incident reach. The footprint is star-shaped around the
        // junction cell, so an angular fan is a valid triangulation.
        for d in network.indices where !network[d].upstream.isEmpty {
            let samples = network[d].samples
            guard !samples.isEmpty else { continue }
            let centre = samples[0].position
            let centreLine = RiverChannel.waterLine(t, samples[0]).y
            var ring: [(p: SIMD2<Float>, y: Float, depth: Float,
                        angle: Float)] = []

            func addCut(_ reachIndex: Int, _ sampleIndex: Int) {
                guard reachIndex >= 0, reachIndex < network.count else {
                    return
                }
                let reach = network[reachIndex]
                guard sampleIndex >= 0, sampleIndex < reach.samples.count else {
                    return
                }
                let sample = reach.samples[sampleIndex]
                let side = RiverChannel.sideVector(sample)
                let half = RiverChannel.halfWidth(sample)
                let line = RiverChannel.waterLine(t, sample)
                for (k, f) in RiverChannel.across.enumerated() {
                    let p = sample.position + side * (half * f)
                    if ring.contains(where: {
                        simd_distance($0.p, p) < 0.002
                    }) { continue }
                    let edge = k == 0 || k == acrossCount - 1
                    ring.append((p, line.y,
                                 depthValue(p, line.y, edge: edge),
                                 atan2(p.y - centre.y, p.x - centre.x)))
                }
            }
            addCut(d, firstKept[d])
            for a in network[d].upstream {
                addCut(a, lastKept[a])
            }
            guard ring.count >= 3 else { continue }
            ring.sort { $0.angle < $1.angle }

            let centreDepth = depthValue(centre, centreLine, edge: false) * 0.9
            let centreIndex = UInt32(verts.count)
            verts.append(Vertex(position: SIMD3(centre.x, centreLine, centre.y),
                                normal: up,
                                color: SIMD4(tint(samples[0]), centreDepth),
                                uv: SIMD2(0.5, 0.5)))
            var ringIndices: [UInt32] = []
            ringIndices.reserveCapacity(ring.count)
            for point in ring {
                ringIndices.append(UInt32(verts.count))
                verts.append(Vertex(position: SIMD3(point.p.x, point.y,
                                                   point.p.y),
                                    normal: up,
                                    color: SIMD4(tint(samples[0]), point.depth),
                                    uv: SIMD2(0.5, 0.5)))
            }
            for i in 0..<ring.count {
                let next = (i + 1) % ring.count
                indices.append(contentsOf: [centreIndex, ringIndices[i],
                                            ringIndices[next]])
                indices.append(contentsOf: [centreIndex, ringIndices[next],
                                            ringIndices[i]])
            }
        }

        // Closed-basin tarn: a round pond at the terminal sample.
        for reach in network where reach.downstream == nil && !reach.isMouth {
            guard let last = reach.samples.last else { continue }
            let centre = last.position
            let lineY = RiverChannel.waterLine(t, last).y
            let radius = RiverChannel.halfWidth(last) * 2.5
            let colour = tint(last)
            let centreDepth = depthValue(centre, lineY, edge: false) * 0.9
            let centreIndex = UInt32(verts.count)
            verts.append(Vertex(position: SIMD3(centre.x, lineY + 0.000002,
                                               centre.y),
                                normal: up,
                                color: SIMD4(colour, centreDepth),
                                uv: SIMD2(0.5, 0.5)))
            let segments = 24
            var ringIndices: [UInt32] = []
            ringIndices.reserveCapacity(segments)
            for k in 0..<segments {
                let a = Float(k) / Float(segments) * 2 * Float.pi
                let p = centre + SIMD2<Float>(cos(a), sin(a)) * radius
                ringIndices.append(UInt32(verts.count))
                verts.append(Vertex(position: SIMD3(p.x, lineY + 0.000002, p.y),
                                    normal: up,
                                    color: SIMD4(colour, 0),
                                    uv: SIMD2(0.5, 0.5)))
            }
            for k in 0..<segments {
                let n = (k + 1) % segments
                indices.append(contentsOf: [centreIndex, ringIndices[k],
                                            ringIndices[n]])
                indices.append(contentsOf: [centreIndex, ringIndices[n],
                                            ringIndices[k]])
            }
        }
        return (verts, indices)
    }

    /// Sloped banks either side of the river    /// Sloped banks either side of the river: waterline, damp margin,
    /// mid-slope, crest and outer apron. The waterline vertices share the
    /// water mesh's position exactly, so there is no seam to see through.
    static func riverBankGeometry(_ t: Terrain,
                                  network: [RiverReach],
                                  field: RiverChannel.Field) -> (vertices: [Vertex], indices: [UInt32]) {
        var verts: [Vertex] = []
        var indices: [UInt32] = []
        let acrossCount = 9
        for reach in network {
            let samples = reach.samples
            guard samples.count >= 2 else { continue }
            let lift: Float = 0

            // Open the bank around a junction. The water sheets of the
            // meeting reaches cover the gap; without this one stem's bank
            // runs across the other's mouth and leaves a land wedge.
            let metres = RiverChannel.metresPerUnit
            var startTrim: Float = 0
            if !reach.upstream.isEmpty, let first = samples.first {
                var radius = RiverChannel.halfWidth(first)
                for a in reach.upstream where a < network.count {
                    if let end = network[a].samples.last {
                        radius = max(radius, RiverChannel.halfWidth(end))
                    }
                }
                startTrim = radius * 1.0 * metres
            }
            var endTrim: Float = 0
            if let d = reach.downstream, d < network.count,
               let first = network[d].samples.first,
               let last = samples.last {
                endTrim = max(RiverChannel.halfWidth(last),
                              RiverChannel.halfWidth(first)) * 1.0 * metres
            }
            let totalLength = samples.last?.along ?? 0

            for sideSign in [Float(-1), Float(1)] {
                let base = UInt32(verts.count)
                for sample in samples {
                    let side = RiverChannel.sideVector(sample) * sideSign
                    let profile = RiverChannel.bankProfile(t, sample,
                                                           sideSign: sideSign,
                                                           lift: lift,
                                                           field: field)
                    for (pointIndex, point) in profile.enumerated() {
                        let p = sample.position + side * point.offset
                        // Sink the waterline vertex a few millimetres below
                        // the sheet (a visual seam offset, separate from terrain carving).
                        // Coplanar bank and water edges z-fight,
                        // and the bank triangles win in alternating pixels,
                        // which reads as a sawtooth of land inside the water.
                        let y = pointIndex == 0
                            ? point.y - (0.004 / RiverChannel.metresPerUnit) : point.y
                        verts.append(Vertex(position: SIMD3(p.x, y, p.y),
                                            normal: point.normal,
                                            color: SIMD4(point.color,
                                                         1 - point.wetness)))
                    }
                }
                for i in 0..<(samples.count - 1) {
                    if samples[i].along < startTrim
                        || samples[i + 1].along < startTrim { continue }
                    if totalLength - samples[i].along < endTrim
                        || totalLength - samples[i + 1].along < endTrim {
                        continue
                    }
                    for k in 0..<(acrossCount - 1) {
                        let a = base + UInt32(i * acrossCount + k)
                        let b = a + 1
                        let c = a + UInt32(acrossCount)
                        let d = c + 1
                        indices.append(contentsOf: [a, c, b, b, c, d])
                        indices.append(contentsOf: [a, b, c, b, d, c])
                    }
                }
            }
        }

        return (verts, indices)
    }

    static func waterGeometry(_ t: Terrain) -> (vertices: [Vertex], indices: [UInt32]) {
        let n = t.size
        // The water plane sits a hair above sea level; cells must be emitted
        // against this height, not 0, or a ring of barely-submerged beach is
        // left uncovered and reads as a coarse staircase.
        let waterLevel: Float = 0.0042
        var verts: [Vertex] = []
        var indices: [UInt32] = []
        var lookup = [Int: UInt32](minimumCapacity: n * n / 2)

        func vertex(_ i: Int, _ j: Int) -> UInt32 {
            if let existing = lookup[t.index(i, j)] { return existing }
            let idx = t.index(i, j)
            let depth = clamp01(-t.height[idx] / 0.075)
            let id = UInt32(verts.count)
            verts.append(Vertex(position: SIMD3(t.worldX(i), waterLevel, t.worldZ(j)),
                                normal: SIMD3(0, 1, 0),
                                color: SIMD4(depth, depth, depth, 1)))
            lookup[idx] = id
            return id
        }

        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let h00 = t.height[t.index(i, j)]
                let h10 = t.height[t.index(i + 1, j)]
                let h01 = t.height[t.index(i, j + 1)]
                let h11 = t.height[t.index(i + 1, j + 1)]
                guard min(h00, h10, h01, h11) < waterLevel else { continue }

                let a = vertex(i, j)
                let b = vertex(i + 1, j)
                let c = vertex(i + 1, j + 1)
                let d = vertex(i, j + 1)
                indices.append(contentsOf: [a, c, b, a, d, c])
            }
        }

        // Open ocean frame, out to the horizon. Depth 1 = fully deep water.
        let inner: Float = 1.0
        let outer: Float = 40.0
        let deep = SIMD4<Float>(1, 1, 1, 1)

        func frameVertex(_ x: Float, _ z: Float) -> UInt32 {
            let id = UInt32(verts.count)
            verts.append(Vertex(position: SIMD3(x, waterLevel, z),
                                normal: SIMD3(0, 1, 0), color: deep))
            return id
        }

        // Each strip is drawn as two triangles, wound so the surface faces up.
        func quad(_ x0: Float, _ x1: Float, _ z0: Float, _ z1: Float) {
            let v0 = frameVertex(x0, z0)
            let v1 = frameVertex(x1, z0)
            let v2 = frameVertex(x1, z1)
            let v3 = frameVertex(x0, z1)
            indices.append(contentsOf: [v0, v2, v1, v0, v3, v2])
        }

        // South, north, west and east bands around the island grid.
        quad(-outer,  outer, -outer, -inner)
        quad(-outer,  outer,  inner,  outer)
        quad(-outer, -inner, -inner,  inner)
        quad( inner,  outer, -inner,  inner)

        return (verts, indices)
    }

    // MARK: - Roads

    /// Lays a ribbon mesh along the road network. Each segment is resampled and
    /// split into a left/right pair of vertices that follow the terrain, which
    /// is what makes the roads hug hillsides instead of cutting through them.
    func rebuildRoads(_ segments: [RoadBuilder.Segment],
                      color: SIMD3<Float>,
                      bridgeColor: SIMD3<Float>,
                      marking: SIMD3<Float>?,
                      width: Float,
                      surface: RoadSurface,
                      bridge: BridgeStyle) throws {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        for segment in segments {
            let path = resample(segment)
            guard path.count >= 2 else { continue }
            let segmentWidth = max(width * segment.widthScale, 0.0008)
            let half = segmentWidth * 0.5

            if surface == .dirt {
                appendRibbon(path, half: half * 0.52, lateral: -half * 1.20,
                             lift: 0.0017, camber: half * 0.10,
                             color: color, surface: surface, skipPattern: 0,
                             into: &vertices, indices: &indices)
                appendRibbon(path, half: half * 0.46, lateral: half * 1.10,
                             lift: 0.0016, camber: half * 0.09,
                             color: color * 0.96, surface: surface, skipPattern: 1,
                             into: &vertices, indices: &indices)
            } else {
                appendRibbon(path, half: half, lateral: 0,
                             lift: 0.0019, camber: half * 0.12,
                             color: color, surface: surface, skipPattern: 0,
                             into: &vertices, indices: &indices)
            }

            if surface == .dirt || surface == .gravel {
                // Steeper ground gets taller banks, reading as a hollow way.
                let slope = terrain.grade(from: path.first!, to: path.last!)
                let bankLift = 0.0014 + min(slope, 1.0) * 0.0025
                for side in [Float(-1), Float(1)] {
                    appendRibbon(path, half: half * 0.34,
                                 lateral: side * half * 1.38,
                                 lift: bankLift, camber: 0,
                                 color: SIMD3(0.32, 0.27, 0.19),
                                 surface: .dirt, skipPattern: 0,
                                 into: &vertices, indices: &indices)
                }
            }

            if let marking {
                appendMarkings(path, color: marking, width: segmentWidth,
                               into: &vertices, indices: &indices)
            }

            appendBridges(path, color: bridgeColor, halfWidth: half,
                          bridge: bridge, surface: surface,
                          into: &vertices, indices: &indices)
        }

        guard vertices.count >= 3, indices.count >= 3 else {
            roadMesh = nil
            return
        }
        roadMesh = try Mesh(device: device, vertices: vertices, indices: indices)
    }

    /// A cambered five-vertex ribbon: shoulders, wheel tracks and a raised
    /// crown. `skipPattern` punches gaps into braided dirt tracks.
    private func appendRibbon(_ path: [SIMD2<Float>],
                              half: Float,
                              lateral: Float,
                              lift: Float,
                              camber: Float,
                              color: SIMD3<Float>,
                              surface: RoadSurface,
                              skipPattern: Int,
                              into vertices: inout [Vertex],
                              indices: inout [UInt32]) {
        let up = SIMD3<Float>(0, 1, 0)
        let across: [Float] = [1, 0.62, 0, -0.62, -1]
        let surfaceValue = Float(surface.rawValue)
        let base = UInt32(vertices.count)
        var travelled: Float = 0

        for i in 0..<path.count {
            if i > 0 { travelled += simd_distance(path[i], path[i - 1]) }
            let prev = path[max(i - 1, 0)]
            let next = path[min(i + 1, path.count - 1)]
            var dir = next - prev
            let len = simd_length(dir)
            if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
            let side = SIMD2(-dir.y, dir.x)
            let centre = path[i] + side * lateral

            var highest = terrain.interpolatedHeight(x: centre.x, z: centre.y)
            for t in across {
                let p = centre + side * (t * half)
                highest = max(highest, terrain.interpolatedHeight(x: p.x, z: p.y))
            }

            let grainRaw = sin(centre.x * 12.9898 + centre.y * 78.233) * 43_758.547
            let grain = grainRaw - floor(grainRaw)
            let shade = 0.91 + 0.16 * grain

            for t in across {
                let p = centre + side * (t * half)
                let crown = 1 - pow(abs(t), 1.6)
                let y = highest + lift + camber * crown
                vertices.append(Vertex(position: SIMD3(p.x, y, p.y),
                                       normal: up,
                                       color: SIMD4(color * shade, surfaceValue),
                                       uv: SIMD2((1 - t) * 0.5,
                                                 travelled / max(half * 2, 0.0008))))
            }

            if i == 0 { continue }
            if skipPattern > 0 && (i / 5) % 3 == skipPattern - 1 { continue }
            for k in 0..<4 {
                let a = base + UInt32((i - 1) * 5 + k)
                let b = a + 1
                let c = a + 5
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
    }

    func rebuildStreets(_ lines: [CityBuilder.StreetLine],
                        color: SIMD3<Float>,
                        surface: RoadSurface) throws {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        for (lineIndex, line) in lines.enumerated() {
            let path = line.points
            guard path.count >= 2 else { continue }
            let half = max(line.width, 0.0008) * 0.5
            let lift: Float = 0.0014 + Float(lineIndex % 6) * 0.000025

            appendRibbon(path, half: half, lateral: 0,
                         lift: lift, camber: half * 0.10,
                         color: color, surface: surface, skipPattern: 0,
                         into: &vertices, indices: &indices)

            // Kerbs and gutters from the classical era on.
            if surface != .dirt && surface != .asphalt {
                for side in [Float(-1), Float(1)] {
                    appendRibbon(path, half: max(half * 0.10, 0.00014),
                                 lateral: side * half * 1.16,
                                 lift: lift + 0.00055, camber: 0.00015,
                                 color: SIMD3(0.38, 0.37, 0.34),
                                 surface: .romanStone, skipPattern: 0,
                                 into: &vertices, indices: &indices)
                }
            }
        }

        guard vertices.count >= 3, indices.count >= 3 else {
            streetMesh = nil
            return
        }
        streetMesh = try Mesh(device: device, vertices: vertices, indices: indices)
    }

    /// Dashed centre line for modern roads.
    private func appendMarkings(_ path: [SIMD2<Float>],
                                color: SIMD3<Float>,
                                width: Float,
                                into vertices: inout [Vertex],
                                indices: inout [UInt32]) {
        let lift: Float = 0.0024
        let half = max(width, 0.0003) * 0.5
        let up = SIMD3<Float>(0, 1, 0)
        let dash: Float = 0.005
        let gap: Float = 0.008

        var distanceToNext: Float = 0.003

        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let d = simd_distance(a, b)
            guard d > 1e-6 else { continue }
            let dir = (b - a) / d
            let side = SIMD2<Float>(-dir.y, dir.x)

            var t: Float = 0
            while t + distanceToNext <= d {
                t += distanceToNext
                distanceToNext = dash + gap

                let p = a + dir * t
                let y = terrain.interpolatedHeight(x: p.x, z: p.y) + lift
                let l = p + side * half
                let r = p - side * half
                let l2 = l + dir * dash
                let r2 = r + dir * dash

                let base = UInt32(vertices.count)
                let paint = Float(RoadSurface.paint.rawValue)
                vertices.append(Vertex(position: SIMD3(l.x, y, l.y), normal: up, color: SIMD4(color, paint)))
                vertices.append(Vertex(position: SIMD3(r.x, y, r.y), normal: up, color: SIMD4(color, paint)))
                vertices.append(Vertex(position: SIMD3(r2.x, y, r2.y), normal: up, color: SIMD4(color, paint)))
                vertices.append(Vertex(position: SIMD3(l2.x, y, l2.y), normal: up, color: SIMD4(color, paint)))
                indices.append(contentsOf: [base, base + 2, base + 1,
                                            base, base + 3, base + 2])
            }
            distanceToNext -= (d - t)
        }
    }

    private func resample(_ segment: RoadBuilder.Segment) -> [SIMD2<Float>] {
        var path: [SIMD2<Float>] = []
        for i in 0..<(segment.points.count - 1) {
            let a = segment.points[i]
            let b = segment.points[i + 1]
            let d = simd_distance(a, b)
            let steps = max(Int((d / 0.006).rounded(.up)), 1)
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                path.append(a + (b - a) * t)
            }
        }
        if let last = segment.points.last { path.append(last) }
        return path
    }

    /// River crossings: a flat gravel ford before bridges, then an arched
    /// deck with parapets in stone, iron or concrete.
    private func appendBridges(_ path: [SIMD2<Float>],
                               color: SIMD3<Float>,
                               halfWidth: Float,
                               bridge: BridgeStyle,
                               surface: RoadSurface,
                               into vertices: inout [Vertex],
                               indices: inout [UInt32]) {
        let lift: Float = 0.0018
        let up = SIMD3<Float>(0, 1, 0)
        var i = 0

        // Cross the rendered water surface, not the narrower raster mask.
        // The smoothed channel can reach several metres beyond the D8 cells;
        // a deck keyed to the raster stops at the waterline and leaves the
        // road running under the sheet.
        func inChannel(_ p: SIMD2<Float>) -> Bool {
            guard let surface = riverField.surface(at: p) else { return false }
            return surface.distance < 2.0 / RiverChannel.metresPerUnit
        }

        func waterAt(_ p: SIMD2<Float>) -> Float {
            riverField.waterLevel(at: p) ?? -Float.greatestFiniteMagnitude
        }

        func deckHeight(_ p: SIMD2<Float>, arch: Float) -> Float {
            let ground = terrain.interpolatedHeight(x: p.x, z: p.y)
            return max(ground, waterAt(p)) + lift + arch
        }

        func deckSurface() -> RoadSurface {
            switch bridge {
            case .ford: return .gravel
            case .stone: return .romanStone
            case .iron: return .sett
            case .concrete: return .asphalt
            }
        }

        while i < path.count {
            if !inChannel(path[i]) {
                i += 1
                continue
            }

            var j = i
            while j < path.count && inChannel(path[j]) {
                j += 1
            }

            let start = max(i - 1, 0)
            let end = min(j, path.count - 1)
            let count = end - start + 1
            guard count >= 2 else { i = j; continue }

            // A road running parallel to the river inside the same margin is
            // not a crossing. Reject spans far longer than any bridge and
            // leave the road to follow the bank.
            var span: Float = 0
            for k in start..<end {
                span += simd_distance(path[k], path[k + 1])
            }
            guard span < 120 / RiverChannel.metresPerUnit else { i = j; continue }

            if !bridge.hasParapets {
                // Ford: a wide, flat gravel fan across the water.
                let base = UInt32(vertices.count)
                let fordHalf = halfWidth * 2.0
                for k in 0..<count {
                    let idx = start + k
                    let p = path[idx]
                    let prev = path[max(idx - 1, start)]
                    let next = path[min(idx + 1, end)]
                    var dir = next - prev
                    let len = simd_length(dir)
                    if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
                    let side = SIMD2(-dir.y, dir.x)
                    let y = max(terrain.interpolatedHeight(x: p.x, z: p.y),
                                waterAt(p)) + lift * 0.10
                    let l = p + side * fordHalf
                    let r = p - side * fordHalf
                    let value = Float(RoadSurface.gravel.rawValue)
                    vertices.append(Vertex(position: SIMD3(l.x, y, l.y),
                                           normal: up, color: SIMD4(color * 0.92, value),
                                           uv: SIMD2(0, Float(k) * 0.5)))
                    vertices.append(Vertex(position: SIMD3(r.x, y, r.y),
                                           normal: up, color: SIMD4(color * 0.92, value),
                                           uv: SIMD2(1, Float(k) * 0.5)))
                }
                for k in 0..<(count - 1) {
                    let a = base + UInt32(k * 2)
                    let b = a + 1
                    let c = a + 2
                    let d = a + 3
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
                i = j
                continue
            }

            let base = UInt32(vertices.count)
            for k in 0..<count {
                let idx = start + k
                let p = path[idx]
                let prev = path[max(idx - 1, start)]
                let next = path[min(idx + 1, end)]
                var dir = next - prev
                let len = simd_length(dir)
                if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
                let side = SIMD2(-dir.y, dir.x)
                let t = Float(k) / Float(max(count - 1, 1))
                let arch = sin(t * .pi) * 0.0022
                let y = deckHeight(p, arch: arch)
                let l = p + side * halfWidth
                let r = p - side * halfWidth
                let value = Float(deckSurface().rawValue)
                vertices.append(Vertex(position: SIMD3(l.x, y, l.y),
                                       normal: up, color: SIMD4(color, value),
                                       uv: SIMD2(0, Float(k) * 0.5)))
                vertices.append(Vertex(position: SIMD3(r.x, y, r.y),
                                       normal: up, color: SIMD4(color, value),
                                       uv: SIMD2(1, Float(k) * 0.5)))
            }
            for k in 0..<(count - 1) {
                let a = base + UInt32(k * 2)
                let b = a + 1
                let c = a + 2
                let d = a + 3
                indices.append(contentsOf: [a, c, b, b, c, d])
            }

            // Parapets: stone walls, iron rails or concrete barriers.
            let railColour: SIMD3<Float>
            switch bridge {
            case .stone: railColour = color * 0.82
            case .iron: railColour = SIMD3(0.28, 0.26, 0.24)
            case .concrete: railColour = SIMD3(0.62, 0.62, 0.60)
            case .ford: railColour = color
            }
            for sideSign in [Float(-1), Float(1)] {
                let railBase = UInt32(vertices.count)
                for k in 0..<count {
                    let idx = start + k
                    let p = path[idx]
                    let prev = path[max(idx - 1, start)]
                    let next = path[min(idx + 1, end)]
                    var dir = next - prev
                    let len = simd_length(dir)
                    if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
                    let side = SIMD2(-dir.y, dir.x)
                    let t = Float(k) / Float(max(count - 1, 1))
                    let arch = sin(t * .pi) * 0.0022
                    let deck = deckHeight(p, arch: arch)
                    let edge = p + side * (halfWidth * sideSign)
                    let value = Float(deckSurface().rawValue)
                    vertices.append(Vertex(position: SIMD3(edge.x, deck, edge.y),
                                           normal: up, color: SIMD4(railColour, value)))
                    vertices.append(Vertex(position: SIMD3(edge.x, deck + 0.0016, edge.y),
                                           normal: up, color: SIMD4(railColour, value)))
                }
                for k in 0..<(count - 1) {
                    let a = railBase + UInt32(k * 2)
                    let b = a + 1
                    let c = a + 2
                    let d = a + 3
                    indices.append(contentsOf: [a, c, b, b, c, d])
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }

                // Parapet detail: stone merlons, iron posts or concrete posts.
                let postStride = bridge == .stone ? 3 : 2
                for k in stride(from: 0, to: count, by: postStride) {
                    let idx = start + k
                    let p = path[idx]
                    let prev = path[max(idx - 1, start)]
                    let next = path[min(idx + 1, end)]
                    var dir = next - prev
                    let len = simd_length(dir)
                    if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
                    let side = SIMD2(-dir.y, dir.x)
                    let t = Float(k) / Float(max(count - 1, 1))
                    let arch = sin(t * .pi) * 0.0022
                    let deck = deckHeight(p, arch: arch)
                    let edge = p + side * (halfWidth * sideSign)
                    let postHalf: Float = bridge == .stone ? 0.00035 : 0.00018
                    let top: Float = bridge == .stone ? 0.0009 : 0.0010
                    let a = edge - dir * postHalf
                    let b = edge + dir * postHalf
                    let y0 = deck + 0.0016
                    let y1 = y0 + top
                    let vb = UInt32(vertices.count)
                    let value = Float(deckSurface().rawValue)
                    vertices.append(Vertex(position: SIMD3(a.x, y0, a.y), normal: up,
                                           color: SIMD4(railColour, value)))
                    vertices.append(Vertex(position: SIMD3(b.x, y0, b.y), normal: up,
                                           color: SIMD4(railColour, value)))
                    vertices.append(Vertex(position: SIMD3(a.x, y1, a.y), normal: up,
                                           color: SIMD4(railColour, value)))
                    vertices.append(Vertex(position: SIMD3(b.x, y1, b.y), normal: up,
                                           color: SIMD4(railColour, value)))
                    indices.append(contentsOf: [vb, vb + 1, vb + 2,
                                                vb + 1, vb + 3, vb + 2])
                    indices.append(contentsOf: [vb, vb + 2, vb + 1,
                                                vb + 1, vb + 2, vb + 3])
                }
            }

            i = j
        }
    }

    // MARK: - Rail

    private(set) var railMesh: Mesh?

    /// Ballast, two steel rails and sleepers along a path. The train itself is
    /// instanced by the renderer and moves along the same path.
    func rebuildRail(_ path: [SIMD2<Float>], color: SIMD3<Float>) throws {
        guard path.count >= 2 else {
            railMesh = nil
            return
        }

        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        let lift: Float = 0.0012
        let up = SIMD3<Float>(0, 1, 0)
        let half: Float = 0.0018
        let gauge: Float = 0.0009
        let railWidth: Float = 0.00030
        let steel = SIMD3<Float>(0.62, 0.62, 0.66)
        let sleeperColour = SIMD3<Float>(0.28, 0.22, 0.16)

        func direction(_ i: Int) -> SIMD2<Float> {
            let prev = path[max(i - 1, 0)]
            let next = path[min(i + 1, path.count - 1)]
            var dir = next - prev
            let len = simd_length(dir)
            return len < 1e-6 ? SIMD2(1, 0) : dir / len
        }

        func surface(_ p: SIMD2<Float>, _ side: SIMD2<Float>, _ halfWidth: Float) -> Float {
            let l = p + side * halfWidth
            let r = p - side * halfWidth
            return max(terrain.interpolatedHeight(x: l.x, z: l.y),
                       max(terrain.interpolatedHeight(x: r.x, z: r.y),
                           terrain.interpolatedHeight(x: p.x, z: p.y)))
        }

        // Ballast.
        let base = UInt32(vertices.count)
        for i in 0..<path.count {
            let dir = direction(i)
            let side = SIMD2<Float>(-dir.y, dir.x)
            let p = path[i]
            let y = surface(p, side, half) + lift
            let l = p + side * half
            let r = p - side * half
            vertices.append(Vertex(position: SIMD3(l.x, y, l.y), normal: up, color: SIMD4(color, 1)))
            vertices.append(Vertex(position: SIMD3(r.x, y, r.y), normal: up, color: SIMD4(color, 1)))
        }
        for i in 0..<(path.count - 1) {
            let a = base + UInt32(i * 2)
            let b = a + 1
            let c = a + 2
            let d = a + 3
            indices.append(contentsOf: [a, c, b, b, c, d])
        }

        // Rails.
        for sideSign in [Float(-1), Float(1)] {
            let railBase = UInt32(vertices.count)
            for i in 0..<path.count {
                let dir = direction(i)
                let side = SIMD2<Float>(-dir.y, dir.x)
                let centre = path[i] + side * (gauge * sideSign)
                let y = surface(centre, side, railWidth) + lift + 0.0005
                let l = centre + side * (railWidth * 0.5)
                let r = centre - side * (railWidth * 0.5)
                vertices.append(Vertex(position: SIMD3(l.x, y, l.y), normal: up, color: SIMD4(steel, 1)))
                vertices.append(Vertex(position: SIMD3(r.x, y, r.y), normal: up, color: SIMD4(steel, 1)))
            }
            for i in 0..<(path.count - 1) {
                let a = railBase + UInt32(i * 2)
                let b = a + 1
                let c = a + 2
                let d = a + 3
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        // Sleepers.
        var travelled: Float = 0
        var nextSleeper: Float = 0.003
        let sleeperLength: Float = 0.0007

        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let d = simd_distance(a, b)
            guard d > 1e-6 else { continue }
            let dir = (b - a) / d
            let side = SIMD2<Float>(-dir.y, dir.x)

            while nextSleeper <= travelled + d {
                let t = (nextSleeper - travelled) / d
                let p = a + (b - a) * t
                let y = surface(p, side, half) + lift + 0.0002
                let l = p + side * (half * 0.95)
                let r = p - side * (half * 0.95)
                let bl = l - dir * (sleeperLength * 0.5)
                let br = r - dir * (sleeperLength * 0.5)
                let fl = l + dir * (sleeperLength * 0.5)
                let fr = r + dir * (sleeperLength * 0.5)
                let sb = UInt32(vertices.count)
                vertices.append(Vertex(position: SIMD3(bl.x, y, bl.y), normal: up, color: SIMD4(sleeperColour, 1)))
                vertices.append(Vertex(position: SIMD3(br.x, y, br.y), normal: up, color: SIMD4(sleeperColour, 1)))
                vertices.append(Vertex(position: SIMD3(fr.x, y, fr.y), normal: up, color: SIMD4(sleeperColour, 1)))
                vertices.append(Vertex(position: SIMD3(fl.x, y, fl.y), normal: up, color: SIMD4(sleeperColour, 1)))
                indices.append(contentsOf: [sb, sb + 2, sb + 1, sb, sb + 3, sb + 2])
                nextSleeper += 0.006
            }
            travelled += d
        }

        railMesh = try Mesh(device: device, vertices: vertices, indices: indices)
    }

}
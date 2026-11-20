import Foundation
import simd

/// Class-specific endpoint checks against submitted water and ocean faces.
enum RiverEndpointValidation {
    private static func oceanOverlapArea(_ ocean: (vertices: [Vertex], indices: [UInt32]),
                                         river: RiverSurface.Geometry) -> Double {
        let oceanFaces = stride(from: 0, to: ocean.indices.count, by: 3).compactMap { i -> [Vertex]? in
            let tri = (0..<3).map { ocean.vertices[Int(ocean.indices[i + $0])] }
            return tri.allSatisfy { abs($0.position.x) <= 1 && abs($0.position.z) <= 1 } ? tri : nil
        }
        let index = RiverTriangleBuckets(oceanFaces)
        var overlap: Double = 0
        for i in stride(from: 0, to: river.indices.count, by: 3) {
            let tri = (0..<3).map { river.vertices[Int(river.indices[i + $0])] }
            guard tri.allSatisfy({ $0.position.y == 0 }) else { continue }
            for ocean in index.near(tri) where RiverPolygon.overlaps(tri, ocean) {
                overlap += abs(RiverPolygon.area(RiverGeometryChecks.intersection(tri, ocean,
                    inset: RiverPolygon.epsilon))) * 1_000_000
            }
        }
        return overlap
    }
    static func fixtureTerrain() -> Terrain {
        let n = 17, count = n * n, metres = RiverGraph.metresPerUnit
        var t = Terrain(size: n, seed: 1, height: Array(repeating: 110 / metres, count: count),
            flow: Array(repeating: 0, count: count), river: Array(repeating: 0, count: count),
            moisture: Array(repeating: 0.5, count: count), slope: Array(repeating: 0, count: count),
            biome: Array(repeating: Terrain.Biome.grass.rawValue, count: count),
            fertility: Array(repeating: 0, count: count), waterDistance: Array(repeating: 0, count: count),
            ao: Array(repeating: 1, count: count))
        var cells: [Int] = []
        for j in 7...9 { for i in 7...9 where i != 8 || j != 8 {
            let cell = j * n + i; cells.append(cell); t.height[cell] = 90 / metres
        }}
        let lake = RiverLake(id: 0, level: 100 / metres, cells: cells)
        let samples = (0...60).map { i -> RiverSample in
            let along = Float(i) * 275 / 60 // metres along the fixture stream
            let fraction = min(along / 55, 1), ramp = fraction * fraction * (3 - 2 * fraction)
            return RiverSample(position: SIMD2(0.4 - along / metres, 0), bed: 99.4 / metres,
                width: 4 / metres, tangent: SIMD2(-1, 0), channelWidth: 4 / metres,
                sourceWidthFactor: (0.15 + 1.85 * ramp) / 2, along: along, waterOverride: 100 / metres)
        }
        let reach = RiverReach(id: 0, samples: samples, isSource: true, isMouth: true,
            firstCell: 8 * n + 11, lastCell: 8 * n + 9, endpoint: .basinLake(0), origin: .spring)
        t.riverGraph = RiverGraph(reaches: [reach], diagnostics: RiverDiagnostics(), lakes: [lake])
        t.lakeWater = Array(repeating: 0, count: count)
        for cell in cells { t.lakeWater[cell] = lake.level }
        return t
    }

    static func fixtures() -> Bool {
        let terrain = fixtureTerrain(), network = terrain.riverGraph!.reaches
        let field = RiverChannel.Field(terrain: terrain, network: network)
        let faces = stride(from: 0, to: field.mesh.indices.count, by: 3).map { i in
            (0..<3).map { field.mesh.vertices[Int(field.mesh.indices[i + $0])] }
        }
        let deep = SIMD2<Float>(0.125, 0), island = SIMD2<Float>.zero
        var sea = terrain; sea.height = Array(repeating: -0.01, count: sea.height.count) // sea bed -10 m
        let zero = [Vertex(position: SIMD3(-0.005, 0, -0.005), normal: SIMD3(0,1,0), rgb: .zero),
                    Vertex(position: SIMD3(0, 0, 0.005), normal: SIMD3(0,1,0), rgb: .zero),
                    Vertex(position: SIMD3(0.005, 0, -0.005), normal: SIMD3(0,1,0), rgb: .zero)]
        let mouth = RiverSurface.Geometry(vertices: zero, indices: [0,1,2], junctions: [], ribbonWidths: [])
        let legacyOverlap = oceanOverlapArea(WorldScene.waterGeometry(sea), river: mouth)
        let repairedOverlap = oceanOverlapArea(WorldScene.waterGeometry(sea, excludingRiver: mouth), river: mouth)
        let passes = run(terrain, network: network, field: field)
            && field.waterLevel(at: island) == nil && !terrain.isWater(x: 0, z: 0)
            && field.waterLevel(at: deep) != nil && terrain.isWater(x: deep.x, z: deep.y)
            && field.carvedHeight(0.09, at: deep, supportRadius: 0) <= 0.09 // preserve 90 m deep terrain
            && RiverPolygon.boundaryFailures(faces) == 0
            && legacyOverlap > 1 && repairedOverlap <= 0.000001
        print("bounded basin fixture: \(passes ? "PASS" : "FAIL") (closed shoreline, dry island, spring entry, no deep-terrain filling)")
        print("ocean/mouth sheet fixture: before \(legacyOverlap) m², after \(repairedOverlap) m² beyond 0.1 mm band")
        return passes
    }

    static func run(_ terrain: Terrain, network: [RiverReach], field: RiverChannel.Field) -> Bool {
        let metres = RiverGraph.metresPerUnit
        let band = 0.0001 / metres, levelTolerance = 0.001 / metres // 0.1 mm, 1 mm
        var failures = 0, springs = 0, lakeOrigins = 0, coasts = 0, lakeEnds = 0
        func covered(_ p: SIMD2<Float>, level: Float, triangles: [[Vertex]]) -> Bool {
            triangles.contains {
                let probe = RiverChannel.Field.probe($0, p)
                return probe.distance <= band && abs(probe.water - level) <= levelTolerance
            }
        }
        let carved = RiverChannel.carvedTerrain(terrain, field: field)
        let ocean = WorldScene.waterGeometry(carved, excludingRiver: field.mesh)
        let oceanOverlap = oceanOverlapArea(ocean, river: field.mesh)
        let rawCoast = RiverCoastalBanks.intrusionArea((field.mesh.vertices,field.mesh.indices),terrain:terrain)
        let elevatedCoast = RiverCoastalBanks.intrusionArea((field.mesh.vertices,field.mesh.indices),terrain:terrain,minimumHeight:levelTolerance)
        print("raw river over original ocean (including <= 1 mm height band): \(rawCoast) m²")
        print("elevated river over original ocean: \(elevatedCoast) m², expected <= 0.000001 m²")
        if elevatedCoast > 0.000001 { failures += 1 }
        if oceanOverlap > 0.000001 { print("ocean/mouth duplicate upward sheets: \(oceanOverlap) m², expected <= 0.000001 m²"); failures += 1 }
        for reach in network {
            guard let first = reach.samples.first, let last = reach.samples.last else { failures += 1; continue }
            if reach.upstream.isEmpty {
                switch reach.origin {
                case .spring:
                    springs += 1
                    let sourceAboveGround = RiverGraph.waterLevel(first)
                        - terrain.originalTriangleHeight(at: first.position)
                    if sourceAboveGround > levelTolerance {
                        print("endpoint R\(reach.id): spring water \(sourceAboveGround * metres) m above original ground; expected <= 0.001 m")
                        failures += 1
                    }
                    // The actual narrow tip must exist in the submitted mesh.
                    for sign: Float in [-1, 1] {
                        let p = first.position + RiverChannel.sideVector(first) * (sign * 0.15 / metres)
                        if !covered(p, level: RiverGraph.waterLevel(first), triangles: field.nearbyTriangles(p)) {
                            let probes = field.nearbyTriangles(p).map { RiverChannel.Field.probe($0, p) }
                            let distance = probes.map { $0.distance * metres }.min() ?? .infinity
                            let error = probes.filter { $0.distance <= band }.map { abs($0.water - RiverGraph.waterLevel(first)) * metres }.min() ?? .infinity
                            print("endpoint R\(reach.id): spring tip at \(p), distance \(distance) m (<= 0.0001), level error \(error) m (<= 0.001)"); failures += 1
                        }
                    }
                case .basinLake(let id):
                    lakeOrigins += 1
                    guard let lake = terrain.riverGraph?.lakes.first(where: { $0.id == id }),
                          covered(first.position, level: lake.level, triangles: field.nearbyTriangles(first.position)) else {
                        print("endpoint R\(reach.id): lake origin not covered"); failures += 1; continue
                    }
                case .junction:
                    print("endpoint R\(reach.id): unclassified source"); failures += 1
                }
            }
            guard reach.downstream == nil else { continue }
            switch reach.endpoint {
            case .coastalMouth:
                coasts += 1
                var contact = false
                for i in stride(from: 0, to: ocean.indices.count, by: 3) {
                    let tri = (0..<3).map { ocean.vertices[Int(ocean.indices[i + $0])] }
                    let p = last.position
                    if tri.map({ $0.position.x }).min()! > p.x + band || tri.map({ $0.position.x }).max()! < p.x - band
                        || tri.map({ $0.position.z }).min()! > p.y + band || tri.map({ $0.position.z }).max()! < p.y - band { continue }
                    if covered(p, level: 0, triangles: [tri]) { contact = true; break }
                }
                if !contact || !covered(last.position, level: 0, triangles: field.nearbyTriangles(last.position)) {
                    print("endpoint R\(reach.id): ocean/river footprint or sea-level contact missing"); failures += 1
                }
            case .basinLake(let id):
                lakeEnds += 1
                guard let lake = terrain.riverGraph?.lakes.first(where: { $0.id == id }),
                      covered(last.position, level: lake.level, triangles: field.nearbyTriangles(last.position)) else {
                    print("endpoint R\(reach.id): terminal lake connection missing"); failures += 1; continue
                }
            case .linked:
                print("endpoint R\(reach.id): terminal has no classified outlet"); failures += 1
            }
        }
        var lakeFaces = 0, lakeBoundaryFailures = 0
        var maxShoreHeightError: Float = 0
        for triangle in field.mesh.lakeTriangles {
            lakeFaces += 1
            let error = triangle.map {
                terrain.originalTriangleHeight(at: SIMD2($0.position.x, $0.position.z)) - $0.position.y
            }.max()!
            maxShoreHeightError = max(maxShoreHeightError, error * metres)
            if error > band { lakeBoundaryFailures += 1 }
        }
        failures += lakeBoundaryFailures
        if lakeBoundaryFailures > 0 { print("lake boundary: \(lakeBoundaryFailures) faces above original terrain contour; max error \(maxShoreHeightError) m, expected <= 0.0001 m") }
        print("endpoint geometry: \(springs) springs, \(lakeOrigins) lake origins, \(coasts) coastal mouths, \(lakeEnds) basin ends; \(lakeFaces) terrain-bounded lake faces; \(failures) failures: \(failures == 0 ? "PASS" : "FAIL")")
        return failures == 0
    }
}

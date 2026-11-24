import simd

/// Cultivated ground is cut from the submitted terrain triangles. Planar
/// parcel boundaries and obstacle cuts are independent of the terrain grid.
enum FieldSurface {
    private static let metres = RiverGraph.metresPerUnit
    static let cropLift: Float = 0.04 / metres // 4 cm surface relief above the soil
    private static let minFragmentArea = 0.02 / pow(Double(metres), 2) // square metres

    private struct Bounds {
        let low: SIMD2<Float>
        let high: SIMD2<Float>

        init(_ polygon: [Vertex]) {
            let first = FieldSurface.xz(polygon[0])
            low = polygon.dropFirst().reduce(first) { simd_min($0, FieldSurface.xz($1)) }
            high = polygon.dropFirst().reduce(first) { simd_max($0, FieldSurface.xz($1)) }
        }

        func overlaps(_ other: Bounds) -> Bool {
            low.x < other.high.x && high.x > other.low.x && low.y < other.high.y && high.y > other.low.y
        }
    }

    /// The road and street exclusion uses the actual uploaded geometry,
    /// including curbs, berms and bridge approaches.
    struct Mask {
        private static let bucketSize: Float = 20 / FieldSurface.metres
        private var polygons: [[Vertex]] = []
        private var bounds: [Bounds] = []
        private var buckets: [SIMD2<Int32>: [Int]] = [:]

        init() {}

        init(mesh: Mesh?) {
            guard let mesh, let indexBuffer = mesh.indexBuffer else { return }
            let vertices = mesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
            let indices = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in stride(from: 0, to: mesh.indexCount, by: 3) {
                let a = vertices[Int(indices[i])], b = vertices[Int(indices[i + 1])], c = vertices[Int(indices[i + 2])]
                let ab = FieldSurface.xz(b) - FieldSurface.xz(a), ac = FieldSurface.xz(c) - FieldSurface.xz(a)
                // Upward projected faces carry the visible road footprint.
                if Double(ab.x) * Double(ac.y) - Double(ab.y) * Double(ac.x) < -2 * RiverPolygon.areaEpsilon {
                    insert([a, b, c])
                }
            }
        }

        private static func bucket(_ value: Float) -> Int32 {
            Int32(floor(value / bucketSize))
        }

        mutating func insert(_ polygon: [Vertex]) {
            let box = Bounds(polygon), id = polygons.count
            polygons.append(polygon)
            bounds.append(box)
            for z in Self.bucket(box.low.y)...Self.bucket(box.high.y) {
                for x in Self.bucket(box.low.x)...Self.bucket(box.high.x) {
                    buckets[SIMD2(x, z), default: []].append(id)
                }
            }
        }

        mutating func insertFootprint(_ points: [SIMD2<Float>]) {
            let polygon = points.map(FieldSurface.projection)
            guard abs(RiverPolygon.area(polygon)) > RiverPolygon.areaEpsilon else { return }
            insert(polygon)
        }

        func intersectsFootprint(_ points: [SIMD2<Float>]) -> Bool {
            let polygon = points.map(FieldSurface.projection)
            return nearby(polygon).contains {
                abs(RiverPolygon.area(RiverGeometryChecks.intersection(polygon, $0)))
                    > RiverPolygon.areaEpsilon
            }
        }

        func covers(_ point: SIMD2<Float>) -> Bool {
            height(at: point) != nil
        }

        func height(at point: SIMD2<Float>) -> Float? {
            // Give the spatial lookup a nonzero bounds box at triangle edges.
            let half: Float = 0.01 / FieldSurface.metres
            let corners = [point - SIMD2(half, half), point + SIMD2(half, -half),
                           point + SIMD2(half, half), point + SIMD2(-half, half)]
            var height: Float?
            for triangle in nearby(corners.map(FieldSurface.projection)) {
                let a = FieldSurface.xz(triangle[0])
                let u = FieldSurface.xz(triangle[1]) - a
                let v = FieldSurface.xz(triangle[2]) - a
                let w = point - a
                func cross(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Float {
                    lhs.x * rhs.y - lhs.y * rhs.x
                }
                let area = cross(u, v)
                guard area != 0 else { continue }
                let t = cross(w, v) / area
                let s = cross(u, w) / area
                guard t >= 0, s >= 0, t + s <= 1 else { continue }
                let y = triangle[0].position.y * (1 - t - s)
                    + triangle[1].position.y * t + triangle[2].position.y * s
                height = max(height ?? y, y)
            }
            return height
        }

        func nearby(_ polygon: [Vertex]) -> [[Vertex]] {
            let box = Bounds(polygon)
            var ids: Set<Int> = []
            for z in Self.bucket(box.low.y)...Self.bucket(box.high.y) {
                for x in Self.bucket(box.low.x)...Self.bucket(box.high.x) {
                    for id in buckets[SIMD2(x, z)] ?? [] where bounds[id].overlaps(box) { ids.insert(id) }
                }
            }
            return ids.sorted().map { polygons[$0] }
        }
    }

    private static func xz(_ v: Vertex) -> SIMD2<Float> { SIMD2(v.position.x, v.position.z) }

    private static func projection(_ p: SIMD2<Float>) -> Vertex {
        Vertex(position: SIMD3(p.x, 0, p.y), normal: SIMD3(0, 1, 0), rgb: .zero)
    }

    private static func cut(_ field: [Vertex], around obstacles: [[Vertex]]) -> [[Vertex]] {
        var pieces = [field]
        for obstacle in obstacles {
            guard !pieces.isEmpty else { break }
            let box = Bounds(obstacle)
            pieces = pieces.flatMap { piece in
                guard box.overlaps(Bounds(piece)),
                      abs(RiverPolygon.area(RiverGeometryChecks.intersection(piece, obstacle))) > RiverPolygon.areaEpsilon
                else { return [piece] }
                return RiverPolygon.subtract(piece, obstacle).filter { abs(RiverPolygon.area($0)) >= minFragmentArea }
            }
        }
        return pieces
    }

    private static func dryGround(_ polygon: [Vertex]) -> [Vertex] {
        let shore: Float = 0.25 / metres // keep crops above the sea wash
        var result: [Vertex] = []
        var previous = polygon.last!
        for current in polygon {
            let a = previous.position.y - shore, b = current.position.y - shore
            if (a >= 0) != (b >= 0) {
                result.append(RiverPolygon.interpolate(previous, current, a / (a - b)))
            }
            if b >= 0 { result.append(current) }
            previous = current
        }
        return result
    }

    /// Preserve each parcel's placement and crop rotation. Chamfer the
    /// corners and turn furrows across the fall line on inclined ground.
    static func build(_ plots: [InstanceData], scene: WorldScene, roads: Mask, streets: Mask)
        -> (vertices: [Vertex], indices: [UInt32]) {
        let grid = (scene.terrain.size - 1) * 2 + 1
        let spacing = scene.terrain.cellSize / 2
        let ground = scene.terrainMesh.vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        // Resolve intersecting proposals in stable generation order so
        // two parcels cannot leave coplanar crop surfaces fighting for depth.
        var cultivated = Mask()
        let outline: [SIMD2<Float>] = [SIMD2(-0.44, -0.50), SIMD2(0.40, -0.50), SIMD2(0.50, -0.40),
            SIMD2(0.50, 0.44), SIMD2(0.44, 0.50), SIMD2(-0.40, 0.50),
            SIMD2(-0.50, 0.40), SIMD2(-0.50, -0.44)]

        func cell(_ x: Float) -> Int { min(max(Int(floor((x + 1) / spacing)), 0), grid - 2) }

        for plot in plots {
            let parcel = RiverPlacement.transformed(outline, by: plot.model).map(projection)
            let water = scene.riverField.nearbyTriangles(parcel).filter {
                RiverPolygon.area($0) < 0 && RiverPolygon.overlaps(parcel, $0)
            }
            let pieces = cut(parcel, around: water + roads.nearby(parcel) + streets.nearby(parcel) + cultivated.nearby(parcel))
            let centre = SIMD2(plot.model.columns.3.x, plot.model.columns.3.z)
            let gradient = scene.terrain.gradientAt(x: centre.x, z: centre.y)
            let axis = SIMD2(plot.model.columns.0.x, plot.model.columns.0.z)
            let across = simd_length(gradient) > 0.08 ? simd_normalize(gradient) : simd_normalize(axis)
            let along = SIMD2(-across.y, across.x)

            for piece in pieces {
                let box = Bounds(piece)
                let first = vertices.count
                for z in cell(box.low.y)...cell(box.high.y) {
                    for x in cell(box.low.x)...cell(box.high.x) {
                        let a = ground[z * grid + x], b = ground[z * grid + x + 1]
                        let c = ground[(z + 1) * grid + x + 1], d = ground[(z + 1) * grid + x]
                        for facet in [[a, c, b], [a, d, c]] {
                            let normal = simd_cross(facet[1].position - facet[0].position,
                                                    facet[2].position - facet[0].position)
                            // Stop at steep escarpments rather than planting
                            // crops on cuts that cannot be worked.
                            guard normal.y > 0, simd_length(SIMD2(normal.x, normal.z)) <= normal.y * 0.72 else { continue }
                            let intersection = RiverGeometryChecks.intersection(facet, piece)
                            guard intersection.count >= 3 else { continue }
                            var patch = dryGround(intersection)
                            let area = RiverPolygon.area(patch)
                            guard abs(area) > RiverPolygon.areaEpsilon else { continue }
                            if area > 0 { patch.reverse() }
                            let base = UInt32(vertices.count)
                            for var vertex in patch {
                                let local = (xz(vertex) - centre) * metres
                                vertex.position.y += cropLift
                                vertex.uv = SIMD2(simd_dot(local, across), simd_dot(local, along))
                                vertex.color = plot.color
                                vertices.append(vertex)
                            }
                            for i in 1..<(patch.count - 1) {
                                let a = xz(patch[i]) - xz(patch[0]), b = xz(patch[i + 1]) - xz(patch[0])
                                if Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x) < -2 * RiverPolygon.areaEpsilon {
                                    indices.append(contentsOf: [base, base + UInt32(i), base + UInt32(i + 1)])
                                }
                            }
                        }
                    }
                }
                if vertices.count > first { cultivated.insert(piece) }
            }
        }
        return (vertices, indices)
    }
}

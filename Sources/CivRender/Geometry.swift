import Foundation
import simd
import Metal

/// Must stay byte-identical to `struct Vertex` in Shaders.metal.
struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    /// rgb = albedo, a = extra per-vertex scalar (water opacity, terrain wetness…).
    var color: SIMD4<Float>
    /// Atlas coordinates for imported assets; procedural meshes leave this zero.
    var uv: SIMD2<Float>

    init(position: SIMD3<Float>, normal: SIMD3<Float>, color: SIMD4<Float>,
         uv: SIMD2<Float> = .zero) {
        self.position = position
        self.normal = normal
        self.color = color
        self.uv = uv
    }

    init(position: SIMD3<Float>, normal: SIMD3<Float>, rgb: SIMD3<Float>,
         uv: SIMD2<Float> = .zero) {
        self.position = position
        self.normal = normal
        self.color = SIMD4(rgb, 1)
        self.uv = uv
    }
}

/// Must stay byte-identical to `struct InstanceData` in Shaders.metal.
struct InstanceData {
    var model: simd_float4x4
    var color: SIMD4<Float>
    /// x = material id (0 default, 1 plaster/timber, 2 stone, 3 roof, 4 glass, 5 field)
    var material: SIMD4<Float> = .zero
}

/// A renderable mesh. Indexed meshes are used for terrain and water; the
/// simpler non-indexed form is used for instanced props.
final class Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer?
    let vertexCount: Int
    let indexCount: Int

    var isIndexed: Bool { indexBuffer != nil }

    init(device: MTLDevice, vertices: [Vertex], indices: [UInt32]? = nil) throws {
        guard !vertices.isEmpty else { throw MetalSetupError.buffer("empty mesh") }

        let vlength = MemoryLayout<Vertex>.stride * vertices.count
        guard let vbuf = device.makeBuffer(length: vlength, options: .storageModeShared) else {
            throw MetalSetupError.buffer("vertices of \(vertices.count)")
        }
        vertices.withUnsafeBytes { raw in
            vbuf.contents().copyMemory(from: raw.baseAddress!, byteCount: vlength)
        }
        vertexBuffer = vbuf
        vertexCount = vertices.count

        if let indices, !indices.isEmpty {
            let ilength = MemoryLayout<UInt32>.stride * indices.count
            guard let ibuf = device.makeBuffer(length: ilength, options: .storageModeShared) else {
                throw MetalSetupError.buffer("indices of \(indices.count)")
            }
            indices.withUnsafeBytes { raw in
                ibuf.contents().copyMemory(from: raw.baseAddress!, byteCount: ilength)
            }
            indexBuffer = ibuf
            indexCount = indices.count
        } else {
            indexBuffer = nil
            indexCount = 0
        }
    }
}

enum Geometry {

    /// Unit cube, flat shaded, centred on the origin.
    static func cube(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        let h: Float = 0.5
        var v: [Vertex] = []

        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                  _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: b, normal: n, rgb: rgb))
            v.append(Vertex(position: c, normal: n, rgb: rgb))
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: c, normal: n, rgb: rgb))
            v.append(Vertex(position: d, normal: n, rgb: rgb))
        }

        face(SIMD3(-h, -h,  h), SIMD3( h, -h,  h), SIMD3( h,  h,  h), SIMD3(-h,  h,  h), SIMD3( 0,  0,  1))
        face(SIMD3( h, -h, -h), SIMD3(-h, -h, -h), SIMD3(-h,  h, -h), SIMD3( h,  h, -h), SIMD3( 0,  0, -1))
        face(SIMD3(-h,  h,  h), SIMD3( h,  h,  h), SIMD3( h,  h, -h), SIMD3(-h,  h, -h), SIMD3( 0,  1,  0))
        face(SIMD3(-h, -h, -h), SIMD3( h, -h, -h), SIMD3( h, -h,  h), SIMD3(-h, -h,  h), SIMD3( 0, -1,  0))
        face(SIMD3(-h, -h, -h), SIMD3(-h, -h,  h), SIMD3(-h,  h,  h), SIMD3(-h,  h, -h), SIMD3(-1,  0,  0))
        face(SIMD3( h, -h,  h), SIMD3( h, -h, -h), SIMD3( h,  h, -h), SIMD3( h,  h,  h), SIMD3( 1,  0,  0))

        return v
    }

    /// A small conifer: a trunk and two stacked canopies. The instance tint
    /// colours the canopy; the trunk reads as a darker olive.
    static func tree(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []

        for vertex in cube() {
            var p = vertex.position
            p.x *= 0.16
            p.z *= 0.16
            p.y = p.y * 0.34 + 0.17
            v.append(Vertex(position: p,
                            normal: vertex.normal,
                            rgb: SIMD3<Float>(0.62, 0.48, 0.32) * rgb))
        }

        for vertex in cone(radius: 0.52, height: 0.62, segments: 7) {
            var p = vertex.position
            p.y += 0.18
            v.append(Vertex(position: p, normal: vertex.normal, rgb: rgb))
        }

        for vertex in cone(radius: 0.36, height: 0.52, segments: 7) {
            var p = vertex.position
            p.x *= 0.92
            p.z *= 0.92
            p.y += 0.55
            v.append(Vertex(position: p, normal: vertex.normal, rgb: rgb * 1.06))
        }

        return v
    }

    /// Applies a matrix to a vertex list (position and normal).
    private static func transformed(_ vertices: [Vertex], _ m: simd_float4x4) -> [Vertex] {
        vertices.map { v in
            let p = m * SIMD4<Float>(v.position, 1)
            let n = m * SIMD4<Float>(v.normal, 0)
            return Vertex(position: SIMD3(p.x, p.y, p.z),
                          normal: simd_normalize(SIMD3(n.x, n.y, n.z)),
                          color: v.color)
        }
    }

    /// Closed cylinder along Y, base at y = 0.
    static func cylinder(radius: Float = 0.5, height: Float = 1, segments: Int = 8,
                         rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []
        let r = radius

        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let c0 = cos(a0), s0 = sin(a0)
            let c1 = cos(a1), s1 = sin(a1)
            let b0 = SIMD3(c0 * r, 0, s0 * r)
            let b1 = SIMD3(c1 * r, 0, s1 * r)
            let t0 = SIMD3(c0 * r, height, s0 * r)
            let t1 = SIMD3(c1 * r, height, s1 * r)

            func tri(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ out: SIMD3<Float>) {
                var q1 = p1, q2 = p2
                var n = simd_cross(q1 - p0, q2 - p0)
                if simd_length_squared(n) < 1e-12 { return }
                n = simd_normalize(n)
                if simd_dot(n, out) < 0 { swap(&q1, &q2); n = -n }
                v.append(Vertex(position: p0, normal: n, rgb: rgb))
                v.append(Vertex(position: q1, normal: n, rgb: rgb))
                v.append(Vertex(position: q2, normal: n, rgb: rgb))
            }

            let mid = (a0 + a1) * 0.5
            let outward = SIMD3(cos(mid), 0, sin(mid))
            tri(b0, b1, t1, outward)
            tri(b0, t1, t0, outward)
            tri(SIMD3(0, height, 0), t0, t1, SIMD3(0, 1, 0))
            tri(SIMD3(0, 0, 0), b1, b0, SIMD3(0, -1, 0))
        }
        return v
    }

    /// A farm cart with two spoked wheels, a plank bed and shafts.
    static func cart() -> [Vertex] {
        var v: [Vertex] = []
        let wood = SIMD3<Float>(0.44, 0.31, 0.19)
        let darkWood = SIMD3<Float>(0.30, 0.21, 0.13)

        box(SIMD3(0.62, 0.09, 0.95), at: SIMD3(0, 0.46, 0), rgb: wood, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.05, 0.22, 0.95), at: SIMD3(side * 0.31, 0.58, 0),
                rgb: wood * 0.92, into: &v)
        }
        box(SIMD3(0.62, 0.22, 0.05), at: SIMD3(0, 0.58, -0.46), rgb: wood * 0.9, into: &v)
        box(SIMD3(0.62, 0.16, 0.05), at: SIMD3(0, 0.55, 0.46), rgb: wood * 0.9, into: &v)

        // Wheels, axes along X.
        for wheelZ in [-0.28, 0.28] as [Float] {
            for side in [Float(-1), Float(1)] {
                let wheel = cylinder(radius: 0.20, height: 0.055, segments: 9,
                                     rgb: SIMD3(0.24, 0.17, 0.10))
                let m = translation(SIMD3(side * 0.36, 0.20, wheelZ))
                    * rotationZ(.pi / 2)
                v.append(contentsOf: transformed(wheel, m))
            }
        }

        // Shafts reaching forward to the ox.
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.045, 0.045, 0.55), at: SIMD3(side * 0.17, 0.47, 0.75),
                rgb: darkWood, into: &v)
        }

        // The ox.
        let hide = SIMD3<Float>(0.48, 0.34, 0.22)
        box(SIMD3(0.34, 0.30, 0.58), at: SIMD3(0, 0.55, 1.10), rgb: hide, into: &v)
        box(SIMD3(0.18, 0.18, 0.22), at: SIMD3(0, 0.44, 1.44), rgb: hide * 1.04, into: &v)
        box(SIMD3(0.12, 0.09, 0.10), at: SIMD3(0, 0.38, 1.56), rgb: hide * 0.82, into: &v)
        for side in [Float(-1), Float(1)] {
            for vertex in cone(radius: 0.022, height: 0.13, segments: 5,
                               rgb: SIMD3(0.78, 0.74, 0.64)) {
                var p = vertex.position
                p.x += side * 0.10
                p.y += 0.52
                p.z += 1.40
                v.append(Vertex(position: p, normal: vertex.normal,
                                rgb: SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)))
            }
        }
        for (sx, sz) in [(Float(-1), Float(-1)), (Float(1), Float(-1)),
                         (Float(-1), Float(1)), (Float(1), Float(1))] {
            box(SIMD3(0.07, 0.42, 0.08), at: SIMD3(sx * 0.12, 0.21, 1.10 + sz * 0.20),
                rgb: hide * 0.66, into: &v)
        }
        box(SIMD3(0.04, 0.26, 0.05), at: SIMD3(0, 0.42, 0.80), rgb: hide * 0.7, into: &v)

        return v
    }

    /// A small car: lower body, cabin, four wheels.
    static func car() -> [Vertex] {
        var v: [Vertex] = []
        let body = SIMD3<Float>(0.92, 0.92, 0.92)
        let glass = SIMD3<Float>(0.16, 0.20, 0.24)

        box(SIMD3(0.56, 0.15, 1.00), at: SIMD3(0, 0.22, 0), rgb: body, into: &v)
        box(SIMD3(0.48, 0.16, 0.48), at: SIMD3(0, 0.36, -0.06), rgb: body * 0.96, into: &v)
        box(SIMD3(0.50, 0.10, 0.02), at: SIMD3(0, 0.36, 0.17), rgb: glass, into: &v)
        box(SIMD3(0.50, 0.10, 0.02), at: SIMD3(0, 0.36, -0.29), rgb: glass, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.02, 0.10, 0.40), at: SIMD3(side * 0.24, 0.36, -0.06),
                rgb: glass, into: &v)
        }

        for wheelZ in [-0.30, 0.30] as [Float] {
            for side in [Float(-1), Float(1)] {
                let wheel = cylinder(radius: 0.12, height: 0.06, segments: 9,
                                     rgb: SIMD3(0.10, 0.10, 0.11))
                let m = translation(SIMD3(side * 0.30, 0.12, wheelZ))
                    * rotationZ(.pi / 2)
                v.append(contentsOf: transformed(wheel, m))
            }
        }

        // Headlight lenses.
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.10, 0.05, 0.03), at: SIMD3(side * 0.17, 0.24, 0.50),
                rgb: SIMD3(1.0, 0.92, 0.74), into: &v)
        }
        return v
    }

    /// A pointed boat hull with a mast, authored along Z.
    static func boatHull() -> [Vertex] {
        var v: [Vertex] = []
        let plank = SIMD3<Float>(0.34, 0.26, 0.18)

        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                  _ d: SIMD3<Float>, _ out: SIMD3<Float>, _ rgb: SIMD3<Float>) {
            func tri(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>) {
                var q1 = p1, q2 = p2
                var n = simd_cross(q1 - p0, q2 - p0)
                if simd_length_squared(n) < 1e-12 { return }
                n = simd_normalize(n)
                if simd_dot(n, out) < 0 { swap(&q1, &q2); n = -n }
                v.append(Vertex(position: p0, normal: n, rgb: rgb))
                v.append(Vertex(position: q1, normal: n, rgb: rgb))
                v.append(Vertex(position: q2, normal: n, rgb: rgb))
            }
            tri(a, b, c)
            tri(a, c, d)
        }

        func triFace(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                     _ out: SIMD3<Float>, _ rgb: SIMD3<Float>) {
            var q1 = b, q2 = c
            var n = simd_cross(q1 - a, q2 - a)
            if simd_length_squared(n) < 1e-12 { return }
            n = simd_normalize(n)
            if simd_dot(n, out) < 0 { swap(&q1, &q2); n = -n }
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: q1, normal: n, rgb: rgb))
            v.append(Vertex(position: q2, normal: n, rgb: rgb))
        }

        let b0 = SIMD3<Float>(-0.16, 0, -0.50)
        let b1 = SIMD3<Float>( 0.16, 0, -0.50)
        let b2 = SIMD3<Float>( 0.16, 0,  0.30)
        let b3 = SIMD3<Float>(-0.16, 0,  0.30)
        let bow = SIMD3<Float>(0, 0, 0.62)

        let t0 = SIMD3<Float>(-0.30, 0.26, -0.50)
        let t1 = SIMD3<Float>( 0.30, 0.26, -0.50)
        let t2 = SIMD3<Float>( 0.30, 0.26,  0.24)
        let t3 = SIMD3<Float>(-0.30, 0.26,  0.24)
        let bowTop = SIMD3<Float>(0, 0.30, 0.72)

        face(b0, b1, b2, b3, SIMD3(0, -1, 0), plank * 0.8)
        // Bow triangle of the bottom.
        var n = SIMD3<Float>(0, -1, 0)
        v.append(Vertex(position: b3, normal: n, rgb: plank * 0.8))
        v.append(Vertex(position: b2, normal: n, rgb: plank * 0.8))
        v.append(Vertex(position: bow, normal: n, rgb: plank * 0.8))

        // Sides.
        face(t0, b0, b3, t3, SIMD3(-1, 0.2, 0), plank)
        triFace(t0, t3, bowTop, SIMD3(-0.7, 0.3, 0.6), plank)
        triFace(b3, bow, bowTop, SIMD3(-0.7, 0.3, 0.6), plank)

        face(b1, t1, t2, b2, SIMD3(1, 0.2, 0), plank)
        triFace(t1, bowTop, t2, SIMD3(0.7, 0.3, 0.6), plank)
        triFace(b2, t2, bowTop, SIMD3(0.7, 0.3, 0.6), plank)
        triFace(b2, bowTop, bow, SIMD3(0.7, 0.3, 0.6), plank)

        // Stern transom.
        face(b0, t0, t1, b1, SIMD3(0, 0, -1), plank * 0.9)

        // Gunwales and a dark interior floor.
        box(SIMD3(0.06, 0.05, 0.75), at: SIMD3(-0.29, 0.27, -0.13), rgb: plank * 1.06, into: &v)
        box(SIMD3(0.06, 0.05, 0.75), at: SIMD3( 0.29, 0.27, -0.13), rgb: plank * 1.06, into: &v)
        box(SIMD3(0.50, 0.04, 0.70), at: SIMD3(0, 0.12, -0.05), rgb: plank * 0.55, into: &v)

        // Mast.
        box(SIMD3(0.035, 0.95, 0.035), at: SIMD3(0, 0.72, 0.06),
            rgb: SIMD3(0.32, 0.24, 0.15), into: &v)
        return v
    }

    /// A single triangular sail, double-sided.
    static func boatSail() -> [Vertex] {
        let cloth = SIMD3<Float>(0.90, 0.88, 0.82)
        let a = SIMD3<Float>(0, 0.42, 0.06)
        let b = SIMD3<Float>(0, 1.16, 0.06)
        let c = SIMD3<Float>(0, 0.50, 0.56)
        var v: [Vertex] = []
        let n = SIMD3<Float>(1, 0.1, 0)
        for (p0, p1, p2) in [(a, b, c), (a, c, b)] {
            v.append(Vertex(position: p0, normal: n, rgb: cloth))
            v.append(Vertex(position: p1, normal: n, rgb: cloth))
            v.append(Vertex(position: p2, normal: n, rgb: cloth))
        }
        return v
    }

    /// A rounded broadleaf tree: a short trunk under a clustered canopy.
    static func treeBroadleaf(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []

        box(SIMD3(0.16, 0.52, 0.16), at: SIMD3(0, 0.26, 0),
            rgb: SIMD3(0.60, 0.46, 0.30) * rgb, into: &v)

        let blobs: [(Float, Float, Float, Float, Float)] = [
            (0.00, 0.70, 0.00, 0.36, 0.92),
            (0.16, 0.80, 0.06, 0.26, 1.02),
            (-0.15, 0.77, -0.09, 0.24, 0.96),
            (0.02, 0.88, -0.02, 0.22, 1.08)
        ]
        for (ox, oy, oz, r, tint) in blobs {
            for vertex in sphere(radius: r, rings: 5, segments: 8, rgb: rgb * tint) {
                var p = vertex.position
                p.x += ox
                p.y += oy
                p.z += oz
                v.append(Vertex(position: p, normal: vertex.normal,
                                rgb: SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)))
            }
        }

        return v
    }

    /// Adds an axis-aligned box, scaled and centred, into a vertex list.
    private static func box(_ size: SIMD3<Float>, at centre: SIMD3<Float>,
                            rgb: SIMD3<Float>, into v: inout [Vertex]) {
        for vertex in cube() {
            let p = SIMD3(vertex.position.x * size.x + centre.x,
                          vertex.position.y * size.y + centre.y,
                          vertex.position.z * size.z + centre.z)
            v.append(Vertex(position: p, normal: vertex.normal, rgb: rgb))
        }
    }

    /// A person's torso and belt. Legs, arms and head are separate meshes so
    /// they can swing independently; the tunic carries the instance colour.
    static func personBody() -> [Vertex] {
        var v: [Vertex] = []
        box(SIMD3(0.30, 0.18, 0.22), at: SIMD3(0, 0.48, 0), rgb: SIMD3(repeating: 1), into: &v)
        box(SIMD3(0.34, 0.30, 0.22), at: SIMD3(0, 0.68, 0), rgb: SIMD3(repeating: 1), into: &v)
        box(SIMD3(0.38, 0.09, 0.23), at: SIMD3(0, 0.84, 0), rgb: SIMD3(repeating: 1), into: &v)
        box(SIMD3(0.315, 0.035, 0.23), at: SIMD3(0, 0.535, 0),
            rgb: SIMD3(repeating: 0.45), into: &v)
        return v
    }

    /// Head, hair and cap. Fixed colours, so faces never take the coat tint.
    static func personHead() -> [Vertex] {
        var v: [Vertex] = []
        let skin = SIMD3<Float>(0.92, 0.74, 0.58)
        let hair = SIMD3<Float>(0.22, 0.16, 0.11)
        let cap = SIMD3<Float>(0.30, 0.26, 0.20)

        box(SIMD3(0.10, 0.08, 0.10), at: SIMD3(0, 0.89, 0), rgb: skin, into: &v)

        for vertex in sphere(radius: 0.105, rings: 5, segments: 7, rgb: skin) {
            var p = vertex.position
            p.y += 0.97
            v.append(Vertex(position: p, normal: vertex.normal,
                            rgb: SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)))
        }

        // Nose, ears and a hair fringe give the head a facing direction.
        box(SIMD3(0.034, 0.042, 0.050), at: SIMD3(0, 0.962, 0.110), rgb: skin, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.026, 0.050, 0.030), at: SIMD3(side * 0.106, 0.968, 0.005),
                rgb: skin * 0.95, into: &v)
        }
        box(SIMD3(0.170, 0.040, 0.040), at: SIMD3(0, 1.018, 0.088), rgb: hair, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.022, 0.016, 0.012), at: SIMD3(side * 0.040, 0.985, 0.096),
                rgb: SIMD3(0.10, 0.09, 0.08), into: &v)
        }

        // Hair at the back, a cap brim and crown.
        box(SIMD3(0.185, 0.075, 0.185), at: SIMD3(0, 1.045, -0.012), rgb: hair, into: &v)
        box(SIMD3(0.30, 0.018, 0.30), at: SIMD3(0, 1.06, 0), rgb: cap, into: &v)
        box(SIMD3(0.17, 0.065, 0.17), at: SIMD3(0, 1.10, 0), rgb: cap, into: &v)
        return v
    }

    /// Alternate head with a wide straw brim, for market/field workers.
    static func personHeadBrim() -> [Vertex] {
        var v: [Vertex] = []
        let skin = SIMD3<Float>(0.92, 0.74, 0.58)
        let hair = SIMD3<Float>(0.22, 0.16, 0.11)
        let straw = SIMD3<Float>(0.66, 0.55, 0.34)

        box(SIMD3(0.10, 0.08, 0.10), at: SIMD3(0, 0.89, 0), rgb: skin, into: &v)
        for vertex in sphere(radius: 0.105, rings: 5, segments: 7, rgb: skin) {
            var p = vertex.position
            p.y += 0.97
            v.append(Vertex(position: p, normal: vertex.normal,
                            rgb: SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)))
        }
        box(SIMD3(0.185, 0.075, 0.185), at: SIMD3(0, 1.045, -0.012), rgb: hair, into: &v)
        box(SIMD3(0.34, 0.020, 0.34), at: SIMD3(0, 1.065, 0), rgb: straw, into: &v)
        box(SIMD3(0.16, 0.075, 0.16), at: SIMD3(0, 1.105, 0), rgb: straw * 0.92, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.022, 0.016, 0.012), at: SIMD3(side * 0.040, 0.985, 0.096),
                rgb: SIMD3(0.10, 0.09, 0.08), into: &v)
        }
        return v
    }

    /// One leg, authored with the hip pivot at the origin and the foot at
    /// y = -0.49.
    static func personLeg() -> [Vertex] {
        var v: [Vertex] = []
        box(SIMD3(0.105, 0.26, 0.115), at: SIMD3(0, -0.13, 0),
            rgb: SIMD3(repeating: 0.82), into: &v)
        box(SIMD3(0.095, 0.20, 0.105), at: SIMD3(0, -0.35, 0),
            rgb: SIMD3(repeating: 0.72), into: &v)
        box(SIMD3(0.105, 0.055, 0.17), at: SIMD3(0, -0.465, 0.03),
            rgb: SIMD3(0.38, 0.31, 0.24), into: &v)
        return v
    }

    /// One arm, authored with the shoulder pivot at the origin.
    static func personArm() -> [Vertex] {
        var v: [Vertex] = []
        box(SIMD3(0.085, 0.22, 0.10), at: SIMD3(0, -0.11, 0),
            rgb: SIMD3(repeating: 0.95), into: &v)
        box(SIMD3(0.075, 0.17, 0.09), at: SIMD3(0, -0.30, 0),
            rgb: SIMD3(repeating: 0.90), into: &v)
        box(SIMD3(0.075, 0.07, 0.085), at: SIMD3(0, -0.41, 0),
            rgb: SIMD3(0.88, 0.72, 0.57), into: &v)
        return v
    }

    /// A small cow-like quadruped: barrel body, lowered head, horns, ears,
    /// hanging tail and four legs. Authored with hooves at y = 0.
    static func animal(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []

        // Barrel and haunches.
        box(SIMD3(0.36, 0.30, 0.66), at: SIMD3(0, 0.47, 0.02),
            rgb: rgb, into: &v)
        box(SIMD3(0.32, 0.26, 0.24), at: SIMD3(0, 0.46, -0.26),
            rgb: rgb * 0.94, into: &v)

        // Neck and lowered head.
        box(SIMD3(0.15, 0.22, 0.16), at: SIMD3(0, 0.44, 0.33),
            rgb: rgb * 0.96, into: &v)
        box(SIMD3(0.18, 0.17, 0.24), at: SIMD3(0, 0.34, 0.44),
            rgb: rgb * 1.02, into: &v)
        box(SIMD3(0.12, 0.10, 0.12), at: SIMD3(0, 0.295, 0.57),
            rgb: rgb * 0.80, into: &v)

        // Horns and ears.
        for side in [Float(-1), Float(1)] {
            for vertex in cone(radius: 0.022, height: 0.14, segments: 5,
                               rgb: rgb * 0.80) {
                var p = vertex.position
                p.x += side * 0.10
                p.y += 0.42
                p.z += 0.35
                v.append(Vertex(position: p, normal: vertex.normal,
                                rgb: SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)))
            }
            box(SIMD3(0.06, 0.05, 0.09), at: SIMD3(side * 0.12, 0.385, 0.36),
                rgb: rgb * 0.72, into: &v)
        }

        // Tail.
        box(SIMD3(0.045, 0.30, 0.05), at: SIMD3(0, 0.33, -0.38),
            rgb: rgb * 0.70, into: &v)
        box(SIMD3(0.07, 0.09, 0.07), at: SIMD3(0, 0.17, -0.38),
            rgb: rgb * 0.55, into: &v)

        // Legs.
        for (sx, sz) in [(Float(-1), Float(-1)), (Float(1), Float(-1)),
                         (Float(-1), Float(1)), (Float(1), Float(1))] {
            box(SIMD3(0.075, 0.34, 0.085), at: SIMD3(sx * 0.12, 0.17, sz * 0.23),
                rgb: rgb * 0.62, into: &v)
        }

        return v
    }

    /// A pitched gable roof: two slopes, two gable ends and an underside.
    /// Unit footprint, base at y = 0, ridge at y = 1 along Z.
    static func gable(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []

        let a = SIMD3<Float>(-0.5, 0, -0.5)
        let b = SIMD3<Float>( 0.5, 0, -0.5)
        let c = SIMD3<Float>( 0.5, 0,  0.5)
        let d = SIMD3<Float>(-0.5, 0,  0.5)
        let r0 = SIMD3<Float>(0, 1, -0.5)
        let r1 = SIMD3<Float>(0, 1,  0.5)

        func tri(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>,
                 _ outward: SIMD3<Float>) {
            var q1 = p1, q2 = p2
            var n = simd_cross(q1 - p0, q2 - p0)
            if simd_length_squared(n) < 1e-12 { return }
            n = simd_normalize(n)
            if simd_dot(n, outward) < 0 { swap(&q1, &q2); n = -n }
            v.append(Vertex(position: p0, normal: n, rgb: rgb))
            v.append(Vertex(position: q1, normal: n, rgb: rgb))
            v.append(Vertex(position: q2, normal: n, rgb: rgb))
        }

        // Left and right slopes.
        tri(a, d, r1, SIMD3(-1, 0.6, 0))
        tri(a, r1, r0, SIMD3(-1, 0.6, 0))
        tri(b, r0, r1, SIMD3(1, 0.6, 0))
        tri(b, r1, c, SIMD3(1, 0.6, 0))

        // Gable ends.
        tri(a, r0, b, SIMD3(0, 0.4, -1))
        tri(d, c, r1, SIMD3(0, 0.4, 1))

        // Underside.
        tri(a, b, c, SIMD3(0, -1, 0))
        tri(a, c, d, SIMD3(0, -1, 0))

        return v
    }

    /// Transforms a vertex list into another, preserving its colours.
    private static func merge(_ source: [Vertex],
                              scale: SIMD3<Float>,
                              at offset: SIMD3<Float>,
                              rgb: SIMD3<Float>? = nil,
                              into v: inout [Vertex]) {
        for vertex in source {
            let p = SIMD3(vertex.position.x * scale.x + offset.x,
                          vertex.position.y * scale.y + offset.y,
                          vertex.position.z * scale.z + offset.z)
            let n = simd_normalize(SIMD3(vertex.normal.x / max(abs(scale.x), 1e-5),
                                         vertex.normal.y / max(abs(scale.y), 1e-5),
                                         vertex.normal.z / max(abs(scale.z), 1e-5)))
            let colour = rgb ?? SIMD3(vertex.color.x, vertex.color.y, vertex.color.z)
            v.append(Vertex(position: p, normal: n, rgb: colour))
        }
    }

    /// A stepped Mesopotamian temple: battered mud-brick tiers, a tripartite
    /// shrine on top and a grand staircase, after the ziggurats of Ur and Uruk.
    static func temple() -> [Vertex] {
        var v: [Vertex] = []
        let brick = SIMD3<Float>(0.68, 0.47, 0.31)
        let recess = SIMD3<Float>(0.50, 0.35, 0.23)
        let lapis = SIMD3<Float>(0.18, 0.30, 0.56)
        let gold = SIMD3<Float>(0.86, 0.70, 0.34)

        // Buried plinth keeps the temple grounded even on a slope.
        box(SIMD3(1.06, 0.14, 1.06), at: SIMD3(0, -0.02, 0), rgb: recess, into: &v)

        // Battered tiers, each inset from the one below.
        let tiers: [(Float, Float)] = [(0.98, 0.13), (0.82, 0.13),
                                       (0.66, 0.13), (0.50, 0.13), (0.36, 0.12)]
        var y: Float = 0.06
        for (width, height) in tiers {
            box(SIMD3(width, height, width), at: SIMD3(0, y, 0), rgb: brick, into: &v)
            // Corner pilasters give the mass a panelled, brick-built read.
            for sx in [Float(-1), Float(1)] {
                for sz in [Float(-1), Float(1)] {
                    box(SIMD3(width * 0.06, height * 0.92, width * 0.06),
                        at: SIMD3(sx * width * 0.48, y, sz * width * 0.48),
                        rgb: recess, into: &v)
                }
            }
            y += height
        }

        // Glazed band and top platform.
        box(SIMD3(0.38, 0.018, 0.38), at: SIMD3(0, y + 0.009, 0),
            rgb: lapis, into: &v)
        box(SIMD3(0.30, 0.035, 0.30), at: SIMD3(0, y + 0.036, 0),
            rgb: recess, into: &v)

        // Tripartite shrine: central hall flanked by storerooms.
        let shrineY = y + 0.13
        box(SIMD3(0.20, 0.16, 0.17), at: SIMD3(0, shrineY, 0), rgb: brick, into: &v)
        box(SIMD3(0.23, 0.022, 0.20), at: SIMD3(0, shrineY + 0.09, 0),
            rgb: recess, into: &v)
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.05, 0.12, 0.15), at: SIMD3(side * 0.12, shrineY - 0.01, 0),
                rgb: recess, into: &v)
        }
        box(SIMD3(0.07, 0.09, 0.012), at: SIMD3(0, shrineY - 0.03, 0.087),
            rgb: SIMD3(0.22, 0.17, 0.12), into: &v)
        box(SIMD3(0.09, 0.012, 0.02), at: SIMD3(0, shrineY + 0.03, 0.090),
            rgb: gold, into: &v)

        // Grand staircase on the front face, plus two smaller side flights.
        for step in 0..<6 {
            let sy = 0.015 + Float(step) * 0.085
            let sz = 0.54 - Float(step) * 0.055
            box(SIMD3(0.17, 0.085, 0.07), at: SIMD3(0, sy, sz), rgb: brick, into: &v)
        }
        for side in [Float(-1), Float(1)] {
            for step in 0..<4 {
                let sy = 0.015 + Float(step) * 0.075
                let sx = side * (0.52 - Float(step) * 0.045)
                box(SIMD3(0.06, 0.075, 0.12), at: SIMD3(sx, sy, 0.30), rgb: recess, into: &v)
            }
        }
        return v
    }

    /// Stained glass for the cathedral: aisle windows and a rose window.
    static func cathedralGlass() -> [Vertex] {
        var v: [Vertex] = []
        let glass: [SIMD3<Float>] = [SIMD3(0.18, 0.40, 0.88),
                                     SIMD3(0.86, 0.20, 0.26),
                                     SIMD3(0.96, 0.74, 0.24),
                                     SIMD3(0.20, 0.62, 0.38)]
        for side in [Float(-1), Float(1)] {
            for k in 0..<3 {
                let z = -0.10 + Float(k) * 0.18
                box(SIMD3(0.018, 0.14, 0.07),
                    at: SIMD3(side * 0.145, 0.20, z),
                    rgb: glass[(k + (side > 0 ? 1 : 0)) % glass.count], into: &v)
            }
        }
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * Float.pi
            box(SIMD3(0.040, 0.040, 0.014),
                at: SIMD3(cos(a) * 0.045, 0.24 + sin(a) * 0.045, -0.348),
                rgb: glass[k % glass.count], into: &v)
        }
        box(SIMD3(0.028, 0.028, 0.014), at: SIMD3(0, 0.24, -0.348),
            rgb: SIMD3(0.88, 0.72, 0.32), into: &v)
        return v
    }

    /// A cathedral: long nave with aisles and buttresses, twin west towers
    /// and spires, a rose window and a deep west door.
    static func cathedral() -> [Vertex] {
        var v: [Vertex] = []
        let stone = SIMD3<Float>(0.72, 0.69, 0.63)
        let darkStone = SIMD3<Float>(0.56, 0.54, 0.49)
        let roof = SIMD3<Float>(0.34, 0.29, 0.27)

        // Nave runs along z so the gable ridge matches.
        box(SIMD3(0.28, 0.30, 0.80), at: SIMD3(0, 0.15, 0.06), rgb: stone, into: &v)
        merge(gable(rgb: roof), scale: SIMD3(0.32, 0.34, 0.84),
              at: SIMD3(0, 0.30, 0.06), into: &v)

        // Aisles and buttresses.
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.09, 0.18, 0.66), at: SIMD3(side * 0.17, 0.09, 0.08),
                rgb: darkStone, into: &v)
            for k in 0..<4 {
                let z = -0.18 + Float(k) * 0.18
                box(SIMD3(0.05, 0.26, 0.05), at: SIMD3(side * 0.225, 0.13, z),
                    rgb: darkStone, into: &v)
            }
        }

        // Twin west towers and spires.
        for side in [Float(-1), Float(1)] {
            box(SIMD3(0.18, 0.58, 0.16), at: SIMD3(side * 0.11, 0.29, -0.38),
                rgb: stone, into: &v)
            box(SIMD3(0.21, 0.03, 0.19), at: SIMD3(side * 0.11, 0.59, -0.38),
                rgb: darkStone, into: &v)
            merge(cone(radius: 0.11, height: 0.34, segments: 4, rgb: roof),
                  scale: SIMD3(1, 1, 1), at: SIMD3(side * 0.11, 0.77, -0.38),
                  into: &v)
        }

        // Rose window, west door and a cross on the gable.
        box(SIMD3(0.08, 0.15, 0.02), at: SIMD3(0, 0.075, -0.345),
            rgb: SIMD3(0.24, 0.18, 0.13), into: &v)
        box(SIMD3(0.02, 0.10, 0.02), at: SIMD3(0, 0.68, 0.06), rgb: darkStone, into: &v)
        box(SIMD3(0.07, 0.02, 0.02), at: SIMD3(0, 0.70, 0.06), rgb: darkStone, into: &v)
        return v
    }

    /// A Renaissance domed civic building: square base, drum, dome, lantern
    /// and a columned portico.
    static func dome() -> [Vertex] {
        var v: [Vertex] = []
        let stone = SIMD3<Float>(0.78, 0.73, 0.64)
        let darkStone = SIMD3<Float>(0.62, 0.58, 0.52)
        let roof = SIMD3<Float>(0.46, 0.38, 0.30)
        let gold = SIMD3<Float>(0.88, 0.72, 0.34)

        box(SIMD3(0.44, 0.26, 0.44), at: SIMD3(0, 0.13, 0), rgb: stone, into: &v)
        box(SIMD3(0.46, 0.03, 0.46), at: SIMD3(0, 0.265, 0), rgb: darkStone, into: &v)
        box(SIMD3(0.32, 0.10, 0.32), at: SIMD3(0, 0.32, 0), rgb: stone, into: &v)
        merge(sphere(radius: 0.26, rings: 6, segments: 12, rgb: roof),
              scale: SIMD3(1, 0.62, 1), at: SIMD3(0, 0.38, 0), into: &v)
        box(SIMD3(0.08, 0.10, 0.08), at: SIMD3(0, 0.54, 0), rgb: stone, into: &v)
        box(SIMD3(0.02, 0.10, 0.02), at: SIMD3(0, 0.64, 0), rgb: gold, into: &v)

        // Portico on the front face.
        box(SIMD3(0.32, 0.04, 0.12), at: SIMD3(0, 0.21, 0.27), rgb: darkStone, into: &v)
        for x in [Float(-0.12), -0.04, 0.04, 0.12] {
            box(SIMD3(0.035, 0.20, 0.035), at: SIMD3(x, 0.10, 0.27),
                rgb: stone, into: &v)
        }
        box(SIMD3(0.36, 0.02, 0.16), at: SIMD3(0, 0.01, 0.29), rgb: darkStone, into: &v)
        return v
    }

    /// A parish church with nave, pitched roof, tower and spire.
    static func church() -> [Vertex] {
        var v: [Vertex] = []
        let stone = SIMD3<Float>(0.74, 0.71, 0.64)
        let darkStone = SIMD3<Float>(0.60, 0.58, 0.53)
        let roof = SIMD3<Float>(0.38, 0.30, 0.27)

        box(SIMD3(0.74, 0.30, 0.30), at: SIMD3(0.06, 0.15, 0), rgb: stone, into: &v)
        merge(gable(rgb: roof), scale: SIMD3(0.78, 0.30, 0.34),
              at: SIMD3(0.06, 0.30, 0), into: &v)

        // West tower and spire.
        box(SIMD3(0.20, 0.54, 0.22), at: SIMD3(-0.34, 0.27, 0), rgb: stone, into: &v)
        box(SIMD3(0.23, 0.03, 0.25), at: SIMD3(-0.34, 0.55, 0), rgb: darkStone, into: &v)
        merge(cone(radius: 0.15, height: 0.34, segments: 4, rgb: roof),
              scale: SIMD3(1, 1, 1), at: SIMD3(-0.34, 0.73, 0), into: &v)

        // Door, windows and buttresses.
        box(SIMD3(0.08, 0.14, 0.02), at: SIMD3(-0.34, 0.07, 0.12),
            rgb: SIMD3(0.26, 0.19, 0.13), into: &v)
        for x in [Float(-0.10), 0.16, 0.40] {
            box(SIMD3(0.05, 0.10, 0.02), at: SIMD3(x, 0.20, 0.16),
                rgb: SIMD3(0.14, 0.16, 0.20), into: &v)
        }
        for x in [Float(-0.12), 0.28] {
            box(SIMD3(0.04, 0.24, 0.05), at: SIMD3(x, 0.14, 0.17), rgb: darkStone, into: &v)
        }
        return v
    }

    /// A timber quay: deck, posts and a small warehouse, one unit long.
    static func dock() -> [Vertex] {
        var v: [Vertex] = []
        let wood = SIMD3<Float>(0.46, 0.35, 0.22)
        let dark = SIMD3<Float>(0.32, 0.25, 0.16)
        let stone = SIMD3<Float>(0.62, 0.60, 0.54)

        box(SIMD3(1.00, 0.05, 0.30), at: SIMD3(0, 0.03, 0), rgb: wood, into: &v)
        for x in [Float(-0.42), -0.14, 0.14, 0.42] {
            for z in [Float(-0.11), 0.11] {
                box(SIMD3(0.05, 0.30, 0.05), at: SIMD3(x, -0.10, z), rgb: dark, into: &v)
            }
        }
        box(SIMD3(0.26, 0.18, 0.22), at: SIMD3(0.42, 0.15, 0), rgb: stone, into: &v)
        box(SIMD3(0.30, 0.04, 0.26), at: SIMD3(0.42, 0.26, 0), rgb: dark, into: &v)
        return v
    }

    /// A flat sign plate in the local XY plane, facing +Z, with atlas UVs.
    static func signPlate() -> [Vertex] {
        let n = SIMD3<Float>(0, 0, 1)
        let c = SIMD3<Float>(1, 1, 1)
        return [
            Vertex(position: SIMD3(-0.5, -0.5, 0), normal: n, rgb: c, uv: SIMD2(0, 1)),
            Vertex(position: SIMD3( 0.5, -0.5, 0), normal: n, rgb: c, uv: SIMD2(1, 1)),
            Vertex(position: SIMD3( 0.5,  0.5, 0), normal: n, rgb: c, uv: SIMD2(1, 0)),
            Vertex(position: SIMD3(-0.5,  0.5, 0), normal: n, rgb: c, uv: SIMD2(0, 0)),
            Vertex(position: SIMD3(-0.5, -0.5, 0), normal: n, rgb: c, uv: SIMD2(0, 1)),
            Vertex(position: SIMD3( 0.5,  0.5, 0), normal: n, rgb: c, uv: SIMD2(1, 0))
        ]
    }

    /// A small heraldic shield for town signs, in the local XY plane.
    static func crest() -> [Vertex] {
        let n = SIMD3<Float>(0, 0, 1)
        let c = SIMD3<Float>(1, 1, 1)
        let tl = SIMD3<Float>(-0.5, 0.5, 0)
        let tr = SIMD3<Float>( 0.5, 0.5, 0)
        let bl = SIMD3<Float>(-0.5, -0.18, 0)
        let br = SIMD3<Float>( 0.5, -0.18, 0)
        let tip = SIMD3<Float>(0, -0.62, 0)
        return [
            Vertex(position: tl, normal: n, rgb: c, uv: SIMD2(0, 0)),
            Vertex(position: tr, normal: n, rgb: c, uv: SIMD2(1, 0)),
            Vertex(position: br, normal: n, rgb: c, uv: SIMD2(1, 0)),
            Vertex(position: tl, normal: n, rgb: c, uv: SIMD2(0, 0)),
            Vertex(position: br, normal: n, rgb: c, uv: SIMD2(1, 0)),
            Vertex(position: bl, normal: n, rgb: c, uv: SIMD2(0, 0)),
            Vertex(position: bl, normal: n, rgb: c, uv: SIMD2(0, 0)),
            Vertex(position: br, normal: n, rgb: c, uv: SIMD2(1, 0)),
            Vertex(position: tip, normal: n, rgb: c, uv: SIMD2(0.5, 1))
        ]
    }

    /// A smooth semicircular arch band, one unit wide and one unit radius.
    /// The instance scale sets the span, rise and width.
    static func arch(segments: Int = 14, thickness: Float = 0.16,
                     rgb: SIMD3<Float> = SIMD3(0.68, 0.65, 0.58)) -> [Vertex] {
        var v: [Vertex] = []
        let n = max(segments, 4)
        let inner = 1 - thickness

        func point(_ x: Float, _ r: Float, _ a: Float) -> SIMD3<Float> {
            SIMD3(x, r * sin(a), -r * cos(a))
        }
        func radial(_ a: Float, _ sign: Float) -> SIMD3<Float> {
            SIMD3(0, sign * sin(a), -sign * cos(a))
        }
        func tri(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>,
                 _ n0: SIMD3<Float>, _ n1: SIMD3<Float>, _ n2: SIMD3<Float>) {
            v.append(Vertex(position: p0, normal: n0, rgb: rgb))
            v.append(Vertex(position: p1, normal: n1, rgb: rgb))
            v.append(Vertex(position: p2, normal: n2, rgb: rgb))
        }

        for i in 0..<n {
            let a0 = Float(i) / Float(n) * Float.pi
            let a1 = Float(i + 1) / Float(n) * Float.pi
            let o0L = point(-0.5, 1, a0), o0R = point(0.5, 1, a0)
            let o1L = point(-0.5, 1, a1), o1R = point(0.5, 1, a1)
            let i0L = point(-0.5, inner, a0), i0R = point(0.5, inner, a0)
            let i1L = point(-0.5, inner, a1), i1R = point(0.5, inner, a1)
            let r0 = radial(a0, 1), r1 = radial(a1, 1)
            let r0i = radial(a0, -1), r1i = radial(a1, -1)

            // Outer and inner curved faces.
            tri(o0L, o1L, o1R, r0, r1, r1)
            tri(o0L, o1R, o0R, r0, r1, r0)
            tri(i0L, i1R, i1L, r0i, r1i, r1i)
            tri(i0L, i0R, i1R, r0i, r0i, r1i)

            // Flat sides.
            let nx = SIMD3<Float>(-1, 0, 0)
            tri(i0L, o0L, o1L, nx, nx, nx)
            tri(i0L, o1L, i1L, nx, nx, nx)
            let px = SIMD3<Float>(1, 0, 0)
            tri(i0R, i1R, o1R, px, px, px)
            tri(i0R, o1R, o0R, px, px, px)
        }

        // End caps at the springing line.
        let cap0 = SIMD3<Float>(0, 0, -1)
        tri(point(-0.5, inner, 0), point(0.5, inner, 0), point(0.5, 1, 0),
            cap0, cap0, cap0)
        tri(point(-0.5, inner, 0), point(0.5, 1, 0), point(-0.5, 1, 0),
            cap0, cap0, cap0)
        let capPi = SIMD3<Float>(0, 0, 1)
        tri(point(-0.5, inner, .pi), point(0.5, 1, .pi), point(0.5, inner, .pi),
            capPi, capPi, capPi)
        tri(point(-0.5, inner, .pi), point(-0.5, 1, .pi), point(0.5, 1, .pi),
            capPi, capPi, capPi)
        return v
    }

    /// Flat chevron used for birds; double-sided so it reads from any angle.
    static func bird(rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        let nose = SIMD3<Float>(0, 0, 0.5)
        let tail = SIMD3<Float>(0, 0, -0.1)
        let left = SIMD3<Float>(-0.6, 0, -0.3)
        let right = SIMD3<Float>(0.6, 0, -0.3)
        let n = SIMD3<Float>(0, 1, 0)
        var v: [Vertex] = []

        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: b, normal: n, rgb: rgb))
            v.append(Vertex(position: c, normal: n, rgb: rgb))
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: c, normal: n, rgb: rgb))
            v.append(Vertex(position: b, normal: n, rgb: rgb))
        }

        tri(nose, left, tail)
        tri(nose, tail, right)
        return v
    }

    /// Low-poly sphere, used for smoke puffs.
    static func sphere(radius: Float = 0.5, rings: Int = 5, segments: Int = 8,
                       rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []

        func point(_ phi: Float, _ theta: Float) -> SIMD3<Float> {
            SIMD3(radius * sin(phi) * cos(theta),
                  radius * cos(phi),
                  radius * sin(phi) * sin(theta))
        }

        for r in 0..<rings {
            let phi0 = Float(r) / Float(rings) * .pi
            let phi1 = Float(r + 1) / Float(rings) * .pi
            for s in 0..<segments {
                let theta0 = Float(s) / Float(segments) * 2 * .pi
                let theta1 = Float(s + 1) / Float(segments) * 2 * .pi
                let a = point(phi0, theta0)
                let b = point(phi0, theta1)
                let c = point(phi1, theta1)
                let d = point(phi1, theta0)

                v.append(Vertex(position: a, normal: simd_normalize(a), rgb: rgb))
                v.append(Vertex(position: b, normal: simd_normalize(b), rgb: rgb))
                v.append(Vertex(position: c, normal: simd_normalize(c), rgb: rgb))
                v.append(Vertex(position: a, normal: simd_normalize(a), rgb: rgb))
                v.append(Vertex(position: c, normal: simd_normalize(c), rgb: rgb))
                v.append(Vertex(position: d, normal: simd_normalize(d), rgb: rgb))
            }
        }
        return v
    }

    /// A simple cone, used for trees.
    static func cone(radius: Float = 0.5, height: Float = 1, segments: Int = 8,
                     rgb: SIMD3<Float> = SIMD3(repeating: 1)) -> [Vertex] {
        var v: [Vertex] = []
        let tip = SIMD3<Float>(0, height, 0)

        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ outward: SIMD3<Float>) {
            var p1 = b, p2 = c
            var n = simd_cross(p1 - a, p2 - a)
            if simd_length_squared(n) < 1e-12 { return }
            n = simd_normalize(n)
            if simd_dot(n, outward) < 0 { swap(&p1, &p2); n = -n }
            v.append(Vertex(position: a, normal: n, rgb: rgb))
            v.append(Vertex(position: p1, normal: n, rgb: rgb))
            v.append(Vertex(position: p2, normal: n, rgb: rgb))
        }

        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = SIMD3(cos(a0) * radius, 0, sin(a0) * radius)
            let p1 = SIMD3(cos(a1) * radius, 0, sin(a1) * radius)
            let mid = (a0 + a1) * 0.5
            tri(p0, p1, tip, SIMD3(cos(mid), 0.6, sin(mid)))
            tri(SIMD3(0, 0, 0), p1, p0, SIMD3(0, -1, 0))
        }
        return v
    }
}

import Foundation
import simd

enum RiverLakeShore {
    static func append(field: RiverChannel.Field, terrain: Terrain, submitted: [Vertex]?,
                       vertices: inout [Vertex], indices: inout [UInt32]) {
        struct Key: Hashable, Comparable {
            let x: Int64; let z: Int64
            static func < (a: Self, b: Self) -> Bool { a.x == b.x ? a.z < b.z : a.x < b.x }
        }
        struct Edge: Hashable { let a: Key; let b: Key }
        let metres = RiverGraph.metresPerUnit, weld = 0.0001 / metres // 0.1 mm boundary identity
        func key(_ p: SIMD3<Float>) -> Key { Key(x: Int64((p.x / weld).rounded()), z: Int64((p.z / weld).rounded())) }
        var counts: [Edge: Int] = [:], directed: [(Edge, Vertex, Vertex)] = []
        for tri in field.mesh.lakeTriangles {
            for i in 0..<3 {
                let a = tri[i], b = tri[(i + 1) % 3], ka = key(a.position), kb = key(b.position)
                guard ka != kb else { continue }
                let edge = ka < kb ? Edge(a: ka, b: kb) : Edge(a: kb, b: ka)
                counts[edge, default: 0] += 1; directed.append((edge, a, b))
            }
        }
        let boundary = directed.filter { counts[$0.0] == 1 }
        var normals: [Key: SIMD2<Float>] = [:]
        for (_, a, b) in boundary {
            let d = SIMD2(b.position.x - a.position.x, b.position.z - a.position.z)
            guard simd_length_squared(d) > weld * weld else { continue }
            let normal = simd_normalize(SIMD2(-d.y, d.x))
            normals[key(a.position), default: .zero] += normal
            normals[key(b.position), default: .zero] += normal
        }
        for (_, a, b) in boundary {
            let pa = SIMD2(a.position.x, a.position.z), pb = SIMD2(b.position.x, b.position.z)
            let direction = pb - pa
            guard simd_length_squared(direction) > weld * weld else { continue }
            let outward = simd_normalize(SIMD2(-direction.y, direction.x))
            let base = UInt32(vertices.count)
            for (point, vertex) in [(pa, a), (pb, b)] {
                let sum = normals[key(vertex.position)] ?? outward
                let normal = simd_length_squared(sum) > 0 ? simd_normalize(sum) : outward
                let miter = normal / max(simd_dot(normal, outward), 0.25) // standard 4× miter limit
                for offsetMetres: Float in [0, 2, 4, 7] {
                    let p = point + miter * (offsetMetres / metres)
                    let ground = submitted.map { WorldScene.renderedTerrainHeight(p, terrain: terrain, vertices: $0) }
                        ?? RiverChannel.carvedHeight(terrain.interpolatedHeight(x: p.x, z: p.y), field: field, x: p.x, z: p.y)
                    let level = a.position.y
                    let y = offsetMetres == 0 ? level - 0.015 / metres
                        : offsetMetres <= 4 ? max(ground, level + (offsetMetres == 2 ? 0.12 : 0.35) / metres) : ground
                    vertices.append(Vertex(position: SIMD3(p.x, y, p.y), normal: SIMD3(0, 1, 0),
                        color: SIMD4(0.34, 0.37, 0.23, offsetMetres < 4 ? 0.3 : 1), uv: SIMD2(0,offsetMetres == 7 ? 1 : 0)))
                }
            }
            for i: UInt32 in 0..<3 {
                let ids = [base + i, base + 4 + i, base + i + 1,
                           base + i + 1, base + 4 + i, base + 5 + i]
                for j in stride(from: 0, to: 6, by: 3) {
                    var face = Array(ids[j..<(j + 3)])
                    if RiverPolygon.area(face.map { vertices[Int($0)] }) > 0 { face.swapAt(1, 2) }
                    indices.append(contentsOf: face)
                }
            }
        }
    }
}

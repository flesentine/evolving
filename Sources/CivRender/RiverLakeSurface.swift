import Foundation
import simd

enum RiverLakeSurface {
    /// Clip original terrain triangles at the spill elevation. Land islands and
    /// shoreline indentations remain dry; no disc or convex lake hull is used.
    static func triangles(_ lake: RiverLake, terrain: Terrain) -> [[Vertex]] {
        let n = terrain.size
        var cells: Set<Int> = []
        for vertex in lake.cells {
            let i = vertex % n, j = vertex / n
            for dz in [-1, 0] { for dx in [-1, 0] {
                let x = i + dx, z = j + dz
                if x >= 0 && x < n - 1 && z >= 0 && z < n - 1 { cells.insert(z * n + x) }
            }}
        }
        var result: [[Vertex]] = []
        func v(_ index: Int) -> Vertex {
            Vertex(position: SIMD3(terrain.worldX(index % n), terrain.height[index], terrain.worldZ(index / n)),
                   normal: SIMD3(0, 1, 0), rgb: SIMD3(0.02, 0.09, 0.15))
        }
        for cell in cells.sorted() {
            for ids in [[cell, cell + n + 1, cell + 1], [cell, cell + n, cell + n + 1]] {
                var polygon: [Vertex] = [], previous = v(ids.last!)
                for id in ids {
                    let current = v(id)
                    if (current.position.y < lake.level) != (previous.position.y < lake.level) {
                        polygon.append(RiverPolygon.interpolate(previous, current,
                            (lake.level - previous.position.y) / (current.position.y - previous.position.y)))
                    }
                    if current.position.y < lake.level { polygon.append(current) }
                    previous = current
                }
                guard polygon.count >= 3 else { continue }
                for i in polygon.indices { polygon[i].position.y = lake.level }
                for i in 1..<(polygon.count - 1) {
                    var tri = [polygon[0], polygon[i], polygon[i + 1]]
                    if RiverPolygon.area(tri) > 0 { tri.swapAt(1, 2) }
                    if abs(RiverPolygon.area(tri)) > RiverPolygon.areaEpsilon { result.append(tri) }
                }
            }
        }
        // Retain the clipped terrain tessellation. Collapsing an entire basin
        // into long contour diagonals creates fragile Boolean slivers at river
        // entries and makes the shore apron span unrelated terrain features.
        // These faces already form a disjoint, hole-preserving planar mesh.
        return result
    }
}

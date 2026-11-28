import Foundation
import simd

/// Bounds come from the submitted mesh's authored coordinates, including its
/// origin offset. Instance columns describe scale, not the mesh's dimensions.
enum RiverPlacement {
    private static var buildingBounds: [String: [SIMD2<Float>]] = [:]

    static let unitBoxBounds = bounds(Geometry.cube())

    static func bounds(_ vertices: [Vertex]) -> [SIMD2<Float>] {
        guard let first = vertices.first else { return [] }
        var lo = SIMD2(first.position.x, first.position.z), hi = lo
        for v in vertices {
            let p = SIMD2(v.position.x,v.position.z)
            lo = simd_min(lo,p); hi = simd_max(hi,p)
        }
        return [lo,SIMD2(hi.x,lo.y),hi,SIMD2(lo.x,hi.y)]
    }
    static func authoredBounds(_ path: String) -> [SIMD2<Float>] {
        if let cached = buildingBounds[path] { return cached }
        let result = bounds(authoredVertices(path))
        buildingBounds[path] = result
        return result
    }
    static func authoredVertices(_ path: String) -> [Vertex] {
        let vertices: [Vertex]
        switch path {
        case "__temple": vertices = Geometry.temple()
        case "__church": vertices = Geometry.church()
        case "__cathedral": vertices = Geometry.cathedral()
        case "__cathedral_glass": vertices = Geometry.cathedralGlass()
        case "__dome": vertices = Geometry.dome()
        case "__dock": vertices = Geometry.dock()
        default:
            if let mesh = try? CivMesh.load(named:path + ".civmesh") {
                vertices = mesh.indices.map { mesh.vertices[Int($0)] }
            } else { vertices = [] }
        }
        return vertices
    }
    static func transformed(_ footprint: [SIMD2<Float>], by model: simd_float4x4) -> [SIMD2<Float>] {
        footprint.map {
            let p = model * SIMD4($0.x,0,$0.y,1)
            return SIMD2(p.x,p.z)
        }
    }
    /// Test transformed rectangular footprints on both sets of edge axes.
    static func rectanglesOverlap(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>],
                                  clearance: Float = 0) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for rectangle in [a, b] {
            for index in [1, 3] {
                let axis = simd_normalize(rectangle[index] - rectangle[0])
                let projectedA = a.map { simd_dot($0, axis) }
                let projectedB = b.map { simd_dot($0, axis) }
                if projectedA.max()! + clearance < projectedB.min()!
                    || projectedB.max()! + clearance < projectedA.min()! {
                    return false
                }
            }
        }
        return true
    }

    static func dry(_ instance: InstanceData, bounds: [SIMD2<Float>], field: RiverChannel.Field, setbackMetres: Float = 1.5) -> Bool {
        !field.intersectsFootprint(transformed(bounds,by:instance.model), margin:setbackMetres / RiverGraph.metresPerUnit)
    }
    /// Independently inspect transformed submitted mesh vertices, rather than
    /// assuming that an instance's scale is its footprint.
    static func violations(_ geometry: CityBuilder.Geometry, field: RiverChannel.Field) -> Int {
        var failures = 0
        func inspect(_ instances: [InstanceData], _ mesh: [Vertex]) {
            for instance in instances {
                let projected = mesh.map { vertex -> SIMD2<Float> in
                    let p = instance.model * SIMD4(vertex.position,1)
                    return SIMD2(p.x,p.z)
                }
                guard let first = projected.first else { continue }
                let lo = projected.reduce(first,simd_min), hi = projected.reduce(first,simd_max)
                if !field.intersectsFootprint([lo,SIMD2(hi.x,lo.y),hi,SIMD2(lo.x,hi.y)],margin:0) { continue }
                for i in stride(from:0,to:projected.count-2,by:3) {
                    let triangle = Array(projected[i..<(i+3)])
                    let a = triangle[1]-triangle[0], b = triangle[2]-triangle[0]
                    if abs(a.x*b.y-a.y*b.x) > 1e-20 && field.intersectsFootprint(triangle,margin:0) {
                        failures += 1; break
                    }
                }
            }
        }
        for path in geometry.buildings.keys.sorted() { inspect(geometry.buildings[path]!,authoredVertices(path)) }
        inspect(geometry.boxes,Geometry.cube()); inspect(geometry.cones,Geometry.cone())
        inspect(geometry.gables,Geometry.gable()); inspect(geometry.arches,Geometry.arch()); inspect(geometry.fields,Geometry.cube())
        return failures
    }
    static func filter(_ geometry: inout CityBuilder.Geometry, field: RiverChannel.Field) {
        for path in geometry.buildings.keys.sorted() {
            let footprint = authoredBounds(path)
            geometry.buildings[path] = geometry.buildings[path]?.filter { dry($0,bounds:footprint,field:field,setbackMetres:2) }
        }
        // Static furniture, walls, market awnings and park/field meshes also
        // have a footprint. Roads and their explicit bridges use separate
        // street geometry and retain their crossing treatment.
        let box = bounds(Geometry.cube()), cone = bounds(Geometry.cone()), gable = bounds(Geometry.gable()), arch = bounds(Geometry.arch())
        geometry.boxes = geometry.boxes.filter { dry($0,bounds:box,field:field) }
        geometry.cones = geometry.cones.filter { dry($0,bounds:cone,field:field) }
        geometry.gables = geometry.gables.filter { dry($0,bounds:gable,field:field) }
        geometry.arches = geometry.arches.filter { dry($0,bounds:arch,field:field) }
        geometry.fields = geometry.fields.filter { dry($0,bounds:box,field:field) }
    }
}

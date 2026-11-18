import Foundation
import simd

/// Loft earth along exposed edges of the submitted junction footprint. Existing
/// bank strips end at the shared trims; their cut profiles are exact anchors.
enum RiverJunctionShore {
    struct ShoreEdge { let a: Vertex; let b: Vertex; let junction: Int }
    static func boundary(_ field: RiverChannel.Field) -> [ShoreEdge] {
        struct Edge: Hashable { let a: SIMD2<Float>; let b: SIMD2<Float> }
        func key(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Edge {
            a.x < b.x || (a.x == b.x && a.y < b.y) ? Edge(a:a,b:b) : Edge(a:b,b:a)
        }
        let mesh = field.mesh, tolerance = 0.0001 / RiverGraph.metresPerUnit
        var counts: [Edge:Int] = [:], edges: [(Edge,Vertex,Vertex,Int?)] = []
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let tri = (0..<3).map { mesh.vertices[Int(mesh.indices[i+$0])] }
            let owner = mesh.junctions.firstIndex { $0.indexRange.contains(i) }
            for k in 0..<3 {
                let a = tri[k], b = tri[(k+1)%3]
                let id = key(SIMD2(a.position.x,a.position.z),SIMD2(b.position.x,b.position.z))
                counts[id,default:0] += 1; edges.append((id,a,b,owner))
            }
        }
        var result: [ShoreEdge] = []
        for (id,a,b,owner) in edges where counts[id] == 1 {
            guard let owner else { continue }
            let pa = SIMD2(a.position.x,a.position.z), pb = SIMD2(b.position.x,b.position.z)
            let j = mesh.junctions[owner]
            if j.cuts.contains(where: { RiverPolygon.segmentDistance(pa,$0.0,$0.1) <= tolerance
                && RiverPolygon.segmentDistance(pb,$0.0,$0.1) <= tolerance }) { continue }
            let spring = field.network.contains { r in
                guard r.upstream.isEmpty, let s = r.samples.first else { return false }
                let radius = RiverChannel.halfWidth(s) + tolerance
                return simd_distance(pa,s.position) <= radius && simd_distance(pb,s.position) <= radius
                    && simd_dot((pa+pb)*0.5-s.position,-s.tangent) >= -tolerance
            }
            if !spring { result.append(ShoreEdge(a:a,b:b,junction:owner)) }
        }
        return result
    }

    static func append(field: RiverChannel.Field, terrain: Terrain, submitted: [Vertex]?,
                       vertices: inout [Vertex], indices: inout [UInt32]) {
        struct Anchor { let p: SIMD2<Float>; let direction: SIMD2<Float>; let half: Float; let level: Float; let profile: [RiverChannel.BankPoint] }
        let edges = boundary(field), metres = RiverGraph.metresPerUnit
        var anchors: [[Anchor]] = []
        for junction in field.mesh.junctions {
            var list: [Anchor] = []
            func add(_ sample: RiverSample) {
                let half = RiverChannel.halfWidth(sample), side = RiverChannel.sideVector(sample)
                let level = RiverGraph.waterLevel(sample)
                for sign: Float in [-1,1] {
                    list.append(Anchor(p: sample.position+side*(sign*half), direction: side*sign,
                        half: half, level: level, profile: RiverChannel.bankProfile(terrain,sample,sideSign:sign,lift:0,field:field)))
                }
            }
            for (a,b,_) in junction.cuts {
                let centre = (a+b)*0.5
                var closest: RiverSample?, distance = Float.greatestFiniteMagnitude
                for reach in field.network { for sample in reach.samples {
                    let d = simd_distance(sample.position,centre)
                    if d < distance { closest = sample; distance = d }
                }}
                if let closest { add(closest) }
            }
            for reach in field.network where reach.upstream.isEmpty {
                if let s = reach.samples.first,
                   junction.input.contains(where: { RiverChannel.Field.probe($0,s.position).distance <= 0 }) { add(s) }
            }
            anchors.append(list)
        }
        var normals: [SIMD2<Float>:SIMD2<Float>] = [:]
        for edge in edges {
            let a = SIMD2(edge.a.position.x,edge.a.position.z), b = SIMD2(edge.b.position.x,edge.b.position.z)
            let d = b-a
            if simd_length_squared(d) == 0 { continue }
            let n = simd_normalize(SIMD2(-d.y,d.x))
            normals[a,default:.zero] += n; normals[b,default:.zero] += n
        }
        for edge in edges {
            let a = SIMD2(edge.a.position.x,edge.a.position.z), b = SIMD2(edge.b.position.x,edge.b.position.z)
            guard simd_length_squared(b-a) > 0 else { continue }
            let n = simd_normalize(SIMD2(a.y-b.y,b.x-a.x))
            let steps = max(Int(ceil(simd_distance(a,b) / (0.5/metres))),1) // 50 cm maximum shore row
            let profiles = anchors[edge.junction]
            guard !profiles.isEmpty else { continue }
            let count = profiles[0].profile.count, base = UInt32(vertices.count)
            for row in 0...steps {
                let t = Float(row)/Float(steps), p = a+(b-a)*t
                let level = edge.a.position.y+(edge.b.position.y-edge.a.position.y)*t
                let exact = profiles.firstIndex { simd_distance($0.p,p) <= 0.0001/metres }
                var weights: [Float] = [], total: Float = 0
                for (i,anchor) in profiles.enumerated() {
                    let w = exact.map { $0 == i ? Float(1) : 0 } ?? 1/max(simd_length_squared(anchor.p-p),1e-20) // world-unit² predicate
                    weights.append(w); total += w
                }
                let na = normals[a] ?? n, nb = normals[b] ?? n
                let sum = na+(nb-na)*t
                let direction = exact.map { profiles[$0].direction } ?? (simd_length_squared(sum) > 0 ? simd_normalize(sum) : n)
                let miter = exact != nil ? direction : direction/max(simd_dot(direction,n),0.25)
                var points: [SIMD3<Float>] = [], offsets: [Float] = [], colors: [SIMD4<Float>] = []
                for k in 0..<count {
                    var offset: Float = 0, height: Float = 0, color = SIMD3<Float>.zero, wetness: Float = 0
                    for (i,anchor) in profiles.enumerated() {
                        let w = weights[i]/total, point = anchor.profile[k]
                        offset += (point.offset-anchor.half)*w; height += (point.y-anchor.level)*w
                        color += point.color*w; wetness += point.wetness*w
                    }
                    let q = p+miter*offset
                    let ground = submitted.map { WorldScene.renderedTerrainHeight(q,terrain:terrain,vertices:$0) }
                        ?? terrain.interpolatedHeight(x:q.x,z:q.y)
                    let y = k == 0 ? level-0.004/metres
                        : k == count-1 ? ground+RiverChannel.seam : max(level+height,ground+RiverChannel.seam)
                    points.append(SIMD3(q.x,y,q.y)); offsets.append(offset); colors.append(SIMD4(color,1-wetness))
                }
                for k in 0..<count {
                    let lo = max(k-1,0), hi = min(k+1,count-1)
                    let slope = (points[hi].y-points[lo].y)/max(offsets[hi]-offsets[lo],0.000001/metres)
                    let normal = simd_normalize(SIMD3(-direction.x*slope,1,-direction.y*slope))
                    vertices.append(Vertex(position:points[k],normal:normal,color:colors[k],uv:SIMD2(0,k == count-1 ? 1 : 0)))
                }
            }
            for row in 0..<steps { for k in 0..<(count-1) {
                let a = base+UInt32(row*count+k), b = a+1, c = a+UInt32(count), d = c+1
                for var face in [[a,c,b],[b,c,d]] {
                    if RiverPolygon.area(face.map { vertices[Int($0)] }) > 0 { face.swapAt(1,2) }
                    indices.append(contentsOf:face)
                }
            }}
        }
    }

    static func closureFailures(field: RiverChannel.Field, banks: (vertices:[Vertex],indices:[UInt32])) -> Int {
        let triangles = stride(from:0,to:banks.indices.count,by:3).map { i in
            (0..<3).map { banks.vertices[Int(banks.indices[i+$0])] }
        }
        let index = RiverTriangleBuckets(triangles), metres = RiverGraph.metresPerUnit
        var failures = 0
        for edge in boundary(field) {
            for t: Float in [0,0.5,1] {
                let p = edge.a.position+(edge.b.position-edge.a.position)*t
                let v = Vertex(position:p,normal:SIMD3(0,1,0),rgb:.zero)
                if !index.near([v]).contains(where: {
                    let probe = RiverChannel.Field.probe($0,SIMD2(p.x,p.z))
                    return probe.distance <= 0.001/metres && abs(probe.water-p.y) <= 0.01/metres
                }) {
                    failures += 1
                    if failures <= 8 {
                        let nearest = index.near([v]).map { RiverChannel.Field.probe($0,SIMD2(p.x,p.z)) }.sorted { $0.distance < $1.distance }.first
                        if let tri = index.near([v]).min(by: { RiverChannel.Field.probe($0,SIMD2(p.x,p.z)).distance < RiverChannel.Field.probe($1,SIMD2(p.x,p.z)).distance }) {
                            print("nearest bank face: \(tri.map { $0.position }); boundary edge \(edge.a.position) -> \(edge.b.position)")
                        }
                        print("junction shore gap J\(field.mesh.junctions[edge.junction].id) at \(p), nearest \(String(describing:nearest)); expected <=1 mm XY, <=1 cm Y")
                    }
                }
            }
        }
        return failures
    }
}

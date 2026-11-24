import Foundation
import simd

extension RiverSurface {
    static func coastalGradeFixture() -> Bool {
        let metres = RiverGraph.metresPerUnit
        func vertex(_ x:Float,_ z:Float,_ y:Float) -> Vertex {
            let angle:Float = 0.37 // radians; translated/rotated case exercises Float seam identities
            let p = SIMD2<Float>(-0.319,-0.655)+SIMD2(cos(angle)*x-sin(angle)*z,sin(angle)*x+cos(angle)*z)/metres
            return Vertex(position:SIMD3(p.x,y/metres,p.y),normal:SIMD3(0,1,0),rgb:.zero)
        }
        let a = vertex(-10,-5,1), b = vertex(0,-5,0), c = vertex(0,5,0), d = vertex(-10,5,1)
        let e = vertex(10,-5,0), f = vertex(10,5,0)
        let input = [[a,c,b],[a,d,c],[b,f,e],[b,c,f]]
        let cuts:[(SIMD2<Float>,SIMD2<Float>,Float)] = [
            (SIMD2(a.position.x,a.position.z),SIMD2(d.position.x,d.position.z),1/metres),
            (SIMD2(e.position.x,e.position.z),SIMD2(f.position.x,f.position.z),0)]
        var vertices:[Vertex] = [], indices:[UInt32] = []
        let centre = (SIMD2(b.position.x,b.position.z)+SIMD2(c.position.x,c.position.z))*0.5
        let seams = appendGradedJunction(input:input,cuts:cuts,controls:[(centre,centre,0)],vertices:&vertices,indices:&indices)
        let final = RiverSurfaceWeld.apply(Geometry(vertices:vertices,indices:indices,junctions:[],ribbonWidths:[],gradeSeams:seams))
        vertices = final.vertices; indices = final.indices
        let faces = stride(from:0,to:indices.count,by:3).map { i in (0..<3).map { vertices[Int(indices[i+$0])] } }
        let topology = RiverPolygon.boundaryFailures(faces)
        var area:Double = 0, elevated:Double = 0
        for i in stride(from:0,to:indices.count,by:3) {
            let triangle = (0..<3).map { vertices[Int(indices[i+$0])] }
            area += abs(RiverPolygon.area(triangle))*1_000_000
            for zero in input.suffix(2) {
                let overlap = RiverGeometryChecks.intersection(triangle,zero,inset:RiverPolygon.epsilon)
                if overlap.contains(where: { $0.position.y > 0.001/metres }) {
                    elevated += abs(RiverPolygon.area(overlap))*1_000_000
                }
            }
        }
        let sourceCut = vertices.filter {
            RiverPolygon.segmentDistance(SIMD2($0.position.x,$0.position.z),cuts[0].0,cuts[0].1) <= 0.0001/metres
        }
        let controlsPreserved = !sourceCut.isEmpty && sourceCut.allSatisfy { abs($0.position.y-1/metres) <= 0.001/metres }
        let pass = abs(area-200) < 0.01 && elevated <= 0.000001 && topology == 0 && controlsPreserved
        print("coastal junction grade fixture: wet area \(area) m² (expected 200), elevated sea region \(elevated) m², topology failures \(topology): \(pass ? "PASS" : "FAIL")")
        return pass
    }

    /// Preserve the exact flat receiving-water domain, rather than allowing
    /// distant positive cut levels to bleed into it through interpolation.
    /// Both regions remain part of the same canonical wet union and mesh.
    @discardableResult
    static func appendGradedJunction(input:[[Vertex]],
        cuts:[(SIMD2<Float>,SIMD2<Float>,Float)], controls:[(SIMD2<Float>,SIMD2<Float>,Float)],
        vertices:inout [Vertex], indices:inout [UInt32]) -> [(SIMD2<Float>,SIMD2<Float>)] {
        let tolerance = 0.0001 / RiverGraph.metresPerUnit // 0.1 mm seam identity
        func level(_ p:SIMD2<Float>) -> Float {
            var sum:Double = 0, weight:Double = 0
            for (a,b,y) in cuts+controls {
                let distance = RiverPolygon.segmentDistance(p,a,b)
                if distance < tolerance { return y }
                let w = 1/Double(distance*distance)
                sum += Double(y)*w; weight += w
            }
            return Float(sum/max(weight,1))
        }
        var graded:[Vertex] = [], gradedIndices:[UInt32] = []
        for piece in RiverPolygon.union(input) {
            RiverPolygon.append(piece.map { vertex in
                var v = vertex
                v.position.y = level(SIMD2(v.position.x,v.position.z)); return v
            },vertices:&graded,indices:&gradedIndices)
        }
        let flat = input.filter { $0.allSatisfy { $0.position.y == RiverGraph.seaLevel } }
        guard !flat.isEmpty && flat.count < input.count else {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf:graded); indices.append(contentsOf:gradedIndices.map { $0+base }); return []
        }
        var sea:[Vertex] = [], seaIndices:[UInt32] = []
        for polygon in RiverPolygon.union(flat) {
            RiverPolygon.append(polygon.map { vertex in
                var v = vertex; v.position.y = RiverGraph.seaLevel; return v
            },vertices:&sea,indices:&seaIndices)
        }
        let seaFaces = stride(from:0,to:seaIndices.count,by:3).map { i in
            (0..<3).map { sea[Int(seaIndices[i+$0])] }
        }
        let seaIndex = RiverTriangleBuckets(seaFaces)
        // Declare internal interfaces and subdivision edges as welds. Exterior
        // shoreline keeps the stricter ordinary vertex identity.
        func boundary(_ vs:[Vertex],_ ids:[UInt32],occurrences:Int = 1) -> [(SIMD2<Float>,SIMD2<Float>)] {
            struct Edge:Hashable { let a:SIMD2<Float>; let b:SIMD2<Float> }
            var counts:[Edge:Int] = [:], order:[Edge] = []
            for i in stride(from:0,to:ids.count,by:3) { for k in 0..<3 {
                let va = vs[Int(ids[i+k])].position, vb = vs[Int(ids[i+(k+1)%3])].position
                let a = SIMD2(va.x,va.z), b = SIMD2(vb.x,vb.z)
                let forward = a.x < b.x || (a.x == b.x && a.y < b.y)
                let edge = forward ? Edge(a:a,b:b) : Edge(a:b,b:a)
                if counts[edge] == nil { order.append(edge) }
                counts[edge,default:0] += 1
            }}
            return order.filter { counts[$0] == occurrences }.map { ($0.a,$0.b) }
        }
        let exterior = boundary(graded,gradedIndices)
        let interface = boundary(sea,seaIndices).filter { a,b in
            let mid = (a+b)*0.5
            return !exterior.contains { RiverPolygon.segmentDistance(mid,$0.0,$0.1) <= tolerance }
        }
        let seams = interface+boundary(graded,gradedIndices,occurrences:2)+boundary(sea,seaIndices,occurrences:2)
        var partition:[Vertex] = [], partitionIndices:[UInt32] = []
        for i in stride(from:0,to:gradedIndices.count,by:3) {
            let triangle = (0..<3).map { graded[Int(gradedIndices[i+$0])] }
            let near = seaIndex.near(triangle)
            var pieces = [triangle]
            for face in near where RiverPolygon.overlaps(triangle,face) {
                pieces = pieces.flatMap { RiverPolygon.subtract($0,face) }
            }
            for piece in pieces {
                RiverPolygon.append(piece,vertices:&partition,indices:&partitionIndices)
            }
        }
        let seaBase = UInt32(partition.count)
        partition.append(contentsOf:sea); partitionIndices.append(contentsOf:seaIndices.map { $0+seaBase })
        // Conform the subdivision in XZ before assigning its heights. Otherwise
        // a new stop can lie off an old triangle's 3D edge after one side was
        // flattened, leaving an internal T-junction that grows a false bank.
        let planar = partition.map { vertex -> Vertex in
            var v = vertex; v.position.y = 0; return v
        }
        let conformed = RiverSurfaceWeld.apply(Geometry(vertices:planar,indices:partitionIndices,
            junctions:[],ribbonWidths:[],endpointSeams:cuts.map { ($0.0,$0.1) },gradeSeams:seams))
        let base = UInt32(vertices.count)
        vertices.append(contentsOf:conformed.vertices.map { vertex in
            var v = vertex
            let p = SIMD2(v.position.x,v.position.z)
            v.position.y = seaIndex.near([v]).contains(where: { RiverChannel.Field.probe($0,p).distance <= tolerance })
                ? RiverGraph.seaLevel : level(p)
            return v
        })
        indices.append(contentsOf:conformed.indices.map { $0+base })
        return seams
    }
}

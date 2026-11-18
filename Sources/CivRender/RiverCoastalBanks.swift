import Foundation
import simd

/// The original island's visible sea footprint, using the same detail-2
/// triangle interpolation as its uncarved submitted terrain. Bank construction
/// may restore soil on original land, but must not invent land in the ocean.
enum RiverCoastalBanks {
    static func wetPolygons(near polygon:[Vertex], terrain:Terrain) -> [[Vertex]] {
        guard let first = polygon.first else { return [] }
        let low = polygon.reduce(SIMD2(first.position.x,first.position.z)) { simd_min($0,SIMD2($1.position.x,$1.position.z)) }
        let high = polygon.reduce(low) { simd_max($0,SIMD2($1.position.x,$1.position.z)) }
        let ci0 = max(terrain.cellX(low.x)-1,0), ci1 = min(terrain.cellX(high.x)+1,terrain.size-1)
        let cj0 = max(terrain.cellZ(low.y)-1,0), cj1 = min(terrain.cellZ(high.y)+1,terrain.size-1)
        guard ci0 <= ci1, cj0 <= cj1 else { return [] }
        var coastal = false
        for j in cj0...cj1 { for i in ci0...ci1 {
            if terrain.height[terrain.index(i,j)] <= RiverGraph.seaLevel { coastal = true }
        }}
        if !coastal { return [] }
        let n = (terrain.size-1)*2+1, spacing = terrain.cellSize/2
        let i0 = min(max(Int(floor((low.x+1)/spacing)),0),n-2), i1 = min(max(Int(floor((high.x+1)/spacing)),0),n-2)
        let j0 = min(max(Int(floor((low.y+1)/spacing)),0),n-2), j1 = min(max(Int(floor((high.y+1)/spacing)),0),n-2)
        func vertex(_ i:Int,_ j:Int) -> Vertex {
            // Match the submitted detail-2 terrain's Float coordinates.
            let x = -1+Float(i)/2*terrain.cellSize, z = -1+Float(j)/2*terrain.cellSize // world units, 2 km island domain
            return Vertex(position:SIMD3(x,terrain.interpolatedHeight(x:x,z:z),z),normal:SIMD3(0,1,0),rgb:.zero)
        }
        var result: [[Vertex]] = []
        for j in j0...j1 { for i in i0...i1 {
            let a = vertex(i,j), b = vertex(i+1,j), c = vertex(i+1,j+1), d = vertex(i,j+1)
            for triangle in [[a,b,c],[a,c,d]] {
                var clipped: [Vertex] = [], previous = triangle.last!
                for current in triangle {
                    let hp = previous.position.y-RiverGraph.seaLevel, hc = current.position.y-RiverGraph.seaLevel
                    if (hp < 0) != (hc < 0) { clipped.append(RiverPolygon.interpolate(previous,current,hp/(hp-hc))) }
                    if hc < 0 { clipped.append(current) }
                    previous = current
                }
                var clean: [Vertex] = []
                for var vertex in clipped {
                    vertex.position.y = RiverGraph.seaLevel
                    if let last = clean.last, simd_distance(RiverPolygon.point(last),RiverPolygon.point(vertex)) <= RiverPolygon.epsilon { continue }
                    clean.append(vertex)
                }
                if clean.count > 1, simd_distance(RiverPolygon.point(clean[0]),RiverPolygon.point(clean.last!)) <= RiverPolygon.epsilon { clean.removeLast() }
                // A coast exactly on a grid vertex can emit that vertex twice.
                // A zero-length cutter edge would otherwise duplicate dry pieces.
                if abs(RiverPolygon.area(clean)) > RiverPolygon.areaEpsilon { result.append(clean) }
            }
        }}
        return result
    }
    static func clip(_ pieces:[[Vertex]], near triangle:[Vertex], terrain:Terrain) -> [[Vertex]] {
        var result = pieces
        for sea in wetPolygons(near:triangle,terrain:terrain) where RiverPolygon.overlaps(triangle,sea) {
            result = result.flatMap { RiverPolygon.subtract($0,sea) }
            if result.isEmpty { break }
        }
        return result
    }
    static func fixture() -> Bool {
        var terrain = RiverEndpointValidation.fixtureTerrain()
        terrain.riverGraph = nil
        for j in 0..<terrain.size { for i in 0..<terrain.size {
            terrain.height[terrain.index(i,j)] = -terrain.worldX(i)*0.2 // 1:5 coast slope, sea at x=0 world units
        }}
        let metres = RiverGraph.metresPerUnit
        let points: [SIMD2<Float>] = [SIMD2(-10,-5),SIMD2(10,-5),SIMD2(10,5),SIMD2(-10,5)]
        let vertices = points.map { Vertex(position:SIMD3($0.x/metres,0.35/metres,$0.y/metres),normal:SIMD3(0,1,0),rgb:.zero) }
        let old = (vertices:vertices,indices:[UInt32](arrayLiteral:0,2,1,0,3,2))
        var output: [Vertex] = [], indices: [UInt32] = []
        for i in stride(from:0,to:old.indices.count,by:3) {
            let triangle = (0..<3).map { vertices[Int(old.indices[i+$0])] }
            for piece in clip([triangle],near:triangle,terrain:terrain) { RiverPolygon.append(piece,vertices:&output,indices:&indices) }
        }
        let before = intrusionArea(old,terrain:terrain), after = intrusionArea((output,indices),terrain:terrain)
        let retained = stride(from:0,to:indices.count,by:3).reduce(0.0) { sum,i in
            sum+abs(RiverPolygon.area((0..<3).map { output[Int(indices[i+$0])] }))*1_000_000
        }
        let pass = before > 99 && after <= 0.000001 && abs(retained-100) < 0.01
        print("coastal bank fixture: above-sea ocean overlap \(before) -> \(after) m²; original-land bank retained \(retained) m²: \(pass ? "PASS" : "FAIL")")
        return pass
    }
    static func intrusionArea(_ banks:(vertices:[Vertex],indices:[UInt32]),terrain:Terrain, minimumHeight:Float = 0) -> Double {
        var area: Double = 0
        for i in stride(from:0,to:banks.indices.count,by:3) {
            let triangle = (0..<3).map { banks.vertices[Int(banks.indices[i+$0])] }
            guard triangle.contains(where: { $0.position.y > RiverGraph.seaLevel }) else { continue }
            for water in wetPolygons(near:triangle,terrain:terrain) where RiverPolygon.overlaps(triangle,water) {
                let overlap = RiverGeometryChecks.intersection(triangle,water,inset:RiverPolygon.epsilon)
                if overlap.contains(where: { $0.position.y > RiverGraph.seaLevel+minimumHeight }) {
                    area += abs(RiverPolygon.area(overlap))*1_000_000
                    if ProcessInfo.processInfo.environment["EVOLVING_COAST_TRACE"] == "1" {
                        print("coast overlap: \(abs(RiverPolygon.area(overlap))*1_000_000) m²; max height \(overlap.map { $0.position.y*RiverGraph.metresPerUnit }.max() ?? 0) m; triangle \(triangle.map { $0.position })")
                    }
                }
            }
        }
        return area
    }
}

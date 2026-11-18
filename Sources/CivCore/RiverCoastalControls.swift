import Foundation
import simd

extension RiverGraph {
    /// Test the swept water triangles against the original detail-2 terrain.
    /// Section probes miss coastal notches between rows and narrow corners.
    /// The first intersecting interval starts the sea-level boundary control;
    /// the grade solver lowers its upstream approach without raising terrain.
    static func coastalWaterControls(_ network: inout [RiverReach], terrain: Terrain) {
        for r in network.indices where network[r].endpoint == .coastalMouth {
            let samples = network[r].samples
            guard samples.count > 1 else { continue }
            func section(_ s:RiverSample) -> (SIMD2<Float>,SIMD2<Float>) {
                let tangent = s.junctionTangent ?? s.tangent
                let offset = SIMD2(-tangent.y,tangent.x)*channelHalfWidth(s)
                return (s.position-offset,s.position+offset)
            }
            for i in 1..<samples.count {
                let a = section(samples[i-1]), b = section(samples[i])
                if originalSeaIntersects([a.0,b.0,a.1],terrain:terrain)
                    || originalSeaIntersects([a.1,b.0,b.1],terrain:terrain) {
                    for k in (i-1)..<samples.count { network[r].samples[k].waterOverride = seaLevel }
                    break
                }
            }
        }
    }

    /// Exact intersection with the original submitted a-c terrain triangles.
    /// Computed in Double; the sea datum is zero world units, without an offset.
    static func originalSeaIntersects(_ footprint:[SIMD2<Float>], terrain:Terrain) -> Bool {
        let low = footprint.reduce(footprint[0],simd_min), high = footprint.reduce(footprint[0],simd_max)
        let ci0 = max(terrain.cellX(low.x)-1,0), ci1 = min(terrain.cellX(high.x)+1,terrain.size-1)
        let cj0 = max(terrain.cellZ(low.y)-1,0), cj1 = min(terrain.cellZ(high.y)+1,terrain.size-1)
        guard ci0 <= ci1 && cj0 <= cj1 else { return false }
        var coastal = false
        for j in cj0...cj1 { for i in ci0...ci1 {
            if terrain.height[terrain.index(i,j)] < seaLevel { coastal = true }
        }}
        if !coastal { return false }
        let n = (terrain.size-1)*2+1, spacing = terrain.cellSize/2
        let i0 = min(max(Int(floor((low.x+1)/spacing)),0),n-2), i1 = min(max(Int(floor((high.x+1)/spacing)),0),n-2)
        let j0 = min(max(Int(floor((low.y+1)/spacing)),0),n-2), j1 = min(max(Int(floor((high.y+1)/spacing)),0),n-2)
        func vertex(_ i:Int,_ j:Int) -> SIMD3<Double> {
            // Match WorldScene.terrainVertices' Float arithmetic exactly.
            let x = -1+Float(i)/2*terrain.cellSize, z = -1+Float(j)/2*terrain.cellSize // world units; 2 km domain
            return SIMD3(Double(x),Double(terrain.interpolatedHeight(x:x,z:z)),Double(z))
        }
        func cross(_ a:SIMD2<Double>,_ b:SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
        let boundary = footprint.map { SIMD2(Double($0.x),Double($0.y)) }
        let winding:Double = cross(boundary[1]-boundary[0],boundary[2]-boundary[0]) >= 0 ? 1 : -1
        func intersects(_ triangle:[SIMD3<Double>]) -> Bool {
            if triangle.allSatisfy({ $0.y >= Double(seaLevel) }) { return false }
            var polygon = triangle
            for k in 0..<3 {
                let a = boundary[k], edge = boundary[(k+1)%3]-a
                func distance(_ p:SIMD3<Double>) -> Double { winding*cross(edge,SIMD2(p.x,p.z)-a) }
                var output:[SIMD3<Double>] = []
                guard var previous = polygon.last else { return false }
                var dp = distance(previous)
                for current in polygon {
                    let dc = distance(current)
                    if (dp >= 0) != (dc >= 0) { output.append(previous+(current-previous)*(dp/(dp-dc))) }
                    if dc >= 0 { output.append(current) }
                    previous = current; dp = dc
                }
                polygon = output
            }
            return polygon.contains { $0.y < Double(seaLevel) }
        }
        for j in j0...j1 { for i in i0...i1 {
            let a = vertex(i,j), b = vertex(i+1,j), c = vertex(i+1,j+1), d = vertex(i,j+1)
            if intersects([a,b,c]) || intersects([a,c,d]) { return true }
        }}
        return false
    }
}

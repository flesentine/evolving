import Foundation
import simd

/// Close the earth banks around the existing spring water cap. This adds land,
/// not water coverage, and follows the same 16-segment cap boundary exactly.
enum RiverSpringBanks {
    static func capPoint(_ sample: RiverSample, fraction: Float) -> SIMD2<Float> {
        let half = RiverChannel.halfWidth(sample), side = RiverChannel.sideVector(sample)
        let a = fraction * .pi
        return sample.position + side * (half * cos(a)) - sample.tangent * (half * 0.62 * sin(a))
    }
    static func exposed(_ sample: RiverSample, field: RiverChannel.Field) -> Bool {
        let probe = sample.position - sample.tangent * (RiverChannel.halfWidth(sample) * 0.62 + 0.001 / RiverGraph.metresPerUnit)
        return RiverGraph.waterLevel(sample) > 0 && field.waterLevel(at: probe) == nil
    }
    static func append(field: RiverChannel.Field, terrain: Terrain, submitted: [Vertex]?,
                       vertices: inout [Vertex], indices: inout [UInt32]) {
        let metres = RiverGraph.metresPerUnit
        for reach in field.network where reach.upstream.isEmpty {
            guard let sample = reach.samples.first, exposed(sample, field: field) else { continue }
            let left = RiverChannel.bankProfile(terrain, sample, sideSign: 1, lift: 0, field: field)
            let right = RiverChannel.bankProfile(terrain, sample, sideSign: -1, lift: 0, field: field)
            let half = RiverChannel.halfWidth(sample), side = RiverChannel.sideVector(sample), outward = -sample.tangent
            let radius = max(left.last!.offset, right.last!.offset)
            let subdivisions = max(Int(ceil(radius * .pi / 16 / (0.5 / metres))), 1) // at most 50 cm shore rows
            let segments = 16 * subdivisions, count = left.count, base = UInt32(vertices.count)
            for row in 0...segments {
                let fraction = Float(row) / Float(segments), angle = fraction * .pi
                let interval = min(row / subdivisions, 15), local = Float(row - interval * subdivisions) / Float(subdivisions)
                let a = capPoint(sample, fraction: Float(interval) / 16), b = capPoint(sample, fraction: Float(interval + 1) / 16)
                let inner = a + (b-a) * local
                let direction = side * cos(angle) + outward * sin(angle)
                let blend = sin(angle) * sin(angle)
                var points: [SIMD3<Float>] = [], offsets: [Float] = []
                for k in 0..<count {
                    let offset = left[k].offset + (right[k].offset-left[k].offset) * fraction
                    let p = inner + direction * (offset-half)
                    let ground = submitted.map { WorldScene.renderedTerrainHeight(p, terrain: terrain, vertices: $0) }
                        ?? terrain.interpolatedHeight(x: p.x, z: p.y)
                    var y = left[k].y + (right[k].y-left[k].y) * fraction
                    if k == 0 { y -= 0.004 / metres } // same 4 mm submerged bank skirt
                    else if k == count-1 { y = ground + RiverChannel.seam }
                    else {
                        let original = field.originalTerrain.interpolatedHeight(x: p.x, z: p.y) + RiverChannel.seam
                        y += (min(y, original)-y) * blend
                    }
                    points.append(SIMD3(p.x,y,p.y)); offsets.append(offset)
                }
                for k in 0..<count {
                    let lo = max(k-1,0), hi = min(k+1,count-1)
                    let slope = (points[hi].y-points[lo].y) / max(offsets[hi]-offsets[lo], 0.000001 / metres)
                    let normal = simd_normalize(SIMD3(-direction.x*slope,1,-direction.y*slope))
                    let color = left[k].color + (right[k].color-left[k].color) * fraction
                    let wetness = left[k].wetness + (right[k].wetness-left[k].wetness) * fraction
                    vertices.append(Vertex(position: points[k], normal: normal, color: SIMD4(color,1-wetness), uv: SIMD2(0,k == count-1 ? 1 : 0)))
                }
            }
            for row in 0..<segments { for k in 0..<(count-1) {
                let a = base + UInt32(row*count+k), b = a+1, c = a+UInt32(count), d = c+1
                for var face in [[a,c,b],[b,c,d]] {
                    if RiverPolygon.area(face.map { vertices[Int($0)] }) > 0 { face.swapAt(1,2) }
                    indices.append(contentsOf: face)
                }
            }}
        }
    }

    static func closureFailures(field: RiverChannel.Field, banks: (vertices: [Vertex], indices: [UInt32])) -> Int {
        let triangles = stride(from: 0, to: banks.indices.count, by: 3).map { i in
            (0..<3).map { banks.vertices[Int(banks.indices[i+$0])] }
        }
        let index = RiverTriangleBuckets(triangles), metres = RiverGraph.metresPerUnit
        var failures = 0
        for reach in field.network where reach.upstream.isEmpty {
            guard let sample = reach.samples.first, exposed(sample, field: field) else { continue }
            for i in 0...16 {
                let p = capPoint(sample, fraction: Float(i)/16)
                let v = Vertex(position: SIMD3(p.x,0,p.y), normal: SIMD3(0,1,0), rgb: .zero)
                let matches = index.near([v]).map { RiverChannel.Field.probe($0,p) }
                if !matches.contains(where: { $0.distance <= 0.001 / metres
                    && abs($0.water-RiverGraph.waterLevel(sample)) <= 0.01 / metres }) {
                    failures += 1
                }
            }
        }
        return failures
    }
}

import Foundation
import simd

extension RiverGraph {
    /// A tributary's complete terminal cross-section must lie inside the actual
    /// receiving stem, including its bend and width gradient. Matching scalar
    /// half-widths alone still leaves projecting terminal corners on acute Ys.
    static func containedTributaryHalf(_ sample:RiverSample, main:[RiverSample], downstream:[RiverSample]) -> Float {
        let half = Double(channelHalfWidth(sample))
        let t = sample.junctionTangent ?? sample.tangent
        let side = SIMD2<Double>(-Double(t.y),Double(t.x))
        let p = SIMD2<Double>(Double(sample.position.x),Double(sample.position.y))
        func cross(_ a:SIMD2<Double>,_ b:SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
        var intervals: [(Double,Double)] = []
        for samples in [main,downstream] {
            let rows = samples.map { s -> [SIMD2<Double>] in
                let t = s.junctionTangent ?? s.tangent
                let n = SIMD2<Double>(-Double(t.y),Double(t.x))*Double(channelHalfWidth(s))
                let q = SIMD2<Double>(Double(s.position.x),Double(s.position.y))
                return [q-n,q+n]
            }
            for i in 1..<rows.count {
                let a = rows[i-1], b = rows[i]
                for tri in [[a[0],a[1],b[0]],[a[1],b[1],b[0]]] {
                    let area = cross(tri[1]-tri[0],tri[2]-tri[0])
                    if area == 0 { continue }
                    let sign: Double = area > 0 ? 1 : -1
                    var lo = -half, hi = half
                    for j in 0..<3 {
                        let edge = tri[(j+1)%3]-tri[j]
                        let origin = sign*cross(edge,p-tri[j]), slope = sign*cross(edge,side)
                        if slope == 0 { if origin < 0 { hi = -half-1 }; continue } // exact parallel half-plane predicate, world units
                        if slope > 0 { lo = max(lo,-origin/slope) } else { hi = min(hi,-origin/slope) }
                    }
                    if lo <= hi { intervals.append((lo,hi)) }
                }
            }
        }
        intervals.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let identity = 0.000001/Double(metresPerUnit) // 1 µm interval identity
        var merged: [(Double,Double)] = []
        for interval in intervals {
            if let last = merged.last, interval.0 <= last.1+identity {
                merged[merged.count-1].1 = max(last.1,interval.1)
            } else { merged.append(interval) }
        }
        guard let span = merged.first(where: { $0.0 <= identity && $0.1 >= -identity }) else { return 0 }
        let fit = min(half,-span.0,span.1)
        let numericalBand = 0.0001/Double(metresPerUnit) // existing 0.1 mm conditioning band
        return fit >= half-numericalBand ? Float(half) : Float(max(fit-numericalBand,0))
    }
}

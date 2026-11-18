import Foundation
import simd

extension RiverGraph {
    static func channelHalfWidth(_ s: RiverSample) -> Float {
        let width = s.channelWidth > 0 ? s.channelWidth : s.width
        return min(max(width * 0.5, minimumHalfWidth) * s.sourceWidthFactor, s.bendLimit, s.junctionLimit)
    }

    /// A tributary's terminal row must fit inside the receiving stem. Otherwise
    /// a valid Boolean union preserves its projecting corners as water spurs.
    /// Width limits propagate along approaches with a bounded bank convergence.
    static func prepareJunctions(_ input: [RiverReach]) -> [RiverReach] {
        if input.allSatisfy({ $0.junctionsPrepared }) { return input }
        var network = input
        func mainStem(_ upstream: [Int]) -> Int {
            upstream.sorted {
                let a = network[$0], b = network[$1]
                if a.incomingArea > 0 && b.incomingArea > 0 && a.incomingArea != b.incomingArea {
                    return a.incomingArea > b.incomingArea
                }
                // The final sample already contains the joined catchment;
                // use the preceding sample when testing synthetic graphs.
                let aw = a.samples[max(a.samples.count-2,0)].width
                let bw = b.samples[max(b.samples.count-2,0)].width
                return aw == bw ? $0 < $1 : aw > bw
            }[0]
        }
        for d in network.indices where !network[d].upstream.isEmpty {
            let upstream = network[d].upstream
            guard let first = network[d].samples.first else { continue }
            let main = mainStem(upstream)
            let last = network[main].samples.count - 1
            let end = network[main].samples[last]
            let sum = first.tangent + end.tangent
            let tangent = first.tangent == end.tangent ? first.tangent
                : (simd_length_squared(sum) > 1e-12 ? simd_normalize(sum) : first.tangent)
            let half: Float
            if upstream.count == 1 {
                half = min(max(channelHalfWidth(first), channelHalfWidth(end)), first.bendLimit, end.bendLimit)
                network[d].samples[0].channelWidth = half * 2
                network[d].samples[0].sourceWidthFactor = 1
                network[main].samples[last].channelWidth = half * 2
                network[main].samples[last].sourceWidthFactor = 1
            } else { half = min(channelHalfWidth(first), channelHalfWidth(end)) }
            network[d].samples[0].junctionTangent = tangent
            network[main].samples[last].junctionTangent = tangent
            // At most 0.25 m of half-width change per metre along a bank.
            // This is a geometric 1:4 convergence bound, not a render offset.
            let convergence: Float = 0.25
            for a in upstream {
                let length = network[a].samples.last!.along
                for i in network[a].samples.indices {
                    let distanceMetres = length - network[a].samples[i].along
                    network[a].samples[i].junctionLimit = min(network[a].samples[i].junctionLimit,
                        half + distanceMetres * convergence / metresPerUnit)
                }
            }
            let start = network[d].samples[0].along
            for i in network[d].samples.indices {
                let distanceMetres = network[d].samples[i].along - start
                network[d].samples[i].junctionLimit = min(network[d].samples[i].junctionLimit,
                    half + distanceMetres * convergence / metresPerUnit)
            }
        }
        // Blend the shared cross-section orientation into each approach.
        // Routing directions remain untouched. Exponential endpoint basis
        // functions satisfy both node constraints even on very short reaches.
        for r in network.indices where network[r].samples.count > 2 {
            let samples = network[r].samples, original = input[r].samples
            let length = Double(samples.last!.along - samples[0].along) // metres
            guard length > 0 else { continue }
            func angle(_ d: SIMD2<Float>) -> Double { atan2(Double(d.y), Double(d.x)) }
            func wrapped(_ d: Double) -> Double { atan2(sin(d), cos(d)) }
            let first = samples[0], last = samples.last!
            let startDelta = wrapped(angle(first.junctionTangent ?? first.tangent) - angle(original[0].tangent))
            let endDelta = wrapped(angle(last.junctionTangent ?? last.tangent) - angle(original.last!.tangent))
            let transitionMetres = max(8, Double(4 * max(channelHalfWidth(first), channelHalfWidth(last)) * metresPerUnit))
            let cross = exp(-length / transitionMetres), denominator = 1 - cross * cross
            let a = (startDelta - cross * endDelta) / denominator
            let b = (endDelta - cross * startDelta) / denominator
            for i in 1..<(samples.count - 1) {
                let distance = Double(samples[i].along - first.along)
                let correction = a * exp(-distance / transitionMetres) + b * exp(-(length-distance) / transitionMetres)
                let theta = angle(original[i].tangent) + correction
                network[r].samples[i].junctionTangent = SIMD2(Float(cos(theta)), Float(sin(theta)))
            }
            for i in 1..<samples.count {
                let a = network[r].samples[i-1], b = network[r].samples[i]
                let ta = a.junctionTangent ?? a.tangent, tb = b.junctionTangent ?? b.tangent
                let sineHalf = sqrt(max((1 - min(max(simd_dot(ta,tb), -1), 1)) * 0.5, 0))
                if sineHalf > 1e-6 { // dimensionless angular predicate
                    let radius = simd_distance(a.position, b.position) / (2 * sineHalf)
                    network[r].samples[i-1].junctionLimit = min(a.junctionLimit, radius * 0.9)
                    network[r].samples[i].junctionLimit = min(b.junctionLimit, radius * 0.9)
                }
            }
        }
        // Bend caps also participate in the width envelope. Applying a bend
        // limit after width smoothing left abrupt notches and projecting bank
        // corners beside junctions. Propagate only narrowing constraints and
        // re-couple shared stem rows until every reach boundary is covered.
        let convergence: Float = 0.25 // metres of half-width per metre along channel
        func propagateWidths() {
        for _ in 0...network.count {
            for d in network.indices where !network[d].upstream.isEmpty {
                let upstream = network[d].upstream
                let main = mainStem(upstream)
                let end = network[main].samples.count - 1
                let half = min(channelHalfWidth(network[d].samples[0]), channelHalfWidth(network[main].samples[end]))
                network[d].samples[0].junctionLimit = min(network[d].samples[0].junctionLimit, half)
                for a in upstream {
                    let last = network[a].samples.count - 1
                    network[a].samples[last].junctionLimit = min(network[a].samples[last].junctionLimit, half)
                }
            }
            for r in network.indices {
                for i in 1..<network[r].samples.count {
                    let a = network[r].samples[i-1], b = network[r].samples[i]
                    let cap = channelHalfWidth(a) + max(b.along-a.along, 0) * convergence / metresPerUnit
                    network[r].samples[i].junctionLimit = min(b.junctionLimit, cap)
                }
                for i in network[r].samples.indices.reversed() where i + 1 < network[r].samples.count {
                    let a = network[r].samples[i], b = network[r].samples[i+1]
                    let cap = channelHalfWidth(b) + max(b.along-a.along, 0) * convergence / metresPerUnit
                    network[r].samples[i].junctionLimit = min(a.junctionLimit, cap)
                }
            }
        }
        }
        propagateWidths()
        // Exact swept-row validity. A centreline radius estimate alone misses
        // skew cross-sections beside a removed junction. Triangle area under
        // proportional width scaling is λ*A + λ²*B; solve its positive root.
        // The 2% conditioning margin is dimensionless, not a height offset.
        for _ in 0..<32 {
            var changed = false
            for r in network.indices {
                for i in 1..<network[r].samples.count {
                    let a = network[r].samples[i-1], b = network[r].samples[i]
                    let ha = Double(channelHalfWidth(a)), hb = Double(channelHalfWidth(b))
                    let ta = a.junctionTangent ?? a.tangent, tb = b.junctionTangent ?? b.tangent
                    let na = SIMD2<Double>(-Double(ta.y),Double(ta.x)), nb = SIMD2<Double>(-Double(tb.y),Double(tb.x))
                    let dp = SIMD2<Double>(Double(b.position.x-a.position.x),Double(b.position.y-a.position.y))
                    func cross(_ x:SIMD2<Double>,_ y:SIMD2<Double>) -> Double { x.x*y.y-x.y*y.x }
                    let bend = 2*ha*hb*cross(na,nb)
                    let terms = [(2*ha*cross(na,dp),-bend),(2*hb*cross(nb,dp),bend)]
                    var scale: Double = 1
                    for (linear,quadratic) in terms where linear < 0 && quadratic > 0 && linear+quadratic >= 0 {
                        scale = min(scale,(-linear/quadratic)*0.98)
                    }
                    if scale < 1 {
                        network[r].samples[i-1].junctionLimit = min(a.junctionLimit,Float(ha*scale))
                        network[r].samples[i].junctionLimit = min(b.junctionLimit,Float(hb*scale))
                        changed = true
                    }
                }
            }
            for d in network.indices where network[d].upstream.count >= 2 {
                let main = mainStem(network[d].upstream)
                for a in network[d].upstream where a != main {
                    let last = network[a].samples.count-1, sample = network[a].samples[last]
                    let fit = containedTributaryHalf(sample,main:network[main].samples,downstream:network[d].samples)
                    if fit < channelHalfWidth(sample) {
                        network[a].samples[last].junctionLimit = min(sample.junctionLimit,fit)
                        changed = true
                    }
                }
            }
            if !changed { break }
            propagateWidths()
        }
        for i in network.indices { network[i].junctionsPrepared = true }
        return network
    }
}

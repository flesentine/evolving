import Foundation

extension RiverGraph {
    /// Lower the connected surface gradually towards each receiving node.
    /// An endpoint stamp alone leaves the entire drop in the final short row.
    /// Source/lake controls stay fixed; naturally steep headwaters may require
    /// a steeper bound than the ordinary 1:10 approach grade.
    static func smoothWaterGrades(_ network: inout [RiverReach], upstreamFirst: [Int], fixed: [Set<Int>]) {
        let ordinaryGrade: Float = 0.10 // metres of fall per metre of channel
        for r in upstreamFirst.reversed() {
            let last = network[r].samples.count-1
            if let d = network[r].downstream {
                network[r].samples[last].waterOverride = network[d].samples[0].waterOverride
            }
            var end = last
            while end > 0 {
                let start = fixed[r].filter { $0 < end }.max() ?? 0
                var grade = ordinaryGrade
                if fixed[r].contains(start) {
                    let level = network[r].samples[start].waterOverride
                    for i in (start+1)...end {
                        let distanceMetres = network[r].samples[i].along-network[r].samples[start].along
                        if distanceMetres > 0 {
                            grade = max(grade,(level-network[r].samples[i].waterOverride)*metresPerUnit/distanceMetres)
                        }
                    }
                }
                for i in stride(from:end-1,through:start,by:-1) {
                    let next = network[r].samples[i+1]
                    let distanceMetres = next.along-network[r].samples[i].along
                    let ceiling = next.waterOverride+grade*max(distanceMetres,0)/metresPerUnit
                    if !fixed[r].contains(i) {
                        network[r].samples[i].waterOverride = min(network[r].samples[i].waterOverride,ceiling)
                    }
                }
                end = start
            }
        }
    }
}

import Foundation
import simd

enum TownHistoryCheck {
    static func run(seed: UInt64, townID: Int32) {
        let terrain = WorldGen.generate(seed: seed)
        let network = RiverNetwork.build(terrain)
        let field = RiverChannel.Field(terrain: terrain, network: network.reaches)
        let metres = RiverGraph.metresPerUnit
        let placementTerrain = RiverChannel.supportedTerrain(RiverChannel.carvedTerrain(terrain, field: field),
            field: field, radius: RiverChannel.terrainSupportRadius(terrain, detail: 2))
        let snapshots: [Float] = [4_400, 5_500, 7_900, 4_400]
        var referenceChurch: simd_float4x4?
        var referenceAxis: Float?
        var commonRoute: [ClosedRange<Float>]?

        for year in snapshots {
            var simulation = Simulation(seed: seed, terrain: terrain)
            simulation.advance(to: year)
            guard let town = simulation.settlements.first(where: { $0.id == townID && $0.isAlive }) else {
                fail("Town #\(townID) is missing at year \(year)")
            }
            let geometry = CityBuilder.build(settlements: [town], era: simulation.era, year: year,
                                             terrain: placementTerrain, seed: seed, riverField: field)
            guard let grid = geometry.streets.first,
                  let churches = geometry.buildings[HistoricQuarter.mesh], churches.count == 1 else {
                fail("Town #\(townID) is missing its single historic church in \(simulation.era.name)")
            }
            let church = churches[0]
            if let referenceChurch, let referenceAxis {
                guard referenceChurch == church.model, referenceAxis == grid.angle else {
                    fail("Town #\(townID) moved its church or changed its street axis in \(simulation.era.name)")
                }
            } else {
                referenceChurch = church.model
                referenceAxis = grid.angle
            }

            let bounds = RiverPlacement.authoredBounds(HistoricQuarter.mesh)
            guard RiverPlacement.dry(church, bounds: bounds, field: field, setbackMetres: 2) else {
                fail("Town #\(townID) church enters the river setback")
            }

            let origin = SIMD2(grid.x, grid.z)
            let along = SIMD2(cos(grid.angle), sin(grid.angle))
            let across = SIMD2(-along.y, along.x)
            let projections = geometry.streetLines.flatMap { line in
                zip(line.points, line.points.dropFirst()).compactMap { a, b -> ClosedRange<Float>? in
                    let start = (a - origin) * metres
                    let end = (b - origin) * metres
                    // The full segment must follow the old axis to within 20 cm.
                    guard abs(simd_dot(start, across)) <= 0.20,
                          abs(simd_dot(end, across)) <= 0.20 else { return nil }
                    let low = min(simd_dot(start, along), simd_dot(end, along))
                    let high = max(simd_dot(start, along), simd_dot(end, along))
                    return high - low > 0.001 ? low...high : nil
                }
            }
            let route = union(projections)
            commonRoute = commonRoute.map { previous in
                union(previous.flatMap { run in
                    route.compactMap { current in
                        let low = max(run.lowerBound, current.lowerBound)
                        let high = min(run.upperBound, current.upperBound)
                        return low < high ? low...high : nil
                    }
                })
            } ?? route
            let pos = church.model.columns.3
            print(String(format: "seed %llu, %@, year %.0f, %@ #%d, church XZ %.3f m, %.3f m; longest high-street run %.2f m",
                         seed, simulation.era.name as NSString, year, town.name as NSString, town.id,
                         pos.x * metres, pos.z * metres, longest(route)))
        }
        let retained = longest(commonRoute ?? [])
        guard retained >= 20 else {
            fail(String(format: "Only %.2f m of continuous shared high street remains across the three eras", retained))
        }
        print(String(format: "PASS fixed church transform through three eras and rewind; %.2f m of shared high street", retained))
    }

    private static func longest(_ parts: [ClosedRange<Float>]) -> Float {
        parts.map { $0.upperBound - $0.lowerBound }.max() ?? 0
    }

    private static func union(_ parts: [ClosedRange<Float>]) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        for part in parts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = runs.last, part.lowerBound <= last.upperBound + 0.001 {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, part.upperBound)
            } else {
                runs.append(part)
            }
        }
        return runs
    }
}

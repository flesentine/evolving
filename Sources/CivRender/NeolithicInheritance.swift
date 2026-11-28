import simd

/// Bronze construction can grow around homes that were standing at the end
/// of the Neolithic. Replaying the boundary works even when Timeline opens
/// directly in the Bronze Age, and needs no new saved data.
enum NeolithicInheritance {
    static let boundaryYear = Era.bronze.startYear - 1
    private static let metres = RiverGraph.metresPerUnit

    struct Home {
        let settlement: Int32
        let court: Int
        let path: String
        let instance: InstanceData
        let footprint: [SIMD2<Float>]
    }

    static func boundaryHomes(for simulation: Simulation, in scene: WorldScene) -> [Home] {
        var replay = Simulation(seed: simulation.seed, terrain: simulation.terrain)
        replay.advance(to: boundaryYear)
        let geometry = CityBuilder.build(settlements: replay.settlements, era: replay.era, year: replay.year,
            terrain: scene.terrain, seed: replay.seed, riverField: scene.riverField,
            renderedGround: scene.renderedTerrainHeight(at:),
            renderedTint: scene.renderedTerrainTint(at:))
        return geometry.neolithicHomes
    }

    static func select(_ homes: [Home], settlements: [Settlement],
                       site: BronzeLayout.Site) -> [Home] {
        let byTown = Dictionary(grouping: homes, by: \.settlement)
        return settlements.flatMap { town -> [Home] in
            let clear = byTown[town.id, default: []].filter {
                site.clear($0.footprint, margin: 2 / metres)
            }
            // Each eligible court can keep its own group of neighbours.
            // Reserve these groups before filling the gaps with new courts.
            let courts = Dictionary(grouping: clear, by: \.court)
            return courts.keys.sorted().flatMap { courts[$0, default: []].prefix(4) }
        }
    }
}

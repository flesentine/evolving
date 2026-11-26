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
            renderedGround: scene.renderedTerrainHeight(at:))
        return geometry.neolithicHomes
    }

    static func place(_ homes: [Home], settlements: [Settlement], geometry: inout CityBuilder.Geometry,
                      scene: WorldScene, trees: [InstanceData]) -> FieldSurface.Mask {
        let bronzePaths = Set(BuildingCatalog.bronze.map(\.path))
        var built = FieldSurface.Mask()
        func reserve(_ instances: [InstanceData], bounds: [SIMD2<Float>]) {
            for item in instances {
                built.insertFootprint(RiverPlacement.transformed(bounds, by: item.model))
            }
        }
        for path in geometry.buildings.keys.sorted() where !bronzePaths.contains(path) {
            reserve(geometry.buildings[path, default: []], bounds: RiverPlacement.authoredBounds(path))
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        reserve(geometry.boxes, bounds: cube)
        reserve(geometry.fields, bounds: cube)
        reserve(geometry.cones, bounds: RiverPlacement.bounds(Geometry.cone()))
        reserve(geometry.gables, bounds: RiverPlacement.bounds(Geometry.gable()))
        reserve(geometry.arches, bounds: RiverPlacement.bounds(Geometry.arch()))
        for tree in trees {
            let p = NeolithicPeople.xz(tree.model.columns.3)
            let r = 0.55 / metres
            built.insertFootprint([p + SIMD2(-r, -r), p + SIMD2(r, -r), p + SIMD2(r, r), p + SIMD2(-r, r)])
        }

        let roads = scene.activityRoads
        let streets = scene.activityStreets
        let banks = scene.riverBankFootprint
        let byTown = Dictionary(grouping: homes, by: \.settlement)
        let retained = settlements.flatMap { town -> [Home] in
            let clear = byTown[town.id, default: []].filter { home in
                !roads.intersectsFootprint(home.footprint)
                    && !streets.intersectsFootprint(home.footprint)
                    && !banks.intersectsFootprint(home.footprint)
                    && !built.intersectsFootprint(home.footprint)
                    && RiverPlacement.dry(home.instance, bounds: RiverPlacement.authoredBounds(home.path),
                                          field: scene.riverField, setbackMetres: 2)
            }
            // Retain a cluster of neighbours when the new town leaves
            // room for one. Stable court order breaks ties.
            let courts = Dictionary(grouping: clear, by: \.court)
            guard let best = courts.keys.sorted().max(by: {
                courts[$0, default: []].count < courts[$1, default: []].count
            }) else { return [] }
            return Array(courts[best, default: []].prefix(4))
        }

        // New houses yield to the retained foundations. Roads, fields and
        // civic structures are already part of the clearance above.
        var reservations = FieldSurface.Mask()
        for home in retained { reservations.insertFootprint(home.footprint) }
        for path in geometry.buildings.keys.sorted() where bronzePaths.contains(path) {
            let bounds = RiverPlacement.authoredBounds(path)
            geometry.buildings[path]?.removeAll {
                reservations.intersectsFootprint(RiverPlacement.transformed(bounds, by: $0.model))
            }
        }
        for home in retained { geometry.buildings[home.path, default: []].append(home.instance) }
        return reservations
    }
}

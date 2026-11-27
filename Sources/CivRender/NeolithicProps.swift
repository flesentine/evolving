import simd

enum NeolithicProps {
    static let paths = ["quern", "basket", "pottery", "wood-stack", "axe"].map {
        "variants/neolithic-prop-" + $0
    }
    private static let metres = RiverGraph.metresPerUnit

    static func place(in scene: WorldScene, geometry: CityBuilder.Geometry) -> [String: [InstanceData]] {
        guard !scene.neolithicYards.yards.isEmpty else { return [:] }
        var occupied = FieldSurface.Mask()
        for path in geometry.buildings.keys.sorted() {
            let bounds = RiverPlacement.authoredBounds(path)
            guard bounds.count == 4 else { continue }
            for instance in geometry.buildings[path, default: []] {
                occupied.insertFootprint(RiverPlacement.transformed(bounds, by: instance.model))
            }
        }
        let cube = RiverPlacement.bounds(Geometry.cube())
        for box in geometry.boxes {
            occupied.insertFootprint(RiverPlacement.transformed(cube, by: box.model))
        }

        let fields = FieldSurface.Mask(mesh: scene.fieldMesh)
        let roads = scene.activityRoads
        let banks = scene.riverBankFootprint
        var placed: [String: [InstanceData]] = [:]
        for yard in scene.neolithicYards.yards {
            guard let approach = yard.connections.first else { continue }
            let forward = approach.entrance.forward
            let side = SIMD2(forward.y, -forward.x)
            let heading = atan2(forward.x, forward.y)
            let door = SIMD2(approach.entrance.door.x, approach.entrance.door.z)
            // Place food preparation by the yard and fuel and tools by the house.
            let anchors = [
                yard.centre + side * (2.8 / metres),
                yard.centre + side * (3.25 / metres) + forward * (0.48 / metres),
                yard.centre + side * (3.24 / metres) - forward * (0.42 / metres),
                door + side * (1.22 / metres) + forward * (0.76 / metres),
                door + side * (1.32 / metres) + forward * (1.45 / metres)
            ]
            for (path, anchor) in zip(paths, anchors) {
                let bounds = RiverPlacement.authoredBounds(path)
                guard bounds.count == 4 else { continue }
                let offsets: [SIMD2<Float>] = [.zero, side * 0.52, -side * 0.52,
                    forward * 0.64, -forward * 0.64, side * 0.85 + forward * 0.64,
                    side * 1.1 - forward * 0.48, side * 1.3]
                for offset in offsets {
                    let point = anchor + offset / metres
                    var model = translation(SIMD3(point.x, 0, point.y))
                        * rotationY(heading) * scaleMatrix(SIMD3(repeating: 1 / metres))
                    let footprint = RiverPlacement.transformed(bounds, by: model)
                    guard !scene.riverField.intersectsFootprint(footprint, margin: 0.3 / metres),
                          !banks.intersectsFootprint(footprint),
                          !scene.activityStreets.intersectsFootprint(footprint),
                          !roads.intersectsFootprint(footprint), !fields.intersectsFootprint(footprint),
                          !occupied.intersectsFootprint(footprint),
                          footprint.allSatisfy({ !scene.terrain.isWater(x: $0.x, z: $0.y) }) else { continue }
                    let heights = (footprint + [point]).map { scene.renderedTerrainHeight(at: $0) }
                    guard let low = heights.min(), let high = heights.max(),
                          low > 0.35 / metres, high - low <= 0.045 / metres else { continue }
                    model.columns.3.y = (high + low) * 0.5
                    occupied.insertFootprint(footprint)
                    placed[path, default: []].append(InstanceData(model: model,
                        color: SIMD4(1, 1, 1, 0), material: SIMD4(9, 0, 0, 0)))
                    break
                }
            }
        }
        return placed
    }
}

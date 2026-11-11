import Foundation
import simd

/// Turns simulation state into instance data. Deterministic: the same
/// settlement at the same population always produces the same buildings, so
/// nothing has to be stored in the save file.
enum CityBuilder {

    /// The street grid of one town, so the renderer can put people on the
    /// actual streets instead of walking them through the houses.
    struct StreetGrid {
        var x: Float
        var z: Float
        /// Direction of the grid's rows.
        var angle: Float
        /// Distance between neighbouring plots.
        var cell: Float
        /// Radius of the built-up area.
        var radius: Float
    }

    struct Geometry {
        var boxes: [InstanceData] = []
        var cones: [InstanceData] = []
        var gables: [InstanceData] = []
        var arches: [InstanceData] = []
        var fields: [InstanceData] = []
        var smoke: [SIMD3<Float>] = []
        var streets: [StreetGrid] = []
        var streetLines: [StreetLine] = []
        var buildings: [String: [InstanceData]] = [:]
    }

    /// One street ribbon, clipped to dry land.
    struct StreetLine {
        var points: [SIMD2<Float>]
        var width: Float
    }

    struct Style {
        var wall: SIMD3<Float>
        var roof: SIMD3<Float>
        var height: ClosedRange<Float>
        var width: ClosedRange<Float>
        var roofs: Bool
        var emissive: Float

        static func forEra(_ era: Era) -> Style {
            switch era {
            case .neolithic:
                return Style(wall: SIMD3(0.60, 0.52, 0.38), roof: SIMD3(0.58, 0.48, 0.28),
                             height: 0.004...0.008, width: 0.005...0.009,
                             roofs: true, emissive: 0)
            case .bronze:
                return Style(wall: SIMD3(0.68, 0.58, 0.43), roof: SIMD3(0.50, 0.36, 0.24),
                             height: 0.005...0.011, width: 0.005...0.010,
                             roofs: true, emissive: 0)
            case .classical:
                return Style(wall: SIMD3(0.80, 0.73, 0.60), roof: SIMD3(0.66, 0.34, 0.22),
                             height: 0.006...0.015, width: 0.006...0.011,
                             roofs: true, emissive: 0)
            case .medieval:
                return Style(wall: SIMD3(0.72, 0.68, 0.58), roof: SIMD3(0.30, 0.32, 0.38),
                             height: 0.008...0.020, width: 0.006...0.011,
                             roofs: true, emissive: 0)
            case .renaissance:
                return Style(wall: SIMD3(0.84, 0.76, 0.62), roof: SIMD3(0.50, 0.31, 0.24),
                             height: 0.009...0.024, width: 0.006...0.012,
                             roofs: true, emissive: 0)
            case .industrial:
                return Style(wall: SIMD3(0.52, 0.40, 0.33), roof: SIMD3(0.28, 0.27, 0.26),
                             height: 0.010...0.032, width: 0.006...0.013,
                             roofs: false, emissive: 0.18)
            case .modern:
                return Style(wall: SIMD3(0.54, 0.55, 0.54), roof: SIMD3(0.40, 0.41, 0.42),
                             height: 0.012...0.055, width: 0.007...0.014,
                             roofs: false, emissive: 0.32)
            case .information:
                return Style(wall: SIMD3(0.27, 0.38, 0.47), roof: SIMD3(0.24, 0.31, 0.37),
                             height: 0.014...0.056, width: 0.007...0.014,
                             roofs: false, emissive: 0.48)
            case .future:
                return Style(wall: SIMD3(0.40, 0.50, 0.57), roof: SIMD3(0.34, 0.45, 0.51),
                             height: 0.016...0.062, width: 0.007...0.015,
                             roofs: false, emissive: 0.62)
            }
        }
    }

    static func build(settlements: [Settlement],
                      era: Era,
                      year: Float,
                      terrain: Terrain,
                      seed: UInt64,
                      riverField: RiverChannel.Field? = nil) -> Geometry {
        var geometry = Geometry()
        let style = Style.forEra(era)
        // One resource field per frame; sampling is cheap and deterministic.
        let resources = ResourceMap(terrain: terrain, seed: seed)

        // Rough capacity estimate so the arrays do not grow constantly.
        geometry.boxes.reserveCapacity(settlements.count * 60)
        geometry.cones.reserveCapacity(settlements.count * 40)

        for settlement in settlements {
            if settlement.isAlive {
                appendSettlement(settlement,
                                 all: settlements,
                                 style: style,
                                 era: era,
                                 year: year,
                                 terrain: terrain,
                                 seed: seed,
                                 resources: resources,
                                 river: riverField,
                                 into: &geometry)
            } else {
                appendRuins(settlement, terrain: terrain, seed: seed, into: &geometry)
            }
        }

        appendOutposts(terrain: terrain, era: era, seed: seed, into: &geometry)

        // A smoothed channel can reach a few metres outside the rasterised
        // river cells. Drop any house whose base would sit under that water;
        // the simulation is unchanged, only the visual placement is corrected.
        if let field = riverField {
            for key in Array(geometry.buildings.keys) {
                geometry.buildings[key] = geometry.buildings[key]?.filter {
                    instance in
                    let p = instance.model.columns.3
                    guard let water = field.waterLevel(at: SIMD2(p.x, p.z)) else {
                        return true
                    }
                    if p.y < water { return false }
                    // A small dry setback keeps loggias and foundations from
                    // overhanging the wet margin.
                    if let d = field.signedDistance(at: SIMD2(p.x, p.z)),
                       d < 0.002 {
                        return false
                    }
                    return true
                }
            }
            // Crops are flat meshes too: drop any field whose footprint
            // reaches the water, so a paddock never paints over the channel.
            geometry.fields = geometry.fields.filter { instance in
                let m = instance.model
                let centre = SIMD3<Float>(m.columns.3.x, 0, m.columns.3.z)
                let axisX = SIMD3<Float>(m.columns.0.x, 0, m.columns.0.z)
                let axisZ = SIMD3<Float>(m.columns.2.x, 0, m.columns.2.z)
                for u in [-0.5, 0, 0.5] as [Float] {
                    for v in [-0.5, 0, 0.5] as [Float] {
                        let q = SIMD2<Float>(
                            centre.x + axisX.x * u + axisZ.x * v,
                            centre.z + axisX.z * u + axisZ.z * v)
                        if let s = field.surface(at: q),
                           s.distance < 1.5 / RiverChannel.metresPerUnit {
                            return false
                        }
                    }
                }
                return true
            }
        }
        return geometry
    }

    /// The planner for an era. Eras without a dedicated planner use the grid.
    static func planner(for era: Era) -> SettlementLayout.Type {
        switch era {
        case .neolithic:
            return NeolithicLayout.self
        case .bronze:
            return BronzeLayout.self
        case .classical:
            return ClassicalLayout.self
        case .medieval:
            return MedievalLayout.self
        case .renaissance:
            return RenaissanceLayout.self
        case .industrial:
            return IndustrialLayout.self
        case .modern:
            return ModernLayout.self
        case .information:
            return InformationLayout.self
        case .future:
            return FutureLayout.self
        default:
            return GridLayout.self
        }
    }

    private static func appendSettlement(_ s: Settlement,
                                         all: [Settlement],
                                         style: Style,
                                         era: Era,
                                         year: Float,
                                         terrain: Terrain,
                                         seed: UInt64,
                                         resources: ResourceMap,
                                         river: RiverChannel.Field?,
                                         into geometry: inout Geometry) {
        let population = max(s.population, 1)
        var count = buildingCount(population)
        if era == .information || era == .future { count = Int(Float(count) * 0.85) }

        var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15))
        let scar = clamp01(s.scar)

        // Every era goes through the same planner entry point. Until an era
        // has its own planner it uses the baseline grid.
        let plan = planner(for: era).plan(settlement: s,
                                          resources: resources,
                                          terrain: terrain,
                                          seed: seed,
                                          style: style)
        let radius = plan.radius
        let cell = plan.cell
        let half = plan.half
        let plots = plan.plots.filter {
            connected($0.center, to: SIMD2(s.x, s.z), river: river)
        }
        let smokeStart = geometry.smoke.count
        // A settlement centre can land on a distributary. Paving is not a
        // building, so it is not caught by the house filter; skip civic
        // paving when the centre square itself is wet.
        let centreDry = river?.waterLevel(at: SIMD2(s.x, s.z)) == nil

        if era != .neolithic {
            geometry.streets.append(StreetGrid(x: s.x, z: s.z, angle: plan.axis,
                                               cell: cell, radius: radius))
        }
        if era == .neolithic {
            // Streetless: movement is across open ground between clusters.
        } else if era == .medieval || era == .bronze {
            appendRoadLines(plan, centre: SIMD2(s.x, s.z),
                            terrain: terrain, river: river,
                            into: &geometry.streetLines)
        } else {
            let plaza: Float = (era == .classical || era == .renaissance)
                ? cell * 1.8 : 0
            appendStreetLines(s, angle: plan.axis, plazaRadius: plaza,
                              cell: cell, radius: radius,
                              terrain: terrain, river: river,
                              into: &geometry.streetLines)
            // Planned extras such as harbour avenues.
            if !plan.roads.isEmpty {
                appendRoadLines(plan, centre: SIMD2(s.x, s.z),
                            terrain: terrain, river: river,
                            into: &geometry.streetLines)
            }
        }

        // A Renaissance piazza is a larger paved civic room.
        if centreDry, era == .renaissance {
            let pg = terrain.interpolatedHeight(x: s.x, z: s.z)
            if pg > 0.004 {
                let pave = translation(SIMD3(s.x, pg + 0.0003, s.z))
                    * rotationY(plan.axis)
                    * scaleMatrix(SIMD3(cell * 3.6, 0.0005, cell * 3.6))
                geometry.boxes.append(InstanceData(
                    model: pave,
                    color: SIMD4(SIMD3(0.70, 0.67, 0.60), 0),
                    material: SIMD4(2, 0, 0, 0)))
            }
        }

        // A classical agora is a paved rectangle at the grid centre.
        if centreDry, era == .classical {
            let ag = terrain.interpolatedHeight(x: s.x, z: s.z)
            if ag > 0.004 {
                let pave = translation(SIMD3(s.x, ag + 0.0003, s.z))
                    * rotationY(plan.axis)
                    * scaleMatrix(SIMD3(cell * 2.9, 0.0005, cell * 2.9))
                geometry.boxes.append(InstanceData(
                    model: pave,
                    color: SIMD4(SIMD3(0.66, 0.63, 0.56), 0),
                    material: SIMD4(2, 0, 0, 0)))
            }
        }

        // Dense eras get a paved civic plaza instead of a solid block of towers.
        if centreDry, era == .information || era == .future {
            let cg = terrain.interpolatedHeight(x: s.x, z: s.z)
            if cg > 0.004 {
                let pave = translation(SIMD3(s.x, cg + 0.0003, s.z))
                    * scaleMatrix(SIMD3(cell * 3.0, 0.0005, cell * 3.0))
                geometry.boxes.append(InstanceData(
                    model: pave,
                    color: SIMD4(SIMD3(0.52, 0.51, 0.48), 0),
                    material: SIMD4(2, 0, 0, 0)))
                for (dx, dz) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    let bx = s.x + Float(dx) * cell * 1.30
                    let bz = s.z + Float(dz) * cell * 1.30
                    let bg = terrain.interpolatedHeight(x: bx, z: bz)
                    guard bg > 0.004 else { continue }
                    let bench = translation(SIMD3(bx, bg + 0.0009, bz))
                        * scaleMatrix(SIMD3(cell * 0.38, 0.0018, cell * 0.10))
                    geometry.boxes.append(InstanceData(
                        model: bench,
                        color: SIMD4(SIMD3(0.36, 0.33, 0.28), 0)))
                }
            }
        }

        let placed = min(count, plots.count)
        let survivors = BuildingCatalog.survivors(for: era)
        let tints: [SIMD3<Float>] = [
            SIMD3(1.00, 1.00, 1.00),
            SIMD3(1.05, 1.00, 0.94),
            SIMD3(0.95, 0.98, 1.03),
            SIMD3(1.02, 0.98, 0.90)
        ]
        var recent: [String] = []

        for index in 0..<placed {
            let slot = plots[index]
            let x = slot.center.x
            let z = slot.center.y

            // Planned parks are green voids, not building plots.
            if slot.district == .park {
                let pg = terrain.heightAt(x: x, z: z)
                if pg > 0.004, !terrain.isWater(x: x, z: z) {
                    let park = translation(SIMD3(x, pg + 0.0003, z))
                        * scaleMatrix(SIMD3(cell * 0.95, 0.0005, cell * 0.95))
                    geometry.fields.append(InstanceData(
                        model: park,
                        color: SIMD4(SIMD3(0.24, 0.38, 0.20), 0),
                        material: SIMD4(5, 0, 0, 0)))
                    let trunk = translation(SIMD3(x + cell * 0.18, pg + 0.0008, z))
                        * scaleMatrix(SIMD3(0.0004, 0.0016, 0.0004))
                    geometry.boxes.append(InstanceData(
                        model: trunk,
                        color: SIMD4(SIMD3(0.38, 0.28, 0.18), 0)))
                    let canopy = translation(SIMD3(x + cell * 0.18, pg + 0.0016, z))
                        * scaleMatrix(SIMD3(0.0024, 0.0032, 0.0024))
                    geometry.cones.append(InstanceData(
                        model: canopy,
                        color: SIMD4(SIMD3(0.22, 0.38, 0.20), 0)))
                }
                continue
            }

            // Ragged outer edge: an occasional empty plot at the fringe so the
            // town does not end on a perfect square.
            if slot.ring == half, rng.nextFloat() < 0.40 { continue }

            // Keep the civic plaza clear in dense eras.
            if (era == .information || era == .future),
               abs(slot.cellIndex.x) <= 1, abs(slot.cellIndex.y) <= 1 { continue }

            // Doors face the street the plot fronts.
            let facing = slot.facing

            // Dense eras keep some plots open as small parks.
            if (era == .information || era == .future) && rng.nextFloat() < 0.10 {
                let parkGround = terrain.heightAt(x: x, z: z)
                guard parkGround > 0.004, !terrain.isWater(x: x, z: z) else { continue }
                let park = translation(SIMD3(x, parkGround + 0.0003, z))
                    * scaleMatrix(SIMD3(cell * 0.70, 0.0005, cell * 0.70))
                geometry.fields.append(InstanceData(
                    model: park,
                    color: SIMD4(SIMD3(0.22, 0.34, 0.18), 0),
                    material: SIMD4(5, 0, 0, 0)))
                for side in [Float(-1), Float(1)] {
                    let bx = x + side * cell * 0.16
                    let bz = z + cell * 0.16
                    let bg = terrain.heightAt(x: bx, z: bz)
                    guard bg > 0.004 else { continue }
                    let bench = translation(SIMD3(bx, bg + 0.0009, bz))
                        * scaleMatrix(SIMD3(cell * 0.20, 0.0018, cell * 0.08))
                    geometry.boxes.append(InstanceData(
                        model: bench,
                        color: SIMD4(SIMD3(0.36, 0.33, 0.28), 0)))
                }
                // A couple of trees and a crossing path.
                for (dx, dz) in [(Float(-0.22), Float(-0.08)),
                                 (Float(0.18), Float(0.16))] {
                    let tx = x + dx * cell
                    let tz = z + dz * cell
                    let tg = terrain.heightAt(x: tx, z: tz)
                    guard tg > 0.004, !terrain.isWater(x: tx, z: tz) else { continue }
                    let trunk = translation(SIMD3(tx, tg + 0.0008, tz))
                        * scaleMatrix(SIMD3(0.0004, 0.0016, 0.0004))
                    geometry.boxes.append(InstanceData(
                        model: trunk,
                        color: SIMD4(SIMD3(0.38, 0.28, 0.18), 0)))
                    let canopy = translation(SIMD3(tx, tg + 0.0015, tz))
                        * scaleMatrix(SIMD3(0.0024, 0.0034, 0.0024))
                    geometry.cones.append(InstanceData(
                        model: canopy,
                        color: SIMD4(SIMD3(0.22, 0.38, 0.20), 0)))
                }
                let path = translation(SIMD3(x, parkGround + 0.0004, z))
                    * scaleMatrix(SIMD3(cell * 0.70, 0.0004, cell * 0.10))
                geometry.boxes.append(InstanceData(
                    model: path,
                    color: SIMD4(SIMD3(0.52, 0.50, 0.45), 0)))
                // Flower beds.
                for (bx, bz, tint) in [(Float(-0.20), Float(0.22), SIMD3<Float>(0.55, 0.22, 0.20)),
                                       (Float(0.22), Float(-0.20), SIMD3<Float>(0.58, 0.50, 0.22))] {
                    let fx = x + bx * cell
                    let fz = z + bz * cell
                    let fg = terrain.heightAt(x: fx, z: fz)
                    guard fg > 0.004 else { continue }
                    let bed = translation(SIMD3(fx, fg + 0.0005, fz))
                        * scaleMatrix(SIMD3(cell * 0.16, 0.0006, cell * 0.10))
                    geometry.boxes.append(InstanceData(
                        model: bed, color: SIMD4(tint, 0)))
                }
                // Park lamp.
                let lampX = x + cell * 0.30
                let lampZ = z + cell * 0.28
                let lg = terrain.heightAt(x: lampX, z: lampZ)
                if lg > 0.004 {
                    let pole = translation(SIMD3(lampX, lg + 0.0014, lampZ))
                        * scaleMatrix(SIMD3(0.0003, 0.0028, 0.0003))
                    geometry.boxes.append(InstanceData(
                        model: pole, color: SIMD4(SIMD3(0.22, 0.22, 0.22), 0)))
                    let head = translation(SIMD3(lampX, lg + 0.0030, lampZ))
                        * scaleMatrix(SIMD3(0.0006, 0.0005, 0.0006))
                    geometry.boxes.append(InstanceData(
                        model: head, color: SIMD4(SIMD3(1.0, 0.84, 0.55), 2.0)))
                }
                continue
            }

            // A few older houses survive into each era.
            let useOlder = !survivors.isEmpty && rng.nextFloat() < 0.12
            let districtPool = BuildingCatalog.assets(for: era, district: slot.district)
            let choices: [BuildingAsset]
            if useOlder {
                choices = survivors
            } else if districtPool.isEmpty {
                choices = BuildingCatalog.assets(for: era)
            } else {
                choices = districtPool
            }
            guard !choices.isEmpty else { continue }

            // Avoid repeating the last two houses on the same street.
            var asset = choices[Int(rng.nextFloat() * Float(choices.count))]
            var attempts = 0
            while recent.contains(asset.path) && attempts < 5 {
                asset = choices[Int(rng.nextFloat() * Float(choices.count))]
                attempts += 1
            }
            recent.append(asset.path)
            if recent.count > 3 { recent.removeFirst() }

            // Some houses sit back from the street behind a low garden wall.
            let setback = rng.nextFloat() < 0.22 ? rng.nextFloat(in: 0.0010...0.0026) : 0
            let front = SIMD2<Float>(sin(facing), cos(facing))
            let hx = x - front.x * setback
            let hz = z - front.y * setback
            let ground = terrain.heightAt(x: hx, z: hz)
            guard ground > 0.004, terrain.isWater(x: hx, z: hz) == false else { continue }

            var baseScale = asset.scale * 0.00088
                * (0.95 + rng.nextFloat() * 0.10)
            if asset.path == "modern-tower" { baseScale *= 0.92 }
            if asset.path.contains("information") || asset.path.contains("future") {
                baseScale *= 0.88
            }

            // Keep the footprint inside its plot; only the height carries the
            // landmark / density multiplier.
            let footprint = BuildingCatalog.footprint(for: asset.path)
            let footprintWidth = max(footprint.x * baseScale, 1e-5)
            let footprintDepth = max(footprint.y * baseScale, 1e-5)
            let fit = min(1.0, min(slot.width * 0.96 / footprintWidth,
                                   slot.depth * 0.96 / footprintDepth))
            let heightScale = slot.scaleMultiplier

            let tint = tints[Int(rng.nextFloat() * Float(tints.count))]
                * (0.93 + rng.nextFloat() * 0.12)
            if slot.podium > 0 {
                let plinth = translation(SIMD3(x, ground + slot.podium * 0.5, z))
                    * rotationY(facing)
                    * scaleMatrix(SIMD3(slot.width * 1.06, slot.podium,
                                        slot.depth * 1.06))
                geometry.boxes.append(InstanceData(
                    model: plinth,
                    color: SIMD4(SIMD3(0.56, 0.53, 0.46), 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            let model = translation(SIMD3(hx, ground + slot.podium - 0.0002, hz))
                * rotationY(facing + rng.nextFloat(in: -0.05...0.05))
                * scaleMatrix(SIMD3(baseScale * fit,
                                    baseScale * heightScale,
                                    baseScale * fit))
            geometry.buildings[asset.path, default: []].append(InstanceData(
                model: model,
                color: SIMD4(tint, 0),
                material: SIMD4(9, 0, 0, 0)))

            // Medieval burgage plots keep a working garden behind the house.
            if era == .medieval, slot.ring == 0, slot.district != .civic {
                let back = slot.center - slot.frontage * (slot.depth * 0.82)
                let bg = terrain.heightAt(x: back.x, z: back.y)
                if bg > 0.004, !terrain.isWater(x: back.x, z: back.y) {
                    let garden = translation(SIMD3(back.x, bg + 0.00035, back.y))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(slot.width * 0.92, 0.0004,
                                            slot.depth * 0.56))
                    geometry.fields.append(InstanceData(
                        model: garden,
                        color: SIMD4(SIMD3(0.30, 0.38, 0.20), 0),
                        material: SIMD4(5, 0, 0, 0)))
                }
            }

            // Industrial detail: villa gardens on the clean side, chimneys and
            // smoke on the mill side.
            if era == .industrial {
                let front = SIMD2<Float>(sin(facing), cos(facing))
                let tangent = SIMD2<Float>(front.y, -front.x)
                if slot.district == .residential && slot.scaleMultiplier > 1.1 {
                    let back = slot.center - front * (slot.depth * 0.85)
                    let bg = terrain.heightAt(x: back.x, z: back.y)
                    if bg > 0.004, !terrain.isWater(x: back.x, z: back.y) {
                        let garden = translation(SIMD3(back.x, bg + 0.00035, back.y))
                            * rotationY(facing)
                            * scaleMatrix(SIMD3(slot.width * 0.95, 0.0004,
                                                slot.depth * 0.65))
                        geometry.fields.append(InstanceData(
                            model: garden,
                            color: SIMD4(SIMD3(0.28, 0.40, 0.20), 0),
                            material: SIMD4(5, 0, 0, 0)))
                        for side in [Float(-1), Float(1)] {
                            let tp = back + tangent * (side * slot.width * 0.55)
                            let tg = terrain.heightAt(x: tp.x, z: tp.y)
                            guard tg > 0.004 else { continue }
                            let trunk = translation(SIMD3(tp.x, tg + 0.0008, tp.y))
                                * scaleMatrix(SIMD3(0.0004, 0.0018, 0.0004))
                            geometry.boxes.append(InstanceData(
                                model: trunk,
                                color: SIMD4(SIMD3(0.38, 0.28, 0.18), 0)))
                            let canopy = translation(SIMD3(tp.x, tg + 0.0017, tp.y))
                                * scaleMatrix(SIMD3(0.0026, 0.0036, 0.0026))
                            geometry.cones.append(InstanceData(
                                model: canopy,
                                color: SIMD4(SIMD3(0.20, 0.36, 0.18), 0)))
                        }
                    }
                } else if slot.district == .industrial, rng.nextFloat() < 0.22,
                          geometry.smoke.count - smokeStart < 4 {
                    let cp = slot.center + tangent * (slot.width * 0.42)
                    let cg = terrain.heightAt(x: cp.x, z: cp.y)
                    if cg > 0.004, !terrain.isWater(x: cp.x, z: cp.y) {
                        let height: Float = 0.0055 + rng.nextFloat() * 0.0025
                        let chimney = translation(SIMD3(cp.x, cg + height * 0.5, cp.y))
                            * scaleMatrix(SIMD3(0.0009, height, 0.0009))
                        geometry.boxes.append(InstanceData(
                            model: chimney,
                            color: SIMD4(SIMD3(0.34, 0.23, 0.19), 0),
                            material: SIMD4(2, 0, 0, 0)))
                        geometry.smoke.append(SIMD3(cp.x, cg + height + 0.0004, cp.y))
                    }
                }
            }

            if setback > 0, rng.nextFloat() < 0.7 {
                // Two low wall segments, leaving a gate opposite the door.
                let tangent = SIMD2<Float>(front.y, -front.x)
                for side in [Float(-1), Float(1)] {
                    let wx = x + tangent.x * side * cell * 0.19
                    let wz = z + tangent.y * side * cell * 0.19
                    let wg = terrain.heightAt(x: wx, z: wz)
                    guard wg > 0.004, !terrain.isWater(x: wx, z: wz) else { continue }
                    let wallModel = translation(SIMD3(wx, wg, wz))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(cell * 0.30, 0.0010, 0.0005))
                    geometry.boxes.append(InstanceData(
                        model: wallModel,
                        color: SIMD4(SIMD3(0.46, 0.43, 0.37), 0),
                        material: SIMD4(2, 0, 0, 0)))
                }
            }
        }

        // Dedicated landmark meshes: temples, churches and docks.
        for landmark in plan.landmarks {
            let g = terrain.heightAt(x: landmark.center.x, z: landmark.center.y)
            guard g > 0.004, !terrain.isWater(x: landmark.center.x, z: landmark.center.y) else {
                continue
            }
            let key: String
            switch landmark.kind {
            case .temple:    key = "__temple"
            case .church:    key = "__church"
            case .cathedral: key = "__cathedral"
            case .dome:      key = "__dome"
            case .dock:      key = "__dock"
            }
            let model = translation(SIMD3(landmark.center.x, g - 0.0003,
                                          landmark.center.y))
                * rotationY(landmark.facing)
                * scaleMatrix(SIMD3(repeating: landmark.scale))
            geometry.buildings[key, default: []].append(InstanceData(
                model: model,
                color: SIMD4(SIMD3(repeating: 1), 0),
                material: SIMD4(0, 0, 0, 0)))

            // Cathedral glass is a separate batch so it can glow at night.
            if landmark.kind == .cathedral {
                geometry.buildings["__cathedral_glass", default: []].append(
                    InstanceData(model: model,
                                 color: SIMD4(SIMD3(repeating: 1), 0),
                                 material: SIMD4(10, 0, 0, 0)))
            }
        }

        if let aqueduct = plan.aqueduct {
            appendAqueduct(aqueduct, width: plan.cell * 0.22,
                           terrain: terrain, into: &geometry)
        }

        if scar > 0.15 {
            appendRubble(s, count: Int(scar * 10), radius: cityRadius(s.population) * 0.9,
                         terrain: terrain, seed: seed, into: &geometry)
        }

        if era.rawValue >= Era.classical.rawValue {
            let ground = terrain.interpolatedHeight(x: s.x, z: s.z)
            if ground > 0.006 {
                appendWell(s, ground: ground, seed: seed, into: &geometry)
                appendPlazaProps(s, era: era, ground: ground, seed: seed, into: &geometry)
            }
        }

        appendFields(s, all: all, era: era, year: year, terrain: terrain, seed: seed, into: &geometry)
        if era.rawValue >= Era.classical.rawValue {
            appendStalls(s, terrain: terrain, seed: seed, into: &geometry)
        }

        if era == .neolithic {
            appendStandingStones(s, terrain: terrain, seed: seed, into: &geometry)
        }

        // Wall circuits enclose whole rings of the historic core; outer
        // rings are left as suburbs. Try progressively smaller cores if the
        // neighbouring town leaves no room.
        var wallLimit = Float.greatestFiniteMagnitude
        for other in all where other.isAlive && other.id != s.id {
            let d = simd_distance(SIMD2(other.x, other.z), SIMD2(s.x, s.z))
            wallLimit = min(wallLimit, d * 0.44)
        }

        var wallCorePlots: [Plot] = []
        var wallCoreRadius: Float = 0
        let candidates = [plan.half - 1, plan.half - 2, plan.half - 3]
            .filter { $0 >= 1 }
        for limit in candidates {
            let plots = plan.plots.filter { $0.ring <= limit }
            guard !plots.isEmpty else { continue }
            let maxDistance = plots.reduce(Float(0)) {
                max($0, simd_distance($1.center, SIMD2(s.x, s.z)))
            }
            let needed = maxDistance + plan.cell * 0.60
            if needed <= wallLimit {
                wallCorePlots = plots
                wallCoreRadius = needed
                break
            }
        }

        // Walls must not overlap a neighbouring town's wall.
        if era == .medieval && s.population > 350 && wallCoreRadius > 0 {
            appendWalls(s, gateAngles: plan.gates, maxRadius: wallLimit,
                        builtRadius: wallCoreRadius, corePlots: wallCorePlots,
                        margin: 1.04, terrain: terrain, seed: seed, into: &geometry)
        } else if era == .bronze && s.population > 450 && wallCoreRadius > 0 {
            appendWalls(s, gateAngles: plan.gates, maxRadius: wallLimit,
                        builtRadius: wallCoreRadius, corePlots: wallCorePlots,
                        margin: 1.04, height: 0.0050,
                        terrain: terrain, seed: seed, into: &geometry)
        } else if era == .classical && s.population > 300 && wallCoreRadius > 0 {
            appendWalls(s, gateAngles: plan.gates, maxRadius: wallLimit,
                        builtRadius: wallCoreRadius, corePlots: wallCorePlots,
                        margin: 1.04, height: 0.0058,
                        terrain: terrain, seed: seed, into: &geometry)
        } else if era == .renaissance && s.population > 260 && wallCoreRadius > 0 {
            appendWalls(s, gateAngles: plan.gates, maxRadius: wallLimit,
                        builtRadius: wallCoreRadius, corePlots: wallCorePlots,
                        margin: 1.04, height: 0.0064,
                        terrain: terrain, seed: seed, into: &geometry)
            appendBastions(s, terrain: terrain, seed: seed, into: &geometry)
        }

        // Bronze Age canal from the gate to fresh water.
        if let water = plan.water {
            appendCanal(water, width: plan.cell * 0.46,
                        terrain: terrain, into: &geometry)
        }

        // Industrial railway corridor.
        if let rail = plan.rail, rail.count >= 2 {
            appendRail(rail, width: plan.cell * 0.55,
                       terrain: terrain, into: &geometry)
        }
    }

    /// Doors, framed windows, stone sills and painted shutters on the street
    /// and garden facades. These replace the shader's painted panes on early
    /// houses, so openings have real depth at close range.
    private static func appendFacadeDetails(x: Float, z: Float, ground: Float,
                                            rotation: Float,
                                            width: Float, depth: Float, height: Float,
                                            front: Float,
                                            wall: SIMD3<Float>,
                                            era: Era,
                                            rng: inout SplitMix64,
                                            into geometry: inout Geometry) {
        let storeys = max(1, Int((height / max(width * 0.72, 0.0001)).rounded()))
        let storeyHeight = height / Float(storeys)
        let halfWidth = width * 0.5
        let halfDepth = depth * 0.5

        func place(_ localX: Float, _ y: Float, _ localZ: Float,
                   _ sx: Float, _ sy: Float, _ sz: Float,
                   _ colour: SIMD3<Float>, emissive: Float = 0,
                   material: Float = 0) {
            let model = translation(SIMD3(x, ground, z))
                * rotationY(rotation)
                * translation(SIMD3(localX, y, localZ))
                * scaleMatrix(SIMD3(max(sx, 0.0004), max(sy, 0.0004), max(sz, 0.0003)))
            geometry.boxes.append(InstanceData(model: model,
                                               color: SIMD4(colour, emissive),
                                               material: SIMD4(material, 0, 0, 0)))
        }

        // A door with a worn stone step and a timber lintel.
        let doorWidth = width * 0.26
        let doorHeight = min(storeyHeight * 0.82, height * 0.76)
        let doorSide: Float = rng.nextFloat() < 0.5 ? -1 : 1
        let doorX = halfWidth * 0.40 * doorSide

        place(doorX, doorHeight * 0.5 + 0.0003, front * (halfDepth + 0.0001),
              doorWidth, doorHeight, 0.0005,
              SIMD3(0.21, 0.14, 0.09))
        place(doorX, 0.0004, front * (halfDepth + 0.0007),
              doorWidth * 1.30, 0.0008, 0.0014,
              wall * 0.88, material: 2)
        place(doorX, doorHeight + 0.0004, front * (halfDepth + 0.0002),
              doorWidth * 1.16, 0.0006, 0.0008,
              SIMD3(0.28, 0.21, 0.14))

        let shutters = rng.nextFloat() < 0.38
        let shutterColour: SIMD3<Float> = era.rawValue >= Era.renaissance.rawValue
            ? SIMD3(0.27, 0.33, 0.30)
            : SIMD3(0.34, 0.27, 0.19)

        for storey in 0..<storeys {
            let centreY = storeyHeight * (Float(storey) + 0.52)
            let windowHeight = storeyHeight * 0.38
            let windowWidth = min(width * 0.27, windowHeight * 0.95)

            let columns: [Float]
            if storey == 0 {
                columns = [-doorX]
            } else if width > 0.009 {
                columns = [-halfWidth * 0.34, halfWidth * 0.34]
            } else {
                columns = [0]
            }

            for facadeSign in [front, -front] {
                let facadeColumns = facadeSign == front ? columns : [0]
                let zSurface = facadeSign * (halfDepth + 0.0001)
                for column in facadeColumns {
                    // The glass sits a hair inside the wall; the sill proud.
                    place(column, centreY, zSurface - facadeSign * 0.0002,
                          windowWidth, windowHeight, 0.0004,
                          SIMD3(0.10, 0.14, 0.18), material: 7)
                    // Glazing bars: a cross of painted timber.
                    place(column, centreY, zSurface - facadeSign * 0.00005,
                          windowWidth * 0.10, windowHeight * 1.0, 0.0005,
                          wall * 1.04)
                    place(column, centreY + windowHeight * 0.12, zSurface - facadeSign * 0.00005,
                          windowWidth * 1.0, windowHeight * 0.09, 0.0005,
                          wall * 1.04)
                    place(column, centreY - windowHeight * 0.5 - 0.0003, zSurface,
                          windowWidth * 1.22, 0.0005, 0.0010,
                          wall * 0.92, material: 2)
                    if shutters {
                        for side in [Float(-1), Float(1)] {
                            place(column + side * windowWidth * 0.74, centreY, zSurface,
                                  windowWidth * 0.40, windowHeight * 1.04, 0.0004,
                                  shutterColour)
                        }
                    }
                }
            }
        }
    }

    /// A stone well with posts and a little tiled roof.
    private static func appendWell(_ s: Settlement,
                                   ground: Float,
                                   seed: UInt64,
                                   into geometry: inout Geometry) {
        let radius = max(cityRadius(s.population) * 0.055, 0.0010)
        let stone = SIMD3<Float>(0.43, 0.41, 0.37)
        let timber = SIMD3<Float>(0.30, 0.24, 0.17)

        func box(_ localX: Float, _ y: Float, _ localZ: Float,
                 _ sx: Float, _ sy: Float, _ sz: Float,
                 _ colour: SIMD3<Float>, material: Float = 0) {
            let model = translation(SIMD3(s.x + localX, ground + y, s.z + localZ))
                * scaleMatrix(SIMD3(max(sx, 0.0003), max(sy, 0.0003), max(sz, 0.0003)))
            geometry.boxes.append(InstanceData(model: model,
                                               color: SIMD4(colour, 0),
                                               material: SIMD4(material, 0, 0, 0)))
        }

        // Square stone kerb.
        let wall = radius * 0.34
        for side in [Float(-1), Float(1)] {
            box(0, 0.0009, side * (radius - wall * 0.5),
                radius * 2.0, 0.0018, wall, stone, material: 2)
            box(side * (radius - wall * 0.5), 0.0009, 0,
                wall, 0.0018, radius * 2.0, stone, material: 2)
        }

        // Two posts and a tiny gable roof.
        let postHeight = radius * 2.6
        for side in [Float(-1), Float(1)] {
            box(side * radius * 0.78, postHeight * 0.5, 0,
                radius * 0.16, postHeight, radius * 0.16, timber)
        }
        let roofModel = translation(SIMD3(s.x, ground + postHeight, s.z))
            * rotationY(0.6)
            * scaleMatrix(SIMD3(radius * 2.2, radius * 1.1, radius * 2.2))
        geometry.cones.append(InstanceData(model: roofModel,
                                           color: SIMD4(SIMD3(0.36, 0.24, 0.16), 0),
                                           material: SIMD4(3, 0, 0, 0)))

        // The rope hanging under the roof.
        box(0, postHeight * 0.55, 0,
            radius * 0.10, postHeight * 0.55, radius * 0.10,
            SIMD3(0.20, 0.17, 0.13))
    }

    /// Era-specific furniture around the plaza: a fountain, market cross,
    /// bollards or planters. Small silhouettes, but they give the square a
    /// reason to exist beyond the well.
    private static func appendPlazaProps(_ s: Settlement,
                                         era: Era,
                                         ground: Float,
                                         seed: UInt64,
                                         into geometry: inout Geometry) {
        let r = max(cityRadius(s.population) * 0.30, 0.006)
        let stone = SIMD3<Float>(0.54, 0.52, 0.47)
        let dark = SIMD3<Float>(0.30, 0.28, 0.25)

        func box(_ x: Float, _ z: Float, _ y: Float,
                 _ sx: Float, _ sy: Float, _ sz: Float,
                 _ colour: SIMD3<Float>, material: Float = 0) {
            let model = translation(SIMD3(x, ground + y, z))
                * scaleMatrix(SIMD3(max(sx, 0.0002), max(sy, 0.0002), max(sz, 0.0002)))
            geometry.boxes.append(InstanceData(model: model,
                                               color: SIMD4(colour, 0),
                                               material: SIMD4(material, 0, 0, 0)))
        }

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0xD6E8_FEB8_6659_FD93)
                             ^ 0x71A2_9C4D)

        switch era {
        case .classical, .renaissance:
            // Fountain: basin, water, column and a small figure.
            let fx = s.x + r * 0.55, fz = s.z + r * 0.15
            let size = r * 0.55
            box(fx, fz, 0.0008, size * 2.0, 0.0016, size * 2.0, stone, material: 2)
            box(fx, fz, 0.0018, size * 1.70, 0.0004, size * 1.70,
                SIMD3(0.20, 0.36, 0.46))
            box(fx, fz, 0.0036, size * 0.20, 0.0036, size * 0.20, stone, material: 2)
            let statue = translation(SIMD3(fx, ground + 0.0054, fz))
                * scaleMatrix(SIMD3(size * 0.30, size * 0.55, size * 0.30))
            geometry.cones.append(InstanceData(model: statue,
                                               color: SIMD4(stone * 1.05, 0),
                                               material: SIMD4(2, 0, 0, 0)))
            // A pair of stone benches.
            for side in [Float(-1), Float(1)] {
                box(fx + side * r * 0.9, fz + r * 0.55, 0.0009,
                    r * 0.55, 0.0018, r * 0.22, stone, material: 2)
            }

        case .neolithic:
            // A few standing stones at the edge of the square.
            for i in 0..<4 {
                let a = Float(i) / 4 * 2 * Float.pi + 0.4
                let px = s.x + cos(a) * r * 0.85
                let pz = s.z + sin(a) * r * 0.85
                box(px, pz, 0.0016, 0.0010, 0.0032, 0.0008, stone, material: 2)
            }

        case .bronze:
            // A small stone ring with a fire pit in the middle.
            let cx = s.x + r * 0.60, cz = s.z - r * 0.30
            for i in 0..<7 {
                let a = Float(i) / 7 * 2 * Float.pi
                let px = cx + cos(a) * r * 0.40
                let pz = cz + sin(a) * r * 0.40
                box(px, pz, 0.0016, 0.0010, 0.0032, 0.0008, stone, material: 2)
            }
            box(cx, cz, 0.0003, 0.0022, 0.0006, 0.0022, dark)
            box(cx, cz, 0.0007, 0.0012, 0.0008, 0.0012,
                SIMD3(0.20, 0.18, 0.16))

        case .medieval:
            // Market cross: three steps, a shaft and a cross.
            let cx = s.x - r * 0.55, cz = s.z - r * 0.10
            for i in 0..<3 {
                let inset = Float(i) * 0.0012
                box(cx, cz, 0.0006 + Float(i) * 0.0012,
                    r * (0.75 - inset * 60), 0.0012, r * (0.75 - inset * 60),
                    stone, material: 2)
            }
            let shaftH: Float = 0.0042
            box(cx, cz, 0.0040 + shaftH * 0.5, 0.0007, shaftH, 0.0007, stone, material: 2)
            box(cx, cz, 0.0040 + shaftH + 0.0003, 0.0026, 0.0005, 0.0005, stone, material: 2)
            box(cx, cz, 0.0040 + shaftH + 0.0007, 0.0005, 0.0014, 0.0005, stone, material: 2)
            // Two benches facing it.
            for side in [Float(-1), Float(1)] {
                box(cx + side * r * 0.85, cz + r * 0.5, 0.0008,
                    r * 0.5, 0.0016, r * 0.20, dark, material: 2)
            }

        case .industrial:
            // Bollards ringing the square, plus benches and a lamp standard.
            for i in 0..<10 {
                let a = Float(i) / 10 * 2 * Float.pi
                let bx = s.x + cos(a) * r * 1.05
                let bz = s.z + sin(a) * r * 1.05
                box(bx, bz, 0.0010, 0.0007, 0.0020, 0.0007, dark, material: 2)
                box(bx, bz, 0.0021, 0.0009, 0.0003, 0.0009,
                    SIMD3(0.62, 0.58, 0.50), material: 2)
            }
            for side in [Float(-1), Float(1)] {
                box(s.x + side * r * 0.85, s.z + r * 0.45, 0.0009,
                    r * 0.55, 0.0018, r * 0.22, dark)
            }
            let lampX = s.x + r * 0.15, lampZ = s.z - r * 0.85
            box(lampX, lampZ, 0.0022, 0.00035, 0.0044, 0.00035, dark, material: 2)
            box(lampX, lampZ, 0.0046, 0.0010, 0.0010, 0.0010,
                SIMD3(1.0, 0.85, 0.55), material: 0)

        case .modern, .information, .future:
            // Planters and benches, plus a small bus shelter.
            for i in 0..<4 {
                let a = Float(i) / 4 * 2 * Float.pi + 0.4
                let px = s.x + cos(a) * r * 0.95
                let pz = s.z + sin(a) * r * 0.95
                box(px, pz, 0.0010, 0.0018, 0.0020, 0.0018,
                    SIMD3(0.52, 0.51, 0.49), material: 2)
                box(px, pz, 0.0021, 0.0016, 0.0004, 0.0016,
                    SIMD3(0.24, 0.36, 0.20))
            }
            for side in [Float(-1), Float(1)] {
                box(s.x + side * r * 0.80, s.z + r * 0.5, 0.0009,
                    r * 0.55, 0.0018, r * 0.22, dark)
            }
            let sx = s.x - r * 0.95, sz = s.z + r * 0.15
            for dx in [Float(-1), Float(1)] {
                for dz in [Float(-1), Float(1)] {
                    box(sx + dx * 0.9, sz + dz * 0.35, 0.0015,
                        0.0004, 0.0030, 0.0004, dark, material: 2)
                }
            }
            box(sx, sz, 0.0031, 0.0020, 0.0004, 0.0010,
                SIMD3(0.58, 0.58, 0.56), material: 2)
            box(sx, sz + 0.35, 0.0017, 0.0019, 0.0024, 0.0003,
                SIMD3(0.30, 0.40, 0.48))

        default:
            break
        }
    }

    /// A few market stalls near the centre: counter, posts and a coloured awning.
    private static func appendStalls(_ s: Settlement,
                                     terrain: Terrain,
                                     seed: UInt64,
                                     into geometry: inout Geometry) {
        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x9E37_79B9_7F4A_7C15)
                             ^ 0x51A1_7E3D)
        let count = 2 + Int(rng.nextFloat() * 2)
        let radius = cityRadius(s.population)
        let awnings: [SIMD3<Float>] = [
            SIMD3(0.62, 0.20, 0.18), SIMD3(0.72, 0.62, 0.40), SIMD3(0.25, 0.35, 0.52)
        ]

        for _ in 0..<count {
            let angle = rng.nextFloat(in: 0...(2 * Float.pi))
            let distance = radius * (0.34 + rng.nextFloat() * 0.22)
            let x = s.x + cos(angle) * distance
            let z = s.z + sin(angle) * distance
            let ground = terrain.interpolatedHeight(x: x, z: z)
            guard ground > 0.006, !terrain.isWater(x: x, z: z) else { continue }

            let rotation = rng.nextFloat(in: 0...(2 * Float.pi))
            let width: Float = 0.006
            let depth: Float = 0.004

            let counter = translation(SIMD3(x, ground + 0.0012, z))
                * rotationY(rotation)
                * scaleMatrix(SIMD3(width, 0.0024, depth))
            geometry.boxes.append(InstanceData(model: counter,
                                               color: SIMD4(SIMD3(0.42, 0.32, 0.22), 0),
                                               material: SIMD4(1, 0, 0, 0)))

            let awning = translation(SIMD3(x, ground + 0.0042, z))
                * rotationY(rotation)
                * scaleMatrix(SIMD3(width * 1.2, 0.0006, depth * 1.3))
            let awningColour = awnings[Int(rng.nextFloat() * Float(awnings.count)) % awnings.count]
            geometry.boxes.append(InstanceData(model: awning,
                                               color: SIMD4(awningColour, 0)))

            for sx in [Float(-1), Float(1)] {
                for sz in [Float(-1), Float(1)] {
                    let px = x + cos(rotation) * sx * width * 0.45 + sin(rotation) * sz * depth * 0.4
                    let pz = z - sin(rotation) * sx * width * 0.45 + cos(rotation) * sz * depth * 0.4
                    let post = translation(SIMD3(px, ground + 0.0021, pz))
                        * scaleMatrix(SIMD3(0.0003, 0.0042, 0.0003))
                    geometry.boxes.append(InstanceData(model: post,
                                                       color: SIMD4(SIMD3(0.30, 0.24, 0.16), 0)))
                }
            }

            // A crate or two of produce beside the counter.
            for crate in 0..<2 {
                let crateOffset = (Float(crate) - 0.5) * width * 1.5
                let cx = x + cos(rotation) * crateOffset - sin(rotation) * depth * 0.85
                let cz = z - sin(rotation) * crateOffset - cos(rotation) * depth * 0.85
                let crateModel = translation(SIMD3(cx, ground + 0.0010, cz))
                    * rotationY(rotation + Float(crate) * 0.4)
                    * scaleMatrix(SIMD3(0.0016, 0.0020, 0.0016))
                geometry.boxes.append(InstanceData(model: crateModel,
                                                   color: SIMD4(SIMD3(0.46, 0.35, 0.21), 0)))
            }
        }
    }

    /// Street polylines along the grid lines, split into runs of dry land so
    /// the ribbon never runs out over the water.
    private static func appendStreetLines(_ s: Settlement,
                                          angle: Float,
                                          plazaRadius: Float = 0,
                                          cell: Float,
                                          radius: Float,
                                          terrain: Terrain,
                                          river: RiverChannel.Field?,
                                          into lines: inout [StreetLine]) {
        let dir = SIMD2<Float>(cos(angle), sin(angle))
        let perp = SIMD2<Float>(-sin(angle), cos(angle))
        let half = max(Int(ceil(radius / cell)), 2)
        let steps = 12
        let width = max(cell * 0.23, 0.0022)

        for line in -half...half {
            let offset = Float(line) * cell
            let run = sqrt(max(radius * radius - offset * offset, 0)) + cell * 0.22
            guard run > cell * 0.4 else { continue }

            for axis in 0..<2 {
                var current: [SIMD2<Float>] = []
                for i in 0...steps {
                    let t = -run + run * 2 * Float(i) / Float(steps)
                    let lx = axis == 0 ? t : offset
                    let lz = axis == 0 ? offset : t
                    let x = s.x + dir.x * lx + perp.x * lz
                    let z = s.z + dir.y * lx + perp.y * lz
                    let ground = terrain.interpolatedHeight(x: x, z: z)

                    let inPlaza = plazaRadius > 0
                        && simd_distance(SIMD2(x, z), SIMD2(s.x, s.z)) < plazaRadius
                    if ground <= 0.006 || terrain.isWater(x: x, z: z)
                        || inPlaza || nearRiver(SIMD2(x, z), river)
                        || !connected(SIMD2(x, z), to: SIMD2(s.x, s.z),
                                      river: river) {
                        if current.count >= 2 {
                            lines.append(StreetLine(points: current, width: width))
                        }
                        current.removeAll(keepingCapacity: true)
                    } else {
                        current.append(SIMD2(x, z))
                    }
                }
                if current.count >= 2 {
                    lines.append(StreetLine(points: current, width: width))
                }
            }
        }
    }

    /// Projecting bastions on the Renaissance wall trace.
    private static func appendBastions(_ s: Settlement,
                                       terrain: Terrain,
                                       seed: UInt64,
                                       into geometry: inout Geometry) {
        let radius = cityRadius(max(s.population, 1)) * 1.06
        guard radius > 0.024 else { return }
        let stone = SIMD3<Float>(0.60, 0.57, 0.50)
        for k in stride(from: 0, to: 24, by: 3) {
            let a = Float(k) / 24 * 2 * Float.pi
            let p = SIMD2(s.x + cos(a) * radius, s.z + sin(a) * radius)
            let g = terrain.heightAt(x: p.x, z: p.y)
            guard g > 0.006, !terrain.isWater(x: p.x, z: p.y) else { continue }
            let model = translation(SIMD3(p.x, g + 0.0035, p.y))
                * rotationY(-a)
                * scaleMatrix(SIMD3(0.0044, 0.0070, 0.0044))
            geometry.boxes.append(InstanceData(
                model: model, color: SIMD4(stone, 0),
                material: SIMD4(2, 0, 0, 0)))
        }
    }

    /// A small ring of standing stones on the highest ground near a hamlet.
    private static func appendStandingStones(_ s: Settlement,
                                             terrain: Terrain,
                                             seed: UInt64,
                                             into geometry: inout Geometry) {
        let radius = cityRadius(max(s.population, 1))
        var best = SIMD2<Float>(s.x, s.z)
        var bestHeight = terrain.heightAt(x: s.x, z: s.z)
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * Float.pi
            let p = SIMD2(s.x + cos(a) * radius * 0.72,
                          s.z + sin(a) * radius * 0.72)
            let h = terrain.heightAt(x: p.x, z: p.y)
            if h > bestHeight { bestHeight = h; best = p }
        }
        guard bestHeight > 0.004, !terrain.isWater(x: best.x, z: best.y) else { return }

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x51A7_3E1D))
        let stone = SIMD3<Float>(0.52, 0.50, 0.45)
        for k in 0..<4 {
            let a = Float(k) / 4 * 2 * Float.pi + 0.3
            let p = SIMD2(best.x + cos(a) * radius * 0.10,
                          best.y + sin(a) * radius * 0.10)
            let g = terrain.heightAt(x: p.x, z: p.y)
            guard g > 0.004 else { continue }
            let height = radius * rng.nextFloat(in: 0.20...0.30)
            let model = translation(SIMD3(p.x, g + height * 0.5, p.y))
                * rotationY(rng.nextFloat(in: 0...Float.pi))
                * scaleMatrix(SIMD3(radius * 0.055, height, radius * 0.045))
            geometry.boxes.append(InstanceData(
                model: model, color: SIMD4(stone, 0),
                material: SIMD4(2, 0, 0, 0)))
        }
    }

    /// A Roman aqueduct: a stone channel carried on an arcade of piers.
    /// The route is resampled into short spans so each gap reads as an arch.
    private static func appendAqueduct(_ points: [SIMD2<Float>],
                                       width: Float,
                                       terrain: Terrain,
                                       into geometry: inout Geometry) {
        guard points.count >= 2 else { return }
        let stone = SIMD3<Float>(0.68, 0.65, 0.58)

        // Resample the polyline evenly.
        let span = max(width * 12, 0.010)
        var samples: [SIMD2<Float>] = [points[0]]
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let steps = max(Int(simd_length(b - a) / span), 1)
            for step in 1...steps {
                samples.append(a + (b - a) * (Float(step) / Float(steps)))
            }
        }

        for i in 0..<(samples.count - 1) {
            let a = samples[i], b = samples[i + 1]
            let mid = (a + b) * 0.5
            let hA = terrain.interpolatedHeight(x: a.x, z: a.y)
            let hB = terrain.interpolatedHeight(x: b.x, z: b.y)
            let hM = terrain.interpolatedHeight(x: mid.x, z: mid.y)
            guard hA > 0.004, hB > 0.004, hM > 0.004 else { continue }

            let deck = max(hA, max(hB, hM)) + 0.0050
            let dir = b - a
            let length = simd_length(dir)
            guard length > 1e-6 else { continue }
            let heading = atan2(dir.x, dir.y)

            // Pier at the start of each span.
            for p in [a] {
                let g = terrain.interpolatedHeight(x: p.x, z: p.y)
                let height = deck - g
                guard height > 0.0005 else { continue }
                let pier = translation(SIMD3(p.x, g + height * 0.5, p.y))
                    * rotationY(heading)
                    * scaleMatrix(SIMD3(width * 0.55, height, width * 0.55))
                geometry.boxes.append(InstanceData(
                    model: pier, color: SIMD4(stone * 0.92, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            // Semicircular arch ring between the piers.
            let maxGround = max(hA, max(hB, hM))
            let radius = min(length * 0.5, deck - 0.0006 - (maxGround + 0.0006))
            if radius > length * 0.10 {
                let springing = deck - 0.0006 - radius
                let arch = translation(SIMD3(mid.x, springing, mid.y))
                    * rotationY(heading)
                    * scaleMatrix(SIMD3(width * 1.10, radius, radius))
                geometry.arches.append(InstanceData(
                    model: arch, color: SIMD4(stone, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            // Channel and the water it carries.
            let channel = translation(SIMD3(mid.x, deck, mid.y))
                * rotationY(heading)
                * scaleMatrix(SIMD3(width * 1.35, 0.0014, length * 1.04))
            geometry.boxes.append(InstanceData(
                model: channel, color: SIMD4(stone, 0),
                material: SIMD4(2, 0, 0, 0)))
            let water = translation(SIMD3(mid.x, deck + 0.0005, mid.y))
                * rotationY(heading)
                * scaleMatrix(SIMD3(width * 0.68, 0.0005, length * 1.03))
            geometry.boxes.append(InstanceData(
                model: water, color: SIMD4(SIMD3(0.18, 0.32, 0.42), 0)))
        }

        // Final pier.
        if let last = samples.last {
            let g = terrain.interpolatedHeight(x: last.x, z: last.y)
            let h = terrain.interpolatedHeight(x: samples[samples.count - 2].x,
                                               z: samples[samples.count - 2].y)
            let deck = max(g, h) + 0.0015
            let height = deck - g
            if height > 0.0005, g > 0.004 {
                let pier = translation(SIMD3(last.x, g + height * 0.5, last.y))
                    * scaleMatrix(SIMD3(width * 0.55, height, width * 0.55))
                geometry.boxes.append(InstanceData(
                    model: pier, color: SIMD4(stone * 0.92, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }
        }
    }

    /// A railway ribbon with sleepers, laid on the ground.
    private static func appendRail(_ points: [SIMD2<Float>],
                                   width: Float,
                                   terrain: Terrain,
                                   into geometry: inout Geometry) {
        guard points.count >= 2 else { return }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let mid = (a + b) * 0.5
            let ground = terrain.interpolatedHeight(x: mid.x, z: mid.y)
            guard ground > 0.004, !terrain.isWater(x: mid.x, z: mid.y) else { continue }
            let dir = b - a
            let length = simd_length(dir)
            guard length > 1e-6 else { continue }
            let model = translation(SIMD3(mid.x, ground + 0.0011, mid.y))
                * rotationY(atan2(dir.x, dir.y))
                * scaleMatrix(SIMD3(width, 0.0007, length * 1.01))
            geometry.boxes.append(InstanceData(
                model: model,
                color: SIMD4(SIMD3(0.24, 0.21, 0.18), 0)))
            // Rails.
            for side in [Float(-1), Float(1)] {
                let offset = SIMD2(-dir.y, dir.x) / length * width * 0.28
                let rp = mid + offset * side
                let rail = translation(SIMD3(rp.x, ground + 0.0016, rp.y))
                    * rotationY(atan2(dir.x, dir.y))
                    * scaleMatrix(SIMD3(width * 0.10, 0.0008, length * 1.01))
                geometry.boxes.append(InstanceData(
                    model: rail,
                    color: SIMD4(SIMD3(0.55, 0.53, 0.50), 0)))
            }
        }
    }

    /// A canal or aqueduct ribbon, laid on the ground.
    private static func appendCanal(_ points: [SIMD2<Float>],
                                    width: Float,
                                    terrain: Terrain,
                                    into geometry: inout Geometry) {
        guard points.count >= 2 else { return }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let mid = (a + b) * 0.5
            let ground = terrain.interpolatedHeight(x: mid.x, z: mid.y)
            guard ground > 0.004, !terrain.isWater(x: mid.x, z: mid.y) else { continue }
            let dir = b - a
            let length = simd_length(dir)
            guard length > 1e-6 else { continue }
            let model = translation(SIMD3(mid.x, ground + 0.0018, mid.y))
                * rotationY(atan2(dir.x, dir.y))
                * scaleMatrix(SIMD3(width, 0.0009, length * 1.02))
            geometry.boxes.append(InstanceData(
                model: model,
                color: SIMD4(SIMD3(0.16, 0.31, 0.40), 0)))
        }
    }

    /// Street ribbons generated by a settlement plan. Each road segment is
    /// clipped where it crosses water so a lane never runs into the sea.
    /// True when a point is on the rendered river surface or its dry margin.
    /// The simulation raster is a few metres narrower than the smoothed water
    /// mesh, so streets must be cut against the same field the water uses.
    private static func nearRiver(_ p: SIMD2<Float>,
                                  _ river: RiverChannel.Field?) -> Bool {
        guard let surface = river?.surface(at: p) else { return false }
        return surface.distance < 2.0 / RiverChannel.metresPerUnit
    }

    /// True when the straight line from the town centre to a point never
    /// crosses the rendered river. Towns grow on one bank; only the road
    /// network should bridge the water, not every parallel street.
    private static func connected(_ p: SIMD2<Float>,
                                  to centre: SIMD2<Float>,
                                  river: RiverChannel.Field?) -> Bool {
        guard let river else { return true }
        let steps = 20
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let q = centre + (p - centre) * t
            if river.waterLevel(at: q) != nil { return false }
        }
        return true
    }

    private static func appendRoadLines(_ plan: SettlementPlan,
                                        centre: SIMD2<Float>,
                                        terrain: Terrain,
                                        river: RiverChannel.Field?,
                                        into lines: inout [StreetLine]) {
        for road in plan.roads where road.roadClass <= 2 {
            let steps = max(Int(road.length / max(plan.cell * 0.5, 0.0005)), 1)
            var current: [SIMD2<Float>] = []
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let p = road.a + (road.b - road.a) * t
                let ground = terrain.interpolatedHeight(x: p.x, z: p.y)
                if ground <= 0.006 || terrain.isWater(x: p.x, z: p.y)
                    || nearRiver(p, river)
                    || !connected(p, to: centre, river: river) {
                    if current.count >= 2 {
                        lines.append(StreetLine(points: current, width: road.width))
                    }
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(p)
                }
            }
            if current.count >= 2 {
                lines.append(StreetLine(points: current, width: road.width))
            }
        }
    }

    /// Rubble piles left behind by a disaster or an abandoned town.
    private static func appendRubble(_ s: Settlement,
                                     count: Int,
                                     radius: Float,
                                     terrain: Terrain,
                                     seed: UInt64,
                                     into geometry: inout Geometry) {
        guard count > 0, radius > 0 else { return }

        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x94D0_49BB_1331_11EB)
                             ^ 0xBEEF)

        for _ in 0..<count {
            let angle = rng.nextFloat(in: 0...(2 * .pi))
            let distance = radius * sqrt(rng.nextFloat())
            let x = s.x + cos(angle) * distance
            let z = s.z + sin(angle) * distance

            let ground = terrain.interpolatedHeight(x: x, z: z)
            guard ground > 0.006, !terrain.isWater(x: x, z: z) else { continue }

            let height = 0.0015 + rng.nextFloat() * 0.0040
            let width = 0.0018 + rng.nextFloat() * 0.0035
            let depth = 0.0018 + rng.nextFloat() * 0.0035
            let model = translation(SIMD3(x, ground + height * 0.5, z))
                * rotationY(rng.nextFloat(in: 0...(2 * .pi)))
                * scaleMatrix(SIMD3(width, height, depth))
            let shade = 0.22 + rng.nextFloat() * 0.14
            geometry.boxes.append(InstanceData(model: model,
                                               color: SIMD4(SIMD3(shade, shade * 0.92, shade * 0.82), 0)))
        }
    }

    /// An abandoned settlement becomes a scorched patch with broken walls.
    private static func appendRuins(_ s: Settlement,
                                    terrain: Terrain,
                                    seed: UInt64,
                                    into geometry: inout Geometry) {
        let population = max(s.population, 80)
        let radius = cityRadius(population) * 1.15

        let era = Era.at(max(s.abandoned, s.founded))
        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x94D0_49BB_1331_11EB)
                             ^ 0xA11C_E5)

        let ground = terrain.interpolatedHeight(x: s.x, z: s.z)
        if ground > 0.006 {
            let patch = translation(SIMD3(s.x, ground + 0.0002, s.z))
                * scaleMatrix(SIMD3(radius * 1.25, 0.0004, radius * 1.25))
            geometry.boxes.append(InstanceData(model: patch,
                                               color: SIMD4(SIMD3(0.24, 0.21, 0.16), 0)))
        }

        let stone = era.rawValue >= Era.industrial.rawValue
            ? SIMD3<Float>(0.44, 0.41, 0.38)
            : SIMD3<Float>(0.56, 0.53, 0.46)
        let charred = SIMD3<Float>(0.24, 0.19, 0.15)

        // Standing fragments of walls, tallest near the centre.
        let fragments = min(2 + Int(radius * 45), 5)
        for k in 0..<fragments {
            let a = Float(k) / Float(fragments) * 2 * Float.pi
                + rng.nextFloat(in: -0.35...0.35)
            let d = radius * rng.nextFloat(in: 0.18...0.82)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard g > 0.006, !terrain.isWater(x: p.x, z: p.y) else { continue }
            let length = radius * rng.nextFloat(in: 0.22...0.46)
            let height = radius * rng.nextFloat(in: 0.10...0.26)
            let model = translation(SIMD3(p.x, g + height * 0.5, p.y))
                * rotationY(rng.nextFloat(in: 0...Float.pi))
                * rotationZ(rng.nextFloat(in: -0.10...0.10))
                * scaleMatrix(SIMD3(radius * 0.045, height, length))
            geometry.boxes.append(InstanceData(
                model: model,
                color: SIMD4(rng.nextFloat() < 0.30 ? charred : stone, 0),
                material: SIMD4(2, 0, 0, 0)))
        }

        // Hollow building shells: three walls, a floor and a sagging roof.
        let shells = min(2 + Int(radius * 50), 4)
        for _ in 0..<shells {
            let a = rng.nextFloat(in: 0...(2 * .pi))
            let d = radius * rng.nextFloat(in: 0.15...0.62)
            let c = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: c.x, z: c.y)
            guard g > 0.006, !terrain.isWater(x: c.x, z: c.y) else { continue }

            let rot = rng.nextFloat(in: 0...(Float.pi))
            let dir = SIMD2<Float>(cos(rot), sin(rot))
            let perp = SIMD2<Float>(-sin(rot), cos(rot))
            let w = radius * rng.nextFloat(in: 0.34...0.58)
            let dpt = radius * rng.nextFloat(in: 0.28...0.48)
            let wallH = radius * rng.nextFloat(in: 0.10...0.22)

            // Floor.
            let floor = translation(SIMD3(c.x, g + 0.0003, c.y))
                * rotationY(rot)
                * scaleMatrix(SIMD3(w, 0.0006, dpt))
            geometry.boxes.append(InstanceData(
                model: floor, color: SIMD4(stone * 0.70, 0),
                material: SIMD4(2, 0, 0, 0)))

            // Three walls, leaving one side open.
            let openSide = rng.nextInt(4)
            for side in 0..<4 {
                if side == openSide { continue }
                let along = side < 2
                let length = along ? w : dpt
                let offset = (side % 2 == 0 ? -1 : 1) * (along ? dpt : w) * 0.5
                let base = c + (along ? perp : dir) * offset
                let height = wallH * rng.nextFloat(in: 0.55...1.0)
                let model = translation(SIMD3(base.x, g + height * 0.5, base.y))
                    * rotationY(rot)
                    * scaleMatrix(SIMD3(radius * 0.035, height,
                                        length * 0.5))
                geometry.boxes.append(InstanceData(
                    model: model, color: SIMD4(stone, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            // Interior partition with a doorway, so the shell reads as rooms.
            let partition = c + dir * (rng.nextFloat(in: -0.18...0.18) * w)
            let segLength = dpt * 0.30
            for side in [Float(-1), Float(1)] {
                let base = partition + perp * (side * (segLength * 0.5 + dpt * 0.13))
                let height = wallH * rng.nextFloat(in: 0.45...0.80)
                let wall = translation(SIMD3(base.x, g + height * 0.5, base.y))
                    * rotationY(rot)
                    * scaleMatrix(SIMD3(radius * 0.026, height, segLength))
                geometry.boxes.append(InstanceData(
                    model: wall, color: SIMD4(stone * 0.92, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            // Rubble heaped inside the shell.
            for _ in 0..<3 {
                let rp = c + dir * (rng.nextFloat(in: -0.35...0.35) * w)
                    + perp * (rng.nextFloat(in: -0.35...0.35) * dpt)
                let rg = terrain.interpolatedHeight(x: rp.x, z: rp.y)
                guard rg > 0.006 else { continue }
                let chunk = translation(SIMD3(rp.x, rg + 0.0007, rp.y))
                    * rotationY(rng.nextFloat(in: 0...Float.pi))
                    * scaleMatrix(SIMD3(radius * rng.nextFloat(in: 0.04...0.09),
                                        0.0012,
                                        radius * rng.nextFloat(in: 0.04...0.09)))
                geometry.boxes.append(InstanceData(
                    model: chunk, color: SIMD4(stone * 0.80, 0),
                    material: SIMD4(2, 0, 0, 0)))
            }

            // Furniture-scale debris: a toppled table, a chair and potsherds.
            if radius > 0.036 {
                let fp = c + dir * (rng.nextFloat(in: -0.25...0.25) * w)
                    + perp * (rng.nextFloat(in: -0.2...0.2) * dpt)
                let fg = terrain.interpolatedHeight(x: fp.x, z: fp.y)
                if fg > 0.006, !terrain.isWater(x: fp.x, z: fp.y) {
                    let tilt = rng.nextFloat(in: -0.5...0.5)
                    let top = translation(SIMD3(fp.x, fg + 0.0009, fp.y))
                        * rotationY(rot + tilt)
                        * rotationZ(rng.nextFloat(in: 0.08...0.20))
                        * scaleMatrix(SIMD3(0.0020, 0.00018, 0.0010))
                    geometry.boxes.append(InstanceData(
                        model: top, color: SIMD4(SIMD3(0.30, 0.22, 0.15), 0)))
                    for (dx, dz) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
                        let lp = fp + dir * (Float(dx) * 0.0007)
                            + perp * (Float(dz) * 0.00035)
                        let lg = terrain.interpolatedHeight(x: lp.x, z: lp.y)
                        guard lg > 0.006 else { continue }
                        let leg = translation(SIMD3(lp.x, lg + 0.0004, lp.y))
                            * scaleMatrix(SIMD3(0.00016, 0.0008, 0.00016))
                        geometry.boxes.append(InstanceData(
                            model: leg, color: SIMD4(SIMD3(0.26, 0.19, 0.13), 0)))
                    }

                    // An overturned chair and a scatter of pot shards.
                    let cp = fp + dir * 0.0018 + perp * 0.0011
                    let cg = terrain.interpolatedHeight(x: cp.x, z: cp.y)
                    if cg > 0.006 {
                        let seat = translation(SIMD3(cp.x, cg + 0.0004, cp.y))
                            * rotationY(rot - 0.3)
                            * rotationZ(0.35)
                            * scaleMatrix(SIMD3(0.0007, 0.0005, 0.0006))
                        geometry.boxes.append(InstanceData(
                            model: seat, color: SIMD4(SIMD3(0.28, 0.20, 0.14), 0)))
                        let back = translation(SIMD3(cp.x - 0.0005, cg + 0.0007, cp.y))
                            * rotationY(rot - 0.3)
                            * rotationZ(0.35)
                            * scaleMatrix(SIMD3(0.00012, 0.0007, 0.00055))
                        geometry.boxes.append(InstanceData(
                            model: back, color: SIMD4(SIMD3(0.26, 0.19, 0.13), 0)))
                    }
                    for _ in 0..<4 {
                        let sp = fp + dir * (rng.nextFloat(in: -0.003...0.003))
                            + perp * (rng.nextFloat(in: -0.003...0.003))
                        let sg = terrain.interpolatedHeight(x: sp.x, z: sp.y)
                        guard sg > 0.006 else { continue }
                        let shard = translation(SIMD3(sp.x, sg + 0.0002, sp.y))
                            * rotationY(rng.nextFloat(in: 0...Float.pi))
                            * scaleMatrix(SIMD3(0.00035, 0.00025, 0.00018))
                        geometry.boxes.append(InstanceData(
                            model: shard, color: SIMD4(SIMD3(0.52, 0.31, 0.20), 0)))
                    }
                }
            }

            // Sagging roof plane and a fallen rafter.
            let roof = translation(SIMD3(c.x, g + wallH * 0.52, c.y))
                * rotationY(rot)
                * rotationZ(rng.nextFloat(in: 0.22...0.42))
                * scaleMatrix(SIMD3(w * 0.80, wallH * 1.00, dpt * 0.80))
            geometry.gables.append(InstanceData(
                model: roof,
                color: SIMD4(era.rawValue >= Era.industrial.rawValue
                             ? SIMD3<Float>(0.27, 0.28, 0.30)
                             : SIMD3<Float>(0.32, 0.21, 0.17), 0),
                material: SIMD4(0, 0, 0, 0)))

            for _ in 0..<2 {
                let rp = c + dir * (rng.nextFloat(in: -0.4...0.4) * w)
                let rg = terrain.interpolatedHeight(x: rp.x, z: rp.y)
                guard rg > 0.006 else { continue }
                let rafter = translation(SIMD3(rp.x, rg + 0.0005, rp.y))
                    * rotationY(rot + rng.nextFloat(in: -0.5...0.5))
                    * rotationZ(rng.nextFloat(in: 0.15...0.35))
                    * scaleMatrix(SIMD3(radius * 0.018, 0.0006, radius * 0.30))
                geometry.boxes.append(InstanceData(
                    model: rafter, color: SIMD4(charred, 0)))
            }
        }

        // Charred roof beams lying in the rubble.
        for _ in 0..<3 {
            let a = rng.nextFloat(in: 0...(2 * .pi))
            let d = radius * rng.nextFloat(in: 0.1...0.7)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard g > 0.006 else { continue }
            let beam = translation(SIMD3(p.x, g + 0.0006, p.y))
                * rotationY(rng.nextFloat(in: 0...(Float.pi)))
                * scaleMatrix(SIMD3(radius * 0.020, 0.0006, radius * rng.nextFloat(in: 0.25...0.45)))
            geometry.boxes.append(InstanceData(model: beam,
                                               color: SIMD4(charred, 0)))
        }

        // Industrial and later ruins keep a chimney standing.
        if era.rawValue >= Era.industrial.rawValue {
            let height = radius * 0.55
            let chimney = translation(SIMD3(s.x, ground + height * 0.5, s.z))
                * scaleMatrix(SIMD3(radius * 0.07, height, radius * 0.07))
            geometry.boxes.append(InstanceData(
                model: chimney, color: SIMD4(stone * 0.82, 0),
                material: SIMD4(2, 0, 0, 0)))
        }

        // Collapsed roof planes and interior floors.
        for _ in 0..<2 {
            let a = rng.nextFloat(in: 0...(2 * .pi))
            let d = radius * rng.nextFloat(in: 0.12...0.60)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard g > 0.006, !terrain.isWater(x: p.x, z: p.y) else { continue }
            let roofColour = era.rawValue >= Era.industrial.rawValue
                ? SIMD3<Float>(0.26, 0.27, 0.29)
                : SIMD3<Float>(0.30, 0.20, 0.16)
            let plane = translation(SIMD3(p.x, g + 0.0007, p.y))
                * rotationY(rng.nextFloat(in: 0...(Float.pi)))
                * rotationZ(rng.nextFloat(in: 0.10...0.22))
                * scaleMatrix(SIMD3(radius * rng.nextFloat(in: 0.14...0.24), 0.0007,
                                    radius * rng.nextFloat(in: 0.18...0.30)))
            geometry.boxes.append(InstanceData(
                model: plane, color: SIMD4(roofColour, 0),
                material: SIMD4(0, 0, 0, 0)))
        }
        for _ in 0..<2 {
            let a = rng.nextFloat(in: 0...(2 * .pi))
            let d = radius * rng.nextFloat(in: 0.12...0.65)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard g > 0.006 else { continue }
            let floor = translation(SIMD3(p.x, g + 0.0004, p.y))
                * rotationY(rng.nextFloat(in: 0...(Float.pi)))
                * scaleMatrix(SIMD3(radius * 0.20, 0.0006, radius * 0.26))
            geometry.boxes.append(InstanceData(
                model: floor, color: SIMD4(stone * 0.72, 0),
                material: SIMD4(2, 0, 0, 0)))
        }

        // Overgrowth reclaiming the plots.
        for _ in 0..<4 {
            let a = rng.nextFloat(in: 0...(2 * .pi))
            let d = radius * rng.nextFloat(in: 0.1...0.85)
            let p = SIMD2(s.x + cos(a) * d, s.z + sin(a) * d)
            let g = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard g > 0.006, !terrain.isWater(x: p.x, z: p.y) else { continue }
            let patch = translation(SIMD3(p.x, g + 0.0003, p.y))
                * rotationY(rng.nextFloat(in: 0...(Float.pi)))
                * scaleMatrix(SIMD3(radius * rng.nextFloat(in: 0.18...0.34), 0.0004,
                                    radius * rng.nextFloat(in: 0.18...0.34)))
            geometry.fields.append(InstanceData(
                model: patch,
                color: SIMD4(SIMD3(0.28, 0.38, 0.20), 0),
                material: SIMD4(5, 0, 0, 0)))
        }

        // Large ruins keep a readable room plan from above.
        if radius > 0.036, ground > 0.006 {
            let planWidth = radius * 0.95
            let plan = translation(SIMD3(s.x, ground + 0.00025, s.z))
                * scaleMatrix(SIMD3(planWidth, 0.0004, planWidth))
            geometry.boxes.append(InstanceData(
                model: plan, color: SIMD4(SIMD3(0.34, 0.30, 0.24), 0),
                material: SIMD4(2, 0, 0, 0)))

            let step = planWidth / 3
            for i in -1...1 {
                for side in [Float(-1), Float(1)] {
                    // Walls along z.
                    let x = s.x + Float(i) * step
                    let z = s.z + side * planWidth * 0.22
                    let nz = terrain.interpolatedHeight(x: x, z: z)
                    if nz > 0.006 {
                        let wall = translation(SIMD3(x, nz + 0.0005, z))
                            * scaleMatrix(SIMD3(0.0009, 0.0007, planWidth * 0.24))
                        geometry.boxes.append(InstanceData(
                            model: wall, color: SIMD4(stone * 0.72, 0),
                            material: SIMD4(2, 0, 0, 0)))
                    }
                    // Walls along x.
                    let zz = s.z + Float(i) * step
                    let xx = s.x + side * planWidth * 0.22
                    let nx = terrain.interpolatedHeight(x: xx, z: zz)
                    if nx > 0.006 {
                        let wall = translation(SIMD3(xx, nx + 0.0005, zz))
                            * scaleMatrix(SIMD3(planWidth * 0.24, 0.0007, 0.0009))
                        geometry.boxes.append(InstanceData(
                            model: wall, color: SIMD4(stone * 0.72, 0),
                            material: SIMD4(2, 0, 0, 0)))
                    }
                }
            }
        }

        appendRubble(s,
                     count: min(Int(12 + pow(population, 0.4) * 1.6), 36),
                     radius: radius,
                     terrain: terrain,
                     seed: seed,
                     into: &geometry)
    }

    /// A stone curtain wall with towers and a gate, for medieval towns only.
    private static func appendWalls(_ s: Settlement,
                                    gateAngles: [Float],
                                    maxRadius: Float = .greatestFiniteMagnitude,
                                    builtRadius: Float,
                                    corePlots: [Plot],
                                    margin: Float = 1.12,
                                    height: Float = 0.0060,
                                    terrain: Terrain,
                                    seed: UInt64,
                                    into geometry: inout Geometry) {
        let desired = builtRadius * margin
        let radius = min(desired, maxRadius)
        // Leave at least a narrow strip of open ground inside the wall; a
        // circuit that would clip the town is worse than no wall.
        guard radius > builtRadius * 1.01, radius > 0.024 else { return }

        let segments = 20
        var rng = SplitMix64(seed: seed
                             ^ (UInt64(bitPattern: Int64(s.id)) &* 0x2545_F491_4F6C_DD1D))
        let stone = SIMD3<Float>(0.58, 0.56, 0.50)

        // The trace follows the outer plots rather than a perfect circle.
        var sectorMax = [Float](repeating: 0, count: segments)
        for plot in corePlots {
            let d = simd_distance(plot.center, SIMD2(s.x, s.z))
            let a = atan2(plot.center.y - s.z, plot.center.x - s.x) + 2 * Float.pi
            let index = Int(a / (2 * Float.pi) * Float(segments)) % segments
            sectorMax[index] = max(sectorMax[index], d)
        }

        var points: [SIMD2<Float>] = []
        points.reserveCapacity(segments)
        for k in 0..<segments {
            let before = sectorMax[(k + segments - 1) % segments]
            let here = sectorMax[k]
            let after = sectorMax[(k + 1) % segments]
            let local = max(here, max(before * 0.92, after * 0.92))
            let base = max(local, builtRadius * 0.90) * margin
            let r = min(base, maxRadius * 0.985)
            let a = Float(k) / Float(segments) * 2 * Float.pi
            points.append(SIMD2(s.x + cos(a) * r, s.z + sin(a) * r))
        }

        // Gate segments aligned with the roads that cross the wall.
        var gates = Set<Int>()
        for angle in gateAngles {
            let turns = angle / (2 * Float.pi)
            let wrapped = turns - floor(turns)
            gates.insert(min(Int((wrapped * Float(segments)).rounded()), segments - 1))
        }

        for k in 0..<segments {
            if gates.contains(k) { continue }
            let p0 = points[k]
            let p1 = points[(k + 1) % segments]
            let mid = (p0 + p1) * 0.5
            let length = simd_distance(p0, p1) * 1.08
            let dir = simd_normalize(p1 - p0)

            let ground = terrain.interpolatedHeight(x: mid.x, z: mid.y)
            guard ground > 0.008, !terrain.isWater(x: mid.x, z: mid.y) else { continue }

            let model = translation(SIMD3(mid.x, ground + height * 0.5, mid.y))
                * rotationY(atan2(dir.x, dir.y))
                * scaleMatrix(SIMD3(0.0014, height, length))
            let colour = stone * (0.88 + rng.nextFloat() * 0.20)
            geometry.boxes.append(InstanceData(model: model, color: SIMD4(colour, 0),
                                               material: SIMD4(2, 0, 0, 0)))
        }

        for k in stride(from: 0, to: segments, by: 5) where !gates.contains(k) {
            let p = points[k]
            let ground = terrain.interpolatedHeight(x: p.x, z: p.y)
            guard ground > 0.008, !terrain.isWater(x: p.x, z: p.y) else { continue }

            let towerHeight: Float = 0.0090
            let model = translation(SIMD3(p.x, ground + towerHeight * 0.5, p.y))
                * scaleMatrix(SIMD3(0.0030, towerHeight, 0.0030))
            geometry.boxes.append(InstanceData(model: model,
                                               color: SIMD4(stone * 0.95, 0)))
        }
    }


    /// A few fishing outposts on the coast, each a hut, a pier and a moored
    /// boat. They are derived from the terrain seed, not from settlements, so
    /// the coast is inhabited even though the towns sit inland.
    private static func appendOutposts(terrain: Terrain,
                                       era: Era,
                                       seed: UInt64,
                                       into geometry: inout Geometry) {
        guard era.rawValue >= Era.classical.rawValue else { return }

        let n = terrain.size
        let step = max(n / 28, 1)
        var candidates: [SIMD2<Float>] = []

        for j in stride(from: step, to: n - step, by: step) {
            for i in stride(from: step, to: n - step, by: step) {
                let idx = terrain.index(i, j)
                let h = terrain.height[idx]
                guard h > 0.0035, h < 0.040 else { continue }

                var nearWater = false
                for dj in -3...3 where !nearWater {
                    for di in -3...3 {
                        let ni = min(max(i + di, 0), n - 1)
                        let nj = min(max(j + dj, 0), n - 1)
                        if terrain.height[terrain.index(ni, nj)] <= 0 {
                            nearWater = true
                            break
                        }
                    }
                }
                if nearWater {
                    candidates.append(SIMD2(terrain.worldX(i), terrain.worldZ(j)))
                }
            }
        }

        guard !candidates.isEmpty else { return }

        var rng = SplitMix64(seed: seed ^ 0x51ED_270B_9A3C_1147)
        var chosen: [SIMD2<Float>] = []
        var attempts = 0
        while chosen.count < 3 && attempts < 200 {
            attempts += 1
            let p = candidates[rng.nextInt(candidates.count)]
            if chosen.contains(where: { simd_distance($0, p) < 0.22 }) { continue }
            chosen.append(p)
        }

        for site in chosen {
            appendHarbour(at: site, era: era, terrain: terrain, rng: &rng, into: &geometry)
        }
    }

    private static func appendHarbour(at site: SIMD2<Float>,
                                      era: Era,
                                      terrain: Terrain,
                                      rng: inout SplitMix64,
                                      into geometry: inout Geometry) {
        var bestAngle: Float = 0
        var bestDistance: Float = 1e9

        for k in 0..<24 {
            let angle = Float(k) / 24 * 2 * Float.pi
            var distance: Float = 0.006
            while distance <= 0.06 {
                let x = site.x + cos(angle) * distance
                let z = site.y + sin(angle) * distance
                if terrain.isWater(x: x, z: z) {
                    if distance < bestDistance {
                        bestDistance = distance
                        bestAngle = angle
                    }
                    break
                }
                distance += 0.004
            }
        }

        guard bestDistance < 0.06 else { return }

        let dir = SIMD2<Float>(cos(bestAngle), sin(bestAngle))
        let heading = atan2(dir.x, dir.y)
        let ground = terrain.interpolatedHeight(x: site.x, z: site.y)

        let hutHeight: Float = 0.0045
        let hut = translation(SIMD3(site.x, ground + hutHeight * 0.5, site.y))
            * rotationY(heading + rng.nextFloat(in: -0.3...0.3))
            * scaleMatrix(SIMD3(0.0045, hutHeight, 0.0040))
        geometry.boxes.append(InstanceData(model: hut,
                                           color: SIMD4(SIMD3(0.55, 0.47, 0.35), 0),
                                           material: SIMD4(1, 0, 0, 0)))

        let roof = translation(SIMD3(site.x, ground + hutHeight, site.y))
            * rotationY(heading + .pi / 4)
            * scaleMatrix(SIMD3(0.0060, 0.0025, 0.0055))
        geometry.gables.append(InstanceData(model: roof,
                                            color: SIMD4(SIMD3(0.36, 0.26, 0.18), 0),
                                            material: SIMD4(3, 0, 0, 0)))

        let shore = site + dir * 0.004
        let end = shore + dir * 0.020
        let mid = (shore + end) * 0.5
        let length = simd_distance(shore, end)
        let deckY: Float = 0.0042 + 0.0014
        let deck = translation(SIMD3(mid.x, deckY, mid.y))
            * rotationY(heading)
            * scaleMatrix(SIMD3(0.0028, 0.0005, length))
        geometry.boxes.append(InstanceData(model: deck,
                                           color: SIMD4(SIMD3(0.40, 0.30, 0.20), 0)))

        let side = SIMD2<Float>(-dir.y, dir.x)
        let bx = end.x + side.x * 0.004
        let bz = end.y + side.y * 0.004

        let hull = translation(SIMD3(bx, 0.0042 + 0.0006, bz))
            * rotationY(heading)
            * scaleMatrix(SIMD3(0.0020, 0.0012, 0.0055))
        geometry.boxes.append(InstanceData(model: hull,
                                           color: SIMD4(SIMD3(0.32, 0.24, 0.16), 0)))

        let sail = translation(SIMD3(bx, 0.0042 + 0.0045, bz))
            * rotationY(heading)
            * scaleMatrix(SIMD3(0.0028, 0.0070, 0.0028))
        geometry.cones.append(InstanceData(model: sail,
                                           color: SIMD4(SIMD3(0.84, 0.84, 0.80), 0)))
    }

    /// Cultivated plots in a ring around the built area. They are the clearest
    /// signal that the landscape belongs to the civilisation, not the other way
    /// round, and their colour follows the era's crops.
    private static func appendFields(_ s: Settlement,
                                     all: [Settlement],
                                     era: Era,
                                     year: Float,
                                     terrain: Terrain,
                                     seed: UInt64,
                                     into geometry: inout Geometry) {
        let population = max(s.population, 1)
        let radius = cityRadius(population)
        let count = min(Int(7 + pow(population, 0.42) * 1.5), 60)

        var rng = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(s.id)) &* 0xD1B5_4A32_D192_ED03))

        // Three-crop rotation; the palette shifts every 12 simulated years so
        // the patchwork changes as the world ages.
        let crops: [SIMD3<Float>]
        switch era {
        case .neolithic:
            crops = [SIMD3(0.55, 0.48, 0.30), SIMD3(0.46, 0.50, 0.28), SIMD3(0.62, 0.56, 0.38)]
        case .bronze, .classical:
            crops = [SIMD3(0.66, 0.55, 0.28), SIMD3(0.50, 0.55, 0.26), SIMD3(0.58, 0.46, 0.24)]
        case .medieval:
            crops = [SIMD3(0.52, 0.48, 0.26), SIMD3(0.42, 0.50, 0.24), SIMD3(0.58, 0.50, 0.30)]
        case .renaissance, .industrial:
            crops = [SIMD3(0.42, 0.34, 0.22), SIMD3(0.40, 0.44, 0.24), SIMD3(0.50, 0.42, 0.26)]
        case .modern, .information, .future:
            crops = [SIMD3(0.45, 0.48, 0.29), SIMD3(0.50, 0.52, 0.30), SIMD3(0.40, 0.45, 0.26)]
        }
        let cropCycle = Int(year / 12)

        for index in 0..<count {
            let angle = rng.nextFloat(in: 0...(2 * .pi))
            let width = 0.009 + rng.nextFloat() * 0.011
            let depth = 0.009 + rng.nextFloat() * 0.011
            let clearance = max(width, depth) * 0.75
            let distance = radius * 1.45 + clearance + rng.nextFloat() * radius * 1.25
            let x = s.x + cos(angle) * distance
            let z = s.z + sin(angle) * distance

            let ground = terrain.interpolatedHeight(x: x, z: z)
            guard ground > 0.007, !terrain.isWater(x: x, z: z) else { continue }
            guard simd_length(terrain.gradientAt(x: x, z: z)) < 0.60 else { continue }

            // Never drop a field into another town's built-up area.
            let clear = all.allSatisfy { other in
                guard other.id != s.id, other.isAlive else { return true }
                let otherRadius = cityRadius(max(other.population, 1))
                let gap = simd_distance(SIMD2(x, z), SIMD2(other.x, other.z))
                return gap > otherRadius * 1.25 + clearance
            }
            guard clear else { continue }

            // Quantised field angles read as a parcellated patchwork.
            let fieldRotation = Float(Int(rng.nextFloat() * 4)) * Float.pi / 2
                + rng.nextFloat(in: -0.10...0.10)

            var colour = crops[(index + cropCycle) % crops.count]
            colour *= 0.88 + rng.nextFloat() * 0.22

            let thickness: Float = 0.0007
            let model = translation(SIMD3(x, ground + 0.0004, z))
                * rotationY(fieldRotation)
                * scaleMatrix(SIMD3(width, thickness, depth))
            geometry.fields.append(InstanceData(model: model,
                                                color: SIMD4(colour, 0),
                                                material: SIMD4(5, 0, 0, 0)))
        }
    }

    /// Footprint radius in world units (1 unit = 10 km). Capped so that even at
    /// near-future populations the valley keeps distinct cities and open land
    /// between them, instead of fusing into one white continent.
    static func cityRadius(_ population: Float) -> Float {
        SettlementMetrics.cityRadius(population)
    }

    /// Late eras concentrate into a smaller, denser core instead of spreading
    /// over the whole population radius, which keeps neighbouring towns apart
    /// and leaves open land between them.
    static func plannedRadius(_ population: Float, era: Era) -> Float {
        let r = cityRadius(population)
        switch era {
        case .industrial: return min(r, 0.082)
        case .modern:     return min(r, 0.078)
        case .information: return min(r, 0.066)
        case .future:     return min(r, 0.060)
        default:          return r
        }
    }

    static func buildingCount(_ population: Float) -> Int {
        let raw = 3 + pow(max(population, 1), 0.50) * 1.5
        return Int(min(max(raw, 3), 260))
    }

    // MARK: - Trees

    /// Cones scattered across forested cells. Static for the life of the world.
    struct Trees {
        var conifers: [InstanceData] = []
        var broadleaves: [InstanceData] = []
    }

    static func trees(terrain: Terrain, settlements: [Settlement], seed: UInt64,
                      riverField: RiverChannel.Field? = nil) -> Trees {
        var result = Trees()
        let n = terrain.size
        var rng = SplitMix64(seed: seed ^ 0x7EE5_0BAD_1234_5678)

        for j in stride(from: 0, to: n, by: 1) {
            for i in stride(from: 0, to: n, by: 1) {
                let idx = terrain.index(i, j)
                guard terrain.biome[idx] == Terrain.Biome.forest.rawValue else { continue }
                // Thin the forest deterministically.
                if (i &* 7 &+ j &* 13) % 5 != 0 { continue }

                let x = terrain.worldX(i) + rng.nextFloat(in: -0.004...0.004)
                let z = terrain.worldZ(j) + rng.nextFloat(in: -0.004...0.004)

                var nearSettlement = false
                for s in settlements where s.isAlive {
                    let clearance = cityRadius(s.population) * 1.35 + 0.003
                    if abs(s.x - x) < clearance && abs(s.z - z) < clearance {
                        nearSettlement = true
                        break
                    }
                }
                if nearSettlement { continue }

                let ground = terrain.heightAt(x: x, z: z)
                guard ground > 0.006 else { continue }
                // Keep trunks out of the channel and off the raised banks.
                guard terrain.riverAt(x: x, z: z) == 0 else { continue }
                if let field = riverField,
                   field.isNearWater(at: SIMD2(x, z), margin: 0.012) {
                    continue
                }

                let h = rng.nextFloat(in: 0.004...0.009)
                let w = h * rng.nextFloat(in: 0.42...0.62)
                let model = translation(SIMD3(x, ground, z))
                    * rotationY(rng.nextFloat(in: 0...(2 * .pi)))
                    * scaleMatrix(SIMD3(w, h, w))
                let green = SIMD3<Float>(0.16 + rng.nextFloat() * 0.10,
                                         0.30 + rng.nextFloat() * 0.12,
                                         0.14 + rng.nextFloat() * 0.08)
                let instance = InstanceData(model: model, color: SIMD4(green, 0))

                // Broadleaf woodland on the lower slopes, conifers higher up
                // and in the deep forest, so the tree line is not one species.
                let leafy = (i &* 31 &+ j &* 57) % 10 < 4
                let low = ground < 0.11
                if leafy && low {
                    result.broadleaves.append(instance)
                } else {
                    result.conifers.append(instance)
                }
            }
        }
        return result
    }
}

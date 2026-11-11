import Foundation
import simd

// MARK: - Resources

/// What a patch of ground offers a settlement. Values are 0…1 and are derived
/// from terrain that already exists, so nothing new is stored in the save file.
struct ResourceSample {
    var fertility: Float = 0
    var freshWater: Float = 0
    var timber: Float = 0
    var stone: Float = 0
    var ore: Float = 0
    var coast: Float = 0
    var buildability: Float = 0
    var routeAccess: Float = 0

    /// How attractive this ground is to a settlement in a given era.
    ///
    /// The weights encode the historical sequence: early towns need soil and
    /// water, classical and medieval towns need stone, timber and a route,
    /// industrial towns need ore and transport, and modern towns mostly need
    /// flat buildable land and connections.
    func score(for era: Era) -> Float {
        let s: Float
        switch era {
        case .neolithic:
            s = fertility * 0.45 + freshWater * 0.30 + buildability * 0.25
        case .bronze:
            s = fertility * 0.28 + freshWater * 0.28 + buildability * 0.20
                + stone * 0.10 + routeAccess * 0.14
        case .classical:
            s = freshWater * 0.24 + buildability * 0.22 + stone * 0.18
                + coast * 0.18 + routeAccess * 0.18
        case .medieval:
            s = freshWater * 0.26 + buildability * 0.20 + stone * 0.16
                + timber * 0.12 + routeAccess * 0.26
        case .renaissance:
            s = buildability * 0.24 + stone * 0.22 + routeAccess * 0.24
                + freshWater * 0.16 + fertility * 0.14
        case .industrial:
            s = ore * 0.28 + freshWater * 0.22 + routeAccess * 0.24
                + buildability * 0.16 + stone * 0.10
        case .modern:
            s = buildability * 0.34 + routeAccess * 0.30 + freshWater * 0.16
                + coast * 0.10 + fertility * 0.10
        case .information:
            s = buildability * 0.30 + routeAccess * 0.32 + coast * 0.14
                + freshWater * 0.14 + fertility * 0.10
        case .future:
            s = buildability * 0.32 + freshWater * 0.24 + routeAccess * 0.22
                + fertility * 0.12 + coast * 0.10
        }
        return clamp01(s)
    }
}

/// Deterministic resource field over the island. Sampling is cheap and uses
/// the terrain's existing layers plus a little seeded value noise for ore.
struct ResourceMap {
    let terrain: Terrain
    let seed: UInt64
    private let noise: ValueNoise

    init(terrain: Terrain, seed: UInt64) {
        self.terrain = terrain
        self.seed = seed
        self.noise = ValueNoise(seed: seed ^ 0x5EED_1234_ABCD_0001)
    }

    func sample(_ point: SIMD2<Float>) -> ResourceSample {
        sample(x: point.x, z: point.y)
    }

    func sample(x: Float, z: Float) -> ResourceSample {
        let h = terrain.heightAt(x: x, z: z)
        let slope = terrain.slopeAt(x: x, z: z)
        let water = terrain.waterDistanceAt(x: x, z: z)
        let moisture = terrain.moistureAt(x: x, z: z)
        let biome = terrain.biomeAt(x: x, z: z)
        let land = smoothstep(0.0, 0.006, h)
        let rock = biome == .rock || biome == .snow

        // Fresh water falls off with distance to sea or river.
        let freshWater = clamp01(1 - water / 16) * land

        // Arable land is the terrain's own fertility, boosted by moisture.
        let fertility = clamp01(terrain.fertilityAt(x: x, z: z) * (0.75 + moisture * 0.5))

        // Timber follows forest cover and moisture.
        let forest: Float = biome == .forest ? 1 : 0
        let timberBase = clamp01((moisture - 0.40) / 0.45)
        let timber = timberBase * (0.35 + forest * 0.65) * land

        // Stone appears on steep and rocky ground.
        let stone = clamp01((slope - 0.18) / 0.55) * (0.45 + (rock ? 0.55 : 0))
            * smoothstep(0.015, 0.05, h)

        // Ore is a slow noise field biased to the highlands.
        let oreNoise = noise.fbm(x * 3.4 + 11.0, z * 3.4 - 7.0, octaves: 3)
        let highland = smoothstep(0.035, 0.13, h)
        let ore = clamp01((oreNoise - 0.46) / 0.30) * highland * land

        // Coast: low shoreline close to open water.
        let shore = (1 - smoothstep(0.004, 0.030, h)) * smoothstep(0.0, 0.004, h)
        let coast = clamp01(shore * clamp01(1 - water / 7))

        // Buildable ground is flat, dry and not too high.
        let flat = smoothstep(0.85, 0.14, slope)
        let dry = smoothstep(0.002, 0.010, h)
        let notAlpine = 1 - smoothstep(0.13, 0.20, h)
        let buildability = clamp01(flat * dry * notAlpine)

        // Routes favour flat, low corridors that already lead somewhere.
        let low = 1 - smoothstep(0.02, 0.14, h)
        let routeAccess = clamp01(flat * low * (0.55 + freshWater * 0.45))

        return ResourceSample(fertility: fertility,
                              freshWater: freshWater,
                              timber: timber,
                              stone: stone,
                              ore: ore,
                              coast: coast,
                              buildability: buildability,
                              routeAccess: routeAccess)
    }

    /// Best site in a list of candidates, scored for an era.
    func bestSite(among candidates: [SIMD2<Float>],
                  era: Era) -> SIMD2<Float>? {
        candidates.max { a, b in
            sample(a).score(for: era) < sample(b).score(for: era)
        }
    }
}

// MARK: - Layout vocabulary

/// What a plot is for. Districts drive which building pool is used and how
/// the ground around the plot is treated.
enum District: Int, CaseIterable {
    case civic
    case residential
    case commercial
    case industrial
    case port
    case agricultural
    case extractive
    case park

    var name: String {
        switch self {
        case .civic:       return "civic"
        case .residential: return "residential"
        case .commercial:  return "commercial"
        case .industrial:  return "industrial"
        case .port:        return "port"
        case .agricultural: return "agricultural"
        case .extractive:  return "extractive"
        case .park:        return "park"
        }
    }
}

/// A parcel of land with a street frontage. Buildings are placed on plots,
/// never on arbitrary points, so rows, terraces and burgage strips line up.
struct Plot {
    var center: SIMD2<Float>
    /// Unit vector from the plot centre toward the street it faces.
    var frontage: SIMD2<Float>
    /// Width along the street.
    var width: Float
    /// Depth away from the street.
    var depth: Float
    var district: District
    /// Index into the plan's road list.
    var roadID: Int
    /// 0 = main street, 1 = secondary, 2 = lane.
    var frontageRank: Int
    /// Ring index for grid towns, used for ragged fringes.
    var ring: Int = 0
    /// Grid coordinates, for era-specific reserved blocks.
    var cellIndex: SIMD2<Int> = .zero
    /// Orientation of the plot's grid, radians.
    var axis: Float = 0
    /// Height multiplier for landmarks such as churches and guildhalls.
    var scaleMultiplier: Float = 1
    /// Height of a stone platform under the building (temples, civic halls).
    var podium: Float = 0

    /// Front edge midpoint, where a door would sit.
    var frontPoint: SIMD2<Float> {
        center + frontage * (depth * 0.5)
    }

    /// Direction a building on this plot should face (toward the street).
    var facing: Float {
        atan2(frontage.x, frontage.y)
    }
}

/// One straight run of road. Curves are approximated by short segments.
struct RoadSegment {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    /// 0 = arterial/canal/processional, 1 = main street, 2 = lane, 3 = path.
    var roadClass: Int
    var width: Float

    var length: Float { simd_length(b - a) }

    var midpoint: SIMD2<Float> { (a + b) * 0.5 }

    var direction: SIMD2<Float> {
        let d = b - a
        let l = simd_length(d)
        return l > 1e-6 ? d / l : SIMD2(1, 0)
    }
}

/// A one-off structure with its own mesh: temple, church or dock.
struct Landmark {
    enum Kind: Int {
        case temple
        case church
        case cathedral
        case dome
        case dock
    }

    var kind: Kind
    var center: SIMD2<Float>
    var facing: Float
    /// Width in world units. The meshes are authored one unit wide.
    var scale: Float
}

/// The full plan for one settlement in one era. The renderer turns this into
/// geometry; nothing else needs to know how the town was laid out.
struct SettlementPlan {
    var center: SIMD2<Float>
    /// Main orientation of the settlement, radians.
    var axis: Float
    var roads: [RoadSegment] = []
    var plots: [Plot] = []
    /// Grid spacing and built-up radius, for street rendering and people.
    var cell: Float = 0.01
    var radius: Float = 0.05
    /// Ring index of the outermost grid, for ragged edges.
    var half: Int = 0
    /// Closed wall polygon, if the town is walled.
    var wall: [SIMD2<Float>]?
    /// Canal, aqueduct or river link.
    var water: [SIMD2<Float>]?
    /// Rail line, once a town has one.
    var rail: [SIMD2<Float>]?
    /// One-off structures with dedicated meshes.
    var landmarks: [Landmark] = []
    /// Roman aqueduct, from a high water source to the town.
    var aqueduct: [SIMD2<Float>]?
    /// Angles of the gates, aligned with the roads that cross the wall.
    var gates: [Float] = []

    var buildingPlots: [Plot] {
        plots.filter { $0.district != .park }
    }
}

// MARK: - Road planning

/// Shared road helpers. Every planner builds roads through these so no era
/// can emit a road that climbs a cliff or crosses open water.
enum RoadPlanning {
    /// Maximum rise over run a road may take.
    static let maxGrade: Float = 0.35

    static func segment(from a: SIMD2<Float>,
                        to b: SIMD2<Float>,
                        roadClass: Int,
                        width: Float,
                        terrain: Terrain,
                        maxGrade: Float = RoadPlanning.maxGrade) -> RoadSegment? {
        let mid = (a + b) * 0.5
        guard terrain.heightAt(x: mid.x, z: mid.y) > 0.004,
              terrain.heightAt(x: a.x, z: a.y) > 0.004,
              terrain.heightAt(x: b.x, z: b.y) > 0.004 else { return nil }
        guard terrain.grade(from: a, to: b) <= maxGrade else { return nil }
        return RoadSegment(a: a, b: b, roadClass: roadClass, width: width)
    }

    /// Splits a long run into short chunks and keeps only the chunks that pass
    /// the slope and water tests. This is how curved roads will be authored.
    static func run(from a: SIMD2<Float>,
                    to b: SIMD2<Float>,
                    roadClass: Int,
                    width: Float,
                    terrain: Terrain,
                    chunks: Int = 1) -> [RoadSegment] {
        let steps = max(chunks, 1)
        var result: [RoadSegment] = []
        result.reserveCapacity(steps)
        for step in 0..<steps {
            let t0 = Float(step) / Float(steps)
            let t1 = Float(step + 1) / Float(steps)
            let p0 = a + (b - a) * t0
            let p1 = a + (b - a) * t1
            if let segment = segment(from: p0, to: p1,
                                     roadClass: roadClass, width: width,
                                     terrain: terrain) {
                result.append(segment)
            }
        }
        return result
    }
}

// MARK: - Planner protocol

/// Each era supplies one of these. Keeping the signature identical means the
/// renderer never switches on era itself; it just asks for a plan.
protocol SettlementLayout {
    static func plan(settlement: Settlement,
                     resources: ResourceMap,
                     terrain: Terrain,
                     seed: UInt64,
                     style: CityBuilder.Style) -> SettlementPlan
}

// MARK: - Terrain accessors

extension Terrain {
    func slopeAt(x: Float, z: Float) -> Float {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return slope[index(i, j)]
    }

    func waterDistanceAt(x: Float, z: Float) -> Float {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return waterDistance[index(i, j)]
    }

    func moistureAt(x: Float, z: Float) -> Float {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return moisture[index(i, j)]
    }

    func biomeAt(x: Float, z: Float) -> Biome {
        let i = min(max(cellX(x), 0), size - 1)
        let j = min(max(cellZ(z), 0), size - 1)
        return Biome(rawValue: biome[index(i, j)]) ?? .grass
    }

    /// Average gradient along a segment, used to reject impossible roads.
    func grade(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Float {
        let length = max(simd_length(b - a), 1e-6)
        let rise = abs(interpolatedHeight(x: b.x, z: b.y)
                       - interpolatedHeight(x: a.x, z: a.y))
        return rise / length
    }
}

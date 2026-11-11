import Foundation
import simd

struct Settlement {
    var id: Int32
    var name: String
    var x: Float
    var z: Float
    var founded: Float
    var population: Float
    var prominence: Float
    var site: Float
    /// Year the settlement was abandoned; -1 while alive.
    var abandoned: Float = -1
    /// Transient set-back applied by the last event, decays over ~30 years.
    var scar: Float = 0

    var isAlive: Bool { abandoned < 0 }
}

struct ChronicleEntry {
    enum Kind: UInt8 {
        case era, founding, plague, fire, war, drought, boom, quake, abandon
    }

    var year: Float
    var kind: Kind
    var text: String
    var x: Float
    var z: Float
}

/// The whole civilisation, as plain data. Deterministic: given a seed and a
/// target year, replaying from zero always produces the same world.
struct Simulation {

    let seed: UInt64
    let terrain: Terrain

    private(set) var year: Float = 0
    private(set) var era: Era = .neolithic
    private(set) var settlements: [Settlement] = []
    private(set) var chronicle: [ChronicleEntry] = []
    private(set) var totalPopulation: Float = 0
    private(set) var peakPopulation: Float = 0
    private(set) var foundedCount: Int = 0

    private var rng: SplitMix64
    private var nextID: Int32 = 0
    private var lastEventYear: Float = -1000
    private var lastSpawnYear: Float = -1000

    private static let chronicleLimit = 240

    // MARK: - Growth curves

    /// Population of a settlement of prominence 1, at a given year.
    static func basePopulation(_ year: Float) -> Float {
        let t = min(max(year / 10000, 0), 1.20)
        return 40 * exp(6.0 * pow(t, 1.35))
    }

    /// How many settlements should exist by a given year.
    static func targetSettlementCount(_ year: Float) -> Int {
        let stops: [(Float, Float)] = [
            (0, 6), (1200, 13), (2600, 19), (4200, 25),
            (5800, 31), (7400, 30), (9000, 23), (11000, 16)
        ]
        if year <= stops[0].0 { return Int(stops[0].1) }
        for i in 0..<(stops.count - 1) where year < stops[i + 1].0 {
            let t = (year - stops[i].0) / (stops[i + 1].0 - stops[i].0)
            return Int(stops[i].1 + t * (stops[i + 1].1 - stops[i].1))
        }
        return Int(stops.last!.1)
    }

    // MARK: - Init

    init(seed: UInt64, terrain: Terrain) {
        self.seed = seed
        self.terrain = terrain
        self.rng = SplitMix64(seed: seed ^ 0xA5A5_1234_9E37_79B9)

        // Three founding camps on the best land.
        for i in 0..<3 {
            let site = bestSite(excluding: settlements.map { SIMD2($0.x, $0.z) },
                                preferNear: nil)
            var settlement = makeSettlement(at: site)
            if i == 0 {
                settlement.prominence = 4.0
                settlement.population = 60
                addChronicle(.founding, "\(settlement.name) is founded", at: settlement)
            }
            settlements.append(settlement)
        }
        recomputeTotals(at: 0)
    }

    // MARK: - Running

    /// Replays the simulation forward to `target` (inclusive).
    mutating func advance(to target: Float) {
        guard target > year else { return }
        let steps = Int((target - year).rounded(.down))
        for _ in 0..<max(steps, 0) {
            tick()
        }
        // Land exactly on the requested fractional year.
        year = max(year, target)
        era = Era.at(year)
    }

    mutating func tick() {
        year += 1
        let newEra = Era.at(year)
        if newEra != era {
            era = newEra
            addChronicle(.era, "The \(newEra.name) begins", at: nil)
        }

        // New settlements appear steadily as the population grows. Abandoned
        // sites stay as ruins but no longer count toward the target.
        let target = Simulation.targetSettlementCount(year)
        let aliveCount = settlements.reduce(0) { $1.isAlive ? $0 + 1 : $0 }
        if aliveCount < target, year - lastSpawnYear > 12 {
            let occupied = settlements.map { SIMD2($0.x, $0.z) }
            let site = bestSite(excluding: occupied, preferNear: occupied)
            let settlement = makeSettlement(at: site)
            settlements.append(settlement)
            foundedCount += 1
            lastSpawnYear = year
            addChronicle(.founding, "\(settlement.name) is founded", at: settlement)
        }

        // Population eases toward an era-scaled target.
        let base = Simulation.basePopulation(year)
        for i in settlements.indices {
            guard settlements[i].isAlive else { continue }
            let s = settlements[i]
            var neighbours = 0
            for other in settlements where other.isAlive && other.id != s.id {
                if simd_distance(SIMD2(other.x, other.z), SIMD2(s.x, s.z)) < 0.13 {
                    neighbours += 1
                }
            }
            let trade = 1 + 0.07 * Float(min(neighbours, 5))
            let targetPop = s.prominence * s.site * base * trade
            let rate: Float = 0.022
            settlements[i].population += (targetPop - s.population) * rate
            settlements[i].scar = max(0, s.scar - 0.04)
        }

        // Urban consolidation: from the industrial era onward the smallest
        // towns are absorbed by larger neighbours, so late eras have fewer,
        // larger cities and open land between them.
        if year >= Era.industrial.startYear {
            let target = Simulation.targetSettlementCount(year)
            var alive = settlements.indices.filter { settlements[$0].isAlive }
            while alive.count > target {
                alive.sort { settlements[$0].population < settlements[$1].population }
                guard let small = alive.first else { break }
                var nearest: Int?
                var bestDistance = Float.greatestFiniteMagnitude
                for i in settlements.indices
                    where settlements[i].isAlive && i != small
                    && settlements[i].population > settlements[small].population {
                    let d = simd_distance(SIMD2(settlements[i].x, settlements[i].z),
                                          SIMD2(settlements[small].x, settlements[small].z))
                    if d < bestDistance { bestDistance = d; nearest = i }
                }
                guard let big = nearest,
                      settlements[small].population < settlements[big].population * 0.45
                else { break }
                settlements[small].abandoned = year
                addChronicle(.abandon,
                             "\(settlements[small].name) is absorbed by \(settlements[big].name)",
                             at: settlements[small])
                alive.removeAll { $0 == small }
            }
        }

        // A town that has been repeatedly hit and fallen below a viable size
        // is abandoned; its ruins remain on the map.
        for i in settlements.indices where settlements[i].isAlive {
            if settlements[i].population < 14, settlements[i].scar > 0.25 {
                settlements[i].abandoned = year
                addChronicle(.abandon, "\(settlements[i].name) is abandoned",
                             at: settlements[i])
            }
        }

        maybeEvent()
        recomputeTotals(at: year)
    }

    private mutating func recomputeTotals(at year: Float) {
        var total: Float = 0
        for s in settlements where s.isAlive {
            total += s.population
        }
        totalPopulation = total
        peakPopulation = max(peakPopulation, total)
    }

    // MARK: - Site selection

    /// Picks the most attractive unoccupied cell. Early settlements are placed
    /// at the best sites; later ones spread outward from what already exists.
    private mutating func bestSite(excluding occupied: [SIMD2<Float>],
                                   preferNear: [SIMD2<Float>]?) -> SIMD2<Float> {
        var best = SIMD2<Float>(0, 0)
        var bestScore: Float = -1
        let n = terrain.size
        let minDistance: Float = occupied.isEmpty ? 0 : 0.058

        for _ in 0..<260 {
            let i = rng.nextInt(n)
            let j = rng.nextInt(n)
            let idx = terrain.index(i, j)
            guard terrain.height[idx] > 0.012,
                  terrain.biome[idx] != Terrain.Biome.snow.rawValue else { continue }

            let x = terrain.worldX(i)
            let z = terrain.worldZ(j)
            let p = SIMD2<Float>(x, z)

            if minDistance > 0 {
                var tooClose = false
                for o in occupied where simd_distance(o, p) < minDistance {
                    tooClose = true
                    break
                }
                if tooClose { continue }
            }

            var score = terrain.fertility[idx] + 0.04
            if let preferNear, !preferNear.isEmpty {
                var nearest: Float = 10
                for o in preferNear { nearest = min(nearest, simd_distance(o, p)) }
                score *= 0.45 + 1.15 * exp(-nearest / 0.30)
            }
            score *= 0.85 + rng.nextFloat() * 0.35

            if score > bestScore {
                bestScore = score
                best = p
            }
        }

        if bestScore < 0 {
            // Fall back to any land cell near the centre.
            for _ in 0..<400 {
                let i = rng.nextInt(n), j = rng.nextInt(n)
                if terrain.height[terrain.index(i, j)] > 0.012 {
                    return SIMD2(terrain.worldX(i), terrain.worldZ(j))
                }
            }
            return SIMD2(0.1, 0.1)
        }
        return best
    }

    private mutating func makeSettlement(at p: SIMD2<Float>) -> Settlement {
        let idx = terrain.index(min(max(terrain.cellX(p.x), 0), terrain.size - 1),
                                min(max(terrain.cellZ(p.y), 0), terrain.size - 1))
        let fert = terrain.fertility[idx]
        // Heavy-tailed prominence: a few places become cities, most stay towns.
        let prominence = 0.25 + 3.5 * pow(rng.nextFloat(), 2.6)
        let settlement = Settlement(id: nextID,
                                    name: makeName(),
                                    x: p.x,
                                    z: p.y,
                                    founded: year,
                                    population: 30 + rng.nextFloat() * 40,
                                    prominence: prominence,
                                    site: 0.55 + fert * 1.15)
        nextID += 1
        return settlement
    }

    private mutating func makeName() -> String {
        let onsets = ["A", "Bel", "Cor", "Dun", "El", "Fen", "Gal", "Har", "Is", "Kar",
                      "Lor", "Mar", "Nor", "Or", "Pel", "Quen", "Rav", "Sel", "Tor",
                      "Ul", "Val", "Wyn", "Xan", "Yel", "Zor", "Bram", "Caster", "Durn"]
        let middles = ["a", "e", "i", "o", "u", "an", "en", "ar", "or", "el", "im", "os", "un", ""]
        let endings = ["", "by", "ton", "ford", "mere", "wick", "stead", "holm", "gate",
                       "bridge", "crest", "fell", "haven", "watch", "moor", "dale"]
        return onsets[rng.nextInt(onsets.count)]
            + middles[rng.nextInt(middles.count)]
            + endings[rng.nextInt(endings.count)]
    }

    // MARK: - Events

    private mutating func maybeEvent() {
        guard year > 260 else { return }
        guard year - lastEventYear > 18 else { return }

        let chance: Float = era.rawValue >= Int(Era.industrial.rawValue) ? 0.011 : 0.005
        guard rng.nextFloat() < chance else { return }

        let living = settlements.indices.filter { settlements[$0].isAlive }
        guard !living.isEmpty else { return }

        // Weight by population so disasters land on real cities.
        var pick = 0
        var roll = rng.nextFloat() * max(totalPopulation, 1)
        for i in living {
            roll -= settlements[i].population
            if roll <= 0 { pick = i; break }
        }

        lastEventYear = year
        let kind = rng.nextInt(6)
        let victim = pick

        switch kind {
        case 0:
            applyShock(to: victim, factor: 0.55)
            addChronicle(.plague, "Plague sweeps \(settlements[victim].name)", at: settlements[victim])
        case 1:
            applyShock(to: victim, factor: 0.80)
            addChronicle(.fire, "Fire destroys much of \(settlements[victim].name)", at: settlements[victim])
        case 2:
            applyShock(to: victim, factor: 0.72)
            if living.count > 1 {
                let other = living[rng.nextInt(living.count)]
                if other != victim {
                    applyShock(to: other, factor: 0.85)
                    addChronicle(.war, "\(settlements[victim].name) and \(settlements[other].name) go to war",
                                 at: settlements[victim])
                } else {
                    addChronicle(.war, "War reaches \(settlements[victim].name)", at: settlements[victim])
                }
            } else {
                addChronicle(.war, "War reaches \(settlements[victim].name)", at: settlements[victim])
            }
        case 3:
            applyShock(to: victim, factor: 0.88)
            addChronicle(.drought, "Drought grips \(settlements[victim].name)", at: settlements[victim])
        case 4:
            applyShock(to: victim, factor: 1.22)
            addChronicle(.boom, "\(settlements[victim].name) prospers", at: settlements[victim])
        default:
            applyShock(to: victim, factor: 0.82)
            addChronicle(.quake, "An earthquake shakes \(settlements[victim].name)", at: settlements[victim])
        }
    }

    private func nearestAlive(to index: Int) -> Int? {
        var nearest: Int?
        var best = Float.greatestFiniteMagnitude
        let here = SIMD2(settlements[index].x, settlements[index].z)

        for j in settlements.indices where j != index && settlements[j].isAlive {
            let distance = simd_distance(SIMD2(settlements[j].x, settlements[j].z), here)
            if distance < best {
                best = distance
                nearest = j
            }
        }
        return nearest
    }

    private mutating func applyShock(to index: Int, factor: Float) {
        let before = settlements[index].population
        settlements[index].population *= factor
        settlements[index].scar = min(1.0, settlements[index].scar + 0.4)

        // Refugees flee to the nearest surviving town.
        let lost = max(before - settlements[index].population, 0)
        if lost > 1, let refuge = nearestAlive(to: index) {
            settlements[refuge].population += lost * 0.35
        }

        // A town that cannot recover is abandoned; what is left disperses and
        // its ruins stay on the map.
        if settlements[index].isAlive, settlements[index].population < 40 {
            let remaining = settlements[index].population
            if remaining > 0, let refuge = nearestAlive(to: index) {
                settlements[refuge].population += remaining
            }
            settlements[index].population = 0
            settlements[index].abandoned = year
            addChronicle(.abandon, "\(settlements[index].name) is abandoned",
                         at: settlements[index])
        }
    }

    private mutating func addChronicle(_ kind: ChronicleEntry.Kind, _ text: String, at settlement: Settlement?) {
        let entry = ChronicleEntry(year: year,
                                   kind: kind,
                                   text: text,
                                   x: settlement?.x ?? 0,
                                   z: settlement?.z ?? 0)
        chronicle.append(entry)
        if chronicle.count > Simulation.chronicleLimit {
            chronicle.removeFirst(chronicle.count - Simulation.chronicleLimit)
        }
    }

    // MARK: - Queries

    func largestSettlement() -> Settlement? {
        settlements.filter { $0.isAlive }.max { $0.population < $1.population }
    }

    /// The most recent chronicle entry at or before the current year.
    func latestChronicle() -> ChronicleEntry? {
        chronicle.last
    }

    /// What the HUD should talk about: the most interesting recent event,
    /// falling back to the newest entry of any kind.
    func headline(maxAge: Float = 180) -> ChronicleEntry? {
        guard let latest = chronicle.last else { return nil }
        for entry in chronicle.reversed() where year - entry.year <= maxAge {
            switch entry.kind {
            case .era, .plague, .fire, .war, .drought, .boom, .quake, .abandon:
                return entry
            case .founding:
                continue
            }
        }
        return latest
    }
}

/// Shared settlement sizing, used by the road builder and the town builder so
/// they agree on where a town's built-up area ends.
enum SettlementMetrics {
    static func cityRadius(_ population: Float) -> Float {
        let r = 0.022 + 0.00095 * sqrt(max(population, 1))
        return min(max(r, 0.026), 0.100)
    }
}

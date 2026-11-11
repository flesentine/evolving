import Foundation
import AppKit
import ScreenSaver
import simd

// A small development tool:
//
//   civheadless snapshot <out.png> [width] [height] [seconds]
//   civheadless checkbundle <path-to.saver> [seconds]
//   civheadless info
//
// `snapshot` renders one frame of the scene offscreen so the visuals can be
// inspected without going through the screen saver host.
// `checkbundle` loads the built .saver bundle the way the system does, builds
// the view, runs it for a moment and reports how many frames were presented.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print("""
    usage:
      civheadless snapshot <out.png> [width] [height] [seconds]
      civheadless checkbundle <path-to.saver> [seconds]
      civheadless hostshot <out.png> [seconds]
      civheadless sheet <out.png>
      civheadless map <out.png> [seed]
      civheadless sim <out.png> [year] [hour] [seed] [cameraTime]
      civheadless bench [year] [width] [height] [frames]
      civheadless resources [seed]
      civheadless determinism [year] [seed]
      civheadless plan [year] [seed]
      civheadless river [seed] [year]
      civheadless info
    """)
    exit(2)
}

/// `EVOLVING_SEASON=0…1` pins the season for stills (0 summer, 1 winter).
/// `EVOLVING_CAMERA=ex,ey,ez,tx,ty,tz,fov` pins the camera for inspection.
func applyCameraOverride(_ renderer: Renderer) {
    guard let text = ProcessInfo.processInfo.environment["EVOLVING_CAMERA"] else { return }
    let parts = text.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 7 else { return }
    renderer.cameraOverride = Renderer.Camera(
        eye: SIMD3(parts[0], parts[1], parts[2]),
        target: SIMD3(parts[3], parts[4], parts[5]),
        fov: parts[6])
}

/// `EVOLVING_WEATHER=0…1` and `EVOLVING_SNOW=1` pin precipitation for stills.
func applyWeatherOverride(_ renderer: Renderer) {
    let env = ProcessInfo.processInfo.environment
    if let text = env["EVOLVING_WEATHER"], let weather = Float(text) {
        renderer.weatherOverride = min(max(weather, 0), 1)
    }
    if let text = env["EVOLVING_SNOW"] {
        renderer.snowOverride = text == "1"
    }
}

/// `EVOLVING_CAMERA_MODE=auto|wide|coast|city` pins the camera for stills.
func applyCameraMode(_ renderer: Renderer) {
    if let text = ProcessInfo.processInfo.environment["EVOLVING_CAMERA_MODE"],
       let mode = CameraMode(rawValue: text.capitalized) {
        renderer.cameraMode = mode
    }
}

func applySeasonOverride(_ renderer: Renderer) {
    if let text = ProcessInfo.processInfo.environment["EVOLVING_SEASON"],
       let season = Float(text) {
        renderer.seasonOverride = min(max(season, 0), 1)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

switch arguments[1] {

case "info":
    print("Evolving headless tool")
    if let device = MTLCreateSystemDefaultDevice() {
        print("metal device: \(device.name)")
    } else {
        print("metal device: none")
    }
    if let source = EvolvingShaderSource.source {
        print("shader source: \(source.count) bytes")
    } else {
        print("shader source: missing")
    }

case "river":
    let seed = arguments.count >= 3 ? UInt64(arguments[2]) ?? 1 : 1
    let year: Float = arguments.count >= 4 ? Float(arguments[3]) ?? 2336 : 2336
    let terrain = WorldGen.generate(seed: seed)
    let network = RiverNetwork.build(terrain)
    print("seed \(seed), year \(year)")
    print(network.diagnostics.summary)
    print("-- channel --")
    var channel = RiverChannel.diagnostics(terrain, network: network.reaches)

    // Check the objects the renderer will place against the same water
    // polygons it draws. Trees and buildings must stand clear of the channel.
    var simulation = Simulation(seed: seed, terrain: terrain)
    simulation.advance(to: year)
    let field = RiverChannel.Field(terrain: terrain, network: network.reaches)
    let geometry = CityBuilder.build(settlements: simulation.settlements,
                                     era: simulation.era,
                                     year: simulation.year,
                                     terrain: terrain,
                                     seed: seed,
                                     riverField: field)
    let trees = CityBuilder.trees(terrain: terrain,
                                  settlements: simulation.settlements,
                                  seed: seed,
                                  riverField: field)

    var clearance = Float.greatestFiniteMagnitude
    func check(_ instances: [InstanceData]) -> Int {
        var submerged = 0
        for instance in instances {
            let p = instance.model.columns.3
            if let water = field.waterLevel(at: SIMD2(p.x, p.z)),
               p.y < water + 0.000002 {
                submerged += 1
            }
            if let d = field.signedDistance(at: SIMD2(p.x, p.z)) {
                clearance = min(clearance, max(d, 0))
            }
        }
        return submerged
    }

    channel.submergedTrees = check(trees.conifers) + check(trees.broadleaves)
    channel.submergedBuildings = geometry.buildings.values.reduce(0) {
        $0 + check($1)
    }

    // Roads are lifted onto a ford or bridge at every crossing, so a street
    // point inside the water is a crossing rather than a submerged surface.
    var crossings: [SIMD2<Float>] = []
    for line in geometry.streetLines {
        for p in line.points where field.waterLevel(at: p) != nil {
            if crossings.allSatisfy({ simd_distance($0, p) > 0.005 }) {
                crossings.append(p)
            }
        }
    }
    channel.roadCrossings = crossings.count
    channel.minObjectClearance = clearance == .greatestFiniteMagnitude
        ? 0 : clearance * RiverChannel.metresPerUnit

    print(channel.summary)
    for reach in network.reaches.prefix(8) where reach.samples.count > 10 {
        let sample = reach.samples[reach.samples.count / 2]
        let ground = terrain.interpolatedHeight(x: sample.position.x,
                                                z: sample.position.y)
        print(String(format: "sample %+.4f,%+.4f ground %.5f water %.5f width %.1f m",
                     sample.position.x, sample.position.y, ground,
                     ground + RiverChannel.waterLift,
                     RiverChannel.halfWidth(sample) * 2
                        * RiverChannel.metresPerUnit))
    }
    var reported = 0
    for (path, list) in geometry.buildings {
        for instance in list where reported < 6 {
            let p = instance.model.columns.3
            if let water = field.waterLevel(at: SIMD2(p.x, p.z)),
               p.y < water + 0.000002 {
                print(String(format: "  wet building %@ at %+.4f,%+.4f ground %.5f water %.5f",
                             path as NSString, p.x, p.z, p.y, water))
                reported += 1
            }
        }
    }
    for p in crossings.prefix(6) {
        print(String(format: "crossing %+.4f, %+.4f", p.x, p.y))
    }
    if !network.diagnostics.passes || !channel.passes {
        exit(1)
    }

case "plan":
    let year = arguments.count >= 3 ? Float(arguments[2]) ?? 1200 : 1200
    let seed: UInt64 = arguments.count >= 4 ? UInt64(arguments[3]) ?? 1 : 1
    let terrain = WorldGen.generate(seed: seed)
    var simulation = Simulation(seed: seed, terrain: terrain)
    simulation.advance(to: year)
    let resources = ResourceMap(terrain: terrain, seed: seed)
    let style = CityBuilder.Style.forEra(simulation.era)
    let planner = CityBuilder.planner(for: simulation.era)
    print("year \(year), era \(simulation.era.name)")
    for settlement in simulation.settlements where settlement.isAlive {
        let plan = planner.plan(settlement: settlement,
                                resources: resources,
                                terrain: terrain,
                                seed: seed,
                                style: style)
        var histogram: [String: Int] = [:]
        for plot in plan.plots {
            histogram[plot.district.name, default: 0] += 1
        }
        let districts = histogram.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print(String(format: "  #%d (%+.3f,%+.3f) pop %5.0f  plots %3d  roads %3d  water %2d  wall %2d  %@",
                     settlement.id, settlement.x, settlement.z, settlement.population,
                     plan.plots.count, plan.roads.count,
                     plan.water?.count ?? 0, plan.wall?.count ?? 0,
                     districts as NSString))
        if !plan.landmarks.isEmpty || plan.aqueduct != nil {
            let kinds = plan.landmarks.map { "\($0.kind)" }.joined(separator: ",")
            print("      landmarks [\(kinds)] aqueduct \(plan.aqueduct?.count ?? 0)")
            for landmark in plan.landmarks {
                print(String(format: "        %@ at %+.3f,%+.3f scale %.4f",
                             "\(landmark.kind)" as NSString,
                             landmark.center.x, landmark.center.y, landmark.scale))
            }
            if let aqueduct = plan.aqueduct {
                for p in aqueduct.prefix(2) {
                    print(String(format: "        aqueduct %+.3f,%+.3f", p.x, p.y))
                }
            }
        }
        if let water = plan.water, let first = water.first, let last = water.last {
            print(String(format: "      water %+.3f,%+.3f -> %+.3f,%+.3f",
                         first.x, first.y, last.x, last.y))
        }
    }
    let ruins = simulation.settlements.filter { !$0.isAlive }
    if !ruins.isEmpty {
        print("ruins:\(ruins.count)")
        for ruin in ruins.prefix(8) {
            print(String(format: "  ruin #%d (%+.3f,%+.3f) abandoned %.0f",
                         ruin.id, ruin.x, ruin.z, ruin.abandoned))
        }
    }

case "determinism":
    let year = arguments.count >= 3 ? Float(arguments[2]) ?? 4200 : 4200
    let seed: UInt64 = arguments.count >= 4 ? UInt64(arguments[3]) ?? 1 : 1
    let terrain = WorldGen.generate(seed: seed)
    var first = Simulation(seed: seed, terrain: terrain)
    first.advance(to: year)
    var second = Simulation(seed: seed, terrain: terrain)
    second.advance(to: year)

    func hash(_ geometry: CityBuilder.Geometry) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ h: inout UInt64, _ list: [InstanceData]) {
            h = (h ^ UInt64(list.count)) &* 0x0000_0100_0000_01B3
            for instance in list {
                var copy = instance
                withUnsafeBytes(of: &copy) { raw in
                    for byte in raw {
                        h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
                    }
                }
            }
        }
        mix(&h, geometry.boxes)
        mix(&h, geometry.cones)
        mix(&h, geometry.gables)
        mix(&h, geometry.fields)
        mix(&h, geometry.streetLines.map {
            InstanceData(model: matrix_identity_float4x4,
                         color: SIMD4($0.points.first?.x ?? 0,
                                      $0.points.first?.y ?? 0,
                                      Float($0.points.count), $0.width))
        })
        for key in geometry.buildings.keys.sorted() {
            for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            mix(&h, geometry.buildings[key] ?? [])
        }
        mix(&h, geometry.smoke.map {
            InstanceData(model: matrix_identity_float4x4,
                         color: SIMD4($0.x, $0.y, $0.z, 0))
        })
        return h
    }

    let network = RiverNetwork.build(terrain).reaches
    let field = RiverChannel.Field(terrain: terrain, network: network)
    let a = CityBuilder.build(settlements: first.settlements,
                              era: first.era,
                              year: first.year,
                              terrain: terrain,
                              seed: seed,
                              riverField: field)
    let b = CityBuilder.build(settlements: second.settlements,
                              era: second.era,
                              year: second.year,
                              terrain: terrain,
                              seed: seed,
                              riverField: field)
    let ha = hash(a), hb = hash(b)
    print("year \(year), seed \(seed), era \(first.era.name)")
    print("settlements \(first.settlements.count), buildings \(a.buildings.values.reduce(0) { $0 + $1.count })")
    print(String(format: "geometry hash %016llx / %016llx", ha, hb))
    if ha != hb {
        fail("determinism failed — geometry differs between identical runs")
    }
    print("deterministic: OK")

case "resources":
    let seed = arguments.count >= 3 ? UInt64(arguments[2]) ?? 1 : 1
    let terrain = WorldGen.generate(seed: seed)
    let map = ResourceMap(terrain: terrain, seed: seed)

    var totals = [Float](repeating: 0, count: 8)
    var maximums = [Float](repeating: 0, count: 8)
    var landSamples = 0
    let steps = 96
    for j in 0..<steps {
        for i in 0..<steps {
            let x = Float(i) / Float(steps - 1) * 2 - 1
            let z = Float(j) / Float(steps - 1) * 2 - 1
            guard terrain.heightAt(x: x, z: z) > 0.004 else { continue }
            let r = map.sample(x: x, z: z)
            let values = [r.fertility, r.freshWater, r.timber, r.stone,
                          r.ore, r.coast, r.buildability, r.routeAccess]
            for k in 0..<values.count {
                totals[k] += values[k]
                maximums[k] = max(maximums[k], values[k])
            }
            landSamples += 1
        }
    }

    let names = ["fertility", "water", "timber", "stone",
                 "ore", "coast", "buildable", "route"]
    print("seed \(seed), \(landSamples) land samples")
    for k in 0..<names.count {
        let mean = landSamples > 0 ? totals[k] / Float(landSamples) : 0
        print(String(format: "  %-10@ mean %.2f  max %.2f",
                     names[k] as NSString, mean, maximums[k]))
    }

    // Best site per era on a coarse candidate grid, to check that the same
    // island offers different centres to different eras.
    var candidates: [SIMD2<Float>] = []
    for j in 0..<64 {
        for i in 0..<64 {
            let x = Float(i) / 63 * 2 - 1
            let z = Float(j) / 63 * 2 - 1
            if terrain.heightAt(x: x, z: z) > 0.006 {
                candidates.append(SIMD2(x, z))
            }
        }
    }
    print("best site per era:")
    for era in Era.allCases {
        guard let site = map.bestSite(among: candidates, era: era) else { continue }
        let score = map.sample(site).score(for: era)
        print(String(format: "  %-12@ %+0.3f, %+0.3f  score %.2f",
                     era.name as NSString, site.x, site.y, score))
    }

case "map":
    guard arguments.count >= 3 else { usage() }
    let out = URL(fileURLWithPath: arguments[2])
    let seed = arguments.count >= 4 ? UInt64(arguments[3]) ?? 1 : 1
    do {
        let terrain = WorldGen.generate(seed: seed)
        try MapImage.write(terrain, seed: seed, to: out)
        var landCells = 0, riverCells = 0
        for i in 0..<terrain.height.count {
            if terrain.height[i] > 0 { landCells += 1 }
            if terrain.river[i] > 0 { riverCells += 1 }
        }
        let total = terrain.height.count
        print("wrote \(out.path)")
        print("grid \(terrain.size)x\(terrain.size), max height \(terrain.maxHeight)")
        print("land \(String(format: "%.1f", Double(landCells) / Double(total) * 100))%, river cells \(riverCells)")
    } catch {
        fail("map failed — \(error)")
    }

case "sim":
    guard arguments.count >= 3 else { usage() }
    let out = URL(fileURLWithPath: arguments[2])
    let simYear = arguments.count >= 4 ? Float(arguments[3]) ?? 0 : 0
    let hour = arguments.count >= 5 ? Float(arguments[4]) ?? 10 : 10
    let seed: UInt64 = arguments.count >= 6 ? UInt64(arguments[5]) ?? 1 : 1
    let seconds = arguments.count >= 7 ? Float(arguments[6]) ?? 0 : 0

    do {
        let context = try MetalContext()
        let terrain = WorldGen.generate(seed: seed)
        var simulation = Simulation(seed: seed, terrain: terrain)

        let started = Date()
        simulation.advance(to: simYear)
        let elapsed = Date().timeIntervalSince(started)

        let renderer = try Renderer(context: context,
                                    terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb,
                                    depthPixelFormat: .depth32Float)
        renderer.hourOverride = hour
        applySeasonOverride(renderer)
        applyWeatherOverride(renderer)
        applyCameraMode(renderer)
        applyCameraOverride(renderer)
        renderer.updateScene(simulation)
        renderer.updateTrees(CityBuilder.trees(terrain: renderer.scene.terrain,
                                               settlements: simulation.settlements,
                                               seed: seed,
                                               riverField: renderer.scene.riverField))

        let env = ProcessInfo.processInfo.environment
        let width = Int(env["EVOLVING_WIDTH"] ?? "") ?? 1600
        let height = Int(env["EVOLVING_HEIGHT"] ?? "") ?? 1000
        let url = try Snapshot.write(renderer: renderer,
                                     width: width, height: height, time: seconds, to: out)

        print("wrote \(url.path)")
        print("  year \(Int(simulation.year)) · \(simulation.era.name)")
        print("  population \(Int(simulation.totalPopulation)) in \(simulation.settlements.count) settlements")
        print("  boxes \(renderer.boxBatch.count) · roofs/trees \(renderer.coneBatch.count)")
        print(String(format: "  replay took %.1f ms", elapsed * 1000))
        if let largest = simulation.largestSettlement() {
            print(String(format: "  largest: %@ (%d) at %.4f, %.4f",
                         largest.name, Int(largest.population), largest.x, largest.z))
        }
        if let last = simulation.latestChronicle() {
            print("  latest: year \(Int(last.year)) — \(last.text)")
        }
    } catch {
        fail("sim failed — \(error)")
    }

case "bench":
    let simYear = arguments.count >= 3 ? Float(arguments[2]) ?? 3000 : 3000
    let width = arguments.count >= 4 ? Int(arguments[3]) ?? 6016 : 6016
    let height = arguments.count >= 5 ? Int(arguments[4]) ?? 3384 : 3384
    let frames = arguments.count >= 6 ? Int(arguments[5]) ?? 6 : 6

    do {
        let context = try MetalContext()
        let terrain = WorldGen.generate(seed: 1)
        var simulation = Simulation(seed: 1, terrain: terrain)
        simulation.advance(to: simYear)
        let renderer = try Renderer(context: context,
                                    terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb,
                                    depthPixelFormat: .depth32Float)
        renderer.hourOverride = 12
        applySeasonOverride(renderer)
        applyWeatherOverride(renderer)
        applyCameraMode(renderer)
        applyCameraOverride(renderer)
        renderer.updateScene(simulation)
        renderer.updateTrees(CityBuilder.trees(terrain: renderer.scene.terrain,
                                               settlements: simulation.settlements,
                                               seed: 1,
                                               riverField: renderer.scene.riverField))

        let scale = renderer.renderScale(width: width, height: height)
        let ms = try Snapshot.measure(renderer: renderer,
                                      width: width, height: height,
                                      frames: frames, time: 40)
        print(String(format: "%.2f ms/frame at %dx%d (scene scale %.2f) -> %.1f fps",
                     ms, width, height, scale, 1000.0 / max(ms, 0.001)))
    } catch {
        fail("bench failed — \(error)")
    }

case "snapshot":
    guard arguments.count >= 3 else { usage() }
    let out = URL(fileURLWithPath: arguments[2])
    let width = arguments.count >= 4 ? Int(arguments[3]) ?? 1600 : 1600
    let height = arguments.count >= 5 ? Int(arguments[4]) ?? 1000 : 1000
    let seconds = arguments.count >= 6 ? Float(arguments[5]) ?? 0 : 0
    let hour = arguments.count >= 7 ? Float(arguments[6]) ?? 10 : 10

    do {
        let context = try MetalContext()
        let terrain = WorldGen.generate(seed: 1)
        let renderer = try Renderer(context: context,
                                    terrain: terrain,
                                    colorPixelFormat: .bgra8Unorm_srgb,
                                    depthPixelFormat: .depth32Float)
        renderer.hourOverride = hour
        applySeasonOverride(renderer)
        let url = try Snapshot.write(renderer: renderer,
                                     width: width,
                                     height: height,
                                     time: seconds,
                                     to: out)
        print("wrote \(url.path) (\(width)x\(height), hour \(hour)) on \(context.device.name)")
    } catch {
        fail("snapshot failed — \(error)")
    }

case "checkbundle":
    guard arguments.count >= 3 else { usage() }
    let path = arguments[2]
    let seconds = arguments.count >= 4 ? Double(arguments[3]) ?? 1.5 : 1.5

    guard let bundle = Bundle(path: path) else {
        fail("not a bundle: \(path)")
    }
    guard bundle.load() else {
        fail("bundle failed to load: \(path)")
    }
    print("loaded bundle: \(bundle.bundleIdentifier ?? "<no id>")")

    guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
        fail("principal class is not a ScreenSaverView: \(String(describing: bundle.principalClass))")
    }
    print("principal class: \(principal)")

    let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    guard let view = principal.init(frame: frame, isPreview: false) else {
        fail("principal class failed to initialise")
    }
    print("view created: \(type(of: view))")

    let window = NSWindow(contentRect: frame,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.contentView = view
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .screenSaver
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()

    view.startAnimation()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    view.stopAnimation()

    let frames = (view.value(forKey: "framesDrawn") as? Int) ?? -1
    window.orderOut(nil)

    print("frames presented in \(seconds)s: \(frames)")
    if frames <= 0 {
        fail("the saver view did not present any frames")
    }
    print("OK")

case "hostshot":
    guard arguments.count >= 3 else { usage() }
    let out = URL(fileURLWithPath: arguments[2])
    let seconds = arguments.count >= 4 ? Double(arguments[3]) ?? 2.0 : 2.0

    guard let bundle = Bundle(path: "build/Evolving.saver"), bundle.load() else {
        fail("build the bundle first with Scripts/build.sh")
    }
    guard let principal = bundle.principalClass as? ScreenSaverView.Type,
          let view = principal.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                    isPreview: false) else {
        fail("could not create the saver view")
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.contentView = view
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.level = .screenSaver
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()

    view.startAnimation()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    view.stopAnimation()

    do {
        let url = try HostShot.capture(window: window, to: out)
        print("wrote \(url.path)")
        let frames = (view.value(forKey: "framesDrawn") as? Int) ?? -1
        print(String(format: "frames: %d (%.1f fps)", frames, Double(frames) / seconds))
    } catch {
        window.orderOut(nil)
        fail("hostshot failed — \(error)")
    }
    window.orderOut(nil)

case "sheet":
    guard arguments.count >= 3 else { usage() }
    let out = URL(fileURLWithPath: arguments[2])

    guard let bundle = Bundle(path: "build/Evolving.saver"), bundle.load() else {
        fail("build the bundle first with Scripts/build.sh")
    }
    guard let principal = bundle.principalClass as? ScreenSaverView.Type,
          let view = principal.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                                    isPreview: true) else {
        fail("could not create the saver view")
    }
    guard let sheet = view.configureSheet else {
        fail("the saver did not provide a configure sheet")
    }

    sheet.orderFrontRegardless()
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))

    do {
        let url = try HostShot.capture(window: sheet, to: out)
        print("wrote \(url.path)")
    } catch {
        sheet.orderOut(nil)
        fail("sheet capture failed — \(error)")
    }
    sheet.orderOut(nil)

default:
    usage()
}

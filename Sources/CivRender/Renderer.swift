import Foundation
import Metal
import MetalKit
import QuartzCore

/// A mesh plus the instance buffer that feeds it.
final class InstanceBatch {
    let mesh: Mesh
    private(set) var buffer: MTLBuffer
    private(set) var count: Int = 0

    init(mesh: Mesh, device: MTLDevice, capacity: Int = 64) {
        self.mesh = mesh
        self.buffer = device.makeBuffer(length: MemoryLayout<InstanceData>.stride * max(capacity, 1),
                                        options: .storageModeShared)!
    }

    func update(_ instances: [InstanceData], device: MTLDevice) {
        let stride = MemoryLayout<InstanceData>.stride
        let needed = stride * instances.count

        if needed > buffer.length {
            let capacity = max(needed * 3 / 2, stride * 256)
            guard let bigger = device.makeBuffer(length: capacity, options: .storageModeShared) else { return }
            buffer = bigger
        }

        if !instances.isEmpty {
            instances.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: needed)
            }
        }
        count = instances.count
    }
}

/// Owns the render pipelines and the scene, and can draw either into an
/// `MTKView` (screen saver) or into an offscreen texture (snapshot tooling).
final class Renderer: NSObject, MTKViewDelegate {

    /// Must stay byte-identical to `struct FrameUniforms` in Shaders.metal.
    struct FrameUniforms {
        var viewProjection: simd_float4x4
        var lightViewProjection: simd_float4x4
        var inverseViewProjection: simd_float4x4
        var cameraAndTime: SIMD4<Float>
        var sunAndPad: SIMD4<Float>
        var night: SIMD4<Float>
        var shadow: SIMD4<Float>
        var closeLightViewProjection: simd_float4x4
        var closeShadow: SIMD4<Float>
    }

    /// Must stay byte-identical to `struct PostUniforms` in Shaders.metal.
    struct PostUniforms {
        var params: SIMD4<Float>   // focusY, band, feather, maxBlurPixels
        var extra: SIMD4<Float>    // time, vignette, bloom, unused
        var view: SIMD4<Float>     // sceneScale, grain, unused, unused
        var grade: SIMD4<Float>    // warmth, contrast, saturation, unused
    }

    struct Camera {
        var eye: SIMD3<Float>
        var target: SIMD3<Float>
        var fov: Float
    }

    private struct CarPath {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        var length: Float
        var speed: Float
        var phase: Float
        var colour: SIMD3<Float>
        var isCart: Bool
    }

    private struct BoatPath {
        var radius: Float
        var speed: Float
        var phase: Float
    }

    let context: MetalContext
    let scene: WorldScene

    let boxBatch: InstanceBatch
    let coneBatch: InstanceBatch
    private let identityBatch: InstanceBatch
    private var roadIdentityBuffer: MTLBuffer?
    private var streetIdentityBuffer: MTLBuffer?
    private var railIdentityBuffer: MTLBuffer?
    private var riverIdentityBuffer: MTLBuffer?
    private var bankIdentityBuffer: MTLBuffer?
    private var buildingBatches: [(path: String, batch: InstanceBatch)] = []
    private var nearbyBuildings: Set<String> = []
    private var dynamicScale: Float = 1.0
    private var smoothedFrameMS: Double = 16
    private var frameSamples: Int = 0
    private var buildingAtlas: MTLTexture?
    private var signAtlas: MTLTexture?
    private var townSignTexture: MTLTexture?
    private var townSignCells: [Int32: Int] = [:]
    private var signalTemplate: [InstanceData] = []
    private var signalBaseBias: [Float] = []
    private var signalLearnedBias: [Float] = []
    private var buildingNormal: MTLTexture?
    private var buildingRoughness: MTLTexture?
    private var groundAlbedo: MTLTexture?
    private var groundFine: MTLTexture?
    private var groundFineNormal: MTLTexture?
    private var groundNormal: MTLTexture?
    private var rockAlbedo: MTLTexture?
    private var rockNormal: MTLTexture?

    /// Local hour used to place the sun. `nil` follows the real clock.
    var hourOverride: Float?

    /// Season 0 (midsummer) … 1 (midwinter). `nil` follows the real month.
    var seasonOverride: Float?

    /// 0…1 precipitation override for stills; `nil` follows the real weather.
    var weatherOverride: Float?
    var snowOverride: Bool?

    /// `auto` cycles the shots; the others pin one framing.
    var cameraMode: CameraMode = .auto

    /// Explicit choice from the options sheet, or auto-detected from the region.
    var southernHemisphere: Bool = Renderer.detectSouthernHemisphere()

    static func detectSouthernHemisphere() -> Bool {
        if let text = ProcessInfo.processInfo.environment["EVOLVING_HEMISPHERE"]?.lowercased() {
            return text == "south" || text == "southern"
        }
        let southern: Set<String> = [
            "AU", "NZ", "ZA", "AR", "CL", "UY", "PY", "BO", "PE", "BR",
            "EC", "ID", "PG", "FJ", "MG", "NA", "BW", "ZW", "MZ", "AO",
            "TZ", "ZM", "MW", "LS", "SZ", "TL"
        ]
        if let region = Locale.current.region?.identifier, southern.contains(region) {
            return true
        }
        return false
    }

    /// Camera override used by the snapshot tool.
    var cameraOverride: Camera?

    private struct FreeOrbit {
        var yaw: Float
        var pitch: Float
        var distance: Float
        var target: SIMD3<Float>
    }
    private var freeOrbit: FreeOrbit?

    /// Starts an interactive orbit around the focused town. Idempotent, so a
    /// drag does not reset the view on every mouse-down.
    func beginFreeCamera() {
        if freeOrbit != nil { return }
        let ground = scene.terrain.interpolatedHeight(x: focusPoint.x, z: focusPoint.z)
        let target = SIMD3<Float>(focusPoint.x, ground + 0.006, focusPoint.z)
        let distance = max(focusRadius * 5.0, 0.055)
        freeOrbit = FreeOrbit(yaw: squareAngle + 0.6, pitch: 0.55,
                              distance: distance, target: target)
        applyFreeCamera()
    }

    func orbitCamera(dx: Float, dy: Float) {
        if freeOrbit == nil { beginFreeCamera() }
        guard var orbit = freeOrbit else { return }
        orbit.yaw += dx
        orbit.pitch = min(max(orbit.pitch + dy, 0.10), 1.35)
        freeOrbit = orbit
        applyFreeCamera()
    }

    func zoomCamera(_ factor: Float) {
        if freeOrbit == nil { beginFreeCamera() }
        guard var orbit = freeOrbit else { return }
        orbit.distance = min(max(orbit.distance * factor, 0.008), 0.45)
        freeOrbit = orbit
        applyFreeCamera()
    }

    func panCamera(dx: Float, dy: Float) {
        if freeOrbit == nil { beginFreeCamera() }
        guard var orbit = freeOrbit else { return }
        let right = SIMD3<Float>(cos(orbit.yaw + .pi / 2), 0,
                                 sin(orbit.yaw + .pi / 2))
        let forward = SIMD3<Float>(cos(orbit.yaw), 0, sin(orbit.yaw))
        orbit.target += right * (dx * orbit.distance)
            + forward * (-dy * orbit.distance)
        freeOrbit = orbit
        applyFreeCamera()
    }

    func endFreeCamera() {
        freeOrbit = nil
        cameraOverride = nil
    }

    private func applyFreeCamera() {
        guard let orbit = freeOrbit else { return }
        let horizontal = cos(orbit.pitch) * orbit.distance
        let eye = orbit.target + SIMD3<Float>(cos(orbit.yaw) * horizontal,
                                              sin(orbit.pitch) * orbit.distance,
                                              sin(orbit.yaw) * horizontal)
        cameraOverride = Camera(eye: eye, target: orbit.target, fov: 48)
    }

    /// Where the close-up shot looks, damped so it drifts rather than jumps.
    private var focusPoint = SIMD3<Float>(0, 0, 0)

    private let meshPipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let smokePipeline: MTLRenderPipelineState
    private let weatherPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let depthWriting: MTLDepthStencilState
    private let depthDisabled: MTLDepthStencilState
    private let waterDepthState: MTLDepthStencilState

    /// Offscreen scene target, reused every frame. The post pass reads it.
    private var sceneColor: MTLTexture?
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var sceneWidth = 0
    private var sceneHeight = 0
    private var postColor: MTLTexture?
    private var postWidth = 0
    private var postHeight = 0
    private var currentNight: Float = 0
    private var currentElevation: Float = 0.5
    private var closeAzimuth: Float = 0
    private var livingSettlements: [Settlement] = []
    private var focusRadius: Float = 0.05
    private var streetGrids: [CityBuilder.StreetGrid] = []
    private var squareAngle: Float = 0
    private var hasFocus = false
    private var carPaths: [CarPath] = []
    private var boatPaths: [BoatPath] = []
    private var railPoints: [SIMD2<Float>] = []
    private var railCumulative: [Float] = []
    private var railLength: Float = 0
    private var smokeEmitters: [SIMD3<Float>] = []
    private var weatherIntensity: Float = 0
    private var weatherIsSnow = false
    private var shadowMap: MTLTexture?
    private var closeShadowMap: MTLTexture?
    private var currentLightVP = matrix_identity_float4x4
    private var currentCloseLightVP = matrix_identity_float4x4
    private let shadowSize = 4096
    private let closeShadowSize = 4096

    /// 4× MSAA smooths coastlines and building silhouettes; the post pass reads
    /// the resolved single-sample texture.
    static let msaaSampleCount = 2

    private let startTime: CFTimeInterval

    @objc dynamic private(set) var framesDrawn: Int = 0

    init(context: MetalContext,
         terrain: Terrain,
         colorPixelFormat: MTLPixelFormat,
         depthPixelFormat: MTLPixelFormat) throws {
        self.context = context
        self.scene = try WorldScene(context: context, terrain: terrain)
        self.startTime = CACurrentMediaTime()

        let device = context.device

        func makePipeline(_ label: String,
                          _ vertex: String,
                          _ fragment: String,
                          blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = label
            desc.vertexFunction = try context.makeFunction(vertex)
            desc.fragmentFunction = try context.makeFunction(fragment)
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            desc.depthAttachmentPixelFormat = depthPixelFormat
            desc.rasterSampleCount = Renderer.msaaSampleCount
            if blending {
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].alphaBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do {
                return try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                throw MetalSetupError.pipeline(String(describing: error))
            }
        }

        meshPipeline  = try makePipeline("Evolving mesh",  "meshVertex",  "meshFragment",  blending: false)
        waterPipeline = try makePipeline("Evolving water", "meshVertex",  "waterFragment", blending: true)
        skyPipeline   = try makePipeline("Evolving sky",   "skyVertex",   "skyFragment",   blending: false)

        smokePipeline = try makePipeline("Evolving smoke", "meshVertex", "smokeFragment", blending: true)
        weatherPipeline = try makePipeline("Evolving weather", "meshVertex", "weatherFragment", blending: true)

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label = "Evolving shadow"
        shadowDesc.vertexFunction = try context.makeFunction("meshVertex")
        shadowDesc.fragmentFunction = nil
        shadowDesc.colorAttachments[0].pixelFormat = .invalid
        shadowDesc.depthAttachmentPixelFormat = .depth32Float
        shadowDesc.rasterSampleCount = 1
        do {
            shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDesc)
        } catch {
            throw MetalSetupError.pipeline(String(describing: error))
        }

        let shadowMapDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                     width: shadowSize,
                                                                     height: shadowSize,
                                                                     mipmapped: false)
        shadowMapDesc.usage = [.renderTarget, .shaderRead]
        shadowMapDesc.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowMapDesc)

        let closeDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                 width: closeShadowSize,
                                                                 height: closeShadowSize,
                                                                 mipmapped: false)
        closeDesc.usage = [.renderTarget, .shaderRead]
        closeDesc.storageMode = .private
        closeShadowMap = device.makeTexture(descriptor: closeDesc)

        let postDesc = MTLRenderPipelineDescriptor()
        postDesc.label = "Evolving post"
        postDesc.vertexFunction = try context.makeFunction("postVertex")
        postDesc.fragmentFunction = try context.makeFunction("postFragment")
        postDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        postDesc.depthAttachmentPixelFormat = .invalid
        postDesc.rasterSampleCount = 1
        do {
            postPipeline = try device.makeRenderPipelineState(descriptor: postDesc)
        } catch {
            throw MetalSetupError.pipeline(String(describing: error))
        }

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.label = "Evolving blit"
        blitDesc.vertexFunction = try context.makeFunction("postVertex")
        blitDesc.fragmentFunction = try context.makeFunction("blitFragment")
        blitDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        blitDesc.depthAttachmentPixelFormat = .invalid
        blitDesc.rasterSampleCount = 1
        do {
            blitPipeline = try device.makeRenderPipelineState(descriptor: blitDesc)
        } catch {
            throw MetalSetupError.pipeline(String(describing: error))
        }

        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .less
        writeDesc.isDepthWriteEnabled = true
        guard let writing = device.makeDepthStencilState(descriptor: writeDesc) else {
            throw MetalSetupError.pipeline("depth state")
        }
        depthWriting = writing

        let alwaysDesc = MTLDepthStencilDescriptor()
        alwaysDesc.depthCompareFunction = .always
        alwaysDesc.isDepthWriteEnabled = false
        guard let always = device.makeDepthStencilState(descriptor: alwaysDesc) else {
            throw MetalSetupError.pipeline("depth state")
        }
        depthDisabled = always

        let noWriteDesc = MTLDepthStencilDescriptor()
        noWriteDesc.depthCompareFunction = .less
        noWriteDesc.isDepthWriteEnabled = false
        guard let noWrite = device.makeDepthStencilState(descriptor: noWriteDesc) else {
            throw MetalSetupError.pipeline("depth state")
        }
        waterDepthState = noWrite

        identityBatch = InstanceBatch(mesh: scene.terrainMesh, device: device, capacity: 1)
        boxBatch = InstanceBatch(mesh: scene.cubeMesh, device: device, capacity: 512)
        coneBatch = InstanceBatch(mesh: scene.coneMesh, device: device, capacity: 512)

        super.init()

        identityBatch.update([InstanceData(model: matrix_identity_float4x4,
                                           color: SIMD4<Float>(1, 1, 1, 0),
                                           material: SIMD4<Float>(8, 0, 0, 0))],
                             device: device)
        roadIdentityBuffer = Renderer.makeIdentityBuffer(device: device, material: 11)
        streetIdentityBuffer = Renderer.makeIdentityBuffer(device: device, material: 12)
        railIdentityBuffer = Renderer.makeIdentityBuffer(device: device, material: 13)
        riverIdentityBuffer = Renderer.makeIdentityBuffer(device: device, material: 18)
        bankIdentityBuffer = Renderer.makeIdentityBuffer(device: device, material: 8)

        for (path, mesh) in scene.buildingMeshes {
            buildingBatches.append((path, InstanceBatch(mesh: mesh, device: device, capacity: 256)))
        }

        if let url = AssetStore.url(named: "buildings-atlas.png") {
            let loader = MTKTextureLoader(device: device)
            buildingAtlas = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: true),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "sign-atlas.png") {
            let loader = MTKTextureLoader(device: device)
            signAtlas = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: true),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "buildings-normal.png") {
            let loader = MTKTextureLoader(device: device)
            buildingNormal = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: false),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "buildings-roughness.png") {
            let loader = MTKTextureLoader(device: device)
            buildingRoughness = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: false),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if buildingRoughness == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let texture = device.makeTexture(descriptor: desc) {
                var pixel: [UInt8] = [200, 200, 200, 255]
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                mipmapLevel: 0, withBytes: &pixel,
                                bytesPerRow: 4)
                buildingRoughness = texture
            }
        }
        if let url = AssetStore.url(named: "Terrain/ground-albedo.png") {
            let loader = MTKTextureLoader(device: device)
            groundAlbedo = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: true),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "Terrain/ground-normal.png") {
            let loader = MTKTextureLoader(device: device)
            groundNormal = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: false),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "Terrain/ground-fine.png") {
            let loader = MTKTextureLoader(device: device)
            groundFine = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: true),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "Terrain/ground-fine-normal.png") {
            let loader = MTKTextureLoader(device: device)
            groundFineNormal = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: false),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if groundAlbedo == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let texture = device.makeTexture(descriptor: desc) {
                var pixel: [UInt8] = [220, 220, 220, 255]
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                mipmapLevel: 0, withBytes: &pixel,
                                bytesPerRow: 4)
                groundAlbedo = texture
            }
        }
        if let url = AssetStore.url(named: "Terrain/rock-albedo.png") {
            let loader = MTKTextureLoader(device: device)
            rockAlbedo = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: true),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if let url = AssetStore.url(named: "Terrain/rock-normal.png") {
            let loader = MTKTextureLoader(device: device)
            rockNormal = try? loader.newTexture(URL: url, options: [
                .SRGB: NSNumber(value: false),
                .generateMipmaps: NSNumber(value: true)
            ])
        }
        if groundNormal == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let texture = device.makeTexture(descriptor: desc) {
                var pixel: [UInt8] = [128, 128, 255, 255]
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                mipmapLevel: 0, withBytes: &pixel,
                                bytesPerRow: 4)
                groundNormal = texture
            }
        }
        if buildingNormal == nil {
            // Flat normal fallback, so the shader always has something bound.
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let texture = device.makeTexture(descriptor: desc) {
                var pixel: [UInt8] = [128, 128, 255, 255]
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                mipmapLevel: 0, withBytes: &pixel,
                                bytesPerRow: 4)
                buildingNormal = texture
            }
        }
    }

    // MARK: - Scene updates

    /// Rebuilds every derived mesh from the simulation. Called once per sim year.
    func updateScene(_ simulation: Simulation) {
        livingSettlements = simulation.settlements.filter { $0.isAlive }
        let geometry = CityBuilder.build(settlements: simulation.settlements,
                                         era: simulation.era,
                                         year: simulation.year,
                                         terrain: scene.terrain,
                                         seed: simulation.seed,
                                         riverField: scene.riverField)
        boxBatch.update(geometry.boxes, device: context.device)
        coneBatch.update(geometry.cones, device: context.device)
        gableBatch.update(geometry.gables, device: context.device)
        archBatch.update(geometry.arches, device: context.device)
        fieldBatch.update(geometry.fields, device: context.device)
        smokeEmitters = geometry.smoke
        for entry in buildingBatches {
            entry.batch.update(geometry.buildings[entry.path] ?? [], device: context.device)
        }

        // Only houses near the camera's town need to cast shadows; distant
        // towns are outside the visible frame and would cost 30-50 extra draws.
        var nearby = Set<String>()
        for (path, list) in geometry.buildings {
            for instance in list {
                let p = instance.model.columns.3
                if simd_distance(SIMD3(p.x, p.y, p.z), focusPoint) < 0.65 {
                    nearby.insert(path)
                    break
                }
            }
        }
        nearbyBuildings = nearby
        streetGrids = geometry.streets

        if let largest = simulation.largestSettlement() {
            let target = SIMD3<Float>(largest.x, 0, largest.z)
            if hasFocus {
                focusPoint += (target - focusPoint) * 0.25
            } else {
                focusPoint = target
                hasFocus = true
            }
            focusRadius = CityBuilder.cityRadius(largest.population)
            updateCloseAzimuth()
            squareAngle = clearAngle(radius: focusRadius * 2.30 + 0.012)
        }

        // Roads only change when a settlement appears or the era (and with it
        // the road surface) changes, so the A* pass is not run every frame.
        let alive = simulation.settlements.reduce(0) { $1.isAlive ? $0 + 1 : $0 }
        if alive != lastRoadSettlementCount || simulation.era != lastRoadEra {
            lastRoadSettlementCount = alive
            lastRoadEra = simulation.era
            let segments = RoadBuilder.segments(for: simulation, terrain: scene.terrain)
            let style = Renderer.roadStyle(for: simulation.era)
            do {
                try scene.rebuildRoads(segments, color: style.color,
                                   bridgeColor: style.bridge,
                                   marking: style.marking, width: style.width,
                                   surface: RoadSurface.forRoad(simulation.era),
                                   bridge: BridgeStyle.forEra(simulation.era))
            } catch {
                NSLog("Evolving: road mesh failed — \(error)")
            }
            rebuildLamps(segments, era: simulation.era)
            let namedSettlements = simulation.settlements
                .filter { $0.isAlive }
                .map { (id: $0.id, name: $0.name) }
            let atlas = TownSignAtlas.make(device: context.device,
                                           settlements: namedSettlements)
            townSignTexture = atlas.texture
            townSignCells = atlas.cells
            rebuildTraffic(segments, era: simulation.era)
            if ProcessInfo.processInfo.environment["EVOLVING_ROAD_PROPS"] != "0" {
                rebuildRoadProps(segments, simulation: simulation)
            } else {
                roadPropBatch.update([], device: context.device)
                roadPropGableBatch.update([], device: context.device)
                catEyeBatch.update([], device: context.device)
                townSignBatch.update([], device: context.device)
                crestBatch.update([], device: context.device)
                emblemBatch.update([], device: context.device)
                signalTemplate = []
                signalBaseBias = []
                signalLearnedBias = []
                sprayBatch.update([], device: context.device)
            }
            rebuildRailPath(segments, era: simulation.era)
        }

        // The streets inside each town follow the same terrain-hugging ribbon
        // as the island roads, at town scale.
        let streetStyle = Renderer.roadStyle(for: simulation.era)
        do {
            try scene.rebuildStreets(geometry.streetLines,
                                     color: streetStyle.color * 0.58,
                                     surface: RoadSurface.forStreet(simulation.era))
        } catch {
            NSLog("Evolving: street mesh failed — \(error)")
        }
    }

    /// Milestones, signposts, tollhouses, cairns, ford posts and cat's eyes.
    /// Slowly adapt signal green bias to the queue waiting at each junction.
    private func updateSignalQueues(_ carPositions: [SIMD2<Float>]) {
        guard !signalTemplate.isEmpty else { return }
        var updated = signalTemplate
        var index = 0
        var group = 0
        while index + 2 < updated.count {
            let p = updated[index].model.columns.3
            let centre = SIMD2<Float>(p.x, p.z)
            var queue = 0
            for car in carPositions
                where simd_distance(car, centre) < 0.020 { queue += 1 }
            let target = min(1.0, max(0.05,
                                     signalBaseBias[min(group, signalBaseBias.count - 1)]
                                     * 0.40 + Float(queue) * 0.10))
            let learned = signalLearnedBias[min(group, signalLearnedBias.count - 1)]
            let next = learned + (target - learned) * 0.02
            signalLearnedBias[group] = next
            for k in 0..<3 {
                updated[index + k].material.z = next
            }
            index += 3
            group += 1
        }
        trafficLightBatch.update(updated, device: context.device)
    }

    private func rebuildRoadProps(_ segments: [RoadBuilder.Segment],
                                  simulation: Simulation) {
        let era = simulation.era
        var props: [InstanceData] = []
        var roofs: [InstanceData] = []
        var eyes: [InstanceData] = []
        var plates: [InstanceData] = []
        var signals: [InstanceData] = []
        var townPlates: [InstanceData] = []
        var crests: [InstanceData] = []
        var signalBase: [Float] = []
        var emblems: [InstanceData] = []

        let baseWidth = Renderer.roadStyle(for: era).width
        let speeds = carPaths.filter { !$0.isCart }.map { $0.speed }
        let averageSpeed = speeds.isEmpty
            ? 0.0025
            : speeds.reduce(0, +) / Float(speeds.count)
        let wavelength = min(max(0.035 * (averageSpeed / 0.0025), 0.020), 0.060)
        let stone = era.rawValue >= Era.industrial.rawValue
            ? SIMD3<Float>(0.46, 0.45, 0.42)
            : SIMD3<Float>(0.62, 0.60, 0.55)
        let wood = SIMD3<Float>(0.32, 0.24, 0.16)
        let roofColour = SIMD3<Float>(0.34, 0.28, 0.26)
        let eyeColour = SIMD3<Float>(0.95, 0.93, 0.78)

        for segment in segments {
            let path = segment.points
            guard path.count >= 2 else { continue }
            let segmentWidth = max(baseWidth * segment.widthScale, 0.0008)
            let half = segmentWidth * 0.5

            var travelled: Float = 0
            var nextMilestone: Float = 0.030
            var nextCairn: Float = 0.034
            var nextTollhouse: Float = 0.055
            var nextEye: Float = 0.005
            var nextSignal: Float = 0.020
            var wasRiver = false

            func point(_ t: Float, _ lateral: Float) -> SIMD2<Float> {
                let a = path[min(max(Int(t), 0), path.count - 2)]
                let b = path[min(Int(t) + 1, path.count - 1)]
                let d = max(simd_distance(a, b), 1e-6)
                let dir = (b - a) / d
                let side = SIMD2(-dir.y, dir.x)
                let p = a + (b - a) * (t - floor(t))
                return p + side * lateral
            }

            for i in 0..<(path.count - 1) {
                let a = path[i], b = path[i + 1]
                let d = simd_distance(a, b)
                guard d > 1e-6 else { continue }
                let dir = (b - a) / d
                let side = SIMD2(-dir.y, dir.x)
                let heading = atan2(dir.x, dir.y)
                let river = scene.terrain.riverAt(x: a.x, z: a.y) > 0

                // Ford/bridge marker posts at the water's edge.
                if river && !wasRiver {
                    for s in [Float(-1), Float(1)] {
                        let p = a + side * (s * (half + 0.0006))
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        guard g > 0.004 else { continue }
                        let model = translation(SIMD3(p.x, g + 0.0009, p.y))
                            * scaleMatrix(SIMD3(0.00010, 0.00050, 0.00010))
                        props.append(InstanceData(model: model,
                                                  color: SIMD4(stone, 0)))
                    }
                }
                wasRiver = river

                // Cat's eyes and road markings era.
                if era.rawValue >= Era.modern.rawValue {
                    while nextEye <= travelled + d {
                        let t = Float(i) + (nextEye - travelled) / d
                        let p = point(t, 0)
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        if g > 0.004 && eyes.count < 900 {
                            let model = translation(SIMD3(p.x, g + 0.0012, p.y))
                                * scaleMatrix(SIMD3(0.00006, 0.00004, 0.00006))
                            eyes.append(InstanceData(model: model,
                                                     color: SIMD4(eyeColour, 1.6)))
                        }
                        nextEye += 0.0040
                    }
                }

                // Roman and later milestones.
                if era.rawValue >= Era.classical.rawValue {
                    while nextMilestone <= travelled + d {
                        let t = Float(i) + (nextMilestone - travelled) / d
                        let p = point(t, half + baseWidth * 0.30)
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        if g > 0.004 {
                            let model = translation(SIMD3(p.x, g + 0.0007, p.y))
                                * rotationY(heading)
                                * scaleMatrix(SIMD3(0.00010, 0.00032, 0.00010))
                            props.append(InstanceData(model: model,
                                                      color: SIMD4(stone, 0)))

                            // Atlas sign plate facing the road.
                            let facing = atan2(-side.x, -side.y)
                            let plateIndex: Float = era == .classical ? 0 : 1
                            let plate = translation(SIMD3(p.x - side.x * 0.00007,
                                                          g + 0.00062,
                                                          p.y - side.y * 0.00007))
                                * rotationY(facing)
                                * scaleMatrix(SIMD3(0.00028, 0.00015, 1))
                            plates.append(InstanceData(
                                model: plate,
                                color: SIMD4(SIMD3(repeating: 1), 0),
                                material: SIMD4(16, plateIndex, 0, 0)))
                        }
                        nextMilestone += 0.100
                    }
                }

                // Ridge cairns on prehistoric high ground.
                if era.rawValue <= Era.bronze.rawValue {
                    while nextCairn <= travelled + d {
                        let t = Float(i) + (nextCairn - travelled) / d
                        let p = point(t, half + 0.0005)
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        if g > 0.050 {
                            for s in [Float(-1), Float(1)] {
                                let q = p + side * (s * 0.0005)
                                let gq = scene.terrain.interpolatedHeight(x: q.x, z: q.y)
                                guard gq > 0.004 else { continue }
                                let model = translation(SIMD3(q.x, gq + 0.0005, q.y))
                                    * scaleMatrix(SIMD3(0.00012, 0.00030, 0.00012))
                                props.append(InstanceData(model: model,
                                                          color: SIMD4(stone * 0.92, 0)))
                            }
                        }
                        nextCairn += 0.036
                    }
                }

                // Turnpike tollhouses.
                if era == .industrial && segment.widthScale > 1.05 {
                    while nextTollhouse <= travelled + d {
                        let t = Float(i) + (nextTollhouse - travelled) / d
                        let p = point(t, half + 0.0032)
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        if g > 0.004 {
                            let walls = translation(SIMD3(p.x, g + 0.0008, p.y))
                                * rotationY(heading)
                                * scaleMatrix(SIMD3(0.00070, 0.00046, 0.00090))
                            props.append(InstanceData(model: walls,
                                                      color: SIMD4(SIMD3(0.70, 0.66, 0.56), 0)))
                            let roof = translation(SIMD3(p.x, g + 0.0017, p.y))
                                * rotationY(heading)
                                * scaleMatrix(SIMD3(0.00082, 0.00030, 0.00102))
                            roofs.append(InstanceData(model: roof,
                                                      color: SIMD4(roofColour, 0)))

                            // Two warm windows facing the road.
                            for offset in [Float(-0.00022), 0.00022] {
                                let wp = p - side * 0.00036 + dir * offset
                                let wg = scene.terrain.interpolatedHeight(x: wp.x, z: wp.y)
                                guard wg > 0.004 else { continue }
                                let windowModel = translation(
                                    SIMD3(wp.x, g + 0.00058, wp.y))
                                    * rotationY(heading)
                                    * scaleMatrix(SIMD3(0.00012, 0.00013, 0.00002))
                                eyes.append(InstanceData(
                                    model: windowModel,
                                    color: SIMD4(SIMD3(1.0, 0.78, 0.46), 1.6)))
                            }

                            // Toll plate above the door.
                            let tollFacing = atan2(-side.x, -side.y)
                            let tollPlate = translation(
                                SIMD3(p.x - side.x * 0.00037, g + 0.00098,
                                      p.y - side.y * 0.00037))
                                * rotationY(tollFacing)
                                * scaleMatrix(SIMD3(0.00030, 0.00010, 1))
                            plates.append(InstanceData(
                                model: tollPlate,
                                color: SIMD4(SIMD3(repeating: 1), 0),
                                material: SIMD4(16, 3, 0, 0)))
                        }
                        nextTollhouse += 0.120
                    }
                }

                if era.rawValue >= Era.modern.rawValue {
                    while nextSignal <= travelled + d {
                        let t = Float(i) + (nextSignal - travelled) / d
                        let p = point(t, half + 0.0009)
                        let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                        if g > 0.004 {
                            let post = translation(SIMD3(p.x, g + 0.00035, p.y))
                                * rotationY(heading)
                                * scaleMatrix(SIMD3(0.00008, 0.00070, 0.00008))
                            props.append(InstanceData(
                                model: post, color: SIMD4(SIMD3(0.22, 0.22, 0.22), 0)))
                            let lampColours: [SIMD3<Float>] = [
                                SIMD3(1.0, 0.12, 0.08),
                                SIMD3(1.0, 0.55, 0.10),
                                SIMD3(0.12, 0.90, 0.30)
                            ]
                            // Signals at the same junction share a phase, and
                            // cross-directions run half a cycle apart.
                            let qx = (p.x * 100).rounded() / 100
                            let qz = (p.y * 100).rounded() / 100
                            let raw = sin(qx * 127.1 + qz * 311.7) * 43_758.5453
                            let junctionHash = raw - floor(raw)
                            let axisOffset: Float = abs(dir.x) > abs(dir.y) ? 0 : 0.5
                            // A green wave runs along each corridor direction,
                            // its spacing derived from measured car speeds.
                            let waveRaw = (p.x * dir.x + p.y * dir.y) / wavelength
                            let wave = waveRaw - floor(waveRaw)
                            let phase = (junctionHash * 0.20 + axisOffset + wave)
                                .truncatingRemainder(dividingBy: 1.0)

                            // Longer green for busier segments, using the same
                            // vehicle density rule as the traffic system.
                            var length: Float = 0
                            for k in 1..<path.count {
                                length += simd_distance(path[k - 1], path[k])
                            }
                            let vehicleCount: Float = era.rawValue >= Era.modern.rawValue
                                ? Float(min(max(Int(length / 0.045), 1), 3))
                                : Float(min(max(Int(length / 0.090), 1), 2))
                            let maxCount: Float = era.rawValue >= Era.modern.rawValue ? 3 : 2
                            let bias = vehicleCount / maxCount

                            signalBase.append(bias)
                            for (index, colour) in lampColours.enumerated() {
                                let lamp = translation(
                                    SIMD3(p.x, g + 0.00048 + Float(index) * 0.00012, p.y))
                                    * rotationY(heading)
                                    * scaleMatrix(SIMD3(0.000075, 0.000075, 0.000075))
                                signals.append(InstanceData(
                                    model: lamp,
                                    color: SIMD4(colour, 0),
                                    material: SIMD4(15, phase, bias, 0)))
                            }
                        }
                        nextSignal += 0.035
                    }
                }

                travelled += d
            }

            // Signposts at the town ends of medieval-and-later roads.
            if era.rawValue >= Era.medieval.rawValue {
                for (p, flip) in [(path.first!, Float(1)), (path.last!, Float(-1))] {
                    let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                    guard g > 0.004 else { continue }
                    let prev = flip > 0 ? path[1] : path[path.count - 2]
                    let dir = simd_normalize(p - prev)
                    let side = SIMD2(-dir.y, dir.x)
                    let base = p + side * (half + 0.0008)
                    let post = translation(SIMD3(base.x, g + 0.0010, base.y))
                        * scaleMatrix(SIMD3(0.00008, 0.00048, 0.00008))
                    props.append(InstanceData(model: post, color: SIMD4(wood, 0)))
                    let arm = translation(SIMD3(base.x, g + 0.0018, base.y))
                        * rotationY(atan2(dir.x, dir.y))
                        * scaleMatrix(SIMD3(0.00032, 0.00007, 0.00008))
                    props.append(InstanceData(model: arm,
                                              color: SIMD4(SIMD3(0.62, 0.52, 0.34), 0)))

                    // Atlas plate on the post, facing the road.
                    let facing = atan2(-side.x, -side.y)
                    let plate = translation(SIMD3(base.x, g + 0.00182, base.y))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(0.00032, 0.00011, 1))
                    plates.append(InstanceData(
                        model: plate,
                        color: SIMD4(SIMD3(repeating: 1), 0),
                        material: SIMD4(16, 2, 0, 0)))
                }
            }
        }

        // One town-name gateway sign per settlement at its first road end.
        var named: Set<Int32> = []
        for segment in segments {
            let ends: [(Int32, SIMD2<Float>, Int)] = [
                (segment.from, segment.points.first!, 1),
                (segment.to, segment.points.last!, segment.points.count - 2)
            ]
            for (id, p, neighbourIndex) in ends where !named.contains(id) {
                guard let settlement = simulation.settlements.first(where: { $0.id == id }),
                      let cell = townSignCells[id] else { continue }
                let centre = SIMD2(settlement.x, settlement.z)
                if simd_distance(centre, p) > SettlementMetrics.cityRadius(settlement.population) * 2.2 {
                    continue
                }
                let neighbour = segment.points[min(max(neighbourIndex, 0),
                                                   segment.points.count - 1)]
                var dir = p - neighbour
                let len = simd_length(dir)
                guard len > 1e-6 else { continue }
                dir /= len
                let facing = atan2(-dir.x, -dir.y)
                let g = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                if g > 0.004 {
                    let seed = abs(Int(id))
                    let plateWidth = 0.00096 + Float(seed % 3) * 0.00009
                    let plateHeight = 0.00027 + Float((seed / 3) % 3) * 0.00004
                    let outward = SIMD2<Float>(sin(facing), cos(facing))

                    // Dark backing frame.
                    let frame = translation(SIMD3(p.x, g + 0.00055, p.y))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(plateWidth * 1.10,
                                            plateHeight * 1.28, 0.00002))
                    props.append(InstanceData(
                        model: frame,
                        color: SIMD4(SIMD3(0.20, 0.17, 0.13), 0)))

                    let plate = translation(
                        SIMD3(p.x + outward.x * 0.000025,
                              g + 0.00055,
                              p.y + outward.y * 0.000025))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(plateWidth, plateHeight, 1))
                    townPlates.append(InstanceData(
                        model: plate,
                        color: SIMD4(SIMD3(repeating: 1), 0),
                        material: SIMD4(17, Float(cell), 0, 0)))

                    // Per-town crest: shape and metal vary by settlement id.
                    let shapes: [SIMD2<Float>] = [SIMD2(0.00013, 0.00019),
                                                  SIMD2(0.00017, 0.00014),
                                                  SIMD2(0.00020, 0.00010)]
                    let metals: [SIMD3<Float>] = [SIMD3(0.86, 0.70, 0.32),
                                                  SIMD3(0.78, 0.80, 0.82),
                                                  SIMD3(0.74, 0.46, 0.26),
                                                  SIMD3(0.38, 0.62, 0.40)]
                    let crestSize = shapes[seed % shapes.count]
                    let crest = translation(
                        SIMD3(p.x + outward.x * 0.00003,
                              g + 0.00084,
                              p.y + outward.y * 0.00003))
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(crestSize.x, crestSize.y, 1))
                    let metal = metals[(seed / 5) % metals.count]
                    crests.append(InstanceData(model: crest,
                                               color: SIMD4(metal, 0)))

                    // Era-specific emblem on the shield.
                    let emblemCentre = SIMD3(p.x + outward.x * 0.00005,
                                             g + 0.00084,
                                             p.y + outward.y * 0.00005)
                    let ink = SIMD4(metal * 0.55, 0)
                    func emblem(_ offset: SIMD3<Float>, _ size: SIMD3<Float>,
                                _ spin: Float = 0) {
                        let model = translation(emblemCentre + offset)
                            * rotationY(facing)
                            * rotationZ(spin)
                            * scaleMatrix(size)
                        emblems.append(InstanceData(model: model, color: ink))
                    }
                    let variant = abs(seed / 11)
                    switch era {
                    case .neolithic, .bronze:
                        // One to three standing stones.
                        let stones = 1 + variant % 3
                        for k in 0..<stones {
                            let offset = Float(k) - Float(stones - 1) * 0.5
                            emblem(SIMD3(offset * 0.00006, 0, 0),
                                   SIMD3(0.000030, 0.000080 + Float(k % 2) * 0.00003,
                                         0.000014))
                        }
                    case .classical, .renaissance:
                        // Laurel ring with 5–7 leaves, rotated per town.
                        let leaves = 5 + variant % 3
                        for k in 0..<leaves {
                            let a = Float(k) / Float(leaves) * 2 * Float.pi
                                + Float(variant % 5) * 0.12
                            emblem(SIMD3(cos(a) * 0.000055, sin(a) * 0.000055, 0),
                                   SIMD3(0.000022, 0.000022, 0.000012), a)
                        }
                    case .medieval:
                        // Cross with a small optional chevron.
                        let arm = 0.000070 + Float(variant % 3) * 0.000010
                        emblem(SIMD3(0, 0, 0), SIMD3(arm, 0.000022, 0.000012))
                        emblem(SIMD3(0, 0.000015, 0), SIMD3(0.000022,
                                                             0.000065 + Float(variant % 2) * 0.000010,
                                                             0.000012))
                        if variant % 2 == 1 {
                            emblem(SIMD3(0, -0.000045, 0),
                                   SIMD3(0.000050, 0.000016, 0.000012), 0.6)
                        }
                    case .industrial:
                        // Two to four gear bars.
                        let bars = 2 + variant % 3
                        for k in 0..<bars {
                            let offset = (Float(k) - Float(bars - 1) * 0.5) * 0.000045
                            emblem(SIMD3(offset, 0, 0),
                                   SIMD3(0.000018,
                                         0.000065 + Float((k + variant) % 2) * 0.000015,
                                         0.000012))
                        }
                    case .modern, .information, .future:
                        // Four-point star, or an eight-point star per town.
                        emblem(SIMD3(0, 0, 0), SIMD3(0.000090, 0.000022, 0.000012))
                        emblem(SIMD3(0, 0, 0), SIMD3(0.000022, 0.000090, 0.000012))
                        if variant % 2 == 1 {
                            emblem(SIMD3(0, 0, 0), SIMD3(0.000064, 0.000016, 0.000012), 0.785)
                            emblem(SIMD3(0, 0, 0), SIMD3(0.000016, 0.000064, 0.000012), 0.785)
                        }
                    }
                }
                named.insert(id)
            }
        }

        roadPropBatch.update(props, device: context.device)
        roadPropGableBatch.update(roofs, device: context.device)
        catEyeBatch.update(eyes, device: context.device)
        signPlateBatch.update(plates, device: context.device)
        trafficLightBatch.update(signals, device: context.device)
        townSignBatch.update(townPlates, device: context.device)
        crestBatch.update(crests, device: context.device)
        emblemBatch.update(emblems, device: context.device)
        signalTemplate = signals
        signalBaseBias = signalBase
        signalLearnedBias = signalBase
    }

    /// Places warm street lamps along the road network from the industrial era
    /// on. At night they turn the road graph into a web of light; by day they
    /// are barely-visible posts.
    private func rebuildLamps(_ segments: [RoadBuilder.Segment], era: Era) {
        guard era.rawValue >= Era.industrial.rawValue else {
            lampBatch.update([], device: context.device)
            return
        }

        let spacing: Float = 0.012
        let sideOffset: Float = 0.0032
        let poleHeight: Float = 0.0044
        let warm = SIMD3<Float>(1.00, 0.74, 0.38)

        var lamps: [InstanceData] = []
        lamps.reserveCapacity(512)

        for segment in segments {
            guard segment.points.count >= 2 else { continue }
            var distanceToNext = spacing * 0.5
            var sideSign: Float = 1

            for i in 0..<(segment.points.count - 1) {
                let a = segment.points[i]
                let b = segment.points[i + 1]
                let d = simd_distance(a, b)
                guard d > 1e-5 else { continue }
                let dir = (b - a) / d
                let side = SIMD2<Float>(-dir.y, dir.x)

                var travelled: Float = 0
                while travelled + distanceToNext <= d {
                    travelled += distanceToNext
                    distanceToNext = spacing

                    let p = a + dir * travelled + side * (sideOffset * sideSign)
                    sideSign = -sideSign

                    let h = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                    guard h > 0.005, !scene.terrain.isWater(x: p.x, z: p.y) else { continue }

                    let model = translation(SIMD3(p.x, h + poleHeight * 0.5, p.y))
                        * scaleMatrix(SIMD3(0.0018, poleHeight, 0.0018))
                    lamps.append(InstanceData(model: model, color: SIMD4(warm, 2.0)))
                }
                distanceToNext -= (d - travelled)
            }
        }

        lampBatch.update(lamps, device: context.device)
    }

    /// Cars run along the road graph from the modern era on; a handful of
    /// boats circle the island from the classical era on. Paths are static and
    /// only the positions change, so the CPU work is a few hundred instances.
    private func rebuildTraffic(_ segments: [RoadBuilder.Segment], era: Era) {
        carPaths.removeAll(keepingCapacity: true)
        boatPaths.removeAll(keepingCapacity: true)

        if era.rawValue >= Era.modern.rawValue {
            var candidates: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
            for segment in segments {
                guard segment.points.count >= 2,
                      let first = segment.points.first,
                      let last = segment.points.last else { continue }
                var length: Float = 0
                for i in 1..<segment.points.count {
                    length += simd_distance(segment.points[i - 1], segment.points[i])
                }
                guard length > 0.02 else { continue }
                let count = min(max(Int(length / 0.045), 1), 3)
                for _ in 0..<count {
                    candidates.append((first, last, length))
                }
            }

            let stride = max(candidates.count / 90, 1)
            let palette: [SIMD3<Float>] = [
                SIMD3(0.78, 0.78, 0.80),
                SIMD3(0.20, 0.22, 0.26),
                SIMD3(0.55, 0.12, 0.10),
                SIMD3(0.20, 0.30, 0.45),
                SIMD3(0.62, 0.54, 0.30)
            ]
            for (i, candidate) in candidates.enumerated() where i % stride == 0 {
                carPaths.append(CarPath(start: candidate.0,
                                        end: candidate.1,
                                        length: candidate.2,
                                        speed: 0.0020 + Float(i % 5) * 0.0004,
                                        phase: Float((i * 37) % 100) / 100,
                                        colour: palette[i % palette.count],
                                        isCart: false))
            }
        } else if era.rawValue >= Era.bronze.rawValue {
            var candidates: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
            for segment in segments {
                guard segment.points.count >= 2,
                      let first = segment.points.first,
                      let last = segment.points.last else { continue }
                var length: Float = 0
                for i in 1..<segment.points.count {
                    length += simd_distance(segment.points[i - 1], segment.points[i])
                }
                guard length > 0.03 else { continue }
                let count = min(max(Int(length / 0.09), 1), 2)
                for _ in 0..<count {
                    candidates.append((first, last, length))
                }
            }

            let stride = max(candidates.count / 34, 1)
            let brown = SIMD3<Float>(0.42, 0.31, 0.20)
            for (i, candidate) in candidates.enumerated() where i % stride == 0 {
                carPaths.append(CarPath(start: candidate.0,
                                        end: candidate.1,
                                        length: candidate.2,
                                        speed: 0.0011 + Float(i % 4) * 0.0002,
                                        phase: Float((i * 53) % 100) / 100,
                                        colour: brown,
                                        isCart: true))
            }
        }

        if era.rawValue >= Era.classical.rawValue {
            for i in 0..<8 {
                boatPaths.append(BoatPath(radius: 1.00 + Float(i) * 0.042,
                                          speed: 0.010 + Float(i) * 0.002,
                                          phase: Float(i) * 0.785))
            }
        }
    }

    private func updateTraffic(time: Float, camera: Camera) {
        var cars: [InstanceData] = []
        var carts: [InstanceData] = []
        var spray: [InstanceData] = []
        var carPositions: [SIMD2<Float>] = []
        cars.reserveCapacity(carPaths.count * 2)
        carPositions.reserveCapacity(carPaths.count)
        spray.reserveCapacity(carPaths.count * 2)

        for path in carPaths {
            let period = max(path.length / max(path.speed, 1e-5), 1)
            let raw = path.phase + time / period
            let v = raw - floor(raw)
            let outbound = v < 0.5
            let u = outbound ? v * 2 : (1 - v) * 2

            var dir = simd_normalize(path.end - path.start)
            if !outbound { dir = -dir }
            let side = SIMD2<Float>(-dir.y, dir.x) * 0.0014
            let p = path.start + (path.end - path.start) * u + side

            let h = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
            guard h > 0.006, !scene.terrain.isWater(x: p.x, z: p.y) else { continue }

            let angle = atan2(dir.x, dir.y)

            if path.isCart {
                let scale: Float = 0.0020
                let body = translation(SIMD3(p.x, h, p.y))
                    * rotationY(angle)
                    * scaleMatrix(SIMD3(repeating: scale))
                carts.append(InstanceData(model: body,
                                          color: SIMD4(SIMD3(repeating: 1), 0)))
            } else {
                let scale: Float = 0.0024
                let body = translation(SIMD3(p.x, h, p.y))
                    * rotationY(angle)
                    * scaleMatrix(SIMD3(repeating: scale))
                cars.append(InstanceData(model: body, color: SIMD4(path.colour, 0)))
                carPositions.append(p)

                let front = p + dir * 0.0012
                let light = translation(SIMD3(front.x, h + 0.0006, front.y))
                    * scaleMatrix(SIMD3(repeating: 0.0008))
                cars.append(InstanceData(model: light, color: SIMD4(SIMD3(1.0, 0.9, 0.7), 2.0)))

                // Wet-road spray behind the car, scaled by the local
                // puddle-prone ground rather than a global rain switch.
                let slope = scene.terrain.slopeAt(x: p.x, z: p.y)
                let waterDistance = scene.terrain.waterDistanceAt(x: p.x, z: p.y)
                let flat = 1.0 - smoothstep(0.06, 0.30, slope)
                let low = 1.0 - smoothstep(0.006, 0.040, h)
                let nearWater = 1.0 - min(waterDistance / 12.0, 1.0)
                let localWet = weatherIntensity
                    * (0.20 + 0.45 * flat + 0.20 * low + 0.15 * nearWater)
                if localWet > 0.14 {
                    let wobble = sin(time * 4.0 + p.x * 73.0 + p.y * 51.0)
                    // Inherit the puddle ripple phase at this point.
                    let ripple = sin((p.x * 70.0 + p.y * 55.0) - time * 3.2)
                    let back = p - dir * 0.0013
                    for k in 0..<2 {
                        let spread = SIMD2(-dir.y, dir.x)
                            * (0.00034 * (k == 0 ? -1 : 1) * (0.7 + wobble * 0.2)
                               + ripple * 0.00006)
                        let q = back + spread + dir * (0.00022 * Float(k))
                        let hh = scene.terrain.interpolatedHeight(x: q.x, z: q.y)
                        guard hh > 0.004 else { continue }
                        let size = (0.00052 + 0.00016 * abs(wobble))
                            * (1.0 + 0.15 * ripple)
                        let mist = translation(SIMD3(q.x,
                                                     hh + 0.00030 + ripple * 0.00005,
                                                     q.y))
                            * scaleMatrix(SIMD3(size, size * 0.55, size))
                        spray.append(InstanceData(
                            model: mist,
                            color: SIMD4(SIMD3(0.74, 0.77, 0.80),
                                         0.03 + 0.14 * localWet
                                         + 0.025 * abs(wobble)
                                         + 0.02 * abs(ripple))))
                    }
                }
            }
        }
        carBatch.update(cars, device: context.device)
        cartBatch.update(carts, device: context.device)
        sprayBatch.update(spray, device: context.device)
        updateSignalQueues(carPositions)

        var hulls: [InstanceData] = []
        var sails: [InstanceData] = []
        for boat in boatPaths {
            let angle = boat.phase + time * boat.speed
            let p = SIMD2<Float>(cos(angle) * boat.radius, sin(angle) * boat.radius)
            let dir = SIMD2<Float>(-sin(angle), cos(angle))
            let heading = atan2(dir.x, dir.y)
            let water: Float = 0.0042
            let scale: Float = 0.0062
            let model = translation(SIMD3(p.x, water - 0.0004, p.y))
                * rotationY(heading)
                * scaleMatrix(SIMD3(repeating: scale))
            hulls.append(InstanceData(model: model,
                                      color: SIMD4(SIMD3(repeating: 1), 0)))
            sails.append(InstanceData(model: model,
                                      color: SIMD4(SIMD3(repeating: 1), 0)))
        }
        boatHullBatch.update(hulls, device: context.device)
        boatSailBatch.update(sails, device: context.device)

        var train: [InstanceData] = []
        if railLength > 0.08, railPoints.count >= 2 {
            let speed: Float = 0.0045
            let carLength: Float = 0.0060
            let gap: Float = 0.0012
            let cycle = railLength * 2
            let raw = time * speed
            let wrapped = raw - floor(raw / cycle) * cycle
            let returning = wrapped >= railLength
            let head = returning ? cycle - wrapped : wrapped

            for i in 0..<4 {
                let distance = returning
                    ? head + Float(i) * (carLength + gap)
                    : head - Float(i) * (carLength + gap)
                guard distance >= 0, distance <= railLength else { break }

                let (p, baseDir) = sampleRail(distance)
                let dir = returning ? -baseDir : baseDir
                let h = scene.terrain.interpolatedHeight(x: p.x, z: p.y)
                let angle = atan2(dir.x, dir.y)
                let isLoco = i == 0
                let bodyColour = isLoco ? SIMD3<Float>(0.15, 0.19, 0.17)
                                        : SIMD3<Float>(0.38, 0.22, 0.18)

                let body = translation(SIMD3(p.x, h + 0.0019, p.y))
                    * rotationY(angle)
                    * scaleMatrix(SIMD3(0.0022, 0.0017, carLength))
                train.append(InstanceData(model: body, color: SIMD4(bodyColour, 0)))

                if isLoco {
                    let lightPos = p + dir * (carLength * 0.46)
                    let light = translation(SIMD3(lightPos.x, h + 0.0024, lightPos.y))
                        * scaleMatrix(SIMD3(0.0008, 0.0006, 0.0008))
                    train.append(InstanceData(model: light,
                                              color: SIMD4(SIMD3(1.0, 0.92, 0.75), 2.0)))
                }
            }
        }
        trainBatch.update(train, device: context.device)

        var puffs: [InstanceData] = []
        puffs.reserveCapacity(smokeEmitters.count * 3)
        for (index, base) in smokeEmitters.enumerated() {
            if simd_distance(base, camera.eye) < 0.08 { continue }
            let phaseOffset = Float((index * 37) % 100) / 100
            for k in 0..<6 {
                let raw = time * 0.10 + phaseOffset + Float(k) / 6
                let phase = raw - floor(raw)
                let y = base.y + phase * 0.024
                let drift = phase * 0.010
                let scale = 0.0012 + phase * 0.0046
                let alpha = (1 - phase) * 0.22
                let model = translation(SIMD3(base.x + drift, y, base.z + drift * 0.4))
                    * scaleMatrix(SIMD3(scale, scale, scale))
                puffs.append(InstanceData(model: model,
                                          color: SIMD4(SIMD3(0.68, 0.68, 0.69), alpha)))
            }
        }
        smokeBatch.update(puffs, device: context.device)

        let clothing: [SIMD3<Float>] = [
            SIMD3(0.55, 0.20, 0.16), SIMD3(0.20, 0.30, 0.48), SIMD3(0.30, 0.40, 0.22),
            SIMD3(0.60, 0.52, 0.38), SIMD3(0.75, 0.72, 0.64), SIMD3(0.42, 0.26, 0.36),
            SIMD3(0.62, 0.50, 0.18), SIMD3(0.22, 0.40, 0.40), SIMD3(0.38, 0.33, 0.30)
        ]
        var people: [InstanceData] = []
        var heads: [InstanceData] = []
        var brims: [InstanceData] = []
        var legs: [InstanceData] = []
        var arms: [InstanceData] = []
        var carried: [InstanceData] = []
        for (si, settlement) in livingSettlements.enumerated() {
            let fallbackRadius = CityBuilder.cityRadius(settlement.population)
            let grid = si < streetGrids.count
                ? streetGrids[si]
                : CityBuilder.StreetGrid(x: settlement.x, z: settlement.z, angle: 0,
                                         cell: max(fallbackRadius * 0.5, 0.008),
                                         radius: fallbackRadius)
            let dir = SIMD2<Float>(cos(grid.angle), sin(grid.angle))
            let perp = SIMD2<Float>(-sin(grid.angle), cos(grid.angle))
            let half = max(Int(ceil(grid.radius / max(grid.cell, 0.0001))), 2)
            let lanes: Float = 3

            // People walk up and down every street in the grid, turning at the
            // ends, so the whole town has foot traffic rather than one lane.
            for k in 0..<16 {
                let h = hash01(si * 37 + k * 11 + 7)
                let h2 = hash01(si * 19 + k * 23 + 101)
                let h3 = hash01(si * 31 + k * 13 + 313)

                let lineIndex = Int(h3 * Float(half * 2 + 1)) - half
                let offset = Float(lineIndex) * grid.cell
                let axis = h < 0.5 ? 0 : 1
                let run = sqrt(max(grid.radius * grid.radius - offset * offset, 0)) * 0.85
                let span = max(run, grid.cell)

                let lane = Float(k) - floor(Float(k) / lanes) * lanes - (lanes - 1) * 0.5
                let lateral = lane * grid.cell * 0.22
                let speed = 0.010 + h2 * 0.014
                let t = (time * speed / span + h3).truncatingRemainder(dividingBy: 2)
                let travelling = t <= 1
                let along = (travelling ? t * 2 - 1 : 2 - t * 2) * span
                let sign: Float = travelling ? 1 : -1

                let lx = axis == 0 ? along : offset + lateral
                let lz = axis == 0 ? offset + lateral : along
                let x = grid.x + dir.x * lx + perp.x * lz
                let z = grid.z + dir.y * lx + perp.y * lz
                let ground = scene.terrain.interpolatedHeight(x: x, z: z)
                guard ground > 0.006, !scene.terrain.isWater(x: x, z: z),
                      scene.riverField.waterLevel(at: SIMD2(x, z)) == nil
                else { continue }

                let walkAngle = axis == 0 ? grid.angle : grid.angle + Float.pi / 2
                let facing = walkAngle + (sign > 0 ? 0 : Float.pi)
                let bob = abs(sin(time * 9 + h2 * 6)) * 0.00030
                let child = h3 < 0.15
                let scale: Float = 0.0044 * (0.92 + h * 0.16) * (child ? 0.72 : 1.0)
                let coat = clothing[(si * 3 + k) % clothing.count]

                let base = SIMD3<Float>(x, ground + bob, z)
                let body = translation(base)
                    * rotationY(facing)
                    * scaleMatrix(SIMD3(repeating: scale))
                people.append(InstanceData(model: body, color: SIMD4(coat, 0)))
                if h2 > 0.58 {
                    brims.append(InstanceData(model: body, color: SIMD4(SIMD3(repeating: 1), 0)))
                } else {
                    heads.append(InstanceData(model: body, color: SIMD4(SIMD3(repeating: 1), 0)))
                }

                let c = cos(facing), sn = sin(facing)
                func localPoint(_ lx: Float, _ ly: Float, _ lz: Float) -> SIMD3<Float> {
                    SIMD3(base.x + (lx * c + lz * sn) * scale,
                          base.y + ly * scale,
                          base.z + (-lx * sn + lz * c) * scale)
                }

                let stride = sin(time * 7.0 + h2 * 6.283)
                for (side, swingSign) in [(Float(-1), Float(1)), (Float(1), Float(-1))] {
                    let hip = localPoint(side * 0.085, 0.49, 0)
                    let model = translation(hip)
                        * rotationY(facing)
                        * rotationX(stride * 0.55 * swingSign)
                        * scaleMatrix(SIMD3(repeating: scale))
                    legs.append(InstanceData(model: model, color: SIMD4(coat * 0.45, 0)))
                }
                for (side, swingSign) in [(Float(-1), Float(-1)), (Float(1), Float(1))] {
                    let shoulder = localPoint(side * 0.205, 0.845, 0)
                    let model = translation(shoulder)
                        * rotationY(facing)
                        * rotationX(stride * 0.42 * swingSign)
                        * scaleMatrix(SIMD3(repeating: scale))
                    arms.append(InstanceData(model: model, color: SIMD4(coat, 0)))
                }

                if h3 > 0.72 {
                    let hand = localPoint(0.21, 0.50, 0.04)
                    let basket = translation(hand)
                        * rotationY(facing)
                        * scaleMatrix(SIMD3(scale * 0.30, scale * 0.22, scale * 0.24))
                    carried.append(InstanceData(
                        model: basket,
                        color: SIMD4(SIMD3(0.52, 0.40, 0.24), 0)))
                } else if h2 > 0.78 {
                    // A walking staff planted in the hand.
                    let hand = localPoint(0.21, 0.52, 0.02)
                    let shaft = translation(SIMD3(hand.x, (base.y + hand.y) * 0.5, hand.z))
                        * scaleMatrix(SIMD3(scale * 0.07, hand.y - base.y, scale * 0.07))
                    carried.append(InstanceData(
                        model: shaft,
                        color: SIMD4(SIMD3(0.36, 0.26, 0.16), 0)))
                }
            }
        }
        // A couple of people standing at the stalls, facing the square.
        for (si, settlement) in livingSettlements.enumerated() {
            let grid = si < streetGrids.count
                ? streetGrids[si]
                : CityBuilder.StreetGrid(x: settlement.x, z: settlement.z, angle: 0,
                                         cell: max(CityBuilder.cityRadius(settlement.population) * 0.5, 0.008),
                                         radius: CityBuilder.cityRadius(settlement.population))
            for k in 0..<2 {
                let h = hash01(si * 91 + k * 13 + 5)
                let h2 = hash01(si * 47 + k * 29 + 77)
                let angle = h * 2 * Float.pi
                let radius = grid.radius * (0.28 + 0.10 * h2)
                let x = grid.x + cos(angle) * radius
                let z = grid.z + sin(angle) * radius
                let ground = scene.terrain.interpolatedHeight(x: x, z: z)
                guard ground > 0.006, !scene.terrain.isWater(x: x, z: z),
                      scene.riverField.waterLevel(at: SIMD2(x, z)) == nil
                else { continue }

                let scale: Float = 0.0044 * (0.94 + h2 * 0.10)
                let facing = angle + Float.pi * 0.5
                let coat = clothing[(si * 5 + k + 2) % clothing.count]
                let base = SIMD3<Float>(x, ground, z)
                let body = translation(base)
                    * rotationY(facing)
                    * scaleMatrix(SIMD3(repeating: scale))
                people.append(InstanceData(model: body, color: SIMD4(coat, 0)))
                if h2 > 0.58 {
                    brims.append(InstanceData(model: body, color: SIMD4(SIMD3(repeating: 1), 0)))
                } else {
                    heads.append(InstanceData(model: body, color: SIMD4(SIMD3(repeating: 1), 0)))
                }

                let c = cos(facing), sn = sin(facing)
                func localPoint(_ lx: Float, _ ly: Float, _ lz: Float) -> SIMD3<Float> {
                    SIMD3(base.x + (lx * c + lz * sn) * scale,
                          base.y + ly * scale,
                          base.z + (-lx * sn + lz * c) * scale)
                }
                for (side, swingSign) in [(Float(-1), Float(1)), (Float(1), Float(-1))] {
                    let hip = localPoint(side * 0.085, 0.49, 0)
                    let model = translation(hip)
                        * rotationY(facing)
                        * rotationX(0.10 * swingSign)
                        * scaleMatrix(SIMD3(repeating: scale))
                    legs.append(InstanceData(model: model, color: SIMD4(coat * 0.45, 0)))
                }
                for (side, swingSign) in [(Float(-1), Float(-1)), (Float(1), Float(1))] {
                    let shoulder = localPoint(side * 0.205, 0.845, 0)
                    let model = translation(shoulder)
                        * rotationY(facing)
                        * rotationX(0.08 * swingSign)
                        * scaleMatrix(SIMD3(repeating: scale))
                    arms.append(InstanceData(model: model, color: SIMD4(coat, 0)))
                }
                let hand = localPoint(0.21, 0.50, 0.02)
                carried.append(InstanceData(
                    model: translation(hand) * rotationY(facing)
                        * scaleMatrix(SIMD3(scale * 0.34, scale * 0.26, scale * 0.28)),
                    color: SIMD4(SIMD3(0.52, 0.40, 0.24), 0)))
            }
        }

        carryBatch.update(carried, device: context.device)
        personBatch.update(people, device: context.device)
        personHeadBatch.update(heads, device: context.device)
        personHeadBrimBatch.update(brims, device: context.device)
        personLegBatch.update(legs, device: context.device)
        personArmBatch.update(arms, device: context.device)

        var animals: [InstanceData] = []
        for (si, settlement) in livingSettlements.enumerated() {
            let base = max(CityBuilder.cityRadius(settlement.population) * 1.65 + 0.012, 0.028)
            for k in 0..<5 {
                let h = hash01(si * 53 + k * 17 + 500)
                let h2 = hash01(si * 29 + k * 7 + 900)
                let angle = h * 2 * Float.pi + time * 0.00005
                let radius = base * (0.8 + 0.5 * h2)
                let x = settlement.x + cos(angle) * radius
                let z = settlement.z + sin(angle) * radius
                let ground = scene.terrain.interpolatedHeight(x: x, z: z)
                guard ground > 0.006, !scene.terrain.isWater(x: x, z: z),
                      scene.riverField.waterLevel(at: SIMD2(x, z)) == nil
                else { continue }

                let scale: Float = 0.0034
                let model = translation(SIMD3(x, ground, z))
                    * rotationY(angle + .pi / 2)
                    * scaleMatrix(SIMD3(scale, scale, scale))
                let coat: SIMD3<Float> = h2 < 0.5 ? SIMD3(0.78, 0.74, 0.66)
                                                 : SIMD3(0.42, 0.30, 0.20)
                animals.append(InstanceData(model: model, color: SIMD4(coat, 0)))
            }
        }
        animalBatch.update(animals, device: context.device)

        var birds: [InstanceData] = []
        for i in 0..<18 {
            let radius = 0.30 + Float(i % 5) * 0.09
            let speed = 0.05 + Float(i % 3) * 0.012
            let angle = time * speed + Float(i) * 0.9
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            let ground = scene.terrain.interpolatedHeight(x: x, z: z)
            let y = max(ground + 0.05, 0.12) + sin(time * 0.8 + Float(i)) * 0.008
            let heading = -angle
            let scale: Float = 0.009
            let model = translation(SIMD3(x, y, z))
                * rotationY(heading)
                * rotationZ(0.25)
                * scaleMatrix(SIMD3(scale, scale, scale))
            birds.append(InstanceData(model: model,
                                      color: SIMD4(SIMD3(0.12, 0.12, 0.13), 0)))
        }
        birdBatch.update(birds, device: context.device)
    }

    /// Picks the longest road as a rail corridor from the industrial era on,
    /// offset slightly so the rails run beside the road rather than on it.
    private func rebuildRailPath(_ segments: [RoadBuilder.Segment], era: Era) {
        railPoints.removeAll(keepingCapacity: true)
        railCumulative.removeAll(keepingCapacity: true)
        railLength = 0

        guard era.rawValue >= Era.industrial.rawValue else {
            try? scene.rebuildRail([], color: .zero)
            return
        }

        var best: RoadBuilder.Segment?
        var bestLength: Float = 0
        for segment in segments {
            guard segment.points.count >= 2 else { continue }
            var length: Float = 0
            for i in 1..<segment.points.count {
                length += simd_distance(segment.points[i - 1], segment.points[i])
            }
            if length > bestLength {
                bestLength = length
                best = segment
            }
        }

        guard let best, best.points.count >= 2 else {
            try? scene.rebuildRail([], color: .zero)
            return
        }

        var offset: [SIMD2<Float>] = []
        offset.reserveCapacity(best.points.count)
        for i in 0..<best.points.count {
            let prev = best.points[max(i - 1, 0)]
            let next = best.points[min(i + 1, best.points.count - 1)]
            var dir = next - prev
            let len = simd_length(dir)
            if len < 1e-6 { dir = SIMD2(1, 0) } else { dir /= len }
            let side = SIMD2<Float>(-dir.y, dir.x)
            offset.append(best.points[i] + side * 0.0045)
        }

        railPoints = offset
        railCumulative = [0]
        var total: Float = 0
        for i in 1..<offset.count {
            total += simd_distance(offset[i - 1], offset[i])
            railCumulative.append(total)
        }
        railLength = total

        do {
            try scene.rebuildRail(offset, color: SIMD3(0.34, 0.31, 0.27))
        } catch {
            NSLog("Evolving: rail mesh failed — \(error)")
        }
    }

    private func sampleRail(_ distance: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        let d = min(max(distance, 0), railLength)
        var i = 1
        while i < railCumulative.count && railCumulative[i] < d { i += 1 }
        let i0 = max(i - 1, 0)
        let i1 = min(i, railPoints.count - 1)
        let segLength = max(railCumulative[i1] - railCumulative[i0], 1e-5)
        let t = (d - railCumulative[i0]) / segLength
        let p = railPoints[i0] + (railPoints[i1] - railPoints[i0]) * t
        var dir = railPoints[i1] - railPoints[i0]
        let len = simd_length(dir)
        dir = len < 1e-6 ? SIMD2(1, 0) : dir / len
        return (p, dir)
    }

    private var lastRoadSettlementCount = -1
    private var lastRoadEra: Era?

    /// Road surfaces get darker and wider as the civilisation industrialises.
    static func roadStyle(for era: Era) -> (color: SIMD3<Float>, bridge: SIMD3<Float>,
                                             marking: SIMD3<Float>?, width: Float) {
        switch era {
        case .neolithic, .bronze:
            return (SIMD3(0.42, 0.34, 0.24), SIMD3(0.40, 0.30, 0.20), nil, 0.0016)
        case .classical:
            return (SIMD3(0.52, 0.45, 0.34), SIMD3(0.50, 0.47, 0.41), nil, 0.0020)
        case .medieval, .renaissance:
            return (SIMD3(0.52, 0.45, 0.34), SIMD3(0.50, 0.47, 0.41), nil, 0.0022)
        case .industrial:
            return (SIMD3(0.30, 0.29, 0.28), SIMD3(0.38, 0.38, 0.37), nil, 0.0028)
        case .modern, .information, .future:
            return (SIMD3(0.20, 0.20, 0.21), SIMD3(0.40, 0.40, 0.39),
                    SIMD3(0.72, 0.72, 0.70), 0.0036)
        }
    }

    func updateTrees(_ trees: CityBuilder.Trees) {
        // Conifers and broadleaves are separate meshes, so separate batches.
        treeBatch.update(trees.conifers, device: context.device)
        broadleafBatch.update(trees.broadleaves, device: context.device)
    }

    private lazy var treeBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.treeMesh, device: context.device, capacity: 1024)
    }()

    private lazy var broadleafBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.treeBroadleafMesh, device: context.device, capacity: 1024)
    }()

    private lazy var roadPropBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 1024)
    }()

    private lazy var roadPropGableBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.gableMesh, device: context.device, capacity: 256)
    }()

    private lazy var catEyeBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    private lazy var signPlateBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.signPlateMesh, device: context.device, capacity: 256)
    }()

    private lazy var trafficLightBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    private lazy var townSignBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.signPlateMesh, device: context.device, capacity: 128)
    }()

    private lazy var crestBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.crestMesh, device: context.device, capacity: 128)
    }()

    private lazy var emblemBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 256)
    }()

    private lazy var sprayBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.smokeMesh, device: context.device, capacity: 512)
    }()

    /// Street lamps live in their own batch: their emissive weight is a marker
    /// (> 1) so the shader draws a solid point of light instead of windows.
    private lazy var lampBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    private lazy var carBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.carMesh, device: context.device, capacity: 256)
    }()

    private lazy var cartBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cartMesh, device: context.device, capacity: 128)
    }()

    /// Farmland plots; drawn before the buildings so they sit on the ground.
    private lazy var fieldBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    /// Pitched roofs for the pre-industrial eras.
    private lazy var archBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.archMesh, device: context.device, capacity: 128)
    }()

    private lazy var gableBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.gableMesh, device: context.device, capacity: 1024)
    }()

    private lazy var boatHullBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.boatHullMesh, device: context.device, capacity: 16)
    }()

    private lazy var boatSailBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.boatSailMesh, device: context.device, capacity: 16)
    }()

    private lazy var trainBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 32)
    }()

    private lazy var smokeBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.smokeMesh, device: context.device, capacity: 256)
    }()

    private lazy var personBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.personBodyMesh, device: context.device, capacity: 1024)
    }()

    private lazy var personHeadBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.personHeadMesh, device: context.device, capacity: 1024)
    }()

    private lazy var personHeadBrimBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.personHeadBrimMesh, device: context.device, capacity: 1024)
    }()

    private lazy var personLegBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.personLegMesh, device: context.device, capacity: 2048)
    }()

    private lazy var personArmBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.personArmMesh, device: context.device, capacity: 2048)
    }()

    private lazy var carryBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    private lazy var animalBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.animalMesh, device: context.device, capacity: 512)
    }()

    private lazy var birdBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.birdMesh, device: context.device, capacity: 32)
    }()

    private lazy var rainBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.cubeMesh, device: context.device, capacity: 512)
    }()

    private lazy var snowBatch: InstanceBatch = {
        InstanceBatch(mesh: scene.smokeMesh, device: context.device, capacity: 512)
    }()

    // MARK: - Weather

    private func hash01(_ value: Int) -> Float {
        var x = UInt64(bitPattern: Int64(value)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Float(x >> 40) / Float(1 << 24)
    }

    /// Precipitation changes every six hours, smoothed so it fades in and out.
    /// Snow when the season is cold, rain otherwise.
    private func weatherState() -> (intensity: Float, snow: Bool) {
        let snow = snowOverride ?? (season() > 0.62)

        if let override = weatherOverride {
            return (min(max(override, 0), 1), snow)
        }

        let t = Date().timeIntervalSince1970 / 21_600.0
        let bucket = floor(t)
        let fraction = t - bucket
        let a = hash01(Int(bucket))
        let b = hash01(Int(bucket) + 1)
        let smooth = Float(fraction * fraction * (3 - 2 * fraction))
        let value = a + (b - a) * smooth
        return (smoothstep(0.22, 0.34, value), snow)
    }

    private func updateWeather(time: Float, camera: Camera) {
        guard weatherIntensity > 0.01 else {
            rainBatch.update([], device: context.device)
            snowBatch.update([], device: context.device)
            return
        }

        let count = weatherIsSnow ? 280 : 420
        let centre = SIMD2<Float>(camera.target.x, camera.target.z)
        var instances: [InstanceData] = []
        instances.reserveCapacity(count)

        for i in 0..<count {
            let h1 = hash01(i * 3 + 1)
            let h2 = hash01(i * 3 + 2)
            let h3 = hash01(i * 3 + 3)

            let x = centre.x + (h1 - 0.5) * 0.85
            let z = centre.y + (h2 - 0.5) * 0.85
            let fall: Float = weatherIsSnow ? 0.035 : 0.35
            let raw = h3 + time * fall
            let phase = raw - floor(raw)
            let y = 0.55 - phase * 0.55

            if weatherIsSnow {
                let drift = sin(time * 0.6 + h1 * 20) * 0.012
                let scale: Float = 0.0018
                let model = translation(SIMD3(x + drift, y, z + drift * 0.5))
                    * scaleMatrix(SIMD3(scale, scale, scale))
                instances.append(InstanceData(
                    model: model,
                    color: SIMD4(SIMD3(0.92, 0.94, 0.97), 0.85 * weatherIntensity)))
            } else {
                let model = translation(SIMD3(x, y, z))
                    * scaleMatrix(SIMD3(0.0004, 0.009, 0.0004))
                instances.append(InstanceData(
                    model: model,
                    color: SIMD4(SIMD3(0.60, 0.70, 0.80), 0.32 * weatherIntensity)))
            }
        }

        if weatherIsSnow {
            snowBatch.update(instances, device: context.device)
            rainBatch.update([], device: context.device)
        } else {
            rainBatch.update(instances, device: context.device)
            snowBatch.update([], device: context.device)
        }
    }

    // MARK: - Camera + sun

    /// Two shots on a ~110 s cycle: a wide orbital hero shot, then a slow push
    /// toward the largest settlement, then back out. The transitions are eased
    /// so the camera never snaps.
    /// Three shots on a ~160 s cycle: wide hero orbit, low coastal drift, then
    /// a slow push toward the largest settlement. The orbit angle uses one
    /// constant speed so blending between shots never snaps the heading.
    private func automaticCamera(time: Float, aspect: Float) -> Camera {
        switch cameraMode {
        case .wide:  return wideCamera(time: time)
        case .coast: return coastCamera(time: time)
        case .city:  return cityCamera(time: time)
        case .street: return streetCamera(time: time)
        case .square: return squareCamera(time: time)
        case .auto:  return cyclingCamera(time: time)
        }
    }

    private func wideCamera(time: Float) -> Camera {
        let orbit = time * 0.016 + 0.55
        let eye = SIMD3<Float>(cos(orbit) * 1.66,
                               0.48 + sin(time * 0.031) * 0.04,
                               sin(orbit) * 1.66)
        return Camera(eye: eye, target: SIMD3(0, 0.10, 0), fov: 36)
    }

    private func coastCamera(time: Float) -> Camera {
        let orbit = time * 0.016 + 0.55
        let eye = SIMD3<Float>(cos(orbit) * 1.80,
                               0.20 + sin(time * 0.023) * 0.03,
                               sin(orbit) * 1.80)
        return Camera(eye: eye, target: SIMD3(0, 0.02, 0), fov: 40)
    }

    /// Picks an azimuth around the largest settlement with open ground and a
    /// clear line of sight, so the close shot never stares into a hillside.
    private func updateCloseAzimuth() {
        let radius: Float = 0.56
        var bestAngle = closeAzimuth
        var bestScore: Float = -1e9

        for k in 0..<32 {
            let angle = Float(k) / 32 * 2 * Float.pi
            let x = focusPoint.x + cos(angle) * radius
            let z = focusPoint.z + sin(angle) * radius
            let ground = scene.terrain.interpolatedHeight(x: x, z: z)
            guard ground > 0.006 else { continue }

            let eyeY = max(ground + 0.22, 0.30)
            let eye = SIMD3<Float>(x, eyeY, z)
            let target = SIMD3<Float>(focusPoint.x, 0.02, focusPoint.z)
            guard hasClearView(from: eye, to: target) else { continue }

            let score = -ground * 3 - eyeY * 0.3
            if score > bestScore {
                bestScore = score
                bestAngle = angle
            }
        }

        if bestScore > -1e8 { closeAzimuth = bestAngle }
    }

    private func hasClearView(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> Bool {
        for step in 1...10 {
            let t = Float(step) / 11
            let p = eye + (target - eye) * t
            let ground = scene.terrain.interpolatedHeight(x: p.x, z: p.z)
            if ground > p.y - 0.005 { return false }
        }
        return true
    }

    private func cityCamera(time: Float) -> Camera {
        let radius: Float = 0.56
        let angle = closeAzimuth + sin(time * 0.05) * 0.10
        let x = focusPoint.x + cos(angle) * radius
        let z = focusPoint.z + sin(angle) * radius
        let ground = scene.terrain.interpolatedHeight(x: x, z: z)
        let eyeY = max(ground + 0.22, 0.30) + sin(time * 0.07) * 0.01
        let eye = SIMD3<Float>(x, eyeY, z)
        let target = SIMD3<Float>(focusPoint.x, 0.02, focusPoint.z)
        return Camera(eye: eye, target: target, fov: 32)
    }

    /// Picks an azimuth at `radius` with dry land under the camera and no other
    /// town between it and the focus, so the hero shot frames its own town.
    private func clearAngle(radius: Float) -> Float {
        var bestAngle = landAngle(radius: radius)
        var bestScore: Float = -Float.greatestFiniteMagnitude

        let centre = scene.terrain.interpolatedHeight(x: focusPoint.x, z: focusPoint.z)
        let target = SIMD3<Float>(focusPoint.x, centre + radius * 0.06, focusPoint.z)

        for k in 0..<32 {
            let angle = Float(k) / 32 * 2 * Float.pi
            let x = focusPoint.x + cos(angle) * radius
            let z = focusPoint.z + sin(angle) * radius
            let ground = scene.terrain.interpolatedHeight(x: x, z: z)
            guard ground > 0.008, !scene.terrain.isWater(x: x, z: z) else { continue }

            // The eye must actually see over the ground between it and town.
            let eyeY = max(ground + radius * 0.39 + 0.015, 0.024)
            guard hasClearView(from: SIMD3<Float>(x, eyeY, z), to: target) else { continue }

            let eye = SIMD2<Float>(x, z)
            let target = SIMD2<Float>(focusPoint.x, focusPoint.z)
            var score: Float = 0

            for grid in streetGrids {
                let centre = SIMD2<Float>(grid.x, grid.z)
                let gap = pointToSegment(centre, eye, target)
                let blocked = grid.radius * 1.05 - gap
                if blocked > 0 {
                    score -= blocked / max(grid.radius, 0.001) * 12
                }
            }

            if score > bestScore {
                bestScore = score
                bestAngle = angle
            }
        }

        return bestAngle
    }

    private func pointToSegment(_ p: SIMD2<Float>,
                                _ a: SIMD2<Float>,
                                _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-8 else { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return simd_distance(p, a + ab * t)
    }

    /// Picks an azimuth at `radius` that is on dry land.
    private func landAngle(radius: Float) -> Float {
        for k in 0..<24 {
            let angle = Float(k) / 24 * 2 * Float.pi
            let x = focusPoint.x + cos(angle) * radius
            let z = focusPoint.z + sin(angle) * radius
            let ground = scene.terrain.interpolatedHeight(x: x, z: z)
            if ground > 0.008, !scene.terrain.isWater(x: x, z: z) {
                return angle
            }
        }
        return closeAzimuth
    }

    private func streetCamera(time: Float) -> Camera {
        let town = max(focusRadius, 0.028)
        let radius = town * 1.45 + 0.045
        let angle = closeAzimuth + sin(time * 0.03) * 0.18
        let x = focusPoint.x + cos(angle) * radius
        let z = focusPoint.z + sin(angle) * radius
        let ground = scene.terrain.interpolatedHeight(x: x, z: z)
        let eyeY = max(ground + town * 0.55 + 0.020, 0.032) + sin(time * 0.05) * 0.0015
        let centre = scene.terrain.interpolatedHeight(x: focusPoint.x, z: focusPoint.z)
        return Camera(eye: SIMD3(x, eyeY, z),
                      target: SIMD3(focusPoint.x, centre + town * 0.10, focusPoint.z),
                      fov: 44)
    }

    /// The close hero shot: just outside the town, above the rooftops, looking
    /// across the square and the streets. The distance tracks the town's size,
    /// so a young hamlet fills the frame without a metropolis swallowing the
    /// camera.
    private func squareCamera(time: Float) -> Camera {
        let town = max(focusRadius, 0.028)
        let radius = town * 2.30 + 0.012
        let angle = squareAngle + sin(time * 0.03) * 0.05
        let x = focusPoint.x + cos(angle) * radius
        let z = focusPoint.z + sin(angle) * radius
        let ground = scene.terrain.interpolatedHeight(x: x, z: z)
        let centre = scene.terrain.interpolatedHeight(x: focusPoint.x, z: focusPoint.z)
        let eyeY = max(ground + town * 0.90 + 0.015, 0.024) + sin(time * 0.05) * 0.001
        return Camera(eye: SIMD3(x, eyeY, z),
                      target: SIMD3(focusPoint.x, centre + town * 0.10, focusPoint.z),
                      fov: 46)
    }

    private func cyclingCamera(time: Float) -> Camera {
        let cycle = time.truncatingRemainder(dividingBy: 160)

        let low: Float
        switch cycle {
        case ..<38:  low = 0
        case ..<50:  low = smoothstep(38, 50, cycle)
        case ..<84:  low = 1
        case ..<96:  low = 1 - smoothstep(84, 96, cycle)
        default:     low = 0
        }

        let close: Float
        switch cycle {
        case ..<108: close = 0
        case ..<122: close = smoothstep(108, 122, cycle)
        case ..<148: close = 1
        default:     close = 1 - smoothstep(148, 160, cycle)
        }

        let wideWeight = max(1 - low - close, 0)
        let orbit = time * 0.016 + 0.55
        let closeCam = cityCamera(time: time)

        let wideEye = SIMD3<Float>(cos(orbit) * 1.66,
                                   0.48 + sin(time * 0.031) * 0.04,
                                   sin(orbit) * 1.66)
        let lowEye = SIMD3<Float>(cos(orbit) * 1.80,
                                  0.20 + sin(time * 0.023) * 0.03,
                                  sin(orbit) * 1.80)

        let eye = wideEye * wideWeight + lowEye * low + closeCam.eye * close
        let fov = 36 * wideWeight + 40 * low + closeCam.fov * close
        let wideTarget = SIMD3<Float>(0, 0.10, 0)
        let lowTarget = SIMD3<Float>(0, 0.02, 0)
        let target = wideTarget * wideWeight + lowTarget * low + closeCam.target * close
        return Camera(eye: eye, target: target, fov: fov)
    }

    private func sun(for time: Float) -> (direction: SIMD3<Float>, elevation: Float, night: Float) {
        let hour: Float
        if let override = hourOverride {
            hour = override
        } else {
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            hour = Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60
        }
        let a = (hour / 24) * 2 * Float.pi - .pi / 2
        let elevation = sin(a)
        let dir = simd_normalize(SIMD3<Float>(cos(a) * 0.86, elevation, 0.38))
        let night = smoothstep(0.06, -0.14, elevation)
        return (dir, elevation, night)
    }

    /// Season as 0 (midsummer) … 1 (midwinter), derived from the real date.
    /// Cosmetic only: it never feeds back into the simulation. Linear between
    /// the solstices (northern hemisphere), so thresholds behave predictably.
    private func season() -> Float {
        if let override = seasonOverride {
            return min(max(override, 0), 1)
        }

        var day = Double(Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 172)
        let summer = 172.0   // ~21 June
        let winter = 355.0   // ~21 December
        let year = 365.25

        if southernHemisphere {
            day += year * 0.5
            if day > year { day -= year }
        }

        if day >= summer && day <= winter {
            return Float((day - summer) / (winter - summer))
        }
        let wrapped = day < summer ? day + year : day
        return Float(1.0 - (wrapped - winter) / (year - (winter - summer)))
    }

    private func lightMatrix(sunDir: SIMD3<Float>) -> simd_float4x4 {
        lightMatrix(sunDir: sunDir, centre: SIMD3<Float>(0, 0.05, 0), extent: 1.45)
    }

    private func lightMatrix(sunDir: SIMD3<Float>,
                             centre: SIMD3<Float>,
                             extent: Float) -> simd_float4x4 {
        let eye = centre + sunDir * 3.0
        let up = abs(sunDir.y) > 0.98 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        let view = lookAt(eye: eye, center: centre, up: up)
        let ortho = orthographic(-extent, extent, -extent, extent, 0.1, 6.0)
        return ortho * view
    }

    private func encodeShadow(commandBuffer: MTLCommandBuffer,
                              map: MTLTexture?,
                              lightVP: simd_float4x4,
                              includeTerrain: Bool) {
        guard let map else { return }

        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = map
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Evolving shadow"
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(depthWriting)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        var uniforms = FrameUniforms(viewProjection: lightVP,
                                     lightViewProjection: lightVP,
                                     inverseViewProjection: matrix_identity_float4x4,
                                     cameraAndTime: .zero,
                                     sunAndPad: .zero,
                                     night: .zero,
                                     shadow: .zero,
                                     closeLightViewProjection: matrix_identity_float4x4,
                                     closeShadow: .zero)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        encoder.setVertexBuffer(identityBatch.buffer, offset: 0, index: 2)
        encoder.setFragmentTexture(groundAlbedo, index: 6)
        encoder.setFragmentTexture(groundNormal, index: 7)
        encoder.setFragmentTexture(rockAlbedo, index: 8)
        encoder.setFragmentTexture(rockNormal, index: 9)
        encoder.setFragmentTexture(groundFine, index: 12)
        encoder.setFragmentTexture(groundFineNormal, index: 13)
        draw(scene.terrainMesh, with: encoder, instances: 1)

        if let buffer = bankIdentityBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 2)
        }
        if ProcessInfo.processInfo.environment["EVOLVING_HIDE_BANKS"] != "1" {
            draw(scene.riverBankMesh, with: encoder, instances: 1)
        }

        for batch in [boxBatch, treeBatch, broadleafBatch, coneBatch] where batch.count > 0 {
            encoder.setVertexBuffer(batch.buffer, offset: 0, index: 2)
            draw(batch.mesh, with: encoder, instances: batch.count)
        }
        for entry in buildingBatches where entry.batch.count > 0
            && nearbyBuildings.contains(entry.path) {
            encoder.setVertexBuffer(entry.batch.buffer, offset: 0, index: 2)
            draw(entry.batch.mesh, with: encoder, instances: entry.batch.count)
        }

        encoder.endEncoding()
    }

    // MARK: - Encoding

    /// Renders the scene into an offscreen target and composites it into
    /// `target` with the post pass. Used by both the live view and the snapshot
    /// tool so they always look the same.
    func encodeFrame(commandBuffer: MTLCommandBuffer,
                     target: MTLTexture,
                     time: Float) {
        let width = target.width
        let height = target.height
        guard width > 0, height > 0 else { return }

        // Very large displays render the scene below native resolution; the
        // post pass still writes every pixel, so the HUD and UI stay crisp.
        let sceneScale = renderScale(width: width, height: height)
        let sceneWidth = max(Int(Float(width) * sceneScale), 1)
        let sceneHeight = max(Int(Float(height) * sceneScale), 1)

        guard ensureSceneTargets(width: sceneWidth, height: sceneHeight),
              let sceneColor, let msaaColor, let msaaDepth else { return }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = msaaColor
        scenePass.colorAttachments[0].resolveTexture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1)
        scenePass.depthAttachment.texture = msaaDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1.0

        let (shadowSunDir, shadowElevation, _) = sun(for: time)
        currentLightVP = lightMatrix(sunDir: shadowSunDir)
        currentCloseLightVP = lightMatrix(sunDir: shadowSunDir,
                                          centre: SIMD3<Float>(focusPoint.x, 0.03, focusPoint.z),
                                          extent: 0.30)
        if shadowElevation > 0.02 {
            encodeShadow(commandBuffer: commandBuffer, map: shadowMap,
                         lightVP: currentLightVP, includeTerrain: true)
            if let closeShadowMap {
                encodeShadow(commandBuffer: commandBuffer, map: closeShadowMap,
                             lightVP: currentCloseLightVP, includeTerrain: true)
            }
        }

        encodeScene(commandBuffer: commandBuffer,
                    passDescriptor: scenePass,
                    size: CGSize(width: sceneWidth, height: sceneHeight),
                    time: time)

        if sceneScale >= 0.999 {
            // Native or near-native: composite straight into the drawable.
            let postPass = MTLRenderPassDescriptor()
            postPass.colorAttachments[0].texture = target
            postPass.colorAttachments[0].loadAction = .dontCare
            postPass.colorAttachments[0].storeAction = .store

            encodePost(commandBuffer: commandBuffer,
                       scene: sceneColor,
                       passDescriptor: postPass,
                       height: Float(height),
                       sceneScale: sceneScale,
                       time: time)
        } else {
            // Very large display: run the post pass at scene resolution, then
            // upscale it. The expensive 15-tap post never touches 8K pixels.
            guard ensurePostTarget(width: sceneWidth, height: sceneHeight),
                  let postColor else { return }

            let postPass = MTLRenderPassDescriptor()
            postPass.colorAttachments[0].texture = postColor
            postPass.colorAttachments[0].loadAction = .dontCare
            postPass.colorAttachments[0].storeAction = .store

            encodePost(commandBuffer: commandBuffer,
                       scene: sceneColor,
                       passDescriptor: postPass,
                       height: Float(height),
                       sceneScale: sceneScale,
                       time: time)

            let upscalePass = MTLRenderPassDescriptor()
            upscalePass.colorAttachments[0].texture = target
            upscalePass.colorAttachments[0].loadAction = .dontCare
            upscalePass.colorAttachments[0].storeAction = .store

            encodeBlit(commandBuffer: commandBuffer,
                       source: postColor,
                       passDescriptor: upscalePass)
        }
    }

    private func ensurePostTarget(width: Int, height: Int) -> Bool {
        if width == postWidth, height == postHeight, postColor != nil {
            return true
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                            width: width,
                                                            height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        guard let texture = context.device.makeTexture(descriptor: desc) else { return false }
        postColor = texture
        postWidth = width
        postHeight = height
        return true
    }

    private func encodeBlit(commandBuffer: MTLCommandBuffer,
                            source: MTLTexture,
                            passDescriptor: MTLRenderPassDescriptor) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.label = "Evolving upscale"
        encoder.setRenderPipelineState(blitPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Caps the scene pass at roughly 6 MP. Above that the scene is rendered
    /// smaller and upscaled by the post pass, which keeps frame rate on 5K/6K
    /// displays without touching the simulation.
    func renderScale(width: Int, height: Int) -> Float {
        let pixels = Float(width * height)
        let budget: Float = 5_500_000
        // Keep the scene under ~30 ms: mild supersampling on small panels,
        // native on a laptop display, and a graceful step down on 4K/6K.
        let base: Float
        if pixels <= 4_500_000 { base = 1.35 }
        else if pixels <= 6_500_000 { base = 1.15 }
        else if pixels <= 9_000_000 { base = 1.00 }
        else { base = max(0.48, sqrt(budget / pixels)) }
        return min(1.35, max(0.50, base * dynamicScale))
    }

    private func ensureSceneTargets(width: Int, height: Int) -> Bool {
        if width == sceneWidth, height == sceneHeight,
           sceneColor != nil, msaaColor != nil, msaaDepth != nil {
            return true
        }

        // Single-sample resolve target that the post pass samples.
        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .private

        let colorDesc = MTLTextureDescriptor()
        colorDesc.textureType = .type2DMultisample
        colorDesc.pixelFormat = .bgra8Unorm_srgb
        colorDesc.width = width
        colorDesc.height = height
        colorDesc.sampleCount = Renderer.msaaSampleCount
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private

        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DMultisample
        depthDesc.pixelFormat = .depth32Float
        depthDesc.width = width
        depthDesc.height = height
        depthDesc.sampleCount = Renderer.msaaSampleCount
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private

        guard let resolve = context.device.makeTexture(descriptor: resolveDesc),
              let msaa = context.device.makeTexture(descriptor: colorDesc),
              let depth = context.device.makeTexture(descriptor: depthDesc) else {
            return false
        }

        sceneColor = resolve
        msaaColor = msaa
        msaaDepth = depth
        sceneWidth = width
        sceneHeight = height
        return true
    }

    private func encodePost(commandBuffer: MTLCommandBuffer,
                            scene: MTLTexture,
                            passDescriptor: MTLRenderPassDescriptor,
                            height: Float,
                            sceneScale: Float,
                            time: Float) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.label = "Evolving post"

        // The blur radius is expressed in pixels at 1000 px tall, so the look is
        // identical whether we are drawing a 1600×1000 still or a 6 MP display.
        let scale = max(height / 1000.0, 0.5)
        let warmth = smoothstep(0.35, 0.0, abs(currentElevation))
        let saturation = 1.06 - currentNight * 0.08

        var uniforms = PostUniforms(
            params: SIMD4(0.50, 0.25, 0.30, 3.2 * scale),
            extra: SIMD4(time, 0.30, 0.62 * currentNight, 0),
            view: SIMD4(sceneScale, 0.0025, 0, 0),
            grade: SIMD4(warmth, 1.06, saturation, 0.34)
        )

        encoder.setRenderPipelineState(postPipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PostUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeScene(commandBuffer: MTLCommandBuffer,
                             passDescriptor: MTLRenderPassDescriptor,
                             size: CGSize,
                             time: Float) {
        guard size.width > 0, size.height > 0 else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.label = "Evolving frame"

        let aspect = Float(size.width / size.height)
        let cam = cameraOverride ?? automaticCamera(time: time, aspect: aspect)
        let view = lookAt(eye: cam.eye, center: cam.target, up: SIMD3(0, 1, 0))
        let projection = perspective(fovyRadians: degreesToRadians(cam.fov),
                                     aspect: aspect, near: 0.004, far: 30)

        let (sunDir, sunElevation, night) = sun(for: time)
        let weather = weatherState()
        weatherIntensity = weather.intensity
        weatherIsSnow = weather.snow

        // Still-frame debugging aids. They cost nothing in the normal path.
        let debug = ProcessInfo.processInfo.environment
        let hideRiver = debug["EVOLVING_HIDE_RIVER"] == "1"
        let hideBanks = debug["EVOLVING_HIDE_BANKS"] == "1"
        let debugShadow: Float
        if debug["EVOLVING_NO_SHADOW"] == "1" { debugShadow = 1 }
        else if debug["EVOLVING_RIVER_MAGENTA"] == "1" { debugShadow = 2 }
        else if debug["EVOLVING_RIVER_UV"] == "1" { debugShadow = 3 }
        else if debug["EVOLVING_RIVER_FOAM"] == "1" { debugShadow = 4 }
        else { debugShadow = 0 }

        var uniforms = FrameUniforms(
            viewProjection: projection * view,
            lightViewProjection: currentLightVP,
            inverseViewProjection: simd_inverse(projection * view),
            cameraAndTime: SIMD4(cam.eye.x, cam.eye.y, cam.eye.z, time),
            sunAndPad: SIMD4(sunDir, sunElevation),
            night: SIMD4(night, season(), 1, weather.intensity),
            shadow: SIMD4(1.0 / Float(shadowSize), 0.0015, 0.00012, debugShadow),
            closeLightViewProjection: currentCloseLightVP,
            closeShadow: SIMD4(1.0 / Float(closeShadowSize), 0.00070, 0.00010, 0)
        )
        currentNight = night
        currentElevation = sunElevation

        updateTraffic(time: time, camera: cam)
        updateWeather(time: time, camera: cam)

        // Sky.
        encoder.setRenderPipelineState(skyPipeline)
        encoder.setDepthStencilState(depthDisabled)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Opaque geometry.
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setDepthStencilState(depthWriting)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentTexture(shadowMap, index: 1)
        encoder.setFragmentTexture(closeShadowMap, index: 4)

        encoder.setVertexBuffer(identityBatch.buffer, offset: 0, index: 2)
        encoder.setFragmentTexture(groundAlbedo, index: 6)
        encoder.setFragmentTexture(groundNormal, index: 7)
        encoder.setFragmentTexture(rockAlbedo, index: 8)
        encoder.setFragmentTexture(rockNormal, index: 9)
        encoder.setFragmentTexture(groundFine, index: 12)
        encoder.setFragmentTexture(groundFineNormal, index: 13)
        draw(scene.terrainMesh, with: encoder, instances: 1)

        if let buffer = bankIdentityBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 2)
        }
        if !hideBanks {
            draw(scene.riverBankMesh, with: encoder, instances: 1)
        }

        // Roads sit just above the terrain and below the buildings.
        if let streets = scene.streetMesh {
            if let buffer = streetIdentityBuffer {
                encoder.setVertexBuffer(buffer, offset: 0, index: 2)
            }
            draw(streets, with: encoder, instances: 1)
        }
        if let roads = scene.roadMesh {
            if let buffer = roadIdentityBuffer {
                encoder.setVertexBuffer(buffer, offset: 0, index: 2)
            }
            draw(roads, with: encoder, instances: 1)
        }
        if let buffer = riverIdentityBuffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 2)
        }
        if !hideRiver {
            draw(scene.riverMesh, with: encoder, instances: 1)
        }
        if let rail = scene.railMesh {
            if let buffer = railIdentityBuffer {
                encoder.setVertexBuffer(buffer, offset: 0, index: 2)
            }
            draw(rail, with: encoder, instances: 1)
        }

        if signPlateBatch.count > 0 {
            if let signAtlas {
                encoder.setFragmentTexture(signAtlas, index: 10)
            }
            encoder.setVertexBuffer(signPlateBatch.buffer, offset: 0, index: 2)
            draw(signPlateBatch.mesh, with: encoder, instances: signPlateBatch.count)
        }
        if townSignBatch.count > 0 {
            if let texture = townSignTexture {
                encoder.setFragmentTexture(texture, index: 11)
            }
            encoder.setVertexBuffer(townSignBatch.buffer, offset: 0, index: 2)
            draw(townSignBatch.mesh, with: encoder, instances: townSignBatch.count)
        }

        for batch in [fieldBatch, boxBatch, gableBatch, archBatch, roadPropBatch, roadPropGableBatch, catEyeBatch, crestBatch, emblemBatch, trafficLightBatch, treeBatch, broadleafBatch, coneBatch, lampBatch, carBatch, cartBatch, boatHullBatch, boatSailBatch, trainBatch, birdBatch, personBatch, personHeadBatch, personHeadBrimBatch, personLegBatch, personArmBatch, carryBatch, animalBatch] where batch.count > 0 {
            encoder.setVertexBuffer(batch.buffer, offset: 0, index: 2)
            draw(batch.mesh, with: encoder, instances: batch.count)
        }

        if let buildingAtlas {
            encoder.setFragmentTexture(buildingAtlas, index: 2)
            encoder.setFragmentTexture(buildingNormal, index: 3)
            encoder.setFragmentTexture(buildingRoughness, index: 5)
            for entry in buildingBatches where entry.batch.count > 0 {
                encoder.setVertexBuffer(entry.batch.buffer, offset: 0, index: 2)
                draw(entry.batch.mesh, with: encoder, instances: entry.batch.count)
            }
        }

        // Smoke: blended, depth tested, no depth writes.
        if smokeBatch.count > 0 || sprayBatch.count > 0 {
            encoder.setRenderPipelineState(smokePipeline)
            encoder.setDepthStencilState(waterDepthState)
            encoder.setCullMode(.back)
            for batch in [smokeBatch, sprayBatch] where batch.count > 0 {
                encoder.setVertexBuffer(batch.buffer, offset: 0, index: 2)
                draw(batch.mesh, with: encoder, instances: batch.count)
            }
        }

        // Water last: blended, depth tested, no depth writes.
        encoder.setRenderPipelineState(waterPipeline)
        encoder.setDepthStencilState(waterDepthState)
        encoder.setVertexBuffer(identityBatch.buffer, offset: 0, index: 2)
        encoder.setFragmentTexture(scene.heightTexture, index: 0)
        draw(scene.waterMesh, with: encoder, instances: 1)

        // Weather particles sit in front of the finished scene.
        if weatherIntensity > 0.01 {
            let batch = weatherIsSnow ? snowBatch : rainBatch
            if batch.count > 0 {
                encoder.setRenderPipelineState(weatherPipeline)
                encoder.setDepthStencilState(waterDepthState)
                encoder.setCullMode(.back)
                encoder.setVertexBuffer(batch.buffer, offset: 0, index: 2)
                draw(batch.mesh, with: encoder, instances: batch.count)
            }
        }

        encoder.endEncoding()
    }

    /// A one-instance buffer that supplies a single material id to a mesh that
    /// is drawn without instancing (terrain, roads, streets, rail).
    private static func makeIdentityBuffer(device: MTLDevice,
                                           material: Float) -> MTLBuffer? {
        var instance = InstanceData(model: matrix_identity_float4x4,
                                    color: SIMD4<Float>(1, 1, 1, 0),
                                    material: SIMD4<Float>(material, 0, 0, 0))
        return device.makeBuffer(bytes: &instance,
                                 length: MemoryLayout<InstanceData>.stride,
                                 options: .storageModeShared)
    }

    private func draw(_ mesh: Mesh, with encoder: MTLRenderCommandEncoder, instances: Int) {
        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        if let indices = mesh.indexBuffer {
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: mesh.indexCount,
                                          indexType: .uint32,
                                          indexBuffer: indices,
                                          indexBufferOffset: 0,
                                          instanceCount: instances,
                                          baseVertex: 0,
                                          baseInstance: 0)
        } else {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: 0,
                                   vertexCount: mesh.vertexCount,
                                   instanceCount: instances,
                                   baseInstance: 0)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer() else {
            return
        }

        let time = Float(CACurrentMediaTime() - startTime)
        encodeFrame(commandBuffer: commandBuffer,
                    target: drawable.texture,
                    time: time)

        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                NSLog("Evolving: frame error — \(error)")
            }
            if ProcessInfo.processInfo.environment["EVOLVING_GPU_LOG"] == "1" {
                let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                NSLog("Evolving gpu: %.2f ms", ms)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        framesDrawn &+= 1
    }
}

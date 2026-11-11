import Foundation
import simd

/// Locates imported assets both in the app bundle and in the repo (the
/// headless tool runs straight out of `build/bin`).
enum AssetStore {
    static func url(named name: String) -> URL? {
        var roots: [URL] = []
        if let resources = Bundle(for: Renderer.self).resourceURL {
            roots.append(resources)
        }
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
        }
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent())
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for root in roots {
            for base in ["Assets/Buildings/", "Assets/Roads/", "Assets/Terrain/", "Assets/"] {
                let candidate = root.appendingPathComponent(base + name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

enum AssetError: Error {
    case missing(String)
    case badFormat
}

struct CivAsset {
    var vertices: [Vertex]
    var indices: [UInt32]
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>
}

/// Reader for the exporter in `Scripts/build_roundhouse.py`.
///
/// Layout, little endian:
///   "CIVM", version u32, vertexCount u32, indexCount u32,
///   min xyz, max xyz, vertices [pos3, normal3, uv2], indices u32.
enum CivMesh {
    /// Reads only the header bounds, for footprint-aware placement.
    static func bounds(named name: String) throws -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let url = AssetStore.url(named: name) else {
            throw AssetError.missing(name)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var reader = Reader(data: data)
        let magic = reader.u32()
        guard magic == 0x4D56_4943 || magic == 0x4349_564D,
              reader.u32() == 1 else { throw AssetError.badFormat }
        let vertexCount = reader.u32()
        let indexCount = reader.u32()
        guard vertexCount > 0, indexCount > 0 else { throw AssetError.badFormat }
        let minimum = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())
        let maximum = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())
        return (minimum, maximum)
    }

    static func load(named name: String) throws -> CivAsset {
        guard let url = AssetStore.url(named: name) else {
            throw AssetError.missing(name)
        }
        let data = try Data(contentsOf: url)
        var reader = Reader(data: data)

        // "CIVM"; little-endian on disk reads back as 0x4D564943 on arm64.
        let magic = reader.u32()
        guard magic == 0x4D56_4943 || magic == 0x4349_564D else {
            throw AssetError.badFormat
        }
        guard reader.u32() == 1 else { throw AssetError.badFormat }

        let vertexCount = Int(reader.u32())
        let indexCount = Int(reader.u32())
        let minimum = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())
        let maximum = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())

        guard vertexCount > 0, indexCount > 0 else { throw AssetError.badFormat }

        var vertices = [Vertex]()
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let position = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())
            let normal = SIMD3<Float>(reader.f32(), reader.f32(), reader.f32())
            let uv = SIMD2<Float>(reader.f32(), reader.f32())
            vertices.append(Vertex(position: position,
                                   normal: normal,
                                   color: SIMD4<Float>(1, 1, 1, 1),
                                   uv: uv))
        }

        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            indices.append(reader.u32())
        }

        return CivAsset(vertices: vertices, indices: indices,
                        minimum: minimum, maximum: maximum)
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func u32() -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let value = data.withUnsafeBytes { raw -> UInt32 in
            let base = raw.baseAddress!.advanced(by: offset)
            return base.loadUnaligned(as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func f32() -> Float {
        Float(bitPattern: u32())
    }
}

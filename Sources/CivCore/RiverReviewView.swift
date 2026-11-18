import Foundation

/// Versioned, portable record of a displayed frame; all camera coordinates are
/// world units (1 km/unit), angles are degrees and hour is local solar time.
struct RiverReviewView: Codable, Equatable {
    var schemaVersion = 1
    var seed: UInt64
    var year: Float
    var hour: Float
    var season: Float
    var precipitation: Float
    var snow: Bool
    var animationTime: Float
    var eye: [Float]
    var target: [Float]
    var fov: Float
    var width: Int
    var height: Int
    var provenance: String = "captured displayed frame"

    func validated() throws -> RiverReviewView {
        let values = [year, hour, season, precipitation, animationTime, fov] + eye + target
        guard schemaVersion == 1, eye.count == 3, target.count == 3,
              values.allSatisfy({ $0.isFinite }), eye != target, year >= 0, year <= 12000,
              hour >= 0, hour < 24, season >= 0, season <= 1,
              precipitation >= 0, precipitation <= 1, animationTime >= 0,
              fov > 1, fov < 170, width >= 64, height >= 64, width <= 8192, height <= 8192 else {
            throw NSError(domain: "RiverReviewView", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid or unsupported review-view record"])
        }
        return self
    }
    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    func write(to url: URL) throws { try encoded().write(to: url, options: .atomic) }
    static func read(_ url: URL) throws -> RiverReviewView {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).validated()
    }

    static func fixtures() -> Bool {
        let view = RiverReviewView(seed: .max, year: 2336, hour: 22, season: 0.7,
            precipitation: 0.8, snow: true, animationTime: 123.5,
            eye: [0.2, 0.4, -0.3], target: [0, 0.03, 0], fov: 52, width: 1600, height: 1000)
        do {
            let data = try view.encoded()
            let decoded = try JSONDecoder().decode(Self.self, from: data).validated()
            guard decoded == view, try decoded.encoded() == data else { return false }
            var invalid = [view, view, view, view, view]
            invalid[0].eye = view.target; invalid[1].eye[0] = .nan
            invalid[2].hour = 24; invalid[3].width = 0; invalid[4].schemaVersion = 2
            for record in invalid {
                if (try? record.validated()) != nil { return false }
            }
            print("review-view records: PASS (UInt64 seed, stable round trip, weather/camera/time, invalid input rejection)")
            return true
        } catch { print("review-view records: FAIL \(error)"); return false }
    }
}

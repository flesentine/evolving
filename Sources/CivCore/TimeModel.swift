import Foundation

/// The civilisations the world passes through.
enum Era: Int, CaseIterable {
    case neolithic  = 0
    case bronze     = 1
    case classical  = 2
    case medieval   = 3
    case renaissance = 4
    case industrial = 5
    case modern     = 6
    case information = 7
    case future     = 8

    static let startYears: [Float] = [0, 800, 2000, 3500, 5000, 6200, 7400, 8600, 10000]

    var name: String {
        switch self {
        case .neolithic:   return "Neolithic"
        case .bronze:      return "Bronze Age"
        case .classical:   return "Classical"
        case .medieval:    return "Medieval"
        case .renaissance: return "Renaissance"
        case .industrial:  return "Industrial"
        case .modern:      return "Modern"
        case .information: return "Information Age"
        case .future:      return "Near Future"
        }
    }

    var shortName: String {
        switch self {
        case .neolithic:   return "Stone"
        case .bronze:      return "Bronze"
        case .classical:   return "Classical"
        case .medieval:    return "Medieval"
        case .renaissance: return "Renaissance"
        case .industrial:  return "Industrial"
        case .modern:      return "Modern"
        case .information: return "Information"
        case .future:      return "Future"
        }
    }

    var startYear: Float { Era.startYears[rawValue] }

    /// Era for a given simulated year.
    static func at(_ year: Float) -> Era {
        var result = Era.neolithic
        for era in Era.allCases where year >= era.startYear {
            result = era
        }
        return result
    }
}

/// Maps real elapsed time onto simulated years.
///
/// The mapping is deliberately non-linear: early eras pass quickly so the first
/// week already shows change, while mature eras slow down so they can be lived
/// in. Era boundaries are the control points.
struct Pace {
    let name: String
    let realDayStarts: [Float]
    let simYearStarts: [Float]

    /// ~20 months from first camp to near future.
    static let standard = Pace(name: "Standard",
                               realDayStarts: [0, 5, 20, 60, 130, 220, 330, 450, 600],
                               simYearStarts: Era.startYears)

    /// A decade-long commitment: ~4x slower.
    static let chronicle = Pace(name: "Chronicle",
                                realDayStarts: [0, 20, 80, 240, 520, 880, 1320, 1800, 2400],
                                simYearStarts: Era.startYears)

    /// Roughly three months end to end.
    static let timelapse = Pace(name: "Time-lapse",
                                realDayStarts: [0, 0.8, 3, 10, 22, 37, 55, 75, 100],
                                simYearStarts: Era.startYears)

    static let all: [Pace] = [.standard, .chronicle, .timelapse]

    static func named(_ name: String) -> Pace {
        all.first { $0.name == name } ?? .standard
    }

    private var slopes: [Float] {
        var result: [Float] = []
        for i in 0..<(realDayStarts.count - 1) {
            let dd = realDayStarts[i + 1] - realDayStarts[i]
            let dy = simYearStarts[i + 1] - simYearStarts[i]
            result.append(dd > 0 ? dy / dd : 0)
        }
        return result
    }

    func simYear(atRealDays days: Float) -> Float {
        guard days > 0 else { return 0 }
        let last = realDayStarts.count - 1
        if days >= realDayStarts[last] {
            let slope = slopes.last ?? 1
            return simYearStarts[last] + (days - realDayStarts[last]) * slope
        }
        for i in 0..<last where days < realDayStarts[i + 1] {
            let t = (days - realDayStarts[i]) / (realDayStarts[i + 1] - realDayStarts[i])
            return simYearStarts[i] + t * (simYearStarts[i + 1] - simYearStarts[i])
        }
        return simYearStarts[last]
    }

    func realDays(atSimYear year: Float) -> Float {
        guard year > 0 else { return 0 }
        let last = simYearStarts.count - 1
        if year >= simYearStarts[last] {
            let slope = slopes.last ?? 1
            return realDayStarts[last] + (year - simYearStarts[last]) / max(slope, 1e-5)
        }
        for i in 0..<last where year < simYearStarts[i + 1] {
            let t = (year - simYearStarts[i]) / (simYearStarts[i + 1] - simYearStarts[i])
            return realDayStarts[i] + t * (realDayStarts[i + 1] - realDayStarts[i])
        }
        return realDayStarts[last]
    }
}

import Foundation

/// A Gregorian date, never a midnight UTC timestamp. JSON is YYYY-MM-DD.
/// Time zones affect picker conversion only, not comparison or day arithmetic.
public struct CivilDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(year: Int, month: Int, day: Int) throws {
        guard (1900...9999).contains(year), (1...12).contains(month) else { throw PlanningError.invalidDate }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { throw PlanningError.invalidDate }
        self.year = year; self.month = month; self.day = day
    }
    public init(_ text: String) throws {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { throw PlanningError.invalidDate }
        try self.init(year: y, month: m, day: d)
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
    public var ordinal: Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = month + (month > 2 ? -3 : 9)
        let doy = (153 * m + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
    public func distance(to other: Self) -> Int { other.ordinal - ordinal }
    public func adding(days: Int) throws -> Self {
        guard (-4_000_000...4_000_000).contains(days) else { throw PlanningError.invalidDate }
        let z = ordinal + days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        y += m <= 2 ? 1 : 0
        return try .init(year: y, month: m, day: d)
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(description) }
    public static func today(timeZone: TimeZone = .current) -> Self {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        if let y = parts.year, let m = parts.month, let d = parts.day,
           let value = try? Self(year: y, month: m, day: d) { return value }
        return try! Self(year: 1970, month: 1, day: 1) // Known-valid fallback for an invalid system clock.
    }
}

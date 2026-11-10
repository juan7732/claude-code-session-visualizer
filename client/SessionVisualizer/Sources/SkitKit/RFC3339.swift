import Foundation

/// Parses the timestamps `skit` writes: RFC 3339 with zero to nine fractional
/// digits, `Z` or a numeric offset. Hand-written because a session document
/// carries thousands of them and `ISO8601DateFormatter` both allocates per use
/// and rejects some fraction lengths.
public enum RFC3339 {
    public static func date(_ string: String) -> Date? {
        var s = Substring(string).utf8[...]
        func number(_ count: Int) -> Int? {
            guard s.count >= count else { return nil }
            var value = 0
            for byte in s.prefix(count) {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            s = s.dropFirst(count)
            return value
        }
        func skip(_ ascii: Character) -> Bool {
            guard let first = s.first, first == ascii.asciiValue else { return false }
            s = s.dropFirst()
            return true
        }
        guard let year = number(4), skip("-"), let month = number(2), skip("-"), let day = number(2),
              skip("T") || skip("t") || skip(" "),
              let hour = number(2), skip(":"), let minute = number(2), skip(":"), let second = number(2)
        else { return nil }

        var fraction = 0.0
        if skip(".") {
            var scale = 0.1
            var digits = 0
            while let byte = s.first, byte >= 48, byte <= 57 {
                fraction += Double(byte - 48) * scale
                scale /= 10
                digits += 1
                s = s.dropFirst()
            }
            guard digits > 0 else { return nil }
        }

        var offset = 0
        if skip("Z") || skip("z") {
            // UTC
        } else if let sign = s.first, sign == 43 || sign == 45 {
            s = s.dropFirst()
            guard let hh = number(2), skip(":"), let mm = number(2) else { return nil }
            offset = (hh * 3600 + mm * 60) * (sign == 45 ? -1 : 1)
        } else {
            return nil
        }
        guard s.isEmpty, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }

        // Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}

extension JSONDecoder {
    /// The decoder for everything under `/v0`: RFC 3339 dates, keys as written.
    public static func skit() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = RFC3339.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an RFC 3339 timestamp: \(text)")
            }
            return date
        }
        return decoder
    }
}

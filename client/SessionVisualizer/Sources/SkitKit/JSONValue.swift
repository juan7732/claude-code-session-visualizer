import Foundation

/// Any JSON value. Tool inputs are whatever the tool takes, so the client keeps
/// them as they are and reads the few fields it knows by name.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The member of an object; nil for anything else.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { members[key] } else { nil }
    }

    /// The text of a string value; nil for anything else.
    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// The value on one line: a string as it is, a number without a needless ".0", anything else as compact JSON with sorted keys.
    public var compact: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): return value
        case .array(let values): return "[" + values.map(\.quoted).joined(separator: ", ") + "]"
        case .object(let members): return "{" + members.keys.sorted().map { "\"\($0)\": " + (members[$0]?.quoted ?? "null") }.joined(separator: ", ") + "}"
        }
    }

    private var quoted: String {
        if case .string(let value) = self { return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return compact
    }

    /// The first of the named members that is a non-empty string.
    public func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let text = self[key]?.string, !text.isEmpty { return text }
        }
        return nil
    }

    /// Indented JSON with sorted keys, for showing an input nobody has a nicer view of.
    public var pretty: String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent + 1)
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            out += value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value):
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            out += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        case .array(let values):
            if values.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, value) in values.enumerated() {
                out += pad
                value.write(into: &out, indent: indent + 1)
                out += i < values.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            let keys = members.keys.sorted()
            for (i, key) in keys.enumerated() {
                out += pad + "\"\(key)\": "
                members[key]!.write(into: &out, indent: indent + 1)
                out += i < keys.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }
}

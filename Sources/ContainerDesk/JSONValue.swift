import Foundation

/// Untyped JSON for CLI output whose schema varies by resource and CLI version.
enum JSONValue: Hashable, Sendable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// Dot-separated lookup; numeric components index into arrays, as in `status.networks.0.ipv4Address`.
    subscript(path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { value, key in
            switch value {
            case .object(let object)?: object[String(key)]
            case .array(let array)?: Int(key).flatMap { array.indices.contains($0) ? array[$0] : nil }
            default: nil
            }
        }
    }

    /// A display string for scalars and arrays of scalars; nil for objects, null, and empty values.
    var text: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "Yes" : "No"
        case .array(let values):
            values.isEmpty ? nil : values.allSatisfy(\.isScalar)
                ? values.compactMap(\.text).joined(separator: ", ") : values.count == 1 ? "1 item" : "\(values.count) items"
        case .object, .null: nil
        }
    }

    /// Objects and arrays of objects, which display as their own group of values.
    var isGroup: Bool {
        switch self {
        case .object: true
        case .array(let values): !values.allSatisfy(\.isScalar)
        case .string, .number, .bool, .null: false
        }
    }

    var isScalar: Bool {
        switch self {
        case .string, .number, .bool, .null: true
        case .array, .object: false
        }
    }

    /// Leaf values with their key paths, in stable key order.
    func leaves(prefix: [String] = []) -> [(path: [String], value: JSONValue)] {
        switch self {
        case .object(let object):
            object.keys.sorted().flatMap { object[$0, default: .null].leaves(prefix: prefix + [$0]) }
        case .array(let values) where !values.allSatisfy(\.isScalar):
            values.enumerated().flatMap { index, value in
                value.leaves(prefix: prefix + (values.count == 1 ? [] : ["\(index + 1)"]))
            }
        default:
            text == nil ? [] : [(prefix, self)]
        }
    }
}

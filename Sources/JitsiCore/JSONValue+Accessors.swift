import Foundation

/// Ergonomic accessors for JSON payloads, wherever they come from: the JS bridge, a
/// recording session state, a config overwrite authored by the app.
public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let entries) = self { return entries[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        doubleValue.map { Int($0) }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case .object(let entries) = self { return entries }
        return [:]
    }

    var isPresent: Bool {
        if case .null = self { return false }
        return true
    }
}

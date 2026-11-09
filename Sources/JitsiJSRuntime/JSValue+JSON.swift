import Foundation
import JavaScriptCore
import JitsiCore

extension JSValue {
    /// Lossy-but-sufficient conversion for the bridge: JS objects arrive as Foundation
    /// containers, which is exactly what `JSONValue` models.
    var jsonValue: JSONValue {
        get throws {
            if isNull || isUndefined {
                return .null
            }
            if isBoolean {
                return .bool(toBool())
            }
            if isNumber {
                return .number(toDouble())
            }
            // `toArray()`/`toDictionary()` bridge nested values into Foundation containers,
            // which lose the JSValue wrapper; subscripting keeps every element a JSValue.
            if isArray {
                let count = objectForKeyedSubscript("length")?.toInt32() ?? 0
                var items: [JSONValue] = []
                items.reserveCapacity(Int(count))
                for index in 0..<Int(count) {
                    guard let element = atIndex(index) else {
                        items.append(.null)
                        continue
                    }
                    items.append(try element.jsonValue)
                }
                return .array(items)
            }
            if isObject, let dictionary = toDictionary() {
                var result: [String: JSONValue] = [:]
                for key in dictionary.keys {
                    let name = String(describing: key)
                    guard let value = objectForKeyedSubscript(name) else {
                        result[name] = .null
                        continue
                    }
                    result[name] = try value.jsonValue
                }
                return .object(result)
            }
            if let string = toString() {
                return .string(string)
            }
            return .null
        }
    }

    func property(_ name: String) -> JSValue? {
        forProperty(name)
    }

    func setProperty(_ name: String, to value: Any?) {
        setValue(value ?? NSNull(), forProperty: name)
    }
}

enum JSONBridge {
    /// `JSON.parse` is the only faithful path: JSC has no JSON-data initializer, and
    /// `valueWithObject:` would bridge `NSNull` as a non-null object.
    static func jsValue(_ value: JSONValue, in context: JSContext) -> JSValue? {
        guard let data = try? value.encoded,
              let text = String(data: data, encoding: .utf8),
              let parse = context.evaluateScript("(function (text) { 'use strict'; return JSON.parse(text); })"),
              let result = parse.call(withArguments: [text]),
              !result.isUndefined
        else {
            return JSValue(nullIn: context)
        }
        return result
    }

    /// A `JSONValue` is already a Foundation graph, so it can be handed to JSC directly;
    /// going through data would re-encode every call.
    static func nativeObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let v): return NSNumber(value: v)
        case .number(let v): return NSNumber(value: v)
        case .string(let v): return v
        case .array(let items): return items.map(nativeObject)
        case .object(let entries): return entries.mapValues(nativeObject)
        }
    }
}

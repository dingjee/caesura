import Foundation

/// JSON value tree that round-trips arbitrary user config (including unknown keys)
/// while keeping types stable. Modeled after the shapes electron-store accepts.
public enum SettingsValue: Equatable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SettingsValue])
    case object([String: SettingsValue])
    case null

    public var isFiniteNumber: Bool {
        switch self {
        case .int: return true
        case .double(let d): return d.isFinite
        default: return false
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [SettingsValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: SettingsValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var jsonValue: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonValue)
        case .object(let o):
            var result: [String: Any] = [:]
            for (key, value) in o { result[key] = value.jsonValue }
            return result
        case .null: return NSNull()
        }
    }

    public static func from(json: Any) -> SettingsValue {
        // Numbers must be checked before booleans: a Swift `Bool` bridges to NSNumber
        // and an NSNumber holding 0 or 1 casts to `Bool` as well. Only the CFBoolean
        // type is a real boolean.
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if floor(number.doubleValue) == number.doubleValue && abs(number.doubleValue) < 9.007_199_254_740_992e15 {
                return .int(Int64(number.doubleValue))
            }
            return .double(number.doubleValue)
        }
        if let string = json as? String { return .string(string) }
        if let array = json as? [Any] { return .array(array.map(from)) }
        if let object = json as? [String: Any] {
            var result: [String: SettingsValue] = [:]
            for (key, value) in object { result[key] = from(json: value) }
            return .object(result)
        }
        return .null
    }

    public static func from(jsonObject: Data) throws -> SettingsValue {
        let any = try JSONSerialization.jsonObject(with: jsonObject, options: [.fragmentsAllowed])
        return from(json: any)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        var format: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        if prettyPrinted { format.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: jsonValue, options: format)
    }
}

import Foundation

/// Injectable time source. The core never reads the wall clock directly;
/// the application owns real time, tests own `ManualClock`.
public protocol Clock {
    var nowMillis: Int64 { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var nowMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public final class ManualClock: Clock {
    public private(set) var nowMillis: Int64

    public init(start: Int64 = 0) {
        nowMillis = start
    }

    public func advance(_ millis: Int64) {
        nowMillis += millis
    }

    public func set(_ millis: Int64) {
        nowMillis = millis
    }
}

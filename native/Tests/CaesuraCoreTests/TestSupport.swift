import Foundation

// Minimal test harness: bare Command Line Tools ship neither XCTest nor Swift Testing,
// so the suite is a plain executable. Add tests via `register("name") { ... }` and
// assert with expect/expectEqual/expectNil/expectTrue/expectFalse.

struct TestFailure: Error {
    let message: String
}

func fail(_ message: String) throws -> Never {
    throw TestFailure(message: message)
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}

func expectTrue(_ condition: Bool, _ message: String = "expected true") throws {
    try expect(condition, message)
}

func expectFalse(_ condition: Bool, _ message: String = "expected false") throws {
    try expect(!condition, message)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    try expect(actual == expected, "expected \(expected), got \(actual) \(message)")
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil") throws {
    try expect(value == nil, "\(message) (got \(String(describing: value)))")
}

@discardableResult
func expectNotNil<T>(_ value: T?, _ message: String = "expected non-nil") throws -> T {
    guard let value else { throw TestFailure(message: "\(message) (got nil)") }
    return value
}

func expectThrows<T>(_ body: @autoclosure () throws -> T, _ message: String = "expected throw") throws {
    do {
        _ = try body()
        throw TestFailure(message: message)
    } catch let error as TestFailure {
        throw error
    } catch {
        // threw as expected
    }
}

struct TestCase {
    let name: String
    let body: () throws -> Void
}

enum TestRunner {
    static var tests: [TestCase] = []

    static func register(_ name: String, _ body: @escaping () throws -> Void) {
        tests.append(TestCase(name: name, body: body))
    }

    @discardableResult
    static func runAll() -> Int32 {
        var failures = 0
        for test in tests {
            do {
                try test.body()
                print("✓ \(test.name)")
            } catch {
                failures += 1
                let detail = (error as? TestFailure)?.message ?? "\(error)"
                print("✗ \(test.name)\n    \(detail)")
            }
        }
        print("\n\(tests.count - failures)/\(tests.count) passed")
        return failures == 0 ? 0 : 1
    }
}

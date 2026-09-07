// Minimal stand-ins for the XCTest API surface this suite uses, so the test
// sources can be type-checked AND run without Xcode. Compiled only by
// scripts/typecheck-tests.sh and scripts/run-tests-without-xcode.sh — never by
// build.sh or Package.swift, both of which take their sources from panel/ and
// shared/ only.
//
// `swift test` needs the XCTest module, which only ships with full Xcode. On a
// Command Line Tools-only machine the whole test target fails to load, so the
// test sources are otherwise the one part of the repo that never gets compiled
// or exercised locally.
//
// Two consumers, one shim:
//   - typecheck-tests.sh passes -typecheck, so nothing here executes. It catches
//     a production API change leaving the test sources uncompilable, which
//     otherwise fails `swift test` in CI on a pure build error.
//   - run-tests-without-xcode.sh compiles and runs them, so the assertions
//     actually evaluate and report.
//
// `swift test` under real Xcode (locally via `make test`, or in CI) remains the
// authority. This is a fast local loop, not a replacement: it reimplements only
// the assertion surface below, runs tests serially in one process, and knows
// nothing about XCTest's isolation, parallelism or timeouts.
//
// If the suite starts using an XCTAssert variant that isn't declared here, the
// type-check fails with "cannot find 'XCTAssertSomething' in scope". Add the
// overload below rather than working around it, and make it evaluate — an
// overload with an empty body silently passes every call site that uses it.
import Foundation

// MARK: - Recorded results

nonisolated(unsafe) var xctFailures: [String] = []
nonisolated(unsafe) var xctAssertions = 0
nonisolated(unsafe) var xctTeardowns: [() throws -> Void] = []

private func record(_ passed: Bool, _ detail: String, _ message: String,
                    _ file: StaticString, _ line: UInt) {
    xctAssertions += 1
    guard !passed else { return }
    let name = URL(fileURLWithPath: String(describing: file)).lastPathComponent
    let note = message.isEmpty ? "" : " - \(message)"
    xctFailures.append("\(name):\(line) \(detail)\(note)")
}

// An assertion whose operands throw can't be evaluated, which is a failure in
// its own right rather than something to skip quietly.
private func evaluate<T>(_ expression: () throws -> T, _ message: String,
                         _ file: StaticString, _ line: UInt) -> T? {
    do {
        return try expression()
    } catch {
        record(false, "expression threw \(error)", message, file, line)
        return nil
    }
}

// MARK: - XCTestCase

class XCTestCase {
    // @MainActor to match real XCTest, or a @MainActor test class's override
    // becomes nonisolated and can't touch its own main-actor properties.
    @MainActor func setUp() {}
    @MainActor func tearDown() {}
    @MainActor func setUpWithError() throws {}
    @MainActor func tearDownWithError() throws {}
    // Real XCTest runs these after the test; the runner drains them in reverse.
    func addTeardownBlock(_ block: @escaping () throws -> Void) {
        xctTeardowns.append(block)
    }
}

// MARK: - Assertions

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T,
                                  _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs == rhs, "expected \(rhs), got \(lhs)", message(), file, line)
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T,
                                     _ b: @autoclosure () throws -> T,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs != rhs, "expected anything but \(rhs)", message(), file, line)
}
func XCTAssertTrue(_ e: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, message(), file, line) else { return }
    record(value, "expected true", message(), file, line)
}
func XCTAssertFalse(_ e: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, message(), file, line) else { return }
    record(!value, "expected false", message(), file, line)
}
func XCTAssertNil<T>(_ e: @autoclosure () throws -> T?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, message(), file, line) else { return }
    record(value == nil, "expected nil, got \(String(describing: value))", message(), file, line)
}
func XCTAssertNotNil<T>(_ e: @autoclosure () throws -> T?,
                        _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let value = evaluate(e, message(), file, line) else { return }
    record(value != nil, "expected non-nil", message(), file, line)
}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T,
                                         _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs > rhs, "expected \(lhs) > \(rhs)", message(), file, line)
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T,
                                                _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs >= rhs, "expected \(lhs) >= \(rhs)", message(), file, line)
}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T,
                                      _ b: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs < rhs, "expected \(lhs) < \(rhs)", message(), file, line)
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T,
                                             _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line) else { return }
    record(lhs <= rhs, "expected \(lhs) <= \(rhs)", message(), file, line)
}
func XCTFail(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath, line: UInt = #line) {
    record(false, "XCTFail", message(), file, line)
}
// The expression is `throws`, so the stand-in has to accept a throwing closure
// (and the trailing error handler) to type-check the same call sites XCTest does.
func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try e()
        record(false, "expected a throw", message(), file, line)
    } catch {
        record(true, "", message(), file, line)
        errorHandler(error)
    }
}
func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try e()
        record(true, "", message(), file, line)
    } catch {
        record(false, "unexpected throw \(error)", message(), file, line)
    }
}
struct XCTUnwrapNilError: Error {}
// Throws rather than trapping: a nil unwrap should fail the one test, not take
// the whole run down with it.
func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try e() else {
        record(false, "expected non-nil to unwrap", message(), file, line)
        throw XCTUnwrapNilError()
    }
    xctAssertions += 1
    return value
}
func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T,
                                      _ b: @autoclosure () throws -> T,
                                      accuracy: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    guard let lhs = evaluate(a, message(), file, line),
          let rhs = evaluate(b, message(), file, line),
          let tolerance = evaluate(accuracy, message(), file, line) else { return }
    record(abs(lhs - rhs) <= tolerance, "expected \(rhs) ± \(tolerance), got \(lhs)",
           message(), file, line)
}

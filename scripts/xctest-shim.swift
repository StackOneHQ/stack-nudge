// Minimal stand-ins for the XCTest API surface this suite uses, so the test
// sources can be TYPE-CHECKED without Xcode. Compiled only by
// scripts/typecheck-tests.sh — never by build.sh or Package.swift, both of which
// take their sources from panel/ and shared/ only.
//
// This does NOT run the tests: no assertion here evaluates anything. It catches
// the failure mode that is otherwise invisible on a Command Line Tools-only
// machine — a production API change (a newly required parameter, a renamed case)
// leaving the test sources uncompilable, which fails `swift test` in CI on a pure
// build error.
//
// If the suite starts using an XCTAssert variant that isn't declared here, the
// type-check fails with "cannot find 'XCTAssertSomething' in scope". Add the
// overload below rather than working around it.
import Foundation

class XCTestCase {
    // @MainActor to match real XCTest, or a @MainActor test class's override
    // becomes nonisolated and can't touch its own main-actor properties.
    @MainActor func setUp() {}
    @MainActor func tearDown() {}
    @MainActor func setUpWithError() throws {}
    @MainActor func tearDownWithError() throws {}
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T,
                                  _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T,
                                     _ b: @autoclosure () throws -> T,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertTrue(_ e: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertFalse(_ e: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertNil<T>(_ e: @autoclosure () throws -> T?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertNotNil<T>(_ e: @autoclosure () throws -> T?,
                        _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T,
                                         _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T,
                                                _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T,
                                      _ b: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T,
                                             _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {}
func XCTFail(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath, line: UInt = #line) {}
func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try e() else { fatalError("unwrap") }
    return value
}
func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T,
                                      _ b: @autoclosure () throws -> T,
                                      accuracy: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {}

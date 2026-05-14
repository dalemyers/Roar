import XCTest
import ArgumentParser

/// Shared XCTest helpers used across the Roar test suite.
///
/// The repetitive `XCTAssertThrowsError + XCTAssertTrue($0 is
/// ValidationError, "got \(type(of: $0))")` pattern appears at ~150
/// sites — one helper collapses every occurrence and makes the
/// intent ("this call must throw a ValidationError") visible from
/// the test name without scanning past assertion machinery.
///
/// The helper intentionally matches `ArgumentParser.ValidationError`
/// specifically (not arbitrary `Error`); the validators in `Send+*`
/// throw `ValidationError` so ArgumentParser formats the failure
/// consistently with `--help`-style messages. A regression that
/// switched the throw to a different type would surface as a
/// failed assertion here.

/// Assert that `expression` throws an `ArgumentParser.ValidationError`.
///
/// - Parameters:
///   - expression: An autoclosure expected to throw.
///   - message: Optional message to include in the failure.
///   - file/line: Standard XCTest location parameters; default to
///     the call site.
func XCTAssertThrowsValidationError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertThrowsError(
        try expression(),
        message(),
        file: file, line: line
    ) { error in
        XCTAssertTrue(
            error is ValidationError,
            "Expected ValidationError, got \(type(of: error)): \(error). \(message())",
            file: file, line: line
        )
    }
}

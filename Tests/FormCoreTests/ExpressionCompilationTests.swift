import Foundation
import XCTest
@testable import FormCore

final class ExpressionCompilationTests: XCTestCase {
  func testArithmeticAndFunctionParity() throws {
    let cases: [(String, Double)] = [
      ("8/2/2", 2), ("1-2-3", -4), ("-2*-3 + +4", 10),
      ("sin(pi/2)+cos(0)", 2), ("sqrt(abs(-9))", 3),
      ("floor(-1.2)+ceil(1.2)", 0), ("round(-1.5)+round(2.5)", 1),
      ("fract(-0.2)", 0.8), ("pow(3,2)+atan2(0,1)", 9),
      ("min(4,2)+max(-3,1)", 3), ("clamp(-5,0,1)", 0),
      ("mix(2,10,0.25)", 4), ("pick(1,sqrt(9),pow(3,2),4)", 9),
      ("pick(0,8,9,10)", 8), ("pick(2,8,9,10)", 10),
      ("2*(3+4)-5/2", 11.5), ("\t 2 +\n3 * 4 ", 14)
    ]
    for (source, expected) in cases {
      XCTAssertEqual(try Expression.evaluate(source, variables: [:]), expected, accuracy: 1e-12, source)
    }
    XCTAssertEqual(try Expression.evaluate("pi", variables: ["pi": 0]), .pi)
  }

  func testCachedSyntaxReadsEveryNewParameterValue() throws {
    let source = "(width-2*margin)/columns+mix(low,high,t)"
    for i in 0..<200 {
      let width = Double(i) * 1.25, t = Double(i % 11) / 10
      let variables = ["width": width, "margin": 4.0, "columns": 3.0,
                       "low": -2.0, "high": 8.0, "t": t]
      let expected = (width - 8) / 3 + (-2 + 10 * t)
      XCTAssertEqual(try Expression.evaluate(source, variables: variables), expected, accuracy: 1e-12)
    }
    XCTAssertThrowsError(try Expression.evaluate(source, variables: [:]))
    XCTAssertEqual(try Expression.evaluate(source, variables: ["width": 20, "margin": 1,
      "columns": 2, "low": 0, "high": 2, "t": 0.5]), 10)
  }

  func testOriginalErrorMessagesAndLeftToRightPrecedence() throws {
    let errors: [(String, String)] = [
      ("1/0", "Division by zero in parameter expression."),
      ("unknown + (", "Unknown variable 'unknown' in parameter expression."),
      ("1/0 + (", "Division by zero in parameter expression."),
      ("sqrt(-1) + (", "Nonfinite result from sqrt."),
      ("sin(1, unknown)", "Unknown variable 'unknown' in parameter expression."),
      ("sin(", "Unknown variable '' in parameter expression."),
      ("(unknown", "Unknown variable 'unknown' in parameter expression."),
      ("sin(1/0", "Division by zero in parameter expression."),
      ("(1+2", "Missing closing parenthesis."),
      ("unknown(1,2", "Missing function closing parenthesis."),
      ("sin(1 2)", "Missing function closing parenthesis."),
      ("1 + 2 3", "Invalid expression: 1 + 2 3"),
      ("sin()", "sin requires 1 arguments."),
      ("pow(2)", "pow requires 2 arguments."),
      ("mix(1,2)", "mix requires 3 arguments."),
      ("clamp(1,2,0)", "Invalid clamp range."),
      ("pick(1.5,2,3)", "pick needs a valid zero-based integer index and choices."),
      ("pick(-1,2,3)", "pick needs a valid zero-based integer index and choices."),
      ("pick(0,5,sqrt(-1))", "Nonfinite result from sqrt."),
      ("unknown(0)", "Unknown function 'unknown'."),
      ("pow(0,-1)", "Nonfinite result from pow.")
    ]
    for (source, expected) in errors {
      // Run twice to exercise both compilation and cached failure paths.
      for _ in 0..<2 {
        XCTAssertThrowsError(try Expression.evaluate(source, variables: [:]), source) {
          XCTAssertEqual($0.localizedDescription, expected, source)
        }
      }
    }
    let seventeen = "pick(" + Array(repeating: "0", count: 17).joined(separator: ",") + ")"
    XCTAssertThrowsError(try Expression.evaluate(seventeen, variables: [:])) {
      XCTAssertEqual($0.localizedDescription, "Too many function arguments.")
    }
    let sixteen = "pick(14," + (0..<15).map(String.init).joined(separator: ",") + ")"
    XCTAssertEqual(try Expression.evaluate(sixteen, variables: [:]), 14)
  }

  func testCharacterLimitTokenBoundariesAndNonfiniteValues() throws {
    XCTAssertEqual(try Expression.evaluate("1" + String(repeating: " ", count: 511), variables: [:]), 1)
    XCTAssertThrowsError(try Expression.evaluate("1" + String(repeating: " ", count: 512), variables: [:])) {
      XCTAssertEqual($0.localizedDescription, "Expression is too long.")
    }
    XCTAssertEqual(try Expression.evaluate("longueur+幅", variables: ["longueur": 4, "幅": 3]), 7)
    // Keep the existing scanner's dictionary lookup behavior at these boundaries.
    XCTAssertEqual(try Expression.evaluate("", variables: ["": 3]), 3)
    XCTAssertEqual(try Expression.evaluate("12..3+1", variables: ["12..3": 7]), 8)
    XCTAssertThrowsError(try Expression.evaluate("value*value", variables: ["value": .greatestFiniteMagnitude])) {
      XCTAssertEqual($0.localizedDescription, "Invalid expression: value*value")
    }
    XCTAssertThrowsError(try Expression.evaluate("sin(value)", variables: ["value": .infinity])) {
      XCTAssertEqual($0.localizedDescription, "Nonfinite result from sin.")
    }
  }

  func testConcurrentCompilationAndIndependentVariables() {
    final class Failures: @unchecked Sendable {
      let lock = NSLock()
      var messages: [String] = []
      func append(_ value: String) { lock.lock(); messages.append(value); lock.unlock() }
    }
    let failures = Failures()
    DispatchQueue.concurrentPerform(iterations: 256) { i in
      do {
        let x = Double(i), t = Double(i % 9) / 8
        for _ in 0..<8 {
          let result = try Expression.evaluate("mix(x,x+8,t)+sqrt(9)", variables: ["x": x, "t": t])
          if abs(result - (x + 8 * t + 3)) > 1e-12 { failures.append("Unexpected result for \(i)") }
        }
        // Also compile distinct keys while other workers read the shared entry.
        let result = try Expression.evaluate("base+\(i)", variables: ["base": -x])
        if result != 0 { failures.append("Incorrect fresh source for \(i)") }
      } catch { failures.append(error.localizedDescription) }
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.prefix(5).joined(separator: "; "))
  }

  func testCacheBoundsCountAndActualUTF8SourceBytes() throws {
    let limits = Expression.compilationCacheUsage
    for i in 0..<(limits.maximumEntries + 64) {
      XCTAssertEqual(try Expression.evaluate("value+\(i)", variables: ["value": 2]), Double(i + 2))
    }
    var usage = Expression.compilationCacheUsage
    XCTAssertGreaterThan(usage.entries, 0)
    XCTAssertLessThanOrEqual(usage.entries, usage.maximumEntries)
    XCTAssertLessThanOrEqual(usage.sourceBytes, usage.maximumSourceBytes)

    // Each source is below 512 characters but uses more than 1,500 UTF-8 bytes.
    let whitespace = String(repeating: "\u{2003}", count: 500)
    for i in 0..<800 {
      let name = "v\(i)", source = whitespace + "v\(i)"
      XCTAssertLessThanOrEqual(source.count, 512)
      XCTAssertGreaterThan(source.utf8.count, 1_500)
      XCTAssertEqual(try Expression.evaluate(source, variables: [name: Double(i)]), Double(i))
    }
    usage = Expression.compilationCacheUsage
    XCTAssertLessThan(usage.entries, usage.maximumEntries)
    XCTAssertLessThanOrEqual(usage.sourceBytes, usage.maximumSourceBytes)
    XCTAssertGreaterThan(usage.sourceBytes, usage.maximumSourceBytes / 2)
    XCTAssertEqual(try Expression.evaluate("value+0", variables: ["value": 19]), 19)
  }
}

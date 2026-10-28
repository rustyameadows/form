import Foundation

/// A small arithmetic grammar for parametric parts. Never evaluates code or Foundation expressions.
public enum Expression {
  public static func evaluate(_ source: String, variables: [String: Double]) throws -> Double {
    guard source.count <= 512 else { throw FormError.invalid("Expression is too long.") }
    var parser = Parser(source: Array(source), variables: variables)
    let result = try parser.sum()
    parser.whitespace()
    guard parser.index == parser.source.count, result.isFinite else {
      throw FormError.invalid("Invalid expression: \(source)")
    }
    return result
  }
  private struct Parser {
    let source: [Character]
    let variables: [String: Double]
    var index = 0
    mutating func whitespace() {
      while index < source.count && source[index].isWhitespace { index += 1 }
    }
    mutating func take(_ c: Character) -> Bool {
      whitespace()
      if index < source.count && source[index] == c {
        index += 1
        return true
      }
      return false
    }
    mutating func sum() throws -> Double {
      var value = try product()
      while true {
        if take("+") {
          value += try product()
        } else if take("-") {
          value -= try product()
        } else {
          return value
        }
      }
    }
    mutating func product() throws -> Double {
      var value = try atom()
      while true {
        if take("*") {
          value *= try atom()
        } else if take("/") {
          let divisor = try atom()
          guard divisor != 0 else {
            throw FormError.invalid("Division by zero in parameter expression.")
          }
          value /= divisor
        } else {
          return value
        }
      }
    }
    mutating func atom() throws -> Double {
      whitespace()
      if take("-") { return -(try atom()) }
      if take("+") { return try atom() }
      if take("(") {
        let value = try sum()
        guard take(")") else { throw FormError.invalid("Missing closing parenthesis.") }
        return value
      }
      let start = index
      while index < source.count && (source[index].isNumber || source[index] == ".") { index += 1 }
      if index > start, let number = Double(String(source[start..<index])) { return number }
      while index < source.count
        && (source[index].isLetter || source[index].isNumber || source[index] == "_")
      { index += 1 }
      let key = String(source[start..<index])
      if key == "pi" { return .pi }
      guard let value = variables[key] else {
        throw FormError.invalid("Unknown variable '\(key)' in parameter expression.")
      }
      return value
    }
  }
}

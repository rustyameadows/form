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
      if take("(") {
        var args:[Double]=[]
        if !take(")") {
          repeat {guard args.count<16 else{throw FormError.invalid("Too many function arguments.")};args.append(try sum())} while take(",")
          guard take(")") else{throw FormError.invalid("Missing function closing parenthesis.")}
        }
        func arity(_ n:Int)throws {guard args.count==n else{throw FormError.invalid("\(key) requires \(n) arguments.")}}
        let result:Double
        switch key {
        case "sin":try arity(1);result=sin(args[0])
        case "cos":try arity(1);result=cos(args[0])
        case "sqrt":try arity(1);result=sqrt(args[0])
        case "abs":try arity(1);result=abs(args[0])
        case "floor":try arity(1);result=floor(args[0])
        case "ceil":try arity(1);result=ceil(args[0])
        case "round":try arity(1);result=args[0].rounded()
        case "fract":try arity(1);result=args[0]-floor(args[0])
        case "pow":try arity(2);result=pow(args[0],args[1])
        case "atan2":try arity(2);result=atan2(args[0],args[1])
        case "min":try arity(2);result=min(args[0],args[1])
        case "max":try arity(2);result=max(args[0],args[1])
        case "clamp":try arity(3);guard args[1]<=args[2] else{throw FormError.invalid("Invalid clamp range.")};result=min(args[2],max(args[1],args[0]))
        case "mix":try arity(3);result=args[0]+(args[1]-args[0])*args[2]
        case "pick":
          guard args.count>=2,args[0].rounded()==args[0],args[0]>=0,args[0]<Double(args.count-1) else{throw FormError.invalid("pick needs a valid zero-based integer index and choices.")}
          result=args[Int(args[0])+1]
        default:throw FormError.invalid("Unknown function '\(key)'.")
        }
        guard result.isFinite else{throw FormError.invalid("Nonfinite result from \(key).")};return result
      }
      if key == "pi" { return .pi }
      guard let value = variables[key] else {
        throw FormError.invalid("Unknown variable '\(key)' in parameter expression.")
      }
      return value
    }
  }
}

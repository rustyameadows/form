import Foundation

/// A small arithmetic grammar for parametric parts. Compiles only this grammar;
/// never evaluates code or Foundation expressions. Variable values are not cached.
public enum Expression {
  private static let compiledCache = CompilationCache()

  public static func evaluate(_ source: String, variables: [String: Double]) throws -> Double {
    let compiled = try compiledCache.expression(source)
    // The cache lock is released before variable lookup or evaluation.
    let result = try compiled.root.evaluate(variables)
    guard !compiled.hasTrailingInput, result.isFinite else {
      throw FormError.invalid("Invalid expression: \(source)")
    }
    return result
  }

  struct CacheUsage: Sendable {
    let entries: Int
    let sourceBytes: Int
    let maximumEntries: Int
    let maximumSourceBytes: Int
  }
  static var compilationCacheUsage: CacheUsage { compiledCache.usage }

  private struct Compiled: Sendable {
    let root: Node
    let hasTrailingInput: Bool
  }

  /// Strict FIFO limits bound retained keys, including their actual UTF-8 size.
  /// Competing misses may compile independently, without holding the cache lock.
  private final class CompilationCache: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEntries = 2_048
    private let maximumSourceBytes = 1_048_576
    private var entries: [String: Compiled] = [:]
    private var order: [String] = []
    private var sourceBytes = 0

    func expression(_ source: String) throws -> Compiled {
      lock.lock()
      if let cached = entries[source] {
        lock.unlock()
        return cached
      }
      lock.unlock()

      guard source.count <= 512 else { throw FormError.invalid("Expression is too long.") }
      var parser = Parser(source: Array(source))
      let root = parser.sum()
      parser.whitespace()
      let compiled = Compiled(root: root, hasTrailingInput: parser.index != parser.source.count)
      let bytes = source.utf8.count
      // One grapheme can contain many code points. Preserve the character limit
      // while declining to retain a source larger than the whole cache budget.
      guard bytes <= maximumSourceBytes else { return compiled }

      lock.lock()
      defer { lock.unlock() }
      if let cached = entries[source] { return cached }
      while entries.count >= maximumEntries || sourceBytes + bytes > maximumSourceBytes {
        let oldest = order.removeFirst()
        entries.removeValue(forKey: oldest)
        sourceBytes -= oldest.utf8.count
      }
      entries[source] = compiled
      order.append(source)
      sourceBytes += bytes
      return compiled
    }

    var usage: CacheUsage {
      lock.lock()
      defer { lock.unlock() }
      return .init(entries: entries.count, sourceBytes: sourceBytes,
                   maximumEntries: maximumEntries, maximumSourceBytes: maximumSourceBytes)
    }
  }

  private enum Binary: Sendable { case add, subtract, multiply, divide }
  private enum Function: String, Sendable {
    case sin, cos, sqrt, abs, floor, ceil, round, fract, pow, atan2, min, max, clamp, mix, pick
  }

  private indirect enum Node: Sendable {
    case number(Double)
    case variable(String)
    case negative(Node)
    case binary(Binary, Node, Node)
    case call(String, Function?, [Node])
    // Defer syntax failures until their already-parsed operands have run. This
    // retains the original parser's left-to-right runtime error precedence.
    case failureAfter([Node], String)

    func evaluate(_ variables: [String: Double]) throws -> Double {
      switch self {
      case .number(let value): return value
      case .variable(let name):
        guard let value = variables[name] else {
          throw FormError.invalid("Unknown variable '\(name)' in parameter expression.")
        }
        return value
      case .negative(let operand): return -(try operand.evaluate(variables))
      case .binary(let operation, let left, let right):
        let a = try left.evaluate(variables), b = try right.evaluate(variables)
        switch operation {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide:
          guard b != 0 else { throw FormError.invalid("Division by zero in parameter expression.") }
          return a / b
        }
      case .failureAfter(let operands, let message):
        for operand in operands { _ = try operand.evaluate(variables) }
        throw FormError.invalid(message)
      case .call(let name, let function, let arguments):
        // Avoid a temporary values array for the common small-arity calls.
        // All arguments still run before arity/range checks, even unused pick choices.
        var a = 0.0, b = 0.0, c = 0.0, selected = 0.0
        for (index, argument) in arguments.enumerated() {
          let value = try argument.evaluate(variables)
          switch index { case 0: a = value; case 1: b = value; case 2: c = value; default: break }
          if index > 0, Double(index - 1) == a { selected = value }
        }
        func arity(_ count: Int) throws {
          guard arguments.count == count else { throw FormError.invalid("\(name) requires \(count) arguments.") }
        }
        let result: Double
        switch function {
        case .sin: try arity(1); result = sin(a)
        case .cos: try arity(1); result = cos(a)
        case .sqrt: try arity(1); result = sqrt(a)
        case .abs: try arity(1); result = abs(a)
        case .floor: try arity(1); result = floor(a)
        case .ceil: try arity(1); result = ceil(a)
        case .round: try arity(1); result = a.rounded()
        case .fract: try arity(1); result = a - floor(a)
        case .pow: try arity(2); result = pow(a, b)
        case .atan2: try arity(2); result = atan2(a, b)
        case .min: try arity(2); result = min(a, b)
        case .max: try arity(2); result = max(a, b)
        case .clamp:
          try arity(3)
          guard b <= c else { throw FormError.invalid("Invalid clamp range.") }
          result = min(c, max(b, a))
        case .mix: try arity(3); result = a + (b - a) * c
        case .pick:
          guard arguments.count >= 2, a.rounded() == a, a >= 0, a < Double(arguments.count - 1) else {
            throw FormError.invalid("pick needs a valid zero-based integer index and choices.")
          }
          result = selected
        case nil: throw FormError.invalid("Unknown function '\(name)'.")
        }
        guard result.isFinite else { throw FormError.invalid("Nonfinite result from \(name).") }
        return result
      }
    }
  }

  private struct Parser {
    let source: [Character]
    var index = 0
    mutating func whitespace() {
      while index < source.count && source[index].isWhitespace { index += 1 }
    }
    mutating func take(_ character: Character) -> Bool {
      whitespace()
      if index < source.count && source[index] == character {
        index += 1
        return true
      }
      return false
    }
    mutating func sum() -> Node {
      var node = product()
      while true {
        if take("+") { node = .binary(.add, node, product()) }
        else if take("-") { node = .binary(.subtract, node, product()) }
        else { return node }
      }
    }
    mutating func product() -> Node {
      var node = atom()
      while true {
        if take("*") { node = .binary(.multiply, node, atom()) }
        else if take("/") { node = .binary(.divide, node, atom()) }
        else { return node }
      }
    }
    mutating func atom() -> Node {
      whitespace()
      if take("-") { return .negative(atom()) }
      if take("+") { return atom() }
      if take("(") {
        let node = sum()
        guard take(")") else { return .failureAfter([node], "Missing closing parenthesis.") }
        return node
      }
      let start = index
      while index < source.count && (source[index].isNumber || source[index] == ".") { index += 1 }
      if index > start, let number = Double(String(source[start..<index])) { return .number(number) }
      while index < source.count && (source[index].isLetter || source[index].isNumber || source[index] == "_") { index += 1 }
      let name = String(source[start..<index])
      if take("(") {
        var arguments: [Node] = []
        if !take(")") {
          repeat {
            guard arguments.count < 16 else { return .failureAfter(arguments, "Too many function arguments.") }
            arguments.append(sum())
          } while take(",")
          guard take(")") else { return .failureAfter(arguments, "Missing function closing parenthesis.") }
        }
        return .call(name, Function(rawValue: name), arguments)
      }
      return name == "pi" ? .number(.pi) : .variable(name)
    }
  }
}

import FormCore
import Foundation

public struct SVGImportIssue: Codable, Equatable, Sendable {
  public let severity: String
  public let element: String
  public let message: String
  public var summary: String { "\(element): \(message)" }
}

final class SVGNode {
  let name: String, attributes: [String: String]
  weak var parent: SVGNode?
  var children: [SVGNode] = []
  enum Content {
    case text(String)
    case node(SVGNode)
  }
  var content: [Content] = []
  var text: String {
    content.map {
      if case .text(let t) = $0 { return t }
      if case .node(let n) = $0 { return n.text }
      return ""
    }.joined()
  }
  var label: String { attributes["id"].map { "\(name)#\(String($0.prefix(300)))" } ?? name }
  subscript(_ key: String) -> String? { attributes[key] }
  init(_ name: String, _ attributes: [String: String]) {
    self.name = name
    self.attributes = attributes
  }
}

final class SVGDocument: NSObject, XMLParserDelegate {
  var root: SVGNode?
  var ids: [String: SVGNode] = [:]
  var warnings: [String] = []
  private var stack: [SVGNode] = []
  private var count = 0
  private var failure: Error?
  static func read(_ data: Data) throws -> SVGDocument {
    guard data.count <= 10_000_000 else {
      throw FormError.invalid("SVG files are limited to 10 MB.")
    }
    // Reject declarations before XML parsing, including UTF-16/32 encodings.
    let utf8 = String(decoding: data, as: UTF8.self).lowercased().replacingOccurrences(
      of: "\0", with: "")
    guard !utf8.contains("<!doctype"), !utf8.contains("<!entity") else {
      throw FormError.invalid("SVG document types and entity declarations are not supported.")
    }
    let result = SVGDocument()
    let parser = XMLParser(data: data)
    parser.delegate = result
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    guard parser.parse(), result.failure == nil, result.root?.name == "svg" else {
      throw result.failure
        ?? FormError.invalid(
          "Invalid SVG XML: \(parser.parserError?.localizedDescription ?? "expected an svg root")")
    }
    return result
  }
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    count += 1
    guard stack.count < 64, count <= 10_000 else {
      failure = FormError.invalid("SVG exceeds 64 levels or 10,000 XML elements.")
      parser.abortParsing()
      return
    }
    let node = SVGNode(name.split(separator: ":").last.map(String.init)!.lowercased(), attributes)
    if let id = node["id"] {
      guard ids[id] == nil else {
        failure = FormError.invalid("Duplicate SVG ID: \(id)")
        parser.abortParsing()
        return
      }
      ids[id] = node
    }
    if let parent = stack.last {
      parent.children.append(node)
      parent.content.append(.node(node))
      node.parent = parent
    } else {
      root = node
    }
    stack.append(node)
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    if !stack.isEmpty { stack.removeLast() }
  }
  func parser(_ parser: XMLParser, foundCharacters text: String) {
    stack.last?.content.append(.text(text))
  }
  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    stack.last?.content.append(.text(String(decoding: data, as: UTF8.self)))
  }
  func parser(
    _ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?
  ) {
    warnings.append(
      "Processing instruction '\(String(target.prefix(100)))' is omitted; external styles are never loaded."
    )
  }
  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) {
    failure = FormError.invalid("SVG entities are not supported.")
    parser.abortParsing()
  }
  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) {
    failure = FormError.invalid("External SVG entities are not supported.")
    parser.abortParsing()
  }
}

struct SVGStyleSheet {
  struct Rule { let selector: String, declarations: [String: String], specificity: Int, order: Int }
  var rules: [Rule] = []
  static let inherited: Set<String> = [
    "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
    "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
    "stroke-dashoffset", "color", "visibility", "font-family", "font-size", "font-weight",
    "font-style", "font-stretch", "letter-spacing", "word-spacing", "text-anchor", "direction",
    "dominant-baseline", "text-decoration", "clip-rule", "white-space",
  ]
  static let supported = inherited.union([
    "display", "opacity", "clip-path", "stop-color", "stop-opacity", "overflow",
  ])
  static func declarations(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for field in text.split(separator: ";") {
      let pair = field.split(separator: ":", maxSplits: 1)
      if pair.count == 2 {
        result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = pair[1]
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return result
  }
  mutating func add(_ text: String, issue: (String) -> Void) {
    let clean = text.replacingOccurrences(
      of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
    guard !clean.contains("@") else {
      issue(
        "Stylesheets containing CSS at-rules are omitted. Flatten media rules and font declarations before import."
      )
      return
    }
    let regex = try! NSRegularExpression(pattern: "([^{}]+)\\{([^{}]*)\\}")
    for match in regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)) {
      let selector = String(clean[Range(match.range(at: 1), in: clean)!])
      let declarations = Self.declarations(String(clean[Range(match.range(at: 2), in: clean)!]))
      for property in declarations.keys where !Self.supported.contains(property) {
        issue("CSS property '\(property)' is not supported.")
      }
      for raw in selector.split(separator: ",") {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 500, !s.contains(where: { ":[~+>@\\".contains($0) }), !s.isEmpty,
          s.split(whereSeparator: \.isWhitespace).allSatisfy({ token in
            let value = String(token)
            let matches = Self.selectorToken.matches(
              in: value, range: NSRange(value.startIndex..., in: value))
            return matches.reduce(0, { $0 + $1.range.length }) == value.utf16.count
          })
        else {
          issue("CSS selector '\(s)' is not supported.")
          continue
        }
        guard rules.count < 512 else {
          issue("CSS rules beyond the 512-rule import limit are omitted.")
          return
        }
        let specificity =
          s.filter { $0 == "#" }.count * 100 + s.filter { $0 == "." }.count * 10
          + s.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter == true }.count
        rules.append(
          .init(
            selector: s, declarations: declarations, specificity: specificity, order: rules.count))
      }
    }
  }
  func style(_ node: SVGNode, inherited parent: [String: String]) -> [String: String] {
    var result = parent.filter { Self.inherited.contains($0.key) }
    for (key, value) in node.attributes where Self.supported.contains(key) { result[key] = value }
    var important = Set<String>()
    func apply(_ declarations: [String: String]) {
      for (key, raw) in declarations {
        let strong = raw.contains("!important")
        let value = raw.replacingOccurrences(of: "!important", with: "").trimmingCharacters(
          in: .whitespacesAndNewlines)
        if !important.contains(key) || strong {
          result[key] = value
          if strong { important.insert(key) }
        }
      }
    }
    for rule in rules.filter({ matches($0.selector, node) }).sorted(by: {
      $0.specificity == $1.specificity ? $0.order < $1.order : $0.specificity < $1.specificity
    }) { apply(rule.declarations) }
    apply(Self.declarations(node["style"] ?? ""))
    for (key, value) in result {
      if value == "inherit" || value == "unset" && Self.inherited.contains(key) {
        result[key] = parent[key]
      } else if value == "initial" || value == "unset" {
        result[key] = nil
      }
    }
    return result
  }
  private func matches(_ selector: String, _ node: SVGNode) -> Bool {
    let tokens = selector.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let last = tokens.last, simple(last, node) else { return false }
    var ancestor = node.parent
    for token in tokens.dropLast().reversed() {
      while let current = ancestor, !simple(token, current) { ancestor = current.parent }
      guard ancestor != nil else { return false }
      ancestor = ancestor?.parent
    }
    return true
  }
  private func simple(_ selector: String, _ node: SVGNode) -> Bool {
    let matches = Self.selectorToken.matches(
      in: selector, range: NSRange(selector.startIndex..., in: selector))
    guard matches.reduce(0, { $0 + $1.range.length }) == selector.utf16.count else { return false }
    let classes = Set((node["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    for match in matches {
      let kind = String(selector[Range(match.range(at: 1), in: selector)!])
      let value = String(selector[Range(match.range(at: 2), in: selector)!])
      if kind == "." {
        if !classes.contains(value) { return false }
      } else if kind == "#" {
        if node["id"] != value { return false }
      } else if value != "*" && value.lowercased() != node.name {
        return false
      }
    }
    return !matches.isEmpty
  }
  private static let selectorToken = try! NSRegularExpression(
    pattern: "([.#]?)([a-zA-Z_][a-zA-Z0-9_-]*|\\*)")
}

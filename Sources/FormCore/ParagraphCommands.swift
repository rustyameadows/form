import Foundation

extension Typography {
  public var usesCustomTabs: Bool { tabStops != nil || defaultTabInterval != nil }
}

public enum ParagraphCommands {
  public static func edit(_ art: inout Artwork, ids: Set<UUID>, arguments: [String: Any]) throws {
    guard !ids.isEmpty, let patch = arguments["typography"] as? [String: Any], !patch.isEmpty,
      Set(patch.keys).isSubset(of: TextStyleCommands.paragraphProperties) else {
      throw FormError.invalid("Choose text and provide supported paragraph typography properties.")
    }
    let targets = art.swatchPaintTargets(for: ids)
    let texts = art.elements.filter { targets.contains($0.id) && $0.kind == "text" }
    let textIDs = Set(texts.map(\.id))
    guard !texts.isEmpty, texts.allSatisfy({ !art.isLocked($0) }),
      (arguments["location"] == nil) == (arguments["length"] == nil),
      arguments["location"] == nil || (arguments["location"] is Int && arguments["length"] is Int && texts.count == 1) else {
      throw FormError.invalid("Choose unlocked text; a UTF-16 paragraph range requires one text object.")
    }
    func changed(_ type: Typography) throws -> Typography {
      var raw = try jsonObject(type) as! [String: Any]
      for (key, value) in patch { raw[key] = value is NSNull ? nil : value }
      let result = try JSONDecoder.form.decode(Typography.self, from: JSONSerialization.data(withJSONObject: raw))
      try validateTypography(result)
      return result
    }
    var candidate = art
    for i in candidate.elements.indices where textIDs.contains(candidate.elements[i].id) {
      var e = candidate.elements[i]
      if let location = arguments["location"] as? Int, let length = arguments["length"] as? Int {
        let count = e.text.utf16.count
        let utf16 = e.text as NSString
        func boundary(_ offset: Int) -> Bool {
          offset == 0 || offset == count
            || !(0xD800...0xDBFF).contains(utf16.character(at:offset-1))
            || !(0xDC00...0xDFFF).contains(utf16.character(at:offset))
        }
        guard location >= 0, length >= 0, location <= count, length <= count-location,
          boundary(location), boundary(location+length),
          Range(NSRange(location: location, length: length), in: e.text) != nil else {
          throw FormError.invalid("Choose a valid UTF-16 range at character boundaries.")
        }
        let range = (e.text as NSString).paragraphRange(for: NSRange(location: location, length: length))
        guard count == 0 || range.length > 0 else { throw FormError.invalid("Choose a paragraph containing text rather than the empty trailing paragraph.") }
        if count == 0 { e.typography = try changed(e.typography ?? .init()) }
        else {
          let old = e.textRuns ?? []
          let edges = Set([0, count, range.location, NSMaxRange(range)]
            + old.flatMap { [$0.location, $0.location+$0.length] }).sorted()
          e.textRuns = try zip(edges, edges.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            var run = old.first { $0.location <= start && $0.location+$0.length >= end } ?? TextStyleCommands.span(e)
            run.location = start; run.length = end-start
            if start >= range.location && end <= NSMaxRange(range) { run.typography = try changed(run.typography) }
            return run
          }
        }
      } else {
        e.typography = try changed(e.typography ?? .init())
        for r in e.textRuns?.indices ?? 0..<0 { e.textRuns![r].typography = try changed(e.textRuns![r].typography) }
      }
      candidate.elements[i] = e
    }
    try validateArtwork(candidate)
    art = candidate
  }
}

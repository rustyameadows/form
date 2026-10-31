import Foundation

public struct TextStyleReference: Codable, Equatable, Hashable, Sendable {
  public var styleID: UUID
  public var overrides: [String] = []
  public var characterOnly: Bool?
  public init(styleID: UUID) { self.styleID = styleID }
  private enum CodingKeys: String, CodingKey { case styleID, overrides, characterOnly }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    styleID = try c.decode(UUID.self, forKey: .styleID)
    overrides = try c.decodeIfPresent([String].self, forKey: .overrides) ?? []
    characterOnly = try c.decodeIfPresent(Bool.self, forKey: .characterOnly)
  }
}

public struct ArtworkTextStyle: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var typography: Typography
  public var fontSize: Double
  public init(name: String, typography: Typography = .init(), fontSize: Double = 14) {
    self.name = name; self.typography = typography; self.fontSize = fontSize
  }
}

/// Styles hold character and paragraph formatting; frame behavior and manual
/// pair positions belong to individual text objects. Colors retain palette links.
public enum TextStyleCommands {
  private struct Property {
    let name: String
    let differs: (Typography, Typography) -> Bool
    let copy: (inout Typography, Typography) -> Void
    init<T: Equatable>(_ name: String, _ path: WritableKeyPath<Typography, T>) {
      self.name = name
      differs = { $0[keyPath: path] != $1[keyPath: path] }
      copy = { $0[keyPath: path] = $1[keyPath: path] }
    }
  }
  private static let properties: [Property] = [
    .init("fontName", \.fontName), .init("tracking", \.tracking), .init("leading", \.leading),
    .init("baseline", \.baseline), .init("wordSpacing", \.wordSpacing),
    .init("horizontalScale", \.horizontalScale), .init("alignment", \.alignment),
    .init("paragraphBefore", \.paragraphBefore), .init("paragraphAfter", \.paragraphAfter),
    .init("leftIndent", \.leftIndent), .init("rightIndent", \.rightIndent),
    .init("firstLineIndent", \.firstLineIndent), .init("underline", \.underline),
    .init("strikethrough", \.strikethrough), .init("ligatures", \.ligatures),
    .init("direction", \.direction), .init("caseTreatment", \.caseTreatment),
    .init("hyphenation", \.hyphenation), .init("features", \.features),
    .init("featureSelections", \.featureSelections), .init("variations", \.variations),
    .init("kerningMode", \.kerningMode), .init("opticalSizing", \.opticalSizing),
    .init("characterPosition", \.characterPosition),
    .init("tabStops", \.tabStops), .init("defaultTabInterval", \.defaultTabInterval),
    .init("language", \.language), .init("hyphenationLimits", \.hyphenationLimits),
    .init("alignToBaselineGrid", \.alignToBaselineGrid),
  ]
  public static let propertyNames = Set(properties.map(\.name) + ["fontSize"])

  public static func recording(_ after: TextSpan, from before: TextSpan) -> TextSpan {
    var result = after
    if var ref = after.textStyle, ref == before.textStyle {
      var keys = Set(ref.overrides)
      for p in properties where p.differs(after.typography, before.typography)
        && (ref.characterOnly != true || !paragraphProperties.contains(p.name)) { keys.insert(p.name) }
      if after.fontSize != before.fontSize { keys.insert("fontSize") }
      ref.overrides = keys.sorted(); result.textStyle = ref
    }
    if var ref = after.paragraphStyle, ref == before.paragraphStyle {
      var keys = Set(ref.overrides)
      for p in properties where paragraphProperties.contains(p.name)
        && p.differs(after.typography, before.typography) { keys.insert(p.name) }
      ref.overrides = keys.sorted(); result.paragraphStyle = ref
    }
    return result
  }
  private static func formatted(_ span: TextSpan, style: ArtworkTextStyle,
    reset: Bool = false) -> TextSpan {
    var result = span
    var ref = reset ? TextStyleReference(styleID: style.id) : span.textStyle ?? .init(styleID: style.id)
    ref.styleID = style.id
    let overrides = Set(ref.overrides)
    for p in properties where !overrides.contains(p.name)
      && (ref.characterOnly != true || !paragraphProperties.contains(p.name)) { p.copy(&result.typography, style.typography) }
    if !overrides.contains("fontSize") { result.fontSize = style.fontSize }
    result.textStyle = ref
    return result
  }
  public static func span(_ element: ArtworkElement) -> TextSpan {
    var value = TextSpan(location: 0, length: element.text.utf16.count,
      typography: element.typography ?? .init(), fontSize: element.fontSize, color: element.color)
    value.swatchID = element.fillSwatchID
    value.paintStack = element.paintStack
    value.textStyle = element.textStyle
    value.paragraphStyle = element.paragraphStyle
    return value
  }
  public static let paragraphProperties: Set<String> = ["leading", "alignment", "paragraphBefore", "paragraphAfter",
    "leftIndent", "rightIndent", "firstLineIndent", "direction", "hyphenation", "tabStops", "defaultTabInterval", "hyphenationLimits", "alignToBaselineGrid"]
  private static func paragraphReference(_ value: TextSpan) -> TextStyleReference? {
    if let ref = value.paragraphStyle { return ref }
    guard var ref = value.textStyle, ref.characterOnly != true else { return nil }
    ref.overrides = ref.overrides.filter { paragraphProperties.contains($0) }
    ref.characterOnly = nil
    return ref
  }
  public static func paragraphMatches(_ value: Typography, style: Typography, overrides: [String]) -> Bool {
    properties.allSatisfy { !paragraphProperties.contains($0.name) || overrides.contains($0.name) || !$0.differs(value, style) }
  }
  public static func changesParagraphs(_ before: Typography, _ after: Typography) -> Bool {
    properties.contains { paragraphProperties.contains($0.name) && $0.differs(before, after) }
  }
  public static func applying(_ value: TextSpan, style: ArtworkTextStyle?, detach: Bool = false,
    preservingParagraphs: Bool = false) -> TextSpan {
    var result = value
    if detach {
      result.paragraphStyle = preservingParagraphs ? paragraphReference(value) : nil
      result.textStyle = nil; return result
    }
    guard let style else { return value }
    result = formatted(value, style: style, reset: true)
    if preservingParagraphs {
      result.paragraphStyle = paragraphReference(value)
      result.textStyle?.characterOnly = true
      for p in properties where paragraphProperties.contains(p.name) {
        p.copy(&result.typography, value.typography)
      }
    } else { result.paragraphStyle = nil }
    return result
  }
  public static func resetting(_ value: TextSpan, styles: [UUID: ArtworkTextStyle],
    styleID: UUID? = nil, preservingParagraphs: Bool = false) -> TextSpan {
    var result = value
    if let ref = value.textStyle, styleID == nil || ref.styleID == styleID,
      let style = styles[ref.styleID] {
      result = applying(value, style: style,
        preservingParagraphs: preservingParagraphs || ref.characterOnly == true)
    }
    if var ref = result.paragraphStyle, styleID == nil || ref.styleID == styleID,
      let style = styles[ref.styleID] {
      for p in properties where paragraphProperties.contains(p.name) { p.copy(&result.typography, style.typography) }
      ref.overrides = []; result.paragraphStyle = ref
    }
    return result
  }
  public static func inheritsCorrectly(_ value: TextSpan, style: ArtworkTextStyle) -> Bool {
    let overrides = Set(value.textStyle?.overrides ?? [])
    return (overrides.contains("fontSize") || value.fontSize == style.fontSize)
      && properties.allSatisfy { overrides.contains($0.name)
        || (value.textStyle?.characterOnly == true && paragraphProperties.contains($0.name))
        || !$0.differs(value.typography, style.typography) }
  }
  public static func inheritedDifferences(_ value: TextSpan, style: ArtworkTextStyle) -> [String] {
    let overrides = Set(value.textStyle?.overrides ?? [])
    return properties.filter { !overrides.contains($0.name)
      && (value.textStyle?.characterOnly != true || !paragraphProperties.contains($0.name))
      && $0.differs(value.typography, style.typography) }.map(\.name)
      + ((!overrides.contains("fontSize") && value.fontSize != style.fontSize) ? ["fontSize"] : [])
  }
  private static func set(_ value: TextSpan, on element: inout ArtworkElement) {
    element.typography = value.typography
    element.fontSize = value.fontSize
    element.textStyle = value.textStyle
    element.paragraphStyle = value.paragraphStyle
  }
  private static func refreshed(_ source:ArtworkElement,style:ArtworkTextStyle)->ArtworkElement {
    var e=source
    if e.textStyle?.styleID==style.id {set(formatted(span(e),style:style),on:&e)}
    if e.paragraphStyle?.styleID==style.id {
      var type=e.typography ?? .init()
      for p in properties where paragraphProperties.contains(p.name) && !e.paragraphStyle!.overrides.contains(p.name) {p.copy(&type,style.typography)}
      e.typography=type
    }
    for r in e.textRuns?.indices ?? 0..<0 where e.textRuns?[r].textStyle?.styleID==style.id {
      e.textRuns![r]=formatted(e.textRuns![r],style:style)
    }
    for r in e.textRuns?.indices ?? 0..<0 where e.textRuns?[r].paragraphStyle?.styleID==style.id {
      var run=e.textRuns![r]
      for p in properties where paragraphProperties.contains(p.name) && !run.paragraphStyle!.overrides.contains(p.name) {p.copy(&run.typography,style.typography)}
      e.textRuns![r]=run
    }
    return e
  }
  @discardableResult public static func save(in project: inout Project, id: UUID? = nil,
    name: String, typography: Typography, fontSize: Double) throws -> UUID {
    var candidate = project
    var values = candidate.textStyles ?? []
    let index: Int
    if let id {
      guard let found = values.firstIndex(where: { $0.id == id }) else { throw FormError.missing("Text style not found.") }
      index = found
    } else {
      values.append(.init(name: name)); index = values.count - 1
    }
    var normalized = typography
    normalized.pairKerning = [:]; normalized.frameMode = "area"; normalized.verticalAlignment = "top"
    values[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    values[index].typography = normalized; values[index].fontSize = fontSize
    candidate.textStyles = values
    let style = values[index]
    // Materialize only inherited properties. Unused sources and physical
    // consumers keep their immutable object files; renderers see ordinary text.
    for i in candidate.objects.indices {
      candidate.objects[i].updateStoredArtworks{art in
        for j in art.elements.indices {art.elements[j]=refreshed(art.elements[j],style:style)}
      }
    }
    for i in candidate.textStories?.indices ?? 0..<0 {
      let changed=refreshed(candidate.textStories![i].sourceElement,style:style)
      candidate.textStories![i].setSource(changed)
    }
    try candidate.validateArtworkLinks()
    project = candidate
    return style.id
  }

  public static func delete(in project: inout Project, id: UUID) throws {
    guard project.textStyles?.contains(where: { $0.id == id }) == true else { throw FormError.missing("Text style not found.") }
    var candidate = project
    for i in candidate.objects.indices {
      candidate.objects[i].updateStoredArtworks{art in
        for j in art.elements.indices {
        if art.elements[j].textStyle?.styleID == id { art.elements[j].textStyle = nil }
        if art.elements[j].paragraphStyle?.styleID == id { art.elements[j].paragraphStyle = nil }
        for r in art.elements[j].textRuns?.indices ?? 0..<0 where art.elements[j].textRuns?[r].textStyle?.styleID == id {
          art.elements[j].textRuns?[r].textStyle = nil
        }
        for r in art.elements[j].textRuns?.indices ?? 0..<0 where art.elements[j].textRuns?[r].paragraphStyle?.styleID == id {
          art.elements[j].textRuns?[r].paragraphStyle = nil
        }
        }
      }
    }
    candidate.textStyles?.removeAll { $0.id == id }
    for i in candidate.textStories?.indices ?? 0..<0 {
      var e=candidate.textStories![i].sourceElement
      if e.textStyle?.styleID==id {e.textStyle=nil}
      if e.paragraphStyle?.styleID==id {e.paragraphStyle=nil}
      for j in e.textRuns?.indices ?? 0..<0 {
        if e.textRuns![j].textStyle?.styleID==id {e.textRuns![j].textStyle=nil}
        if e.textRuns![j].paragraphStyle?.styleID==id {e.textRuns![j].paragraphStyle=nil}
      }
      candidate.textStories![i].setSource(e)
    }
    try candidate.validateArtworkLinks()
    project = candidate
  }

  public static func apply(in project: inout Project, objectID: UUID, ids: Set<UUID>,
    styleID: UUID? = nil, mode: String = "assign", location: Int? = nil, length: Int? = nil) throws {
    guard ["assign", "reset", "detach"].contains(mode), let object = project.objects.first(where: { $0.id == objectID }),
      !project.artworkOwner(object).locked, var art = project.editableArtwork(object), !ids.isEmpty,
      ids.isSubset(of: Set(art.elements.map(\.id))) else { throw FormError.invalid("Choose unlocked text artwork.") }
    let targets = art.swatchPaintTargets(for: ids)
    let texts = art.elements.filter { targets.contains($0.id) && $0.kind == "text" }
    let textIDs = Set(texts.map(\.id))
    guard !texts.isEmpty, texts.allSatisfy({ !art.isLocked($0) }),
      (location == nil) == (length == nil), location == nil || texts.count == 1 else {
      throw FormError.invalid("Choose text layers; a character range needs one text object.")
    }
    let styles = Dictionary(uniqueKeysWithValues: (project.textStyles ?? []).map { ($0.id, $0) })
    if mode == "assign", styleID.flatMap({ styles[$0] }) == nil { throw FormError.missing("Text style not found.") }
    func edit(_ span: TextSpan, preservingParagraphs: Bool = false) throws -> TextSpan {
      if mode == "detach" { return applying(span, style: nil, detach: true, preservingParagraphs: preservingParagraphs) }
      if mode == "reset" { return resetting(span, styles: styles, styleID: styleID, preservingParagraphs: preservingParagraphs) }
      let id = mode == "assign" ? styleID : span.textStyle?.styleID
      guard let id, let style = styles[id] else { return span }
      return applying(span, style: style, preservingParagraphs: preservingParagraphs || (mode == "reset" && span.textStyle?.characterOnly == true))
    }
    var candidate=project,changedStories=Set<UUID>()
    for i in art.elements.indices where textIDs.contains(art.elements[i].id) {
      let story=art.elements[i].storyFrame?.storyID
      if let story,!changedStories.insert(story).inserted {continue}
      let storyIndex=story.flatMap{id in candidate.textStories?.firstIndex{$0.id==id}}
      if let storyIndex {try PublicationCommands.ensureEditable(candidate.textStories![storyIndex],in:candidate)}
      var e=storyIndex.map{candidate.textStories![$0].sourceElement} ?? art.elements[i]
      if let location, let length {
        let partial = location != 0 || length != e.text.utf16.count
        try editRange(&e, location: location, length: length) { try edit($0, preservingParagraphs: partial) }
      } else {
        set(try edit(span(e)), on: &e)
        for r in e.textRuns?.indices ?? 0..<0 {
          let run = e.textRuns![r]
          e.textRuns?[r] = try edit(run)
        }
      }
      if let storyIndex {candidate.textStories![storyIndex].setSource(e)}else{art.elements[i]=e}
    }
    try candidate.setArtwork(art, for: objectID, recordingStyleOverrides: false)
    try candidate.validateArtworkLinks()
    project = candidate
  }

  private static func editRange(_ element: inout ArtworkElement, location: Int, length: Int,
    _ edit: (TextSpan) throws -> TextSpan) throws {
    let count = element.text.utf16.count
    let utf16 = element.text as NSString
    func boundary(_ offset: Int) -> Bool {
      if offset == 0 || offset == count { return true }
      return !(0xD800...0xDBFF).contains(utf16.character(at: offset-1))
        || !(0xDC00...0xDFFF).contains(utf16.character(at: offset))
    }
    guard location >= 0, length > 0, location <= count, length <= count-location,
      boundary(location), boundary(location+length),
      Range(NSRange(location: location, length: length), in: element.text) != nil else {
      throw FormError.invalid("Choose a nonempty UTF-16 range at character boundaries.")
    }
    let old = element.textRuns ?? []
    let boundaries = Set([0, count, location, location+length] + old.flatMap { [$0.location, $0.location+$0.length] }).sorted()
    element.textRuns = try zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
      guard end > start else { return nil }
      var run = old.first { $0.location <= start && $0.location+$0.length >= end } ?? span(element)
      run.location = start; run.length = end-start
      return start >= location && end <= location+length ? try edit(run) : run
    }
  }
}

extension Artwork {
  public var referencedTextStyles: Set<UUID> {
    Set(elements.flatMap { e in [e.textStyle?.styleID, e.paragraphStyle?.styleID].compactMap { $0 }
      + (e.textRuns ?? []).flatMap { [$0.textStyle?.styleID, $0.paragraphStyle?.styleID].compactMap { $0 } } })
  }
  public func recordingTextStyleOverrides(from previous: Artwork?) -> Artwork {
    guard let previous, !referencedTextStyles.isEmpty else { return self }
    let old = Dictionary(uniqueKeysWithValues: previous.elements.map { ($0.id, $0) })
    var result = self
    for i in result.elements.indices {
      guard let before = old[result.elements[i].id] else { continue }
      var e = result.elements[i]
      let recorded = TextStyleCommands.recording(TextStyleCommands.span(e), from: TextStyleCommands.span(before))
      e.textStyle = recorded.textStyle
      e.paragraphStyle = recorded.paragraphStyle
      for r in e.textRuns?.indices ?? 0..<0 {
        let run = e.textRuns![r]
        let base = before.textRuns?.first { $0.location <= run.location && $0.location+$0.length > run.location }
          ?? TextStyleCommands.span(before)
        e.textRuns?[r] = TextStyleCommands.recording(run, from: base)
      }
      result.elements[i] = e
    }
    return result
  }
}

extension Project {
  public func validateTextStyles() throws {
    let styles = textStyles ?? []
    let ids = Set(styles.map(\.id))
    guard styles.count <= 256, ids.count == styles.count,
      Set(styles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == styles.count else {
      throw FormError.invalid("Use up to 256 text styles with unique IDs and names.")
    }
    for style in styles {
      guard !style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        style.name.count <= 100, style.fontSize.isFinite, (0.1...10000).contains(style.fontSize) else {
        throw FormError.invalid("Use a style name of 1–100 characters and valid point size.")
      }
      try validateTypography(style.typography)
    }
    let artworks=storedArtworks+(textStories ?? []).map{Artwork(elements:[$0.sourceElement])}
    for art in artworks {
      guard art.referencedTextStyles.isSubset(of: ids) else { throw FormError.invalid("Artwork references a missing text style.") }
      let byID = Dictionary(uniqueKeysWithValues: styles.map { ($0.id, $0) })
      for e in art.elements {
        let references = [e.textStyle, e.paragraphStyle].compactMap { $0 }
          + (e.textRuns ?? []).flatMap { [$0.textStyle, $0.paragraphStyle].compactMap { $0 } }
        guard (references.isEmpty || e.kind == "text"), references.allSatisfy({
          Set($0.overrides).count == $0.overrides.count && Set($0.overrides).isSubset(of: TextStyleCommands.propertyNames)
        }) else { throw FormError.invalid("Text style references need text and valid unique override properties.") }
        for value in [TextStyleCommands.span(e)] + (e.textRuns ?? []) {
          if let ref = value.textStyle, let style = byID[ref.styleID],
            !TextStyleCommands.inheritsCorrectly(value, style: style) {
            let fields = TextStyleCommands.inheritedDifferences(value, style: style).joined(separator: ", ")
            throw FormError.invalid("Text differs from \(style.name) in \(fields). Reset the style or record local overrides.")
          }
          if let ref = value.paragraphStyle, let style = byID[ref.styleID],
            !TextStyleCommands.paragraphMatches(value.typography, style: style.typography, overrides: ref.overrides) {
            throw FormError.invalid("Paragraph formatting must match its style or retain local overrides.")
          }
        }
      }
    }
  }
}

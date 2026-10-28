import Foundation

public enum ClockDesign {
  public static func boundary(diameter: Double, bore: Double) -> VectorPath {
    let k = 0.5522847498307936
    let c = diameter / 2
    func circle(_ radius: Double) -> VectorContour {
      .init(
        [
          .init(
            .init(c, c - radius), incoming: .init(c - k * radius, c - radius),
            outgoing: .init(c + k * radius, c - radius)),
          .init(
            .init(c + radius, c), incoming: .init(c + radius, c - k * radius),
            outgoing: .init(c + radius, c + k * radius)),
          .init(
            .init(c, c + radius), incoming: .init(c + k * radius, c + radius),
            outgoing: .init(c - k * radius, c + radius)),
          .init(
            .init(c - radius, c), incoming: .init(c - radius, c + k * radius),
            outgoing: .init(c - radius, c - k * radius)),
        ], closed: true)
    }
    var result = VectorPath(
      width: diameter, height: diameter, contours: [circle(c), circle(bore / 2)], evenOdd: true)
    for n in 0..<8 {
      result.contours[n / 4].nodes[n % 4].id = UUID(
        uuidString: String(format: "00000000-0000-C10C-0000-%012d", n + 1))!
    }
    return result
  }
  public static func dial(diameter d: Double = 240, ink: String = "#28312D") -> Artwork {
    var art = Artwork(background: "#F1EBDD")
    art.unit = .mm
    var numerals = ArtworkElement(kind: "group", x: 0, y: 0, width: d, height: d)
    numerals.name = "Hour numerals"
    numerals.contentSize = .init(d, d)
    var marks = ArtworkElement(kind: "group", x: 0, y: 0, width: d, height: d)
    marks.name = "Minute indices"
    marks.contentSize = .init(d, d)
    art.elements = [marks, numerals]
    for minute in 0..<60 {
      let angle = Double(minute) * 6
      let major = minute % 5 == 0
      var mark = ArtworkElement(
        kind: "rectangle", x: d / 2 - (major ? 0.55 : 0.2), y: d * 0.055,
        width: major ? 1.1 : 0.4, height: major ? d * 0.025 : d * 0.012, color: ink)
      mark.name = String(format: "Index %02d", minute)
      mark.parentID = marks.id
      mark.affine = .translation(d / 2, d / 2).followed(by: .rotation(angle)).followed(
        by: .translation(-d / 2, -d / 2))
      art.elements.append(mark)
    }
    for hour in 1...12 {
      let angle = Double(hour) * .pi / 6
      let x = d / 2 + sin(angle) * d * 0.343
      let y = d / 2 - cos(angle) * d * 0.343
      var text = ArtworkElement(
        kind: "text", x: x - d * 0.075, y: y - d * 0.062, width: d * 0.15, height: d * 0.124,
        text: String(hour), color: ink, fontSize: d * 0.109)
      text.name = "Hour \(hour)"
      text.parentID = numerals.id
      var type = Typography()
      type.fontName = "Georgia"
      type.alignment = "center"
      type.verticalAlignment = "middle"
      type.tracking = -0.5
      text.typography = type
      art.elements.append(text)
    }
    var wordmark = ArtworkElement(
      kind: "text", x: d * 0.25, y: d * 0.275, width: d * 0.5, height: d * 0.07,
      text: "FORM", color: ink, fontSize: d * 0.053)
    wordmark.name = "Dial signature"
    var style = Typography()
    style.fontName = "HelveticaNeue-Medium"
    style.alignment = "center"
    style.tracking = 3.2
    wordmark.typography = style
    art.elements.append(wordmark)
    var detail = ArtworkElement(
      kind: "text", x: d * 0.2, y: d * 0.645, width: d * 0.6, height: d * 0.05,
      text: "TIME, WELL SPENT.", color: ink, fontSize: d * 0.023)
    detail.name = "Maker's line"
    style.tracking = 1.1
    detail.typography = style
    art.elements.append(detail)
    return art
  }
  public static func source(for clock: ProductObject, in project: Project) throws -> ProductObject {
    let d = clock["diameter"]
    var source = try project.makeObject(
      recipeID: "artboard", name: clock.name + " · Dial artwork",
      parameters: ["width": d, "depth": d], materialID: "chalk",
      position: .init(clock.position.x + d + 65, 0, clock.position.z))
    source.artwork = dial(diameter: d)
    return source
  }
  public static func profileSVG(_ clock: ProductObject) -> String {
    let d = clock["diameter"]
    let r = d / 2
    let b = clock["bore"] / 2
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <svg xmlns="http://www.w3.org/2000/svg" width="\(d)mm" height="\(d)mm" viewBox="0 0 \(d) \(d)">
      <title>Clock dial · cut profile</title><desc>Millimeter scale. Outer dial and shaft opening. Thickness \(clock["thickness"]) mm. Verify physical fit before fabrication.</desc>
      <g fill="none" stroke="#C65E3D" stroke-width="0.2"><circle cx="\(r)" cy="\(r)" r="\(r)"/><circle cx="\(r)" cy="\(r)" r="\(b)"/></g></svg>
      """
  }
}

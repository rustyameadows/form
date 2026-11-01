import CoreGraphics
import CryptoKit
import FormCore
import Foundation
import ImageIO

extension FigmaSceneBuilder {
  func color(_ value: FigmaValue?) throws -> (String, Double) {
    let converted = try FigmaColor.convert(value,profile:currentColorProfile)
    return (converted.hex,converted.alpha)
  }
  func blend(_ value: FigmaValue?, id: String) -> String? {
    if value != nil,value?.stringValue == nil {issue(id,"blend","Unknown numeric blend mode.",severity:"error");return nil}
    let name = value?.stringValue ?? "NORMAL"
    if name == "PASS_THROUGH" { return nil }
    let mode = name == "LUMINOSITY" ? "luminosity" : name.lowercased().replacingOccurrences(of: "_", with: "-")
    guard AppearanceCommands.blendModes.contains(mode) else {
      issue(id, "blend", "Unsupported blend mode \(name).", severity: "error"); return nil
    }
    return mode
  }
  func paint(_ value: FigmaValue, on original: ArtworkElement, id: String) throws -> [ArtworkElement] {
    var e = original; e.id = UUID(); e.stroke = nil; e.fillEnabled = true
    let opacity = try number(value["opacity"], 1)
    guard (0...1).contains(opacity) else { throw FigmaClipboardError.invalid("Paint opacity is outside 0–1.") }
    e.fillOpacity = opacity; e.blendMode = blend(value["blendMode"], id: id)
    if value["type"] != nil,value["type"]?.stringValue == nil {
      issue(id,"paint","Unknown numeric paint type.",severity:"error");e.fillEnabled=false;return [e]
    }
    switch value["type"]?.stringValue ?? "SOLID" {
    case "SOLID":
      let (hex, alpha) = try color(value["color"]); e.color = hex; e.fillOpacity = opacity * alpha
    case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
      let raw = value["stops"]?.arrayValue ?? []
      guard raw.count >= 2, raw.count <= 256 else { throw FigmaClipboardError.invalid("Gradient requires 2–256 stops.") }
      var stops: [GradientStop] = []
      for stop in raw {
        let offset = try number(stop["position"]), (hex, alpha) = try color(stop["color"])
        guard (0...1).contains(offset) else { throw FigmaClipboardError.invalid("Gradient stop is outside 0–1.") }
        var native = GradientStop(offset, hex); native.opacity = alpha; stops.append(native)
      }
      stops = stops.enumerated().sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }.map(\.element)
      let t = try matrix(value["transform"])
      guard let inverse = t.inverse else { throw FigmaClipboardError.invalid("Gradient transform is singular.") }
      let kind=["GRADIENT_LINEAR":"linear","GRADIENT_RADIAL":"radial","GRADIENT_ANGULAR":"angular","GRADIENT_DIAMOND":"diamond"][value["type"]?.stringValue ?? ""] ?? "linear"
      let radial = kind != "linear"
      var gradient = ArtworkGradient(kind: kind,
        start: .init(radial ? 0.5 : 0, 0.5), end: .init(1, 0.5), stops: stops)
      // Native radial gradients begin as circles. Normalize both native axes
      // by the width, then map the unit gradient through Figma's inverse map.
      if radial {
        gradient.start = .init(0.5, 0.5 * e.width / e.height)
        gradient.end = .init(1, 0.5 * e.width / e.height)
        gradient.transform = Affine2.scale(e.width, e.height).followed(by: inverse)
          .followed(by: .scale(1/e.width, 1/e.width))
      } else {
        gradient.transform = Affine2.scale(e.width, e.height).followed(by: inverse)
          .followed(by: .scale(1/e.width, 1/e.height))
      }
      e.gradient = gradient
    case "IMAGE": return try imagePaint(value, geometry: e, id: id)
    default:
      issue(id, "paint", "The \(value["type"]?.stringValue ?? "unknown") paint has no native editable mapping yet.", severity: "error")
      e.fillEnabled = false
    }
    if value["colorVar"] != nil {
      issue(id, "variables", "The resolved paint color is editable; its variable binding is retained as source metadata.", severity: "info")
    }
    return [e]
  }

  func stroke(_ paints: [FigmaValue], node: FigmaValue, geometry: ArtworkElement, id: String) throws -> [ArtworkElement] {
    let weight = try number(node["strokeWeight"], 1) * scale
    guard weight >= 0, weight <= 100 else { throw FigmaClipboardError.invalid("Stroke width is outside native limits.") }
    var result: [ArtworkElement] = []
    for paint in paints where paint["visible"]?.boolValue != false {
      guard paint["type"]?.stringValue == "SOLID" || paint["type"] == nil else {
        let outlines = try vectorShapes(node, id: id, geometry: "strokeGeometry")
        if outlines.isEmpty {
          var inkNode=node.objectValue ?? [:]
          inkNode["fillPaints"] = .array([]);inkNode["strokePaints"] = .array([paint])
          var e=geometry;e.id=UUID();e.fillEnabled=false;e.gradient=nil;e.stroke=nil;e.blendMode=nil
          e.paintStack=try textPaintStack(.object(inkNode),width:e.width,height:e.height,id:id)
          result.append(e)
        }
        for outline in outlines {
          var e = geometry; e.kind = "path"; e.path = .init(width: e.width, height: e.height, contours: outline.contours, evenOdd: outline.evenOdd)
          result += try self.paint(paint, on: e, id: id)
        }
        if !outlines.isEmpty { issue(id, "stroke", "Painted stroke outlines remain editable paths.", severity: "info") }
        continue
      }
      var e = geometry; e.id = UUID(); e.fillEnabled = false; e.gradient = nil
      let (hex, alpha) = try color(paint["color"])
      var stroke = ArtworkStroke(color: hex, width: weight)
      stroke.opacity = alpha * (try number(paint["opacity"], 1))
      stroke.alignment = (node["strokeAlign"]?.stringValue ?? "CENTER").lowercased()
      stroke.cap = ["ROUND":"round", "SQUARE":"square", "NONE":"butt"][node["strokeCap"]?.stringValue ?? "NONE"]
      stroke.join = (node["strokeJoin"]?.stringValue ?? "MITER").lowercased()
      stroke.miter = try number(node["miterLimit"], 4)
      if let dashes = node["dashPattern"]?.arrayValue, !dashes.isEmpty { stroke.dash = try dashes.map { try number($0) * scale } }
      e.stroke = stroke; e.blendMode = blend(paint["blendMode"], id: id); result.append(e)
      if stroke.cap == nil { issue(id, "stroke", "Decorative stroke caps need supplied outline geometry.", severity: "error") }
    }
    if node["borderStrokeWeightsIndependent"]?.boolValue == true {
      issue(id, "stroke", "Independent side stroke widths are not mapped by this stroke representation.", severity: "error")
    }
    return result
  }

}

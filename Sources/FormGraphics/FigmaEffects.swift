import FormCore
import Foundation

extension FigmaSceneBuilder {
  func effects(_ node: FigmaValue, on element: inout ArtworkElement, id: String) throws {
    let values = node["effects"]?.arrayValue ?? []
    guard values.count <= 16 else { throw FigmaClipboardError.limit("16 effects per layer") }
    var effects: [ArtworkEffect] = []
    let nodeType = node["type"]?.stringValue ?? "UNKNOWN"
    let unspread = ["TEXT", "BOOLEAN_OPERATION", "STAR", "REGULAR_POLYGON", "POLYGON", "VECTOR"].contains(nodeType)
    let container = ["FRAME", "GROUP", "SECTION", "SYMBOL", "INSTANCE"].contains(nodeType)
    let clips = container && nodeType != "GROUP" && node["frameMaskDisabled"]?.boolValue == false && node["resizeToFit"]?.boolValue != true
    let fallback:FigmaValue?=node["backgroundColor"].map { color in
      .array([.object(["type":.string("SOLID"),"color":color,"opacity":node["backgroundOpacity"] ?? .double(1)])])
    }
    let fills = node["fillPaints"] ?? node["backgroundPaints"] ?? fallback
    let hasFill = (fills?.arrayValue ?? []).contains { paint in
      guard paint["visible"]?.boolValue != false, (paint["opacity"]?.numberValue ?? 1) > 0 else { return false }
      if let stops = paint["stops"]?.arrayValue { return stops.contains { ($0["color"]?["a"]?.numberValue ?? 1) > 0 } }
      return (paint["color"]?["a"]?.numberValue ?? 1) > 0
    }
    for effect in values where effect["visible"]?.boolValue != false {
      let kind = effect["type"]?.stringValue ?? "UNKNOWN"
      let radius = try number(effect["radius"])
      guard radius >= 0 else { throw FigmaClipboardError.invalid("Effect radius must be nonnegative.") }
      switch kind {
      case "FOREGROUND_BLUR", "LAYER_BLUR":
        guard effect["blurOpType"] == nil || effect["blurOpType"]?.stringValue == "NORMAL" else {
          issue(id,"effects","Progressive or unknown layer blur has no calibrated native mapping.",severity:"error");continue
        }
        guard !effects.contains(where: { $0.kind == "blur" }) else {
          issue(id,"effects","Multiple layer blurs require an explicit source ordering policy.",severity:"error");continue
        }
        effects.append(.init(kind:"blur",blur:radius * 0.43 * scale))
      case "DROP_SHADOW", "INNER_SHADOW":
        let (hex, alpha) = try color(effect["color"])
        let offset = Point2(try number(effect["offset"]?["x"]) * scale, try number(effect["offset"]?["y"]) * scale)
        let sourceSpread = try number(effect["spread"]) * scale
        let spread = unspread || (kind == "DROP_SHADOW" && container && !(clips && hasFill)) ? 0 : sourceSpread
        if spread != 0, !supportsAnalyticSpread(node,inner:kind == "INNER_SHADOW") {
          issue(id,"effects","Nonzero spread on this curved, compound or container shadow needs additional outline semantics.",severity:"error")
        }
        effects.append(.init(kind:kind == "DROP_SHADOW" ? "drop-shadow":"inner-shadow",offset:offset,
          blur:radius * 0.43 * scale,spread:spread,color:hex,opacity:alpha,
          blendMode:blend(effect["blendMode"],id:id),knockout:kind == "DROP_SHADOW" && effect["showShadowBehindNode"]?.boolValue == false))
      default:
        issue(id,"effects","The \(kind) effect has no calibrated native mapping.",severity:"error")
      }
    }
    if !effects.isEmpty {
      let stack = ArtworkEffectStack(coverage:"paint-outline",effects:effects)
      try stack.validate(); element.effectStack = stack; element.blur = nil; element.shadow = nil
    }
  }
  private func supportsAnalyticSpread(_ node:FigmaValue,inner:Bool)->Bool {
    let type=node["type"]?.stringValue ?? "UNKNOWN"
    let cornerKeys=["cornerRadius","rectangleTopLeftCornerRadius","rectangleTopRightCornerRadius","rectangleBottomRightCornerRadius","rectangleBottomLeftCornerRadius"]
    let curved=type=="ELLIPSE" || cornerKeys.contains{(node[$0]?.numberValue ?? 0)>0}
    let container=["FRAME","GROUP","SECTION","SYMBOL","INSTANCE"].contains(type)
    // Uncurved drop silhouettes use the same rectangular morphology as the
    // reference. Inner container spread depends on child-shape isolation.
    if !curved {return !(container && inner)}
    guard !container, ["RECTANGLE","ROUNDED_RECTANGLE","ELLIPSE"].contains(type),
      node["fillGeometry"]?.arrayValue?.isEmpty != false,
      (node["cornerSmoothing"]?.numberValue ?? 0)==0 else{return false}
    let fills=(node["fillPaints"]?.arrayValue ?? []).filter{$0["visible"]?.boolValue != false && ($0["opacity"]?.numberValue ?? 1)>0}
    let strokes=(node["strokePaints"]?.arrayValue ?? []).filter{$0["visible"]?.boolValue != false && ($0["opacity"]?.numberValue ?? 1)>0}
    guard fills.count<=1,strokes.count<=1,
      fills.allSatisfy({$0["type"]?.stringValue != "IMAGE" && ($0["blendMode"]==nil || $0["blendMode"]?.stringValue=="NORMAL")}),
      strokes.allSatisfy({($0["type"]==nil || $0["type"]?.stringValue=="SOLID") && ($0["blendMode"]==nil || $0["blendMode"]?.stringValue=="NORMAL")}),
      node["dashPattern"]?.arrayValue?.isEmpty != false else{return false}
    let corners=cornerKeys.dropFirst().map{node[$0]?.numberValue ?? node["cornerRadius"]?.numberValue ?? 0}
    guard corners.allSatisfy({$0==corners[0]}) else{return false}
    if let arc=node["arcData"], (arc["innerRadius"]?.numberValue ?? 0)>0 || abs((arc["endingAngle"]?.numberValue ?? 2 * .pi)-(arc["startingAngle"]?.numberValue ?? 0))<2 * .pi-1e-6 {
      // Partial arcs use the general silhouette fallback in the reference;
      // drop spread is rectangular morphology and inner spread is not applied.
      return !inner
    }
    return !inner || (!fills.isEmpty && (strokes.isEmpty || node["strokeAlign"]?.stringValue=="INSIDE"))
  }
}

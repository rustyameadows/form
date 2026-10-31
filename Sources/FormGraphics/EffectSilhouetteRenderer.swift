import CoreGraphics
import FormCore

/// Transient geometric ink for shadows. These proxies are never written back
/// to a project: editable paints, image assets and live text remain untouched.
public enum EffectSilhouetteRenderer {
  /// Regular boxes and ellipses grow as boxes and ellipses, rather than using
  /// square raster morphology at their curved edges. Nil selects the general
  /// silhouette path; an empty path means erosion consumed the entire shape.
  public static func spreadPath(_ element: ArtworkElement, spread: Double, inner: Bool) -> CGPath? {
    guard spread.isFinite, ["rectangle","ellipse"].contains(element.kind),
      let proxy = self.element(element,knockout:false) else { return nil }
    let strokes: [ArtworkStroke]
    let fills: Bool
    if let stack=proxy.paintStack {
      strokes=stack.compactMap(\.stroke);fills=stack.contains(where:{$0.stroke==nil})
    } else {strokes=proxy.stroke.map{[$0]} ?? [];fills=proxy.fillEnabled != false}
    guard strokes.count<=1 else{return nil}
    let stroke=strokes.first
    let alignment=stroke?.alignment ?? "center",weight=stroke?.width ?? 0
    let outward=alignment == "inside" ? 0 : weight * (alignment == "outside" ? 1:0.5)
    let inward=weight-outward
    if inner {
      guard fills,outward==0 else{return nil}
      return shape(element,grow:-spread)
    }
    guard stroke?.dash?.isEmpty != false,
      element.kind == "ellipse" || (element.cornerRadius ?? 0)>0 || stroke==nil || (stroke?.join ?? "miter")=="miter" else{return nil}
    let outer=shape(element,grow:outward+spread)
    if fills{return outer}
    guard stroke != nil else{return CGMutablePath()}
    return outer.subtracting(shape(element,grow:-inward-spread))
  }
  private static func shape(_ element:ArtworkElement,grow:Double)->CGPath {
    let width=element.width+2*grow,height=element.height+2*grow
    guard width>0,height>0 else{return CGMutablePath()}
    let bounds=CGRect(x:-grow,y:-grow,width:width,height:height)
    if element.kind=="ellipse" {return CGPath(ellipseIn:bounds,transform:nil)}
    let original=element.cornerRadius ?? 0
    let radius=original>0 ? min(max(0,original+grow),width/2,height/2):0
    return CGPath(roundedRect:bounds,cornerWidth:radius,cornerHeight:radius,transform:nil)
  }
  public static func element(_ element: ArtworkElement, knockout: Bool) -> ArtworkElement? {
    guard element.hidden != true, (element.opacity ?? 1) > 0, element.kind != "group" else { return nil }
    var proxy = element
    proxy.opacity = nil; proxy.blendMode = nil; proxy.blur = nil; proxy.shadow = nil; proxy.effectStack = nil
    proxy.isolatedBlending = nil; proxy.fillSwatchID = nil
    if element.kind == "image" {
      proxy.kind = "rectangle"; proxy.asset = nil; proxy.imageCrop = nil; proxy.imageAdjustments = nil
      proxy.fillEnabled = true; proxy.fillOpacity = 1; proxy.color = "#FFFFFF"; proxy.paintStack = nil
      proxy.gradient = nil; proxy.stroke = nil
      return proxy
    }
    let castsFill = element.fillEnabled != false && (element.fillOpacity ?? 1) > 0
      && (element.gradient?.stops.contains { ($0.opacity ?? 1) > 0 } ?? true)
    proxy.fillEnabled = (castsFill || knockout) && element.kind != "line"
    proxy.fillOpacity = 1; proxy.color = "#FFFFFF"; proxy.gradient = nil
    if var stroke = element.visibleStroke, (stroke.opacity ?? 1) > 0 {
      stroke.color = "#FFFFFF"; stroke.opacity = 1; stroke.swatchID = nil; proxy.stroke = stroke
    } else { proxy.stroke = nil }
    if let stack = element.paintStack { proxy.paintStack = opaque(stack, knockout: knockout && element.kind != "line") }
    for index in proxy.textRuns?.indices ?? 0..<0 {
      proxy.textRuns![index].color = "#FFFFFF"; proxy.textRuns![index].swatchID = nil
      if let stack = element.textRuns?[index].paintStack { proxy.textRuns![index].paintStack = opaque(stack, knockout: knockout) }
    }
    return proxy
  }
  private static func opaque(_ stack: [ArtworkPaintLayer], knockout: Bool) -> [ArtworkPaintLayer] {
    var result: [ArtworkPaintLayer] = []
    for layer in stack where layer.enabled && layer.effectivePaint.opacity > 0 {
      guard layer.paint.gradient?.stops.contains(where: { ($0.opacity ?? 1) > 0 }) ?? true else { continue }
      var stroke = layer.stroke
      if stroke != nil {
        guard stroke?.enabled != false, (stroke?.width ?? 0) > 0 else { continue }
        stroke!.color = "#FFFFFF"; stroke!.opacity = 1; stroke!.swatchID = nil
      }
      result.append(.init(.init(color: "#FFFFFF"), stroke: stroke))
    }
    if knockout && !result.contains(where: { $0.stroke == nil }) { result.insert(.init(.init(color: "#FFFFFF")), at: 0) }
    return result
  }
}

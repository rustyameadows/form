import Foundation

public enum SewingLayoutDrawing {
  /// Technical paths use stock coordinates directly; exports do not fit, rescale, or add a page
  /// offset to physical placements. Source copy IDs and roll origins therefore remain meaningful.
  public static func artwork(_ report: SewingLayoutPreflight, layout: SewingCutLayout, labels: Bool = true, labelBackplates: Bool = false) throws -> Artwork {
    guard report.workingWidth > 0, report.consumedLength > 0 else { throw FormError.invalid("Configure stock dimensions and place the required pieces before drawing the layout.") }
    var elements: [ArtworkElement] = []
    let w = report.workingWidth, h = report.consumedLength
    elements.append(SewingPatternDrawing.technicalPath([.init(0,0),.init(w,0),.init(w,h),.init(0,h)], closed: true,
      source: layout.id, name: "Usable stock boundary", role: "guide", color: "#929A94"))
    if layout.stock == .foldedPair {
      elements.append(SewingPatternDrawing.technicalPath([.init(0,0),.init(0,h)], closed: false,
        source: layout.id, name: "Material fold", role: "guide", color: "#A67B41", dash: [8,4]))
    }
    for p in report.placements {
      let id = p.placement.id, g = p.geometry
      for (index,cut) in SewingLayoutGeometry.cuttingPaths(p).enumerated() {
        elements.append(SewingPatternDrawing.technicalPath(cut.points,closed:cut.closed,source:id,name:index==0 ? "Cut contour":"Cut hole \(index)",role:"cut",color:"#292D2C"))
      }
      for (index,stitch) in g.allStitchContours.enumerated() {
        elements.append(SewingPatternDrawing.technicalPath(stitch.map(p.transform.apply),closed:true,source:id,name:index==0 ? "Stitch outline":"Stitch hole \(index)",role:"stitch",color:"#43718A",dash:[3,2]))
      }
      let grain = SewingPatternDrawing.grainline(g).map(p.transform.apply)
      elements.append(SewingPatternDrawing.technicalPath(grain, closed: false, source: id, name: "Grainline", role: "guide", color: "#A67B41"))
      let d = p.grainDirection, n = Point2(-d.y,d.x)
      for (index, tip) in grain.enumerated() {
        if layout.grain == .directional && index == 0 { continue }
        let sign = index == 0 ? 1.0 : -1.0, size = min(4, min(p.bounds.width,p.bounds.height)/5)
        let back = Point2(tip.x+sign*d.x*size,tip.y+sign*d.y*size)
        elements.append(SewingPatternDrawing.technicalPath([.init(back.x+n.x*size/2,back.y+n.y*size/2),tip,.init(back.x-n.x*size/2,back.y-n.y*size/2)],
          closed: false, source: id, name: "Grain arrow \(index+1)", role: "guide", color: "#A67B41"))
      }
      if labels, p.bounds.width >= 18, p.bounds.height >= 10 {
        let copies = p.placement.copies.map(String.init).joined(separator: ", ")
        let text = "\(g.piece.name)\nCopy \(copies)\(g.piece.onFoldEdge == nil ? "" : " · ON FOLD")"
        var label = SewingPatternDrawing.annotation(text,x:p.bounds.x+2,y:p.bounds.y+2,width:max(1,min(120,p.bounds.width-4)),height:min(12,p.bounds.height-4),source:id,name:"Cut copy label")
        if labelBackplates {
          let mask = SewingPatternDrawing.technicalCompoundPath(p.materialContours,source:id,name:"Copy label clip",role:"guide",color:"#FFFFFF")
          elements.append(mask)
          var backplate = ArtworkElement(kind:"rectangle",x:label.x,y:label.y,width:label.width,height:label.height,color:"#FFFFFF")
          backplate.id = ComponentCommands.derivedID(label.id,UUID(uuidString:"D83F46BF-D355-47B0-9E73-095F42E4A661")!)
          backplate.name = "Cut copy label background"; backplate.productionRole = "guide"; backplate.fillOpacity = 0.92
          backplate.clipID = mask.id; label.clipID = mask.id; elements.append(backplate)
        }
        elements.append(label)
      }
    }
    var art = Artwork(background: "#FFFFFF", elements: elements, bleed: 0); art.unit = .mm; art.backgroundOpacity = 0
    try validateArtwork(art); return art
  }
}

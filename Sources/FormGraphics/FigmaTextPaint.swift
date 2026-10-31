import FormCore
import Foundation

extension FigmaSceneBuilder {
  /// The same normalized inks serve ordinary shapes and live glyph outlines.
  /// Paint opacity belongs to the ink; node opacity remains on the text layer.
  func textPaintStack(_ node:FigmaValue,width:Double,height:Double,id:String) throws -> [ArtworkPaintLayer] {
    let previous=currentColorProfile
    if let profile=node["colorProfile"]?.stringValue {currentColorProfile=profile}
    defer {currentColorProfile=previous}
    var result:[ArtworkPaintLayer]=[]
    let geometry=ArtworkElement(kind:"rectangle",x:0,y:0,width:width,height:height,color:"#000000")
    func ink(_ value:FigmaValue) throws -> ArtworkPaint? {
      if value["type"]?.stringValue == "IMAGE" {
        return try imagePaintSource(paint:value,width:width,height:height,id:id)
      }
      guard let mapped=try paint(value,on:geometry,id:id).first,mapped.fillEnabled != false else {return nil}
      return .init(kind:mapped.gradient == nil ? "solid":"gradient",color:mapped.color,
        opacity:mapped.fillOpacity ?? 1,blendMode:mapped.blendMode,gradient:mapped.gradient)
    }
    if node["fillPaints"] == nil {result.append(.init(.init(color:"#000000")))}
    for value in node["fillPaints"]?.arrayValue ?? [] where value["visible"]?.boolValue != false {
      if let paint=try ink(value) {result.append(.init(paint))}
    }
    for value in node["strokePaints"]?.arrayValue ?? [] where value["visible"]?.boolValue != false {
      guard let paint=try ink(value) else {continue}
      let weight=try number(node["strokeWeight"],1)*scale
      guard (0...100).contains(weight) else {throw FigmaClipboardError.invalid("Text stroke width is outside native limits.")}
      var stroke=ArtworkStroke(color:paint.color,width:weight)
      stroke.opacity=1
      stroke.alignment=(node["strokeAlign"]?.stringValue ?? "CENTER").lowercased()
      stroke.cap=["ROUND":"round","SQUARE":"square","NONE":"butt"][node["strokeCap"]?.stringValue ?? "NONE"]
      stroke.join=(node["strokeJoin"]?.stringValue ?? "MITER").lowercased()
      stroke.miter=try number(node["miterLimit"],4)
      if let values=node["dashPattern"]?.arrayValue,!values.isEmpty {stroke.dash=try values.map{try number($0)*scale}}
      if stroke.cap == nil {issue(id,"text-stroke","Decorative text stroke caps have no glyph-outline equivalent.",severity:"error")}
      result.append(.init(paint,stroke:stroke))
    }
    return result
  }
}

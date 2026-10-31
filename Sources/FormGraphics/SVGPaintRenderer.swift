import AppKit
import FormCore

/// Export native ink sources through vector coverage without changing the
/// document's editable text or paths. Images retain embedded original bytes.
@MainActor enum SVGPaintRenderer {
  static func layers(_ layers:[(CGPath,ArtworkPaint)],size:CGSize,assets:URL,prefix:String,evenOdd:Bool=false)throws->String {
    func matrix(_ t:Affine2)->String{"matrix(\(t.a) \(t.b) \(t.c) \(t.d) \(t.tx) \(t.ty))"}
    var output=""
    for (index,item) in layers.enumerated() {
      let (path,paint)=item,id="\(prefix)-\(index)",d=SVGRenderer.data(path)
      let rule=evenOdd ? "evenodd":"nonzero"
      let style="fill-rule=\"\(rule)\" clip-rule=\"\(rule)\" opacity=\"\(paint.opacity)\" style=\"mix-blend-mode:\(paint.blendMode ?? "normal")\""
      switch paint.kind {
      case "solid":output += "<path d=\"\(d)\" fill=\"\(paint.color)\" \(style)/>"
      case "gradient":
        guard let g=paint.gradient else{throw FormError.invalid("Missing gradient paint during SVG export.")}
        if NativeGradientRenderer.handles(g) {
          let bounds=path.boundingBoxOfPath
          if !bounds.isNull && !bounds.isEmpty {
            let png=try NativeGradientRenderer.png(g,size:size,bounds:bounds)
            output += "<defs><clipPath id=\"\(id)\"><path d=\"\(d)\" clip-rule=\"\(rule)\"/></clipPath></defs><g clip-path=\"url(#\(id))\" \(style)><image x=\"\(bounds.minX)\" y=\"\(bounds.minY)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,\(png.base64EncodedString())\"/></g>"
          }
          continue
        }
        let stops=g.stops.map{"<stop offset=\"\($0.offset)\" stop-color=\"\($0.color)\" stop-opacity=\"\($0.opacity ?? 1)\"/>"}.joined()
        let transform=g.transform.map{" gradientTransform=\"\(matrix($0))\""} ?? ""
        let start=CGPoint(x:g.start.x*size.width,y:g.start.y*size.height),end=CGPoint(x:g.end.x*size.width,y:g.end.y*size.height)
        let definition:String
        if g.kind == "radial" {definition="<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\"\(transform) cx=\"\(start.x)\" cy=\"\(start.y)\" r=\"\(hypot(end.x-start.x,end.y-start.y))\">\(stops)</radialGradient>"}
        else{definition="<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\"\(transform) x1=\"\(start.x)\" y1=\"\(start.y)\" x2=\"\(end.x)\" y2=\"\(end.y)\">\(stops)</linearGradient>"}
        output += "<defs>\(definition)</defs><path d=\"\(d)\" fill=\"url(#\(id))\" \(style)/>"
      case "image":
        guard let name=paint.asset,!name.contains("/") else{throw FormError.invalid("Missing image paint during SVG export.")}
        let url=assets.appendingPathComponent(name),ext=url.pathExtension.lowercased()
        var bytes=try Data(contentsOf:url),mime=["jpg","jpeg"].contains(ext) ? "image/jpeg":"image/png"
        let metadata=try ImageRenderer.info(url)
        if !["png","jpg","jpeg"].contains(ext) || metadata.oriented {
          let bitmap=try ImageRenderer.bitmap(url,requestedEdge:Double(max(metadata.width,metadata.height)))
          guard max(metadata.width,metadata.height)<=ImageRenderer.maximumEdge,metadata.width*metadata.height<=ImageRenderer.maximumPixels,
            let png=NSBitmapImageRep(cgImage:bitmap).representation(using:.png,properties:[:]) else{throw FormError.invalid("Image paint exceeds lossless SVG conversion limits.")}
          bytes=png;mime="image/png"
        }
        let map=Affine2.scale(size.width,size.height).followed(by:paint.imageTransform ?? .init())
        var filter="",filterDefinition=""
        if let adjustment=paint.imageAdjustments,!adjustment.isIdentity {
          let values=adjustment.colorMatrix.flatMap{$0}.map{String($0)}.joined(separator:" ")
          filterDefinition="<filter id=\"\(id)-color\" color-interpolation-filters=\"sRGB\"><feColorMatrix type=\"matrix\" values=\"\(values)\"/></filter>"
          filter=" filter=\"url(#\(id)-color)\""
        }
        let image="<image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" href=\"data:\(mime);base64,\(bytes.base64EncodedString())\"\(filter)/>"
        if paint.imageRepeat == true {
          output += "<defs>\(filterDefinition)<pattern id=\"\(id)\" patternUnits=\"userSpaceOnUse\" width=\"1\" height=\"1\" patternTransform=\"\(matrix(map))\">\(image)</pattern></defs><path d=\"\(d)\" fill=\"url(#\(id))\" \(style)/>"
        }else{
          output += "<defs>\(filterDefinition)<clipPath id=\"\(id)\"><path d=\"\(d)\" clip-rule=\"\(rule)\"/></clipPath></defs><g clip-path=\"url(#\(id))\" \(style)><g transform=\"\(matrix(map))\">\(image)</g></g>"
        }
      default:throw FormError.invalid("Unsupported editable paint in SVG output.")
      }
    }
    return output
  }
}

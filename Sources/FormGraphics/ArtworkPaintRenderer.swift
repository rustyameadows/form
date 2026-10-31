import AppKit
import FormCore

/// Shared ink compositor. Callers supply glyph/vector coverage as a clip; the
/// element size defines paint coordinates, not the extent of visible coverage.
@MainActor public enum ArtworkPaintRenderer {
  public static func validateOutput(_ element:ArtworkElement,assets:URL,pixelsPerMM:Double,transform:Affine2)throws {
    for layer in element.paintLayers where layer.enabled && layer.paint.kind == "image" {
      let paint=layer.paint
      guard let name=paint.asset,(try? ImageRenderer.info(assets.appendingPathComponent(name))) != nil else{
        throw FormError.invalid("An editable image paint is missing or unreadable.")
      }
      let image=ArtworkElement(kind:"image",x:0,y:0,width:1,height:1,asset:name)
      let map=transform.followed(by:.scale(element.width,element.height)).followed(by:paint.imageTransform ?? .init())
      try ImageRenderer.validateOutput(image,assets:assets,pixelsPerMM:pixelsPerMM,transform:map)
    }
  }
  @discardableResult public static func draw(_ paint:ArtworkPaint,size:CGSize,assets:URL,context:CGContext)->Bool {
    guard size.width>0,size.height>0 else{return false}
    context.saveGState();defer{context.restoreGState()}
    context.setAlpha(paint.opacity);context.setBlendMode(AppearanceRenderer.blend(paint.blendMode))
    let coverage=context.boundingBoxOfClipPath
    switch paint.kind {
    case "solid":
      context.setFillColor(FormColor.color(paint.color).cgColor);context.fill(coverage);return true
    case "gradient":
      guard let gradient=paint.gradient else{return false}
      if NativeGradientRenderer.handles(gradient) {return NativeGradientRenderer.draw(gradient,size:size,opacity:paint.opacity,context:context)}
      let colors=gradient.stops.map{FormColor.color($0.color).withAlphaComponent($0.opacity ?? 1).cgColor}
      let locations=gradient.stops.map{CGFloat($0.offset)}
      guard let ramp=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:locations) else{return false}
      if let transform=gradient.transform{context.concatenate(transform.cg)}
      let start=CGPoint(x:gradient.start.x*size.width,y:gradient.start.y*size.height)
      let end=CGPoint(x:gradient.end.x*size.width,y:gradient.end.y*size.height)
      let radius=hypot(end.x-start.x,end.y-start.y)
      if radius<1e-9,let stop=gradient.stops.last {
        context.setFillColor(FormColor.color(stop.color).withAlphaComponent(stop.opacity ?? 1).cgColor)
        context.fill(context.boundingBoxOfClipPath)
      }else if gradient.kind == "radial" {
        context.drawRadialGradient(ramp,startCenter:start,startRadius:0,endCenter:start,endRadius:radius,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
      }else{context.drawLinearGradient(ramp,start:start,end:end,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])}
      return true
    case "image":
      guard let name=paint.asset,!name.contains("/"),let info=try? ImageRenderer.info(assets.appendingPathComponent(name)) else{return false}
      let map=Affine2.scale(size.width,size.height).followed(by:paint.imageTransform ?? .init())
      let pixelMap=context.ctm.concatenating(map.cg).scaledBy(x:1/Double(info.width),y:1/Double(info.height))
      let edge=Double(max(info.width,info.height))*AppearanceRenderer.scale(pixelMap)
      guard let image=try? ImageRenderer.bitmap(assets.appendingPathComponent(name),adjustments:paint.imageAdjustments,requestedEdge:edge) else{return false}
      context.concatenate(map.cg)
      context.interpolationQuality = .high
      // CGImage uses bottom-left image coordinates; paint coordinates follow
      // the top-left scene convention used by all native canvas layers.
      context.translateBy(x:0,y:1);context.scaleBy(x:1,y:-1)
      if paint.imageRepeat == true {context.draw(image,in:.init(x:0,y:0,width:1,height:1),byTiling:true)}
      else{context.draw(image,in:.init(x:0,y:0,width:1,height:1))}
      return true
    default:return false
    }
  }

  public static func drawVector(_ e:ArtworkElement,assets:URL,context:CGContext) {
    let path=VectorGeometry.path(e),rule:CGPathFillRule=e.path?.evenOdd == true ? .evenOdd:.winding
    for layer in e.paintStack ?? [] where layer.enabled {
      context.saveGState()
      if let stroke=layer.stroke {
        if stroke.enabled == false || stroke.width<=0 {context.restoreGState();continue}
        var sample=e;sample.paintStack=nil;sample.stroke=stroke
        if let outline=try? VectorGeometry.expandedStroke(sample),!outline.isEmpty{context.addPath(outline);context.clip()}
        else{context.restoreGState();continue}
      }else{
        // An empty path is no coverage, not permission to paint the prior clip.
        guard !path.isEmpty,!path.boundingBoxOfPath.isEmpty else{context.restoreGState();continue}
        context.addPath(path);context.clip(using:rule)
      }
      draw(layer.effectivePaint,size:.init(width:e.width,height:e.height),assets:assets,context:context)
      context.restoreGState()
    }
  }
}

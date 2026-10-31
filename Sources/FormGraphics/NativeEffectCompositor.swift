import AppKit
import CryptoKit
import FormCore

/// Owns bounded source capture and cache; each shadow remains a separate draw
/// so its blend mode sees the real backdrop until an authored isolation boundary.
@MainActor enum NativeEffectCompositor {
  final class Entry {
    let raster:EffectStackRaster,bounds:CGRect,density:Double
    init(_ raster:EffectStackRaster,_ bounds:CGRect,_ density:Double){self.raster=raster;self.bounds=bounds;self.density=density}
  }
  private static let cache:NSCache<NSString,Entry> = {
    let value=NSCache<NSString,Entry>();value.countLimit=128;value.totalCostLimit=64_000_000;return value
  }()
  private static var lastError:String?
  static func invalidateFonts(){cache.removeAllObjects()}
  static func validate(_ stack:ArtworkEffectStack,bounds:CGRect,pixelsPerMM:Double)throws {
    try stack.validate()
    let w=ceil(bounds.width*pixelsPerMM),h=ceil(bounds.height*pixelsPerMM)
    guard [bounds.minX,bounds.minY,bounds.width,bounds.height,pixelsPerMM,w,h].allSatisfy(\.isFinite),
      bounds.width>0,bounds.height>0,pixelsPerMM>0,w<=Double(EffectStackRenderer.maximumEdge),h<=Double(EffectStackRenderer.maximumEdge),
      w*h<=Double(EffectStackRenderer.maximumPixelsPerRender(stack)) else{throw FormError.invalid("The editable effect stack exceeds its output resolution budget. Reduce the effect extent or export DPI.")}
  }
  static func raster(_ element:ArtworkElement,signature:Data,bounds:CGRect,pixelsPerMM:Double,strict:Bool=false,
    content:(CGContext)->Void,silhouette:(CGContext,Bool)->Void)throws->Entry {
    guard let stack=element.effectStack,stack.hasActiveEffects else{throw FormError.invalid("No active effect stack.")}
    let requested=max(0.25,ceil(pixelsPerMM*4)/4)
    guard [bounds.minX,bounds.minY,bounds.width,bounds.height,requested].allSatisfy(\.isFinite),bounds.width>0,bounds.height>0 else{
      throw FormError.invalid("Invalid effect coverage bounds.")
    }
    if strict{try validate(stack,bounds:bounds,pixelsPerMM:requested)}
    let maximum=EffectStackRenderer.maximumPixelsPerRender(stack)
    var density=min(requested,Double(EffectStackRenderer.maximumEdge)/max(bounds.width,bounds.height),sqrt(Double(maximum)/(bounds.width*bounds.height)))
    var width=max(1,Int(ceil(bounds.width*density))),height=max(1,Int(ceil(bounds.height*density)))
    for _ in 0..<8 where width*height>maximum || max(width,height)>EffectStackRenderer.maximumEdge {
      density *= 0.99;width=max(1,Int(ceil(bounds.width*density)));height=max(1,Int(ceil(bounds.height*density)))
    }
    guard width*height<=maximum,max(width,height)<=EffectStackRenderer.maximumEdge else{throw FormError.invalid("Effect raster cannot fit its bounded budget.")}
    let output=CGRect(x:bounds.minX,y:bounds.minY,width:Double(width)/density,height:Double(height)/density)
    var bytes=signature
    bytes.append(Data("|\(output.minX),\(output.minY),\(output.width),\(output.height)|\(width)x\(height)".utf8))
    let key=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() as NSString
    if let value=cache.object(forKey:key){return value}
    let reservation=try ArtworkRasterBudget.reserve(width*height*4*(6+stack.activeEffects.filter{$0.kind != "blur"}.count))
    defer{ArtworkRasterBudget.release(reservation)}
    func capture(_ draw:(CGContext)->Void)throws->CGImage {
      try Task.checkCancellation()
      guard let bitmap=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("Could not allocate effect coverage.")}
      bitmap.translateBy(x:-output.minX*density,y:output.maxY*density);bitmap.scaleBy(x:density,y:-density)
      NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
      NSGraphicsContext.current=NSGraphicsContext(cgContext:bitmap,flipped:true);draw(bitmap)
      try ArtworkRasterBudget.check(reservation)
      guard let image=bitmap.makeImage() else{throw FormError.invalid("Could not capture effect coverage.")};return image
    }
    let source=try capture(content)
    let casting=stack.coverage == "paint-outline" ? try capture{silhouette($0,false)}:nil
    let knockout=stack.coverage == "paint-outline" ? try capture{silhouette($0,true)}:nil
    var spreadError:Error?
    let raster=try EffectStackRenderer.render(source:source,casting:casting,knockout:knockout,stack:stack,density:density,
      spreadCoverage:{effect in
        var shape=element;shape.hidden=nil
        guard let path=EffectSilhouetteRenderer.spreadPath(shape,spread:effect.spread,inner:effect.kind == "inner-shadow") else{return nil}
        do {return try capture{context in
          context.setFillColor(NSColor.white.cgColor);context.addPath(path);context.fillPath()
        }}catch{spreadError=error;return nil}
      })
    if let spreadError{throw spreadError}
    let value=Entry(raster,output,density);cache.setObject(value,forKey:key,cost:raster.byteCost);return value
  }
  @discardableResult static func draw(_ element:ArtworkElement,signature:Data,bounds:CGRect,context:CGContext,pixelsPerMM:Double?,
    content:(CGContext)->Void,silhouette:(CGContext,Bool)->Void)->Bool {
    do {
      let entry=try raster(element,signature:signature,bounds:bounds,pixelsPerMM:AppearanceRenderer.scale(context)*(pixelsPerMM ?? 1),content:content,silhouette:silhouette)
      func draw(_ image:CGImage,blend:String?=nil) {
        context.saveGState();defer{context.restoreGState()}
        context.setBlendMode(AppearanceRenderer.blend(blend))
        context.translateBy(x:entry.bounds.minX,y:entry.bounds.maxY);context.scaleBy(x:entry.bounds.width,y:-entry.bounds.height)
        context.interpolationQuality = .high;context.draw(image,in:.init(x:0,y:0,width:1,height:1))
      }
      for layer in entry.raster.behind{draw(layer.image,blend:layer.blendMode)}
      if element.effectStack?.activeEffects.contains(where:{$0.kind == "blur"}) == true {draw(entry.raster.content)}
      else {content(context)}
      for layer in entry.raster.above{draw(layer.image,blend:layer.blendMode)}
      lastError=nil;return true
    }catch{ArtworkRasterBudget.failed();lastError=error.localizedDescription;return false}
  }
  static func svgImage(_ image:CGImage,bounds:CGRect,blend:String?=nil)throws->String {
    guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw FormError.invalid("Could not encode effect coverage for SVG.")}
    return "<image x=\"\(bounds.minX)\" y=\"\(bounds.minY)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" preserveAspectRatio=\"none\" style=\"mix-blend-mode:\(blend ?? "normal")\" href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
  }
  static func svgMaskImage(_ coverage:ArtworkMaskRenderer.Coverage)throws->String {
    let image=coverage.image,rect=CGRect(x:0,y:0,width:image.width,height:image.height)
    guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("Could not allocate SVG mask coverage.")}
    context.clip(to:rect,mask:image);context.setFillColor(NSColor.white.cgColor);context.fill(rect)
    guard let alpha=context.makeImage() else{throw FormError.invalid("Could not encode SVG mask coverage.")}
    return try svgImage(alpha,bounds:coverage.bounds)
  }
}

import AppKit
import CryptoKit
import FormCore

/// Native editable angular/diamond inks. Only the paint preview is sampled;
/// vector/glyph coverage and the gradient's stops/transform remain independent.
@MainActor public enum NativeGradientRenderer {
  public static let maximumPixels=4_000_000,maximumEdge=4096
  private final class Entry {
    let image:CGImage,bounds:CGRect
    init(_ image:CGImage,_ bounds:CGRect){self.image=image;self.bounds=bounds}
  }
  private static let cache:NSCache<NSString,Entry>={
    let result=NSCache<NSString,Entry>();result.totalCostLimit=64_000_000;result.countLimit=128;return result
  }()
  public static func handles(_ gradient:ArtworkGradient)->Bool { ["angular","diamond"].contains(gradient.kind) }
  /// Sample a normalized stop position in the gradient's local coordinate frame.
  public static func position(_ gradient:ArtworkGradient,size:CGSize,point:Point2)->Double {
    let p=(gradient.transform?.inverse ?? .init()).apply(point)
    let center=Point2(gradient.start.x*size.width,gradient.start.y*size.height)
    let dx=(gradient.end.x-gradient.start.x)*size.width,dy=(gradient.end.y-gradient.start.y)*size.height
    let radius=hypot(dx,dy)
    guard radius>1e-12 else{return 1}
    let ux=dx/radius,uy=dy/radius,px=p.x-center.x,py=p.y-center.y
    let x=(px*ux+py*uy)/radius,y=(-px*uy+py*ux)/radius
    if gradient.kind == "diamond" {return min(1,abs(x)+abs(y))}
    var turn=atan2(y,x)/(2 * .pi)
    if turn<0 {turn+=1}
    return turn
  }
  private static func entry(_ gradient:ArtworkGradient,size:CGSize,bounds:CGRect,density:Double)throws->Entry {
    guard handles(gradient),size.width>0,size.height>0,!bounds.isNull,!bounds.isEmpty,
      [bounds.minX,bounds.minY,bounds.width,bounds.height,density].allSatisfy({$0.isFinite}),density>0 else {
      throw FormError.invalid("Invalid angular or diamond gradient extent.")
    }
    let cap=min(Double(maximumEdge)/max(bounds.width,bounds.height),sqrt(Double(maximumPixels)/(bounds.width*bounds.height)))
    guard cap.isFinite,cap>0 else {throw FormError.invalid("Gradient extent exceeds preview limits.")}
    let scale=min(max(0.01,ceil(density*4)/4),cap)
    let w=max(1,Int(floor(bounds.width*scale))),h=max(1,Int(floor(bounds.height*scale)))
    var key=try JSONEncoder().encode(gradient)
    key.append(Data("|\(size.width)|\(size.height)|\(bounds)|\(w)|\(h)".utf8))
    let hash=SHA256.hash(data:key).map{String(format:"%02x",$0)}.joined() as NSString
    if let entry=cache.object(forKey:hash){return entry}
    let stops=gradient.stops.map { stop -> (Double,[Double]) in
      let c=FormColor.color(stop.color).usingColorSpace(.sRGB)!
      return (stop.offset,[c.redComponent,c.greenComponent,c.blueComponent,stop.opacity ?? 1])
    }
    guard stops.count>=2 else{throw FormError.invalid("A gradient needs at least two stops.")}
    let inverse=gradient.transform?.inverse ?? .init()
    var normalized=gradient;normalized.transform=nil
    var pixels=[UInt8](repeating:0,count:w*h*4)
    for y in 0..<h {
      if y & 31 == 0 {try Task.checkCancellation()}
      for x in 0..<w {
        let p=inverse.apply(.init(bounds.minX+(Double(x)+0.5)*bounds.width/Double(w),bounds.minY+(Double(y)+0.5)*bounds.height/Double(h)))
        let t=position(normalized,size:size,point:p)
        var lo=0,hi=stops.count
        while lo<hi {let middle=(lo+hi)/2;if stops[middle].0<=t {lo=middle+1}else{hi=middle}}
        let upper=min(lo,stops.count-1),lower=max(0,lo-1)
        let span=stops[upper].0-stops[lower].0
        let f=span>1e-12 ? max(0,min(1,(t-stops[lower].0)/span)):0
        let a=stops[lower].1,b=stops[upper].1,alpha=a[3]+(b[3]-a[3])*f,index=(y*w+x)*4
        for c in 0..<3 {pixels[index+c]=UInt8(max(0,min(255,((a[c]+(b[c]-a[c])*f)*alpha*255).rounded())))}
        pixels[index+3]=UInt8(max(0,min(255,(alpha*255).rounded())))
      }
    }
    let data=Data(pixels)
    guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
      provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw FormError.invalid("Could not render a gradient paint.")}
    let result=Entry(image,bounds);cache.setObject(result,forKey:hash,cost:w*h*4);return result
  }
  @discardableResult public static func draw(_ gradient:ArtworkGradient,size:CGSize,opacity:Double=1,context:CGContext)->Bool {
    // The element frame keeps the cache stable while the viewport clips a
    // partially offscreen fill. Include painted overflow for strokes/glyphs.
    let bounds=CGRect(origin:.zero,size:size).union(context.boundingBoxOfClipPath)
    guard let entry=try? entry(gradient,size:size,bounds:bounds,density:AppearanceRenderer.scale(context)) else{return false}
    context.saveGState();defer{context.restoreGState()}
    context.translateBy(x:entry.bounds.minX,y:entry.bounds.maxY);context.scaleBy(x:1,y:-1)
    context.setAlpha(opacity);context.interpolationQuality = .high
    context.draw(entry.image,in:.init(origin:.zero,size:entry.bounds.size));return true
  }
  public static func validateOutput(bounds:CGRect,pixelsPerMM:Double)throws {
    let w=ceil(bounds.width*pixelsPerMM),h=ceil(bounds.height*pixelsPerMM)
    guard w.isFinite,h.isFinite,w>0,h>0,w<=Double(maximumEdge),h<=Double(maximumEdge),w*h<=Double(maximumPixels) else {
      throw FormError.invalid("An angular or diamond gradient exceeds bounded output resolution. Reduce export DPI or the gradient's painted extent.")
    }
  }
  public static func png(_ gradient:ArtworkGradient,size:CGSize,bounds:CGRect,pixelsPerMM:Double=300/25.4)throws->Data {
    try validateOutput(bounds:bounds,pixelsPerMM:pixelsPerMM)
    let entry=try entry(gradient,size:size,bounds:bounds,density:pixelsPerMM)
    guard let data=NSBitmapImageRep(cgImage:entry.image).representation(using:.png,properties:[:]) else {throw FormError.invalid("Could not encode a gradient paint.")}
    return data
  }
}

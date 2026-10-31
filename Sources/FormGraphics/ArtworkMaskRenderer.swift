import AppKit
import CryptoKit
import FormCore

/// Bounded transient coverage for editable mask subtrees. No mask is flattened
/// into the document; geometry, text, images and effects remain ordinary layers.
@MainActor public enum ArtworkMaskRenderer {
  public static let maximumEdge = 8192, maximumPixels = 16_000_000
  public final class Coverage {
    public let image: CGImage
    public let bounds: CGRect
    public let canSample = true
    private let alpha: Data
    private let width: Int, height: Int
    init(image: CGImage, bounds: CGRect, alpha: Data, width: Int, height: Int) {
      self.image=image;self.bounds=bounds;self.alpha=alpha;self.width=width;self.height=height
    }
    public func sample(atParentPoint point: CGPoint) -> Double {
      guard point.x.isFinite,point.y.isFinite,bounds.contains(point),bounds.width>0,bounds.height>0 else{return 0}
      let x=min(width-1,max(0,Int((point.x-bounds.minX)/bounds.width*Double(width))))
      // The capture is drawn into a flipped bitmap: its first stored row is
      // the parent's minimum Y. Image installation handles Quartz's image
      // transform separately; sampling must not apply that second flip.
      let y=min(height-1,max(0,Int((point.y-bounds.minY)/bounds.height*Double(height))))
      return Double(alpha[y*width+x])/255
    }
    /// Positive coverage near a screen-space tolerance is sampled with a fixed
    /// work cap. Exact clicks never grow the painted mask boundary.
    public func maximum(around point:CGPoint,radius:Double)->Double {
      let exact=sample(atParentPoint:point)
      guard exact==0,radius.isFinite,radius>0 else{return exact}
      var result=0.0
      for ring in 1...3 { for index in 0..<16 {
        let angle=Double(index)*2 * Double.pi/16,r=radius*Double(ring)/3
        result=max(result,sample(atParentPoint:.init(x:point.x+cos(angle)*r,y:point.y+sin(angle)*r)))
      } }
      return result
    }
  }
  private static let cache:NSCache<NSString,Coverage> = {
    let result=NSCache<NSString,Coverage>();result.countLimit=128;result.totalCostLimit=64_000_000;return result
  }()
  private static var builds=0,hits=0,limited=0,lastError:String?
  public static var diagnostics:[String:Any] { ["builds":builds,"cache_hits":hits,"preview_scale_limits":limited,"last_error":lastError ?? ""] }
  public static func invalidateFonts(){cache.removeAllObjects()}
  public static func validate(bounds:CGRect,pixelsPerMM:Double)throws {
    let w=ceil(bounds.width*pixelsPerMM),h=ceil(bounds.height*pixelsPerMM)
    guard [bounds.minX,bounds.minY,bounds.width,bounds.height,pixelsPerMM,w,h].allSatisfy(\.isFinite),
      bounds.width>0,bounds.height>0,pixelsPerMM>0,w<=Double(maximumEdge),h<=Double(maximumEdge),w*h<=Double(maximumPixels) else{
      throw FormError.invalid("An editable mask exceeds its output resolution budget. Reduce its extent or export DPI.")
    }
  }
  public static func coverage(mode:String,bounds:CGRect,signature:Data,pixelsPerMM:Double,
    draw:(CGContext)->Void)->Coverage? {
    guard !Task.isCancelled,ArtworkMasks.isCoverage(mode),ArtworkMasks.modes.contains(mode),
      [bounds.minX,bounds.minY,bounds.width,bounds.height,pixelsPerMM].allSatisfy(\.isFinite),
      bounds.width>0,bounds.height>0,pixelsPerMM>0 else{return nil}
    let requested=max(0.25,ceil(pixelsPerMM*4)/4)
    // Leave one edge pixel of rounding headroom so ceil cannot exceed the
    // advertised allocation budget, including very elongated mask bounds.
    let cap=min(Double(maximumEdge-1)/max(bounds.width,bounds.height),sqrt(Double(maximumPixels-2*maximumEdge)/(bounds.width*bounds.height)))
    let density=min(requested,cap)
    if density<requested {limited+=1}
    guard density.isFinite,density>0 else{return nil}
    let width=max(1,Int(ceil(bounds.width*density))),height=max(1,Int(ceil(bounds.height*density)))
    let output=CGRect(x:bounds.minX,y:bounds.minY,width:Double(width)/density,height:Double(height)/density)
    var bytes=signature
    bytes.append(Data("|\(mode)|\(output.minX),\(output.minY),\(output.width),\(output.height)|\(width)x\(height)".utf8))
    let key=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() as NSString
    if let value=cache.object(forKey:key){hits+=1;return value}
    let reservation:ArtworkRasterBudget.Reservation
    do{reservation=try ArtworkRasterBudget.reserve(width*height*5)}catch{lastError=error.localizedDescription;return nil}
    defer{ArtworkRasterBudget.release(reservation)}
    guard let bitmap=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{
      ArtworkRasterBudget.failed();lastError="Could not allocate editable mask coverage.";return nil
    }
    bitmap.translateBy(x:-output.minX*density,y:output.maxY*density);bitmap.scaleBy(x:density,y:-density)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:bitmap,flipped:true)
    draw(bitmap)
    NSGraphicsContext.restoreGraphicsState()
    do{try ArtworkRasterBudget.check(reservation)}catch{lastError=error.localizedDescription;return nil}
    guard !Task.isCancelled,let rgba=bitmap.data?.assumingMemoryBound(to:UInt8.self) else{return nil}
    var alpha=Data(count:width*height)
    var cancelled=false
    alpha.withUnsafeMutableBytes { destination in
      let output=destination.bindMemory(to:UInt8.self)
      for y in 0..<height {
        if y & 31 == 0 && Task.isCancelled {cancelled=true;break}
        for x in 0..<width {
          let i=y*width+x,p=i*4,a=Double(rgba[p+3])/255
          let value:Double
          if mode=="alpha" {value=Double(rgba[p+3])}
          else {
            // These are premultiplied sRGB samples. Ordinary luminance already
            // includes alpha once; luminance-alpha retains a second authored
            // coverage multiplication used by some interchange producers.
            value=(0.2126*Double(rgba[p])+0.7152*Double(rgba[p+1])+0.0722*Double(rgba[p+2])) * (mode=="luminance-alpha" ? a:1)
          }
          output[i]=UInt8(max(0,min(255,value.rounded())))
        }
      }
    }
    guard !cancelled,let provider=CGDataProvider(data:alpha as CFData),let image=CGImage(width:width,height:height,
      bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
      provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return nil}
    let result=Coverage(image:image,bounds:output,alpha:alpha,width:width,height:height)
    cache.setObject(result,forKey:key,cost:width*height);builds+=1;lastError=nil;return result
  }
  @discardableResult public static func install(_ coverage:Coverage?,context:CGContext)->Bool {
    guard let coverage else{context.clip(to:.zero);return false}
    let bounds=coverage.bounds
    context.translateBy(x:bounds.minX,y:bounds.maxY);context.scaleBy(x:1,y:-1)
    context.clip(to:.init(origin:.zero,size:bounds.size),mask:coverage.image)
    context.scaleBy(x:1,y:-1);context.translateBy(x:-bounds.minX,y:-bounds.maxY)
    return true
  }
  @discardableResult public static func install(mode:String,bounds:CGRect,signature:Data,context:CGContext,
    pixelsPerMM:Double?=nil,draw:(CGContext)->Void)->Bool {
    install(coverage(mode:mode,bounds:bounds,signature:signature,
      pixelsPerMM:AppearanceRenderer.scale(context)*(pixelsPerMM ?? 1),draw:draw),context:context)
  }
}

import AppKit
import CryptoKit
import FormCore
import ImageIO
import UniformTypeIdentifiers

/// A deterministic local graphic, deliberately labelled on the pixels and in
/// PNG metadata. References are shown as references, never claimed AI results.
@MainActor enum StudioGenerationDemoRenderer {
  struct Input {let scene:NSImage?;let references:[NSImage]}
  static let maximumImageBytes=32*1024*1024
  static let maximumSceneBytes=64*1024*1024
  static let maximumTotalBytes=64*1024*1024
  static func prepare(_ request:StudioGenerationRequest)throws->Input {
    try request.options.validate();try request.validateOutputPixels();try Task.checkCancellation();try request.context?.validate()
    guard !request.prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
      request.prompt.count<=8000,request.prompt.utf8.count<=32_000,
      request.style.count<=4000,request.style.utf8.count<=16_000 else {
      throw StudioGenerationError.invalid("Use a prompt of up to 8,000 characters and style instructions of up to 4,000 characters.")
    }
    let ids=Set(request.references.map(\.assetID)),imageIDs=Set(request.referenceImages.map(\.assetID))
    guard request.references.count<=StudioGenerationConfigurationRegistry.maximumReferences,
      ids.count==request.references.count,imageIDs.count==request.referenceImages.count,
      request.referenceImages.count<=StudioGenerationConfigurationRegistry.maximumReferences,
      request.referenceImages.allSatisfy({$0.name.count<=500 && $0.name.utf8.count<=2000}) else {
      throw StudioGenerationError.invalid("Use up to eight distinct, named reference images.")
    }
    if request.source == .canvas {
      guard request.inputPNG==nil,request.context==nil,ids==imageIDs else {
        throw StudioGenerationError.invalid("Canvas generation requires the frozen bytes for each reference and no Studio scene input.")
      }
    } else {
      guard request.inputPNG != nil else {throw StudioGenerationError.invalid("The captured scene image is unavailable.")}
      // Legacy Studio requests identify Library references without their bytes.
      // New materialized reference requests must be complete in either surface.
      guard imageIDs.isEmpty || ids==imageIDs else {throw StudioGenerationError.invalid("Reference image bytes do not match the request.")}
    }
    var bytes=request.inputPNG?.count ?? 0
    // Studio captures retain their full pixels; Canvas references keep the
    // smaller per-image budget. Both fit the shared Library's owned-byte limit.
    guard bytes<=maximumSceneBytes else {throw StudioGenerationError.invalid("The Studio scene input exceeds 64 MiB.")}
    for image in request.referenceImages {
      guard image.png.count<=maximumImageBytes,bytes<=maximumTotalBytes-image.png.count else {
        throw StudioGenerationError.invalid("Reference images exceed their 64 MiB total limit.")
      }
      bytes+=image.png.count
    }
    let scene=try request.inputPNG.map { try sceneImage($0,exact:request.options.outputPixels) }
    let ordered=request.references.compactMap {reference in request.referenceImages.first{$0.assetID==reference.assetID}}
    let references=try ordered.map {try image($0.png)}
    return .init(scene:scene,references:references)
  }
  private static func sceneImage(_ data:Data,exact pixels:StudioPixels?)throws->NSImage {
    if let pixels {
      let image=try StudioGenerationPNG.image(of:data,matching:pixels)
      // NSImage's point size may reflect PNG DPI metadata. The exact Studio
      // path deliberately uses the validated pixel extent, never a thumbnail.
      return NSImage(cgImage:image,size:.init(width:pixels.width,height:pixels.height))
    }
    // Retain the pre-exact-pixel legacy aspect/size rendering path while still
    // bounding full decoding. Reference thumbnails must not downsample scenes.
    guard data.starts(with:[137,80,78,71,13,10,26,10]),
      let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
      CGImageSourceGetCount(source)==1,
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
      width>0,height>0,width<=8192,height<=8192,width<=16_777_216/height,
      CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) != nil,
      let image=NSImage(data:data),image.size.width>0,image.size.height>0 else {
      throw StudioGenerationError.invalid("The captured scene needs a valid PNG within 8,192 pixels per side and 16 megapixels.")
    }
    return image
  }
  private static func image(_ data:Data)throws->NSImage {
    try Task.checkCancellation()
    guard data.starts(with:[137,80,78,71,13,10,26,10]),
      let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
      CGImageSourceGetCount(source)==1,
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
      width>0,height>0,width<=8192,height<=8192,width<=16_777_216/height,
      let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
        kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024,
        kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
      throw StudioGenerationError.invalid("Use a valid PNG input within 8,192 pixels per side and 16 megapixels.")
    }
    try Task.checkCancellation()
    return NSImage(cgImage:image,size:.init(width:image.width,height:image.height))
  }
  static func render(_ request:StudioGenerationRequest,input:Input,index:Int)throws->Data {
    try Task.checkCancellation();try request.validateOutputPixels()
    let pixels=request.outputPixels
    guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels.width,pixelsHigh:pixels.height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
      let context=NSGraphicsContext(bitmapImageRep:bitmap) else{throw StudioGenerationError.invalid("Unable to allocate a bounded demo image.")}
    let contextHash=try request.context?.sha256 ?? ""
    let references=request.references.map{$0.assetID.uuidString+$0.role.rawValue}.joined()
    let seed=Data((request.prompt+request.style+request.options.model.rawValue+String(index)+contextHash+references).utf8)
    let hash=Array(SHA256.hash(data:seed)),hue=CGFloat(hash[0])/255
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    defer{NSGraphicsContext.restoreGraphicsState()}
    let bounds=CGRect(x:0,y:0,width:pixels.width,height:pixels.height),inset=CGFloat(max(20,pixels.width/30))
    if let scene=input.scene {
      NSColor(calibratedHue:hue,saturation:0.055,brightness:0.96,alpha:1).setFill();bounds.fill()
      let rect:CGRect
      if request.options.outputPixels != nil {
        rect=bounds;context.imageInterpolation = .none
      } else { rect=fitted(scene,in:bounds.insetBy(dx:inset,dy:inset+18)) }
      scene.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
      NSColor(calibratedHue:hue,saturation:0.25,brightness:0.85,alpha:0.055+CGFloat(index)*0.01).setFill();rect.fill(using:.sourceAtop)
    } else {
      drawCanvas(bounds:bounds,hue:hue,references:input.references)
    }
    let ink=NSColor(calibratedWhite:0.17,alpha:1)
    let caption=request.source == .studioScene ? "Scene input + local color treatment · no AI request":input.references.isEmpty ? "Sample artwork · no AI request":"Reference collage · no AI request"
    if request.source == .studioScene {
      // Match Studio's full-canvas treatment: lightweight labels over pixels,
      // without Canvas demo badge/strip panels that could obscure source edges.
      let studioInk=NSColor(calibratedWhite:0.2,alpha:1)
      let font=NSFont.monospacedSystemFont(ofSize:CGFloat(max(9,pixels.width/75)),weight:.medium)
      ("LOCAL DEMO · \(index+1) / \(request.options.count)" as NSString).draw(at:.init(x:inset,y:bounds.maxY-inset-14),withAttributes:[.font:font,.foregroundColor:studioInk])
      (caption as NSString).draw(at:.init(x:inset,y:inset/2),withAttributes:[.font:NSFont.systemFont(ofSize:CGFloat(max(8,pixels.width/100))),.foregroundColor:studioInk])
    } else if request.canvasOutputPixels != nil, min(pixels.width,pixels.height)<256 {
      // A wide or tall custom artboard still needs readable demo identification;
      // fixed margins from the larger presets can otherwise cover the whole image.
      let padding=max(3,min(bounds.width,bounds.height)*0.06),badge="LOCAL DEMO"
      let fontSize=min(11,max(5,(bounds.width-padding*4)/7))
      let font=NSFont.monospacedSystemFont(ofSize:fontSize,weight:.semibold)
      let textSize=(badge as NSString).size(withAttributes:[.font:font])
      let badgeRect=CGRect(x:padding,y:bounds.maxY-padding-textSize.height-6,
        width:min(bounds.width-padding*2,textSize.width+8),height:textSize.height+6)
      NSColor.white.withAlphaComponent(0.9).setFill();NSBezierPath(roundedRect:badgeRect,xRadius:4,yRadius:4).fill()
      (badge as NSString).draw(at:.init(x:badgeRect.minX+4,y:badgeRect.minY+3),withAttributes:[.font:font,.foregroundColor:ink])
      let footer="NO AI REQUEST",footerFont=NSFont.systemFont(ofSize:min(9,max(5,(bounds.width-padding*2)/8)))
      let strip=CGRect(x:0,y:0,width:bounds.width,height:footerFont.pointSize*1.6+padding)
      NSColor.white.withAlphaComponent(0.92).setFill();strip.fill()
      (footer as NSString).draw(at:.init(x:padding,y:padding/2),withAttributes:[.font:footerFont,.foregroundColor:ink])
    } else {
      let font=NSFont.monospacedSystemFont(ofSize:CGFloat(max(11,pixels.width/65)),weight:.semibold)
      let badge="LOCAL DEMO · \(index+1) / \(request.options.count)"
      let badgeRect=CGRect(x:inset-8,y:bounds.maxY-inset-23,width:min(bounds.width-2*inset+16,CGFloat(pixels.width)*0.56),height:30)
      NSColor.white.withAlphaComponent(0.9).setFill();NSBezierPath(roundedRect:badgeRect,xRadius:8,yRadius:8).fill()
      (badge as NSString).draw(at:.init(x:inset,y:bounds.maxY-inset-15),withAttributes:[.font:font,.foregroundColor:ink])
      let strip=CGRect(x:0,y:0,width:bounds.width,height:inset*1.8)
      NSColor.white.withAlphaComponent(0.92).setFill();strip.fill()
      (caption as NSString).draw(at:.init(x:inset,y:inset/2),withAttributes:[.font:NSFont.systemFont(ofSize:CGFloat(max(9,pixels.width/85))),.foregroundColor:ink])
    }
    guard let image=bitmap.cgImage else{throw StudioGenerationError.invalid("Unable to finish the demo image.")}
    let data=NSMutableData()
    guard let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else{throw StudioGenerationError.invalid("Unable to encode the demo image.")}
    let properties=[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGTitle:"LOCAL DEMO",kCGImagePropertyPNGDescription:caption]] as CFDictionary
    CGImageDestinationAddImage(destination,image,properties)
    guard CGImageDestinationFinalize(destination) else{throw StudioGenerationError.invalid("Unable to encode the demo result.")}
    return data as Data
  }
  private static func fitted(_ image:NSImage,in rect:CGRect)->CGRect {
    let factor=min(rect.width/image.size.width,rect.height/image.size.height)
    return .init(x:rect.midX-image.size.width*factor/2,y:rect.midY-image.size.height*factor/2,width:image.size.width*factor,height:image.size.height*factor)
  }
  private static func drawCanvas(bounds:CGRect,hue:CGFloat,references:[NSImage]) {
    let top=NSColor(calibratedHue:hue,saturation:0.13,brightness:0.99,alpha:1)
    let bottom=NSColor(calibratedHue:(hue+0.1).truncatingRemainder(dividingBy:1),saturation:0.32,brightness:0.82,alpha:1)
    NSGradient(starting:bottom,ending:top)?.draw(in:bounds,angle:90)
    let sun=CGRect(x:bounds.width*0.57,y:bounds.height*0.42,width:bounds.width*0.24,height:bounds.width*0.24)
    NSColor(calibratedHue:(hue+0.12).truncatingRemainder(dividingBy:1),saturation:0.4,brightness:1,alpha:0.9).setFill()
    NSBezierPath(ovalIn:sun).fill()
    for layer in 0..<3 {
      let height=bounds.height*(0.18+Double(layer)*0.09),path=NSBezierPath()
      path.move(to:.init(x:0,y:0));path.line(to:.init(x:0,y:height))
      path.curve(to:.init(x:bounds.width,y:height*0.9),controlPoint1:.init(x:bounds.width*0.3,y:height+bounds.height*0.27),controlPoint2:.init(x:bounds.width*0.65,y:height-bounds.height*0.12))
      path.line(to:.init(x:bounds.width,y:0));path.close()
      NSColor(calibratedHue:(hue+0.48).truncatingRemainder(dividingBy:1),saturation:0.28+CGFloat(layer)*0.1,brightness:0.46+CGFloat(layer)*0.13,alpha:0.75).setFill();path.fill()
    }
    guard !references.isEmpty else{return}
    let count=min(StudioGenerationConfigurationRegistry.maximumReferences,references.count)
    let columns=count==1 ? 1:count<=4 ? 2:3,rows=(count+columns-1)/columns
    let area=CGRect(x:bounds.width*0.12,y:bounds.height*0.19,width:bounds.width*0.76,height:bounds.height*0.61)
    let gap=min(12,min(area.width/CGFloat(columns),area.height/CGFloat(rows))*0.15)
    let width=(area.width-gap*CGFloat(columns-1))/CGFloat(columns),height=(area.height-gap*CGFloat(rows-1))/CGFloat(rows)
    for (index,image) in references.prefix(count).enumerated() {
      let rect=CGRect(x:area.minX+CGFloat(index%columns)*(width+gap),y:area.maxY-CGFloat(index/columns+1)*height-CGFloat(index/columns)*gap,width:width,height:height)
      let inset=min(8,min(rect.width,rect.height)*0.1)
      NSColor.white.withAlphaComponent(0.94).setFill();NSBezierPath(roundedRect:rect,xRadius:inset,yRadius:inset).fill()
      image.draw(in:fitted(image,in:rect.insetBy(dx:inset,dy:inset)),from:.zero,operation:.sourceOver,fraction:1)
    }
  }
}

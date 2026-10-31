import AppKit
import Combine
import CryptoKit
import FormCore
import ImageIO

@MainActor protocol StudioImageGenerationProvider {
  func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data]
}

/// PNG header dimensions are independent of NSImage's DPI-dependent point size.
/// Validate the bounded pixel extent before requesting full bitmap decoding.
enum StudioGenerationPNG {
  static func pixelSize(of data:Data)throws->StudioPixels {
    guard data.starts(with:[137,80,78,71,13,10,26,10]),
      let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)==1,
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.doubleValue.isFinite,height.doubleValue.isFinite,width.doubleValue==Double(width.intValue),height.doubleValue==Double(height.intValue)
      else{throw StudioGenerationError.invalid("The scene image needs a valid single PNG with exact pixel dimensions.")}
    let pixels=StudioPixels(width:width.intValue,height:height.intValue);try pixels.validate();return pixels
  }
  static func image(of data:Data,matching expected:StudioPixels)throws->CGImage {
    guard try pixelSize(of:data)==expected,let source=CGImageSourceCreateWithData(data as CFData,nil),
      let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary),image.width==expected.width,image.height==expected.height
      else{throw StudioGenerationError.invalid("The scene image does not match its Studio output pixels. Recapture the scene; no resizing was applied.")}
    return image
  }
}

/// A deliberately local visual fixture, not an AI implementation. It neither
/// receives credentials nor owns a transport. Every result identifies the demo.
@MainActor struct LocalStudioImageGenerationProvider:StudioImageGenerationProvider {
  var delayNanoseconds:UInt64=90_000_000
  func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data] {
    try request.options.validate();try Task.checkCancellation()
    try request.context?.validate()
    let input:NSImage
    if let pixels=request.options.outputPixels {
      let image=try StudioGenerationPNG.image(of:request.inputPNG,matching:pixels)
      input=NSImage(cgImage:image,size:NSSize(width:pixels.width,height:pixels.height))
    }else {
      // Older recorded requests retain their original mock rendering behavior.
      guard let image=NSImage(data:request.inputPNG),image.size.width>0,image.size.height>0 else{throw StudioGenerationError.invalid("The captured scene image is unavailable.")}
      input=image
    }
    for step in 1...3 {try await Task.sleep(nanoseconds:delayNanoseconds);try Task.checkCancellation();progress(Double(step)*0.1)}
    if request.options.failureFixture != .none {throw StudioGenerationError.fixture(request.options.failureFixture)}
    var output=[Data]()
    for index in 0..<request.options.count {
      try Task.checkCancellation()
      let pixels=request.options.pixels
      guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels.width,pixelsHigh:pixels.height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{throw StudioGenerationError.invalid("Unable to allocate a bounded demo image.")}
      let contextHash=try request.context?.sha256 ?? ""
      let seed=Data((request.prompt+request.style+request.options.model.rawValue+String(index)+contextHash+request.references.map{$0.assetID.uuidString+$0.role.rawValue}.joined()).utf8)
      let hash=Array(SHA256.hash(data:seed)),hue=CGFloat(hash[0])/255
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
      let bounds=CGRect(x:0,y:0,width:pixels.width,height:pixels.height)
      NSColor(calibratedHue:hue,saturation:0.055,brightness:0.96,alpha:1).setFill();bounds.fill()
      let inset=CGFloat(max(20,pixels.width/30)),rect:CGRect
      if request.options.outputPixels != nil {
        // Exact source pixel extent, full canvas, no margins or letterboxing.
        rect=bounds;context.imageInterpolation = .none
      }else {
        let available=bounds.insetBy(dx:inset,dy:inset+18)
        let factor=min(available.width/input.size.width,available.height/input.size.height)
        rect=CGRect(x:bounds.midX-input.size.width*factor/2,y:bounds.midY-input.size.height*factor/2,width:input.size.width*factor,height:input.size.height*factor)
      }
      input.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
      NSColor(calibratedHue:hue,saturation:0.25,brightness:0.85,alpha:0.055+CGFloat(index)*0.01).setFill();rect.fill(using:.sourceAtop)
      let ink=NSColor(calibratedWhite:0.2,alpha:1),font=NSFont.monospacedSystemFont(ofSize:CGFloat(max(9,pixels.width/75)),weight:.medium)
      ("LOCAL DEMO · \(index+1) / \(request.options.count)" as NSString).draw(at:.init(x:inset,y:bounds.maxY-inset-14),withAttributes:[.font:font,.foregroundColor:ink])
      ("Scene input + local color treatment · no AI request" as NSString).draw(at:.init(x:inset,y:inset/2),withAttributes:[.font:NSFont.systemFont(ofSize:CGFloat(max(8,pixels.width/100))),.foregroundColor:ink])
      NSGraphicsContext.restoreGraphicsState()
      guard let png=bitmap.representation(using:.png,properties:[:]) else{throw StudioGenerationError.invalid("Unable to encode the demo result.")}
      output.append(png);progress(0.3+0.7*Double(index+1)/Double(request.options.count))
      try await Task.sleep(nanoseconds:delayNanoseconds)
    }
    return output
  }
}

enum StudioConnectionPreviewState:String {case disconnected,testing,demoReady,authenticationFailed,rateLimited,offline
  var title:String {switch self {case .disconnected:return "Not connected";case .testing:return "Testing local preview";case .demoReady:return "Demo connection ready";case .authenticationFailed:return "Demo authentication error";case .rateLimited:return "Demo rate limit";case .offline:return "Demo offline"}}
}

/// UI state rehearsal only. SecureField contents stay in the view; this API has
/// no secret parameter, credential storage, environment lookup, or client.
@MainActor final class OpenAIConnectionPreviewController:ObservableObject {
  @Published private(set) var state:StudioConnectionPreviewState = .disconnected
  @Published var fixture:StudioGenerationFailureFixture = .none
  @Published private(set) var detail:String?="Local preview only. No credentials or requests are sent."
  private var generation=0
  func useDemoConnection(){generation+=1;state = .demoReady;detail="Demo mode is ready. Images are made locally, with no AI request."}
  func reset(){generation+=1;state = .disconnected;detail="Local preview only. No credentials or requests are sent."}
  func testPreview()async {
    generation+=1;let token=generation,value=fixture;state = .testing
    do {try await Task.sleep(nanoseconds:180_000_000);try Task.checkCancellation()}
    catch {if generation==token {state = .disconnected;detail="Preview test cancelled."};return}
    guard generation==token else{return}
    switch value {case .none:state = .demoReady;case .authentication,.refused:state = .authenticationFailed;case .rateLimit:state = .rateLimited;case .offline:state = .offline}
    detail=value == .none ? "Demo mode is ready. No service was contacted.":value.message
  }
}

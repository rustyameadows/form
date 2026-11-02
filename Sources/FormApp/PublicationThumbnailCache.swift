import AppKit
import CryptoKit
import FormCore
import FormGraphics

/// Transient previews of the resolved source. Neither paper color nor cached
/// pixels are written into page artwork, story frames or production output.
@MainActor final class PublicationThumbnailCache {
  struct Request {
    let artwork:Artwork
    let width:Double,height:Double
    let assets:URL
    let paperColor:String?
    let paperOpacity:Double
    let maximumPixelSize:Int
  }
  typealias Renderer = @MainActor (Request)->NSImage?
  static let shared=PublicationThumbnailCache()
  private struct Key:Hashable {
    let projectID:UUID,objectID:UUID,signature:Data
  }
  private struct Signature:Encodable {
    let artwork:Data,resolved:Data
    let width:Double,height:Double,assets:String,paperColor:String?,paperOpacity:Double,maximumPixelSize:Int,fonts:Int
    let files:[String:String]
  }
  private struct Entry {let image:NSImage,cost:Int;var used:UInt64}
  private let capacity:Int,maximumBytes=32*1024*1024
  private let renderer:Renderer
  private let fontRevision:@MainActor ()->Int
  private var entries:[Key:Entry]=[:],clock:UInt64=0
  private(set) var retainedBytes=0,renderCount=0,hitCount=0
  var count:Int {entries.count}
  init(capacity:Int=128,fontRevision:@escaping @MainActor ()->Int={GeometryFactory.fontRevision},renderer:Renderer?=nil) {
    self.capacity=max(1,min(128,capacity));self.fontRevision=fontRevision
    self.renderer=renderer ?? Self.render
  }
  func removeAll(){entries.removeAll();retainedBytes=0}
  func image(projectID:UUID,objectID:UUID,artwork:Artwork,width:Double,height:Double,assets:URL,
    paperColor:String?=nil,paperOpacity:Double=1,maximumPixelSize:Int=200)->NSImage? {
    guard width.isFinite,height.isFinite,width>0,height>0,assets.isFileURL,(1...1024).contains(maximumPixelSize),
      paperOpacity.isFinite,(0...1).contains(paperOpacity),
      paperColor.map({$0.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil}) ?? true else{return nil}
    let directory=assets.standardizedFileURL
    var names:Set<String>
    do {
      names=try ArtworkRenderer.requiredImageAssets(artwork,assets:directory)
      // Linked frame text is deliberately absent from saved Artwork encoding.
      // Its paints still reference current portable assets through the story.
      var stories=Set<UUID>()
      for element in artwork.elements {
        if let story=element.storyFrame?.resolved,stories.insert(story.story.id).inserted {
          names.formUnion(try ArtworkRenderer.requiredImageAssets(Artwork(elements:[story.story.sourceElement]),assets:directory))
        }
      }
    }catch{return nil}
    var files:[String:String]=[:]
    for name in names {
      guard !name.isEmpty,!name.contains("/"),!name.contains("\\") else{return nil}
      // Content identity also catches a replacement with unchanged size/mtime.
      // Files are mapped, not copied into a second retained asset cache.
      files[name]=(try? Data(contentsOf:directory.appendingPathComponent(name),options:.mappedIfSafe))
        .map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? "unavailable"
    }
    let key:Key
    do {
      let signature=Signature(artwork:try JSONEncoder.form.encode(artwork),resolved:try artwork.renderCacheData(),
        width:width,height:height,assets:directory.absoluteString,paperColor:paperColor,paperOpacity:paperOpacity,maximumPixelSize:maximumPixelSize,
        fonts:fontRevision(),files:files)
      key=Key(projectID:projectID,objectID:objectID,signature:Data(SHA256.hash(data:try JSONEncoder.form.encode(signature))))
    }catch{return nil}
    clock &+= 1
    if var entry=entries[key] {entry.used=clock;entries[key]=entry;hitCount+=1;return entry.image}
    // The underlying raster decoder keys metadata by URL. A new exact source
    // must decode current bytes rather than retain a warm, same-path bitmap.
    for name in names {ImageRenderer.invalidate(directory.appendingPathComponent(name))}
    if !names.isEmpty {
      // These shared painter caches retain image-derived effects, coverage and
      // text paints without file-byte revisions. Other views can warm them too;
      // a private last-seen fingerprint would not establish their current state.
      // Hits and pure-vector misses leave all painter resources untouched.
      AppearanceRenderer.invalidateFonts();TextPaintRenderer.invalidateFonts()
    }
    renderCount+=1
    guard let image=renderer(.init(artwork:artwork,width:width,height:height,assets:directory,
      paperColor:paperColor,paperOpacity:paperOpacity,maximumPixelSize:maximumPixelSize)) else{return nil}
    let cost=image.representations.compactMap{$0 as? NSBitmapImageRep}.reduce(0){$0+$1.bytesPerRow*$1.pixelsHigh}
    let estimate=max(1,cost>0 ? cost:maximumPixelSize*maximumPixelSize*4)
    guard estimate<=maximumBytes else{return image}
    while entries.count>=capacity || retainedBytes+estimate>maximumBytes {
      guard let oldest=entries.min(by:{$0.value.used<$1.value.used}) else{break}
      retainedBytes-=oldest.value.cost;entries.removeValue(forKey:oldest.key)
    }
    entries[key] = .init(image:image,cost:estimate,used:clock);retainedBytes+=estimate
    return image
  }
  private static func render(_ value:Request)->NSImage? {
    let image=ArtworkRenderer.image(value.artwork,width:value.width,height:value.height,assets:value.assets,
      pixelsPerMM:Double(value.maximumPixelSize)/max(value.width,value.height),opaqueBackground:value.paperColor==nil)
    guard let color=value.paperColor else{return image}
    guard let source=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
      let context=CGContext(data:nil,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
    let bounds=CGRect(x:0,y:0,width:source.width,height:source.height)
    context.setFillColor(NSColor.white.cgColor);context.fill(bounds)
    context.setFillColor(FormColor.color(color).withAlphaComponent(value.paperOpacity).cgColor)
    context.fill(bounds);context.draw(source,in:bounds)
    guard let composed=context.makeImage() else{return nil}
    return NSImage(cgImage:composed,size:image.size)
  }
}

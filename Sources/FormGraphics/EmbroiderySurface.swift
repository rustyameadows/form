import AppKit
import CryptoKit
import FormCore

/// Physical-face maps made exclusively from the generated needle commands.
/// Travel and thread-control commands break runs and never become visible thread.
@MainActor public enum EmbroiderySurface {
  public static let maximumTextureEdge=1024
  public final class Resources:NSObject {
    public let program:EmbroideryProgram
    public let diffuse:NSImage
    public let normal:NSImage
    public let pixelsWide:Int
    public let pixelsHigh:Int
    init(program:EmbroideryProgram,diffuse:NSImage,normal:NSImage,width:Int,height:Int) {
      self.program=program;self.diffuse=diffuse;self.normal=normal;pixelsWide=width;pixelsHigh=height
    }
  }
  private final class Entry:NSObject {
    let result:Result<Resources,Error>
    init(_ result:Result<Resources,Error>) {self.result=result}
  }
  private static let cache:NSCache<NSString,Entry> = {
    let value=NSCache<NSString,Entry>();value.countLimit=8;value.totalCostLimit=32_000_000;return value
  }()
  public private(set) static var programBuilds=0
  public private(set) static var textureBuilds=0
  public static func invalidate() {cache.removeAllObjects()}
  public static func resources(object:ProductObject,project:Project,fontRevision:Int = 0,textureLimit:Int = 1024,sampling:SourceTextureRasterPlan?=nil)throws -> Resources {
    guard let design=object.textile?.embroidery,let art=project.surfaceArtwork(object) else {throw FormError.invalid("A physical embroidery surface needs saved digitizing settings and artwork.")}
    let size=object.artworkSize,edge=min(maximumTextureEdge,max(32,textureLimit))
    var signature=try JSONEncoder.form.encode(art.embroideryRenderDefinition)
    signature.append(try JSONEncoder.form.encode(design));if let sampling {signature.append(try JSONEncoder.form.encode(sampling))}
    signature.append(Data("\(size.x),\(size.y),\(object["corner"]),\(fontRevision),\(edge)".utf8))
    let key=SHA256.hash(data:signature).map {String(format:"%02x",$0)}.joined() as NSString
    if let entry=cache.object(forKey:key) {return try entry.result.get()}
    do {
      programBuilds+=1
      let program=try EmbroideryDigitizer.generate(object:object,project:project)
      let resources=try make(program:program,width:size.x,height:size.y,limit:edge,sampling:sampling)
      let cost=resources.pixelsWide*resources.pixelsHigh*16+program.commands.count*80
      cache.setObject(Entry(.success(resources)),forKey:key,cost:cost)
      return resources
    } catch {cache.setObject(Entry(.failure(error)),forKey:key,cost:1024);throw error}
  }
  public static func make(program:EmbroideryProgram,width:Double,height:Double,limit:Int = 1024,sampling:SourceTextureRasterPlan?=nil)throws -> Resources {
    try program.validate()
    guard width.isFinite,height.isFinite,(1...500).contains(width),(1...500).contains(height) else {throw FormError.invalid("Physical embroidery textures need a finite 1–500 mm face.")}
    let edge=min(maximumTextureEdge,max(32,limit)),scale=Double(edge)/max(width,height)
    let requested=try sampling?.rasterSize(width:width,height:height)
    let w=requested?.width ?? max(1,Int((width*scale).rounded())),h=requested?.height ?? max(1,Int((height*scale).rounded()))
    func context()->CGContext? {CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)}
    guard let color=context(),let heightMap=context(),let heightPixels=heightMap.data else {throw FormError.invalid("Could not allocate the bounded embroidery face maps.")}
    struct Run {var path:CGPath;var thread:Int}
    var runs:[Run]=[],path:CGMutablePath?,previous=Point2(),thread=0
    func finish() {if let path,!path.isEmpty {runs.append(.init(path:path,thread:thread))};path=nil}
    for command in program.commands {
      let point=command.point
      if command.action == .stitch {
        if path==nil || thread != command.threadIndex {finish();path=CGMutablePath();thread=command.threadIndex;path!.move(to:.init(x:previous.x,y:previous.y))}
        path!.addLine(to:.init(x:point.x,y:point.y))
      } else {finish()}
      previous=point
    }
    finish()
    let diameter=program.design.process?.threadDiameter ?? 0.22
    for context in [color,heightMap] {
      context.translateBy(x:Double(w)/2,y:Double(h)/2)
      context.scaleBy(x:Double(w)/width,y:-Double(h)/height)
      context.setLineCap(.round);context.setLineJoin(.round)
    }
    for run in runs {
      color.setStrokeColor(FormColor.color(program.design.threads[run.thread].color).cgColor)
      color.setLineWidth(diameter);color.addPath(run.path);color.strokePath()
    }
    // Three concentric bands approximate the cross-section of the same threads.
    // No fabric deformation, thread physics, or unrelated stitch texture is inferred.
    for (fraction,gray) in [(1.0,0.34),(0.72,0.72),(0.35,1.0)] {
      heightMap.setStrokeColor(CGColor(gray:gray,alpha:1));heightMap.setLineWidth(diameter*fraction)
      for run in runs {heightMap.addPath(run.path);heightMap.strokePath()}
    }
    guard let diffuseCG=color.makeImage(),let normalContext=context(),let normalPixels=normalContext.data else {throw FormError.invalid("Could not finish embroidery face maps.")}
    let heightBytes=heightPixels.assumingMemoryBound(to:UInt8.self),normalBytes=normalPixels.assumingMemoryBound(to:UInt8.self)
    let stride=w*4,physicalHeight=diameter*0.45
    func sample(_ x:Int,_ y:Int)->Double {Double(heightBytes[min(h-1,max(0,y))*stride+min(w-1,max(0,x))*4])/255}
    func channel(_ value:Double)->UInt8 {UInt8(max(0,min(255,(value*255).rounded())))}
    for y in 0..<h {for x in 0..<w {
      let dx=(sample(x+1,y)-sample(x-1,y))*physicalHeight*Double(w)/width/2
      let dy=(sample(x,y+1)-sample(x,y-1))*physicalHeight*Double(h)/height/2
      let length=sqrt(dx*dx+dy*dy+1),index=y*stride+x*4
      normalBytes[index]=channel(-dx/length*0.5+0.5)
      normalBytes[index+1]=channel(dy/length*0.5+0.5)
      normalBytes[index+2]=channel(1/length*0.5+0.5);normalBytes[index+3]=255
    }}
    guard let normalCG=normalContext.makeImage() else {throw FormError.invalid("Could not finish embroidery normals.")}
    func image(_ cg:CGImage)->NSImage {
      let image=NSImage(size:.init(width:w,height:h));image.addRepresentation(NSBitmapImageRep(cgImage:cg));return image
    }
    textureBuilds+=1
    return Resources(program:program,diffuse:image(diffuseCG),normal:image(normalCG),width:w,height:h)
  }
}

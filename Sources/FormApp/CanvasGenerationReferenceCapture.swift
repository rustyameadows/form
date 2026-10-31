import AppKit
import CryptoKit
import FormCore
import FormGraphics
import ImageIO
import UniformTypeIdentifiers

/// A live Canvas choice. Capture resolves it once at Generate; requests retain
/// the resulting bytes and hashes rather than rereading these IDs later.
struct CanvasGenerationReference:Codable,Equatable,Identifiable,Sendable {
  var objectID:UUID
  var elementIDs:[UUID]
  var title:String
  var id:String {objectID.uuidString+":"+elementIDs.map(\.uuidString).sorted().joined(separator:",")}
  init(objectID:UUID,elementIDs:[UUID]=[],title:String) {
    self.objectID=objectID;self.elementIDs=Array(Set(elementIDs)).sorted{$0.uuidString<$1.uuidString}
    self.title=Self.boundedTitle(title)
  }
  /// Labels combine separately bounded layer and artboard names. Keep the
  /// resulting historical label within provenance limits at every UI entry.
  static func boundedTitle(_ title:String)->String {
    var result="",bytes=0,characters=0
    for character in title.trimmingCharacters(in:.whitespacesAndNewlines) {
      let size=String(character).utf8.count
      guard characters<500,bytes+size<=2_000 else{break}
      result.append(character);bytes+=size;characters+=1
    }
    return result.isEmpty ? "Canvas reference":result
  }
}

struct CanvasGenerationReferenceImage:Sendable {
  let reference:CanvasGenerationReference
  let projectID:UUID
  let png:Data
  let sourceSHA256:String
  let pngSHA256:String
  let width:Int
  let height:Int
}

@MainActor enum CanvasGenerationReferenceCapture {
  static let maximumLongEdge=2048
  static let maximumSourceBytes=64*1024*1024
  static let maximumPNGBytes=32*1024*1024

  /// Read-only reference inventory. Locks protect editing, not capture. Hidden
  /// layers and component support definitions are not independent Canvas assets.
  static func choices(in project:Project)->[CanvasGenerationReference] {
    var result:[CanvasGenerationReference]=[]
    for object in project.objects where supported(object) {
      guard let art=project.editableArtwork(object) else{continue}
      if !object.isCanvasWorkspace {result.append(.init(objectID:object.id,title:object.name))}
      let byID=Dictionary(art.elements.map{($0.id,$0)},uniquingKeysWith:{$1})
      let masks=Set(art.elements.compactMap(\.clipID))
      for element in art.elements where ["image","group"].contains(element.kind)
        && visible(element,byID:byID,masks:masks) {
        let label=element.name?.trimmingCharacters(in:.whitespacesAndNewlines)
        result.append(.init(objectID:object.id,elementIDs:[element.id],
          title:(label?.isEmpty==false ? label!:element.kind.capitalized)+" · "+object.name))
      }
    }
    return result
  }

  static func capture(project:Project,repository:ProjectRepository,reference:CanvasGenerationReference,
    longEdge:Int=1024)throws->CanvasGenerationReferenceImage {
    try Task.checkCancellation()
    guard (1...maximumLongEdge).contains(longEdge),reference.elementIDs.count<=10_000,
      Set(reference.elementIDs).count==reference.elementIDs.count,
      let object=project.objects.first(where:{$0.id==reference.objectID}),supported(object),
      var art=project.editableArtwork(object) else{
      throw FormError.invalid("Choose an existing Canvas asset or artboard and a reference size up to 2048 pixels.")
    }
    guard !object.isCanvasWorkspace || !reference.elementIDs.isEmpty else{
      throw FormError.invalid("Choose an image or group on the Canvas, or choose a complete artboard.")
    }
    try validateArtwork(art,maxTextCharacters:100_000)
    let owner=project.artworkOwner(object)
    art=project.resolvingTextStories(in:art,objectID:owner.id)
    art=try project.resolvingComponents(in:art,keepingSwatchReferences:true)
    art=project.resolvingSwatches(in:art)
    let frame=object.artworkSize
    var width=frame.x,height=frame.y
    if !reference.elementIDs.isEmpty {
      let selected=Set(reference.elementIDs),byID=Dictionary(uniqueKeysWithValues:art.elements.map{($0.id,$0)})
      let masks=Set(art.elements.compactMap(\.clipID))
      guard selected.allSatisfy({id in byID[id].map{visible($0,byID:byID,masks:masks)} ?? false}) else{
        throw FormError.invalid("A Canvas reference was removed or hidden. Choose the visible artwork again.")
      }
      let exported=try art.exporting(selected)
      art=exported.artwork
      var bounds=exported.bounds
      if !object.isCanvasWorkspace {
        let left=max(0,bounds.x),top=max(0,bounds.y)
        let right=min(frame.x,bounds.maxX),bottom=min(frame.y,bounds.maxY)
        guard right>left,bottom>top else{throw FormError.invalid("The selected reference is outside its artboard.")}
        let cropped=Rect2(left,top,right-left,bottom-top)
        translate(&art,dx:bounds.x-cropped.x,dy:bounds.y-cropped.y)
        bounds=cropped
      }
      width=bounds.width;height=bounds.height
      // An asset carries its own transparency. Full artboards retain their
      // declared background and trim boundary above.
      art.backgroundOpacity=0
    }
    guard width.isFinite,height.isFinite,width>0,height>0,width<=1_000_000,height<=1_000_000 else{
      throw FormError.invalid("The Canvas reference needs finite, nonempty bounds.")
    }
    // Capture what is visible on Canvas, including non-print production roles.
    // This is an appearance preview, never a production-ink output.
    for index in art.elements.indices {art.elements[index].productionRole=nil}
    art=try BooleanGeometry.materialized(art).renderDefinition
    art.requiresInkOutput=false;art.outputColorProfile=nil
    try validateArtwork(art,maxTextCharacters:100_000)
    let density=Double(longEdge)/max(width,height)
    guard density.isFinite,density>0,(width*density).isFinite,(height*density).isFinite else{
      throw FormError.invalid("The Canvas reference bounds cannot be represented at this resolution.")
    }
    let pixelsWide=max(1,Int((width*density).rounded())),pixelsHigh=max(1,Int((height*density).rounded()))
    let sourceAssets=repository.url(for:project.id).appendingPathComponent("Assets",isDirectory:true)
    let frozenAssets=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-reference-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:frozenAssets,withIntermediateDirectories:true)
    defer{try? FileManager.default.removeItem(at:frozenAssets)}
    var bytes=0,assets:[AssetFingerprint]=[]
    let stories=Dictionary(art.elements.compactMap{$0.storyFrame?.resolved}.map{($0.story.id,$0)},uniquingKeysWith:{$1})
      .values.sorted{$0.story.id.uuidString<$1.story.id.uuidString}
    let requiredAssets=stories.reduce(into:art.renderedAssetNames){$0.formUnion($1.story.sourceElement.renderedAssetNames)}
    if !requiredAssets.isEmpty {
      let attributes=try sourceAssets.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
      guard attributes.isDirectory==true,attributes.isSymbolicLink != true else{
        throw FormError.invalid("Canvas references need the project's regular Assets directory.")
      }
    }
    let root=sourceAssets.resolvingSymlinksInPath().standardizedFileURL.path+"/"
    for name in requiredAssets.sorted() {
      try Task.checkCancellation()
      guard !name.isEmpty,!name.contains("/"),!name.contains("\\"),name != ".",name != ".." else{
        throw FormError.invalid("A Canvas reference has an invalid asset filename.")
      }
      let file=sourceAssets.appendingPathComponent(name)
      let attributes=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
      guard attributes.isRegularFile==true,attributes.isSymbolicLink != true,
        file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
        let size=attributes.fileSize,size>0,size<=maximumSourceBytes-bytes else{
        throw FormError.invalid("Reference assets must be regular project files totaling at most 64 MB.")
      }
      let data=try Data(contentsOf:file,options:.mappedIfSafe)
      guard data.count>0,data.count<=maximumSourceBytes-bytes else{
        throw FormError.invalid("Reference assets exceed the 64 MB capture budget.")
      }
      bytes+=data.count;assets.append(.init(name:name,sha256:hash(data)))
      try data.write(to:frozenAssets.appendingPathComponent(name),options:.atomic)
    }
    let fingerprint=Fingerprint(projectID:project.id,objectID:object.id,elementIDs:reference.elementIDs.sorted{$0.uuidString<$1.uuidString},
      artwork:art.renderDefinition,stories:stories,width:width,height:height,assets:assets)
    let sourceHash=hash(try JSONEncoder.form.encode(fingerprint))
    try ArtworkRenderer.validateAppearanceOutput(art,assets:frozenAssets,pixelsPerMM:density)
    try Task.checkCancellation()
    guard let colorSpace=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:pixelsWide,height:pixelsHigh,
      bitsPerComponent:8,bytesPerRow:0,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{
      throw FormError.invalid("Could not allocate the bounded Canvas reference image.")
    }
    context.translateBy(x:0,y:Double(pixelsHigh));context.scaleBy(x:density,y:-density)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    ArtworkRenderer.draw(art,width:width,height:height,assets:frozenAssets,production:false,effectScale:density)
    NSGraphicsContext.restoreGraphicsState()
    try Task.checkCancellation()
    guard let image=context.makeImage() else{throw FormError.invalid("Could not render the Canvas reference.")}
    let output=NSMutableData()
    guard let destination=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else{
      throw FormError.invalid("Could not encode the Canvas reference.")
    }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination),output.length<=maximumPNGBytes else{
      throw FormError.invalid("The Canvas reference PNG exceeds its 32 MB limit.")
    }
    let png=output as Data
    return .init(reference:reference,projectID:project.id,png:png,sourceSHA256:sourceHash,pngSHA256:hash(png),width:pixelsWide,height:pixelsHigh)
  }

  private static func supported(_ object:ProductObject)->Bool {
    (object.isCanvasWorkspace || object.recipeID=="artboard") && object.canvasSourceOnly != true
      && object.componentDefinition != true && object.artworkSourceID==nil
  }
  private static func visible(_ element:ArtworkElement,byID:[UUID:ArtworkElement],masks:Set<UUID>)->Bool {
    var current:ArtworkElement?=element,visited=Set<UUID>()
    while let value=current {
      guard visited.insert(value.id).inserted,value.hidden != true,(value.opacity ?? 1)>0,!masks.contains(value.id) else{return false}
      current=value.parentID.flatMap{byID[$0]}
    }
    return true
  }
  private static func translate(_ art:inout Artwork,dx:Double,dy:Double) {
    for index in art.elements.indices where art.elements[index].parentID==nil {
      ArtworkCommands.translate(&art.elements[index],dx:dx,dy:dy)
    }
    if var boundary=art.boundary {
      for index in boundary.contours.indices {
        boundary.contours[index].nodes=boundary.contours[index].nodes.map{PathCommands.transformed($0,by:.translation(dx,dy))}
      }
      art.boundary=boundary
    }
  }
  private struct AssetFingerprint:Codable {let name:String;let sha256:String}
  private struct Fingerprint:Codable {
    let projectID:UUID;let objectID:UUID;let elementIDs:[UUID];let artwork:Artwork;let stories:[ResolvedTextStory]
    let width:Double;let height:Double;let assets:[AssetFingerprint]
  }
  private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}

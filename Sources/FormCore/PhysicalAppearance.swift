import Foundation
import CryptoKit

/// Portable, renderer-independent viewing intent. These values do not certify a
/// manufacturing material or claim measured optical response.
public struct PhysicalAppearance: Codable, Equatable, Sendable {
  public var ior: Double = 1.5
  public var diffuseTransmission: Double = 0
  public var transmission: Double = 0
  public var subsurface: Double = 0
  public var subsurfaceRadiusMM: Vector3 = .init(1, 0.2, 0.1)
  public var sheen: Double = 0
  public var sheenRoughness: Double = 0.5
  public var sheenTint: String = "#FFFFFF"
  public var anisotropy: Double = 0
  /// Turns around the surface tangent, independently of texture rotation.
  public var anisotropyRotation: Double = 0
  public var coat: Double = 0
  public var coatRoughness: Double = 0.03
  public var bumpStrength: Double = 1
  public var normalStrength: Double = 1
  public var displacementScaleMM: Double = 0
  public var displacementMidlevel: Double = 0.5
  /// Keys are PhysicalTextureChannel raw values; string keys keep JSON portable.
  public var textures: [String: PhysicalTextureReference] = [:]
  public init() {}
  public func validate() throws {
    guard ior.isFinite, (1...4).contains(ior), bumpStrength.isFinite, (0...10).contains(bumpStrength), normalStrength.isFinite, (0...10).contains(normalStrength),
      displacementScaleMM.isFinite, (-100...100).contains(displacementScaleMM),
      [diffuseTransmission,transmission,subsurface,sheen,sheenRoughness,anisotropy,anisotropyRotation,coat,coatRoughness,displacementMidlevel].allSatisfy({$0.isFinite && (0...1).contains($0)}),
      [subsurfaceRadiusMM.x,subsurfaceRadiusMM.y,subsurfaceRadiusMM.z].allSatisfy({$0.isFinite && (0.001...1000).contains($0)}),
      textures.count <= PhysicalTextureChannel.allCases.count else {throw FormError.invalid("Physical appearance requires finite bounded optical values and millimeter displacement/scattering distances.")}
    try validateColor(sheenTint)
    for (channel,texture) in textures {
      guard let kind=PhysicalTextureChannel(rawValue:channel) else {throw FormError.invalid("Unknown physical texture channel: \(channel).")}
      try texture.validate()
      if ![.baseColor,.emission,.sheenTint].contains(kind),texture.colorSpace != .data {throw FormError.invalid("Scalar, normal and displacement maps must use data color space.")}
    }
  }
  private enum CodingKeys:String,CodingKey {case ior,diffuseTransmission,transmission,subsurface,subsurfaceRadiusMM,sheen,sheenRoughness,sheenTint,anisotropy,anisotropyRotation,coat,coatRoughness,bumpStrength,normalStrength,displacementScaleMM,displacementMidlevel,textures}
  public init(from decoder:Decoder)throws {
    self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
    ior=try c.decodeIfPresent(Double.self,forKey:.ior) ?? ior
    diffuseTransmission=try c.decodeIfPresent(Double.self,forKey:.diffuseTransmission) ?? diffuseTransmission
    transmission=try c.decodeIfPresent(Double.self,forKey:.transmission) ?? transmission
    subsurface=try c.decodeIfPresent(Double.self,forKey:.subsurface) ?? subsurface
    subsurfaceRadiusMM=try c.decodeIfPresent(Vector3.self,forKey:.subsurfaceRadiusMM) ?? subsurfaceRadiusMM
    sheen=try c.decodeIfPresent(Double.self,forKey:.sheen) ?? sheen
    sheenRoughness=try c.decodeIfPresent(Double.self,forKey:.sheenRoughness) ?? sheenRoughness
    sheenTint=try c.decodeIfPresent(String.self,forKey:.sheenTint) ?? sheenTint
    anisotropy=try c.decodeIfPresent(Double.self,forKey:.anisotropy) ?? anisotropy
    anisotropyRotation=try c.decodeIfPresent(Double.self,forKey:.anisotropyRotation) ?? anisotropyRotation
    coat=try c.decodeIfPresent(Double.self,forKey:.coat) ?? coat
    coatRoughness=try c.decodeIfPresent(Double.self,forKey:.coatRoughness) ?? coatRoughness
    bumpStrength=try c.decodeIfPresent(Double.self,forKey:.bumpStrength) ?? bumpStrength
    normalStrength=try c.decodeIfPresent(Double.self,forKey:.normalStrength) ?? normalStrength
    displacementScaleMM=try c.decodeIfPresent(Double.self,forKey:.displacementScaleMM) ?? displacementScaleMM
    displacementMidlevel=try c.decodeIfPresent(Double.self,forKey:.displacementMidlevel) ?? displacementMidlevel
    textures=try c.decodeIfPresent([String:PhysicalTextureReference].self,forKey:.textures) ?? textures
  }
}

public enum PhysicalTextureChannel:String,Codable,CaseIterable,Sendable {
  case baseColor,roughness,metallic,normal,bump,displacement,emission,diffuseTransmission,transmission,subsurface,sheen,sheenTint,anisotropy,coat
}
public struct PhysicalTextureReference:Codable,Equatable,Sendable {
  public enum ColorSpace:String,Codable,Sendable {case srgb,linearSRGB,data}
  public enum Wrap:String,Codable,Sendable {case `repeat`,clamp,mirror}
  public var asset:String
  public var sha256:String
  public var colorSpace:ColorSpace
  public var uvIndex:Int = 0
  public var wrapS:Wrap = .repeat
  public var wrapT:Wrap = .repeat
  public var scale:Point2 = .init(1,1)
  public var offset:Point2 = .init()
  public var rotationDegrees:Double = 0
  /// Physical size covered by one repeat; nil retains mesh UV coordinates.
  public var scaleMM:Point2?
  public init(asset:String,sha256:String,colorSpace:ColorSpace = .data) {self.asset=asset;self.sha256=sha256;self.colorSpace=colorSpace}
  public func validate()throws {
    guard !asset.isEmpty,asset.utf8.count<=240,asset==URL(fileURLWithPath:asset).lastPathComponent,!asset.contains(".."),!asset.contains("/"),!asset.contains("\\"),
      sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,(0...1).contains(uvIndex),
      [scale.x,scale.y].allSatisfy({$0.isFinite && (0.000001...1000000).contains($0)}),
      [offset.x,offset.y,rotationDegrees].allSatisfy({$0.isFinite && abs($0)<=1_000_000}) else {throw FormError.invalid("A texture needs a portable asset name, SHA-256 and finite independent UV mapping.")}
    if let size=scaleMM {guard [size.x,size.y].allSatisfy({$0.isFinite && (0.001...100000).contains($0)}) else {throw FormError.invalid("Texture repeat dimensions must be 0.001–100000 mm.")}}
  }
  public func verifiedURL(in assets:URL)throws->URL {
    try validate();let url=assets.appendingPathComponent(asset)
    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? 0)>0,(values.fileSize ?? 0)<=268_435_456 else {throw FormError.invalid("The material texture is missing or exceeds 256 MiB.")}
    let digest=SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
    guard digest==sha256 else {throw FormError.invalid("The material texture hash does not match its saved reference.")};return url
  }
  private enum CodingKeys:String,CodingKey {case asset,sha256,colorSpace,uvIndex,wrapS,wrapT,scale,offset,rotationDegrees,scaleMM}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    asset=try c.decode(String.self,forKey:.asset);sha256=try c.decode(String.self,forKey:.sha256)
    colorSpace=try c.decodeIfPresent(ColorSpace.self,forKey:.colorSpace) ?? .data
    uvIndex=try c.decodeIfPresent(Int.self,forKey:.uvIndex) ?? 0
    wrapS=try c.decodeIfPresent(Wrap.self,forKey:.wrapS) ?? .repeat;wrapT=try c.decodeIfPresent(Wrap.self,forKey:.wrapT) ?? .repeat
    scale=try c.decodeIfPresent(Point2.self,forKey:.scale) ?? .init(1,1);offset=try c.decodeIfPresent(Point2.self,forKey:.offset) ?? .init()
    rotationDegrees=try c.decodeIfPresent(Double.self,forKey:.rotationDegrees) ?? 0;scaleMM=try c.decodeIfPresent(Point2.self,forKey:.scaleMM)
  }
}

/// Links are evidence, never commands or calibration inferred from a photograph.
public struct MaterialReference:Codable,Equatable,Sendable {
  public enum Evidence:String,Codable,Sendable {case photograph,manufacturerSpecification,measured,estimated}
  public var title:String
  public var url:String?
  public var asset:String?
  public var license:String?
  public var evidence:Evidence
  public var notes:String
  public init(title:String,url:String?=nil,asset:String?=nil,license:String?=nil,evidence:Evidence = .estimated,notes:String="") {self.title=title;self.url=url;self.asset=asset;self.license=license;self.evidence=evidence;self.notes=notes}
  public func validate()throws {
    guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=256,notes.utf8.count<=8192,(license?.utf8.count ?? 0)<=1024 else {throw FormError.invalid("Use bounded material reference titles and notes.")}
    if let url {guard url.utf8.count<=4096,let parsed=URL(string:url),["https","http"].contains(parsed.scheme?.lowercased() ?? ""),parsed.host != nil,parsed.user==nil,parsed.password==nil else {throw FormError.invalid("Material reference links must be HTTP(S) URLs without credentials.")}}
    if let asset {guard !asset.isEmpty,asset.utf8.count<=240,!asset.contains(".."),!asset.contains("/"),!asset.contains("\\") else {throw FormError.invalid("Reference assets must use portable project filenames.")}}
  }
  private enum CodingKeys:String,CodingKey {case title,url,asset,license,evidence,notes}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self);title=try c.decode(String.self,forKey:.title)
    url=try c.decodeIfPresent(String.self,forKey:.url);asset=try c.decodeIfPresent(String.self,forKey:.asset);license=try c.decodeIfPresent(String.self,forKey:.license)
    evidence=try c.decodeIfPresent(Evidence.self,forKey:.evidence) ?? .estimated;notes=try c.decodeIfPresent(String.self,forKey:.notes) ?? ""
  }
}

public struct PhysicalAreaLight:Codable,Equatable,Identifiable,Sendable {
  public enum Shape:String,Codable,CaseIterable,Sendable {case rectangle,disk}
  public var id:UUID = UUID()
  public var positionMM:Vector3 = .init(-300,500,300)
  public var targetMM:Vector3 = .init()
  public var sizeMM:Point2 = .init(300,300)
  public var color:String = "#FFFFFF"
  public var powerWatts:Double = 3
  public var shape:Shape = .rectangle
  public init(){}
  public func validate()throws {
    try validateColor(color)
    guard [positionMM.x,positionMM.y,positionMM.z,targetMM.x,targetMM.y,targetMM.z].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),
      [sizeMM.x,sizeMM.y].allSatisfy({$0.isFinite && (0.1...100_000).contains($0)}),powerWatts.isFinite,(0...1_000_000).contains(powerWatts),positionMM != targetMM else {throw FormError.invalid("Area lights require distinct finite position/target, millimeter dimensions and nonnegative watts.")}
  }
  private enum CodingKeys:String,CodingKey {case id,positionMM,targetMM,sizeMM,color,powerWatts,shape}
  public init(from decoder:Decoder)throws {
    self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? id;positionMM=try c.decodeIfPresent(Vector3.self,forKey:.positionMM) ?? positionMM
    targetMM=try c.decodeIfPresent(Vector3.self,forKey:.targetMM) ?? targetMM;sizeMM=try c.decodeIfPresent(Point2.self,forKey:.sizeMM) ?? sizeMM
    color=try c.decodeIfPresent(String.self,forKey:.color) ?? color;powerWatts=try c.decodeIfPresent(Double.self,forKey:.powerWatts) ?? powerWatts;shape=try c.decodeIfPresent(Shape.self,forKey:.shape) ?? shape
  }
}
public struct CyclesRenderSettings:Codable,Equatable,Sendable {
  public enum Renderer:String,Codable,CaseIterable,Sendable {case realtime,cycles}
  public enum Device:String,Codable,CaseIterable,Sendable {case automatic,metal,cpu}
  public var renderer:Renderer = .cycles
  public var device:Device = .metal
  public var samples:Int = 512
  public var previewSamples:Int = 64
  public var noiseThreshold:Double = 0.01
  public var denoise:Bool = true
  public var maxBounces:Int = 12
  public var displacementDicingRate:Double = 2
  public var displacementMaxTriangles:Int = 2_000_000
  public var displacementMaxSubdivisions:Int = 10
  public var exposure:Double = 0
  public var depthOfField:Bool = false
  public var fStop:Double = 5.6
  public var focusDistanceMM:Double = 1000
  /// Nil retains the selected studio preset; an empty array removes area lights.
  public var areaLights:[PhysicalAreaLight]?
  public var environmentColor:String = "#FFFFFF"
  public var environmentStrength:Double = 0.1
  public var environmentTexture:PhysicalTextureReference?
  public var environmentRotationDegrees:Double = 0
  public init(){}
  public static func validateFields(_ raw:Any)throws {
    if raw is NSNull{return}
    guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:["renderer","device","samples","previewSamples","noiseThreshold","denoise","maxBounces","displacementDicingRate","displacementMaxTriangles","displacementMaxSubdivisions","exposure","depthOfField","fStop","focusDistanceMM","areaLights","environmentColor","environmentStrength","environmentTexture","environmentRotationDegrees"]) else {throw FormError.invalid("Unknown render setting.")}
    if let raw=object["areaLights"],!(raw is NSNull) {
      guard let lights=raw as? [[String:Any]],lights.count<=64 else {throw FormError.invalid("Use at most 64 area lights.")}
      for light in lights {
        guard Set(light.keys).isSubset(of:["id","positionMM","targetMM","sizeMM","color","powerWatts","shape"]) else {throw FormError.invalid("Unknown area light setting.")}
        for key in ["positionMM","targetMM"] {if let raw=light[key] {guard let value=raw as? [String:Any],Set(value.keys)==["x","y","z"] else {throw FormError.invalid("Area light positions need x, y and z millimeters.")}}}
        if let raw=light["sizeMM"] {guard let value=raw as? [String:Any],Set(value.keys)==["x","y"] else {throw FormError.invalid("Area light size needs x and y millimeters.")}}
      }
    }
    if let texture=object["environmentTexture"],!(texture is NSNull) {try MaterialCommands.validateAppearanceFields(["textures":["baseColor":texture]])}
  }
  public func validate()throws {
    guard (1...4096).contains(samples),(1...512).contains(previewSamples),noiseThreshold.isFinite,(0...1).contains(noiseThreshold),(1...64).contains(maxBounces),exposure.isFinite,(-20...20).contains(exposure),fStop.isFinite,(0.5...128).contains(fStop),focusDistanceMM.isFinite,(0.1...1_000_000).contains(focusDistanceMM) else {throw FormError.invalid("Use bounded Cycles samples, bounces, exposure and physical camera settings.")}
    guard displacementDicingRate.isFinite,(0.25...64).contains(displacementDicingRate),(1...2_000_000).contains(displacementMaxTriangles),(0...10).contains(displacementMaxSubdivisions) else {throw FormError.invalid("Use 0.25–64 pixel displacement dicing, 1–2000000 generated triangles and 0–10 subdivision levels.")}
    try validateColor(environmentColor);try environmentTexture?.validate()
    guard environmentStrength.isFinite,(0...1000).contains(environmentStrength),environmentRotationDegrees.isFinite,abs(environmentRotationDegrees)<=36000,(areaLights?.count ?? 0)<=64,Set((areaLights ?? []).map(\.id)).count==(areaLights?.count ?? 0),environmentTexture?.colorSpace != .data else {throw FormError.invalid("Use finite environment settings, a color environment map and up to 64 unique area lights.")}
    for light in areaLights ?? [] {try light.validate()}
  }
  private enum CodingKeys:String,CodingKey {case renderer,device,samples,previewSamples,noiseThreshold,denoise,maxBounces,displacementDicingRate,displacementMaxTriangles,displacementMaxSubdivisions,exposure,depthOfField,fStop,focusDistanceMM,areaLights,environmentColor,environmentStrength,environmentTexture,environmentRotationDegrees}
  public init(from decoder:Decoder)throws {
    self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
    renderer=try c.decodeIfPresent(Renderer.self,forKey:.renderer) ?? renderer;device=try c.decodeIfPresent(Device.self,forKey:.device) ?? device
    samples=try c.decodeIfPresent(Int.self,forKey:.samples) ?? samples;previewSamples=try c.decodeIfPresent(Int.self,forKey:.previewSamples) ?? previewSamples
    noiseThreshold=try c.decodeIfPresent(Double.self,forKey:.noiseThreshold) ?? noiseThreshold;denoise=try c.decodeIfPresent(Bool.self,forKey:.denoise) ?? denoise
    maxBounces=try c.decodeIfPresent(Int.self,forKey:.maxBounces) ?? maxBounces;exposure=try c.decodeIfPresent(Double.self,forKey:.exposure) ?? exposure
    displacementDicingRate=try c.decodeIfPresent(Double.self,forKey:.displacementDicingRate) ?? displacementDicingRate
    displacementMaxTriangles=try c.decodeIfPresent(Int.self,forKey:.displacementMaxTriangles) ?? displacementMaxTriangles
    displacementMaxSubdivisions=try c.decodeIfPresent(Int.self,forKey:.displacementMaxSubdivisions) ?? displacementMaxSubdivisions
    depthOfField=try c.decodeIfPresent(Bool.self,forKey:.depthOfField) ?? depthOfField;fStop=try c.decodeIfPresent(Double.self,forKey:.fStop) ?? fStop;focusDistanceMM=try c.decodeIfPresent(Double.self,forKey:.focusDistanceMM) ?? focusDistanceMM
    areaLights=try c.decodeIfPresent([PhysicalAreaLight].self,forKey:.areaLights);environmentColor=try c.decodeIfPresent(String.self,forKey:.environmentColor) ?? environmentColor
    environmentStrength=try c.decodeIfPresent(Double.self,forKey:.environmentStrength) ?? environmentStrength;environmentTexture=try c.decodeIfPresent(PhysicalTextureReference.self,forKey:.environmentTexture)
    environmentRotationDegrees=try c.decodeIfPresent(Double.self,forKey:.environmentRotationDegrees) ?? environmentRotationDegrees
  }
}

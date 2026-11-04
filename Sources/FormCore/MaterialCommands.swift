import Foundation
import CryptoKit
import ImageIO

extension Material {
  var usesPhysicalAppearance:Bool {appearance != nil || backSurface != nil || references != nil || paperStock?.usesPhysicalAppearance == true}
  public func validatePhysicalAppearance()throws {
    guard !id.isEmpty,id.utf8.count<=200,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=256,category.utf8.count<=128,
      roughness.isFinite,(0...1).contains(roughness),metallic.isFinite,(0...1).contains(metallic),thickness.isFinite,(0...10000).contains(thickness),
      (references?.count ?? 0)<=64 else {throw FormError.invalid("A material needs a bounded identity, name, color and physical surface values.")}
    try validateColor(color);try appearance?.validate();try backSurface?.validate();try fabric?.validate();try paperStock?.validate()
    for reference in references ?? [] {try reference.validate()}
  }
}
extension PaperStock {
  var usesPhysicalAppearance:Bool {profile?.appearance != nil || plies?.contains(where:{$0.profile?.appearance != nil}) == true}
}
extension SheetPanelFeatures {
  var usesPhysicalAppearance:Bool {
    wrap?.stock.usesPhysicalAppearance == true || recesses?.contains(where:{$0.insert?.stock.usesPhysicalAppearance == true}) == true
  }
}
extension ProductObject {
  var usesPhysicalAppearance:Bool {
    if textile?.embroidery?.threads.contains(where:{$0.appearance != nil || $0.roughness != nil}) == true || patternAssembly?.panels.contains(where:{$0.material.usesPhysicalAppearance}) == true {return true}
    if paperConstruction?.stock.usesPhysicalAppearance == true || paperConstruction?.finishes?.contains(where:{$0.appearance != nil}) == true || paperConstruction?.authored?.panels.contains(where:{$0.features?.usesPhysicalAppearance == true}) == true {return true}
    guard let sheet=sheetAssembly else {return false}
    return sheet.stock.usesPhysicalAppearance || sheet.leaves?.contains(where:{$0.stock?.usesPhysicalAppearance == true || $0.finishes?.contains(where:{$0.appearance != nil}) == true}) == true || sheet.enclosure?.contains(where:{$0.stock.usesPhysicalAppearance || $0.finishes?.contains(where:{$0.appearance != nil}) == true || $0.features?.usesPhysicalAppearance == true}) == true || sheet.parentSheets?.contains(where:{$0.stock.usesPhysicalAppearance}) == true || sheet.auxiliaryLeaves?.contains(where:{$0.stock.usesPhysicalAppearance}) == true
  }
}
extension Project {
  public func validatePhysicalMaterials()throws {
    guard materials.count<=4096,Set(materials.map(\.id)).count==materials.count else {throw FormError.invalid("A project supports up to 4096 uniquely identified materials.")}
    for material in materials {try material.validatePhysicalAppearance()}
  }
}

public enum MaterialCommands {
  public static let readOnlyNames:Set<String>=["list","get"]
  public static let appearanceKeys:Set<String>=["ior","diffuseTransmission","transmission","subsurface","subsurfaceRadiusMM","sheen","sheenRoughness","sheenTint","anisotropy","anisotropyRotation","coat","coatRoughness","bumpStrength","normalStrength","displacementScaleMM","displacementMidlevel","textures"]
  public static func validateAppearanceFields(_ raw:Any)throws {
    if raw is NSNull{return}
    guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:appearanceKeys) else {throw FormError.invalid("Unknown physical appearance field.")}
    if let raw=object["subsurfaceRadiusMM"] {guard let vector=raw as? [String:Any],Set(vector.keys)==["x","y","z"] else {throw FormError.invalid("Scattering radius needs x, y and z millimeters.")}}
    if let raw=object["textures"] {
      guard let textures=raw as? [String:Any],textures.count<=PhysicalTextureChannel.allCases.count else {throw FormError.invalid("Use a bounded dictionary of material textures.")}
      for (channel,raw) in textures {
        guard PhysicalTextureChannel(rawValue:channel) != nil,let texture=raw as? [String:Any],Set(texture.keys).isSubset(of:["asset","sha256","colorSpace","uvIndex","wrapS","wrapT","scale","offset","rotationDegrees","scaleMM"]) else {throw FormError.invalid("Unknown material texture channel or field.")}
        for key in ["scale","offset","scaleMM"] {if let raw=texture[key],!(raw is NSNull) {guard let vector=raw as? [String:Any],Set(vector.keys)==["x","y"] else {throw FormError.invalid("Texture mapping \(key) needs x and y values.")}}}
      }
    }
  }
  public static func call(engine:OperationEngine,arguments args:[String:Any],source:String)throws->Any {
    guard let project=engine.project,let command=args["command"] as? String else {throw FormError.invalid("Open a project and choose a material command.")}
    let library=StudioLibrary.load(from:engine.repository.root).materials
    let materials=project.materials+library.filter{item in !project.materials.contains(where:{$0.id==item.id})}
    if command=="list" {guard args.count==1 else {throw FormError.invalid("List accepts command only.")};return try jsonObject(materials)}
    if command=="import_texture" {return try importTexture(engine:engine,args:args)}
    guard Set(args.keys).isSubset(of:["command","material_id","material","patch"]) else {throw FormError.invalid("Unknown material command arguments.")}
    if command=="get" {
      guard args.count==2,let id=args["material_id"] as? String,let material=materials.first(where:{$0.id==id}) else {throw FormError.missing("Choose an existing project or Lab material.")};return try jsonObject(material)
    }
    let material:Material
    if command=="create" {
      guard args.count==2,var raw=args["material"] as? [String:Any],Set(raw.keys).isSubset(of:["id","name","category","color","roughness","metallic","thickness","fabric","paperStock","appearance","backSurface","references"]) else {throw FormError.invalid("Create accepts a portable material definition.")}
      if raw["id"]==nil {raw["id"]="material-"+UUID().uuidString.lowercased()}
      for (key,value) in ["roughness":0.65,"metallic":0.0,"thickness":0.3] where raw[key]==nil {raw[key]=value}
      if raw["category"]==nil {raw["category"]="Surface"}
      try validateFields(raw)
      material=try JSONDecoder.form.decode(Material.self,from:JSONSerialization.data(withJSONObject:raw))
      guard !project.materials.contains(where:{$0.id==material.id}) else {throw FormError.invalid("Material ID already exists; use update.")}
    } else if command=="update" {
      guard args.count==3,let id=args["material_id"] as? String,let old=materials.first(where:{$0.id==id}),let patch=args["patch"] as? [String:Any],!patch.isEmpty,Set(patch.keys).isSubset(of:["name","category","color","roughness","metallic","thickness","appearance","backSurface","references"]) else {throw FormError.invalid("Update needs a material_id and a nonempty patch; Lab materials become a local project snapshot.")}
      try validateFields(patch)
      var raw=try jsonObject(old) as! [String:Any]
      for (key,value) in patch {raw[key]=value}
      material=try JSONDecoder.form.decode(Material.self,from:JSONSerialization.data(withJSONObject:raw))
    }else {throw FormError.invalid("Use list, get, create, update or import_texture.")}
    try material.validatePhysicalAppearance()
    let assets=engine.repository.url(for:project.id).appendingPathComponent("Assets")
    for appearance in [material.appearance,material.backSurface?.appearance].compactMap({$0}) {
      for texture in appearance.textures.values {_ = try texture.verifiedURL(in:assets)}
    }
    try engine.edit(command=="create" ? "Created material":"Updated material",source:source) {value in
      if let index=value.materials.firstIndex(where:{$0.id==material.id}) {value.materials[index]=material}else {value.materials.append(material)}
    }
    return try jsonObject(material)
  }
  private static func validateFields(_ raw:[String:Any])throws {
    guard JSONSerialization.isValidJSONObject(raw) else {throw FormError.invalid("Material edits require finite JSON values.")}
    if let appearance=raw["appearance"] {try validateAppearanceFields(appearance)}
    if let stock=raw["paperStock"],!(stock is NSNull) {_ = try PaperAppearanceCommands.stock(stock,previous:.init())}
    if let back=raw["backSurface"],!(back is NSNull) {
      guard let value=back as? [String:Any],Set(value.keys).isSubset(of:["color","roughness","metallic","appearance"]),["color","roughness","metallic"].allSatisfy({value[$0] != nil}) else {throw FormError.invalid("A reverse surface needs color, roughness and metallic, with an optional physical appearance.")}
      if let appearance=value["appearance"] {try validateAppearanceFields(appearance)}
    }
    if let references=raw["references"],!(references is NSNull) {
      guard let values=references as? [[String:Any]],values.count<=64,values.allSatisfy({Set($0.keys).isSubset(of:["title","url","asset","license","evidence","notes"])}) else {throw FormError.invalid("Use bounded material reference records.")}
    }
  }
  /// Content-addressed immutable Assets bytes; attaching the returned reference
  /// is an ordinary separately undoable material edit.
  private static func importTexture(engine:OperationEngine,args:[String:Any])throws->Any {
    guard Set(args.keys).isSubset(of:["command","path","color_space","max_dimension"]),let path=args["path"] as? String,path.hasPrefix("/"),let project=engine.project else {throw FormError.invalid("Texture import requires an absolute local image path.")}
    var maximum:Int?
    if let raw=args["max_dimension"] {
      guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,
        number.doubleValue.rounded()==number.doubleValue,(1...4096).contains(number.doubleValue) else {throw FormError.invalid("max_dimension must be an integer from 1 to 4096.")}
      maximum=number.intValue
    }
    let url=URL(fileURLWithPath:path),values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
    guard values.isRegularFile==true,(values.fileSize ?? 0)>0,(values.fileSize ?? 0)<=268_435_456,["png","jpg","jpeg","tif","tiff","exr","hdr"].contains(url.pathExtension.lowercased()) else {throw FormError.invalid("Choose a PNG, JPEG, TIFF, EXR or HDR image no larger than 256 MiB.")}
    let originalBytes=try Data(contentsOf:url,options:.mappedIfSafe)
    guard originalBytes.count<=268_435_456,let source=CGImageSourceCreateWithData(originalBytes as CFData,nil),CGImageSourceGetCount(source)==1,
      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width>0,height>0,width<=8192,height<=8192,
      width*height <= (maximum==nil ? 16_777_216:33_554_432) else {throw FormError.invalid(maximum==nil ? "Material maps require one decodable image, at most 8192 pixels per edge and 16 megapixels. Choose an import size (max_dimension) to resize a source up to 32 megapixels.":"Resized material maps require one decodable source image at most 8192 pixels per edge and 32 megapixels. Choose a smaller source image.")}
    guard let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) else {throw FormError.invalid("The material image could not be decoded.")}
    let encoding:PhysicalTextureReference.ColorSpace
    if let raw=args["color_space"] {guard let value=raw as? String,let parsed=PhysicalTextureReference.ColorSpace(rawValue:value) else {throw FormError.invalid("Use srgb, linearSRGB or data color space.")};encoding=parsed}else {encoding = .data}
    let originalDigest=SHA256.hash(data:originalBytes).map{String(format:"%02x",$0)}.joined()
    var bytes=originalBytes,fileExtension=url.pathExtension.lowercased(),outputWidth=width,outputHeight=height,resampled=false
    if let maximum {
      let dimensions=try MaterialTextureResampler.dimensions(width:width,height:height,maximum:maximum)
      if dimensions.0 != width || dimensions.1 != height {
        let resized=try MaterialTextureResampler.resize(image,width:dimensions.0,height:dimensions.1,encoding:encoding)
        bytes=resized.bytes;fileExtension=resized.fileExtension;outputWidth=resized.width;outputHeight=resized.height;resampled=true
      }
    }
    let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    let name="material-"+digest+"."+fileExtension,assets=engine.repository.url(for:project.id).appendingPathComponent("Assets")
    let reference=PhysicalTextureReference(asset:name,sha256:digest,colorSpace:encoding)
    try reference.validate();try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let target=assets.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath:target.path) {_ = try reference.verifiedURL(in:assets)}else {try bytes.write(to:target,options:.atomic)}
    let precision:[String:Any]=["bits_per_component":image.bitsPerComponent,"floating_point":image.bitmapInfo.contains(.floatComponents)]
    return ["texture":try jsonObject(reference),"width":outputWidth,"height":outputHeight,"project_changed":false,
      "original":precision.merging(["width":width,"height":height,"sha256":originalDigest]){_,new in new},
      "derived":precision.merging(["width":outputWidth,"height":outputHeight,"sha256":digest]){_,new in new},
      "resampling":["applied":resampled,"max_dimension":maximum as Any? ?? NSNull(),"method":resampled ? "vImage high-quality resampling":"immutable byte copy","filter_space":resampled ? (encoding == .data ? "numeric channels":"linear premultiplied color"):"unchanged","channel_encoding":encoding.rawValue,"format":fileExtension,"working_memory_limit_bytes":MaterialTextureResampler.maximumWorkingBytes]]
  }
}

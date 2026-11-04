import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// Immutable little-endian binary buffers avoid JSON expansion of dense meshes.
/// Every generated path belongs to this job directory; source asset files are
/// never moved or handed to a helper as writable destinations.
public enum CyclesSceneManifest {
  public static func write(snapshot:SceneSnapshot,settings:CyclesRenderConfiguration,jobID:UUID,directory:URL)throws->URL {
    try settings.validate();try snapshot.camera.validate()
    guard !snapshot.revision.isEmpty,snapshot.revision.utf8.count<=512,snapshot.renderables.count+snapshot.curves.count<=8192,snapshot.lights.count<=256 else {throw CyclesRenderError.invalidScene("The scene needs a revision and bounded component/light counts.")}
    if let f=snapshot.apertureFStop {guard f.isFinite,(0.1...256).contains(f) else{throw CyclesRenderError.invalidScene("Use an aperture from f/0.1 to f/256.")}}
    if let d=snapshot.focusDistanceMM {guard d.isFinite,d>0,d<=1e12 else{throw CyclesRenderError.invalidScene("Focus distance must be positive finite millimeters.")}}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let writer=Writer(directory:directory)
    let eye=snapshot.camera.worldFromCameraMM.columns.3
    let origin=SIMD3<Double>(eye.x,eye.y,eye.z)
    var materials=[[String:Any]](),meshes=[[String:Any]](),curves=[[String:Any]](),materialKeys:[Data:Int]=[:]
    func materialSlot(_ material:SceneMaterialPayload,useVertexColor:Bool = false)throws->Int {
      var value=try writer.material(material);value["useVertexColor"]=useVertexColor
      let key=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
      if let index=materialKeys[key] {return index}
      let index=materials.count;materials.append(value);materialKeys[key]=index;return index
    }
    for payload in snapshot.renderables where payload.visible {
      try payload.mesh.validate(materialCount:payload.materials.count);try payload.transform.validate()
      for slot in Set(payload.mesh.parts.filter{!$0.triangleIndices.isEmpty}.map(\.materialIndex)) {
        try validateTextureCoordinates(payload.materials[slot],available:[!payload.mesh.uvs.isEmpty,!payload.mesh.uvs1.isEmpty],subject:"Mesh "+payload.componentID)
      }
      let mapping=try payload.materials.map{try materialSlot($0,useVertexColor:!payload.mesh.colors.isEmpty)}
      let mesh=payload.mesh
      let slots=mesh.parts.flatMap{Array(repeating:UInt32(mapping[$0.materialIndex]),count:$0.triangleIndices.count/3)}
      var record=try writer.meshBuffers(mesh)
      record["id"]=payload.componentID;record["materialIndices"]=try writer.uints(slots);record["transform"]=matrix(payload.transform.matrixMM,origin:origin)
      meshes.append(record)
    }
    for curve in snapshot.curves where curve.visible {
      try curve.validate()
      try validateTextureCoordinates(curve.material,available:[true,!curve.uvs1MM.isEmpty],subject:"Curve "+curve.id)
      for appearance in [curve.material.physicalAppearance].compactMap({$0})+curve.material.physicalLayers.compactMap(\.appearance) {
        if appearance.displacementScaleMM != 0,appearance.textures[.displacement] != nil {
          throw CyclesRenderError.invalidScene("True displacement is supported on triangle surfaces. Use a bump or normal map for curve material "+curve.material.id+".")
        }
      }
      let slot=try materialSlot(curve.material),uvs=try curve.resolvedTextureCoordinatesMM()
      var record:[String:Any]=["id":curve.id,"points":try writer.doubles(curve.pointsMM.flatMap{[$0.x,$0.y,$0.z]},count:curve.pointsMM.count),"radii":try writer.floats(curve.radiiMM,count:curve.radiiMM.count),"firstKey":try writer.uints(curve.firstKey),"materialIndex":slot,"transform":matrix(curve.transform.matrixMM,origin:origin),"uvs":try writer.floats(uvs.flatMap{[$0.x,$0.y]},count:uvs.count)]
      if !curve.uvs1MM.isEmpty {record["uvs1"]=try writer.floats(curve.uvs1MM.flatMap{[$0.x,$0.y]},count:curve.uvs1MM.count)}
      curves.append(record)
    }
    guard !meshes.isEmpty || !curves.isEmpty else {throw CyclesRenderError.invalidScene("There are no visible surfaces to render.")}
    // Cycles cameras use local +Z into the scene; LAB's canonical camera uses -Z.
    var cameraMatrix=snapshot.camera.worldFromCameraMM;cameraMatrix.columns.2 *= -1
    var camera:[String:Any]=["transform":matrix(cameraMatrix,origin:origin),"near":snapshot.camera.nearMM,"far":snapshot.camera.farMM]
    switch snapshot.camera.projection {
    case .perspective(let fov):camera["type"]="perspective";camera["fovRadians"]=fov * .pi/180
    case .orthographic(let span):camera["type"]="orthographic";camera["orthoScale"]=span
    }
    camera["apertureFStop"]=snapshot.apertureFStop;camera["focusDistanceMM"]=snapshot.focusDistanceMM
    var lights=[[String:Any]]()
    for light in snapshot.lights {
      let values=matrix(light.transform,origin:origin)
      guard values.allSatisfy(\.isFinite),light.power.isFinite,light.power>=0,light.power<=1e9,[light.sizeMM.x,light.sizeMM.y].allSatisfy({$0.isFinite && $0>0 && $0<=1e9}),[light.color.x,light.color.y,light.color.z].allSatisfy({$0.isFinite && $0>=0}) else{throw CyclesRenderError.invalidScene("Lights need finite transforms, positive sizes and nonnegative power/color.")}
      lights.append(["type":light.kind.rawValue,"shape":light.shape.rawValue,"transform":values,"color":[light.color.x,light.color.y,light.color.z],"power":light.power,"size":[light.sizeMM.x,light.sizeMM.y]])
    }
    let environment=snapshot.environment
    guard environment.strength.isFinite,(0...1e6).contains(environment.strength),environment.rotationDegrees.isFinite,[environment.color.x,environment.color.y,environment.color.z].allSatisfy({$0.isFinite && $0>=0}) else{throw CyclesRenderError.invalidScene("Environment values must be finite and nonnegative.")}
    var background:[String:Any]=["color":[environment.color.x,environment.color.y,environment.color.z],"strength":environment.strength,"rotationDegrees":environment.rotationDegrees]
    if let texture=environment.texture {background["texture"]=try writer.texture(texture,defaultEncoding:.linear)}
    var manifest:[String:Any]=["version":1,"jobID":jobID.uuidString,"sourceRevision":snapshot.revision,"width":settings.width,"height":settings.height,"samples":settings.samples,"adaptiveThreshold":settings.adaptiveThreshold,"denoise":settings.denoise,"device":settings.device.rawValue,"seed":settings.seed,"transparent":settings.transparent,"exposureEV":settings.exposureEV,"maxBounces":settings.maxBounces,"outputDirectory":directory.path,"meshes":meshes,"curves":curves,"materials":materials,"camera":camera,"lights":lights,"background":background]
    manifest["projectID"]=snapshot.projectID?.uuidString
    manifest["originMM"]=[origin.x,origin.y,origin.z]
    manifest["displacementDicingRate"]=settings.displacementDicingRate
    manifest["displacementMaxTriangles"]=settings.displacementMaxTriangles
    manifest["displacementMaxSubdivisions"]=settings.displacementMaxSubdivisions
    let url=directory.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:url,options:.atomic)
    return url
  }
  private static func validateTextureCoordinates(_ material:SceneMaterialPayload,available:[Bool],subject:String)throws {
    var textures=baseTextures(material).map{$0.1}
    textures += Array(material.physicalAppearance?.textures.values ?? [:].values)
    for layer in material.physicalLayers {textures.append(layer.mask);textures += Array(layer.appearance?.textures.values ?? [:].values)}
    for texture in textures where texture.image.width>1 || texture.image.height>1 {
      guard available.indices.contains(texture.uvIndex),available[texture.uvIndex] else {
        throw CyclesRenderError.invalidScene(subject+" has no UV\(texture.uvIndex) coordinates required by material "+material.id+". Supply that coordinate set or use a constant 1×1 texture.")
      }
    }
  }
  /// Resolve overrides before allocating files. The base normal is retained:
  /// an authored physical normal becomes normalDetail in the same shader.
  private static func baseTextures(_ material:SceneMaterialPayload)->[(String,SceneTexturePayload,SceneTextureEncoding)] {
    let candidates:[(String,SceneTexturePayload?,SceneTextureEncoding)]=[
      ("baseColor",material.baseColorTexture,.srgb),("artwork",material.artworkTexture,.srgb),
      ("normal",material.normalTexture,.data),("roughness",material.roughnessTexture,.data),
      ("metallic",material.metallicTexture,.data),("emission",material.emissiveTexture,.srgb)]
    return candidates.compactMap {name,value,encoding in
      guard let value else{return nil}
      if name != "normal",let channel=ScenePhysicalTextureChannel(rawValue:name),material.physicalAppearance?.textures[channel] != nil {return nil}
      return (name,value,encoding)
    }
  }
  private static func matrix(_ source:simd_double4x4,origin:SIMD3<Double>)->[Double] {
    var m=source;m.columns.3.x-=origin.x;m.columns.3.y-=origin.y;m.columns.3.z-=origin.z
    return (0..<4).flatMap{c in (0..<4).map{r in m[c,r]}}
  }
  private final class Writer {
    let directory:URL
    var sequence=0,geometryBytes=0,textureBytes=0
    enum TextureContent:Hashable {case image(ObjectIdentifier),verified(String)}
    struct TextureKey:Hashable {let content:TextureContent;let encoding:String}
    var textureFiles:[TextureKey:[String:Any]]=[:]
    var sharedMeshes:[String:[String:Any]]=[:]
    init(directory:URL){self.directory=directory}
    func buffer(_ data:Data,count:Int)throws->[String:Any] {
      geometryBytes+=data.count;guard geometryBytes<=536_870_912,geometryBytes+textureBytes<=1_073_741_824 else{throw CyclesRenderError.invalidScene("The prepared scene exceeds 512 MiB geometry or 1 GiB total transfer budget.")}
      sequence+=1;let name="buffer-\(sequence).bin";try data.write(to:directory.appendingPathComponent(name),options:.atomic)
      return ["path":name,"count":count]
    }
    func doubles(_ values:[Double],count:Int)throws->[String:Any] {let words=values.map{$0.bitPattern.littleEndian};return try words.withUnsafeBytes{try buffer(Data($0),count:count)}}
    func floats(_ values:[Float],count:Int)throws->[String:Any] {let words=values.map{$0.bitPattern.littleEndian};return try words.withUnsafeBytes{try buffer(Data($0),count:count)}}
    func uints(_ values:[UInt32])throws->[String:Any] {let words=values.map(\.littleEndian);return try words.withUnsafeBytes{try buffer(Data($0),count:values.count)}}
    func meshBuffers(_ mesh:SceneMeshPayload)throws->[String:Any] {
      let key=mesh.id+"\u{0}"+mesh.revision
      if let record=sharedMeshes[key] {return record}
      var record:[String:Any]=["positions":try doubles(mesh.positionsMM.flatMap{[$0.x,$0.y,$0.z]},count:mesh.positionsMM.count),"triangles":try uints(mesh.parts.flatMap(\.triangleIndices))]
      if !mesh.normals.isEmpty {record["normals"]=try floats(mesh.normals.flatMap{[$0.x,$0.y,$0.z]},count:mesh.normals.count)}
      if !mesh.uvs.isEmpty {record["uvs"]=try floats(mesh.uvs.flatMap{[$0.x,$0.y]},count:mesh.uvs.count)}
      if !mesh.uvs1.isEmpty {record["uvs1"]=try floats(mesh.uvs1.flatMap{[$0.x,$0.y]},count:mesh.uvs1.count)}
      if !mesh.colors.isEmpty {record["colors"]=try floats(mesh.colors.flatMap{[$0.x,$0.y,$0.z,$0.w]},count:mesh.colors.count)}
      sharedMeshes[key]=record;return record
    }
    func texture(_ texture:SceneTexturePayload,defaultEncoding:SceneTextureEncoding)throws->[String:Any] {
      guard !texture.revision.isEmpty,texture.image.width<=8192,texture.image.height<=8192,texture.image.width*texture.image.height<=16_777_216,(0...1).contains(texture.uvIndex),[texture.scale.x,texture.scale.y,texture.offset.x,texture.offset.y,texture.rotationDegrees].allSatisfy(\.isFinite) else{throw CyclesRenderError.invalidScene("Textures need a revision, finite mapping, UV0/UV1 and at most 16 MP / 8192 pixels per edge.")}
      let encoding=texture.encoding ?? defaultEncoding
      let content=texture.verifiedContentSHA256.map(TextureContent.verified) ?? .image(ObjectIdentifier(texture.image))
      let identity=TextureKey(content:content,encoding:encoding.rawValue)
      var resource:[String:Any]
      if let cached=textureFiles[identity] {resource=cached}
      else {
        sequence+=1
        textureBytes+=texture.image.width*texture.image.height*((texture.image.bitsPerComponent>8 || texture.image.bitmapInfo.contains(.floatComponents)) ? 16:4)
        guard textureBytes+geometryBytes<=1_073_741_824 else{throw CyclesRenderError.invalidScene("Prepared render assets exceed 1 GiB.")}
        if texture.image.bitsPerComponent>8 || texture.image.bitmapInfo.contains(.floatComponents) {
          let width=texture.image.width,height=texture.image.height
          guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:32,bytesPerRow:width*16,space:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,bitmapInfo:CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),let address=context.data else {throw CyclesRenderError.invalidScene("Could not preserve floating-point render texture values.")}
          // Bitmap rows and ImageIO files both start at the image's top row.
          // Keep that order: the native texture sampler handles LAB's UV flip.
          // Encoding declares numeric samples and overrides embedded profiles
          // at every precision. Retag before reading, then decode declared
          // sRGB explicitly after unpremultiplication. CGImage
          // cannot replace a monochrome color space with an RGB color space;
          // use the matching linear model, then let the destination expand
          // gray into RGB. This also retains 16-bit roughness/height maps.
          let numericSpace=CGColorSpace(name:texture.image.colorSpace?.model == .monochrome ? CGColorSpace.extendedLinearGray:CGColorSpace.extendedLinearSRGB)!
          let input=texture.image.copy(colorSpace:numericSpace)
          guard let input else{throw CyclesRenderError.invalidScene("Could not preserve the texture's declared data encoding.")}
          context.draw(input,in:CGRect(x:0,y:0,width:width,height:height))
          let pixels=address.bindMemory(to:Float.self,capacity:width*height*4)
          for index in stride(from:0,to:width*height*4,by:4) {
            let alpha=pixels[index+3]
            guard (0..<4).allSatisfy({pixels[index+$0].isFinite}) else{throw CyclesRenderError.invalidScene("Floating-point render textures must contain finite samples.")}
            if alpha>0 {pixels[index]/=alpha;pixels[index+1]/=alpha;pixels[index+2]/=alpha}
            if encoding == .srgb {
              for channel in 0..<3 {
                let value=pixels[index+channel]
                pixels[index+channel]=value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)
                guard pixels[index+channel].isFinite else{throw CyclesRenderError.invalidScene("Decoded render texture values must be finite.")}
              }
            }
          }
          let data=Data(bytes:address,count:width*height*16)
          let name="texture-\(sequence).rgba32f";try data.write(to:directory.appendingPathComponent(name),options:.atomic)
          resource=["path":name,"format":"rgba32f","width":width,"height":height,"colorSpace":encoding == .data ? "data":"linear"]
        } else {
          let name="texture-\(sequence).png",url=directory.appendingPathComponent(name)
          guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{throw CyclesRenderError.invalidScene("Could not create a render texture.")}
          CGImageDestinationAddImage(destination,texture.image,nil)
          guard CGImageDestinationFinalize(destination) else{throw CyclesRenderError.invalidScene("Could not encode a render texture.")}
          resource=["path":name]
        }
        textureFiles[identity]=resource
      }
      resource.merge(["colorSpace":resource["colorSpace"] ?? (texture.encoding ?? defaultEncoding).rawValue,"uvIndex":texture.uvIndex,"wrapS":texture.wrapS == .repeatMode ? "repeat":texture.wrapS.rawValue,"wrapT":texture.wrapT == .repeatMode ? "repeat":texture.wrapT.rawValue,"channel":texture.channel.rawValue,"scale":[texture.scale.x,texture.scale.y],"offset":[texture.offset.x,texture.offset.y],"rotationDegrees":texture.rotationDegrees]){_,new in new}
      return resource
    }
    func material(_ material:SceneMaterialPayload)throws->[String:Any] {
      let color=material.baseColor
      guard [color.x,color.y,color.z,color.w,material.metallic,material.roughness,material.emissiveColor.x,material.emissiveColor.y,material.emissiveColor.z,material.emissiveIntensity,material.normalScale,material.alphaCutoff].allSatisfy(\.isFinite),(0...1).contains(material.metallic),(0...1).contains(material.roughness) else {throw CyclesRenderError.invalidScene("Material colors and surface channels must be finite.")}
      func linear(_ x:Float)->Float {material.colorEncoding == .linearSRGB ? x:(x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4))}
      var result:[String:Any]=["id":material.id,"baseColor":[linear(color.x),linear(color.y),linear(color.z),color.w],"metallic":material.metallic,"roughness":material.roughness,"emissionColor":[linear(material.emissiveColor.x),linear(material.emissiveColor.y),linear(material.emissiveColor.z)],"emissionStrength":material.emissiveIntensity,"alphaMode":material.alphaMode.rawValue,"alphaCutoff":material.alphaCutoff,"normalScale":material.normalScale,"unlit":material.unlit,"doubleSided":material.doubleSided]
      var textures:[String:Any]=[:]
      for (name,value,encoding) in CyclesSceneManifest.baseTextures(material) {textures[name]=try texture(value,defaultEncoding:encoding)}
      if let p=material.physicalAppearance {
        var resolved=try appearance(p)
        if var mapped=resolved.removeValue(forKey:"textures") as? [String:Any] {
          if textures["normal"] != nil,let detail=mapped.removeValue(forKey:"normal") {mapped["normalDetail"]=detail}
          textures.merge(mapped){_,new in new}
        }
        result.merge(resolved){_,new in new}
      }
      guard material.physicalLayers.count<=16 else{throw CyclesRenderError.invalidScene("A material supports at most 16 masked physical layers.")}
      if !material.physicalLayers.isEmpty {
        result["physicalLayers"]=try material.physicalLayers.map{layer -> [String:Any] in
          guard [layer.roughness,layer.metallic].compactMap({$0}).allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw CyclesRenderError.invalidScene("Finish roughness and metallic factors must be between zero and one.")}
          var value:[String:Any]=["mask":try texture(layer.mask,defaultEncoding:.data)]
          if let response=layer.appearance {value["appearance"]=try appearance(response)}
          value["roughness"]=layer.roughness;value["metallic"]=layer.metallic
          return value
        }
      }
      result["textures"]=textures;return result
    }
    func appearance(_ p:ScenePhysicalAppearance)throws->[String:Any] {
      try p.validate();var textures:[String:Any]=[:]
      for (channel,value) in p.textures {textures[channel.rawValue]=try texture(value,defaultEncoding:[.baseColor,.emission,.sheenTint].contains(channel) ? .srgb:.data)}
      return ["ior":p.ior,"transmission":p.transmission,"diffuseTransmission":p.diffuseTransmission,"subsurface":p.subsurface,"subsurfaceRadiusMM":[p.subsurfaceRadiusMM.x,p.subsurfaceRadiusMM.y,p.subsurfaceRadiusMM.z],"sheen":p.sheen,"sheenRoughness":p.sheenRoughness,"sheenTint":[p.sheenTint.x,p.sheenTint.y,p.sheenTint.z],"anisotropy":p.anisotropy,"anisotropyRotation":p.anisotropyRotation,"coat":p.coat,"coatRoughness":p.coatRoughness,"bumpStrength":p.bumpStrength,"normalStrength":p.normalStrength,"displacementScaleMM":p.displacementScaleMM,"displacementMidlevel":p.displacementMidlevel,"textures":textures]
    }
  }
}

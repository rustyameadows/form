import Foundation
import CryptoKit
import FormCore

/// A bounded description of the exact captured input, not a query against the
/// scene that happens to be open when a provider eventually finishes.
struct StudioGenerationInputContext:Codable,Equatable {
  struct Viewport:Codable,Equatable {var width:Int,height:Int,aspect:Double}
  struct Camera:Codable,Equatable {
    var projection:String,azimuthDegrees:Double,elevationDegrees:Double,distanceMM:Double
    var targetMM:Vector3,positionMM:Vector3
    var upDirection:Vector3
    var verticalFieldOfViewDegrees:Double?,orthographicSpanMM:Double?
  }
  struct Ply:Codable,Equatable {var name:String,color:String,thicknessMM:Double}
  struct Finish:Codable,Equatable {
    var name:String,kind:String,side:String,depthMM:Double,heightMM:Double
    var color:String?,roughness:Double?,metallic:Double?,opacity:Double?
  }
  struct RegistryMaterial:Codable,Equatable {var id:String,name:String,category:String,color:String,roughness:Double,metallic:Double}
  struct MaterialSlot:Codable,Equatable,Identifiable {
    /// Color factors plus explicit override, not a claim that textured pixels
    /// have one flat color. PBR factors include the authored slot override.
    var id:Int,name:String,sourceBaseColor:[Double],colorEncoding:String,overrideColorHex:String?
    var roughness:Double,metallic:Double,opacity:Double,textureChannels:[String],alphaMode:String
  }
  /// Substrate before editable printed artwork and spatial finish masks.
  struct Face:Codable,Equatable {var color:String,roughness:Double,texture:String,opacity:Double,textureScaleMM:Double,textureDepthMM:Double}
  struct Paper:Codable,Equatable {
    var name:String,thicknessMM:Double,grain:String,profile:PaperSurfaceProfile?
    var plies:[Ply],finishes:[Finish]
    var front:Face,back:Face
  }
  struct Object:Codable,Equatable,Identifiable {
    var id:UUID,name:String,sourceObjectID:UUID?,sourceName:String?,recipeID:String
    var materialID:String,materialName:String,materialCategory:String,materialOrigin:String
    var color:String?,roughness:Double?,metallic:Double?
    var registryMaterial:RegistryMaterial,materialSlots:[MaterialSlot]
    var positionMM:Vector3,rotationDegrees:Double,parameters:[String:Double]
    /// Authored width/height/depth controls only; never guessed mesh bounds.
    var declaredDimensionsMM:Vector3?
    var paper:Paper?
    var dimensionsMM:Vector3? {declaredDimensionsMM}
  }
  var version=1
  var projectID:UUID,projectName:String,sceneID:UUID,sceneName:String
  var objects:[Object],camera:Camera,viewport:Viewport,lighting:String,surface:String
  var renderObjectCount:Int
  var units="millimeters; world XYZ; Y is up"
  var renderer:String
  var instanceCount:Int {objects.count}
  var materialCount:Int {Set(objects.map(\.materialID)).count}
  var sha256:String {get throws {SHA256.hash(data:try JSONEncoder.form.encode(self)).map{String(format:"%02x",$0)}.joined()}}
  @MainActor static func make(project:Project,scene:StudioComposition,resolved:Project,renderObjectCount:Int,width:Int,height:Int,renderer:String)throws->Self {
    let indexed=Dictionary(uniqueKeysWithValues:resolved.objects.map{($0.id,$0)})
    let sources=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)})
    var values=[Object]()
    for instance in scene.instances where instance.visible {
      guard let object=indexed[instance.id] else{throw StudioGenerationError.invalid("Captured instance metadata could not be resolved.")}
      let material=resolved.material(object.materialID)
      let registry=RegistryMaterial(id:material.id,name:material.name,category:material.category,color:material.color,roughness:material.roughness,metallic:material.metallic)
      var materialName=material.name,category=material.category,origin="registry base appearance"
      var color:String?=object.color ?? material.color,roughness:Double?=material.roughness,metallic:Double?=material.metallic
      var slots=[MaterialSlot]()
      if let mesh=object.meshAsset {
        materialName="Authored mesh material slots";category="Imported mesh";origin="authored mesh slots; registry material is not used"
        color=nil;roughness=nil;metallic=nil
        slots=mesh.materials.map {slot in
          let override=mesh.materialOverrides.first{$0.materialIndex==slot.index}
          return .init(id:slot.index,name:slot.name,sourceBaseColor:slot.baseColor,
            colorEncoding:(mesh.format=="glb" || mesh.format=="gltf") ? "linear sRGB":"sRGB",overrideColorHex:override?.colorHex,
            roughness:override?.roughness ?? slot.roughness,metallic:override?.metallic ?? slot.metallic,
            opacity:override?.opacity ?? slot.baseColor.last ?? 1,textureChannels:slot.textureChannels,alphaMode:slot.alphaMode)
        }
      }
      var size:Vector3?
      if let w=object.parameters["width"],let h=object.parameters["height"],let d=object.parameters["depth"],[w,h,d].allSatisfy({$0.isFinite && $0>=0}) {size = .init(w,h,d)}
      var paper:Paper?
      if PaperConstruction.isPaper(object) {
        let definition=try PaperConstruction.definition(for:object),stock=definition.stock
        let front=PaperGeometry.faceAppearance(for:object,stock:stock,project:resolved,inside:false)
        let back=PaperGeometry.faceAppearance(for:object,stock:stock,project:resolved,inside:true)
        materialName=stock.name;category="Paper stock";origin="paper stock faces and finish masks"
        color=nil;roughness=nil;metallic=nil
        paper = .init(name:stock.name,thicknessMM:stock.resolvedThicknessMM,grain:stock.grain.rawValue,profile:stock.profile,
          plies:(stock.plies ?? []).map{.init(name:$0.name,color:$0.color,thicknessMM:$0.thicknessMM)},
          finishes:(definition.finishes ?? []).filter(\.enabled).map{.init(name:$0.name,kind:$0.kind.rawValue,side:$0.side.rawValue,depthMM:$0.depthMM,heightMM:$0.heightMM,color:$0.color,roughness:$0.roughness,metallic:$0.metallic,opacity:$0.opacity)},
          front:.init(color:front.resolvedColor,roughness:front.profile.roughness,texture:front.profile.texture.rawValue,opacity:front.profile.opacity,textureScaleMM:front.profile.textureScaleMM,textureDepthMM:front.profile.textureDepthMM),
          back:.init(color:back.resolvedColor,roughness:back.profile.roughness,texture:back.profile.texture.rawValue,opacity:back.profile.opacity,textureScaleMM:back.profile.textureScaleMM,textureDepthMM:back.profile.textureDepthMM))
      }
      let materialKey:String
      if let paper {materialKey="paper:"+SHA256.hash(data:try JSONEncoder.form.encode(paper)).map{String(format:"%02x",$0)}.joined()}
      else if let mesh=object.meshAsset {materialKey="mesh:"+mesh.normalizedSHA256+":"+mesh.appearanceRevision}
      else {materialKey=material.id}
      values.append(.init(id:instance.id,name:instance.name,sourceObjectID:instance.sourceObjectID,
        sourceName:instance.sourceObjectID.flatMap{sources[$0]?.name},recipeID:object.recipeID,
        materialID:materialKey,materialName:materialName,materialCategory:category,materialOrigin:origin,color:color,
        roughness:roughness,metallic:metallic,registryMaterial:registry,materialSlots:slots,positionMM:instance.positionMM,rotationDegrees:instance.rotationDegrees,
        parameters:object.parameters,declaredDimensionsMM:size,paper:paper))
    }
    let state=scene.camera,basis=CameraNavigation.basis(state),target=state.target
    let horizontal=hypot(basis.outward.x,basis.outward.z)
    let azimuth=horizontal>1e-10 ? atan2(basis.outward.x,basis.outward.z):state.azimuth.remainder(dividingBy:2*Double.pi)
    let elevation=atan2(basis.outward.y,horizontal)
    let position=Vector3((target.x+basis.outward.x*state.distance)*100,(target.y+basis.outward.y*state.distance)*100,(target.z+basis.outward.z*state.distance)*100)
    var shot=scene.shot(camera:state);shot.referenceAspect=state.viewportAspect ?? Double(width)/Double(max(1,height));shot.pixels = .init(width:width,height:height)
    let camera=Camera(projection:state.projection,azimuthDegrees:azimuth*180/Double.pi,elevationDegrees:elevation*180/Double.pi,
      distanceMM:state.distance*100,targetMM:.init(target.x*100,target.y*100,target.z*100),positionMM:position,upDirection:basis.up,
      verticalFieldOfViewDegrees:state.projection=="perspective" ? shot.outputFieldOfView:nil,
      orthographicSpanMM:state.projection=="orthographic" ? 2*state.distance*CameraFraming.orthographicFactor*100*shot.expansion:nil)
    let value=Self(projectID:project.id,projectName:project.name,sceneID:scene.id,sceneName:scene.name,objects:values,camera:camera,
      viewport:.init(width:width,height:height,aspect:Double(width)/Double(max(1,height))),lighting:scene.lighting,surface:scene.surface,renderObjectCount:renderObjectCount,renderer:renderer)
    try value.validate();return value
  }
  func validate()throws {
    let numbers=[camera.azimuthDegrees,camera.elevationDegrees,camera.distanceMM,camera.targetMM.x,camera.targetMM.y,camera.targetMM.z,camera.positionMM.x,camera.positionMM.y,camera.positionMM.z,viewport.aspect]
    guard version==1,projectName.count<=500,sceneName.count<=120,!renderer.isEmpty,renderer.count<=120,(1...128).contains(objects.count),
      (objects.count...1024).contains(renderObjectCount),(1...8192).contains(viewport.width),(1...8192).contains(viewport.height),
      numbers.allSatisfy({$0.isFinite && abs($0)<=1e10}),camera.distanceMM>0,
      abs(viewport.aspect-Double(viewport.width)/Double(viewport.height))<1e-12 else{throw StudioGenerationError.invalid("Captured input metadata exceeds its bounded physical context.")}
    for object in objects {
      guard object.name.count<=240,(object.sourceName?.count ?? 0)<=240,object.recipeID.count<=240,
        object.materialID.count<=240,object.materialName.count<=240,object.materialOrigin.count<=160,object.materialCategory.count<=240,object.parameters.count<=256,
        object.parameters.allSatisfy({$0.key.count<=256 && $0.value.isFinite}),
        [object.positionMM.x,object.positionMM.y,object.positionMM.z,object.rotationDegrees].allSatisfy(\.isFinite),
        [object.roughness,object.metallic].compactMap{$0}.allSatisfy({$0.isFinite && (0...1).contains($0)}),
        object.materialSlots.count<=2048,(object.paper?.plies.count ?? 0)<=32,(object.paper?.finishes.count ?? 0)<=256 else{throw StudioGenerationError.invalid("An input object has invalid or excessive metadata.")}
      let registry=object.registryMaterial
      guard registry.id.count<=240,registry.name.count<=240,registry.category.count<=240,registry.color.count<=32,
        [registry.roughness,registry.metallic].allSatisfy({$0.isFinite && (0...1).contains($0)}) else{throw StudioGenerationError.invalid("Registry material metadata is invalid.")}
      for slot in object.materialSlots {
        guard (0..<2048).contains(slot.id),slot.name.count<=4096,slot.sourceBaseColor.count==4,
          slot.sourceBaseColor.allSatisfy({$0.isFinite && (0...1).contains($0)}),
          [slot.roughness,slot.metallic,slot.opacity].allSatisfy({$0.isFinite && (0...1).contains($0)}),
          ["linear sRGB","sRGB"].contains(slot.colorEncoding),(slot.overrideColorHex?.count ?? 0)<=32,
          slot.textureChannels.count<=5,slot.textureChannels.allSatisfy({$0.count<=64}),slot.alphaMode.count<=16 else{throw StudioGenerationError.invalid("Authored mesh material metadata is invalid.")}
      }
      if let paper=object.paper {
        for face in [paper.front,paper.back] {
          guard face.color.count<=32,face.texture.count<=32,[face.roughness,face.opacity].allSatisfy({$0.isFinite && (0...1).contains($0)}),
            face.textureScaleMM.isFinite,face.textureScaleMM>0,face.textureDepthMM.isFinite,face.textureDepthMM>=0 else{throw StudioGenerationError.invalid("Paper substrate metadata is invalid.")}
        }
      }
    }
    guard try JSONEncoder.form.encode(self).count<=512*1024 else{throw StudioGenerationError.invalid("Captured input metadata is limited to512KiB.")}
  }
}

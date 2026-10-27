import Foundation
import CryptoKit

public struct StudioProp:Codable,Equatable,Sendable {
  public var widthMM:Double,heightMM:Double,depthMM:Double,color:String
  public init(widthMM:Double=500,heightMM:Double=30,depthMM:Double=180,color:String="#DED8CB"){self.widthMM=widthMM;self.heightMM=heightMM;self.depthMM=depthMM;self.color=color}
}
public struct StudioInstance:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var sourceObjectID:UUID?
  public var prop:StudioProp?
  public var positionMM:Vector3
  public var rotationDegrees:Double
  public var materialID:String?
  public var visible:Bool=true
  public init(name:String,sourceObjectID:UUID?=nil,prop:StudioProp?=nil,positionMM:Vector3 = .init(),rotationDegrees:Double=0){self.name=name;self.sourceObjectID=sourceObjectID;self.prop=prop;self.positionMM=positionMM;self.rotationDegrees=rotationDegrees}
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=120,(sourceObjectID != nil) != (prop != nil),[positionMM.x,positionMM.y,positionMM.z,rotationDegrees].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),materialID.map({!$0.isEmpty && $0.count<=200}) ?? true else{throw FormError.invalid("A Studio instance needs one product source or prop, a name and finite placement.")}
    if let prop {guard [prop.widthMM,prop.heightMM,prop.depthMM].allSatisfy({$0.isFinite && (5...10000).contains($0)}),prop.color.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil else{throw FormError.invalid("Studio props need 5–10000 mm dimensions and a six-digit hex color.")}}
  }
}
public struct StudioMotion:Codable,Equatable,Sendable {
  public enum Mode:String,Codable,CaseIterable,Sendable {case orbit,between}
  public var mode:Mode = .orbit
  public var seconds:Double=6
  public var fps:Int=24
  public var orbitDegrees:Double=45
  public var startCamera:CameraState?
  public var endCamera:CameraState?
  public init(){}
  public var frameCount:Int{Int((seconds*Double(fps)).rounded())}
  public func validate()throws {
    guard seconds.isFinite,(0.5...20).contains(seconds),[12,24,30].contains(fps),(6...600).contains(frameCount),orbitDegrees.isFinite,abs(orbitDegrees)<=720 else{throw FormError.invalid("Use 0.5–20 seconds at 12, 24 or 30 fps, at most 600 frames and ±720° orbit.")}
    if let startCamera {try StudioShot(name:"Start camera",camera:startCamera,referenceAspect:1.5).validate()}
    if mode == .between {guard let endCamera else{throw FormError.invalid("Capture an end camera before using a two-camera motion.")};try StudioShot(name:"End camera",camera:endCamera,referenceAspect:1.5).validate()}
  }
  public func camera(start:CameraState,fraction:Double)throws->CameraState {
    try validate();guard fraction.isFinite,(0...1).contains(fraction) else{throw FormError.invalid("Motion time must be between zero and one.")}
    let start=startCamera ?? start
    var result=start;result.orientation=nil
    if mode == .orbit {result.azimuth += orbitDegrees * .pi/180 * fraction}
    else if let end=endCamera {
      let t=fraction*fraction*(3-2*fraction)
      var delta=(end.azimuth-start.azimuth).truncatingRemainder(dividingBy:2 * .pi)
      if delta > .pi {delta-=2 * .pi};if delta < -.pi {delta+=2 * .pi}
      result.azimuth=start.azimuth+delta*t;result.elevation=start.elevation+(end.elevation-start.elevation)*t;result.distance=start.distance+(end.distance-start.distance)*t
      result.target = .init(start.target.x+(end.target.x-start.target.x)*t,start.target.y+(end.target.y-start.target.y)*t,start.target.z+(end.target.z-start.target.z)*t)
      guard start.projection==end.projection else{throw FormError.invalid("Start and end cameras must use the same projection.")}
    }
    return result
  }
}
public struct StudioComposition:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID(),name:String,revision:Int=1
  public var instances:[StudioInstance]=[]
  public var camera:CameraState
  public var pixels=StudioPixels()
  public var lighting="soft-side-v1",surface="Daylight"
  public var motion=StudioMotion()
  public init(name:String,camera:CameraState){self.name=name;self.camera=camera}
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=80,(1...1_000_000).contains(revision),instances.count<=128,Set(instances.map(\.id)).count==instances.count else{throw FormError.invalid("Use a named scene with at most 128 uniquely identified instances.")}
    var shot=StudioShot(name:name,camera:camera,referenceAspect:pixels.aspect);shot.pixels=pixels;shot.lighting=lighting;shot.surface=surface;try shot.validate();try motion.validate()
    if motion.mode == .between {guard (motion.startCamera ?? camera).projection==motion.endCamera?.projection else{throw FormError.invalid("Motion endpoints must use the same camera projection.")}}
    for instance in instances {try instance.validate()}
  }
  public static func fromProject(_ project:Project,name:String="Still life 01")->Self {
    var scene=Self(name:name,camera:project.camera)
    scene.instances=project.objects.filter{!$0.isCanvasWorkspace && $0.recipeID != "artboard" && $0.recipeID != "reference" && $0.textile?.attachment==nil && $0.clothAttachment==nil && $0.patternAssemblyAttachment==nil}.prefix(128).map{.init(name:$0.name,sourceObjectID:$0.id,positionMM:$0.position,rotationDegrees:$0.rotation)}
    return scene
  }
  /// Resolve linked sources into ephemeral render objects, with deterministic IDs.
  /// Original objects remain available for artwork/pattern lookup but are hidden.
  public func resolved(in project:Project)throws->(project:Project,visible:Set<UUID>) {
    try validate();var copy=project,visible=Set<UUID>(),created=[ProductObject]()
    let originals=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)})
    for instance in instances where instance.visible {
      if let prop=instance.prop {
        var object=ProductObject(name:instance.name,recipeID:"box",parameters:["width":prop.widthMM,"height":prop.heightMM,"depth":prop.depthMM,"corner":2],position:instance.positionMM,rotation:instance.rotationDegrees)
        object.id=instance.id;object.color=prop.color;created.append(object);visible.insert(object.id);continue
      }
      guard let sourceID=instance.sourceObjectID,let source=originals[sourceID],!source.isCanvasWorkspace else{throw FormError.missing("A scene product is missing. Replace its source or remove the instance before rendering.")}
      guard source.meshAsset==nil || instance.materialID==nil else{throw FormError.invalid("Imported meshes retain their authored material slots. Choose an authored source colorway for this instance.")}
      var family=[source],familyIDs:Set<UUID>=[source.id]
      for _ in 0..<8 {
        let children=project.objects.filter{object in
          let parent=object.textile?.attachment?.garmentID ?? object.clothAttachment?.surfaceObjectID ?? object.patternAssemblyAttachment?.surfaceObjectID
          return !familyIDs.contains(object.id) && parent.map{familyIDs.contains($0)} == true
        }
        if children.isEmpty {break};family+=children;familyIDs.formUnion(children.map(\.id))
      }
      guard family.count<=128,created.count+family.count<=1024 else{throw FormError.invalid("Scene attachment expansion exceeds 1024 render objects.")}
      let map=Dictionary(uniqueKeysWithValues:family.map{($0.id,$0.id==source.id ? instance.id:Self.derivedID(instance.id,$0.id))})
      for original in family {
        var object=original;object.id=map[original.id]!;object.groupID=nil
        if original.id==source.id {
          object.name=instance.name;object.position=instance.positionMM;object.rotation=instance.rotationDegrees
          if let material=instance.materialID {guard project.material(material).id==material else{throw FormError.missing("A scene material is missing.")};object.materialID=material;object.color=nil}
          // The source's world attachment does not constrain its independent presentation instance.
          object.textile?.attachment=nil;object.clothAttachment=nil;object.patternAssemblyAttachment=nil
        }
        if let parent=object.textile?.attachment?.garmentID,let mapped=map[parent] {object.textile?.attachment?.garmentID=mapped}
        if let parent=object.clothAttachment?.surfaceObjectID,let mapped=map[parent] {object.clothAttachment?.surfaceObjectID=mapped}
        if let parent=object.patternAssemblyAttachment?.surfaceObjectID,let mapped=map[parent] {object.patternAssemblyAttachment?.surfaceObjectID=mapped}
        created.append(object);visible.insert(object.id)
      }
    }
    guard !visible.isEmpty,Set(created.map(\.id)).isDisjoint(with:Set(project.objects.map(\.id))) else{throw FormError.invalid("The scene needs visible instances whose IDs are separate from design objects.")}
    // Lookup-only originals stay intact for linked artwork/pattern construction.
    // The stage builds only the returned visible IDs, not these source objects.
    copy.objects+=created;copy.camera=camera;return (copy,visible)
  }
  private static func derivedID(_ instance:UUID,_ source:UUID)->UUID {
    let b=Array(SHA256.hash(data:Data((instance.uuidString+source.uuidString).utf8)).prefix(16))
    return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
  }
  public func shot(camera:CameraState?=nil)->StudioShot {
    var shot=StudioShot(name:name,camera:camera ?? self.camera,referenceAspect:pixels.aspect);shot.pixels=pixels;shot.lighting=lighting;shot.surface=surface;return shot
  }
}

public enum StudioSceneCommands {
  public static func call(engine:OperationEngine,arguments a:[String:Any],source:String)throws->Any {
    guard Set(a.keys).isSubset(of:["command","scene_id","scene","name"]),let command=a["command"] as? String,let project=engine.project else{throw FormError.invalid("Open a project and use a known Studio scene command.")}
    let scenes=project.studioPresentation?.scenes ?? []
    if command=="list" {guard a.count==1 else{throw FormError.invalid("List accepts command only.")};return try jsonObject(scenes)}
    func existing()throws->StudioComposition {guard let raw=a["scene_id"] as? String,let id=UUID(uuidString:raw),let result=scenes.first(where:{$0.id==id}) else{throw FormError.missing("Studio scene not found.")};return result}
    if command=="get" {guard a.count==2 else{throw FormError.invalid("Get accepts scene_id only.")};return try jsonObject(existing())}
    if command=="delete" {
      guard a.count==2 else{throw FormError.invalid("Delete accepts scene_id only.")};let scene=try existing()
      try engine.edit("Deleted Studio scene",source:source){p in var value=p.studioPresentation!;value.scenes?.removeAll{$0.id==scene.id};p.studioPresentation=value};return ["deleted":true]
    }
    var scene:StudioComposition
    if command=="create" {guard Set(a.keys).isSubset(of:["command","name"]),a["name"]==nil || a["name"] is String else{throw FormError.invalid("Create accepts a scene name.")};scene = .fromProject(project,name:a["name"] as? String ?? "Still life \(scenes.count+1)")}
    else if command=="save" {
      guard a.count==2,let raw=a["scene"] as? [String:Any],Set(raw.keys).isSubset(of:["id","name","revision","instances","camera","pixels","lighting","surface","motion"]) else{throw FormError.invalid("Save requires a complete Studio composition.")}
      try validateFields(raw)
      let data=try JSONSerialization.data(withJSONObject:raw)
      guard data.count<=2_097_152 else{throw FormError.invalid("Scene definitions are limited to 2 MiB.")}
      scene=try JSONDecoder.form.decode(StudioComposition.self,from:data)
      if let prior=scenes.first(where:{$0.id==scene.id}) {guard scene.revision==prior.revision else{throw FormError.invalid("The saved scene changed. Reload before saving this draft.")};if scene==prior{return try jsonObject(prior)};scene.revision+=1}
    }else if command=="duplicate" {guard Set(a.keys).isSubset(of:["command","scene_id","name"]),a["name"]==nil || a["name"] is String else{throw FormError.invalid("Duplicate accepts scene_id and an optional name.")};scene=try existing();scene.id=UUID();scene.revision=1;scene.name=a["name"] as? String ?? scene.name+" copy";for i in scene.instances.indices{scene.instances[i].id=UUID()}}
    else {throw FormError.invalid("Use list, get, create, save, duplicate or delete for Studio scenes.")}
    try scene.validate();guard scenes.contains(where:{$0.id==scene.id}) || scenes.count<32 else{throw FormError.invalid("A project supports at most 32 Studio scenes.")}
    try engine.edit("Saved Studio scene",source:source){p in var value=p.studioPresentation ?? .init();var items=value.scenes ?? [];if let i=items.firstIndex(where:{$0.id==scene.id}){items[i]=scene}else{items.append(scene)};value.scenes=items;p.studioPresentation=value}
    return try jsonObject(scene)
  }
  private static func validateFields(_ raw:[String:Any])throws {
    func fields(_ raw:Any?,_ allowed:Set<String>)throws {
      guard let raw else{return}
      if raw is NSNull{return}
      guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:allowed) else{throw FormError.invalid("Unknown or malformed field in Studio scene definition.")}
    }
    let cameraFields:Set<String>=["azimuth","elevation","orientation","distance","target","projection","viewportAspect"]
    func camera(_ raw:Any?)throws {try fields(raw,cameraFields);if let value=raw as? [String:Any]{try fields(value["target"],["x","y","z"]);try fields(value["orientation"],["x","y","z","w"])}}
    try camera(raw["camera"]);try fields(raw["pixels"],["width","height"]);try fields(raw["motion"],["mode","seconds","fps","orbitDegrees","startCamera","endCamera"])
    if let motion=raw["motion"] as? [String:Any]{try camera(motion["startCamera"]);try camera(motion["endCamera"])}
    guard let instances=raw["instances"] as? [[String:Any]],instances.count<=128 else{throw FormError.invalid("Use at most 128 scene instances.")}
    for instance in instances {try fields(instance,["id","name","sourceObjectID","prop","positionMM","rotationDegrees","materialID","visible"]);try fields(instance["prop"],["widthMM","heightMM","depthMM","color"]);try fields(instance["positionMM"],["x","y","z"])}
  }
}

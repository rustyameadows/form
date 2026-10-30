import Foundation
import CoreFoundation
import CryptoKit

public struct StudioPixels: Codable, Equatable, Sendable {
  public var width: Int = 3000
  public var height: Int = 2000
  public init(width:Int=3000,height:Int=2000) {self.width=width;self.height=height}
  public var aspect:Double {Double(width)/Double(height)}
  public func validate()throws {
    guard (64...8192).contains(width),(64...8192).contains(height),width*height<=16_777_216,(0.125...8).contains(aspect) else {throw FormError.invalid("Studio output needs integer dimensions 64–8192 pixels, at most 16,777,216 pixels, and aspect 1:8–8:1.")}
  }
  public static func integer(_ value:Any?,name:String)throws->Int {
    guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,(64...8192).contains(n.intValue) else {throw FormError.invalid("\(name) must be an integer pixel dimension from 64 to 8192.")};return n.intValue
  }
}
public struct StudioVisibility:Codable,Equatable,Sendable {
  public enum Mode:String,Codable,Sendable {case project,objects}
  public var mode:Mode = .project
  public var objectIDs:[UUID] = []
  public init(mode:Mode = .project,objectIDs:[UUID] = []) {self.mode=mode;self.objectIDs=objectIDs}
  public func validate()throws {
    guard objectIDs.count<=4096,Set(objectIDs).count==objectIDs.count,(mode == .project ? objectIDs.isEmpty:!objectIDs.isEmpty) else {throw FormError.invalid("Use project visibility or 1–4096 unique explicit object IDs.")}
  }
  public func resolved(in project:Project)throws->Set<UUID> {
    try validate();let ids=Set(project.objects.filter{$0.hasTablePresentation}.map(\.id))
    guard mode == .project || Set(objectIDs).isSubset(of:ids) else {throw FormError.missing("A saved shot subject is missing or is an internal Canvas workspace. Repair its explicit visibility before rendering.")}
    let result=mode == .project ? ids:Set(objectIDs)
    guard !result.isEmpty,result.count<=4096 else {throw FormError.invalid("The shot needs 1–4096 physical subjects.")};return result
  }
}
public struct StudioShot:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var revision:Int = 1
  public var camera:CameraState
  public var referenceAspect:Double
  public var lighting:String = "classic-v1"
  public var surface:String = "Daylight"
  public var visibility=StudioVisibility()
  public var pixels=StudioPixels()
  public init(name:String,camera:CameraState,referenceAspect:Double) {self.name=name;self.camera=camera;self.referenceAspect=referenceAspect}
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=80,(1...1_000_000).contains(revision),[camera.azimuth,camera.elevation,camera.distance,camera.target.x,camera.target.y,camera.target.z,referenceAspect].allSatisfy(\.isFinite),camera.distance>0,camera.distance<=1_000_000,[camera.target.x,camera.target.y,camera.target.z].allSatisfy({abs($0)<=1_000_000}),camera.viewportAspect.map({$0.isFinite && $0>0}) ?? true,(0.125...8).contains(referenceAspect),["perspective","orthographic"].contains(camera.projection),camera.orientation == nil || camera.orientation?.quaternion != nil else {throw FormError.invalid("A Studio shot requires a name, finite saved camera and supported reference frame.")}
    guard Self.lightingIDs.contains(lighting),Self.surfaces.contains(surface) else {throw FormError.invalid("Unknown Studio lighting or surface preset version.")}
    try pixels.validate();try visibility.validate()
  }
  public static let lightingIDs=["classic-v1","soft-side-v1","rim-v1"]
  public static let surfaces=["Daylight","Warm paper","Graphite"]
  public var expansion:Double {CameraFraming.viewportExpansion(from:referenceAspect,to:pixels.aspect)}
  public var outputFieldOfView:Double {atan(tan(39 * .pi/360)*expansion)*360 / .pi}
}
public struct StudioPresentation:Codable,Equatable,Sendable {
  public var shots:[StudioShot] = []
  public var scenes:[StudioComposition]?
  public init(shots:[StudioShot] = []) {self.shots=shots}
}
extension Project {
  public func validateStudioPresentation()throws {
    guard let value=studioPresentation else{return}
    guard value.shots.count<=64,Set(value.shots.map(\.id)).count==value.shots.count else {throw FormError.invalid("A project supports at most 64 uniquely identified Studio shots.")}
    for shot in value.shots {try shot.validate()}
    let scenes=value.scenes ?? []
    guard scenes.count<=32,Set(scenes.map(\.id)).count==scenes.count else{throw FormError.invalid("A project supports at most 32 uniquely identified Studio scenes.")}
    let designIDs=Set(objects.map(\.id))
    for scene in scenes {try scene.validate();guard Set(scene.instances.map(\.id)).isDisjoint(with:designIDs) else{throw FormError.invalid("Scene instance IDs must be separate from design object IDs.")}}
  }
  /// Committed design identity deliberately excludes navigation, history and shot metadata.
  public func studioDesignDigest()throws->String {
    var source=self;source.camera = .init();source.studioPresentation=nil;source.collectionProduction=nil;source.history=[]
    source.createdAt=Date(timeIntervalSince1970:0);source.updatedAt=source.createdAt;source.schemaVersion=1
    return SHA256.hash(data:try JSONEncoder.form.encode(source)).map{String(format:"%02x",$0)}.joined()
  }
}
public enum StudioShotCommands {
  public static func isInspection(_ args:[String:Any])->Bool {args["view"] as? String == "studio" && ["list","get"].contains(args["studio_command"] as? String ?? "")}
  public static func shot(in project:Project,id:Any?)throws->StudioShot {
    guard let raw=id as? String,let uuid=UUID(uuidString:raw),let shot=project.studioPresentation?.shots.first(where:{$0.id==uuid}) else {throw FormError.missing("Saved Studio shot not found.")};return shot
  }
  public static func inspect(_ project:Project,args:[String:Any])throws->Any {
    guard Set(args.keys).isSubset(of:["view","studio_command","shot_id"]) else {throw FormError.invalid("Unknown Studio inspection argument.")}
    if args["studio_command"] as? String == "list" {return try jsonObject(project.studioPresentation?.shots ?? [])}
    return try jsonObject(shot(in:project,id:args["shot_id"]))
  }
  public static func apply(_ project:inout Project,args:[String:Any])throws->StudioShot? {
    let known:Set<String>=["view","studio_command","shot_id","name","camera","reference_aspect","lighting","surface","visibility","width","height"]
    guard Set(args.keys).isSubset(of:known),let command=args["studio_command"] as? String,["capture","update","rename","delete"].contains(command) else {throw FormError.invalid("Unknown Studio shot operation or argument.")}
    if command == "delete",!Set(args.keys).isSubset(of:["view","studio_command","shot_id"]) {throw FormError.invalid("Delete accepts shot_id only.")}
    if command == "capture",args["shot_id"] != nil {throw FormError.invalid("Capture creates a new shot ID.")}
    var value=project.studioPresentation ?? .init()
    let existing=command == "capture" ? nil:try shot(in:project,id:args["shot_id"])
    if command == "delete" {value.shots.removeAll{$0.id==existing!.id};project.studioPresentation=value.shots.isEmpty && (value.scenes?.isEmpty ?? true) ? nil:value;return nil}
    var shot:StudioShot
    if let existing {shot=existing} else {
      guard value.shots.count<64 else{throw FormError.invalid("A project supports at most 64 Studio shots.")}
      let aspect=(args["reference_aspect"] as? Double) ?? project.camera.viewportAspect
      guard let aspect else{throw FormError.invalid("Capture needs a real reference viewport aspect.")}
      shot=StudioShot(name:args["name"] as? String ?? "Shot \(value.shots.count+1)",camera:project.camera,referenceAspect:aspect)
    }
    if let raw=args["name"] {guard let name=raw as? String else{throw FormError.invalid("Shot name must be text.")};shot.name=name.trimmingCharacters(in:.whitespacesAndNewlines)}
    if command == "rename" {guard args["name"] != nil,Set(args.keys).isSubset(of:["view","studio_command","shot_id","name"]) else {throw FormError.invalid("Rename needs a name only.")}}
    if command != "rename" {
      if let raw=args["camera"] {
        guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:["azimuth","elevation","orientation","distance","target","projection","viewportAspect"]) else{throw FormError.invalid("Unknown saved camera argument.")}
        shot.camera=try JSONDecoder.form.decode(CameraState.self,from:JSONSerialization.data(withJSONObject:raw))
      }
      else if command == "update" {shot.camera=project.camera}
      if args["reference_aspect"] == nil,let aspect=shot.camera.viewportAspect {shot.referenceAspect=aspect}
      if let aspect=args["reference_aspect"] {guard let n=aspect as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() else{throw FormError.invalid("Reference aspect must be numeric.")};shot.referenceAspect=n.doubleValue}
      if let raw=args["lighting"] {guard let v=raw as? String else{throw FormError.invalid("Lighting must be a preset ID.")};shot.lighting=v}
      if let raw=args["surface"] {guard let v=raw as? String else{throw FormError.invalid("Surface must be a preset name.")};shot.surface=v}
      if let raw=args["visibility"] {guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:["mode","objectIDs"]) else{throw FormError.invalid("Unknown visibility argument.")};shot.visibility=try JSONDecoder.form.decode(StudioVisibility.self,from:JSONSerialization.data(withJSONObject:raw));_ = try shot.visibility.resolved(in:project)}
      if args["width"] != nil || args["height"] != nil {shot.pixels=try .init(width:StudioPixels.integer(args["width"],name:"width"),height:StudioPixels.integer(args["height"],name:"height"))}
    }
    try shot.validate()
    if let existing {
      guard shot != existing else{return existing}
      guard existing.revision<1_000_000 else{throw FormError.invalid("Shot revision limit reached.")};shot.revision+=1
      value.shots[value.shots.firstIndex(where:{$0.id==shot.id})!]=shot
    } else {value.shots.append(shot)}
    project.studioPresentation=value;return shot
  }
}

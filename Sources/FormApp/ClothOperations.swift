import Foundation
import CoreFoundation
import CryptoKit
import FormCore

@MainActor extension StudioStore {
  static func isClothRuntime(_ arguments:[String:Any])->Bool {["get","run","stop","step","reset","snapshot"].contains(arguments["command"] as? String ?? "get")}
  func bridgeClothCall(_ arguments:[String:Any])throws -> Any {
    if Self.isClothRuntime(arguments) {cloth.reconcile();return try engine.call("form_cloth",arguments:arguments)}
    try preflightPublicationHandoff("form_cloth",arguments);finishArtworkEditing()
    let result=try engine.call("form_cloth",arguments:arguments)
    artworkSession.showingTabs=false;artworkSession.showingGlyphs=false
    if project != nil {showingHome=false}
    changed();try engine.flush();saving=false;toast("Updated from Codex",symbol:"sparkle")
    return result
  }
  func clothCall(_ args:[String:Any],source:String = "Codex")throws -> Any {
    guard let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let project,let object=project.objects.first(where:{$0.id==id}) else {throw FormError.invalid("Choose an existing cloth object_id.")}
    let command=args["command"] as? String ?? "get"
    func integer(_ key:String,default fallback:Int)throws -> Int {
      guard let raw=args[key] else {return fallback}
      guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue==number.doubleValue.rounded(),(0...100000).contains(number.doubleValue) else {throw FormError.invalid("Use a bounded whole number for \(key).")};return number.intValue
    }
    func number(_ key:String,default fallback:Double)throws -> Double {
      guard let raw=args[key] else {return fallback}
      guard let value=raw as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite else {throw FormError.invalid("Use a finite number for \(key).")};return value.doubleValue
    }
    switch command {
    case "configure":
      guard !object.locked else {throw FormError.invalid("Unlock the cloth source before editing its initial mesh/settings.")}
      guard args["definition"]==nil || args["settings"]==nil else {throw FormError.invalid("Provide either a complete definition or settings changes.")}
      var definition:ClothStudy
      if let raw=args["definition"] as? [String:Any] {definition=try JSONDecoder.form.decode(ClothStudy.self,from:JSONSerialization.data(withJSONObject:raw))}
      else if let current=object.cloth {definition=current}
      else if ClothDesign.recipeIDs.contains(object.recipeID) {definition=try ClothDesign.definition(for:object)}
      else {throw FormError.invalid("Provide a complete initial cloth definition to replace this object's surface.")}
      if let raw=args["settings"] {
        guard let values=raw as? [String:Any],var full=try jsonObject(definition.settings) as? [String:Any],Set(values.keys).isSubset(of:Set(full.keys)) else {throw FormError.invalid("Provide supported cloth settings fields.")}
        full.merge(values) {_,new in new}
        let settings=try JSONDecoder.form.decode(ClothSettings.self,from:JSONSerialization.data(withJSONObject:full))
        if settings.collisionThicknessMm != definition.settings.collisionThicknessMm,ClothDesign.recipeIDs.contains(object.recipeID),
          let generated=try? ClothDesign.definition(for:object,settings:definition.settings),generated.mesh==definition.mesh,generated.colliders==definition.colliders {
          definition=try ClothDesign.definition(for:object,settings:settings)
        } else {definition.settings=settings}
      }
      try definition.validate()
      try engine.edit("Configured cloth study",source:source) {try $0.setCloth(definition,for:id)}
      cloth.reconcile()
    case "remove":
      guard !ClothDesign.recipeIDs.contains(object.recipeID) else {throw FormError.invalid("A cloth template requires its flexible surface. Delete the object to remove the study.")}
      try engine.edit("Removed cloth study",source:source) {try $0.setCloth(nil,for:id)};cloth.reconcile()
    case "attach":
      guard !object.locked,object.cloth==nil,object.textile?.attachment==nil,let target=args["surface_object_id"] as? String,let surfaceID=UUID(uuidString:target),let surface=project.objects.first(where:{$0.id==surfaceID}),let definition=surface.cloth else {throw FormError.invalid("Choose an unlocked separate object and a configured surface_object_id; detach any garment placement first.")}
      let anchor=try definition.mesh.anchor(at:.init(number("u",default:0.5),number("v",default:0.5)),panel:integer("panel",default:0),normalOffsetMm:number("offset_mm",default:1))
      let attachment=try ClothAttachment(surfaceObjectID:surfaceID,anchor:anchor,rotationDegrees:number("rotation",default:0))
      try engine.edit("Attached object to cloth",source:source) {p in guard let i=p.objects.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Object disappeared.")};p.objects[i].clothAttachment=attachment}
    case "detach":
      guard !object.locked else {throw FormError.invalid("Unlock the object before detaching it.")}
      let placement=try cloth.placement(of:object,in:project)
      try engine.edit("Detached object from cloth",source:source) {p in
        guard let i=p.objects.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Object disappeared.")}
        p.objects[i].clothAttachment=nil
        if let placement {p.objects[i].position=placement.positionMm;p.objects[i].rotation=atan2(-placement.materialTangent.z,placement.materialTangent.x)*180 / .pi}
      }
    case "run","step","reset":
      guard !showingHome else {throw FormError.invalid("Open the project's Table before running a cloth study.")}
      try cloth.activate(id)
      if command=="run" {try cloth.preview.run()}
      else if command=="reset" {cloth.preview.reset()}
      else {try cloth.preview.stepImmediately(frames:integer("frames",default:1))}
    case "stop":
      if cloth.preview.source?.projectID==project.id,cloth.preview.source?.objectID==id {cloth.preview.stop()}
    case "get","snapshot":break
    default:throw FormError.invalid("Cloth command must be get, configure, remove, run, stop, step, reset, snapshot, attach or detach.")
    }
    guard let current=self.project,let currentObject=current.objects.first(where:{$0.id==id}) else {throw FormError.missing("The cloth object is no longer available.")}
    var result:[String:Any]=["object_id":id.uuidString,"configured":currentObject.cloth != nil,"runtime_persisted":false,"open_surface":currentObject.cloth != nil]
    if let study=currentObject.cloth {
      let frame=try cloth.frame(for:currentObject,in:current) ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders).frame
      result["source_digest"]=ClothSceneSurface.sourceIdentity(object:currentObject,project:current).revision
      result["bounds_mm"]=try jsonObject(ClothBounds(positionsMm:frame.positionsMm))
      result["definition_digest"]=try study.digest;result["diagnostics"]=try jsonObject(frame.diagnostics);result["settings"]=try jsonObject(study.settings)
      if command=="get" || command=="configure" {result["definition"]=try jsonObject(study)}
      if command=="snapshot" {
        let snapshot:[String:Any]=["units":"mm","open_surface":true,"source_digest":result["source_digest"]!,"definition_digest":result["definition_digest"]!,"positionsMm":try jsonObject(frame.positionsMm),"normals":try jsonObject(frame.normals),"uv":try jsonObject(study.mesh.uv),"triangles":try jsonObject(study.mesh.triangles),"panelIDs":study.mesh.panelIDs ?? [Int](repeating:0,count:study.mesh.restPositionsMm.count),"pinnedVertices":frame.pinnedVertices,"diagnostics":try jsonObject(frame.diagnostics)]
        if let path=args["path"] as? String {
          let url=URL(fileURLWithPath:path),data=try JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys])
          guard url.isFileURL,url.pathExtension.lowercased()=="json" else {throw FormError.invalid("Cloth snapshots export to a local .json file; they are open surfaces, not STL solids.")}
          try data.write(to:url,options:.atomic);result["path"]=url.path;result["bytes"]=data.count;result["sha256"]=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        } else {result["mesh"]=snapshot}
      }
    }
    if let attachment=currentObject.clothAttachment {
      result["attachment"]=try jsonObject(attachment)
      if let placement=try cloth.placement(of:currentObject,in:current) {result["placement"]=try jsonObject(placement)}
    }
    return result
  }
}

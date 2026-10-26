import Foundation
import CoreFoundation
import CryptoKit
import FormCore
import FormGraphics

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
    guard args["assembly"]==nil || args["assembly"] is [String:Any],args["element_ids"]==nil || args["element_ids"] is [String] else {throw FormError.invalid("Provide an assembly declaration object and source element UUID array.")}
    if command=="assemble" {
      var created:UUID?
      try engine.edit("Assembled original pattern panels",source:source) {p in
        let definition:PatternAssemblyDefinition
        if let raw=args["assembly"] as? [String:Any] {
          definition=try JSONDecoder.form.decode(PatternAssemblyDefinition.self,from:JSONSerialization.data(withJSONObject:raw))
          guard definition.sourceObjectID==id else {throw FormError.invalid("The assembly sourceObjectID must match this source pattern object_id.")}
        } else {
          let values=args["element_ids"] as? [String]
          let selected=values.map{Set($0.compactMap(UUID.init(uuidString:)))}
          guard values==nil || selected!.count==values!.count else {throw FormError.invalid("Select distinct source piece UUIDs.")}
          definition=try PatternAssemblyPlanning.arrangedPieces(in:&p,sourceID:id,elements:selected)
        }
        created=try p.addPatternAssembly(definition,name:args["name"] as? String ?? "Sewn assembly")
      }
      guard let created else {throw FormError.missing("The assembly was not created.")}
      engine.selection=[created];cloth.reconcile()
      return try clothCall(["command":"get","object_id":created.uuidString],source:source)
    }
    if command=="configure",var assembly=object.patternAssembly {
      guard !object.locked,args["definition"]==nil else {throw FormError.invalid("Edit the assembly declaration/settings; its derived mesh is not another editable source.")}
      guard args["assembly"]==nil || args["settings"]==nil else {throw FormError.invalid("Provide a complete assembly or settings changes.")}
      if let raw=args["assembly"] as? [String:Any] {assembly=try JSONDecoder.form.decode(PatternAssemblyDefinition.self,from:JSONSerialization.data(withJSONObject:raw))}
      if let raw=args["settings"] {
        guard let values=raw as? [String:Any],var full=try jsonObject(assembly.settings) as? [String:Any],Set(values.keys).isSubset(of:Set(full.keys)) else {throw FormError.invalid("Provide supported cloth settings fields.")}
        full.merge(values){_,new in new};assembly.settings=try JSONDecoder.form.decode(ClothSettings.self,from:JSONSerialization.data(withJSONObject:full))
      }
      try engine.edit("Configured pattern assembly",source:source) {try $0.setPatternAssembly(assembly,for:id)}
      cloth.reconcile()
      return try clothCall(["command":"get","object_id":id.uuidString],source:source)
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
        definition=try ClothDesign.updatingSettings(settings,for:object,study:definition)
      }
      try definition.validate()
      try engine.edit("Configured cloth study",source:source) {try $0.setCloth(definition,for:id)}
      cloth.reconcile()
    case "remove":
      guard object.patternAssembly==nil,!ClothDesign.recipeIDs.contains(object.recipeID) else {throw FormError.invalid("A cloth template requires its flexible surface. Delete the object to remove the study.")}
      try engine.edit("Removed cloth study",source:source) {try $0.setCloth(nil,for:id)};cloth.reconcile()
    case "attach":
      guard !object.locked,!object.isFlexibleSurface,object.textile?.attachment==nil,let target=args["surface_object_id"] as? String,let surfaceID=UUID(uuidString:target),let surface=project.objects.first(where:{$0.id==surfaceID}),let definition=try AssemblyProducts.study(for:surface,in:project) else {throw FormError.invalid("Choose an unlocked separate object and a configured surface_object_id; detach any garment placement first.")}
      if let product=try AssemblyProducts.product(for:surface,in:project) {
        let index=try integer("panel",default:0)
        guard let panel=product.panels.first(where:{$0.panelIndex==index}) else {throw FormError.invalid("Choose an existing generated assembly panel index.")}
        let anchor=try PatternAssemblyAnchor(panel:panel.id,materialPointMm:.init(number("material_x_mm",default:number("u",default:0.5)*panel.materialSizeMm.x),number("material_y_mm",default:number("v",default:0.5)*panel.materialSizeMm.y)),normalOffsetMm:number("offset_mm",default:1))
        _ = try anchor.resolve(in:product)
        let attachment=try PatternAssemblyAttachment(surfaceObjectID:surfaceID,anchor:anchor,rotationDegrees:number("rotation",default:0))
        try engine.edit("Attached object to assembly material",source:source) {p in guard let i=p.objects.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Object disappeared.")};p.objects[i].clothAttachment=nil;p.objects[i].patternAssemblyAttachment=attachment}
        return try clothCall(["command":"get","object_id":id.uuidString],source:source)
      }
      let anchor=try definition.mesh.anchor(at:.init(number("u",default:0.5),number("v",default:0.5)),panel:integer("panel",default:0),normalOffsetMm:number("offset_mm",default:1))
      let attachment=try ClothAttachment(surfaceObjectID:surfaceID,anchor:anchor,rotationDegrees:number("rotation",default:0))
      try engine.edit("Attached object to cloth",source:source) {p in guard let i=p.objects.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Object disappeared.")};p.objects[i].clothAttachment=attachment;p.objects[i].patternAssemblyAttachment=nil}
    case "detach":
      guard !object.locked else {throw FormError.invalid("Unlock the object before detaching it.")}
      let placement=try cloth.placement(of:object,in:project)
      try engine.edit("Detached object from cloth",source:source) {p in
        guard let i=p.objects.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Object disappeared.")}
        p.objects[i].clothAttachment=nil;p.objects[i].patternAssemblyAttachment=nil
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
    var result:[String:Any]=["object_id":id.uuidString,"configured":currentObject.isFlexibleSurface,"runtime_persisted":false,"open_surface":currentObject.isFlexibleSurface]
    let product=try? AssemblyProducts.product(for:currentObject,in:current)
    if let assembly=currentObject.patternAssembly {
      result["assembly"]=try jsonObject(assembly);result["derived_mesh_persisted"]=false
      if let product {result["assembly_panels"]=try jsonObject(product.panels);result["material_points_mm"]=try jsonObject(product.materialPointsMm);result["seam_samples"]=try jsonObject(product.seamSamples);result["meshing_operations"]=product.operations}
      else {do {_ = try AssemblyProducts.product(for:currentObject,in:current)}catch {if command=="snapshot" {throw error};result["issue"]=error.localizedDescription}}
    }
    if let study=currentObject.cloth ?? product?.study {
      let frame=try cloth.frame(for:currentObject,in:current) ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders,preparation:study.preparation).frame
      let identity=ClothSceneSurface.sourceIdentity(object:currentObject,project:current)
      result["source_digest"]=identity.revision
      result["bounds_mm"]=try jsonObject(ClothBounds(positionsMm:frame.positionsMm))
      if cloth.preview.source==identity,let digest=cloth.preview.definitionDigest {result["definition_digest"]=digest}
      else if let product {result["definition_digest"]=product.definitionDigest}
      else {result["definition_digest"]=try study.digest}
      result["constraint_force_scope"]="XPBD distance multipliers only; ideal-seam, contact and support reactions are not estimated."
      result["diagnostics"]=try jsonObject(frame.diagnostics);result["settings"]=try jsonObject(study.settings)
      if command=="get" || command=="configure" {result["definition"]=try jsonObject(study)}
      if command=="snapshot" {
        var snapshot:[String:Any]=["units":"mm","open_surface":true,"source_digest":result["source_digest"]!,"definition_digest":result["definition_digest"]!,"positionsMm":try jsonObject(frame.positionsMm),"normals":try jsonObject(frame.normals),"uv":try jsonObject(study.mesh.uv),"triangles":try jsonObject(study.mesh.triangles),"panelIDs":study.mesh.panelIDs ?? [Int](repeating:0,count:study.mesh.restPositionsMm.count),"pinnedVertices":frame.pinnedVertices,"diagnostics":try jsonObject(frame.diagnostics)]
        if let candidate=frame.preparationCandidatePositionsMm {snapshot["preparation_candidate_positions_mm"]=try jsonObject(candidate);snapshot["display_state"]="declared_source_pose"}
        if let product,let assembly=currentObject.patternAssembly {
          snapshot["assembly"]=try jsonObject(assembly);snapshot["initial_definition"]=try jsonObject(product.study)
          snapshot["assembly_panels"]=try jsonObject(product.panels);snapshot["material_points_mm"]=try jsonObject(product.materialPointsMm);snapshot["seam_samples"]=try jsonObject(product.seamSamples);snapshot["assembly_source_digest"]=product.sourceDigest
          snapshot["source_artwork"]=try current.objects.first(where:{$0.id==assembly.sourceObjectID})?.artwork.map(jsonObject)
        }
        if let path=args["path"] as? String {
          let url=URL(fileURLWithPath:path),data=try JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys])
          guard url.isFileURL,url.pathExtension.lowercased()=="json" else {throw FormError.invalid("Cloth snapshots export to a local .json file; they are open surfaces, not STL solids.")}
          try data.write(to:url,options:.atomic);result["path"]=url.path;result["bytes"]=data.count;result["sha256"]=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        } else {result["mesh"]=snapshot}
      }
    }
    if let attachment=currentObject.patternAssemblyAttachment {
      result["assembly_attachment"]=try jsonObject(attachment)
      if let placement=try cloth.placement(of:currentObject,in:current) {result["placement"]=try jsonObject(placement)}
    }
    if let attachment=currentObject.clothAttachment {
      result["attachment"]=try jsonObject(attachment)
      if let placement=try cloth.placement(of:currentObject,in:current) {result["placement"]=try jsonObject(placement)}
    }
    return result
  }
}

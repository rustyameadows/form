import AppKit
import FormCore
import FormGeometry
import FormMeshAssets
import simd

private struct SolidModelInspection:Sendable {
  let json:Data
  let stl:Data?
  nonisolated static func build(object:ProductObject,definition:ParametricSolid,surface:SolidSurface,export:Bool,revision:String)throws->SolidModelInspection {
    guard !surface.isEditingPreview else{throw FormError.invalid("Solid inspection requires the full-detail source.")}
    try Task.checkCancellation()
    let start=Date(),evaluated=try definition.evaluate(object.parameters)
    let primitive=MeshAssetPrimitive(id:"solid",positionsMM:surface.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:surface.indices)
    let report=try MeshTopology.inspect(primitive,maximumTriangles:2_000_000)
    try Task.checkCancellation()
    let low=surface.positions.reduce(SIMD3<Double>(repeating:.infinity),simd_min),high=surface.positions.reduce(SIMD3<Double>(repeating:-.infinity),simd_max)
    var parent=Array(surface.positions.indices)
    func find(_ n:Int)->Int {var i=n;while parent[i] != i{parent[i]=parent[parent[i]];i=parent[i]};return i}
    var welded:[[Int64]:Int]=[:]
    for (i,p) in surface.positions.enumerated() {
      if i&4095==0 {try Task.checkCancellation()}
      let key=[p.x,p.y,p.z].map{Int64(($0*100_000).rounded())}
      if let first=welded[key]{parent[i]=first}else{welded[key]=i}
    }
    for i in stride(from:0,to:surface.indices.count,by:3) {
      if i%12_288==0 {try Task.checkCancellation()}
      let a=find(Int(surface.indices[i]));for j in 1...2{parent[find(Int(surface.indices[i+j]))]=a}
    }
    let components=Set(surface.indices.map{find(Int($0))}).count
    let qualification=evaluated.sweeps.isEmpty ? "Geometric inspection only; verify process, supports and physical strength before manufacture.":"Analytic assembled surfaces preserve authored detail. Intersecting shells are not Boolean-unioned; self-intersections and physical manufacture require separate validation."
    let result:[String:Any]=["object_id":object.id.uuidString,"source_revision":revision,"source_quality":"full","primitives":evaluated.primitives.count,"analytic_sweeps":evaluated.sweeps.count,"representation":evaluated.sweeps.isEmpty ? "sampled_union":"analytic_assembly","vertices":surface.positions.count,"triangles":surface.indices.count/3,"components":components,"topology":try jsonObject(report),"minimum_mm":[low.x,low.y,low.z],"maximum_mm":[high.x,high.y,high.z],"size_mm":[high.x-low.x,high.y-low.y,high.z-low.z],"seconds":Date().timeIntervalSince(start),"qualification":qualification]
    var stl:Data?
    if export {
      guard report.isClosedOrientedSurface,report.signedVolumeMM3>0 else{throw FormError.invalid("Repair the solid's topology before STL export.")}
      var triangles:[MeshTriangle]=[];triangles.reserveCapacity(surface.indices.count/3)
      for i in stride(from:0,to:surface.indices.count,by:3) {
        if i%12_288==0 {try Task.checkCancellation()}
        func p(_ j:Int)->Vector3 {let v=surface.positions[Int(surface.indices[i+j])];return .init(v.x,-v.z,v.y)}
        triangles.append(.init(p(0),p(1),p(2)))
      }
      stl=try PrintMesh(triangles:triangles).binarySTL()
    }
    return .init(json:try JSONSerialization.data(withJSONObject:result),stl:stl)
  }
}

extension StudioStore {
  /// The ordinary native tool route awaits this method. Source construction,
  /// topology, connected-shell inspection and STL encoding all run off the UI.
  func solidModelCallAsync(_ args:[String:Any])async throws->Any {
    guard let project,let id=UUID(uuidString:args["object_id"] as? String ?? ""),let object=project.objects.first(where:{$0.id==id}),let definition=project.recipe(object.recipeID)?.solid else{throw FormError.invalid("Choose an object with a project-defined solid construction.")}
    let command=args["command"] as? String ?? "inspect"
    guard ["inspect","export_stl"].contains(command) else{throw FormError.invalid("Use inspect or export_stl.")}
    var path:String?
    if command=="export_stl" {
      guard let value=args["path"] as? String,value.hasPrefix("/"),URL(fileURLWithPath:value).pathExtension.lowercased()=="stl",!FileManager.default.fileExists(atPath:value) else{throw FormError.invalid("Provide an unused absolute .stl path.")}
      path=value
    }
    let revision=try SolidRecipeGeometry.sourceKey(definition,parameters:object.parameters,isEditingPreview:false)
    let surfaces=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[id])
    guard let surface=surfaces[id] else{throw FormError.invalid("The full-detail solid source is unavailable.")}
    let worker=Task.detached(priority:.userInitiated){
      let lease=UUID();try await SolidSurfaceWorkPool.shared.acquire(lease)
      do {
        let result=try SolidModelInspection.build(object:object,definition:definition,surface:surface,export:command=="export_stl",revision:revision)
        await SolidSurfaceWorkPool.shared.release();return result
      }catch{await SolidSurfaceWorkPool.shared.release();throw error}
    }
    let output=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    try Task.checkCancellation()
    guard let current=self.project,current.id==project.id,let latest=current.objects.first(where:{$0.id==id}),latest.parameters==object.parameters,current.recipe(latest.recipeID)?.solid==definition else{throw FormError.invalid("The solid changed while inspection was preparing. No file was exported.")}
    var result=(try JSONSerialization.jsonObject(with:output.json) as? [String:Any]) ?? [:]
    if let path,let stl=output.stl {
      let write=Task.detached(priority:.userInitiated){try Task.checkCancellation();try stl.write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)}
      try await withTaskCancellationHandler(operation:{try await write.value},onCancel:{write.cancel()})
      result["path"]=path
    }
    return result
  }
  /// A synchronous batch cannot own an asynchronous inspection/file publication.
  /// The existing form_solid tool is dispatched individually by the native bridge.
  func solidModelCall(_ args:[String:Any])throws->Any {
    throw FormError.invalid("Call form_solid individually so full-detail inspection and export can prepare in the background.")
  }
}

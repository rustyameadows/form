import AppKit
import FormCore
import FormMeshAssets
import simd

extension StudioStore {
  /// Local geometry inspection/export only. No slicer or printer is contacted.
  func solidModelCall(_ args:[String:Any])throws->Any {
    guard let project,let id=UUID(uuidString:args["object_id"] as? String ?? ""),let object=project.objects.first(where:{$0.id==id}),let definition=project.recipe(object.recipeID)?.solid else{throw FormError.invalid("Choose an object with a project-defined solid construction.")}
    let command=args["command"] as? String ?? "inspect"
    guard ["inspect","export_stl"].contains(command) else{throw FormError.invalid("Use inspect or export_stl.")}
    let start=Date(),evaluated=try definition.evaluate(object.parameters),mesh=try SolidRecipeGeometry.surface(definition,parameters:object.parameters)
    let primitive=MeshAssetPrimitive(id:"solid",positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:mesh.indices)
    let report=try MeshTopology.inspect(primitive,maximumTriangles:2_000_000)
    let low=mesh.positions.reduce(SIMD3<Double>(repeating:.infinity),simd_min),high=mesh.positions.reduce(SIMD3<Double>(repeating: -.infinity),simd_max)
    var parent=Array(mesh.positions.indices)
    func find(_ n:Int)->Int {var i=n;while parent[i] != i{parent[i]=parent[parent[i]];i=parent[i]};return i}
    // Analytic cap/crease vertices intentionally split their shading normals.
    // Weld coincident positions before reporting connected geometric shells.
    var welded:[[Int64]:Int]=[:]
    for (i,p) in mesh.positions.enumerated() {let key=[p.x,p.y,p.z].map{Int64(($0*100_000).rounded())};if let first=welded[key]{parent[i]=first}else{welded[key]=i}}
    for i in stride(from:0,to:mesh.indices.count,by:3){let a=find(Int(mesh.indices[i]));for j in 1...2{parent[find(Int(mesh.indices[i+j]))]=a}}
    let components=Set(mesh.indices.map{find(Int($0))}).count
    let qualification=evaluated.sweeps.isEmpty ? "Geometric inspection only; verify process, supports and physical strength before manufacture." : "Analytic assembled surfaces preserve authored detail. Intersecting shells are not Boolean-unioned; self-intersections and physical manufacture require separate validation."
    var result:[String:Any]=["object_id":id.uuidString,"primitives":evaluated.primitives.count,"analytic_sweeps":evaluated.sweeps.count,"representation":evaluated.sweeps.isEmpty ? "sampled_union":"analytic_assembly","vertices":mesh.positions.count,"triangles":mesh.indices.count/3,"components":components,"topology":try jsonObject(report),"minimum_mm":[low.x,low.y,low.z],"maximum_mm":[high.x,high.y,high.z],"size_mm":[high.x-low.x,high.y-low.y,high.z-low.z],"seconds":Date().timeIntervalSince(start),"qualification":qualification]
    if command=="export_stl" {
      guard report.isClosedOrientedSurface,report.signedVolumeMM3>0 else{throw FormError.invalid("Repair the solid's topology before STL export.")}
      guard let path=args["path"] as? String,path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="stl",!FileManager.default.fileExists(atPath:path) else{throw FormError.invalid("Provide an unused absolute .stl path.")}
      let triangles=stride(from:0,to:mesh.indices.count,by:3).map{i -> MeshTriangle in
        func p(_ j:Int)->Vector3 {let v=mesh.positions[Int(mesh.indices[i+j])];return .init(v.x,-v.z,v.y)}
        return .init(p(0),p(1),p(2))
      }
      try PrintMesh(triangles:triangles).binarySTL().write(to:URL(fileURLWithPath:path),options:.withoutOverwriting);result["path"]=path
    }
    return result
  }
}

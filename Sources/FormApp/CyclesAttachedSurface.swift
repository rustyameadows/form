import CryptoKit
import Foundation
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import simd

/// One frozen parent mapping and one aggregate budget for a rendered attached
/// decoration. Fast picking and manufacturing keep their authored rigid mesh.
struct CyclesAttachedSurface:Sendable {
  let revision:String
  private let coordinates:[SIMD2<Double>],positions:[SIMD3<Double>],normals:[SIMD3<Double>],triangles:[SIMD3<UInt32>]
  private let normalOffsetMM:Double
  @MainActor init?(object:ProductObject,project:Project,frame:(UUID)->ClothFrame?)throws {
    let mesh:ClothMesh,coordinates:[Point2],binding:ClothSurfaceAnchor,parent:ProductObject,current:ClothFrame,rotation:Double
    if let attachment=object.patternAssemblyAttachment {
      guard let source=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let product=try AssemblyProducts.product(for:source,in:project) else {throw FormError.invalid("The attached pattern assembly is unavailable.")}
      parent=source;mesh=product.study.mesh;coordinates=product.materialPointsMm;binding=try attachment.anchor.resolve(in:product);rotation=attachment.rotationDegrees
      current=try frame(source.id) ?? ClothSolver(mesh:mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation).frame
    } else if let attachment=object.clothAttachment {
      guard let source=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let study=source.cloth else {throw FormError.invalid("The attached cloth surface is unavailable.")}
      parent=source;mesh=study.mesh;coordinates=mesh.uv;binding=attachment.anchor;rotation=attachment.rotationDegrees
      current=try frame(source.id) ?? ClothSolver(mesh:mesh,settings:study.settings,colliders:study.colliders,preparation:study.preparation).frame
    } else {return nil}
    _=try binding.placement(mesh:mesh,frame:current)
    guard coordinates.count==mesh.restPositionsMm.count else {throw FormError.invalid("The attached surface has no material coordinates.")}
    func vector(_ p:Vector3)->SIMD3<Double> {.init(p.x,p.y,p.z)}
    let t=mesh.triangles[binding.triangle],w=binding.weights,a=coordinates[t.a],b=coordinates[t.b],c=coordinates[t.c]
    let origin=SIMD2(a.x*w.x+b.x*w.y+c.x*w.z,a.y*w.x+b.y*w.y+c.y*w.z),det=(b.x-a.x)*(c.y-a.y)-(c.x-a.x)*(b.y-a.y)
    guard abs(det)>1e-12 else {throw FormError.invalid("The attached material coordinates have collapsed.")}
    let pa=vector(mesh.restPositionsMm[t.a]),pb=vector(mesh.restPositionsMm[t.b]),pc=vector(mesh.restPositionsMm[t.c])
    let du=((pb-pa)*(c.y-a.y)-(pc-pa)*(b.y-a.y))/det,dv=((pc-pa)*(b.x-a.x)-(pb-pa)*(c.x-a.x))/det
    let uu=simd_dot(du,du),uv=simd_dot(du,dv),vv=simd_dot(dv,dv),metric=uu*vv-uv*uv
    guard metric>1e-16 else {throw FormError.invalid("The attached rest-material surface has collapsed.")}
    let tangent=simd_normalize(du),normal=simd_normalize(simd_cross(pb-pa,pc-pa)),down=simd_cross(tangent,normal),angle=rotation * .pi/180,cs=cos(angle),sn=sin(angle)
    func chart(_ direction:SIMD3<Double>)->SIMD2<Double> {let u=simd_dot(direction,du),v=simd_dot(direction,dv);return .init((u*vv-v*uv)/metric,(v*uu-u*uv)/metric)}
    let fromPatch=simd_double2x2(columns:(chart(tangent*cs+down*sn),chart(-tangent*sn+down*cs)))
    guard abs(simd_determinant(fromPatch))>1e-16 else {throw FormError.invalid("The attached physical coordinate basis has collapsed.")}
    let toPatch=fromPatch.inverse,panel=mesh.panelID(forTriangle:binding.triangle)
    let selected=mesh.triangles.indices.filter{mesh.panelID(forTriangle:$0)==panel},used=Set(selected.flatMap{let t=mesh.triangles[$0];return [t.a,t.b,t.c]}).sorted()
    let remap=Dictionary(uniqueKeysWithValues:used.enumerated().map{($0.element,UInt32($0.offset))})
    let yaw=parent.rotation * .pi/180,yc=cos(yaw),ys=sin(yaw),translation=vector(parent.position)
    func rotate(_ p:Vector3)->SIMD3<Double> {.init(yc*p.x+ys*p.z,p.y,-ys*p.x+yc*p.z)}
    let points=used.map{toPatch*(SIMD2(coordinates[$0].x,coordinates[$0].y)-origin)},positions=used.map{rotate(current.positionsMm[$0])+translation},normals=used.map{rotate(current.normals[$0])}
    let triangles=selected.map{index->SIMD3<UInt32> in let t=mesh.triangles[index];return .init(remap[t.a]!,remap[t.b]!,remap[t.c]!)}
    var digest=SHA256()
    func add(_ value:Double){var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){digest.update(bufferPointer:$0)}}
    add(binding.normalOffsetMm)
    for p in points {add(p.x);add(p.y)};for p in positions+normals {add(p.x);add(p.y);add(p.z)}
    for triangle in triangles {for value in [triangle.x,triangle.y,triangle.z] {var bits=value.littleEndian;withUnsafeBytes(of:&bits){digest.update(bufferPointer:$0)}}}
    revision=digest.finalize().map{String(format:"%02x",$0)}.joined()
    self.coordinates=points;self.positions=positions;self.normals=normals;self.triangles=triangles;normalOffsetMM=binding.normalOffsetMm
  }
  func makeSurface(limits:SceneMaterialSurface.Limits = .init())throws->SceneMaterialSurface {
    try .init(revision:revision,coordinatesMM:coordinates,positionsMM:positions,normals:normals,triangles:triangles,normalOffsetMM:normalOffsetMM,limits:limits)
  }
  @MainActor func localPayload(_ payload:SceneRenderablePayload,node:MeshNode,container:MeshNode)throws->SceneRenderablePayload {
    var result=payload,local=payload.mesh,matrix=container.worldTransform.raw.inverse*node.worldTransform.raw
    matrix.columns.3.x*=100;matrix.columns.3.y*=100;matrix.columns.3.z*=100
    let linear=simd_double3x3(columns:(SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z)))
    guard abs(simd_determinant(linear))>1e-12 else {throw FormError.invalid("The attached render component has a collapsed transform.")}
    local.positionsMM=local.positionsMM.map{let p=matrix*SIMD4($0,1);return .init(p.x,p.y,p.z)}
    local.normals=local.normals.map{SIMD3<Float>(simd_normalize(linear.inverse.transpose*SIMD3<Double>($0)))}
    local.tangents=local.tangents.map{let t=simd_normalize(linear*SIMD3<Double>(Double($0.x),Double($0.y),Double($0.z)));return .init(Float(t.x),Float(t.y),Float(t.z),$0.w*(simd_determinant(linear)<0 ? -1:1))}
    if simd_determinant(linear)<0 {for part in local.parts.indices {for i in stride(from:0,to:local.parts[part].triangleIndices.count,by:3) {local.parts[part].triangleIndices.swapAt(i+1,i+2)}}}
    result.mesh=local;result.transform = .init()
    return result
  }
  @MainActor static func contains(_ node:MeshNode,in container:MeshNode)->Bool {
    var current:MeshNode?=node
    while let value=current {if value === container {return true};current=value.parent}
    return false
  }
  struct Prepared:Sendable {
    var mapping:CyclesAttachedSurface
    var indices:[Int]
    var renderables:[SceneRenderablePayload]
    var curves:[SceneCurvePayload]
  }
  static func deform(_ jobs:[Prepared])throws->[Prepared] {
    var output=[Prepared](),sceneWork=0,sceneTriangles=0,sceneKeys=0
    for var job in jobs {
      try Task.checkCancellation()
      var limits=SceneMaterialSurface.Limits();limits.maximumWork=min(limits.maximumWork,32_000_000-sceneWork)
      limits.maximumTriangles=min(limits.maximumTriangles,2_000_000-sceneTriangles);limits.maximumCurveKeys=min(limits.maximumCurveKeys,2_000_000-sceneKeys)
      let surface=try job.mapping.makeSurface(limits:limits);var budget=surface.makeBudget()
      for i in job.renderables.indices {job.renderables[i].mesh=try surface.deform(job.renderables[i].mesh,budget:&budget)}
      for i in job.curves.indices {
        let original=job.curves[i];var points=[SIMD3<Double>](),radii=[Float](),starts=[UInt32]()
        for strand in original.firstKey.indices {
          let start=Int(original.firstKey[strand]),end=strand+1<original.firstKey.count ? Int(original.firstKey[strand+1]):original.pointsMM.count
          let radius=original.radiiMM[start]
          guard original.radiiMM[start..<end].allSatisfy({$0==radius}),original.uvsMM.isEmpty,original.uvs1MM.isEmpty else {throw FormError.invalid("Attached thread refinement requires the generated constant-radius strand and physical automatic UV mapping.")}
          let mapped=try surface.deformCurve(Array(original.pointsMM[start..<end]),budget:&budget)
          starts.append(UInt32(points.count));points+=mapped;radii+=Array(repeating:radius,count:mapped.count)
        }
        job.curves[i].pointsMM=points;job.curves[i].radiiMM=radii;job.curves[i].firstKey=starts
        job.curves[i].revision=SHA256.hash(data:Data((original.revision+":"+surface.revision).utf8)).map{String(format:"%02x",$0)}.joined()
        try job.curves[i].validate()
      }
      sceneWork+=budget.work;sceneTriangles+=budget.triangles;sceneKeys+=budget.curveKeys;output.append(job)
    }
    return output
  }
  static func prepare(_ jobs:[Prepared])async throws->[Prepared] {
    try Task.checkCancellation()
    let worker=Task.detached(priority:.userInitiated){try deform(jobs)}
    return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
  }
}

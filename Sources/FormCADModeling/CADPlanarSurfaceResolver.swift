import Foundation
import FormCADModel
import FormCADKernel

extension CADModelEvaluator {
  func resolvePlanarSurfaces(_ evaluation: CADModelEvaluation, previous: [CADPlanarSurface]) async throws
    -> (surfaces: [CADResolvedPlanarSurface], issues: [CADSurfaceResolutionIssue]) {
    let definitions=evaluation.definition.surfaces ?? [],values=evaluation.definition.parameterValues
    var resolved:[CADResolvedPlanarSurface]=[],issues:[CADSurfaceResolutionIssue]=[]
    var meshes:[UUID:CADMesh]=[:],faceReports:[UUID:[CADFaceInfo]]=[:]
    for definition in definitions {
      try Task.checkCancellation()
      do {
        guard let shape=evaluation.outputs[definition.outputFeatureID],
              let feature=evaluation.features.first(where:{$0.id==definition.outputFeatureID}) else {
          throw CADModelError("The artwork surface's output feature is unavailable.")
        }
        var surface=try definition.resolved(using:values)
        let selection:CADTopologySelection
        if case let .faceAtCenter(point,tolerance)=definition.selection {
          func scalar(_ value:CADScalar)throws->CADScalar{CADScalar(try CADExpression.evaluate(value.expression,variables:values))}
          selection = .faceAtCenter(point:.init(try scalar(point.x),try scalar(point.y),try scalar(point.z)),tolerance:tolerance)
        }else{selection=definition.selection}
        surface.faceIndex=try await surfaceFaceIndex(selection,source:shape,fingerprint:feature.fingerprint)
        surface.fingerprint=feature.fingerprint
        let faces:[CADFaceInfo]
        if let cached=faceReports[definition.outputFeatureID]{faces=cached}
        else{faces=try await kernel.faces(shape);faceReports[definition.outputFeatureID]=faces}
        guard let face=faces.first(where:{$0.index==surface.faceIndex}),face.surfaceType==0 else {
          throw CADModelError("The selected artwork target is not a planar face.")
        }
        let mesh:CADMesh
        if let cached=meshes[definition.outputFeatureID]{mesh=cached}
        else{mesh=try await self.mesh(for:evaluation,outputID:definition.outputFeatureID,quality:.inspection);meshes[definition.outputFeatureID]=mesh}
        try CADPlanarRegion.validate(surface,mesh:mesh)
        resolved.append(surface)
      }catch is CancellationError{throw CancellationError()}
      catch {
        issues.append(.init(surfaceID:definition.id,outputFeatureID:definition.outputFeatureID,
          code:"unresolved-surface",message:error.localizedDescription))
      }
    }
    let current=Set(definitions.map(\.id))
    for old in previous where !current.contains(old.id) {
      issues.append(.init(surfaceID:old.id,outputFeatureID:old.outputFeatureID,code:"removed-surface",
        message:"The authored surface '\(old.name)' was removed. Review or clear any artwork binding that used '\(old.id)'."))
    }
    return(resolved,issues)
  }
}

/// Proves that the complete authored polygon lies within the selected planar
/// face's inspection mesh. Testing only corners would miss face holes and
/// concave cutouts. Invalid or oversized regions remain explicitly unresolved.
private enum CADPlanarRegion {
  typealias P=CADSurfacePoint2
  static func cross(_ a:P,_ b:P,_ c:P)->Double{(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)}
  static func signedArea(_ polygon:[P])->Double {
    polygon.indices.reduce(0){sum,i in let a=polygon[i],b=polygon[(i+1)%polygon.count];return sum+a.x*b.y-b.x*a.y}/2
  }
  static func validate(_ surface:CADResolvedPlanarSurface,mesh:CADMesh)throws {
    let origin=surface.origin,u=surface.uAxis,v=surface.vAxis
    let normal=CADModelVector(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
    func project(_ p:CADPoint3)throws->P {
      let x=p.x-origin.x,y=p.y-origin.y,z=p.z-origin.z
      guard abs(x*normal.x+y*normal.y+z*normal.z)<=1e-5 else {
        throw CADModelError("The declared artwork frame is not in the selected face's plane.")
      }
      return .init(x*u.x+y*u.y+z*u.z,x*v.x+y*v.y+z*v.z)
    }
    let boundaryTriangles=try triangulate(surface.boundary)
    var faceTriangles:[[P]]=[]
    guard mesh.indices.count==mesh.faceIndices.count*3 else{throw CADModelError("Artwork surface mesh has invalid face ownership.")}
    for index in mesh.faceIndices.indices where mesh.faceIndices[index]==surface.faceIndex {
      guard faceTriangles.count<8192 else{throw CADModelError("The selected planar artwork face exceeds the 8,192-triangle inspection budget.")}
      let vertices=[mesh.indices[index*3],mesh.indices[index*3+1],mesh.indices[index*3+2]]
      guard vertices.allSatisfy({Int($0)<mesh.positions.count}) else{throw CADModelError("Artwork face mesh references a missing vertex.")}
      let triangle=try vertices.map{try project(mesh.positions[Int($0)])}
      if abs(signedArea(triangle))>1e-12{faceTriangles.append(triangle)}
    }
    guard !faceTriangles.isEmpty else{throw CADModelError("The selected planar face has no measurable triangle region.")}
    let area=abs(signedArea(surface.boundary))
    var covered=0.0
    for triangle in boundaryTriangles {
      try Task.checkCancellation()
      for face in faceTriangles {covered+=abs(signedArea(clipped(triangle,by:face)))}
    }
    guard abs(area-covered)<=max(1e-6,area*1e-8) else {
      throw CADModelError("The complete artwork boundary does not fit the selected planar face; it crosses a trim edge, hole or cutout.")
    }
  }
  static func triangulate(_ source:[P])throws->[[P]] {
    guard (3...128).contains(source.count),abs(signedArea(source))>1e-8 else{throw CADModelError("Artwork boundary has no positive physical area.")}
    let epsilon=1e-10
    for i in source.indices {
      let a=source[i],b=source[(i+1)%source.count]
      guard hypot(b.x-a.x,b.y-a.y)>1e-7 else{throw CADModelError("Artwork boundary contains a repeated or zero-length edge.")}
      for j in source.indices where j>i && j != (i+1)%source.count && i != (j+1)%source.count {
        let c=source[j],d=source[(j+1)%source.count],abC=cross(a,b,c),abD=cross(a,b,d),cdA=cross(c,d,a),cdB=cross(c,d,b)
        if min(a.x,b.x)<=max(c.x,d.x)+epsilon && min(c.x,d.x)<=max(a.x,b.x)+epsilon &&
           min(a.y,b.y)<=max(c.y,d.y)+epsilon && min(c.y,d.y)<=max(a.y,b.y)+epsilon &&
           abC*abD<=epsilon && cdA*cdB<=epsilon {
          throw CADModelError("Artwork boundary crosses or touches itself.")
        }
      }
    }
    var points=signedArea(source)>0 ? source:Array(source.reversed())
    var triangles:[[P]]=[]
    while points.count>3 {
      var removed=false
      for i in points.indices {
        let before=(i+points.count-1)%points.count,after=(i+1)%points.count
        let a=points[before],b=points[i],c=points[after],turn=cross(a,b,c)
        if abs(turn)<=epsilon {points.remove(at:i);removed=true;break}
        guard turn>0 else{continue}
        let contains=points.indices.contains{j in j != before && j != i && j != after && cross(a,b,points[j])>=(-epsilon) && cross(b,c,points[j])>=(-epsilon) && cross(c,a,points[j])>=(-epsilon)}
        if !contains {triangles.append([a,b,c]);points.remove(at:i);removed=true;break}
      }
      guard removed,points.count>=3 else{throw CADModelError("Artwork boundary could not form a valid simple region.")}
    }
    guard cross(points[0],points[1],points[2])>epsilon else{throw CADModelError("Artwork boundary has a degenerate closing region.")}
    triangles.append(points);return triangles
  }
  static func clipped(_ subject:[P],by triangle:[P])->[P] {
    var polygon=subject
    let orientation=signedArea(triangle)>=0 ? 1.0:-1.0
    for i in triangle.indices {
      guard let last=polygon.last else{return []}
      let a=triangle[i],b=triangle[(i+1)%3],input=polygon;polygon=[]
      func side(_ p:P)->Double{orientation*cross(a,b,p)}
      var previous=last,wasInside=side(last)>=(-1e-10)
      for point in input {
        let inside=side(point)>=(-1e-10)
        if inside != wasInside {
          let first=side(previous),second=side(point),fraction=first/(first-second)
          polygon.append(.init(previous.x+(point.x-previous.x)*fraction,previous.y+(point.y-previous.y)*fraction))
        }
        if inside{polygon.append(point)}
        previous=point;wasInside=inside
      }
    }
    return polygon
  }
}

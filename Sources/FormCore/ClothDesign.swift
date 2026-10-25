import Foundation
import simd

public struct ClothAttachment:Codable,Equatable,Sendable {
  public var surfaceObjectID:UUID
  public var anchor:ClothSurfaceAnchor
  public var rotationDegrees:Double
  public init(surfaceObjectID:UUID,anchor:ClothSurfaceAnchor,rotationDegrees:Double = 0) {self.surfaceObjectID=surfaceObjectID;self.anchor=anchor;self.rotationDegrees=rotationDegrees}
}
public enum ClothDesign {
  public static let recipeIDs:Set<String>=["clothPanel","clothTote"]
  public static let recipes:[Recipe]=[
    .init("clothPanel","Fabric drape","square.3.layers.3d","A real flexible sheet, with one declared support pin and analytic sphere/floor contacts. Uncalibrated study, not a printable solid.",[
      .init("width","Panel width",320,100...800),.init("depth","Panel height",300,100...800),
      .init("densityGSM","Declared areal mass",220,10...1000,unit:"GSM"),.init("resolution","Cells per axis",16,4...32,unit:"cells"),
      .init("supportRadius","Support radius",70,20...180)]),
    .init("clothTote","Seamed panels","bag","Two actually simulated panels with paired side/bottom seams and fixed open-top points. No self-collision or calibrated fit.",[
      .init("width","Panel width",220,100...600),.init("depth","Panel height",260,100...700),
      .init("densityGSM","Declared areal mass",200,10...1000,unit:"GSM"),.init("resolution","Cells per axis",16,4...24,unit:"cells")])]
  public static func definition(for object:ProductObject,settings:ClothSettings? = nil)throws -> ClothStudy {
    guard recipeIDs.contains(object.recipeID),let recipe=recipes.first(where:{$0.id==object.recipeID}) else {throw FormError.invalid("Choose a supported cloth template.")}
    try recipe.validate(object.parameters)
    let resolution=object["resolution"]
    guard resolution==resolution.rounded() else {throw FormError.invalid("Cloth mesh resolution must use whole cells.")}
    let cells=Int(resolution),width=object["width"],height=object["depth"],density=object["densityGSM"]/1000
    var solver=settings ?? .init()
    if settings==nil {solver.substeps=8;solver.iterations=6;solver.velocityDampingPerSecond=1.5}
    let mesh:ClothMesh,colliders:[ClothCollider]
    if object.recipeID=="clothTote" {
      mesh=try ClothMeshes.seamedPanels(widthMm:width,heightMm:height,columns:cells,rows:cells,areaDensityKgPerM2:density)
      colliders=[.plane()]
    } else {
      let radius=object["supportRadius"],surface=2*radius+solver.collisionThicknessMm/2
      var sheet=try ClothMeshes.rectangle(widthMm:width,heightMm:height,columns:cells,rows:cells,areaDensityKgPerM2:density,originMm:.init(0,2*radius+55,0))
      let middle=cells/2,index=middle*(cells+1)+middle,rest=sheet.restPositionsMm[index]
      // Odd resolutions place their nearest central vertex away from the pole;
      // target the same material x/z on the inflated support's top hemisphere.
      let offset=rest.x*rest.x+rest.z*rest.z,r=radius+solver.collisionThicknessMm/2
      let pinY=radius+sqrt(max(0,r*r-offset))
      sheet.pins=[.init(index,targetMm:.init(rest.x,offset<r*r ? pinY:surface,rest.z))]
      mesh=sheet;colliders=[.sphere(centerMm:.init(0,radius,0),radiusMm:radius),.plane()]
    }
    let result=ClothStudy(mesh:mesh,settings:solver,colliders:colliders);try result.validate();return result
  }
}
extension Project {
  public func validateCloth()throws {
    for object in objects {
      if ClothDesign.recipeIDs.contains(object.recipeID),object.cloth==nil {throw FormError.invalid("Cloth templates require a valid initial flexible surface.")}
      if let cloth=object.cloth {
        guard !object.isCanvasWorkspace,object.textile==nil,object.clothAttachment==nil else {throw FormError.invalid("Cloth studies require independent flexible surfaces; convert a separate panel instead of replacing a garment, decoration or Canvas workspace.")}
        try cloth.validate()
      }
      if let attachment=object.clothAttachment {
        guard object.cloth==nil,object.textile?.attachment==nil,attachment.surfaceObjectID != object.id,
          let surface=objects.first(where:{$0.id==attachment.surfaceObjectID}),let study=surface.cloth,
          attachment.rotationDegrees.isFinite,abs(attachment.rotationDegrees)<=36000 else {throw FormError.invalid("Attach a separate object to an existing cloth surface. Detach its decorations before removing that surface.")}
        _ = try attachment.anchor.placement(mesh:study.mesh,frame:ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders).frame)
      }
    }
  }
  public mutating func setCloth(_ study:ClothStudy?,for id:UUID)throws {
    var candidate=self;try candidate.applyClothDefinition(study,for:id);self=candidate
  }
  private mutating func applyClothDefinition(_ study:ClothStudy?,for id:UUID)throws {
    guard let index=objects.firstIndex(where:{$0.id==id}),!objects[index].locked else {throw FormError.invalid("Choose an unlocked cloth object.")}
    let old=objects[index].cloth
    if let study {try study.validate()}
    if study==nil,objects.contains(where:{$0.clothAttachment?.surfaceObjectID==id}) {throw FormError.invalid("Detach decorations before removing this cloth surface.")}
    if let old,let study,old.mesh != study.mesh {
      for i in objects.indices where objects[i].clothAttachment?.surfaceObjectID==id {
        let anchor=objects[i].clothAttachment!.anchor
        let uv=try old.mesh.materialPoint(anchor),panel=old.mesh.panelID(forTriangle:anchor.triangle)
        objects[i].clothAttachment?.anchor=try study.mesh.anchor(at:uv,panel:panel,normalOffsetMm:anchor.normalOffsetMm)
      }
    }
    objects[index].cloth=study
    try validateCloth()
  }
}

extension Project {
  public func clothPlacement(_ object:ProductObject,frame supplied:ClothFrame? = nil)throws -> ClothSurfacePlacement? {
    guard let attachment=object.clothAttachment,let parent=objects.first(where:{$0.id==attachment.surfaceObjectID}),let study=parent.cloth else {return nil}
    let frame=try supplied ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders).frame
    let local=try attachment.anchor.placement(mesh:study.mesh,frame:frame),angle=parent.rotation * .pi/180,c=cos(angle),s=sin(angle)
    func rotated(_ p:Vector3)->Vector3 {.init(c*p.x+s*p.z,p.y,-s*p.x+c*p.z)}
    let normal=rotated(local.normal),tangent=rotated(local.materialTangent),position=rotated(local.positionMm)
    let a=attachment.rotationDegrees * .pi/180,bitangent=Vector3(tangent.y*normal.z-tangent.z*normal.y,tangent.z*normal.x-tangent.x*normal.z,tangent.x*normal.y-tangent.y*normal.x)
    return .init(positionMm:.init(position.x+parent.position.x,position.y+parent.position.y,position.z+parent.position.z),normal:normal,materialTangent:.init(tangent.x*cos(a)+bitangent.x*sin(a),tangent.y*cos(a)+bitangent.y*sin(a),tangent.z*cos(a)+bitangent.z*sin(a)))
  }
}

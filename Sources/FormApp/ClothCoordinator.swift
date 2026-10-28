import Foundation
import SceneKit
import FormCore
import FormGraphics

@MainActor final class ClothCoordinator {
  weak var store:StudioStore?
  let preview=ClothPreviewController()
  private var requestedObjectID:UUID?
  private var requestedProjectID:UUID?
  init(store:StudioStore) {
    self.store=store
    preview.onFrame={ [weak self] _,frame in
      guard let self,let store=self.store,let identity=self.preview.source,identity.projectID==store.project?.id else {return}
      store.scene?.updateClothFrame(frame,objectID:identity.objectID)
    }
  }
  func activate(_ id:UUID)throws {
    guard let project=store?.project,let object=project.objects.first(where:{$0.id==id}),object.isFlexibleSurface else {throw FormError.invalid("Choose a configured cloth surface.")}
    requestedObjectID=id;requestedProjectID=project.id
    let previous=preview.source?.objectID
    do {
      let identity=ClothSceneSurface.sourceIdentity(object:object,project:project),product=try AssemblyProducts.product(for:object,in:project)
      if let product {for child in project.objects where child.patternAssemblyAttachment?.surfaceObjectID==id {_ = try child.patternAssemblyAttachment!.anchor.resolve(in:product)}}
      // The identity covers stored source and resolved visual dependencies. No
      // large derived-mesh revalidation/hash is needed for an unchanged source.
      if preview.source==identity {return}
      guard let study=object.cloth ?? product?.study else {throw FormError.invalid("Choose a configured cloth surface.")}
      if try preview.bind(identity,study:study),let previous,previous != id {store?.scene?.resetClothFrame(objectID:previous)}
    } catch {
      if let previous,previous != id {preview.clear();store?.scene?.resetClothFrame(objectID:previous)}
      throw error
    }
  }
  func reconcile() {
    guard let id=preview.source?.objectID ?? requestedObjectID else {return}
    guard let store,!store.showingHome,store.project?.id==(preview.source?.projectID ?? requestedProjectID),store.project?.objects.contains(where:{$0.id==id && $0.isFlexibleSurface})==true else {clear();return}
    do {try activate(id)}catch {preview.clear();requestedObjectID=id;preview.report(error)}
  }
  func clear() {let old=preview.source?.objectID ?? requestedObjectID;requestedObjectID=nil;requestedProjectID=nil;preview.clear();if let old {store?.scene?.resetClothFrame(objectID:old)}}
  func historyChanged() {
    guard let id=preview.source?.objectID ?? requestedObjectID else {return}
    preview.clear()
    do {try activate(id)}catch {clear()}
  }
  func frame(for object:ProductObject,in project:Project)->ClothFrame? {
    guard preview.source==ClothSceneSurface.sourceIdentity(object:object,project:project) else {return nil};return preview.frame
  }
  func frame(for objectID:UUID,projectID:UUID)->ClothFrame? {
    guard preview.source?.projectID==projectID,preview.source?.objectID==objectID else {return nil};return preview.frame
  }
  func placement(of object:ProductObject,in project:Project)throws -> ClothSurfacePlacement? {
    if let attachment=object.patternAssemblyAttachment {
      guard let parent=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let product=try AssemblyProducts.product(for:parent,in:project) else {throw FormError.invalid("The attached assembly surface is unavailable.")}
      let current=try frame(for:parent,in:project) ?? ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation).frame
      let local=try attachment.anchor.placement(in:product,frame:current)
      return project.worldClothPlacement(local,parent:parent,rotationDegrees:attachment.rotationDegrees)
    }
    guard let attachment=object.clothAttachment else {return nil}
    return try project.clothPlacement(object,frame:frame(for:attachment.surfaceObjectID,projectID:project.id))
  }
  func reposition(_ objectID:UUID,to position:Vector3,in project:inout Project)throws {
    if let index=project.objects.firstIndex(where:{$0.id==objectID}),let attachment=project.objects[index].patternAssemblyAttachment,
      let parent=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let product=try AssemblyProducts.product(for:parent,in:project) {
      let angle=parent.rotation * .pi/180,c=cos(angle),s=sin(angle),dx=position.x-parent.position.x,dz=position.z-parent.position.z
      let local=Vector3(c*dx-s*dz,position.y-parent.position.y,s*dx+c*dz),current=try frame(for:parent,in:project) ?? ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation).frame
      guard let panel=product.panels.first(where:{$0.id==attachment.anchor.panel}) else {throw FormError.invalid("The attached assembly panel is unavailable.")}
      let anchor=try product.study.mesh.closestAnchor(to:local,frame:current,panel:panel.panelIndex,normalOffsetMm:attachment.anchor.normalOffsetMm),t=product.study.mesh.triangles[anchor.triangle],w=anchor.weights
      let a=product.materialPointsMm[t.a],b=product.materialPointsMm[t.b],d=product.materialPointsMm[t.c]
      project.objects[index].patternAssemblyAttachment?.anchor.materialPointMm = .init(a.x*w.x+b.x*w.y+d.x*w.z,a.y*w.x+b.y*w.y+d.y*w.z)
      return
    }
    guard let index=project.objects.firstIndex(where:{$0.id==objectID}),let attachment=project.objects[index].clothAttachment,let parent=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let study=parent.cloth else {return}
    let angle=parent.rotation * .pi/180,c=cos(angle),s=sin(angle),dx=position.x-parent.position.x,dz=position.z-parent.position.z
    let local=Vector3(c*dx-s*dz,position.y-parent.position.y,s*dx+c*dz),current=try frame(for:parent,in:project) ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders,preparation:study.preparation).frame
    let anchor=try study.mesh.closestAnchor(to:local,frame:current,panel:study.mesh.panelID(forTriangle:attachment.anchor.triangle),normalOffsetMm:attachment.anchor.normalOffsetMm)
    project.objects[index].clothAttachment?.anchor=anchor
  }
}

import Foundation
import SceneKit
import FormCore
import FormGraphics

@MainActor final class ClothCoordinator {
  weak var store:StudioStore?
  let preview=ClothPreviewController()
  init(store:StudioStore) {
    self.store=store
    preview.onFrame={ [weak self] _,frame in
      guard let self,let store=self.store,let identity=self.preview.source,identity.projectID==store.project?.id else {return}
      store.scene?.updateClothFrame(frame,objectID:identity.objectID)
    }
  }
  func activate(_ id:UUID)throws {
    guard let project=store?.project,let object=project.objects.first(where:{$0.id==id}),let study=object.cloth else {throw FormError.invalid("Choose a configured cloth surface.")}
    let previous=preview.source?.objectID
    if try preview.bind(ClothSceneSurface.sourceIdentity(object:object,project:project),study:study),let previous,previous != id {store?.scene?.resetClothFrame(objectID:previous)}
  }
  func reconcile() {
    guard let id=preview.source?.objectID else {return}
    guard let store,!store.showingHome,store.project?.id==preview.source?.projectID,store.project?.objects.contains(where:{$0.id==id && $0.cloth != nil})==true else {clear();return}
    do {try activate(id)}catch {preview.report(error);clear()}
  }
  func clear() {let old=preview.source?.objectID;preview.clear();if let old {store?.scene?.resetClothFrame(objectID:old)}}
  func historyChanged() {
    guard let id=preview.source?.objectID else {return}
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
    guard let attachment=object.clothAttachment else {return nil}
    return try project.clothPlacement(object,frame:frame(for:attachment.surfaceObjectID,projectID:project.id))
  }
  func reposition(_ objectID:UUID,to position:Vector3,in project:inout Project)throws {
    guard let index=project.objects.firstIndex(where:{$0.id==objectID}),let attachment=project.objects[index].clothAttachment,let parent=project.objects.first(where:{$0.id==attachment.surfaceObjectID}),let study=parent.cloth else {return}
    let angle=parent.rotation * .pi/180,c=cos(angle),s=sin(angle),dx=position.x-parent.position.x,dz=position.z-parent.position.z
    let local=Vector3(c*dx-s*dz,position.y-parent.position.y,s*dx+c*dz),current=try frame(for:parent,in:project) ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders).frame
    let anchor=try study.mesh.closestAnchor(to:local,frame:current,panel:study.mesh.panelID(forTriangle:attachment.anchor.triangle),normalOffsetMm:attachment.anchor.normalOffsetMm)
    project.objects[index].clothAttachment?.anchor=anchor
  }
}

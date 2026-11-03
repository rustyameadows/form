import AppKit
import FormCore

/// A report points to editable source identities, never a rendered master clone.
/// Capture project ownership when the report is made so a stale popover cannot
/// navigate an identically named (or imported) document in another project.
struct PublicationPreflightTarget:Equatable {
  let projectID:UUID
  let publicationID:UUID
  let objectID:UUID
  let elementID:UUID?
  let affectedPageObjectID:UUID?
  let renderedElementID:UUID?
  let instanceObjectID:UUID?
  let instanceElementID:UUID?

  init?(issue:[String:Any],projectID:UUID,publicationID:UUID) {
    func id(_ key:String)->UUID? {(issue[key] as? String).flatMap(UUID.init(uuidString:))}
    guard let object=id("object_id") ?? id("page_object_id") ?? id("page_id") else{return nil}
    self.projectID=projectID;self.publicationID=publicationID;objectID=object
    elementID=id("element_id");affectedPageObjectID=id("page_object_id") ?? id("page_id")
    renderedElementID=id("rendered_element_id");instanceObjectID=id("instance_object_id");instanceElementID=id("instance_element_id")
  }

  func isAvailable(in project:Project)->Bool {
    guard project.id==projectID,let document=project.publications?.first(where:{$0.id==publicationID}),
      let object=project.objects.first(where:{$0.id==objectID}) else{return false}
    let isPage=document.pages.contains{$0.objectID==objectID}
    let isMaster=document.masters?.contains{$0.sourceObjectID==objectID}==true
    if let affectedPageObjectID,!document.pages.contains(where:{$0.objectID==affectedPageObjectID}) {return false}
    if let renderedElementID,let affectedPageObjectID {
      guard let sources=try? project.publicationTextSources(for:affectedPageObjectID),let source=sources[renderedElementID],
        source.objectID==objectID,source.elementID==elementID,
        source.instanceObjectID==instanceObjectID,source.instanceElementID==instanceElementID else{return false}
    }else if !isPage && !isMaster {return false}
    if let elementID {return project.editableArtwork(object)?.elements.contains{$0.id==elementID}==true}
    return true
  }
}

extension PublicationWorkspaceController {
  @discardableResult func focusPreflightIssue(_ target:PublicationPreflightTarget)->Bool {
    guard let project,let session,target.isAvailable(in:project) else{return false}
    // Validate before committing any draft. Marked text remains owned by the IME.
    guard session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true,
      session.canvas?.activeTextView?.hasMarkedText() != true else{return false}
    session.canvas?.finishText()
    guard let current=self.project,target.isAvailable(in:current) else{return false}
    session.store?.showSurface(.artwork,ensureCanvasIfNeeded:false)
    let document=current.publications!.first{$0.id==target.publicationID}!
    if document.masters?.contains(where:{$0.sourceObjectID==target.objectID})==true {
      guard focusMaster(target.objectID,publicationID:target.publicationID) else{return false}
    }else if document.pages.contains(where:{$0.objectID==target.objectID}) {
      open(target.publicationID);focusPage(target.objectID)
    }else if let instanceObjectID=target.instanceObjectID,let instanceElementID=target.instanceElementID {
      session.activate(target.objectID)
      session.componentReturn = .init(objectID:instanceObjectID,linkedTargetID:nil,instanceID:instanceElementID)
      _=session.canvas?.fit(frameIDs:[target.objectID])
    }else{return false}
    if let id=target.elementID {
      session.scopeID=current.objects.first{$0.id==target.objectID}.flatMap{current.editableArtwork($0)}?.elements.first{$0.id==id}?.parentID
      session.choose([id])
    }
    session.objectWillChange.send();session.canvas?.synchronize()
    return true
  }
}

import Foundation

extension PublicationCommands {
  /// Change the whole document's physical trim without fitting or translating
  /// canonical artwork. Declared folded sheets retain their identities, stock,
  /// print intent and gathered order; only their physical extent changes.
  public static func resizePages(in project:inout Project,publicationID:UUID,width:Double,height:Double)throws {
    guard width.isFinite,height.isFinite,(20...2000).contains(width),(20...2000).contains(height),
      let document=project.publications?.first(where:{$0.id==publicationID}),(1...200).contains(document.pages.count),
      Set(document.pages.map(\.id)).count==document.pages.count,Set(document.pages.map(\.objectID)).count==document.pages.count else {
      throw FormError.invalid("Choose a nonempty publication and a uniform 20–2000 mm trim width and height.")
    }
    let ids=Set(document.pages.map(\.objectID))
    try ensureIndependentPageOwners(ids,in:project)
    var candidate=project
    for entry in document.pages {
      let page=try ArtworkPageSetup.source(project,objectID:entry.objectID)
      guard page.sheetAssembly==nil,let index=candidate.objects.firstIndex(where:{$0.id==page.id}) else {
        throw FormError.invalid("Publication trim requires independent rectangular page artwork.")
      }
      candidate.objects[index].parameters["width"]=width
      candidate.objects[index].parameters["depth"]=height
    }
    for index in candidate.objects.indices {
      guard let definition=project.objects[index].sheetAssembly,definition.publicationID==publicationID else{continue}
      // A resize is not a repair/reimposition of malformed saved parent slots.
      // Validate their current registration before changing page dimensions.
      _ = try project.sheetParentAssignments(definition,document:document)
      guard let parents=definition.parentSheets,!parents.isEmpty else{continue}
      let extent=Point2(width*2,height)
      if parents.contains(where:{$0.sizeMM != extent}) {
        guard !candidate.objects[index].locked else{throw FormError.invalid("Unlock the physical sheet assembly before resizing its parent sheets.")}
        for parent in parents.indices {candidate.objects[index].sheetAssembly!.parentSheets![parent].sizeMM=extent}
      }
    }
    // Crop validation must follow the dimension DAG: cover, spine, edge and
    // jacket source extents/explicit anchors can depend on the new trim.
    try candidate.reconcilePhysicalDimensions(previous:project)
    for id in ids {
      guard let old=project.objects.first(where:{$0.id==id}),let changed=candidate.objects.first(where:{$0.id==id}),
        changed.artworkSize==Point2(width,height),changed.artwork==old.artwork else {
        throw FormError.invalid("Page trim and artwork have another parameter or anchor authority. Detach that relationship before resizing; page artwork must keep its physical scale and position.")
      }
    }
    try candidate.validateArtworkLinks()
    project=candidate
  }
}

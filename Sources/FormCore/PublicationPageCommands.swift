import Foundation

extension PublicationCommands {
  /// Opening a publication is a view of its current implicit leaves. Source page
  /// edits may reduce that count; retarget the preview in the same transaction.
  /// Explicit physical mappings retain their authored references and must validate.
  public static func reconcileImplicitAssemblyPreviews(in project:inout Project,publicationID:UUID?=nil) {
    for index in project.objects.indices {
      guard let definition=project.objects[index].sheetAssembly,definition.leaves==nil,
        definition.parentSheets?.isEmpty != false,
        publicationID==nil || definition.publicationID==publicationID,
        let document=project.publications?.first(where:{$0.id==definition.publicationID}) else{continue}
      let count=document.leafPairs().count
      if definition.activeSpread>count {project.objects[index].sheetAssembly!.activeSpread=count}
    }
  }
  public static func insertPages(in project:inout Project,publicationID:UUID,pageIDs:[UUID],at:Int)throws {
    var candidate=project
    guard var document=candidate.publications?.first(where:{$0.id==publicationID}),(0...document.pages.count).contains(at),
      !pageIDs.isEmpty,Set(pageIDs).count==pageIDs.count,Set(pageIDs).isDisjoint(with:Set(document.pages.map(\.objectID))) else{throw FormError.invalid("Insert distinct new physical pages at an index in the publication.")}
    document.pages.insert(contentsOf:pageIDs.map{PublicationPage(objectID:$0)},at:at)
    try setPublication(in:&candidate,document:document);try candidate.validateSheetAssemblies();project=candidate
  }
  /// Removing membership/capacity preserves every original story character. The
  /// optional physical deletion is validated against remaining project sources.
  public static func removePages(in project:inout Project,publicationID:UUID,pageIDs:Set<UUID>,deleteObjects:Bool=false)throws {
    var candidate=project
    guard var document=candidate.publications?.first(where:{$0.id==publicationID}),!pageIDs.isEmpty,
      pageIDs.isSubset(of:Set(document.pages.map(\.objectID))) else{throw FormError.invalid("Choose existing publication pages to remove.")}
    for object in candidate.objects where pageIDs.contains(object.id) {guard !object.locked else{throw FormError.invalid("Unlock a page before removing it.")}}
    let frames=(candidate.textStories ?? []).flatMap(\.frames).filter{pageIDs.contains($0.objectID)}
    if !frames.isEmpty {try unlinkFrames(in:&candidate,frames:frames)}
    document.pages.removeAll{pageIDs.contains($0.objectID)}
    try setPublication(in:&candidate,document:document)
    if deleteObjects {candidate.objects.removeAll{pageIDs.contains($0.id)}}
    try candidate.validateArtworkLinks();project=candidate
  }
  @discardableResult public static func duplicatePublicationPage(in project:inout Project,publicationID:UUID,objectID:UUID,at:Int?=nil)throws->UUID {
    var candidate=project
    guard let document=candidate.publications?.first(where:{$0.id==publicationID}),let index=document.pages.firstIndex(where:{$0.objectID==objectID}),
      let source=candidate.objects.first(where:{$0.id==objectID}),!source.locked else{throw FormError.invalid("Choose an unlocked physical publication page to duplicate.")}
    let destination=at ?? index+1
    guard (0...document.pages.count).contains(destination) else{throw FormError.invalid("Choose an insertion index within the publication.")}
    var copy=source;copy.id=UUID();copy.designID=UUID();copy.parentIterationID=source.id;copy.groupID=nil;copy.relationship="iteration";copy.name=source.name+" · copy"
    copy.position.x+=source.artworkSize.x+36
    if let p=copy.artwork?.canvasPosition {copy.artwork?.canvasPosition = .init(p.x+source.artworkSize.x+36,p.y)}
    candidate.objects.append(copy)
    var changed=document
    changed.pages.insert(.init(objectID:copy.id,margins:document.pages[index].margins,masterIDs:document.pages[index].masterIDs),at:destination)
    // Store membership before reconciliation so the ordinary story ordering path
    // inserts the duplicated empty references as additional source capacity.
    let publicationIndex=candidate.publications!.firstIndex{$0.id==publicationID}!
    candidate.publications![publicationIndex]=changed
    if let artwork=copy.artwork {try reconcileFrames(in:&candidate,objectID:copy.id,artwork:artwork)}
    try setPublication(in:&candidate,document:changed);try candidate.validateArtworkLinks();project=candidate;return copy.id
  }
  @discardableResult public static func addPages(in project:inout Project,publicationID:UUID,count:Int,width:Double=160,height:Double=210,storyID:UUID?=nil,columns:Int=1,gutter:Double=8,at:Int?=nil)throws->[UUID] {
    guard (1...200).contains(count) else{throw FormError.invalid("Create one to 200 physical pages in a single operation.")}
    var candidate=project;var ids:[UUID]=[]
    for offset in 0..<count {
      let inserted=try addPage(in:&candidate,publicationID:publicationID,width:width,height:height,storyID:storyID,columns:columns,gutter:gutter,at:at.map{$0+offset})
      ids.append(inserted.0)
    }
    try candidate.validateArtworkLinks();project=candidate;return ids
  }
  public static func replaceStoryText(in project:inout Project,storyID:UUID,range:NSRange,text:String)throws {
    guard let story=project.textStories?.first(where:{$0.id==storyID}) else{throw FormError.missing("Text story not found.")}
    let replacement=try PublicationTextEdits.replacing(story.sourceElement,range:range,with:text)
    try setSource(in:&project,storyID:storyID,source:replacement)
  }
}

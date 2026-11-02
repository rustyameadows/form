import AppKit
import Combine
import FormCore
import FormGraphics

/// A navigation/authoring lens over ordinary Canvas artboards. No page artwork,
/// text fragments or independent viewport is owned by this controller.
@MainActor final class PublicationWorkspaceController:ObservableObject {
  weak var session:ArtworkSession?
  @Published private(set) var isVisible=false
  @Published private(set) var publicationID:UUID?
  @Published var showsSpreads=true {didSet{frameRevision &+= 1;session?.objectWillChange.send();session?.canvas?.synchronize()}}
  @Published private(set) var frameRevision=0
  private var viewAnchor=CGPoint(x:36,y:40)
  @Published private(set) var issue:String?
  private var projectID:UUID?
  private var readingCanonicalFrames=false
  init(session:ArtworkSession){self.session=session}
  var project:Project? {session?.store?.project}
  var documents:[PublicationDocument] {project?.publications ?? []}
  var document:PublicationDocument? {
    guard projectID==project?.id else{return nil}
    return documents.first{$0.id==publicationID}
  }
  var currentPageID:UUID? {
    guard let document else{return nil}
    return document.pages.first{$0.objectID==session?.objectID}?.objectID
  }
  var stories:[TextStory] {
    guard let document else{return []}
    return (project?.textStories ?? []).filter{$0.publicationID==document.id}
  }
  var activeStory:TextStory? {
    session?.selectedTextStory.flatMap{value in stories.first{$0.id==value.id}} ?? stories.first
  }
  var spreads:[PublicationSpread] {document?.spreads() ?? []}
  func open(_ id:UUID?=nil) {
    guard let project else{return}
    projectID=project.id
    let current=documents.first{$0.pages.contains{$0.objectID==session?.objectID}}
    publicationID=documents.first{$0.id==id}?.id ?? current?.id ?? documents.first{$0.id==publicationID}?.id ?? documents.first?.id
    // Read the canonical page placement before enabling the view-only spread lens.
    isVisible=false;frameRevision &+= 1
    if let first=document?.pages.first,let object=project.objects.first(where:{$0.id==first.objectID}) {
      if let position=object.artwork?.canvasPosition {viewAnchor = .init(x:position.x,y:position.y)}
      else if let frame=session?.frames.first(where:{$0.id==first.objectID}) {viewAnchor=frame.rect.origin}
    }
    isVisible=true;frameRevision &+= 1;issue=nil
    session?.objectWillChange.send();session?.canvas?.synchronize()
    if let id=currentPageID ?? document?.pages.first?.objectID {focusPage(id,deferFit:true)}
  }
  func toggle(){isVisible ? close():open()}
  func close(){isVisible=false;frameRevision &+= 1;session?.objectWillChange.send();session?.canvas?.synchronize()}
  func reset(){
    guard isVisible || publicationID != nil || projectID != nil || issue != nil else{return}
    isVisible=false;frameRevision &+= 1;publicationID=nil;projectID=nil;issue=nil;session?.objectWillChange.send()
  }
  func reconcile() {
    guard projectID != nil else{return}
    guard project?.id==projectID else{reset();return}
    if publicationID != nil,!documents.contains(where:{$0.id==publicationID}) {publicationID=documents.first?.id}
    objectWillChange.send()
  }
  /// Facing layout belongs to the publication, independently of its navigator.
  /// Canonical positions remain available for placing unrelated new documents.
  func layoutFrames(_ values:[CanvasFrame])->[CanvasFrame] {
    guard !readingCanonicalFrames,let project else{return values}
    return CanvasPublicationSpreads.applying(to:values,project:project)
  }
  func frameRect(for id:UUID,size:CGSize)->CGRect? {
    guard !readingCanonicalFrames,let frame=session?.frames.first(where:{$0.object.id==id && $0.publicationSpread != nil}) else{return nil}
    return frame.rect
  }
  func focusPage(_ id:UUID,deferFit:Bool=false) {
    guard let session,let document,document.pages.contains(where:{$0.objectID==id}) else{return}
    issue=nil
    if let editor=session.canvas?.storyEditor,
      let frame=editor.composition.context.frames.first(where:{$0.frame.objectID==id})?.frame {
      session.focusStoryFrame(frame)
    } else {session.activate(id);session.choose([])}
    session.objectWillChange.send();session.canvas?.synchronize()
    let ids:Set<UUID>
    if document.layout?.facingPages==true,let spread=document.spreads().first(where:{$0.pages.contains{$0.objectID==id}}) {ids=Set(spread.pages.map(\.objectID))}
    else {ids=[id]}
    if deferFit {
      let expectedProject=projectID,expectedDocument=document.id,revision=frameRevision
      DispatchQueue.main.async{[weak self] in
        guard let self,self.isVisible,self.frameRevision==revision,self.project?.id==expectedProject,
          self.document?.id==expectedDocument,self.currentPageID==id else{return}
        // Let the floating rail mount and publish its real viewport occlusion
        // before fitting. Closing/navigating in the meantime cancels this focus.
        self.session?.canvas?.window?.contentView?.layoutSubtreeIfNeeded()
        _=self.session?.canvas?.fit(frameIDs:ids)
      }
    }else{_=session.canvas?.fit(frameIDs:ids)}
  }
  func navigate(_ delta:Int) {
    guard let document,let current=currentPageID,let index=document.pages.firstIndex(where:{$0.objectID==current}) else{return}
    if showsSpreads,let current=spreads.firstIndex(where:{$0.pages.contains{$0.objectID==current}}) {
      let next=current+delta
      if spreads.indices.contains(next),let page=spreads[next].pages.first {focusPage(page.objectID)}
    }else{
      let next=index+delta
      if document.pages.indices.contains(next){focusPage(document.pages[next].objectID)}
    }
  }
  @discardableResult private func edit(_ label:String,_ body:(inout Project)throws->Void)->Bool {
    guard let session,let store=session.store,let source=store.project,source.id==projectID else{return false}
    do {
      guard session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else{throw FormError.invalid("Finish the current text input before changing publication pages.")}
      // Rejected commands must not close a native text draft or alter its Undo.
      var proposal=source;try body(&proposal);try proposal.validatePublications()
      session.canvas?.finishText()
      guard store.project?.id==source.id else{throw FormError.invalid("The publication's project changed.")}
      try store.engine.edit(label,source:"Studio",body)
      issue=nil;store.changed();reconcile();return true
    }catch{issue=error.localizedDescription;store.error=error.localizedDescription;return false}
  }
  private func canonicalCanvasRightEdge()->Double {
    // The frame memo remains canonical. Suppress only this transient lens while
    // querying placement, without publishing a visibility change or moving art.
    let previous=readingCanonicalFrames;readingCanonicalFrames=true
    defer{readingCanonicalFrames=previous}
    return Double(session?.frames.filter{!$0.isWorkspace}.map(\.rect.maxX).max() ?? -24)
  }
  @discardableResult func create(name:String,width:Double=148,height:Double=210,pageCount:Int=4,columns:Int=1,gutter:Double=8,margins:PublicationMargins = .init(),facingPages:Bool=true,linkedBody:Bool=true)->UUID? {
    guard let project else{return nil};projectID=project.id
    let origin=Point2(canonicalCanvasRightEdge()+60,40)
    var identifier:UUID?
    if edit("Created publication",{project in
      guard (1...200).contains(pageCount) else{throw FormError.invalid("Choose one to two hundred pages.")}
      identifier=try PublicationCommands.createPublication(in:&project,name:name,pages:[],margins:margins)
      var frames:[StoryFrameID]=[]
      for number in 0..<pageCount {
        let added=try PublicationCommands.addPage(in:&project,publicationID:identifier!,width:width,height:height,columns:columns,gutter:gutter)
        frames+=added.1
        if let index=project.objects.firstIndex(where:{$0.id==added.0}) {project.objects[index].artwork?.canvasPosition = .init(origin.x+Double(number)*(width+36),origin.y)}
      }
      if let index=project.publications?.firstIndex(where:{$0.id==identifier}) {
        var document=project.publications![index];document.layout = .init(facingPages:facingPages)
        try PublicationCommands.setPublication(in:&project,document:document)
      }
      if linkedBody {_=try PublicationCommands.createStory(in:&project,frames:frames,name:"Body text",publicationID:identifier)}
    }),let identifier {open(identifier);return identifier}
    return nil
  }
  @discardableResult func update(_ body:(inout PublicationDocument)->Void)->Bool {
    guard var document else{return false};body(&document)
    return edit("Updated publication"){try PublicationCommands.setPublication(in:&$0,document:document)}
  }
  @discardableResult func update(documentID:UUID,expectedProjectID:UUID,_ body:(inout PublicationDocument)->Void)->Bool {
    guard project?.id==expectedProjectID,var value=project?.publications?.first(where:{$0.id==documentID}) else{return false}
    if projectID==nil {projectID=expectedProjectID}
    body(&value)
    let success=edit("Updated publication"){try PublicationCommands.setPublication(in:&$0,document:value)}
    if success {frameRevision &+= 1;session?.objectWillChange.send();session?.canvas?.synchronize()}
    return success
  }
  @discardableResult func focusMaster(_ sourceID:UUID,publicationID:UUID)->Bool {
    guard let session,let project,let document=project.publications?.first(where:{$0.id==publicationID}),
      document.masters?.contains(where:{$0.sourceObjectID==sourceID})==true else{return false}
    projectID=project.id;self.publicationID=publicationID;frameRevision &+= 1
    session.store?.showSurface(.artwork)
    session.activate(sourceID);session.objectWillChange.send();session.canvas?.synchronize()
    _=session.canvas?.fit(frameIDs:[sourceID]);return true
  }
  @discardableResult func createMaster(documentID:UUID,expectedProjectID:UUID)->UUID? {
    guard project?.id==expectedProjectID,let document=project?.publications?.first(where:{$0.id==documentID}),
      let first=document.pages.first.flatMap({entry in project?.objects.first{$0.id==entry.objectID}}) else{return nil}
    if projectID==nil {projectID=expectedProjectID}
    var identifier:UUID?
    if edit("Added publication master",{project in
      var source=try project.makeObject(recipeID:"artboard",name:document.name+" / Master \((document.masters?.count ?? 0)+1)",parameters:["width":first.artworkSize.x,"depth":first.artworkSize.y])
      var artwork=Artwork(background:"#FFFFFF",elements:[],bleed:0);artwork.backgroundOpacity=0
      let anchor=first.artwork?.canvasPosition ?? .init(36,40)
      artwork.canvasPosition = .init(anchor.x-first.artworkSize.x-60,anchor.y)
      source.artwork=artwork;identifier=source.id;project.objects.append(source)
      var changed=document;if changed.masters==nil {changed.masters=[]}
      changed.masters!.append(.init(name:source.name,sourceObjectID:source.id))
      try PublicationCommands.setPublication(in:&project,document:changed)
    }),let identifier {_=focusMaster(identifier,publicationID:documentID);return identifier}
    return nil
  }
  @discardableResult func addPage(linkStory:Bool=true)->UUID? {
    guard let document else{return nil}
    let source=(currentPageID ?? document.pages.last?.objectID).flatMap{id in project?.objects.first{$0.id==id}}
    let position=currentPageID.flatMap{id in document.pages.firstIndex{$0.objectID==id}}.map{$0+1} ?? document.pages.count
    let story=linkStory ? activeStory?.id:nil
    var identifier:UUID?
    if edit("Added publication page",{project in
      identifier=try PublicationCommands.addPage(in:&project,publicationID:document.id,width:source?.artworkSize.x ?? 148,height:source?.artworkSize.y ?? 210,storyID:story,columns:1,at:position).0
    }),let identifier {focusPage(identifier);return identifier}
    return nil
  }
  @discardableResult func duplicatePage(_ id:UUID?=nil)->UUID? {
    guard let document,let id=id ?? currentPageID,let index=document.pages.firstIndex(where:{$0.objectID==id}) else{return nil}
    var identifier:UUID?
    if edit("Duplicated publication page",{project in identifier=try PublicationCommands.duplicatePublicationPage(in:&project,publicationID:document.id,objectID:id,at:index+1)}),let identifier {focusPage(identifier);return identifier}
    return nil
  }
  @discardableResult func movePage(_ id:UUID,by delta:Int)->Bool {
    guard var document,let index=document.pages.firstIndex(where:{$0.objectID==id}),document.pages.indices.contains(index+delta) else{return false}
    document.pages.swapAt(index,index+delta)
    let changed=edit("Reordered publication pages"){try PublicationCommands.setPublication(in:&$0,document:document)}
    if changed {frameRevision &+= 1;focusPage(id)};return changed
  }
  @discardableResult func removePage(_ id:UUID,deleteObject:Bool=false)->Bool {
    guard let document,let index=document.pages.firstIndex(where:{$0.objectID==id}) else{return false}
    let next=document.pages.filter{$0.objectID != id}
    if edit(deleteObject ? "Deleted publication page":"Removed publication page",{project in try PublicationCommands.removePages(in:&project,publicationID:document.id,pageIDs:[id],deleteObjects:deleteObject)}) {
      if !next.isEmpty {focusPage(next[min(index,next.count-1)].objectID)}
      return true
    };return false
  }
  @discardableResult func newChapter(name:String,openEditor:Bool=true)->UUID? {
    guard let document else{return nil}
    let size=(currentPageID ?? document.pages.last?.objectID).flatMap{id in project?.objects.first{$0.id==id}}?.artworkSize ?? .init(148,210)
    let position=currentPageID.flatMap{id in document.pages.firstIndex{$0.objectID==id}}.map{$0+1} ?? document.pages.count
    var storyID:UUID?,pageID:UUID?
    if edit("Added publication chapter",{project in
      let added=try PublicationCommands.addPage(in:&project,publicationID:document.id,width:size.x,height:size.y,columns:1,at:position);pageID=added.0
      storyID=try PublicationCommands.createStory(in:&project,frames:added.1,name:name,publicationID:document.id)
      if let index=project.publications?.firstIndex(where:{$0.id==document.id}),let page=project.publications![index].pages.firstIndex(where:{$0.objectID==added.0}) {project.publications![index].pages[page].chapterTitle=name}
    }),let storyID,let pageID {focusPage(pageID);if openEditor {openStory(storyID)};return storyID}
    return nil
  }
  func openStory(_ id:UUID) {
    guard stories.contains(where:{$0.id==id}) else{return}
    if let page=stories.first(where:{$0.id==id})?.frames.first?.objectID {focusPage(page)}
    session?.canvas?.openStorySource(id)
  }
  func overset(_ id:UUID)->Int {
    guard let context=project?.resolvedTextStory(id) else{return 0}
    return PublicationStoryLayout.composition(context).oversetRange.length
  }
  func reflow() {
    session?.canvas?.finishText();session?.canvas?.synchronize();session?.objectWillChange.send();objectWillChange.send()
  }
  func preflight()->[String:Any] {
    guard let project,let document,let session else{return [:]}
    session.canvas?.finishText()
    return PublicationOutput.preflight(session.store?.project ?? project,documentID:document.id,assets:session.assets)
  }
}

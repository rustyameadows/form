import Foundation

public enum PublicationCommands {
  private static func pageOrdered(_ frames:[StoryFrameID],document:PublicationDocument)->[StoryFrameID] {
    let indices=Dictionary(uniqueKeysWithValues:document.pages.enumerated().map{($0.element.objectID,$0.offset)})
    return frames.enumerated().sorted {a,b in
      let left=indices[a.element.objectID] ?? Int.max,right=indices[b.element.objectID] ?? Int.max
      return left==right ? a.offset<b.offset:left<right
    }.map(\.element)
  }
  private static func adoptStories(in project:inout Project,document:PublicationDocument) {
    let pages=Set(document.pages.map(\.objectID))
    for i in project.textStories?.indices ?? 0..<0 {
      let story=project.textStories![i]
      if story.publicationID==document.id || (story.publicationID==nil && !story.frames.isEmpty && story.frames.allSatisfy({pages.contains($0.objectID)})) {
        project.textStories![i].publicationID=document.id
        project.textStories![i].frames=pageOrdered(story.frames,document:document)
      }
    }
  }
  private static func frame(_ id:StoryFrameID,in project:Project,allowLinked:Bool=false) throws -> (ProductObject,Artwork,ArtworkElement) {
    guard let value=project.storyFrame(id),value.element.kind=="text",value.object.artworkSourceID==nil,!value.object.isCanvasWorkspace,
      value.object.recipeID=="artboard",project.objects.filter({$0.designID==value.object.designID}).count==1,
      !value.object.locked,!value.artwork.isLocked(value.element),allowLinked || value.element.storyFrame==nil else {
      throw FormError.invalid("Choose unlocked independent physical text frames; an existing story frame must be unlinked first.")
    }
    return(value.object,value.artwork,value.element)
  }
  private static func replace(_ element:ArtworkElement,frame:StoryFrameID,in project:inout Project) throws {
    guard let i=project.objects.firstIndex(where:{$0.id==frame.objectID}),let j=project.objects[i].artwork?.elements.firstIndex(where:{$0.id==frame.elementID}) else{
      throw FormError.missing("The linked text frame no longer exists.")
    }
    project.objects[i].artwork!.elements[j]=element
  }
  public static func sourceSpans(_ source:ArtworkElement)->[TextSpan] {
    let count=source.text.utf16.count;guard count>0 else{return []}
    let runs=source.textRuns ?? [],edges=Set([0,count]+runs.flatMap{[$0.location,$0.location+$0.length]}).filter{$0>=0 && $0<=count}.sorted()
    return zip(edges,edges.dropFirst()).map{start,end in
      var run=runs.first{$0.location<=start && $0.location+$0.length>=end} ?? TextStyleCommands.span(source)
      run.location=start;run.length=end-start;return run
    }
  }
  private static func append(_ source:ArtworkElement,language:String?,to story:inout TextStory) {
    guard !source.text.isEmpty else{return}
    if story.text.isEmpty {
      story.setSource(source);story.language=language ?? story.language;return
    }
    let old=story.sourceElement,separator=story.text.hasSuffix("\n") || source.text.hasPrefix("\n") ? "":"\n"
    let offset=story.text.utf16.count+separator.utf16.count
    var runs=sourceSpans(old)
    if !separator.isEmpty {var run=TextStyleCommands.span(old);run.location=story.text.utf16.count;run.length=separator.utf16.count;runs.append(run)}
    let effectiveLanguage=language ?? (try? ParagraphLanguage.canonical(Locale.preferredLanguages.first ?? "en"))
    for var run in sourceSpans(source) {
      run.location += offset
      run.typography.pairKerning=Dictionary(uniqueKeysWithValues:run.typography.pairKerning.map{($0.key+offset,$0.value)})
      if run.typography.language==nil,language != story.language {run.typography.language=effectiveLanguage}
      runs.append(run)
    }
    var glyphs=story.glyphOverrides ?? [],glyphIDs=Set(glyphs.map(\.id))
    for var choice in source.glyphOverrides ?? [] {
      choice.location += offset
      if !glyphIDs.insert(choice.id).inserted {choice.id=UUID();glyphIDs.insert(choice.id)}
      glyphs.append(choice)
    }
    var items=story.listItems ?? [],itemIDs=Set(items.map(\.id))
    for var item in source.listItems ?? [] {
      item.location += offset;item.resolvedNumber=nil
      if !itemIDs.insert(item.id).inserted {item.id=UUID();itemIDs.insert(item.id)}
      items.append(item)
    }
    story.text += separator+source.text;story.textRuns=runs
    story.glyphOverrides=glyphs.isEmpty ? nil:glyphs;story.listItems=items.isEmpty ? nil:items
  }
  private static func reference(_ e:ArtworkElement,to story:UUID)->ArtworkElement {
    var result=e
    result.text="";result.textRuns=nil;result.glyphOverrides=nil;result.listItems=nil;result.textStyle=nil;result.paragraphStyle=nil;result.fillSwatchID=nil
    var type=Typography();type.frameMode="area";type.verticalAlignment=e.typography?.verticalAlignment ?? "top"
    result.typography=type;result.storyFrame = .init(storyID:story)
    return result
  }
  @discardableResult public static func createStory(in project:inout Project,frames:[StoryFrameID],name:String="Text story",publicationID:UUID?=nil) throws -> UUID {
      guard !frames.isEmpty,Set(frames).count==frames.count else{throw FormError.invalid("Choose an ordered list of distinct source text frames.")}
      var candidate=project
      let first=try frame(frames[0],in:candidate)
      var story=TextStory(name:name,source:first.2,frames:[],language:first.1.language,publicationID:publicationID)
      for (index,id) in frames.enumerated() {
        let value=try frame(id,in:candidate)
        if index>0 {append(value.2,language:value.1.language,to:&story)}
        story.frames.append(id);try replace(reference(value.2,to:story.id),frame:id,in:&candidate)
      }
      if candidate.textStories==nil {candidate.textStories=[]};candidate.textStories!.append(story)
      try candidate.validatePublications();project=candidate;return story.id
  }
  public static func appendFrames(in project:inout Project,storyID:UUID,frames:[StoryFrameID]) throws {
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}),!frames.isEmpty,Set(frames).count==frames.count else{throw FormError.invalid("Choose an existing story and distinct new text frames.")}
    var story=candidate.textStories![index]
    try ensureEditable(story,in:candidate)
    for id in frames {
      let value=try frame(id,in:candidate);append(value.2,language:value.1.language,to:&story)
      story.frames.append(id);try replace(reference(value.2,to:story.id),frame:id,in:&candidate)
    }
    if let document=story.publicationID.flatMap({id in candidate.publications?.first{$0.id==id}}) {story.frames=pageOrdered(story.frames,document:document)}
    candidate.textStories![index]=story;try candidate.validatePublications();project=candidate
  }
  public static func ensureEditable(_ story:TextStory,in project:Project) throws {
    for id in story.frames {_ = try frame(id,in:project,allowLinked:true)}
  }
  public static func setSource(in project:inout Project,storyID:UUID,source:ArtworkElement,language:String?=nil,replaceLanguage:Bool=false) throws {
    guard source.kind=="text",source.storyFrame==nil else{throw FormError.invalid("A story source must be ordinary editable text, without a frame reference.")}
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}) else{throw FormError.missing("Text story not found.")}
    try ensureEditable(candidate.textStories![index],in:candidate)
    var source=source;source.id=storyID
    let old=Artwork(elements:[candidate.textStories![index].sourceElement])
    let recorded=Artwork(elements:[source]).recordingTextStyleOverrides(from:old).elements[0]
    candidate.textStories![index].setSource(recorded)
    if replaceLanguage {candidate.textStories![index].language=try language.map{try ParagraphLanguage.canonical($0)}}
    try candidate.validatePublications();project=candidate
  }
  public static func reorderFrames(in project:inout Project,storyID:UUID,frames:[StoryFrameID]) throws {
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}),Set(frames)==Set(candidate.textStories![index].frames),frames.count==Set(frames).count else{
      throw FormError.invalid("Reordering must include each existing story frame exactly once.")
    }
    try ensureEditable(candidate.textStories![index],in:candidate);candidate.textStories![index].frames=frames
    try candidate.validatePublications();project=candidate
  }
  /// Removing capacity never deletes source words. An orphan story stays recoverable.
  public static func unlinkFrames(in project:inout Project,frames:[StoryFrameID]) throws {
    var candidate=project
    for id in frames {
      let value=try frame(id,in:candidate,allowLinked:true)
      guard let storyID=value.2.storyFrame?.storyID,let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}) else{throw FormError.missing("The frame is not linked to a story.")}
      var element=value.2;element.storyFrame=nil
      candidate.textStories![index].frames.removeAll{$0==id};try replace(element,frame:id,in:&candidate)
    }
    try candidate.validatePublications();project=candidate
  }
  @discardableResult public static func createPublication(in project:inout Project,name:String,pages:[UUID],margins:PublicationMargins = .init(),language:String?=nil) throws -> UUID {
    var candidate=project
    let document=PublicationDocument(name:name,pages:pages.map{PublicationPage(objectID:$0)},margins:margins,language:try language.map{try ParagraphLanguage.canonical($0)})
    if candidate.publications==nil {candidate.publications=[]};candidate.publications!.append(document)
    adoptStories(in:&candidate,document:document)
    try candidate.validatePublications();project=candidate;return document.id
  }
  public static func setPublication(in project:inout Project,document:PublicationDocument) throws {
    var candidate=project
    guard let index=candidate.publications?.firstIndex(where:{$0.id==document.id}) else{throw FormError.missing("Publication not found.")}
    candidate.publications![index]=document;adoptStories(in:&candidate,document:document);try candidate.validatePublications();project=candidate
  }
  public static func assignStory(in project:inout Project,storyID:UUID,publicationID:UUID?) throws {
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}) else{throw FormError.missing("Text story not found.")}
    try ensureEditable(candidate.textStories![index],in:candidate);candidate.textStories![index].publicationID=publicationID
    if let document=publicationID.flatMap({id in candidate.publications?.first{$0.id==id}}) {
      candidate.textStories![index].frames=pageOrdered(candidate.textStories![index].frames,document:document)
    }
    try candidate.validatePublications();project=candidate
  }
  public static func reconcileFrames(in project:inout Project,objectID:UUID,artwork:Artwork) throws {
    for i in project.textStories?.indices ?? 0..<0 {
      let story=project.textStories![i]
      var frames=story.frames.filter{frame in frame.objectID != objectID || artwork.elements.contains{$0.id==frame.elementID && $0.storyFrame?.storyID==story.id}}
      for element in artwork.elements where element.storyFrame?.storyID==story.id {
        let frame=StoryFrameID(objectID:objectID,elementID:element.id)
        if !frames.contains(frame) {frames.append(frame)}
      }
      if let document=story.publicationID.flatMap({id in project.publications?.first{$0.id==id}}) {frames=pageOrdered(frames,document:document)}
      if frames != story.frames {try ensureEditable(story,in:project);project.textStories![i].frames=frames}
    }
  }
  public static func retainAvailableFrames(in project:inout Project) {
    for i in project.textStories?.indices ?? 0..<0 {
      let story=project.textStories![i]
      let frames=story.frames.filter{project.storyFrame($0)?.element.storyFrame?.storyID==story.id}
      project.textStories![i].frames=frames
    }
    let ids=Set(project.objects.map(\.id))
    for i in project.publications?.indices ?? 0..<0 {project.publications![i].pages.removeAll{!ids.contains($0.objectID)}}
  }
  public static func duplicatePage(in project:inout Project,from sourceID:UUID,to targetID:UUID) throws {
    for i in project.publications?.indices ?? 0..<0 {
      if let index=project.publications![i].pages.firstIndex(where:{$0.objectID==sourceID}) {
        project.publications![i].pages.insert(.init(objectID:targetID),at:index+1)
      }
    }
    if let artwork=project.objects.first(where:{$0.id==targetID})?.artwork {try reconcileFrames(in:&project,objectID:targetID,artwork:artwork)}
    try project.validatePublications()
  }
  public static func transferFrames(in project:inout Project,from sourceID:UUID,to targetID:UUID,mapping:[UUID:UUID]) throws {
    for i in project.textStories?.indices ?? 0..<0 {
      let story=project.textStories![i]
      guard story.frames.contains(where:{$0.objectID==sourceID && mapping[$0.elementID] != nil}) else{continue}
      try ensureEditable(story,in:project)
      guard let target=project.objects.first(where:{$0.id==targetID}),target.recipeID=="artboard",!target.isCanvasWorkspace,target.artworkSourceID==nil,
        project.objects.filter({$0.designID==target.designID}).count==1 else {throw FormError.invalid("Linked story frames belong to independent physical pages. Unlink the frame before moving it onto the free Canvas.")}
      if let publicationID=story.publicationID,let index=project.publications?.firstIndex(where:{$0.id==publicationID}),!project.publications![index].pages.contains(where:{$0.objectID==targetID}) {
        guard project.publications?.contains(where:{$0.id != publicationID && $0.pages.contains(where:{$0.objectID==targetID})}) != true else{throw FormError.invalid("Move a linked story frame within its publication, or unlink it first.")}
        project.publications![index].pages.append(.init(objectID:targetID))
      }
      var frames=story.frames.map {frame in frame.objectID==sourceID ? mapping[frame.elementID].map{StoryFrameID(objectID:targetID,elementID:$0)} ?? frame:frame}
      if let document=story.publicationID.flatMap({id in project.publications?.first{$0.id==id}}) {frames=pageOrdered(frames,document:document)}
      project.textStories![i].frames=frames
    }
  }
  @discardableResult public static func addPage(in project:inout Project,publicationID:UUID,width:Double=160,height:Double=210,storyID:UUID?=nil,columns:Int=1,gutter:Double=8) throws -> (UUID,[StoryFrameID]) {
    var candidate=project
    guard let index=candidate.publications?.firstIndex(where:{$0.id==publicationID}),width.isFinite,height.isFinite,
      (20...2000).contains(width),(20...2000).contains(height),(1...4).contains(columns),gutter.isFinite,(0...100).contains(gutter) else{
      throw FormError.invalid("Choose a publication, 20–2000mm page size, one to four columns and a finite gutter.")
    }
    let document=candidate.publications![index],margins=document.margins
    let column=(width-margins.left-margins.right-gutter*Double(columns-1))/Double(columns)
    guard column>=5,height-margins.top-margins.bottom>=5 else{throw FormError.invalid("Page margins and columns must leave at least a 5mm text frame.")}
    var page=try candidate.makeObject(recipeID:"artboard",name:"\(document.name) / Page \(document.pages.count+1)",parameters:["width":width,"depth":height])
    var artwork=Artwork(background:"#F5F1E6",bleed:0),frames:[StoryFrameID]=[]
    for i in 0..<columns {
      var e=ArtworkElement(kind:"text",x:margins.left+Double(i)*(column+gutter),y:margins.top,width:column,height:height-margins.top-margins.bottom,text:"",color:"#24353D",fontSize:14)
      e.name="Body column \(i+1)";e.typography=Typography()
      artwork.elements.append(e);frames.append(.init(objectID:page.id,elementID:e.id))
    }
    if let last=document.pages.last.flatMap({entry in candidate.objects.first{$0.id==entry.objectID}}) {
      page.position = .init(last.position.x+last.artworkSize.x+60,0,last.position.z)
      if let position=last.artwork?.canvasPosition {artwork.canvasPosition = .init(position.x+last.artworkSize.x+36,position.y)}
    }
    page.artwork=artwork;candidate.objects.append(page);candidate.publications![index].pages.append(.init(objectID:page.id))
    if let storyID {
      guard let storyIndex=candidate.textStories?.firstIndex(where:{$0.id==storyID}),candidate.textStories![storyIndex].publicationID==nil || candidate.textStories![storyIndex].publicationID==publicationID else{throw FormError.invalid("The story belongs to another publication.")}
      candidate.textStories![storyIndex].publicationID=publicationID
      try appendFrames(in:&candidate,storyID:storyID,frames:frames)
    }
    try candidate.validatePublications();project=candidate;return(page.id,frames)
  }
}

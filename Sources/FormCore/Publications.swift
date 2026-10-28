import Foundation

public struct StoryFrameID:Codable,Equatable,Hashable,Sendable {
  public var objectID:UUID
  public var elementID:UUID
  public init(objectID:UUID,elementID:UUID) {self.objectID=objectID;self.elementID=elementID}
}

/// One source owns all characters and their formatting; frames contain references.
public struct TextStory:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var text:String
  public var typography:Typography?
  public var fontSize:Double
  public var color:String
  public var fillSwatchID:UUID?
  public var textStyle:TextStyleReference?
  public var paragraphStyle:TextStyleReference?
  public var textRuns:[TextSpan]?
  public var glyphOverrides:[GlyphOverride]?
  public var listItems:[ParagraphListItem]?
  public var language:String?
  public var publicationID:UUID?
  public var frames:[StoryFrameID]
  public init(name:String="Text story",source:ArtworkElement,frames:[StoryFrameID]=[],language:String?=nil,publicationID:UUID?=nil) {
    self.name=name;self.text=source.text;self.typography=source.typography;self.fontSize=source.fontSize;self.color=source.color
    self.fillSwatchID=source.fillSwatchID;self.textStyle=source.textStyle;self.paragraphStyle=source.paragraphStyle
    self.textRuns=source.textRuns;self.glyphOverrides=source.glyphOverrides;self.listItems=source.listItems
    self.frames=frames;self.language=language;self.publicationID=publicationID
    normalizeFrameBehavior()
  }
  public var sourceElement:ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:100,text:text,color:color,fontSize:fontSize)
    e.id=id;e.name=name;e.typography=typography;e.fillSwatchID=fillSwatchID;e.textStyle=textStyle;e.paragraphStyle=paragraphStyle
    e.textRuns=textRuns;e.glyphOverrides=glyphOverrides;e.listItems=listItems;return e
  }
  public mutating func setSource(_ e:ArtworkElement) {
    text=e.text;typography=e.typography;fontSize=e.fontSize;color=e.color;fillSwatchID=e.fillSwatchID
    textStyle=e.textStyle;paragraphStyle=e.paragraphStyle;textRuns=e.textRuns;glyphOverrides=e.glyphOverrides;listItems=e.listItems
    normalizeFrameBehavior()
  }
  private mutating func normalizeFrameBehavior() {
    if typography != nil {typography!.frameMode="area";typography!.verticalAlignment="top";typography!.inheritedLanguage=nil}
    for i in textRuns?.indices ?? 0..<0 {textRuns![i].typography.frameMode="area";textRuns![i].typography.verticalAlignment="top";textRuns![i].typography.inheritedLanguage=nil}
  }
}

public struct PublicationMargins:Codable,Equatable,Sendable {
  public var top:Double,right:Double,bottom:Double,left:Double
  public init(top:Double=14,right:Double=14,bottom:Double=14,left:Double=14) {self.top=top;self.right=right;self.bottom=bottom;self.left=left}
  public var valid:Bool {[top,right,bottom,left].allSatisfy{$0.isFinite && (0...1000).contains($0)}}
}
public struct BaselineGrid:Codable,Equatable,Sendable {
  public var spacing:Double
  public var origin:Double
  public init(spacing:Double=18,origin:Double=0) {self.spacing=spacing;self.origin=origin}
  public var valid:Bool {spacing.isFinite && (4...200).contains(spacing) && origin.isFinite && abs(origin)<=10000}
}
public struct PublicationPage:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var objectID:UUID
  public var label:String?
  public var margins:PublicationMargins?
  public init(objectID:UUID,label:String?=nil,margins:PublicationMargins?=nil) {self.objectID=objectID;self.label=label;self.margins=margins}
}
public struct PublicationDocument:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var pages:[PublicationPage]
  public var margins:PublicationMargins
  public var baselineGrid:BaselineGrid?
  public var language:String?
  public init(name:String="Publication",pages:[PublicationPage]=[],margins:PublicationMargins = .init(),baselineGrid:BaselineGrid?=nil,language:String?=nil) {
    self.name=name;self.pages=pages;self.margins=margins;self.baselineGrid=baselineGrid;self.language=language
  }
}

public struct StoryFrameGeometry:Codable,Equatable,Sendable {
  public var frame:StoryFrameID
  public var width:Double,height:Double
  /// Physical page Y in points; independent of its position on the Canvas table.
  public var pageY:Double
  public init(frame:StoryFrameID,width:Double,height:Double,pageY:Double) {self.frame=frame;self.width=width;self.height=height;self.pageY=pageY}
}
public struct ResolvedTextStory:Codable,Equatable,Sendable {
  public var story:TextStory
  public var frames:[StoryFrameGeometry]
  public var baselineGrid:BaselineGrid?
  public var language:String?
  public init(story:TextStory,frames:[StoryFrameGeometry],baselineGrid:BaselineGrid?,language:String?) {self.story=story;self.frames=frames;self.baselineGrid=baselineGrid;self.language=language}
}
public struct StoryFrameReference:Codable,Equatable,Sendable {
  public var storyID:UUID
  /// Runtime composition context is excluded from all saved object files.
  public var resolved:ResolvedTextStory?=nil
  public var frame:StoryFrameID?=nil
  private enum CodingKeys:String,CodingKey {case storyID}
  public init(storyID:UUID) {self.storyID=storyID}
}

extension Artwork {
  public var requiresSchemaTwentySix:Bool {
    elements.contains {element in
      element.storyFrame != nil || element.typography?.alignToBaselineGrid != nil
        || element.textRuns?.contains(where:{$0.typography.alignToBaselineGrid != nil})==true
    }
  }
  public func renderCacheData() throws -> Data {
    struct Signature:Encodable {var artwork:Artwork;var stories:[ResolvedTextStory]}
    var seen=Set<UUID>(),stories:[ResolvedTextStory]=[]
    for element in elements {
      if let story=element.storyFrame?.resolved,seen.insert(story.story.id).inserted {stories.append(story)}
    }
    return try JSONEncoder.form.encode(Signature(artwork:renderDefinition,stories:stories))
  }
}

extension Project {
  public func storyFrame(_ id:StoryFrameID)->(object:ProductObject,artwork:Artwork,element:ArtworkElement)? {
    guard let object=objects.first(where:{$0.id==id.objectID}),let art=object.artwork,
      let element=art.elements.first(where:{$0.id==id.elementID}) else{return nil}
    return (object,art,element)
  }
  public func resolvedTextStory(_ id:UUID)->ResolvedTextStory? {
    guard var story=textStories?.first(where:{$0.id==id}) else{return nil}
    let source=resolvingSwatches(in:Artwork(elements:[story.sourceElement]),keepingReferences:true).elements[0]
    story.setSource(source)
    let document=story.publicationID.flatMap{id in publications?.first{$0.id==id}}
    let geometry=story.frames.compactMap{frame -> StoryFrameGeometry? in
      guard let value=storyFrame(frame) else{return nil}
      return .init(frame:frame,width:value.element.width,height:value.element.height,pageY:document?.baselineGrid != nil ? value.artwork.worldTransform(value.element).ty*72/25.4:0)
    }
    return .init(story:story,frames:geometry,baselineGrid:document?.baselineGrid,language:story.language ?? document?.language)
  }
  public func resolvingTextStories(in artwork:Artwork,objectID:UUID)->Artwork {
    var result=artwork
    for i in result.elements.indices {
      guard var reference=result.elements[i].storyFrame,let resolved=resolvedTextStory(reference.storyID) else{continue}
      reference.resolved=resolved
      reference.frame = .init(objectID:objectID,elementID:result.elements[i].id)
      result.elements[i].storyFrame=reference
    }
    return result
  }
  public func validatePublications() throws {
    let stories=textStories ?? [],documents=publications ?? []
    guard stories.count<=200,documents.count<=30,Set(stories.map(\.id)).count==stories.count,Set(documents.map(\.id)).count==documents.count else{
      throw FormError.invalid("A project supports up to 200 uniquely identified text stories and 30 publications.")
    }
    var pageOwners=Set<UUID>(),members=Set<StoryFrameID>()
    for document in documents {
      guard !document.name.isEmpty,document.name.count<=500,document.pages.count<=200,document.margins.valid,document.baselineGrid?.valid != false,
        Set(document.pages.map(\.id)).count==document.pages.count,Set(document.pages.map(\.objectID)).count==document.pages.count else{
        throw FormError.invalid("Use a publication name, unique physical pages, finite margins, and a 4–200pt baseline grid.")
      }
      try ParagraphLanguage.validate(document.language)
      for page in document.pages {
        guard let object=objects.first(where:{$0.id==page.objectID}),object.recipeID=="artboard",!object.isCanvasWorkspace,
          object.artworkSourceID==nil,object.artwork != nil,page.margins?.valid != false,pageOwners.insert(object.id).inserted,
          (page.label?.count ?? 0)<=500 else{throw FormError.invalid("Each publication page must own one independent physical artwork sheet; a sheet belongs to one publication.")}
      }
    }
    for story in stories {
      guard !story.name.isEmpty,story.name.count<=500,story.text.count<=100000,story.frames.count<=400,Set(story.frames).count==story.frames.count else{
        throw FormError.invalid("Use a story name, up to 100,000 characters and 400 distinct linked frames.")
      }
      try ParagraphLanguage.validate(story.language)
      try validateArtwork(Artwork(elements:[story.sourceElement]),maxTextCharacters:100000)
      let document=story.publicationID.flatMap{id in documents.first{$0.id==id}}
      guard story.publicationID==nil || document != nil else{throw FormError.invalid("The story's publication does not exist.")}
      if let document {
        let pages=Dictionary(uniqueKeysWithValues:document.pages.enumerated().map{($0.element.objectID,$0.offset)})
        let order=story.frames.map{pages[$0.objectID] ?? Int.max}
        guard order==order.sorted() else{throw FormError.invalid("Story frame order must follow the publication's page sequence. Reorder its pages or its frames.")}
      }
      for frame in story.frames {
        guard let value=storyFrame(frame),value.element.kind=="text",value.element.storyFrame?.storyID==story.id,
          value.object.artworkSourceID==nil,!value.object.isCanvasWorkspace,value.object.recipeID=="artboard",objects.filter({$0.designID==value.object.designID}).count==1,members.insert(frame).inserted,
          value.element.text.isEmpty,value.element.textRuns==nil,value.element.glyphOverrides==nil,value.element.listItems==nil,
          document==nil || document!.pages.contains(where:{$0.objectID==frame.objectID}) else{
          throw FormError.invalid("A story frame must be a distinct empty text reference on its physical publication page.")
        }
        if document?.baselineGrid != nil,story.typography?.alignToBaselineGrid==true || story.textRuns?.contains(where:{$0.typography.alignToBaselineGrid==true})==true {
          let t=value.artwork.worldTransform(value.element)
          guard abs(t.a-1)<1e-8,abs(t.d-1)<1e-8,abs(t.b)<1e-8,abs(t.c)<1e-8 else{
            throw FormError.invalid("Baseline-grid story frames must be unrotated and unscaled: \(value.element.title).")
          }
          guard (value.element.typography?.verticalAlignment ?? "top")=="top" else{throw FormError.invalid("Baseline-grid frames use top alignment: \(value.element.title).")}
        }
      }
    }
    for object in objects {for element in object.artwork?.elements ?? [] {
      if let reference=element.storyFrame {
        guard members.contains(.init(objectID:object.id,elementID:element.id)),stories.contains(where:{$0.id==reference.storyID}) else{
          throw FormError.invalid("A text frame refers to a missing story or is absent from its frame order.")
        }
      }
    }}
  }
}

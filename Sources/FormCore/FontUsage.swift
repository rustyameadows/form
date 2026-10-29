import Foundation

public struct FontUse:Equatable,Sendable {
  public var fontName:String,kind:String,owner:String
  public var objectID:UUID?,elementID:UUID?,storyID:UUID?,styleID:UUID?
  public var location:Int?,length:Int?
  public var json:[String:Any] {
    var value:[String:Any]=["font_name":fontName,"kind":kind,"owner":owner]
    if let objectID {value["object_id"]=objectID.uuidString};if let elementID {value["element_id"]=elementID.uuidString}
    if let storyID {value["story_id"]=storyID.uuidString};if let styleID {value["style_id"]=styleID.uuidString}
    if let location {value["location"]=location};if let length {value["length"]=length}
    return value
  }
}

public enum FontUsage {
  public static func uses(in element:ArtworkElement,owner:String="",objectID:UUID?=nil,storyID:UUID?=nil)->[FontUse] {
    guard element.kind=="text",element.storyFrame==nil else{return []}
    func use(_ name:String,_ kind:String,_ location:Int?=nil,_ length:Int?=nil)->FontUse {
      .init(fontName:name,kind:kind,owner:owner,objectID:objectID,elementID:storyID==nil ? element.id:nil,storyID:storyID,location:location,length:length)
    }
    var result=[use(element.typography?.fontName ?? Typography().fontName,element.hidden==true ? "recoverable_text":"text")]
    result += (element.textRuns ?? []).map{use($0.typography.fontName,"rich_span",$0.location,$0.length)}
    result += (element.listItems ?? []).compactMap{item in item.fontName.map{use($0,"list_marker",item.location,0)}}
    result += (element.glyphOverrides ?? []).map{use($0.glyph.fontName,"exact_glyph",$0.location,$0.length)}
    return result
  }
  public static func uses(in project:Project)->[FontUse] {
    var result:[FontUse]=[]
    for object in project.objects {for art in object.storedArtworks {for element in art.elements {result += uses(in:element,owner:object.name+" / "+element.title,objectID:object.id)}}}
    for story in project.textStories ?? [] {result += uses(in:story.sourceElement,owner:story.name,storyID:story.id)}
    for style in project.textStyles ?? [] {result.append(.init(fontName:style.typography.fontName,kind:"text_style",owner:style.name,styleID:style.id))}
    return result
  }
  /// Replaces matching face assignments while retaining words, ranges, styles,
  /// features, axes and exact glyph metadata. Glyph choices are never retargeted.
  public static func replacing(in project:Project,from:String,to:String) throws -> Project {
    guard !from.isEmpty,!to.isEmpty,from.count<=300,to.count<=300 else{throw FormError.invalid("Provide exact source and replacement face names.")}
    guard from != to else{return project}
    var candidate=project
    func changed(_ e:ArtworkElement)->ArtworkElement {
      guard e.kind=="text",e.storyFrame==nil else{return e}
      var result=e
      if (e.typography?.fontName ?? Typography().fontName)==from {var t=e.typography ?? .init();t.fontName=to;result.typography=t}
      for i in result.textRuns?.indices ?? 0..<0 where result.textRuns![i].typography.fontName==from {result.textRuns![i].typography.fontName=to}
      for i in result.listItems?.indices ?? 0..<0 where result.listItems![i].fontName==from {result.listItems![i].fontName=to}
      return result
    }
    for i in candidate.objects.indices {
      let object=candidate.objects[i]
      try candidate.objects[i].updateStoredArtworks{art in
        for j in art.elements.indices {
          let value=changed(art.elements[j])
          if value != art.elements[j] {
            guard !object.locked,!art.isLocked(art.elements[j]) else{throw FormError.invalid("Unlock affected text before replacing its font: \(object.name) / \(art.elements[j].title).")}
            art.elements[j]=value
          }
        }
      }
    }
    for i in candidate.textStories?.indices ?? 0..<0 {
      let story=candidate.textStories![i],source=changed(story.sourceElement)
      if source != story.sourceElement {try PublicationCommands.ensureEditable(story,in:project);candidate.textStories![i].setSource(source)}
    }
    for i in candidate.textStyles?.indices ?? 0..<0 where candidate.textStyles![i].typography.fontName==from {candidate.textStyles![i].typography.fontName=to}
    try candidate.validateArtworkLinks();return candidate
  }
}

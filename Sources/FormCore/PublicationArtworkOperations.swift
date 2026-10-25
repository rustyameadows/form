import Foundation

extension PublicationCommands {
  public static func editText(in project:inout Project,objectID:UUID,ids:Set<UUID>,command:String,arguments:[String:Any],
    prepareGlyph:((inout ArtworkElement,GlyphOverride?)throws->Void)?=nil,
    prepareParagraphs:((inout Artwork,Set<UUID>)throws->Void)?=nil) throws -> Bool {
    guard ["paragraph","glyph","list","font"].contains(command),let object=project.objects.first(where:{$0.id==objectID}),var artwork=project.editableArtwork(object) else{return false}
    let targets=artwork.swatchPaintTargets(for:ids)
    let linked=artwork.elements.filter{targets.contains($0.id) && $0.storyFrame != nil}
    guard !linked.isEmpty else{return false}
    var seen=Set<UUID>()
    for element in linked {
      let id=element.storyFrame!.storyID
      guard seen.insert(id).inserted,let story=project.textStories?.first(where:{$0.id==id}) else{continue}
      try ensureEditable(story,in:project)
      var source=story.sourceElement,art=Artwork(elements:[story.sourceElement])
      try ArtworkCommands.apply(command,to:&art,ids:[source.id],arguments:arguments,maxTextCharacters:100000)
      source=art.elements[0]
      if command=="glyph" {
        let location=(arguments["location"] as? NSNumber)?.intValue
        let choice=arguments["glyph"] is [String:Any] ? source.glyphOverrides?.first{$0.location==location}:nil
        var prepared=source.inheritingLanguage(project.resolvedTextStory(id)?.language)
        try prepareGlyph?(&prepared,choice)
      }
      try setSource(in:&project,storyID:id,source:source)
    }
    let ordinary=Set(artwork.elements.filter{targets.contains($0.id) && $0.kind=="text" && $0.storyFrame==nil}.map(\.id))
    if !ordinary.isEmpty {
      try ArtworkCommands.apply(command,to:&artwork,ids:ordinary,arguments:arguments)
      if command=="glyph" {
        let location=(arguments["location"] as? NSNumber)?.intValue
        for i in artwork.elements.indices where ordinary.contains(artwork.elements[i].id) {
          let choice=arguments["glyph"] is [String:Any] ? artwork.elements[i].glyphOverrides?.first{$0.location==location}:nil
          try prepareGlyph?(&artwork.elements[i],choice)
        }
      }
      try prepareParagraphs?(&artwork,ordinary)
    }
    try project.setArtwork(artwork,for:objectID);return true
  }
}

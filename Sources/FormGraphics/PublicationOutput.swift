import AppKit
import FormCore

@MainActor public enum PublicationOutput {
  public static func outputProfile(_ project:Project,document:PublicationDocument) throws -> ArtworkOutputProfile? {
    let profiles=document.pages.map{page in project.objects.first{$0.id==page.objectID}?.artwork?.outputColorProfile}
    let assigned=profiles.compactMap{$0}
    guard !assigned.isEmpty else{return nil}
    guard assigned.count==profiles.count,Set(assigned.map(\.sha256)).count==1 else{
      throw FormError.invalid("Publication pages have conflicting or missing output profiles. Assign the same ICC profile to every page before exporting.")
    }
    return assigned.first
  }
  public static func storyLayout(_ project:Project,storyID:UUID) throws -> [String:Any] {
    guard let context=project.resolvedTextStory(storyID) else{throw FormError.missing("Text story not found.")}
    let value=PublicationStoryLayout.composition(context)
    let frames=value.containers.indices.map {index -> [String:Any] in
      let geometry=context.frames[index],source=value.sourceRange(index),display=value.displayRange(index)
      return ["object_id":geometry.frame.objectID.uuidString,"element_id":geometry.frame.elementID.uuidString,
        "source_location":source.location,"source_length":source.length,"display_location":display.location,"display_length":display.length,
        "glyph_location":value.glyphRange(index).location,"glyph_length":value.glyphRange(index).length,
        "top_offset_points":value.topOffsets[index],"used_width_points":value.layout.usedRect(for:value.containers[index]).width,
        "used_height_points":value.layout.usedRect(for:value.containers[index]).height]
    }
    return ["story_id":storyID.uuidString,"source_length":context.story.text.utf16.count,"display_length":value.storage.length,
      "frames":frames,"overset_location":value.oversetRange.location,"overset_length":value.oversetRange.length,
      "renderer":PublicationStoryLayout.diagnostics]
  }
  public static func preflight(_ project:Project,documentID:UUID,assets:URL?=nil,previewOnly:Bool=false)->[String:Any] {
    var issues:[[String:Any]]=[]
    func issue(_ severity:String,_ message:String,page:UUID?=nil,element:UUID?=nil,story:UUID?=nil,code:String?=nil) {
      var value:[String:Any]=["severity":severity,"message":message]
      if let code {value["code"]=code}
      if let page {value["page_id"]=page.uuidString};if let element {value["element_id"]=element.uuidString};if let story {value["story_id"]=story.uuidString}
      issues.append(value)
    }
    guard let document=project.publications?.first(where:{$0.id==documentID}) else{return ["publication_id":documentID.uuidString,"can_export":false,"issues":[["severity":"error","message":"Publication not found."]]]}
    do {try project.validatePublications()}catch{issue("error",error.localizedDescription)}
    do {
      if !previewOnly,let profile=try outputProfile(project,document:document),let assets {_ = try ICCOutputProfile(reference:profile,assets:assets)}
    }catch{issue("error",error.localizedDescription)}
    if document.pages.isEmpty {issue("error","Add at least one physical page before exporting.")}
    var stories:[[String:Any]]=[]
    let pageIDs=Set(document.pages.map(\.objectID))
    for story in project.textStories ?? [] where story.publicationID==documentID || story.frames.contains(where:{pageIDs.contains($0.objectID)}) {
      if story.frames.contains(where:{!pageIDs.contains($0.objectID)}) {issue("error","\(story.name) also flows through frames outside this publication. Move its complete flow onto these pages before exporting.",story:story.id)}
      if let layout=try? storyLayout(project,storyID:story.id) {
        stories.append(layout)
        if (layout["overset_length"] as? Int ?? 0)>0 {issue("error","\(story.name) has \(layout["overset_length"]!) source units beyond its linked frames. Add capacity or edit the overset source.",story:story.id,code:"overset")}
        if let context=project.resolvedTextStory(story.id) {
          let value=PublicationStoryLayout.composition(context)
          for index in value.containers.indices where value.layout.usedRect(for:value.containers[index]).width>value.containers[index].size.width+0.01 {
            issue("error","A glyph or unbreakable line in \(story.name) is wider than its frame. Widen the frame or reduce its text size.",page:context.frames[index].frame.objectID,element:context.frames[index].frame.elementID,story:story.id)
          }
        }
      }
      let missing=FontCatalog.missing(in:Artwork(elements:[story.sourceElement]))
      for font in missing {issue("warning","\(story.name) uses missing font \(font); install it or select an available face.",story:story.id)}
      for message in GlyphEngine.issues(story.sourceElement.inheritingLanguage(story.language ?? document.language)) {issue("error",message,story:story.id)}
      let sourceArt=Artwork(elements:[story.sourceElement.inheritingLanguage(story.language ?? document.language)])
      for message in CharacterTypography.warnings(sourceArt)+SmallCapsTypography.warnings(sourceArt) {issue("warning",message,story:story.id,code:"character_forms")}
    }
    var pages:[[String:Any]]=[]
    for (index,page) in document.pages.enumerated() {
      guard let object=project.objects.first(where:{$0.id==page.objectID}),let art=project.surfaceArtwork(object) else{continue}
      pages.append(["index":index+1,"page_id":page.id.uuidString,"object_id":object.id.uuidString,"name":page.label ?? object.name,
        "width_mm":object.artworkSize.x,"height_mm":object.artworkSize.y,"bleed_mm":art.bleed])
      for font in FontCatalog.missing(in:art) {issue("warning","\(object.name) uses missing font \(font).",page:object.id)}
      let independent=Artwork(elements:art.elements.filter{$0.storyFrame==nil})
      for message in CharacterTypography.warnings(independent)+SmallCapsTypography.warnings(independent) {issue("warning",message,page:object.id,code:"character_forms")}
      for element in art.elements where element.kind != "group" && element.hidden != true {
        let bounds=art.bounds(of:element)
        if bounds.x < -art.bleed - 0.001 || bounds.y < -art.bleed - 0.001 || bounds.maxX > object.artworkSize.x+art.bleed+0.001 || bounds.maxY > object.artworkSize.y+art.bleed+0.001 {
          issue("warning","\(element.title) extends beyond \(object.name)'s bleed area.",page:object.id,element:element.id)
        }
      }
      for element in art.elements where element.storyFrame != nil && element.hidden==true {
        issue("warning","\(element.title) is hidden but still reserves story capacity. Its outlined replacement is frozen; unhide the frame to return to live text.",page:object.id,element:element.id,story:element.storyFrame?.storyID)
      }
    }
    return ["publication_id":document.id.uuidString,"name":document.name,"can_export":!issues.contains{$0["severity"] as? String=="error"},"issues":issues,"pages":pages,"stories":stories]
  }
  public static func pdf(_ project:Project,documentID:UUID,assets:URL,dpi:Double=300,outlineText:Bool=false,allowOverset:Bool=false,inkOutput:InkOutputMode?=nil) throws -> Data {
    try project.validatePublications()
    guard let document=project.publications?.first(where:{$0.id==documentID}),!document.pages.isEmpty,dpi.isFinite,(36...1200).contains(dpi) else{
      throw FormError.invalid("Choose a publication with physical pages and 36–1200DPI effects resolution.")
    }
    let physicalPages=try document.pages.map {page->InkPrintPage in
      guard let object=project.objects.first(where:{$0.id==page.objectID}),let art=project.surfaceArtwork(object,keepingSwatchReferences:true) else{throw FormError.missing("A physical publication page is missing.")}
      return .init(id:object.id,name:object.name,artwork:art,width:object.artworkSize.x,height:object.artworkSize.y)
    }
    if inkOutput == .composite || inkOutput == .plates {
      return try ProductionInkPDF.export(project:project,pages:physicalPages,assets:assets,mode:inkOutput!,title:document.name).data
    }
    if physicalPages.contains(where:{$0.artwork.requiresInkOutput}),inkOutput != .preview {throw FormError.invalid("This publication declares production inks. Choose an explicit preview, composite or plates output.")}
    let profile=inkOutput == .preview ? nil:try outputProfile(project,document:document)
    let report=preflight(project,documentID:documentID,assets:assets,previewOnly:inkOutput == .preview)
    let errors=(report["issues"] as? [[String:Any]] ?? []).filter{$0["severity"] as? String=="error" && !(allowOverset && $0["code"] as? String=="overset")}.compactMap{$0["message"] as? String}
    if !errors.isEmpty {throw FormError.invalid(errors.joined(separator:"\n"))}
    let data=NSMutableData();var first=CGRect(x:0,y:0,width:100,height:100)
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&first,[kCGPDFContextTitle:document.name] as CFDictionary) else{throw FormError.invalid("Could not create publication PDF.")}
    func box(_ value:CGRect)->Data {var value=value;return Data(bytes:&value,count:MemoryLayout<CGRect>.size)}
    for page in document.pages {
      guard let object=project.objects.first(where:{$0.id==page.objectID}),var art=project.surfaceArtwork(object) else{throw FormError.missing("A publication page no longer exists.")}
      art=try BooleanGeometry.materialized(art)
      for element in art.elements where element.storyFrame != nil {
        if let story=element.storyFrame?.resolved {try GlyphEngine.validateOutput(story.story.sourceElement.inheritingLanguage(story.language),outlines:outlineText)}
      }
      if outlineText {
        let ids=Set(art.elements.filter{$0.kind=="text" && $0.hidden != true}.map(\.id))
        if !ids.isEmpty {art=try ArtworkOutlines.convert(art,ids:ids,mode:"text",resolvedPaint:art).artwork}
      }
      try ArtworkRenderer.validateAppearanceOutput(art,assets:assets,pixelsPerMM:dpi/25.4)
      let width=object.artworkSize.x,height=object.artworkSize.y,bleed=art.bleed,factor=TypographyEngine.pointsPerMM
      let media=CGRect(x:0,y:0,width:(width+2*bleed)*factor,height:(height+2*bleed)*factor)
      let trim=CGRect(x:bleed*factor,y:bleed*factor,width:width*factor,height:height*factor)
      context.beginPDFPage([kCGPDFContextMediaBox:box(media),kCGPDFContextCropBox:box(media),kCGPDFContextTrimBox:box(trim),kCGPDFContextBleedBox:box(media)] as CFDictionary)
      context.translateBy(x:0,y:media.height);context.scaleBy(x:factor,y:-factor)
      context.setFillColor(FormColor.color(art.background).withAlphaComponent(art.backgroundOpacity ?? 1).cgColor)
      context.fill(CGRect(x:0,y:0,width:width+2*bleed,height:height+2*bleed))
      context.translateBy(x:bleed,y:bleed)
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      ArtworkRenderer.draw(art,width:width,height:height,assets:assets,effectScale:dpi/25.4,unbounded:true)
      NSGraphicsContext.restoreGraphicsState();context.endPDFPage()
    }
    context.closePDF()
    if let profile {return try ProfiledPDF.convert(data as Data,profile:ICCOutputProfile(reference:profile,assets:assets),title:document.name)}
    return data as Data
  }
}

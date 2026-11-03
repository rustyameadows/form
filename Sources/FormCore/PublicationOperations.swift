import Foundation
import CoreFoundation

extension OperationEngine {
  func publicationCall(_ name:String,_ arguments:[String:Any],source:String) throws -> Any {
    guard let current=project else{throw FormError.missing("Open a project first.")}
    let command=arguments["command"] as? String ?? "list"
    if let language=arguments["language"],!(language is String),!(language is NSNull) {throw FormError.invalid("Language must be a BCP47 identifier or null.")}
    func uuid(_ key:String) throws -> UUID {
      guard let value=arguments[key] as? String,let id=UUID(uuidString:value) else{throw FormError.invalid("Provide a valid \(key) UUID.")};return id
    }
    func parseUUIDs(_ raw:[String]) throws -> Set<UUID> {
      let values=raw.compactMap(UUID.init(uuidString:))
      guard values.count==raw.count,Set(values).count==values.count else{throw FormError.invalid("Use distinct valid page UUIDs.")}
      return Set(values)
    }
    func frames() throws -> [StoryFrameID] {
      guard let values=arguments["frames"] as? [[String:Any]],!values.isEmpty else{throw FormError.invalid("Provide an ordered frames array of object_id/element_id pairs.")}
      return try values.map {value in
        guard let object=value["object_id"] as? String,let objectID=UUID(uuidString:object),let element=value["element_id"] as? String,let elementID=UUID(uuidString:element) else{throw FormError.invalid("Each frame needs object_id and element_id UUIDs.")}
        return .init(objectID:objectID,elementID:elementID)
      }
    }
    func integer(_ key:String,default fallback:Int?=nil)throws->Int {
      guard let raw=arguments[key] else{if let fallback{return fallback};throw FormError.invalid("Provide \(key).")}
      guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,abs(n.doubleValue)<=1_000_000 else{throw FormError.invalid("Use a bounded integer for \(key).")}
      return n.intValue
    }
    func scalar(_ key:String,default fallback:Double)throws->Double {
      guard let raw=arguments[key] else{return fallback}
      guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("Use a finite number for \(key).")}
      return n.doubleValue
    }
    func configure(_ document:inout PublicationDocument)throws {
      if let raw=arguments["layout"] {
        guard raw is NSNull || raw is [String:Any] else{throw FormError.invalid("Publication layout must be an object or null.")}
        document.layout=raw is NSNull ? nil:try JSONDecoder.form.decode(PublicationLayout.self,from:JSONSerialization.data(withJSONObject:raw))
      }
      if let raw=arguments["numbering"] {
        guard raw is NSNull || raw is [String:Any] else{throw FormError.invalid("Publication numbering must be an object or null.")}
        document.numbering=raw is NSNull ? nil:try JSONDecoder.form.decode(PublicationNumbering.self,from:JSONSerialization.data(withJSONObject:raw))
      }
      if let raw=arguments["masters"] {
        guard raw is NSNull || raw is [[String:Any]] else{throw FormError.invalid("Publication masters must be an array of source definitions or null.")}
        document.masters=raw is NSNull ? nil:try JSONDecoder.form.decode([PublicationMaster].self,from:JSONSerialization.data(withJSONObject:raw))
      }
    }
    if command=="list" {return try name=="form_story" ? ["stories":jsonObject(current.textStories ?? [])]:["publications":jsonObject(current.publications ?? [])]}
    if name=="form_story",command=="get" {
      guard let story=current.textStories?.first(where:{$0.id == (try? uuid("story_id"))}) else{throw FormError.missing("Text story not found.")}
      return ["story":try jsonObject(story),"source":try jsonObject(story.sourceElement)]
    }
    if name=="form_publication",command=="get" {
      guard let document=current.publications?.first(where:{$0.id == (try? uuid("publication_id"))}) else{throw FormError.missing("Publication not found.")}
      return try jsonObject(document)
    }
    if name=="form_publication",command=="spreads" {
      let id=try uuid("publication_id")
      guard let document=current.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Publication not found.")}
      return ["publication_id":id.uuidString,"spreads":try jsonObject(document.spreads()),"leaves":try jsonObject(document.leafPairs())]
    }
    if command=="layout" || command=="preflight" {
      guard let onGraphics else{throw FormError.missing("Publication layout/preflight requires the running native LAB app.")}
      return try onGraphics(name,arguments)
    }
    var result:[String:Any]=[:]
    try edit("\(name=="form_story" ? "Text story":"Publication"): \(command)",source:source) {p in
      if name=="form_story" {
        switch command {
        case "create":
          let id=try PublicationCommands.createStory(in:&p,frames:frames(),name:arguments["name"] as? String ?? "Text story",publicationID:arguments["publication_id"] == nil ? nil:uuid("publication_id"))
          result=["story_id":id.uuidString]
        case "append":try PublicationCommands.appendFrames(in:&p,storyID:uuid("story_id"),frames:frames())
        case "reorder":try PublicationCommands.reorderFrames(in:&p,storyID:uuid("story_id"),frames:frames())
        case "unlink":try PublicationCommands.unlinkFrames(in:&p,frames:frames())
        case "edit":
          let id=try uuid("story_id")
          guard let index=p.textStories?.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Text story not found.")}
          var element=p.textStories![index].sourceElement
          if let raw=arguments["source"] as? [String:Any] {element=try JSONDecoder.form.decode(ArtworkElement.self,from:JSONSerialization.data(withJSONObject:raw))}
          else if let text=arguments["text"] as? String {element.text=text}
          else if arguments["language"]==nil,arguments["name"]==nil {throw FormError.invalid("Provide complete source text/formatting, text, language, or a story name.")}
          let language=arguments["language"] as? String
          try PublicationCommands.setSource(in:&p,storyID:id,source:element,language:language,replaceLanguage:arguments["language"] != nil)
          if let name=arguments["name"] as? String {p.textStories![index].name=name;try p.validatePublications()}
          result=["story_id":id.uuidString,"source":try jsonObject(p.textStories![index].sourceElement)]
        case "replace_text":
          guard let text=arguments["text"] as? String else{throw FormError.invalid("Provide replacement source text.")}
          let id=try uuid("story_id")
          try PublicationCommands.replaceStoryText(in:&p,storyID:id,range:NSRange(location:integer("location"),length:integer("length")),text:text)
          result=["story_id":id.uuidString,"source":try jsonObject(p.textStories!.first{$0.id==id}!.sourceElement)]
        case "publication":try PublicationCommands.assignStory(in:&p,storyID:uuid("story_id"),publicationID:arguments["publication_id"] is NSNull ? nil:uuid("publication_id"))
        case "delete":
          let id=try uuid("story_id")
          guard let story=p.textStories?.first(where:{$0.id==id}) else{throw FormError.missing("Text story not found.")}
          try PublicationCommands.ensureEditable(story,in:p)
          if !story.frames.isEmpty {try PublicationCommands.unlinkFrames(in:&p,frames:story.frames)}
          p.textStories?.removeAll{$0.id==id};result=["deleted":true]
        default:throw FormError.invalid("Story commands: list/get/create/append/reorder/unlink/edit/replace_text/publication/delete/layout.")
        }
      } else {
        switch command {
        case "create":
          let raw=arguments["page_ids"] as? [String] ?? [],ids=try parseUUIDs(raw)
          guard ids.count==raw.count else{throw FormError.invalid("Choose distinct physical page UUIDs.")}
          let margins=try (arguments["margins"] as? [String:Any]).map{try JSONDecoder.form.decode(PublicationMargins.self,from:JSONSerialization.data(withJSONObject:$0))} ?? .init()
          let id=try PublicationCommands.createPublication(in:&p,name:arguments["name"] as? String ?? "Publication",pages:raw.compactMap(UUID.init(uuidString:)),margins:margins,language:arguments["language"] as? String)
          if var document=p.publications?.first(where:{$0.id==id}) {try configure(&document);try PublicationCommands.setPublication(in:&p,document:document)}
          result=["publication_id":id.uuidString]
        case "settings","reorder":
          let id=try uuid("publication_id")
          guard var document=p.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Publication not found.")}
          if let name=arguments["name"] as? String {document.name=name}
          try configure(&document)
          if let raw=arguments["margins"] as? [String:Any] {document.margins=try JSONDecoder.form.decode(PublicationMargins.self,from:JSONSerialization.data(withJSONObject:raw))}
          if let raw=arguments["baseline_grid"] {
            document.baselineGrid=raw is NSNull ? nil:try JSONDecoder.form.decode(BaselineGrid.self,from:JSONSerialization.data(withJSONObject:raw))
          }
          if arguments["language"] != nil {document.language=try (arguments["language"] as? String).map{try ParagraphLanguage.canonical($0)}}
          if let raw=arguments["page_ids"] as? [String] {
            let ids=try parseUUIDs(raw)
            guard ids.count==raw.count else{throw FormError.invalid("Use distinct physical page UUIDs.")}
            if command=="reorder",ids != Set(document.pages.map(\.objectID)) {throw FormError.invalid("Reordering must include every existing publication page exactly once.")}
            document.pages=raw.compactMap(UUID.init(uuidString:)).map{id in document.pages.first{$0.objectID==id} ?? .init(objectID:id)}
          }
          try PublicationCommands.setPublication(in:&p,document:document);result=["publication":try jsonObject(document)]
        case "add_page":
          let page=try PublicationCommands.addPage(in:&p,publicationID:uuid("publication_id"),width:arguments["width"] as? Double ?? 160,height:arguments["height"] as? Double ?? 210,
            storyID:arguments["story_id"] == nil ? nil:uuid("story_id"),columns:integer("columns",default:1),gutter:scalar("gutter",default:8),at:arguments["index"] == nil ? nil:integer("index"))
          result=["page_id":page.0.uuidString,"frames":try jsonObject(page.1)]
        case "create_pages":
          let id=try uuid("publication_id")
          let ids=try PublicationCommands.addPages(in:&p,publicationID:id,count:integer("count"),width:scalar("width",default:160),height:scalar("height",default:210),
            storyID:arguments["story_id"] == nil ? nil:uuid("story_id"),columns:integer("columns",default:1),gutter:scalar("gutter",default:8),at:arguments["index"] == nil ? nil:integer("index"))
          result=["publication_id":id.uuidString,"page_ids":ids.map(\.uuidString)]
        case "insert":
          guard let raw=arguments["page_ids"] as? [String] else{throw FormError.invalid("Provide ordered page_ids.")}
          _ = try parseUUIDs(raw)
          try PublicationCommands.insertPages(in:&p,publicationID:uuid("publication_id"),pageIDs:raw.compactMap(UUID.init(uuidString:)),at:integer("index"))
        case "remove":
          guard let raw=arguments["page_ids"] as? [String] else{throw FormError.invalid("Provide page_ids to remove.")}
          if let raw=arguments["delete_objects"],!(raw is Bool) {throw FormError.invalid("delete_objects must be a boolean.")}
          try PublicationCommands.removePages(in:&p,publicationID:uuid("publication_id"),pageIDs:parseUUIDs(raw),deleteObjects:arguments["delete_objects"] as? Bool ?? false)
        case "duplicate":
          let id=try PublicationCommands.duplicatePublicationPage(in:&p,publicationID:uuid("publication_id"),objectID:uuid("page_id"),at:arguments["index"] == nil ? nil:integer("index"))
          result=["page_id":id.uuidString]
        case "page_settings":
          let id=try uuid("publication_id"),pageID=try uuid("page_id")
          guard var document=p.publications?.first(where:{$0.id==id}),let index=document.pages.firstIndex(where:{$0.objectID==pageID}) else{throw FormError.missing("Publication page not found.")}
          if let raw=arguments["label"] {guard raw is String || raw is NSNull else{throw FormError.invalid("Use a page label or null.")};document.pages[index].label=raw as? String}
          if let raw=arguments["margins"] {document.pages[index].margins=raw is NSNull ? nil:try JSONDecoder.form.decode(PublicationMargins.self,from:JSONSerialization.data(withJSONObject:raw))}
          if let raw=arguments["spread_id"] {document.pages[index].spreadID=raw is NSNull ? nil:try uuid("spread_id")}
          if let raw=arguments["number_override"] {document.pages[index].numberOverride=raw is NSNull ? nil:try integer("number_override")}
          if let raw=arguments["chapter_title"] {guard raw is String || raw is NSNull else{throw FormError.invalid("Use a chapter title or null.")};document.pages[index].chapterTitle=raw as? String}
          if let raw=arguments["master_ids"] {
            if raw is NSNull {document.pages[index].masterIDs=nil}
            else {guard let values=raw as? [String] else{throw FormError.invalid("Use master UUIDs or null.")};_ = try parseUUIDs(values);document.pages[index].masterIDs=values.compactMap(UUID.init(uuidString:))}
          }
          try PublicationCommands.setPublication(in:&p,document:document);result=["page":try jsonObject(document.pages[index])]
        case "sheet_assembly_create":
          guard let raw=arguments["definition"] as? [String:Any] else{throw FormError.invalid("Provide the complete sheet assembly definition.")}
          let definition=try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:JSONSerialization.data(withJSONObject:raw))
          if arguments["publication_id"] != nil,try uuid("publication_id") != definition.publicationID {throw FormError.invalid("The assembly definition must reference this publication.")}
          let position:Vector3
          if let value=arguments["position"] {
            if let values=value as? [Double],values.count==3,values.allSatisfy(\.isFinite) {position = .init(values[0],values[1],values[2])}
            else if let values=value as? [String:Any] {position=try JSONDecoder.form.decode(Vector3.self,from:JSONSerialization.data(withJSONObject:values))}
            else{throw FormError.invalid("Position needs three finite millimeter coordinates.")}
          }else{position = .init()}
          let id=try SheetAssemblyCommands.create(in:&p,definition:definition,name:arguments["name"] as? String ?? "Sheet assembly",position:position)
          result=["object_id":id.uuidString,"definition":try jsonObject(definition)]
        case "sheet_assembly_configure":
          let id=try uuid("object_id")
          guard var definition=p.objects.first(where:{$0.id==id})?.sheetAssembly else{throw FormError.missing("Sheet assembly not found.")}
          if let supplied=arguments["definition"] {
            guard let raw=supplied as? [String:Any] else{throw FormError.invalid("Provide a complete sheet assembly definition object.")}
            definition=try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:JSONSerialization.data(withJSONObject:raw))
          }
          else {
            if arguments["opening_degrees"] != nil {definition.openingDegrees=try scalar("opening_degrees",default:definition.openingDegrees)}
            if arguments["active_spread"] != nil {definition.activeSpread=try integer("active_spread")}
            if arguments["bend_mm"] != nil {definition.bendMM=try scalar("bend_mm",default:definition.bendMM)}
          }
          if arguments["publication_id"] != nil,try uuid("publication_id") != definition.publicationID {throw FormError.invalid("The assembly definition must reference this publication.")}
          try SheetAssemblyCommands.configure(in:&p,objectID:id,definition:definition);result=["object_id":id.uuidString,"definition":try jsonObject(definition)]
        case "delete":
          let id=try uuid("publication_id")
          guard p.publications?.contains(where:{$0.id==id})==true else{throw FormError.missing("Publication not found.")}
          p.publications?.removeAll{$0.id==id}
          for i in p.textStories?.indices ?? 0..<0 where p.textStories![i].publicationID==id {p.textStories![i].publicationID=nil}
          result=["deleted":true]
        default:throw FormError.invalid("Publication commands: list/get/spreads/create/settings/reorder/add_page/create_pages/insert/remove/duplicate/page_settings/sheet_assembly_create/sheet_assembly_configure/delete/preflight.")
        }
      }
    }
    return result
  }
}

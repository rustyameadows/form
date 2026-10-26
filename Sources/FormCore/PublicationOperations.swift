import Foundation

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
    if command=="list" {return try name=="form_story" ? ["stories":jsonObject(current.textStories ?? [])]:["publications":jsonObject(current.publications ?? [])]}
    if name=="form_story",command=="get" {
      guard let story=current.textStories?.first(where:{$0.id == (try? uuid("story_id"))}) else{throw FormError.missing("Text story not found.")}
      return ["story":try jsonObject(story),"source":try jsonObject(story.sourceElement)]
    }
    if name=="form_publication",command=="get" {
      guard let document=current.publications?.first(where:{$0.id == (try? uuid("publication_id"))}) else{throw FormError.missing("Publication not found.")}
      return try jsonObject(document)
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
        case "publication":try PublicationCommands.assignStory(in:&p,storyID:uuid("story_id"),publicationID:arguments["publication_id"] is NSNull ? nil:uuid("publication_id"))
        case "delete":
          let id=try uuid("story_id")
          guard let story=p.textStories?.first(where:{$0.id==id}) else{throw FormError.missing("Text story not found.")}
          try PublicationCommands.ensureEditable(story,in:p)
          if !story.frames.isEmpty {try PublicationCommands.unlinkFrames(in:&p,frames:story.frames)}
          p.textStories?.removeAll{$0.id==id};result=["deleted":true]
        default:throw FormError.invalid("Story commands: list/get/create/append/reorder/unlink/edit/publication/delete/layout.")
        }
      } else {
        switch command {
        case "create":
          let raw=arguments["page_ids"] as? [String] ?? [],ids=try parseUUIDs(raw)
          guard ids.count==raw.count else{throw FormError.invalid("Choose distinct physical page UUIDs.")}
          let margins=try (arguments["margins"] as? [String:Any]).map{try JSONDecoder.form.decode(PublicationMargins.self,from:JSONSerialization.data(withJSONObject:$0))} ?? .init()
          let id=try PublicationCommands.createPublication(in:&p,name:arguments["name"] as? String ?? "Publication",pages:raw.compactMap(UUID.init(uuidString:)),margins:margins,language:arguments["language"] as? String)
          result=["publication_id":id.uuidString]
        case "settings","reorder":
          let id=try uuid("publication_id")
          guard var document=p.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Publication not found.")}
          if let name=arguments["name"] as? String {document.name=name}
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
            storyID:arguments["story_id"] == nil ? nil:uuid("story_id"),columns:arguments["columns"] as? Int ?? 1,gutter:arguments["gutter"] as? Double ?? 8)
          result=["page_id":page.0.uuidString,"frames":try jsonObject(page.1)]
        case "delete":
          let id=try uuid("publication_id")
          guard p.publications?.contains(where:{$0.id==id})==true else{throw FormError.missing("Publication not found.")}
          p.publications?.removeAll{$0.id==id}
          for i in p.textStories?.indices ?? 0..<0 where p.textStories![i].publicationID==id {p.textStories![i].publicationID=nil}
          result=["deleted":true]
        default:throw FormError.invalid("Publication commands: list/get/create/settings/reorder/add_page/delete/preflight.")
        }
      }
    }
    return result
  }
}

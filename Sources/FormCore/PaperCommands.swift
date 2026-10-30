import Foundation
import CoreFoundation

public enum PaperCommands {
  /// Shared inside-source creation, composed into the caller's existing transaction.
  /// Merely discovering a physical face never calls this mutating helper.
  @discardableResult public static func ensureInside(in project:inout Project,objectID:UUID)throws->UUID {
    guard let object=project.objects.first(where:{$0.id==objectID}),PaperConstruction.isPaper(object) else{throw FormError.missing("Choose a paper construction.")}
    guard !object.locked else{throw FormError.invalid("Unlock the construction before creating its inside source.")}
    let current=try PaperConstruction.definition(for:object)
    if let existing=current.insideArtworkSourceID {return existing}
    let siblings=project.objects.indices.filter{project.objects[$0].designID==object.designID}
    guard siblings.allSatisfy({!project.objects[$0].locked}) else{throw FormError.invalid("Unlock linked paper variants before creating their shared inside source.")}
    let net=try current.net()
    var art=try project.makeObject(recipeID:"artboard",name:object.name+" · Inside registered",parameters:["width":net.size.x,"depth":net.size.y],materialID:"paper-superfine",position:.init(object.position.x+net.size.x+70,0,object.position.z))
    var blank=Artwork(background:"#F7F5EF");blank.backgroundOpacity=0
    art.artwork=current.insideArtwork ?? blank;art.canvasSourceOnly=true
    // Resolve every sibling before publishing any mutation, including helper-only callers.
    let definitions=try siblings.map{index -> (Int,PaperConstruction) in
      var definition=try PaperConstruction.definition(for:project.objects[index]);definition.insideArtworkSourceID=art.id;definition.insideArtwork=nil
      return(index,definition)
    }
    project.objects.append(art)
    for (index,definition) in definitions {project.objects[index].paperConstruction=definition}
    return art.id
  }
  public static func isReadOnly(_ args:[String:Any])->Bool{["inspect","preflight","layout","view","export","template_inspect"].contains(args["command"] as? String ?? "inspect") || PaperAppearanceCommands.readOnlyNames.contains(args["command"] as? String ?? "")}
  public static func preservesDocumentDrafts(_ args:[String:Any])->Bool{isReadOnly(args) || args["command"] as? String == "save_stock"}
  public static func call(engine:OperationEngine,arguments args:[String:Any],source:String)throws->Any {
    if let raw=args["command"],!(raw is String){throw FormError.invalid("Paper command must be a string.")}
    let command=args["command"] as? String ?? "inspect"
    if PaperAppearanceCommands.names.contains(command) {return try PaperAppearanceCommands.call(engine:engine,arguments:args,source:source)}
    if command=="template_attach" || command=="template_inspect" {
      let fields:Set<String>=command=="template_inspect" ? ["command","object_id"]:["command","object_id","path","instructions","vendor","revision","technical_mapping","canonical_to_template"]
      guard Set(args.keys).isSubset(of:fields),let raw=args["object_id"] as? String,UUID(uuidString:raw) != nil else{throw FormError.invalid("Use an object UUID and known template arguments.")}
      if command=="template_attach" {
        guard let path=args["path"] as? String,path.hasPrefix("/"),let instructions=args["instructions"] as? String,!instructions.isEmpty,instructions.utf8.count<=16000,
          let mapping=args["technical_mapping"] as? [[String:Any]],!mapping.isEmpty,mapping.count<=4096 else{throw FormError.invalid("Template attachment needs an absolute SVG path, instructions and explicit technical_mapping.")}
        for key in ["vendor","revision"] {if let raw=args[key] {guard let value=raw as? String,value.utf8.count<=512 else{throw FormError.invalid("\(key) must be a bounded string.")}}}
        for entry in mapping {guard Set(entry.keys).isSubset(of:["elementID","kind"]),let id=entry["elementID"] as? String,!id.isEmpty,id.utf8.count<=512,let kind=entry["kind"] as? String,PaperTemplateChannel.Kind(rawValue:kind) != nil else{throw FormError.invalid("Each template mapping needs an elementID and supported technical kind.")}}
        if let raw=args["canonical_to_template"] {guard let map=raw as? [String:Any],Set(map.keys).isSubset(of:["a","b","c","d","tx","ty"]),map.values.allSatisfy({value in guard let n=value as? NSNumber else{return false};return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite}) else{throw FormError.invalid("Template registration needs finite affine a,b,c,d,tx,ty values.")}}
      }
      guard let graphics=engine.onGraphics else{throw FormError.invalid("Template attachment/inspection requires the native graphics host.")}
      return try graphics("form_paper",args)
    }
    let common:Set<String>=["command","object_id"],fields:[String:Set<String>]=["inspect":[],"preflight":["contents","contents_object_id","interior_id","clearance_mm"],"layout":["sheet_width","sheet_height","margin","gap","count","allow_rotation"],"configure":["definition","parameters","stock","annotations","annotation","annotation_id","acknowledge_artwork"],"annotations":["annotations","annotation","annotation_id"],"ensure_inside":[],"convert":[],"view":["representation","inside","panel_id","split"],"export":["path","format","inside","sheet_width","sheet_height","margin","gap","count","bleed_mm","handoff"]]
    guard let allowed=fields[command],Set(args.keys).isSubset(of:common.union(allowed)) else{throw FormError.invalid("Unknown paper command or argument fields.")}
    if command=="preflight" {
      if let raw=args["contents_object_id"] {
        guard let id=raw as? String,UUID(uuidString:id) != nil,args["contents"]==nil else{throw FormError.invalid("Use one modeled contents_object_id or numeric contents dimensions, not both.")}
        if let raw=args["interior_id"] {guard let id=raw as? String,!id.isEmpty,id.utf8.count<=256 else{throw FormError.invalid("interior_id must be a bounded source identifier.")}}
        if let raw=args["clearance_mm"] {guard let value=raw as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite,value.doubleValue>=0 else{throw FormError.invalid("clearance_mm must be a finite nonnegative millimeter value.")}}
        guard let graphics=engine.onGraphics else{throw FormError.invalid("Modeled contents preflight requires the native graphics host.")}
        return try graphics("form_paper",args)
      }
      guard args["interior_id"]==nil,args["clearance_mm"]==nil else{throw FormError.invalid("interior_id and clearance_mm require a modeled contents_object_id.")}
      if let contents=args["contents"] {
        guard let fields=contents as? [String:Any],Set(fields.keys).isSubset(of:["width","height","depth"]) else{throw FormError.invalid("Numeric contents needs width, height and depth in millimeters.")}
      }
    }
    if command=="export" {
      if let raw=args["bleed_mm"] {guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,(0...25).contains(n.doubleValue) else{throw FormError.invalid("bleed_mm must be0–25 physical millimeters.")}}
      if let raw=args["handoff"] {guard let handoff=raw as? String,["artwork_only","separate","registered_original"].contains(handoff) else{throw FormError.invalid("Choose artwork_only, separate or registered_original handoff.")}}
    }
    if command=="view" || command=="export"{guard let graphics=engine.onGraphics else{throw FormError.invalid("Paper view/export requires the native graphics host.")};return try graphics("form_paper",args)}
    guard let project=engine.project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}) else{throw FormError.missing("Choose a paper object in the current project.")}
    func number(_ key:String,_ fallback:Double)throws->Double{guard let raw=args[key] else{return fallback};guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("\(key) must be a finite number.")};return n.doubleValue}
    func boolean(_ key:String,_ fallback:Bool=false)throws->Bool{guard let raw=args[key] else{return fallback};guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("\(key) must be boolean.")};return n.boolValue}
    func decode<T:Decodable>(_ value:Any,_ type:T.Type)throws->T{guard JSONSerialization.isValidJSONObject(value) else{throw FormError.invalid("Paper definitions must contain JSON-safe finite values.")};return try JSONDecoder.form.decode(type,from:JSONSerialization.data(withJSONObject:value))}
    if command=="convert"{
      guard object.recipeID=="sleeve",!object.locked else{throw FormError.invalid("Explicit conversion supports an unlocked historical folding sleeve.")}
      var d=PaperConstructionEngine.defaults(recipeID:"paperEnvelope");d.dimensions = .init(width:object["width"],height:object["depth"],depth:object["height"]);d.stock.thicknessMM=object["stock"];d.glueTabMM=object["tab"];d.foldPercent=object["fold"];d.artworkReviewRequired=true;d.artworkReferenceSize=object.artworkSize
      try PaperConstructionEngine.validate(d)
      let front=try d.net().panels.first{$0.id=="front"}!.bounds,translation=Affine2.translation(front.x,front.y)
      var transferred=project.surfaceArtwork(object,keepingSwatchReferences:true)
      if var art=transferred {
        if (art.backgroundOpacity ?? 1)>0{let size=project.artworkSize(object);var background=ArtworkElement(kind:"rectangle",x:0,y:0,width:size.x,height:size.y,color:art.background);background.name="Legacy front background";background.opacity=art.backgroundOpacity;background.fillSwatchID=art.backgroundSwatchID;art.elements.insert(background,at:0)}
        art.backgroundOpacity=0
        for i in art.elements.indices where art.elements[i].parentID==nil{art.elements[i].affine=translation.followed(by:art.elements[i].affine ?? .init())}
        if var boundary=art.boundary{for c in boundary.contours.indices{boundary.contours[c].nodes=boundary.contours[c].nodes.map{PathCommands.transformed($0,by:translation)}};art.boundary=boundary}
        art.safeInset=nil;transferred=art
      }
      d.annotations.append(.init(kind:.assembly,text:"Legacy front artwork was translated by (\(front.x), \(front.y)) mm into the registered front panel without scaling. The original linked source is unchanged; review the new net before fabrication.",panelID:"front",view:"dieline"))
      try engine.edit("Converted sleeve to constructed envelope",source:source){p in guard let i=p.objects.firstIndex(where:{$0.id==id}) else{throw FormError.missing("Object missing.")};p.objects[i].recipeID="paperEnvelope";p.objects[i].parameters=PaperConstructionEngine.parameters(d);p.objects[i].paperConstruction=d;p.objects[i].artwork=transferred;p.objects[i].artworkSourceID=nil;p.objects[i].artworkFit=nil;p.objects[i].designID=UUID();p.objects[i].relationship="original"}
      return try jsonObject(engine.project!.objects.first{$0.id==id}!)
    }
    let current=try PaperConstruction.definition(for:object)
    switch command {
    case "inspect":return ["object_id":id.uuidString,"definition":try jsonObject(current),"net":try jsonObject(current.net()),"preflight":try jsonObject(current.preflight()),"appearance":try jsonObject(PaperAppearance.inspect(project:project,object:object)),"inside_source_id":current.insideArtworkSourceID?.uuidString as Any? ?? NSNull(),"artwork_coordinates":"Registered full-net millimeters; both sides share physical coordinates. No automatic fitting or duplex feed is inferred."]
    case "preflight":let contents=try args["contents"].map{try decode($0,PaperDimensions.self)};return try jsonObject(current.preflight(contents:contents))
    case "layout":let count=try number("count",1);guard count.rounded()==count,(1...500).contains(count) else{throw FormError.invalid("Use 1–500 whole copies.")};return try jsonObject(current.net().layout(sheetSize:.init(try number("sheet_width",700),try number("sheet_height",1000)),marginMM:number("margin",10),gapMM:number("gap",6),count:Int(count),allowRotation:boolean("allow_rotation",false)))
    case "ensure_inside":
      guard !object.locked else{throw FormError.invalid("Unlock the construction before creating its inside source.")}
      if let existing=current.insideArtworkSourceID{return ["object_id":id.uuidString,"inside_source_id":existing.uuidString]}
      var created:UUID?
      try engine.edit("Created registered inside artwork",source:source){p in created=try ensureInside(in:&p,objectID:id)}
      return ["object_id":id.uuidString,"inside_source_id":created!.uuidString]
    case "configure","annotations":
      guard !object.locked else{throw FormError.invalid("Unlock this paper construction before editing it.")}
      var next=current
      if let raw=args["definition"]{guard args["parameters"]==nil,args["stock"]==nil else{throw FormError.invalid("Use a complete paper definition or partial parameters/stock, not both.")};try PaperAppearanceCommands.validateDefinitionFields(raw);next=try decode(raw,PaperConstruction.self)}
      if let raw=args["parameters"]{guard let values=raw as? [String:Any] else{throw FormError.invalid("parameters must be a numeric map.")};var numbers:[String:Double]=[:];for (key,value) in values{guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,PaperConstructionEngine.parameters(current)[key] != nil else{throw FormError.invalid("Unknown or nonnumeric paper parameter.")};numbers[key]=n.doubleValue};next=PaperConstructionEngine.applying(numbers,to:next)}
      if let raw=args["stock"]{next.stock=try PaperAppearanceCommands.stock(raw,previous:next.stock)}
      if let raw=args["annotations"]{next.annotations=try decode(raw,[PaperAnnotation].self)}
      if let raw=args["annotation"]{next.annotations.append(try decode(raw,PaperAnnotation.self))}
      if let raw=args["annotation_id"]{guard let value=raw as? String,let uuid=UUID(uuidString:value),next.annotations.contains(where:{$0.id==uuid}) else{throw FormError.invalid("Choose an existing paper annotation.")};next.annotations.removeAll{$0.id==uuid}}
      guard next.kind==current.kind else{throw FormError.invalid("Changing construction families requires an explicit new object.")}
      try PaperConstructionEngine.validate(next)
      var appearanceObject=object;appearanceObject.paperConstruction=next;appearanceObject.parameters=PaperConstructionEngine.parameters(next)
      for finish in next.finishes ?? [] {
        let previous=current.finishes?.first{$0.id==finish.id}
        let disablingRetained=previous != nil && !finish.enabled && previous?.elementIDs==finish.elementIDs && previous?.side==finish.side
        if previous != finish,!disablingRetained {
          guard let artwork=PaperAppearance.source(project:project,object:appearanceObject,side:finish.side).artwork else{throw FormError.invalid("New or changed finishes require their canonical artwork side before assignment.")}
          try PaperAppearance.validateVisibleTargets(finish,artwork:artwork,project:project)
          try PaperAppearance.validateColorOverride(finish,artwork:artwork,project:project)
        }
      }
      let acknowledge=try boolean("acknowledge_artwork")
      try engine.edit(command=="annotations" ? "Changed construction annotations":"Changed paper construction",source:source,coalescing:source=="Studio" && args["stock"] != nil ? "paper-stock-\(id)":nil){p in
        try applyConfiguration(next,objectID:id,in:&p,acknowledgeArtwork:acknowledge)
      }
      return try jsonObject(engine.project!.objects.first{$0.id==id}!)
    default:throw FormError.invalid("Unknown paper command.")
    }
  }
  public static func applyConfiguration(_ next:PaperConstruction,objectID:UUID,in project:inout Project,acknowledgeArtwork:Bool=false)throws {
    guard let object=project.objects.first(where:{$0.id==objectID}) else{throw FormError.missing("Physical paper object missing.")}
    try PaperConstructionEngine.validate(next)
    for i in project.objects.indices where project.objects[i].designID==object.designID {
      guard !project.objects[i].locked else{throw FormError.invalid("Unlock linked paper variants before changing their shared construction.")}
      let previous=project.objects[i];var applied=next
      if previous.id != objectID {applied.finishes=previous.paperConstruction?.finishes}
      project.objects[i].parameters=PaperConstructionEngine.parameters(applied)
      project.objects[i].paperConstruction=applied
      project.objects[i]=try PaperConstructionEngine.synchronized(project.objects[i],previous:previous)
      if acknowledgeArtwork {project.objects[i].paperConstruction?.artworkReviewRequired=false;project.objects[i].paperConstruction?.artworkReferenceSize=try next.net().size}
    }
  }
}

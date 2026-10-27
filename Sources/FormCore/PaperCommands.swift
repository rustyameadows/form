import Foundation
import CoreFoundation

public enum PaperCommands {
  public static func isReadOnly(_ args:[String:Any])->Bool{["inspect","preflight","layout","view","export"].contains(args["command"] as? String ?? "inspect")}
  public static func call(engine:OperationEngine,arguments args:[String:Any],source:String)throws->Any {
    if let raw=args["command"],!(raw is String){throw FormError.invalid("Paper command must be a string.")}
    let command=args["command"] as? String ?? "inspect"
    let common:Set<String>=["command","object_id"],fields:[String:Set<String>]=["inspect":[],"preflight":["contents"],"layout":["sheet_width","sheet_height","margin","gap","count","allow_rotation"],"configure":["definition","parameters","stock","annotations","annotation","annotation_id","acknowledge_artwork"],"annotations":["annotations","annotation","annotation_id"],"ensure_inside":[],"convert":[],"view":["representation","inside","panel_id","split"],"export":["path","format","inside","sheet_width","sheet_height","margin","gap","count"]]
    guard let allowed=fields[command],Set(args.keys).isSubset(of:common.union(allowed)) else{throw FormError.invalid("Unknown paper command or argument fields.")}
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
    case "inspect":return ["object_id":id.uuidString,"definition":try jsonObject(current),"net":try jsonObject(current.net()),"preflight":try jsonObject(current.preflight()),"inside_source_id":current.insideArtworkSourceID?.uuidString as Any? ?? NSNull(),"artwork_coordinates":"Registered full-net millimeters; both sides share physical coordinates. No automatic fitting or duplex feed is inferred."]
    case "preflight":let contents=try args["contents"].map{try decode($0,PaperDimensions.self)};return try jsonObject(current.preflight(contents:contents))
    case "layout":let count=try number("count",1);guard count.rounded()==count,(1...500).contains(count) else{throw FormError.invalid("Use 1–500 whole copies.")};return try jsonObject(current.net().layout(sheetSize:.init(try number("sheet_width",700),try number("sheet_height",1000)),marginMM:number("margin",10),gapMM:number("gap",6),count:Int(count),allowRotation:boolean("allow_rotation",false)))
    case "ensure_inside":
      guard !object.locked else{throw FormError.invalid("Unlock the construction before creating its inside source.")}
      if let existing=current.insideArtworkSourceID{return ["object_id":id.uuidString,"inside_source_id":existing.uuidString]}
      var created:UUID?
      try engine.edit("Created registered inside artwork",source:source){p in
        let net=try current.net();var art=try p.makeObject(recipeID:"artboard",name:object.name+" · Inside registered",parameters:["width":net.size.x,"depth":net.size.y],materialID:"paper-superfine",position:.init(object.position.x+net.size.x+70,0,object.position.z));art.artwork=current.insideArtwork ?? Artwork(background:"#F7F5EF");created=art.id;p.objects.append(art)
        for i in p.objects.indices where p.objects[i].designID==object.designID{guard !p.objects[i].locked else{throw FormError.invalid("Unlock linked paper variants before creating their shared inside source.")};var s=try PaperConstruction.definition(for:p.objects[i]);s.insideArtworkSourceID=art.id;s.insideArtwork=nil;p.objects[i].paperConstruction=s}
      }
      return ["object_id":id.uuidString,"inside_source_id":created!.uuidString]
    case "configure","annotations":
      guard !object.locked else{throw FormError.invalid("Unlock this paper construction before editing it.")}
      var next=current
      if let raw=args["definition"]{guard args["parameters"]==nil,args["stock"]==nil else{throw FormError.invalid("Use a complete paper definition or partial parameters/stock, not both.")};next=try decode(raw,PaperConstruction.self)}
      if let raw=args["parameters"]{guard let values=raw as? [String:Any] else{throw FormError.invalid("parameters must be a numeric map.")};var numbers:[String:Double]=[:];for (key,value) in values{guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,PaperConstructionEngine.parameters(current)[key] != nil else{throw FormError.invalid("Unknown or nonnumeric paper parameter.")};numbers[key]=n.doubleValue};next=PaperConstructionEngine.applying(numbers,to:next)}
      if let raw=args["stock"]{guard let fields=raw as? [String:Any],Set(fields.keys).isSubset(of:["name","vendor","gsm","thicknessMM","grain","sheetSizeMM","verified","notes"]),var merged=try jsonObject(next.stock) as? [String:Any] else{throw FormError.invalid("Invalid stock declaration fields.")};for (key,value) in fields{merged[key]=value};next.stock=try decode(merged,PaperStock.self)}
      if let raw=args["annotations"]{next.annotations=try decode(raw,[PaperAnnotation].self)}
      if let raw=args["annotation"]{next.annotations.append(try decode(raw,PaperAnnotation.self))}
      if let raw=args["annotation_id"]{guard let value=raw as? String,let uuid=UUID(uuidString:value),next.annotations.contains(where:{$0.id==uuid}) else{throw FormError.invalid("Choose an existing paper annotation.")};next.annotations.removeAll{$0.id==uuid}}
      guard next.kind==current.kind else{throw FormError.invalid("Changing construction families requires an explicit new object.")}
      try PaperConstructionEngine.validate(next)
      let acknowledge=try boolean("acknowledge_artwork")
      try engine.edit(command=="annotations" ? "Changed construction annotations":"Changed paper construction",source:source){p in
        for i in p.objects.indices where p.objects[i].designID==object.designID{
          guard !p.objects[i].locked else{throw FormError.invalid("Unlock linked paper variants before changing their shared construction.")}
          let previous=p.objects[i];p.objects[i].parameters=PaperConstructionEngine.parameters(next);p.objects[i].paperConstruction=next;p.objects[i]=try PaperConstructionEngine.synchronized(p.objects[i],previous:previous)
          if acknowledge{p.objects[i].paperConstruction?.artworkReviewRequired=false;p.objects[i].paperConstruction?.artworkReferenceSize=try next.net().size}
        }
      }
      return try jsonObject(engine.project!.objects.first{$0.id==id}!)
    default:throw FormError.invalid("Unknown paper command.")
    }
  }
}

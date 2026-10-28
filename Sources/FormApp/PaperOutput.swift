import AppKit
import CoreFoundation
import CryptoKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

@MainActor enum PaperOutput {
  static func layout(store:StudioStore,definition:PaperConstruction)throws->PaperLayout {
    try definition.net().layout(sheetSize:.init(store.paperSheetWidth,store.paperSheetHeight),marginMM:store.paperSheetMargin,gapMM:store.paperSheetGap,count:store.paperQuantity,allowRotation:false)
  }
  static func path(_ points:[Point2])->CGPath {
    let path=CGMutablePath()
    if let first=points.first {path.move(to:.init(x:first.x,y:first.y));for p in points.dropFirst(){path.addLine(to:.init(x:p.x,y:p.y))};path.closeSubpath()}
    return path
  }
  static func clipPath(_ net:PaperNet)->CGPath {
    let result=CGMutablePath();for panel in net.panels {result.addPath(path(panel.polygon))};return result
  }
  static func drawNet(_ net:PaperNet,artwork:Artwork?,assets:URL,context:CGContext,guides:Bool=true,selected:String?=nil,lineWidth:Double=0.18,stockColor:String="#F7F5EF") {
    context.saveGState();context.addPath(clipPath(net));context.clip()
    context.setFillColor(NSColor(hex:stockColor).cgColor);context.fill(.init(x:0,y:0,width:net.size.x,height:net.size.y))
    if let artwork {ArtworkRenderer.draw(artwork,width:net.size.x,height:net.size.y,assets:assets)}
    context.restoreGState()
    if let selected,let panel=net.panels.first(where:{$0.id==selected}) {
      context.saveGState();context.addPath(path(panel.polygon));context.setFillColor(NSColor(hex:"#D3AB77").withAlphaComponent(0.22).cgColor);context.fillPath();context.restoreGState()
    }
    guard guides else{return}
    drawStructure(net,context:context,lineWidth:lineWidth)
  }
  static func drawStructure(_ net:PaperNet,context:CGContext,lineWidth:Double=0.18) {
    context.saveGState();context.setLineWidth(lineWidth)
    context.setStrokeColor(NSColor(hex:"#CA6543").cgColor)
    for edge in net.cutEdges {context.move(to:.init(x:edge.start.x,y:edge.start.y));context.addLine(to:.init(x:edge.end.x,y:edge.end.y))};context.strokePath()
    context.setStrokeColor(NSColor(hex:"#397D9A").cgColor);context.setLineDash(phase:0,lengths:[2,1.3])
    for fold in net.folds {context.move(to:.init(x:fold.start.x,y:fold.start.y));context.addLine(to:.init(x:fold.end.x,y:fold.end.y))};context.strokePath();context.setLineDash(phase:0,lengths:[])
    for panel in net.panels where panel.role == .glue {
      context.addPath(path(panel.polygon));context.setFillColor(NSColor(hex:"#B49B71").withAlphaComponent(0.2).cgColor);context.fillPath()
    }
    context.restoreGState()
  }
  static func svg(_ net:PaperNet,artwork:Artwork?,assets:URL,guides:Bool=true,title:String)throws->String {
    func xml(_ s:String)->String{s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
    let paths=net.panels.map {p in "M " + p.polygon.map{"\($0.x),\($0.y)"}.joined(separator:" L ") + " Z"}.joined(separator:" ")
    var body="<defs><clipPath id=\"paper-cut-boundary\"><path d=\"\(paths)\"/></clipPath></defs>\n"
    if let artwork {body += "<g id=\"artwork\" clip-path=\"url(#paper-cut-boundary)\">" + (try SVGRenderer.fragment(artwork,width:net.size.x,height:net.size.y,assets:assets)) + "</g>\n"}
    if guides {
      body += "<g id=\"cut\" fill=\"none\" stroke=\"#CA6543\" stroke-width=\"0.18\">\n"
      for e in net.cutEdges {body += "<path id=\"\(xml(e.id))\" d=\"M \(e.start.x),\(e.start.y) L \(e.end.x),\(e.end.y)\"/>\n"};body += "</g>\n<g id=\"crease\" fill=\"none\" stroke=\"#397D9A\" stroke-width=\"0.18\" stroke-dasharray=\"2 1.3\">\n"
      for f in net.folds {body += "<path id=\"\(xml(f.id))\" d=\"M \(f.start.x),\(f.start.y) L \(f.end.x),\(f.end.y)\"/>\n"};body += "</g>\n"
    }
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(net.size.x)mm\" height=\"\(net.size.y)mm\" viewBox=\"0 0 \(net.size.x) \(net.size.y)\"><title>\(xml(title))</title><desc>Actual millimeters. Red cut, blue dashed crease. Prototype construction; prove stock, grain, glue and fit. Artwork uses registered flat coordinates.</desc>\n\(body)</svg>\n"
  }
  static func pdf(net:PaperNet,artwork:Artwork?,assets:URL,layout:PaperLayout,stockColor:String="#F7F5EF")throws->Data {
    guard !layout.hasErrors,layout.sheetCount>0,layout.sheetCount<=64 else{throw FormError.invalid("Resolve sheet layout errors before producing a proof (maximum 64 sheets).")}
    let data=NSMutableData();let unit=72.0/25.4
    var box=CGRect(x:0,y:0,width:layout.sheetSize.x*unit,height:layout.sheetSize.y*unit)
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&box,nil) else{throw FormError.invalid("Could not prepare paper proof.")}
    for index in 0..<layout.sheetCount {
      context.beginPDFPage(nil);context.saveGState();context.translateBy(x:0,y:box.height);context.scaleBy(x:unit,y:-unit)
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      context.setFillColor(NSColor.white.cgColor);context.fill(.init(x:0,y:0,width:layout.sheetSize.x,height:layout.sheetSize.y))
      for p in layout.placements where p.sheetIndex == index {
        context.saveGState();context.translateBy(x:p.origin.x,y:p.origin.y)
        if p.rotationDegrees != 0 {context.translateBy(x:net.size.y,y:0);context.rotate(by:p.rotationDegrees * .pi/180)}
        drawNet(net,artwork:artwork,assets:assets,context:context,stockColor:stockColor)
        context.restoreGState()
      }
      NSGraphicsContext.restoreGraphicsState();context.restoreGState();context.endPDFPage()
    }
    context.closePDF();return data as Data
  }
}

extension StudioStore {
  func prepareSelectedPrint() {
    if let object=primary,PaperConstruction.isPaper(object) {printing.cancel();showingPrint=false;showEnvironment(.fabricate);showPaper(.sheet,object:object,split:true)}
    else {printing.open()}
  }
  func exportPaperDialog(object:ProductObject,format:String) {
    finishArtworkEditing()
    if format == "packet" {
      let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.prompt="Choose output folder"
      guard panel.runModal() == .OK,let url=panel.url else{return}
      let child=url.appendingPathComponent("LAB-paper-" + UUID().uuidString.prefix(8))
      do {_ = try paperOutputCall(paperExportArguments(object:object,format:format,path:child.path));toast("Paper production packet exported")}
      catch {self.error=error.localizedDescription}
    } else {
      let panel=NSSavePanel();panel.allowedContentTypes=[format == "svg" ? .svg:.pdf];panel.nameFieldStringValue=object.name.replacingOccurrences(of:"/",with:"-")+"."+format
      guard panel.runModal() == .OK,let url=panel.url else{return}
      do {_ = try paperOutputCall(paperExportArguments(object:object,format:format,path:url.path));toast("Paper \(format.uppercased()) exported")}
      catch {self.error=error.localizedDescription}
    }
  }
  private func paperExportArguments(object:ProductObject,format:String,path:String)->[String:Any] {
    ["command":"export","object_id":object.id.uuidString,"format":format,"path":path,"inside":paperInside,"sheet_width":paperSheetWidth,"sheet_height":paperSheetHeight,"margin":paperSheetMargin,"gap":paperSheetGap,"count":paperQuantity]
  }
  func paperOutputCall(_ args:[String:Any])throws->Any {
    if args["command"] as? String == "view" { return try paperViewCall(args) }
    guard args["command"] as? String == "export",let project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}) else{throw FormError.invalid("Select a paper construction to export.")}
    guard let format=args["format"] as? String,["svg","pdf","packet"].contains(format),let path=args["path"] as? String,path.hasPrefix("/") else{throw FormError.invalid("Paper output requires svg, pdf or packet and a new absolute path.")}
    let destination=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
    guard !FileManager.default.fileExists(atPath:destination.path) else{throw FormError.invalid("Choose a new output path; existing files are preserved.")}
    // Never publish exports into authoritative source/asset storage.
    let library=repository.root.standardizedFileURL.resolvingSymlinksInPath().path
    let exports=repository.url(for:project.id).appendingPathComponent("Exports").standardizedFileURL.resolvingSymlinksInPath().path
    if destination.path.hasPrefix(library+"/"),!destination.path.hasPrefix(exports+"/") {throw FormError.invalid("Export into this project's Exports folder or an independent destination.")}
    let definition=try PaperConstruction.definition(for:object),net=try definition.net()
    func number(_ key:String,_ fallback:Double)throws->Double {
      guard let raw=args[key] else{return fallback}
      guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("Use a finite number for \(key).")};return n.doubleValue
    }
    let count=try number("count",3);guard count.rounded()==count,(1...64).contains(count) else{throw FormError.invalid("Use 1–64 prototypes.")}
    let layout=try net.layout(sheetSize:.init(try number("sheet_width",700),try number("sheet_height",1000)),marginMM:try number("margin",10),gapMM:try number("gap",6),count:Int(count),allowRotation:false)
    let inside:Bool
    if let raw=args["inside"] {guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("inside must be boolean.")};inside=n.boolValue}else{inside=false}
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    let stockColor=object.color ?? project.material(object.materialID).color
    let outside=project.paperArtwork(for:object,inside:false),interior=project.paperArtwork(for:object,inside:true),art=inside ? interior:outside
    for artwork in [outside,interior].compactMap({$0}) {try ArtworkRenderer.validateGlyphOutput(artwork,assets:assets);try ArtworkRenderer.validateAppearanceOutput(artwork,assets:assets,pixelsPerMM:300/25.4)}
    let preflight=try definition.preflight()
    guard !preflight.hasErrors else{throw FormError.invalid("Resolve construction errors before exporting.")}
    let stage=destination.deletingLastPathComponent().appendingPathComponent(".lab-paper-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:stage)}
    if format == "packet" {
      guard !layout.hasErrors else{throw FormError.invalid("Resolve sheet layout errors before exporting a production packet.")}
      try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
      try PaperOutput.svg(net,artwork:outside,assets:assets,guides:false,title:object.name+" · outside").write(to:stage.appendingPathComponent("outside-artwork.svg"),atomically:true,encoding:.utf8)
      if let interior {try PaperOutput.svg(net,artwork:interior,assets:assets,guides:false,title:object.name+" · inside registered").write(to:stage.appendingPathComponent("inside-artwork.svg"),atomically:true,encoding:.utf8)}
      try PaperOutput.svg(net,artwork:nil,assets:assets,title:object.name+" · cut and crease").write(to:stage.appendingPathComponent("cut-crease.svg"),atomically:true,encoding:.utf8)
      try PaperOutput.pdf(net:net,artwork:outside,assets:assets,layout:layout,stockColor:stockColor).write(to:stage.appendingPathComponent("sheet-proof.pdf"))
      if let interior {try PaperOutput.pdf(net:net,artwork:interior,assets:assets,layout:layout,stockColor:stockColor).write(to:stage.appendingPathComponent("inside-sheet-proof.pdf"))}
      let encoder=JSONEncoder.form
      try encoder.encode(definition).write(to:stage.appendingPathComponent("construction.json"))
      try encoder.encode(layout).write(to:stage.appendingPathComponent("sheet-layout.json"))
      let files=try FileManager.default.contentsOfDirectory(at:stage,includingPropertiesForKeys:nil).sorted{$0.lastPathComponent<$1.lastPathComponent}
      let hashes=try Dictionary(uniqueKeysWithValues:files.map{($0.lastPathComponent,SHA256.hash(data:try Data(contentsOf:$0)).map{String(format:"%02x",$0)}.joined())})
      let record:[String:Any] = ["version":1,"project_id":project.id.uuidString,"object_id":object.id.uuidString,"project_updated_at":ISO8601DateFormatter().string(from:project.updatedAt),"definition":try jsonObject(definition),"net":try jsonObject(net),"preflight":try jsonObject(preflight),"layout":try jsonObject(layout),"source_object":try jsonObject(object),"artifact_sha256":hashes,"hardware_commands":[],"instructions":["Print artwork at actual size; do not scale to fit.","Red lines cut; blue dashed lines crease. Keep construction layers separate from final print.","Inside artwork is registered to the same flat coordinates. Prove duplex feed/turn on actual stock.","Cut and crease a prototype, fold body and dust flaps, glue declared joins, then prove closure and contents fit."]]
      try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:stage.appendingPathComponent("production.json"))
    } else if format == "svg" {try PaperOutput.svg(net,artwork:art,assets:assets,title:object.name).write(to:stage,atomically:true,encoding:.utf8)}
    else {try PaperOutput.pdf(net:net,artwork:art,assets:assets,layout:layout,stockColor:stockColor).write(to:stage)}
    try FileManager.default.moveItem(at:stage,to:destination)
    return ["path":destination.path,"format":format,"object_id":object.id.uuidString,"net_size_mm":[net.size.x,net.size.y],"sheet_count":layout.sheetCount,"prototype_count":layout.count,"preflight":try jsonObject(preflight),"hardware_commands":[]]
  }
  func paperViewCall(_ args:[String:Any])throws->Any {
    guard let project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}),PaperConstruction.isPaper(object) else{throw FormError.invalid("Choose a paper construction.")}
    let representation:PaperRepresentation
    if let raw=args["representation"] {guard let value=raw as? String,let parsed=PaperRepresentation(rawValue:value) else{throw FormError.invalid("Paper view must be panels, dieline or sheet.")};representation=parsed}else{representation=paperRepresentation}
    func boolean(_ key:String,_ fallback:Bool)throws->Bool {
      guard let raw=args[key] else{return fallback}
      guard let value=raw as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else{throw FormError.invalid("\(key) must be boolean.")};return value.boolValue
    }
    let inside=try boolean("inside",paperInside),split=try boolean("split",false)
    var panel=paperSelectedPanelID
    if let raw=args["panel_id"] {guard let value=raw as? String,try PaperConstruction.definition(for:object).net().panels.contains(where:{$0.id==value}) else{throw FormError.invalid("Choose an identified panel in this construction.")};panel=value}
    finishArtworkEditing();paperInside=inside;paperSelectedPanelID=panel;showPaper(representation,object:object,split:split)
    return ["representation":representation.rawValue,"inside":paperInside,"panel_id":paperSelectedPanelID as Any? ?? NSNull(),"layout":surfaceLayout.rawValue,"object_id":object.id.uuidString]
  }
}

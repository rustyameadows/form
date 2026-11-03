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
    let result=CGMutablePath();for ring in PaperPrintGeometry.materialContours(net) {result.addPath(path(ring))};return result
  }
  static func drawNet(_ net:PaperNet,artwork:Artwork?,assets:URL,context:CGContext,guides:Bool=true,selected:String?=nil,lineWidth:Double=0.18,stockColor:String="#F7F5EF",bleedMM:Double=0) {
    let clipping=CGMutablePath()
    if bleedMM>0,let contours=try? PaperPrintGeometry.bleedContours(net,millimeters:bleedMM) {for ring in contours {clipping.addPath(path(ring))}}
    else {clipping.addPath(clipPath(net))}
    context.saveGState();context.addPath(clipping);context.clip(using:.evenOdd)
    let printBounds=CGRect(x:-bleedMM,y:-bleedMM,width:net.size.x+2*bleedMM,height:net.size.y+2*bleedMM)
    context.setFillColor(NSColor(hex:stockColor).cgColor);context.fill(printBounds)
    if let artwork,(artwork.backgroundOpacity ?? 1)>0 {
      context.setFillColor(NSColor(hex:artwork.background).withAlphaComponent(artwork.backgroundOpacity ?? 1).cgColor);context.fill(printBounds)
    }
    if let artwork {ArtworkRenderer.draw(artwork,width:net.size.x,height:net.size.y,assets:assets)}
    context.restoreGState()
    if let selected,let panel=net.panels.first(where:{$0.id==selected}) {
      context.saveGState();context.addPath(path(panel.polygon));for hole in panel.cutouts ?? [] {context.addPath(path(hole.polygon))};context.setFillColor(NSColor(hex:"#D3AB77").withAlphaComponent(0.22).cgColor);context.drawPath(using:.eoFill);context.restoreGState()
    }
    guard guides else{return}
    drawStructure(net,context:context,lineWidth:lineWidth)
  }
  static func drawStructure(_ net:PaperNet,context:CGContext,lineWidth:Double=0.18,interface:Bool=false,interfaceCutColor:NSColor?=nil) {
    context.saveGState();context.setLineWidth(lineWidth)
    context.setStrokeColor((interface ? interfaceCutColor ?? NSColor.black:NSColor(hex:"#CA6543")).cgColor)
    for edge in net.cutEdges {context.move(to:.init(x:edge.start.x,y:edge.start.y));context.addLine(to:.init(x:edge.end.x,y:edge.end.y))};context.strokePath()
    context.setStrokeColor((interface ? Palette.secondaryNS:NSColor(hex:"#397D9A")).cgColor);context.setLineDash(phase:0,lengths:[2,1.3])
    for fold in net.folds {context.move(to:.init(x:fold.start.x,y:fold.start.y));context.addLine(to:.init(x:fold.end.x,y:fold.end.y))};context.strokePath();context.setLineDash(phase:0,lengths:[])
    for panel in net.panels where panel.role == .glue {
      context.addPath(path(panel.polygon));context.setFillColor((interface ? NSColor.black:NSColor(hex:"#B49B71")).withAlphaComponent(0.2).cgColor);context.fillPath()
    }
    context.restoreGState()
  }
  static func xml(_ value:String)->String {
    value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
  }
  static func artworkFragment(_ net:PaperNet,artwork:Artwork,assets:URL,bleedMM:Double=0,prefix:String="paper")throws->String {
    let contours=try PaperPrintGeometry.bleedContours(net,millimeters:bleedMM)
    let shape=PaperPrintGeometry.svgPath(contours),id=prefix+"-print-boundary"
    var background=""
    if (artwork.backgroundOpacity ?? 1)>0 {
      background="<rect x=\"\(-bleedMM)\" y=\"\(-bleedMM)\" width=\"\(net.size.x+2*bleedMM)\" height=\"\(net.size.y+2*bleedMM)\" fill=\"\(xml(artwork.background))\" opacity=\"\(artwork.backgroundOpacity ?? 1)\"/>"
    }
    return "<defs><clipPath id=\"\(id)\"><path fill-rule=\"evenodd\" clip-rule=\"evenodd\" d=\"\(shape)\"/></clipPath></defs><g id=\"artwork\" clip-path=\"url(#\(id))\">\(background)"+(try SVGRenderer.fragment(artwork,width:net.size.x,height:net.size.y,assets:assets))+"</g>"
  }
  static func svg(_ net:PaperNet,artwork:Artwork?,assets:URL,guides:Bool=true,title:String,bleedMM:Double=0)throws->String {
    guard bleedMM.isFinite,(0...25).contains(bleedMM) else{throw FormError.invalid("Paper bleed must be0–25mm.")}
    var body=try artwork.map{try artworkFragment(net,artwork:$0,assets:assets,bleedMM:bleedMM)} ?? ""
    if guides {
      body += "<g id=\"cut\" fill=\"none\" stroke=\"#CA6543\" stroke-width=\"0.18\">\n"
      for e in net.cutEdges {body += "<path id=\"\(xml(e.id))\" data-cut-kind=\"\(e.cutoutKind?.rawValue ?? "outline")\" d=\"M \(e.start.x),\(e.start.y) L \(e.end.x),\(e.end.y)\"/>\n"}
      body += "</g>\n<g id=\"crease\" fill=\"none\" stroke=\"#397D9A\" stroke-width=\"0.18\" stroke-dasharray=\"2 1.3\">\n"
      for f in net.folds {body += "<path id=\"\(xml(f.id))\" d=\"M \(f.start.x),\(f.start.y) L \(f.end.x),\(f.end.y)\"/>\n"}
      body += "</g>\n"
    }
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(net.size.x+2*bleedMM)mm\" height=\"\(net.size.y+2*bleedMM)mm\" viewBox=\"\(-bleedMM) \(-bleedMM) \(net.size.x+2*bleedMM) \(net.size.y+2*bleedMM)\"><title>\(xml(title))</title><desc>Registered canonical millimeters; bleed \(bleedMM)mm. Red cut including actual interior cuts, blue dashed crease. Prototype assumptions require supplier review.</desc>\n\(body)</svg>\n"
  }
  static func registeredSVG(_ net:PaperNet,artwork:Artwork,assets:URL,reference:PaperTemplateReference,bleedMM:Double,includeOriginal:Bool)throws->String {
    let fragment=try artworkFragment(net,artwork:artwork,assets:assets,bleedMM:bleedMM,prefix:"lab")
    let original=try PaperTemplateOperations.original(reference,assets:assets)
    if includeOriginal {return try PaperTemplateOperations.appendArtwork(fragment,to:original,reference:reference)}
    let m=reference.canonicalToTemplate,b=reference.viewBox
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(reference.sizeMM.x)mm\" height=\"\(reference.sizeMM.y)mm\" viewBox=\"\(b.x) \(b.y) \(b.width) \(b.height)\"><g id=\"lab-registered-artwork\" transform=\"matrix(\(m.a) \(m.b) \(m.c) \(m.d) \(m.tx) \(m.ty))\">\(fragment)</g></svg>"
  }
  static func pdf(net:PaperNet,artwork:Artwork?,assets:URL,layout:PaperLayout,stockColor:String="#F7F5EF",bleedMM:Double=0)throws->Data {
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
        drawNet(net,artwork:artwork,assets:assets,context:context,stockColor:stockColor,bleedMM:bleedMM)
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
    ["command":"export","object_id":object.id.uuidString,"format":format,"path":path,"inside":paperInside,"sheet_width":paperSheetWidth,"sheet_height":paperSheetHeight,"margin":paperSheetMargin,"gap":paperSheetGap,"count":paperQuantity,"bleed_mm":paperBleedMM]
  }
  func paperOutputCall(_ args:[String:Any])throws->Any {
    if args["command"] as? String == "view" { return try paperViewCall(args) }
    if ["template_attach","template_inspect"].contains(args["command"] as? String ?? "") { return try paperTemplateCall(args) }
    if args["command"] as? String == "preflight",args["contents_object_id"] != nil { return try PaperNativeFit.preflight(store:self,args:args) }
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
    let bleed=try number("bleed_mm",0)
    guard (0...25).contains(bleed) else{throw FormError.invalid("Paper bleed must be0–25mm.")}
    let handoff=args["handoff"] as? String ?? "separate"
    guard ["artwork_only","separate","registered_original"].contains(handoff) else{throw FormError.invalid("Use artwork_only, separate or registered_original handoff.")}
    if args["handoff"] != nil,format=="pdf" {throw FormError.invalid("Template handoff modes apply to SVG or packet. PDF here is the registered prototype sheet proof.")}
    if handoff=="registered_original",object.paperTemplateReference==nil {throw FormError.invalid("Attach a retained SVG template before requesting registered_original.")}
    if let reference=object.paperTemplateReference,try reference.requiresGeometryReview(definition) {throw FormError.invalid("The construction changed after template interpretation. Review and explicitly reattach the approved template mapping before handoff.")}
    if let reference=object.paperTemplateReference,(format=="packet" || format=="svg"),!reference.containsPrintBounds(netSize:net.size,bleedMM:bleed) {
      throw FormError.invalid("The retained template viewport clips the requested bleed. Attach a template with sufficient registered margin before handoff.")
    }
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    let stockColor=object.color ?? definition.stock.profile?.color ?? project.material(object.materialID).color
    let rawOutside=project.paperArtwork(for:object,inside:false),rawInterior=project.paperArtwork(for:object,inside:true)
    func printed(_ raw:Artwork?,side:PaperFinishAssignment.Side)throws->Artwork? {
      guard let raw else{return nil}
      let resolved=project.resolvingSwatches(in:try project.resolvingComponents(in:raw))
      return try PaperSurfaceRasterizer.printArtwork(resolved,finishes:(definition.finishes ?? []).filter{$0.side==side})
    }
    let outside=try printed(rawOutside,side:.outside),interior=try printed(rawInterior,side:.inside),art=inside ? interior:outside
    for artwork in [rawOutside,rawInterior].compactMap({$0}) {try ArtworkRenderer.validateGlyphOutput(artwork,assets:assets);try ArtworkRenderer.validateAppearanceOutput(artwork,assets:assets,pixelsPerMM:300/25.4)}
    let preflight=try definition.preflight()
    let appearancePreflight=try PaperAppearance.inspect(project:project,object:object)
    guard appearancePreflight.finishes.filter({$0.assignment.enabled}).allSatisfy({$0.sourceRevision != nil && $0.missingElementIDs.isEmpty}),!appearancePreflight.issues.contains(where:{$0.code=="invisibleFinishTargets"}) else{throw FormError.invalid("Repair missing or invisible enabled finish targets before producing a paper handoff.")}
    guard !preflight.hasErrors else{throw FormError.invalid("Resolve construction errors before exporting.")}
    let stage=destination.deletingLastPathComponent().appendingPathComponent(".lab-paper-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:stage)}
    if format == "packet" {
      guard !layout.hasErrors else{throw FormError.invalid("Resolve sheet layout errors before exporting a production packet.")}
      try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
      try PaperOutput.svg(net,artwork:outside,assets:assets,guides:false,title:object.name+" · outside",bleedMM:bleed).write(to:stage.appendingPathComponent("outside-artwork.svg"),atomically:true,encoding:.utf8)
      if let interior {try PaperOutput.svg(net,artwork:interior,assets:assets,guides:false,title:object.name+" · inside registered",bleedMM:bleed).write(to:stage.appendingPathComponent("inside-artwork.svg"),atomically:true,encoding:.utf8)}
      try PaperOutput.svg(net,artwork:nil,assets:assets,title:object.name+" · cut and crease",bleedMM:bleed).write(to:stage.appendingPathComponent("cut-crease.svg"),atomically:true,encoding:.utf8)
      try PaperOutput.pdf(net:net,artwork:outside,assets:assets,layout:layout,stockColor:stockColor,bleedMM:bleed).write(to:stage.appendingPathComponent("sheet-proof.pdf"))
      if let interior {try PaperOutput.pdf(net:net,artwork:interior,assets:assets,layout:layout,stockColor:stockColor,bleedMM:bleed).write(to:stage.appendingPathComponent("inside-sheet-proof.pdf"))}
      if layout.count>1,layout.gapMM<bleed*2 {throw FormError.invalid("Sheet gap must cover the bleed on both adjacent copies.")}
      let appearance=try PaperAppearance.inspect(project:project,object:object)
      try JSONEncoder.form.encode(appearance).write(to:stage.appendingPathComponent("paper-appearance-and-finishes.json"))
      var plateRecords:[[String:Any]]=[]
      for finish in definition.finishes ?? [] where finish.enabled {
        guard let raw=project.paperArtwork(for:object,inside:finish.side == .inside) else{throw FormError.invalid("Finish side source is missing; repair it before export.")}
        let resolved=project.resolvingSwatches(in:try project.resolvingComponents(in:raw))
        let plate=try PaperSurfaceRasterizer.maskArtwork(resolved,elementIDs:Set(finish.elementIDs),paintColor:"#000000")
        let name="finish-"+finish.id.uuidString.lowercased()+".svg"
        try PaperOutput.svg(net,artwork:plate,assets:assets,guides:false,title:finish.name,bleedMM:bleed).write(to:stage.appendingPathComponent(name),atomically:true,encoding:.utf8)
        plateRecords.append(["file":name,"assignment":try jsonObject(finish),"registered_coordinates":"canonical net mm including common bleed extent","manufacturing_tooling_verified":false,"contains_raster_alpha":plate.elements.contains{$0.kind=="image"}])
      }
      if let ref=object.paperTemplateReference {
        let original=try PaperTemplateOperations.original(ref,assets:assets)
        try original.write(to:stage.appendingPathComponent("manufacturer-original.svg"))
        try JSONEncoder.form.encode(ref).write(to:stage.appendingPathComponent("manufacturer-template-reference.json"))
        if let outside {
          try PaperOutput.registeredSVG(net,artwork:outside,assets:assets,reference:ref,bleedMM:bleed,includeOriginal:handoff=="registered_original").write(to:stage.appendingPathComponent("manufacturer-registered-artwork.svg"),atomically:true,encoding:.utf8)
        }
      }
      let encoder=JSONEncoder.form
      try encoder.encode(definition).write(to:stage.appendingPathComponent("construction.json"))
      try encoder.encode(layout).write(to:stage.appendingPathComponent("sheet-layout.json"))
      let files=try FileManager.default.contentsOfDirectory(at:stage,includingPropertiesForKeys:nil).sorted{$0.lastPathComponent<$1.lastPathComponent}
      let hashes=try Dictionary(uniqueKeysWithValues:files.map{($0.lastPathComponent,SHA256.hash(data:try Data(contentsOf:$0)).map{String(format:"%02x",$0)}.joined())})
      let record:[String:Any] = ["version":2,"bleed_mm":bleed,"handoff":handoff,"finishing_plates":plateRecords,"appearance":try jsonObject(appearance),"artwork_safety":try PaperProductionReview.inspect(object:object,project:project),"vendor_handoff_approved":false,"project_id":project.id.uuidString,"object_id":object.id.uuidString,"project_updated_at":ISO8601DateFormatter().string(from:project.updatedAt),"definition":try jsonObject(definition),"net":try jsonObject(net),"preflight":try jsonObject(preflight),"layout":try jsonObject(layout),"source_object":try jsonObject(object),"artifact_sha256":hashes,"hardware_commands":[],"instructions":["Print artwork at actual size; do not scale to fit.","Red lines cut; blue dashed lines crease. Keep construction layers separate from final print.","Inside artwork is registered to the same flat coordinates. Prove duplex feed/turn on actual stock.","Cut and crease a prototype, fold body and dust flaps, glue declared joins, then prove closure and contents fit."]]
      try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:stage.appendingPathComponent("production.json"))
    } else if format == "svg" {
      let output:String
      if let ref=object.paperTemplateReference,let art,args["handoff"] != nil {
        output=try PaperOutput.registeredSVG(net,artwork:art,assets:assets,reference:ref,bleedMM:bleed,includeOriginal:handoff=="registered_original")
      } else {output=try PaperOutput.svg(net,artwork:art,assets:assets,guides:handoff != "artwork_only",title:object.name,bleedMM:bleed)}
      try output.write(to:stage,atomically:true,encoding:.utf8)
    }
    else {try PaperOutput.pdf(net:net,artwork:art,assets:assets,layout:layout,stockColor:stockColor,bleedMM:bleed).write(to:stage)}
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
    var panel=paperSelectionObjectID==object.id ? paperSelectedPanelID:nil
    if let raw=args["panel_id"] {guard let value=raw as? String,try PaperConstruction.definition(for:object).net().panels.contains(where:{$0.id==value}) else{throw FormError.invalid("Choose an identified panel in this construction.")};panel=value}
    finishArtworkEditing();if paperSelectionObjectID != object.id {paperSelectedFoldID=nil};paperInside=inside;paperSelectionObjectID=object.id;paperSelectedPanelID=panel;showPaper(representation,object:object,split:split)
    return ["representation":representation.rawValue,"inside":paperInside,"panel_id":paperSelectedPanelID as Any? ?? NSNull(),"layout":surfaceLayout.rawValue,"object_id":object.id.uuidString]
  }
}

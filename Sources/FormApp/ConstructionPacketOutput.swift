import AppKit
import CoreFoundation
import CryptoKit
import Foundation
import FormCore
import FormGraphics
import FormCADModel

/// One production path for independently stocked planar cut-piece assemblies.
/// It consumes the accepted source, never moves artwork or assembly parts, and
/// publishes only a new immutable destination after every file is prepared.
@MainActor enum ConstructionPacketOutput {
  static let maximumBytes=128_000_000,maximumFiles=2048
  struct Files {
    var values=[String:Data]()
    var roles=[String:String]()
    var bytes=0
    mutating func add(_ name:String,_ data:Data,role:String)throws {
      guard !name.hasPrefix("/"),!name.split(separator:"/").contains(".."),values[name]==nil,!data.isEmpty,
        data.count<=64_000_000,bytes<=maximumBytes-data.count,values.count<maximumFiles else {
        throw FormError.invalid("The construction packet exceeds its bounded file envelope or contains a duplicate/unsafe file path.")
      }
      values[name]=data;roles[name]=role;bytes+=data.count
    }
    mutating func json<T:Encodable>(_ name:String,_ value:T,role:String="specification")throws {try add(name,JSONEncoder.form.encode(value),role:role)}
  }
  static func export(store:StudioStore,objectID:UUID,arguments:[String:Any])throws->Any {
    guard let project=store.project,let object=project.objects.first(where:{$0.id==objectID}) else{throw FormError.invalid("Open the construction's project before preparing its packet.")}
    if arguments["command"] as? String == "packet_status" {return try status(project:project,object:object,arguments:arguments)}
    let model=try ConstructionPacketModel(project:project,object:object)
    if arguments["command"] as? String == "preflight" {return try model.metadata()}
    let format=arguments["format"] as? String ?? "packet"
    guard ["packet","svg","pdf"].contains(format),let path=arguments["path"] as? String,path.hasPrefix("/") else {throw FormError.invalid("Construction files require packet/svg/pdf and a new absolute destination.")}
    for key in ["sheet_width","sheet_height","margin","gap","count","bleed_mm"] where arguments[key] != nil {
      throw FormError.invalid("Independent-piece output uses saved production materials, quantity and bleed. Edit the production source rather than overriding ‘\(key)’ during export.")
    }
    guard model.isValid else{throw FormError.invalid(model.issues.filter{$0.severity == .error}.map(\.message).joined(separator:"\n"))}
    let fm=FileManager.default,destination=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
    guard !fm.fileExists(atPath:destination.path) else{throw FormError.invalid("Choose a new construction-packet destination; exported revisions are immutable.")}
    let library=store.repository.root.standardizedFileURL.resolvingSymlinksInPath().path
    let exports=store.repository.url(for:project.id).appendingPathComponent("Exports").standardizedFileURL.resolvingSymlinksInPath().path
    guard !destination.path.hasPrefix(library+"/") || destination.path.hasPrefix(exports+"/") else {throw FormError.invalid("Export construction files into this project's Exports folder or an independent destination.")}
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    var files=Files()
    if format == "svg" {
      try files.add("output.svg",Data(ConstructionPacketDrawing.logicalPartsSVG(model.pieces,labels:model.production.labels).utf8),role:"nominalCut")
    }else if format == "pdf" {
      try files.add("output.pdf",try ConstructionPacketPDF.patterns(model),role:"proof")
    }else {
      try files.json("Source.json",model.sourceSnapshot,role:"editableSource")
      try files.json("Cut-list.json",model.pieces)
      try files.json("Material-layouts.json",model.layouts)
      try files.json("Assembly-order.json",model.steps)
      try files.json("Tape-schedule.json",model.attachments.tapes)
      try files.json("Staple-schedule.json",model.attachments.staples)
      try files.json("Adhesive-regions.json",model.attachments.adhesives)
      let preflight=try JSONSerialization.data(withJSONObject:model.metadata(),options:[.prettyPrinted,.sortedKeys]);try files.add("Preflight.json",preflight,role:"specification")
      try files.add("Nominal-parts.svg",Data(ConstructionPacketDrawing.logicalPartsSVG(model.pieces,labels:model.production.labels).utf8),role:"nominalCut")
      try files.add("Actual-size-pattern-proofs.pdf",ConstructionPacketPDF.patterns(model),role:"proof")
      try files.add("Material-layout-proofs.pdf",ConstructionPacketPDF.materialLayouts(model),role:"proof")
      try files.add("Assembly-and-sections.pdf",ConstructionPacketPDF.assembly(model),role:"instructions")
      let views=model.production.views.isEmpty ? ConstructionAssemblyDrawings.defaultViews():model.production.views
      for view in views {
        let drawing=try ConstructionAssemblyDrawings.resolve(source:model.source,view:view)
        try files.add("Drawings/"+fileID(view.id)+".svg",Data(ConstructionAssemblyDrawings.svg(drawing,labels:model.production.labels).utf8),role:"assemblyReference")
      }
      var printByPiece=[String:(front:Artwork?,back:Artwork?)](),pieceNets=[String:PaperNet](),finishRecords=[[String:Any]]()
      for piece in model.pieces {
        let prefix="Pieces/"+fileID(piece.id)
        pieceNets[piece.id+":front"]=pieceNet(piece)
        let independentReverse=piece.back.map {face in !(project.objects.first(where:{$0.id==face.sourceObjectID}).map{PaperConstruction.isPaper($0) && face.sourceSide == .inside} ?? false)} ?? false
        pieceNets[piece.id+":reverse"]=pieceNet(piece,reverseIndependent:independentReverse)
        try files.add(prefix+"/nominal-cut.svg",Data(ConstructionPacketDrawing.pieceSVG(piece,labels:model.production.labels,registrationMarks:model.production.registrationMarks).utf8),role:"nominalCut")
        var printable:[PaperFinishAssignment.Side:Artwork]=[:]
        for side in [PaperFinishAssignment.Side.outside,.inside] {
          guard let original=try pieceArtwork(piece,side:side,owner:object,project:project,source:model.source) else{continue}
          try ArtworkRenderer.validateGlyphOutput(original,assets:assets)
          try ArtworkRenderer.validateAppearanceOutput(original,assets:assets,pixelsPerMM:300/25.4)
          let assignments=pieceFinishes(piece,side:side,owner:object)
          let print=try PaperSurfaceRasterizer.printArtwork(original,finishes:assignments)
          printable[side]=print
          let label=side == .outside ? "front":"reverse"
          let net=pieceNets[piece.id+":"+label]!
          let svg=try artworkSVG(net:net,artwork:print,assets:assets,title:piece.name+" / "+label+" printing",bleed:model.production.bleedMM)
          try files.add(prefix+"/"+label+"-artwork.svg",Data(svg.utf8),role:"printArtwork")
          for finish in assignments where finish.enabled {
            let ids=Set(original.elements.map(\.id));guard Set(finish.elementIDs).isSubset(of:ids) else{throw FormError.invalid("Finish ‘\(finish.name)’ has missing canonical piece targets; repair it before exporting.")}
            let mask=try PaperSurfaceRasterizer.maskArtwork(original,elementIDs:Set(finish.elementIDs),paintColor:"#000000")
            let name=prefix+"/finish-"+label+"-"+finish.id.uuidString.lowercased()+".svg"
            try files.add(name,Data(try artworkSVG(net:net,artwork:mask,assets:assets,title:finish.name,bleed:model.production.bleedMM).utf8),role:"finishMask")
            finishRecords.append(["piece_id":piece.id,"side":label,"file":name,"assignment":try json(finish),"registered_coordinates":"piece-local actual millimeters","manufacturing_tooling_verified":false])
          }
        }
        printByPiece[piece.id]=(printable[.outside],printable[.inside])
      }
      try files.add("Finish-assignments.json",JSONSerialization.data(withJSONObject:finishRecords,options:[.prettyPrinted,.sortedKeys]),role:"specification")
      for batch in model.layouts.batches {
        for index in 0..<batch.sheetCount {
          let prefix="Layouts/"+fileID(batch.id)+String(format:"/sheet-%03d",index+1)
          try files.add(prefix+"-nominal-cut.svg",Data(ConstructionPacketDrawing.layoutSVG(batch,sheetIndex:index,pieces:model.pieces,labels:model.production.labels).utf8),role:"nominalCutLayout")
          if model.production.labels {
            for (keyIndex,svg) in ConstructionPacketDrawing.layoutLabelKeySVGs(batch,sheetIndex:index).enumerated() {
              try files.add(prefix+String(format:"-label-key-%03d.svg",keyIndex+1),Data(svg.utf8),role:"layoutLabelKey")
            }
          }
          for inside in [false,true] {
            let label=inside ? "reverse":"front"
            if let svg=try layoutArtwork(batch,sheetIndex:index,pieces:model.pieces,nets:pieceNets,artwork:printByPiece,inside:inside,assets:assets,bleed:model.production.bleedMM) {
              try files.add(prefix+"-"+label+"-artwork.svg",Data(svg.utf8),role:"printArtworkLayout")
            }
          }
        }
      }
      for asset in model.assetNames.sorted() {
        guard safeAsset(asset) else{throw FormError.invalid("A construction source asset has an unsafe filename.")}
        let url=assets.appendingPathComponent(asset),info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>0,size<=64_000_000 else {throw FormError.invalid("A construction source asset is missing or exceeds its bounded file size.")}
        let data=try Data(contentsOf:url);guard data.count==size else{throw FormError.invalid("A source asset changed while preparing construction files.")}
        try files.add("Assets/"+asset,data,role:"originalAsset")
      }
      let descriptions=files.values.keys.sorted().map{name in ["path":name,"sha256":ConstructionMaterialLayouts.digest(files.values[name]!),"bytes":files.values[name]!.count,"role":files.roles[name]!] as [String:Any]}
      let manifest:[String:Any]=["packet_version":1,"application":"LAB","kind":"independentPlanarConstruction","project_id":project.id.uuidString,"object_id":objectID.uuidString,
        "source_digest":model.sourceDigest,"source_snapshot":"Source.json","units":"mm","nominal_geometry":true,"tool_compensation_applied":false,"font_revision":GeometryFactory.fontRevision,
        "declared_kerf_mm":model.production.declaredKerfMM as Any? ?? NSNull(),"production_quantity":model.production.quantity,"print_bleed_mm":model.production.bleedMM,
        "technical_labels_enabled":model.production.labels,"registration_marks_enabled":model.production.registrationMarks,
        "material_layout_pdf_pages":ConstructionPacketPDF.materialLayoutPageIndex(model),"layout_label_keys_are_annotation_only":true,
        "assembly_instructions":"Assembly-order.json","physical_cut_count":model.pieces.reduce(0){$0+$1.quantity*model.production.quantity},
        "total_staple_count":model.attachments.staples.count*model.production.quantity,"total_tape_cut_count":model.physicalTapeCutCount,
        "files":descriptions,"assumptions":model.production.assumptions,"process_notes":model.production.processNotes,
        "reverse_face_registration":"Independent reverse sources remain readable; their cut contour is reflected across the whole piece. Registered paper-inside sources keep their canonical atlas. Layout positions are logical references; no press-specific duplex feed/mirroring is inferred.","source_material_color_is_printed":false,
        "piece_coordinate_system":"Cut contours and guides are piece-local actual millimeters. Cut-list bounds x/y identify the original canonical net origin, not a sheet placement.",
        "sheet_repacking_changes_canonical_artwork":false,"physical_production_verified":false,"machine_contacted":false,"inventory_deducted":false]
      try files.add("Manifest.json",JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]),role:"manifest")
    }
    guard let live=store.project,live.id==project.id,let current=live.objects.first(where:{$0.id==objectID}),
      try ConstructionPacketModel.currentSourceDigest(project:live,object:current)==model.sourceDigest else {throw FormError.invalid("The construction changed while preparing its files; capture the current accepted revision again.")}
    let parent=destination.deletingLastPathComponent(),stage=parent.appendingPathComponent(".lab-construction-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:stage,withIntermediateDirectories:true);defer{try? fm.removeItem(at:stage)}
    if format == "packet" {
      let content=stage.appendingPathComponent("Construction",isDirectory:true);try fm.createDirectory(at:content,withIntermediateDirectories:false)
      for name in files.values.keys.sorted() {let url=content.appendingPathComponent(name);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try files.values[name]!.write(to:url,options:.atomic)}
      if destination.pathExtension.lowercased()=="zip" {
        let archive=stage.appendingPathComponent("packet.zip"),process=Process(),errors=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");process.arguments=["-c","-k","--keepParent","--norsrc","--noextattr","--noqtn",content.path,archive.path];process.standardError=errors;process.standardOutput=FileHandle.nullDevice
        try process.run();let message=errors.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();guard process.terminationStatus==0 else{throw FormError.invalid("Local construction packaging failed: "+String(decoding:message.prefix(1000),as:UTF8.self))}
        let size=try archive.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size>0,size<=maximumBytes else{throw FormError.invalid("The compressed construction packet exceeds its bounded size.")}
        try fm.moveItem(at:archive,to:destination)
      }else{try fm.moveItem(at:content,to:destination)}
    }else {
      let name=format == "svg" ? "output.svg":"output.pdf",temp=stage.appendingPathComponent(name);try files.values[name]!.write(to:temp,options:.atomic);try fm.moveItem(at:temp,to:destination)
    }
    return ["path":destination.path,"format":format,"source_digest":model.sourceDigest,"manifest_digest":files.values["Manifest.json"].map{ConstructionMaterialLayouts.digest($0)} as Any? ?? NSNull(),"object_id":objectID.uuidString,"files":files.values.keys.sorted(),"bytes":files.bytes,
      "piece_count":model.pieces.count,"material_batch_count":model.layouts.batches.count,"nominal_geometry":true,"tool_compensation_applied":false,"physical_production_verified":false,"machine_contacted":false]
  }
  static func status(project:Project,object:ProductObject,arguments:[String:Any])throws->[String:Any] {
    guard let path=arguments["path"] as? String,path.hasPrefix("/") else{throw FormError.invalid("Choose the absolute path of an exported construction packet folder.")}
    let root=URL(fileURLWithPath:path).standardizedFileURL
    let manifestURL=root.appendingPathComponent("Manifest.json"),properties=try manifestURL.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
    guard properties.isRegularFile==true,properties.isSymbolicLink != true,let length=properties.fileSize,(1...2_000_000).contains(length) else{throw FormError.invalid("Choose an unpacked construction packet with its bounded Manifest.json.")}
    let data=try Data(contentsOf:manifestURL)
    guard let manifest=try JSONSerialization.jsonObject(with:data) as? [String:Any],manifest["kind"] as? String=="independentPlanarConstruction",
      manifest["object_id"] as? String==object.id.uuidString,let original=manifest["source_digest"] as? String,original.count==64,original.allSatisfy(\.isHexDigit),
      let files=manifest["files"] as? [[String:Any]],files.count<maximumFiles else{throw FormError.invalid("This folder is not a valid captured construction packet for the selected source.")}
    var bad=[String](),total=data.count,names=Set<String>()
    for file in files {
      guard let name=file["path"] as? String,!name.isEmpty,!name.hasPrefix("/"),name.utf8.count<=1024,!name.split(separator:"/").contains(".."),!name.contains("\\"),names.insert(name).inserted,
        let expected=file["sha256"] as? String,expected.count==64,expected.allSatisfy(\.isHexDigit),let bytes=file["bytes"] as? Int,(1...64_000_000).contains(bytes),total<=maximumBytes-bytes else{throw FormError.invalid("The packet manifest contains an invalid or oversized file entry.")}
      total+=bytes;let url=root.appendingPathComponent(name)
      let resolved=url.standardizedFileURL.resolvingSymlinksInPath()
      guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else{throw FormError.invalid("A packet file escapes its captured folder.")}
      guard let info=try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]),info.isRegularFile==true,info.isSymbolicLink != true,info.fileSize==bytes,
        let payload=try? Data(contentsOf:url),payload.count==bytes,ConstructionMaterialLayouts.digest(payload)==expected else{bad.append(name);continue}
    }
    let current=try ConstructionPacketModel.currentSourceDigest(project:project,object:object)
    return ["path":root.path,"object_id":object.id.uuidString,"captured_source_digest":original,"current_source_digest":current,"source_current":original==current,
      "artifact_integrity":bad.isEmpty,"changed_or_missing_files":bad,"manifest_digest":ConstructionMaterialLayouts.digest(data),"stale":original != current,"files_checked":files.count,
      "captured_revision_modified":false,"physical_production_verified":false,"machine_contacted":false]
  }
  static func fileID(_ value:String)->String {
    let readable=String(value.unicodeScalars.map{CharacterSet.alphanumerics.contains($0) || $0=="-" || $0=="_" ? Character(String($0)):"_"}.prefix(80))
    return readable+"-"+String(ConstructionMaterialLayouts.digest(Data(value.utf8)).prefix(8))
  }
  private static func safeAsset(_ value:String)->Bool {!value.isEmpty && value.utf8.count<=512 && value==URL(fileURLWithPath:value).lastPathComponent && !value.hasPrefix(".") && !value.contains("\\") && value.rangeOfCharacter(from:.controlCharacters)==nil}
  private static func json<T:Encodable>(_ value:T)throws->Any {try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(value))}
  static func pieceNet(_ piece:ResolvedConstructionPiece,reverseIndependent:Bool=false)->PaperNet {
    let contours=piece.cutContours.map {ring in reverseIndependent ? ring.map{Point2(piece.bounds.width-$0.x,$0.y)}:ring}
    let outer=contours[0],holes=contours.dropFirst().enumerated().map{PaperPanelCutout(id:"hole-\($0.offset)",polygon:$0.element)}
    return .init(size:.init(piece.bounds.width,piece.bounds.height),panels:[.init(id:piece.id,name:piece.name,role:.body,polygon:outer,cutouts:holes.isEmpty ? nil:holes)],folds:[],joins:[],cutEdges:[],rootPanelID:piece.id)
  }
  static func pieceFinishes(_ piece:ResolvedConstructionPiece,side:PaperFinishAssignment.Side,owner:ProductObject)->[PaperFinishAssignment] {
    let explicit=side == .outside ? piece.front != nil:piece.back != nil
    let declared=owner.paperConstruction?.authored?.components?.first{$0.id==piece.id}?.finishes != nil
    if explicit || declared {return piece.finishes.filter{$0.side==side}}
    return (piece.finishes.isEmpty ? owner.paperConstruction?.finishes ?? []:piece.finishes).filter{$0.side==side}
  }
  private static func artworkSVG(net:PaperNet,artwork:Artwork,assets:URL,title:String,bleed:Double)throws->String {
    let fragment=try PaperOutput.artworkFragment(net,artwork:artwork,assets:assets,bleedMM:bleed,prefix:"piece-print")
    return ConstructionPacketDrawing.header(width:net.size.x+bleed*2,height:net.size.y+bleed*2,title:title,viewBox:"\(-bleed) \(-bleed) \(net.size.x+bleed*2) \(net.size.y+bleed*2)")+"<metadata>Actual piece-local millimeters; substrate color is material, not synthetic ink. Technical cut, score, turn-in, seam and registration guides are excluded from printing.</metadata>"+fragment+"</svg>"
  }
  static func pieceArtwork(_ piece:ResolvedConstructionPiece,side:PaperFinishAssignment.Side,owner:ProductObject,project:Project,source:PaperConstruction)throws->Artwork? {
    let face=side == .outside ? piece.front:piece.back
    var artwork:Artwork?,origin:Point2
    if let face {
      guard let original=project.objects.first(where:{$0.id==face.sourceObjectID}) else{throw FormError.invalid("Cut piece ‘\(piece.id)’ lost its canonical artwork source.")}
      artwork=PaperConstruction.isPaper(original) ? project.paperArtwork(for:original,inside:face.sourceSide == .inside):project.surfaceArtwork(original)
      let values=try source.authored?.poseValues(fold:100,opening:0,explosion:0) ?? [:]
      origin=try face.sourceOriginMM.map {p in .init(try CADExpression.evaluate(p.x.expression,variables:values),try CADExpression.evaluate(p.y.expression,variables:values))} ?? .init()
    }else{artwork=project.paperArtwork(for:owner,inside:side == .inside);origin = .init(piece.bounds.x,piece.bounds.y)}
    guard var artwork else{return nil}
    artwork=project.resolvingSwatches(in:try project.resolvingComponents(in:artwork))
    let crop=Affine2.translation(-origin.x,-origin.y)
    for index in artwork.elements.indices where artwork.elements[index].parentID==nil {artwork.elements[index].affine=crop.followed(by:artwork.elements[index].affine ?? .init())}
    return artwork
  }
  private static func uniqueIDs(_ fragment:String,prefix:String)->String {
    guard let expression=try? NSRegularExpression(pattern:"\\bid=\"([^\"]+)\"") else{return fragment}
    let source=fragment as NSString,ids=Set(expression.matches(in:fragment,range:NSRange(location:0,length:source.length)).map{source.substring(with:$0.range(at:1))})
    var result=fragment
    for id in ids.sorted(by:{$0.count>$1.count}) {let replacement=prefix+"-"+id;result=result.replacingOccurrences(of:"id=\"\(id)\"",with:"id=\"\(replacement)\"").replacingOccurrences(of:"url(#\(id))",with:"url(#\(replacement))").replacingOccurrences(of:"href=\"#\(id)\"",with:"href=\"#\(replacement)\"")}
    return result
  }
  private static func layoutArtwork(_ batch:ConstructionMaterialBatch,sheetIndex:Int,pieces:[ResolvedConstructionPiece],nets:[String:PaperNet],artwork:[String:(front:Artwork?,back:Artwork?)],inside:Bool,assets:URL,bleed:Double)throws->String? {
    var fragments=[String]()
    for p in batch.placements where p.sheetIndex==sheetIndex {
      guard let values=artwork[p.pieceID],let art=inside ? values.back:values.front,let net=nets[p.pieceID+":"+(inside ? "reverse":"front")] else{continue}
      let prefix=fileID(p.pieceID)+"-\(p.copy)",fragment=try PaperOutput.artworkFragment(net,artwork:art,assets:assets,bleedMM:bleed,prefix:prefix),m=p.transform
      fragments.append("<g data-piece-id=\"\(ConstructionPacketDrawing.xml(p.pieceID))\" data-copy=\"\(p.copy)\" transform=\"matrix(\(m.a) \(m.b) \(m.c) \(m.d) \(m.tx) \(m.ty))\">"+uniqueIDs(fragment,prefix:prefix)+"</g>")
    }
    guard !fragments.isEmpty else{return nil}
    return ConstructionPacketDrawing.header(width:batch.format.widthMM,height:batch.format.surface == .roll ? batch.usedLengthMM:batch.format.lengthMM,title:batch.stock.name+" / registered piece artwork / "+(inside ? "reverse":"front"))+fragments.joined()+"</svg>"
  }
}

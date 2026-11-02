import AppKit
import FormCore

extension PublicationOutput {
  /// A declared physical edition provides the parent stock and ink intent. A
  /// second edition with different parent assignments requires explicit choice.
  public static func physicalAssembly(_ project:Project,documentID:UUID,objectID:UUID?=nil)throws->ProductObject? {
    if let objectID {
      guard let object=project.objects.first(where:{$0.id==objectID}),object.sheetAssembly?.publicationID==documentID,
        object.sheetAssembly?.parentSheets != nil else{throw FormError.invalid("Choose a physical edition with declared parent sheets for this publication.")}
      _ = try project.resolvedSheetAssembly(object);return object
    }
    let editions=project.objects.filter{$0.sheetAssembly?.publicationID==documentID && $0.sheetAssembly?.parentSheets != nil}
    guard let first=editions.first else{return nil}
    guard editions.allSatisfy({$0.sheetAssembly?.parentSheets==first.sheetAssembly?.parentSheets}) else{
      throw FormError.invalid("This publication has different physical editions. Choose physical_object_id before exporting their stock and ink assignments.")
    }
    _ = try project.resolvedSheetAssembly(first);return first
  }
  public static func physicalArrangement(_ project:Project,documentID:UUID,assembly:ProductObject,layout:PublicationPDFLayout)throws->PublicationPDFPlan {
    guard let document=project.publications?.first(where:{$0.id==documentID}),
      let parents=assembly.sheetAssembly?.parentSheets,!parents.isEmpty else{throw FormError.invalid("Choose a declared physical sheet edition.")}
    _ = try project.resolvedSheetAssembly(assembly)
    if layout != .booklet {
      var plan=try arrangement(project,documentID:documentID,layout:layout)
      for i in plan.sides.indices {plan.sides[i].bleedMM=0}
      return plan
    }
    let byID=Dictionary(uniqueKeysWithValues:document.pages.enumerated().map{($0.element.id,($0.offset+1,$0.element.objectID))})
    var sides=[PublicationPDFSide](),blanks=0
    for(index,parent) in parents.enumerated() {
      for(reverse,slots) in [(false,parent.frontPageIDs),(true,parent.backPageIDs)] {
        var x=0.0,placements=[PublicationPDFPlacement]()
        for slot in slots {
          let source=slot.flatMap{byID[$0]},object=source.flatMap{entry in project.objects.first{$0.id==entry.1}}
          let width=object?.artworkSize.x ?? parent.sizeMM.x/2,height=object?.artworkSize.y ?? parent.sizeMM.y
          placements.append(.init(sourcePage:source?.0,objectID:source?.1,xMM:x,widthMM:width,heightMM:height));x+=width
          if source==nil {blanks+=1}
        }
        sides.append(.init(index:sides.count+1,sheet:index+1,reverse:reverse,widthMM:parent.sizeMM.x,heightMM:parent.sizeMM.y,bleedMM:0,placements:placements))
      }
    }
    return .init(layout:layout,sourcePageCount:document.pages.count,addedBlankPages:blanks,sides:sides)
  }
  private static func physicalInkPage(_ project:Project,object:ProductObject)throws->InkPrintPage {
    guard var art=project.surfaceArtwork(object,keepingSwatchReferences:true) else{throw FormError.missing("A physical print page is missing its artwork.")}
    // Parent dimensions explicitly define the cut/fold sheet. Extra source bleed
    // is cropped by this output, never added outside that physical paper size.
    art.bleed=0
    guard art.backgroundOpacity==0 else{throw FormError.invalid("Black-only stock pages need a transparent artwork background; the paper color is a substrate, not printed ink.")}
    let masks=Set(art.elements.compactMap(\.clipID)),source=art
    let children=Dictionary(grouping:source.elements,by:\.parentID)
    var removed=Set<UUID>()
    func subtree(_ root:ArtworkElement)->[ArtworkElement] {
      [root]+(children[root.id] ?? []).flatMap{subtree($0)}
    }
    func outside(_ bounds:Rect2)->Bool {
      bounds.maxX<=0 || bounds.maxY<=0 || bounds.x>=object.artworkSize.x || bounds.y>=object.artworkSize.y
    }
    func exclude(_ element:ArtworkElement) {
      guard !masks.contains(element.id) else{return}
      let tree=subtree(element),hasBoolean=tree.contains{$0.booleanOperation != nil}
      // A boolean's declared frame need not contain its operands. Their union
      // is conservative for every operation, including a disjoint intersection.
      // Never remove an individual operand: doing so changes the printed result.
      let bounds:Rect2
      if hasBoolean {
        bounds=tree.dropFirst().reduce(source.visualBounds(of:element)){$0.union(source.visualBounds(of:$1))}
      }else{bounds=source.visualBounds(of:element)}
      if outside(bounds) {removed.formUnion(tree.map(\.id));return}
      guard element.booleanOperation==nil else{return}
      for child in children[element.id] ?? [] {exclude(child)}
    }
    for element in children[nil] ?? [] {exclude(element)}
    art.elements.removeAll{removed.contains($0.id)}
    return .init(id:object.id,name:object.name,artwork:art,width:object.artworkSize.x,height:object.artworkSize.y)
  }
  private static func validateBlackOnly(_ project:Project,page:InkPrintPage,assets:URL)throws {
    let plan=ProductionInkPlan(project:project,pages:[page],assets:assets)
    guard plan.canExport else{throw FormError.invalid(plan.issues.filter{$0["severity"] as? String=="error"}.compactMap{$0["message"] as? String}.joined(separator:"\n"))}
    for primitive in plan.pages.flatMap(\.primitives) {
      guard case .process(let channels)=primitive.paint,channels.count==4,channels.prefix(3).allSatisfy({$0==0}) else{
        throw FormError.invalid("\(page.name) is assigned black-only stock. Use explicit K-only ink; RGB black can convert into cyan, magenta and yellow.")
      }
    }
  }
  public static func physicalPreflight(_ project:Project,documentID:UUID,assembly:ProductObject,assets:URL,layout:PublicationPDFLayout,previewOnly:Bool=false)->[String:Any] {
    var report=preflight(project,documentID:documentID,assets:assets,previewOnly:previewOnly)
    var issues=report["issues"] as? [[String:Any]] ?? []
    do {
      let plan=try physicalArrangement(project,documentID:documentID,assembly:assembly,layout:layout)
      report["arrangement"]=try jsonObject(plan);report["physical_object_id"]=assembly.id.uuidString
      let pages=project.publications?.first{$0.id==documentID}?.pages ?? []
      for entry in pages {
        guard let object=project.objects.first(where:{$0.id==entry.objectID}),let parent=try project.parentSheet(forPageObjectID:object.id,in:assembly) else{continue}
        if !previewOnly,parent.printIntent == .blackOnly {try validateBlackOnly(project,page:physicalInkPage(project,object:object),assets:assets)}
      }
      report["parent_sheet_count"]=assembly.sheetAssembly?.parentSheets?.count ?? 0
      report["substrate_is_printed"]=false
      report["stock_color_encoded_in_pdf"]=previewOnly;report["for_print"] = !previewOnly
    }catch{issues.append(["severity":"error","code":"physical_print","message":error.localizedDescription])}
    report["issues"]=issues;report["can_export"] = !issues.contains{$0["severity"] as? String=="error"}
    return report
  }
  public static func physicalPDF(_ project:Project,documentID:UUID,assembly:ProductObject,assets:URL,dpi:Double=300,
    outlineText:Bool=false,allowOverset:Bool=false,layout:PublicationPDFLayout,previewOnly:Bool=false)throws->Data {
    let plan=try physicalArrangement(project,documentID:documentID,assembly:assembly,layout:layout)
    let report=physicalPreflight(project,documentID:documentID,assembly:assembly,assets:assets,layout:layout,previewOnly:previewOnly)
    let errors=(report["issues"] as? [[String:Any]] ?? []).filter{$0["severity"] as? String=="error" && !(allowOverset && $0["code"] as? String=="overset")}.compactMap{$0["message"] as? String}
    guard errors.isEmpty else{throw FormError.invalid(errors.joined(separator:"\n"))}
    guard let document=project.publications?.first(where:{$0.id==documentID}) else{throw FormError.missing("Publication not found.")}
    let rgb=try pdf(project,documentID:documentID,assets:assets,dpi:dpi,outlineText:outlineText,allowOverset:allowOverset,inkOutput:.preview)
    guard let provider=CGDataProvider(data:rgb as CFData),let reader=CGPDFDocument(provider) else{throw FormError.invalid("Could not read composed publication pages.")}
    let profile=previewOnly ? nil:try outputProfile(project,document:document)
    let physicalProfile=try profile.map{try ICCOutputProfile(reference:$0,assets:assets)}
    var prepared=[Int:CGPDFDocument]()
    func onePage(_ page:CGPDFPage)throws->Data {
      let data=NSMutableData();var media=page.getBoxRect(.mediaBox)
      guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&media,nil) else{throw FormError.invalid("Could not prepare a physical page.")}
      func box(_ value:CGRect)->Data {var value=value;return Data(bytes:&value,count:MemoryLayout<CGRect>.size)}
      context.beginPDFPage([kCGPDFContextMediaBox:box(media),kCGPDFContextTrimBox:box(page.getBoxRect(.trimBox))] as CFDictionary)
      context.drawPDFPage(page);context.endPDFPage();context.closePDF();return data as Data
    }
    for(index,entry) in document.pages.enumerated() {
      guard let object=project.objects.first(where:{$0.id==entry.objectID}),let parent=try project.parentSheet(forPageObjectID:object.id,in:assembly),let page=reader.page(at:index+1) else{throw FormError.invalid("A declared print page is missing.")}
      let data:Data
      if !previewOnly,parent.printIntent == .blackOnly {
        data=try ProductionInkPDF.export(project:project,pages:[physicalInkPage(project,object:object)],assets:assets,mode:.composite,title:document.name).data
      }else if let physicalProfile {
        data=try ProfiledPDF.convert(onePage(page),profile:physicalProfile,title:document.name)
      }else{data=try onePage(page)}
      guard let provider=CGDataProvider(data:data as CFData),let composed=CGPDFDocument(provider) else{throw FormError.invalid("Could not prepare print page \(index+1).")}
      prepared[index+1]=composed
    }
    let data=NSMutableData();var initial=CGRect(x:0,y:0,width:100,height:100)
    var documentInfo:[String:Any]=[kCGPDFContextTitle as String:document.name,kCGPDFContextCreator as String:"LAB"]
    if let physicalProfile {
      // Label the assembled document's actual selected output condition. Its
      // component pages have already been converted or written as explicit ink
      // channels; attaching this intent must not reconvert K-only source paints.
      documentInfo[kCGPDFContextOutputIntent as String]=[
        kCGPDFXOutputIntentSubtype as String:"GTS_PDFX",
        kCGPDFXOutputConditionIdentifier as String:"FORM-ICC-"+physicalProfile.reference.sha256,
        kCGPDFXInfo as String:physicalProfile.reference.name,
        kCGPDFXDestinationOutputProfile as String:physicalProfile.space]
      documentInfo[kCGPDFContextSubject as String]="ICC-SHA256-"+physicalProfile.reference.sha256+"; no PDF/X certification"
    }
    guard let consumer=CGDataConsumer(data:data),let output=CGContext(consumer:consumer,mediaBox:&initial,documentInfo as CFDictionary) else{throw FormError.invalid("Could not create physical publication output.")}
    func box(_ value:CGRect)->Data {var value=value;return Data(bytes:&value,count:MemoryLayout<CGRect>.size)}
    let factor=TypographyEngine.pointsPerMM
    for side in plan.sides {
      let media=CGRect(x:0,y:0,width:side.widthMM*factor,height:side.heightMM*factor)
      output.beginPDFPage([kCGPDFContextMediaBox:box(media),kCGPDFContextCropBox:box(media),kCGPDFContextTrimBox:box(media),kCGPDFContextBleedBox:box(media)] as CFDictionary)
      for placement in side.placements {
        let rect=CGRect(x:placement.xMM*factor,y:(side.heightMM-placement.heightMM)*factor,width:placement.widthMM*factor,height:placement.heightMM*factor)
        output.saveGState();output.clip(to:rect)
        let parent:SheetAssemblyParentSheet?
        if let id=placement.objectID {parent=try project.parentSheet(forPageObjectID:id,in:assembly)}
        else if layout == .booklet,let sheet=side.sheet,let parents=assembly.sheetAssembly?.parentSheets,parents.indices.contains(sheet-1) {parent=parents[sheet-1]}
        else {parent=nil}
        if previewOnly,let parent {
          let front:Bool
          if let id=placement.objectID,let pageID=document.pages.first(where:{$0.objectID==id})?.id {front=parent.frontPageIDs.contains{$0==pageID}}
          else {front = !side.reverse}
          let ply=front ? parent.stock.plies?.last:parent.stock.plies?.first
          let color=ply?.profile?.color ?? ply?.color ?? parent.stock.profile?.color ?? "#FFFFFF"
          let hex=UInt32(color.dropFirst(),radix:16) ?? 0xFFFFFF
          output.setFillColor(CGColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1));output.fill(rect)
        }
        if let number=placement.sourcePage,let page=prepared[number]?.page(at:1) {
          let trim=page.getBoxRect(.trimBox)
          output.translateBy(x:rect.minX-trim.minX,y:rect.minY-trim.minY);output.drawPDFPage(page)
        }
        output.restoreGState()
      }
      output.endPDFPage()
    }
    output.closePDF();return data as Data
  }
}

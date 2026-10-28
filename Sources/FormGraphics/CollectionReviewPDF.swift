import AppKit
import CoreText
import FormCore

@MainActor public enum CollectionReviewPDF {
  public static func data(source:CollectionSource,report:CollectionPreflight)throws->Data {
    guard report.rows.count<=CollectionLimits.rows,report.occurrences.count<=CollectionLimits.rows else{throw FormError.invalid("Collection review exceeds its early row bound.")}
    let text=NSMutableAttributedString(string:"")
    var keepSpans:[NSRange]=[]
    var pendingHeadingStart:Int?
    func paragraph(_ value:String,_ size:CGFloat=9,_ bold:Bool=false) {
      let start=text.length
      let p=NSMutableParagraphStyle();p.paragraphSpacing=6;p.lineSpacing=1
      text.append(.init(string:value+"\n",attributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular),.foregroundColor:NSColor(calibratedWhite:0.14,alpha:1),.paragraphStyle:p]))
      if let heading=pendingHeadingStart {keepSpans.append(.init(location:heading,length:text.length-heading));pendingHeadingStart=nil}
      if bold,size>=11 {pendingHeadingStart=start}
    }
    paragraph("FORM / COLLECTION PRODUCTION REVIEW",9,true);paragraph(source.plan.name,23,true)
    paragraph("Source "+CollectionSource.digest(try source.data()),8)
    paragraph("Run declarations and estimates. No stock reservation/deduction, machine contact, supplier quotation, calibrated fit or factory-readiness claim.")
    paragraph("Included product runs",14,true)
    for o in report.occurrences {paragraph("\(o.quantity) × \(o.name) · \(o.parentID==nil ? "run root":"attached detail; counted once")")}
    paragraph("Materials, components and process quantities",14,true)
    for row in report.rows {
      let start=text.length
      paragraph(row.name+" / "+(row.quantity ?? "Unknown")+" "+row.unit.rawValue+" / "+row.evidence.rawValue,10,true)
      paragraph(row.formula)
      paragraph("Supplier: \(row.supplier ?? "Unknown") · SKU: \(row.sku ?? "Unknown") · cost: \(row.currency ?? "Unknown currency") \(row.cost ?? "Unknown").")
      if let reason=row.excludedReason {paragraph("Excluded from total: "+reason)}
      if let c=row.calculation {paragraph("Estimate arithmetic v1: \(c.numerator) / \(c.denominator) = \(c.result); \(c.roundingMode), scale\(c.scale), rounding occurred: \(c.rounded). Original inputs: "+c.originalInputs.keys.sorted().map{$0+"="+c.originalInputs[$0]!}.joined(separator:"; "))}
      if let notes=row.notes {paragraph(notes)}
      keepSpans.append(NSRange(location:start,length:text.length-start))
    }
    paragraph("Declared price subtotals",14,true)
    for currency in report.knownSubtotals.keys.sorted() {paragraph(currency+" "+report.knownSubtotals[currency]!+" / known priced subtotal",11,true)}
    paragraph(report.completeTotal.map{"Complete declared estimate: "+(report.currency ?? "")+" "+$0} ?? "Complete estimate unknown; retain the following missing stages/rates/quantities.",11,true)
    for u in report.unknowns {paragraph(u)}
    paragraph("Shared stock declarations",14,true)
    if report.stock.isEmpty {paragraph("No portable stock assigned; availability is unknown.")}
    for stock in report.stock {paragraph(stock.name+" · known demand "+stock.knownDemand+" "+stock.unit.rawValue+" · available "+(stock.available ?? "Unknown")+" · "+stock.status+". Compared once across all contributor rows; no deduction.")}
    paragraph("Construction, placement and provenance",14,true)
    for run in source.plan.runs {
      if let id=run.objectID,let root=source.project.objects.first(where:{$0.id==id}) {
        paragraph(root.name+" / "+(root.textile?.blankName ?? root.recipeID),11,true)
        paragraph("Manufacturer: \(root.textile?.manufacturer ?? "Unknown") · blank SKU: \(root.textile?.sku ?? "Unknown") · size: \(root.textile?.size ?? "Unknown").")
        for child in source.project.objects where CollectionQuantities.parent(child)==id {
          if let a=child.textile?.attachment {paragraph("\(child.name): \(a.zone.name), offset \(a.offset.x)/\(a.offset.y) mm, rotation \(a.rotation)°, method \(child.textile?.attachmentMethod ?? "Unknown").")}
          if let a=child.patternAssemblyAttachment {paragraph("\(child.name): original assembly material anchor \(a.anchor.materialPointMm.x)/\(a.anchor.materialPointMm.y) mm; runtime drape is not a placement measurement.")}
        }
      }
      if let id=run.garmentBlockID,let block=source.project.garmentBlocks?.first(where:{$0.id==id}),let size=block.sizes.first(where:{$0.id==run.sizeID}) {
        let v=try block.resolved(size)
        paragraph(block.name+" / "+v.label+" · recipe\(block.recipeVersion)",11,true)
        paragraph("Declared body waist/hip \(v.waist)/\(v.hip) mm; nominal body length \(v.bodyLength) mm; raw source height \(v.rawHeight) mm; elastic cut \(v.elasticCutLength) mm includes lap\(block.style.elasticOverlap) mm once. Not physically validated fit.")
      }
    }
    if !report.findings.isEmpty {paragraph("Findings and unknowns",14,true);for finding in report.findings {paragraph(finding.severity.uppercased()+": "+finding.message)}}
    if let notes=source.plan.notes {paragraph("Collection notes: "+notes)}
    guard text.length<=240000 else{throw FormError.invalid("Collection review exceeds240,000 characters before PDF rendering; split the collection.")}
    // A heading and its first detail may overlap an existing complete BOM row.
    // Union those spans so moving the row cannot leave its heading orphaned.
    // Adjacent independent rows remain separate, bounded pagination units.
    var keepBlocks:[NSRange]=[]
    for span in keepSpans.sorted(by:{$0.location<$1.location}) {
      if let last=keepBlocks.last,span.location<NSMaxRange(last) {keepBlocks[keepBlocks.count-1]=NSUnionRange(last,span)}
      else {keepBlocks.append(span)}
    }
    let setter=CTFramesetterCreateWithAttributedString(text),path=CGPath(rect:.init(x:42,y:45,width:511.276,height:751.89),transform:nil)
    var frames:[CTFrame]=[],offset=0
    let diagrams=source.plan.runs.compactMap{run in run.objectID.flatMap{id in source.project.objects.first{$0.id==id && $0.textile?.kind == .garment}}}
    while offset<text.length {
      guard frames.count+diagrams.count<CollectionLimits.pages else{throw FormError.invalid("Collection review exceeds100 pages before PDF rendering.")}
      var frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil)
      var range=CTFrameGetVisibleStringRange(frame)
      let end=range.location+range.length
      if let block=keepBlocks.first(where:{$0.location>offset && $0.location<end && NSMaxRange($0)>end}) {frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:block.location-offset),path,nil);range=CTFrameGetVisibleStringRange(frame)}
      guard range.length>0 else{throw FormError.invalid("Collection text cannot fit its bounded review page.")};frames.append(frame);offset+=range.length
    }
    let bytes=NSMutableData();var media=CGRect(x:0,y:0,width:595.276,height:841.89)
    guard let consumer=CGDataConsumer(data:bytes),let context=CGContext(consumer:consumer,mediaBox:&media,[kCGPDFContextTitle as String:source.plan.name,kCGPDFContextCreator as String:"FORM"] as CFDictionary) else{throw FormError.invalid("Could not create the collection review PDF.")}
    func label(_ value:String,_ x:Double,_ y:Double,_ size:Double=8) {let line=CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.darkGray]));context.textPosition = .init(x:x,y:y);CTLineDraw(line,context)}
    for (i,frame) in frames.enumerated() {context.beginPDFPage(nil);context.textMatrix = .identity;CTFrameDraw(frame,context);label("FORM / COLLECTION / \(i+1)",42,24);context.endPDFPage()}
    for root in diagrams {
      context.beginPDFPage(nil);context.textMatrix = .identity
      label(root.name,42,792,17);label("Source placement schematic / mm / not a cutting pattern or verified physical blank",42,770,9)
      let w=root["width"],h=root["depth"],children=source.project.objects.filter{$0.textile?.attachment?.garmentID==root.id}
      guard w>0,h>0,w.isFinite,h.isFinite else{throw FormError.invalid("Garment schematic dimensions are invalid.")}
      var marks:[(ProductObject,Double,Double)]=[]
      for child in children {
        guard let a=child.textile?.attachment else{continue}
        let anchor=MerchandiseBlanks.garmentIDs.contains(root.recipeID) ? Vector3():TextileDesign.anchor(root,zone:a.zone)
        // Bomber anchors have a defined physical source coordinate. Other
        // merchandise zones remain listed, without inventing a flat projection.
        if root.recipeID=="bomberJacket" {marks.append((child,anchor.x+a.offset.x,anchor.z+a.offset.y))}
      }
      let extentX=max(w/2,marks.map{abs($0.1)+$0.0.artworkSize.x/2}.max() ?? 0),extentY=max(h/2,marks.map{abs($0.2)+$0.0.artworkSize.y/2}.max() ?? 0),scale=min(490/(extentX*2),480/(extentY*2))
      let cx=297.638,cy=462.0
      context.setStrokeColor(NSColor.gray.cgColor);context.setLineWidth(0.7);context.stroke(.init(x:cx-w*scale/2,y:cy-h*scale/2,width:w*scale,height:h*scale))
      label("Body source envelope \(w) × \(h) mm",42,715,10)
      for (i,mark) in marks.enumerated() {let size=mark.0.artworkSize,x=cx+(mark.1-size.x/2)*scale,y=cy-(mark.2+size.y/2)*scale;context.stroke(.init(x:x,y:y,width:size.x*scale,height:size.y*scale));label(String(i+1),x+2,y+2)}
      for (i,item) in children.prefix(12).enumerated() {label("\(i+1). \(item.name) / \(item.artworkSize.x) × \(item.artworkSize.y) mm",42,185-Double(i)*12)}
      label("Front/back zones retain their separate source definition; this envelope is a reference projection.",42,25,8)
      context.endPDFPage()
    }
    context.closePDF();guard bytes.length<=CollectionLimits.fileBytes else{throw FormError.invalid("Collection review exceeds64 MB.")};return bytes as Data
  }
}

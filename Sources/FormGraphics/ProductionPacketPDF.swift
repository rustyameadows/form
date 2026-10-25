import AppKit
import CoreText
import FormCore

@MainActor public enum ProductionPacketPDF {
  public static func data(job:ProductionJob,revision:ProductionJobRevision,program:EmbroideryProgram)throws -> Data {
    try job.validate();try revision.validate();try program.validate()
    guard revision.sourceDigest==program.sourceDigest,job.sourceDigest==program.sourceDigest,revision.object.textile?.embroidery==program.design,
      revision.usage==ThreadNeedleUsage.measure(program),revision.threadSequence==program.threadOrder else {throw FormError.invalid("Production report inputs differ from the archived needle revision.")}
    let report=NSMutableAttributedString(string:"")
    func paragraph(_ text:String,size:CGFloat = 10,bold:Bool = false,mono:Bool = false) {
      let style=NSMutableParagraphStyle();style.paragraphSpacing=7;style.lineSpacing=2
      let font=mono ? NSFont.monospacedSystemFont(ofSize:size,weight:.regular):NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular)
      report.append(.init(string:text+"\n",attributes:[.font:font,.foregroundColor:NSColor(calibratedWhite:0.15,alpha:1),.paragraphStyle:style]))
    }
    func amount(_ value:Double?)->String {value.map {String(format:"%.6g",$0)} ?? "Unknown"}
    func money(_ value:Double?,_ currency:String?)->String {guard let value,let currency else {return "Unknown"};return currency+" "+amount(value)}
    func heading(_ text:String) {paragraph(text,size:13,bold:true)}
    let estimate=ProductionCostEstimate.estimate(revision),object=revision.object,date=ISO8601DateFormatter().string(from:job.createdAt)
    paragraph("FORM / PRODUCTION RECORD",size:9,bold:true)
    paragraph(job.name,size:24,bold:true)
    paragraph("Quantity \(job.quantity) · \(job.status.rawValue.capitalized) · captured \(date)",size:10)
    paragraph("Job \(job.id.uuidString)",size:8,mono:true)
    paragraph("Source \(job.sourceDigest)",size:8,mono:true)
    paragraph("Revision \(job.revisionDigest)",size:8,mono:true)
    paragraph("Needle program \(job.programDigest)",size:8,mono:true)
    heading("Scope and physical specification")
    paragraph("\(object.name) · \(amount(object.artworkSize.x)) × \(amount(object.artworkSize.y)) mm · \(object.textile?.process.name ?? "Embroidery")")
    paragraph("Material: \(revision.material.name) · \(revision.material.fabric?.composition ?? "Composition unknown") · supplier \(revision.material.fabric?.supplier ?? "Unknown") · SKU \(revision.material.fabric?.sku ?? "Unknown")")
    paragraph("Backing: \(object.textile?.backing ?? "Unknown") · border: \(object.textile?.border ?? "Unknown") · attachment: \(object.textile?.attachmentMethod ?? "Unknown")")
    if let garment=revision.garment,let placement=object.textile?.attachment {
      paragraph("Placement: \(garment.name), \(placement.zone.name), offset \(amount(placement.offset.x)) / \(amount(placement.offset.y)) mm, rotation \(amount(placement.rotation))°. Blank SKU: \(garment.textile?.sku ?? "Unknown").")
      paragraph(garment.textile?.measurementsVerified == true ? "Blank dimensions are user-declared verified.":"Blank dimensions are concept declarations; physical sample measurements are not verified.")
    }
    paragraph("Hoop \(amount(program.design.hoopWidth)) × \(amount(program.design.hoopHeight)) mm · clearance \(amount(program.design.margin)) mm · \(program.stitchCount) needle commands per item. Captured outputs: \(revision.outputs.map {$0.uppercased()}.joined(separator:", ")).")
    heading("Thread schedule and measured needle paths")
    paragraph("Pass order: "+revision.threadSequence.enumerated().map {"\($0.offset+1) → thread \($0.element+1)"}.joined(separator:"; "))
    for usage in revision.usage {
      let thread=program.design.threads[usage.threadIndex],line=estimate.threads.first {$0.threadIndex==usage.threadIndex}
      paragraph("\(usage.threadIndex+1). \(thread.name) / \(thread.color) · \(usage.stitches) stitches · needle path \(amount(usage.needleMeters)) m/item (underlay \(amount(usage.underlayMeters)); locks \(amount(usage.tieMeters))).",bold:true)
      paragraph("Stock: \(thread.stock?.brand ?? thread.brand ?? "Unknown brand") · SKU \(thread.stock?.sku ?? thread.catalog ?? "Unknown") · supplier \(thread.stock?.supplier ?? "Unknown") · location \(thread.stock?.location ?? "Unknown").")
      paragraph("Estimated job use: \(amount(line?.estimatedMeters)) m · stock at assignment: \(amount(line?.stockAvailableMeters)) m · stock sufficiency: \(line?.stockSufficient.map {$0 ? "Declared sufficient":"Declared insufficient"} ?? "Unknown") · cost: \(money(line?.estimatedCost,line?.currency)).")
    }
    heading("BOM and explicit cost assumptions")
    for note in estimate.inventoryNotes {paragraph("Inventory: "+note)}
    paragraph("Base component: \(object.name), \(job.quantity) items. Unit cost \(money(revision.assumptions.baseUnitCost,revision.assumptions.baseCurrency)). Garment placement context does not automatically add garment purchases to this decoration-only BOM.")
    for item in revision.assumptions.extraBOM {
      paragraph("\(item.name): \(amount(item.quantityPerItem*Double(job.quantity))) \(item.unit) · unit cost \(money(item.unitCost,item.currency)) · supplier \(item.supplier ?? "Unknown") · SKU \(item.sku ?? "Unknown").")
    }
    paragraph("Upper-thread factor: \(amount(revision.assumptions.upperThreadFactor)); extra allowance: \(amount(revision.assumptions.allowanceMetersPerThreadPerItem)) m/color/item. Estimated use = quantity × (measured needle path × factor + allowance). Both assumptions are required; needle-path length excludes travel and is not machine consumption. Bobbin, stabilizer, fabric losses, and other materials need explicit additional BOM lines.")
    paragraph("Labor: \(amount(revision.assumptions.laborMinutesPerItem)) minutes/item at \(money(revision.assumptions.hourlyLaborRate,revision.assumptions.laborCurrency))/hour.")
    for currency in estimate.knownSubtotals.keys.sorted() {paragraph("Known priced subtotal: "+money(estimate.knownSubtotals[currency],currency))}
    paragraph("Complete estimated total: "+money(estimate.total,estimate.currency),bold:true)
    for unknown in estimate.unknowns {paragraph("Unknown: "+unknown)}
    if let notes=revision.assumptions.notes,!notes.isEmpty {paragraph("Assumption notes: "+notes)}
    heading("Declared equipment compatibility")
    paragraph("\(revision.equipment?.name ?? "No profile selected") · \(revision.compatibility.status.displayName)")
    for message in revision.compatibility.messages {paragraph(message)}
    heading("User-recorded samples and quality history")
    if job.records.isEmpty {paragraph("No samples, actual use, quality results, or completion have been recorded.")}
    for record in job.records {
      paragraph("\(ISO8601DateFormatter().string(from:record.date)) · \(record.kind.rawValue) · \(record.recordedBy ?? "Author unspecified")",bold:true)
      if let status=record.status {paragraph("User-declared status: "+status.rawValue)}
      if let outcome=record.outcome {paragraph("User-reported result: "+outcome.rawValue)}
      if let meters=record.reportedMeters {paragraph("User-reported consumption: \(amount(meters)) m; not a machine measurement.")}
      paragraph(record.notes)
    }
    paragraph("No machine was contacted. Inventory was not reserved or deducted. User-recorded approval/completion does not create an automatic verified sew-out claim. Compatibility covers declared hoop/format only; no fabric compensation, machine tuning, or physical quality is inferred.",size:9)
    let data=NSMutableData(),framesetter=CTFramesetterCreateWithAttributedString(report)
    var media=CGRect(x:0,y:0,width:595.276,height:841.89)
    let info:[String:Any]=[kCGPDFContextCreator as String:"FORM",kCGPDFContextTitle as String:job.name,kCGPDFContextSubject as String:"Revision-linked embroidery production review; final hoop page is actual size."]
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&media,info as CFDictionary) else {throw FormError.invalid("Could not create production review PDF.")}
    var offset=0,page=0
    while offset<report.length {
      guard page<100 else {throw FormError.invalid("Production history exceeds the 100-page review limit. Shorten long records before creating the packet.")}
      context.beginPDFPage(nil);page+=1;context.textMatrix = .identity
      let path=CGPath(rect:.init(x:42,y:45,width:media.width-84,height:media.height-90),transform:nil)
      let frame=CTFramesetterCreateFrame(framesetter,CFRange(location:offset,length:0),path,nil),range=CTFrameGetVisibleStringRange(frame)
      guard range.length>0 else {throw FormError.invalid("A production record cannot be composed within the PDF page.")}
      CTFrameDraw(frame,context);offset+=range.length
      let footer=CTLineCreateWithAttributedString(NSAttributedString(string:"FORM / \(job.id.uuidString.prefix(8)) / \(page)",attributes:[.font:NSFont.monospacedSystemFont(ofSize:8,weight:.regular),.foregroundColor:NSColor.gray]))
      context.textPosition = .init(x:42,y:24);CTLineDraw(footer,context);context.endPDFPage()
    }
    // A separate physical page preserves hoop origin/scale rather than fitting
    // needle bounds into an arbitrary report illustration.
    let unit=TypographyEngine.pointsPerMM,w=(program.design.hoopWidth+32)*unit,h=(program.design.hoopHeight+32)*unit
    var physical=CGRect(x:0,y:0,width:w,height:h)
    context.beginPDFPage([kCGPDFContextMediaBox:Data(bytes:&physical,count:MemoryLayout<CGRect>.size)] as CFDictionary)
    context.saveGState();context.translateBy(x:w/2,y:h/2);context.scaleBy(x:unit,y:-unit)
    context.setStrokeColor(NSColor.gray.cgColor);context.setLineWidth(0.1)
    context.stroke(.init(x:-program.design.hoopWidth/2,y:-program.design.hoopHeight/2,width:program.design.hoopWidth,height:program.design.hoopHeight))
    EmbroideryRenderer.draw(program,context:context,showJumps:false)
    context.restoreGState();context.textMatrix = .identity
    let caption=CTLineCreateWithAttributedString(NSAttributedString(string:"1:1 / \(amount(program.design.hoopWidth)) × \(amount(program.design.hoopHeight)) mm",attributes:[.font:NSFont.systemFont(ofSize:8),.foregroundColor:NSColor.gray]))
    context.textPosition = .init(x:12,y:h-22);CTLineDraw(caption,context)
    context.endPDFPage();context.closePDF();return data as Data
  }
}

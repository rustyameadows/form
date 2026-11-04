import AppKit
import CoreText
import FormCore
import FormGraphics

@MainActor enum ConstructionPacketPDF {
  private static let unit=72.0/25.4
  private static func make(_ title:String,_ body:(CGContext)throws->Void)throws->Data {
    let data=NSMutableData();var box=CGRect(x:0,y:0,width:210*unit,height:297*unit)
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&box,[kCGPDFContextTitle:title,kCGPDFContextCreator:"LAB",kCGPDFContextSubject:"Revision-linked nominal construction reference; actual-size cutting proofs are identified separately."] as CFDictionary) else {throw FormError.invalid("Could not prepare the construction PDF.")}
    try body(context);context.closePDF();return data as Data
  }
  private static func page(_ context:CGContext,width:Double,height:Double,_ draw:(CGContext)throws->Void)throws {
    guard width>0,height>0,width*unit<=14400,height*unit<=14400 else {throw FormError.invalid("Actual-size PDF proof exceeds the supported 200-inch page extent; use the nominal SVG for the larger piece.")}
    var box=CGRect(x:0,y:0,width:width*unit,height:height*unit)
    context.beginPDFPage([kCGPDFContextMediaBox:Data(bytes:&box,count:MemoryLayout<CGRect>.size)] as CFDictionary)
    context.saveGState();context.translateBy(x:0,y:box.height);context.scaleBy(x:unit,y:-unit)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    context.setFillColor(NSColor.white.cgColor);context.fill(.init(x:0,y:0,width:width,height:height))
    defer{NSGraphicsContext.restoreGraphicsState();context.restoreGState();context.endPDFPage()}
    try draw(context)
  }
  private static func text(_ value:String,x:Double,y:Double,width:Double,height:Double,size:Double=3,bold:Bool=false,color:NSColor = .darkGray,alignment:NSTextAlignment = .left,monospaced:Bool=false) {
    let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping;paragraph.alignment=alignment
    let font=monospaced ? NSFont.monospacedSystemFont(ofSize:size,weight:bold ? .semibold:.regular):NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular)
    (value as NSString).draw(in:.init(x:x,y:y,width:width,height:height),withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
  }
  private static func line(_ points:[Point2],closed:Bool,context:CGContext) {
    guard let first=points.first else{return};context.move(to:.init(x:first.x,y:first.y));for p in points.dropFirst(){context.addLine(to:.init(x:p.x,y:p.y))};if closed{context.closePath()}
  }
  static func patterns(_ model:ConstructionPacketModel)throws->Data {
    try make(model.name+" / actual-size independent patterns") {context in
      for piece in model.pieces {
        let width=max(160,piece.bounds.width+20),height=max(65,piece.bounds.height+36)
        try page(context,width:width,height:height) {context in
          if model.production.labels {
            text(piece.id+" / "+piece.name,x:10,y:5,width:width-20,height:7,size:4,bold:true)
            text("\(piece.stock.name) · \(amount(piece.stock.resolvedThicknessMM)) mm · \(amount(piece.bounds.width)) × \(amount(piece.bounds.height)) mm · Cut \(piece.quantity*model.production.quantity)",x:10,y:13,width:width-20,height:6)
          }
          context.saveGState();context.translateBy(x:10,y:22);context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(0.18)
          for contour in piece.cutContours {line(contour,closed:true,context:context)};context.strokePath()
          for guide in piece.guides {
            context.setStrokeColor(NSColor(hex:guide.role.isToolPath ? "#AD4E39":"#507C9A").cgColor);context.setLineWidth(0.15)
            context.setLineDash(phase:0,lengths:guide.role.isToolPath ? []:[2,1]);line(guide.points,closed:guide.closed,context:context);context.strokePath()
          }
          context.setLineDash(phase:0,lengths:[])
          if model.production.registrationMarks {
            context.setStrokeColor(NSColor.gray.cgColor)
            for p in [Point2(-2,-2),.init(piece.bounds.width+2,-2),.init(piece.bounds.width+2,piece.bounds.height+2),.init(-2,piece.bounds.height+2)] {
              line([.init(p.x-1,p.y),.init(p.x+1,p.y)],closed:false,context:context);line([.init(p.x,p.y-1),.init(p.x,p.y+1)],closed:false,context:context)
            };context.strokePath()
          }
          context.restoreGState()
          if model.production.labels {
            text("1:1 millimeters · print at 100% · nominal cut, no tool compensation · source "+model.sourceDigest.prefix(12),x:10,y:height-10,width:width-20,height:6,size:2.5)
          }
        }
      }
    }
  }
  static func materialLayouts(_ model:ConstructionPacketModel)throws->Data {
    try make(model.name+" / actual-size material layouts") {context in
      let byID=Dictionary(uniqueKeysWithValues:model.pieces.map{($0.id,$0)})
      var pages=0
      for batch in model.layouts.batches {for index in 0..<batch.sheetCount {
        pages+=1;guard pages<=256 else{throw FormError.invalid("Material proof exceeds 256 pages; split its production scope.")}
        let height=batch.format.surface == .roll ? batch.usedLengthMM:batch.format.lengthMM
        let annotations=model.production.labels ? ConstructionPacketDrawing.materialLayoutAnnotations(batch,sheetIndex:index):nil
        let labelsByPiece=Dictionary(grouping:annotations?.placements ?? [],by:\.pieceID).mapValues{Dictionary(uniqueKeysWithValues:$0.map{($0.copy,$0)})}
        try page(context,width:batch.format.widthMM,height:height) {context in
          context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(0.18)
          for placement in batch.placements where placement.sheetIndex==index {
            guard let piece=byID[placement.pieceID] else{continue}
            for contour in piece.cutContours {line(contour.map(placement.transform.apply),closed:true,context:context)};context.strokePath()
            if let annotation=labelsByPiece[placement.pieceID]?[placement.copy] {
              let label=annotation.frame
              context.saveGState();context.translateBy(x:label.origin.x,y:label.origin.y);context.rotate(by:label.rotationDegrees * .pi/180)
              text(annotation.text,x:0,y:0,width:label.size.x,height:label.size.y,size:label.fontSize,monospaced:true)
              context.restoreGState()
            }
          }
          if model.production.labels {text(batch.stock.name+" / \(amount(batch.stock.resolvedThicknessMM)) mm / sheet \(index+1) / 1:1",x:batch.format.marginMM,y:2,width:batch.format.widthMM-batch.format.marginMM*2,height:5,size:2.5)}
        }
        for (keyIndex,entries) in (annotations?.keyPages ?? []).enumerated() {
          pages+=1;guard pages<=256 else{throw FormError.invalid("Material proof and annotation keys exceed256 pages; split its production scope.")}
          let size=ConstructionPacketDrawing.materialKeyPageSize
          try page(context,width:size.x,height:size.y) {_ in
            text("Placement key / annotation only",x:15,y:12,width:180,height:8,size:5,bold:true)
            text("Batch \(batch.id) / sheet \(index+1) / key page \(keyIndex+1) of \(annotations?.keyPages.count ?? 0)",x:15,y:23,width:180,height:9,size:2.8)
            text("Full identities for numbered stock-layout labels. This page is not a cutting sheet.",x:15,y:34,width:180,height:10,size:2.6)
            var y=52.0
            for entry in entries {
              for line in entry.lines {
                text(line,x:15,y:y,width:180,height:ConstructionPacketDrawing.materialKeyLineHeight,size:ConstructionPacketDrawing.materialKeyFontSize,monospaced:true)
                y+=ConstructionPacketDrawing.materialKeyLineHeight
              }
              y+=ConstructionPacketDrawing.materialKeyLineHeight
            }
          }
        }
      }}
    }
  }
  /// Explicit page roles keep review keys from being mistaken for physical
  /// stock sheets by packet consumers and scale/quantity verification.
  static func materialLayoutPageIndex(_ model:ConstructionPacketModel)->[[String:Any]] {
    var result=[[String:Any]]()
    for batch in model.layouts.batches {for index in 0..<batch.sheetCount {
      result.append(["page":result.count+1,"role":"actualSizeStock","batch_id":batch.id,"sheet_index":index,
        "width_mm":batch.format.widthMM,"height_mm":batch.format.surface == .roll ? batch.usedLengthMM:batch.format.lengthMM,"annotation_only":false])
      if model.production.labels {
        let annotations=ConstructionPacketDrawing.materialLayoutAnnotations(batch,sheetIndex:index)
        for (keyIndex,entries) in annotations.keyPages.enumerated() {
          result.append(["page":result.count+1,"role":"labelKey","batch_id":batch.id,"sheet_index":index,"key_page_index":keyIndex,
            "width_mm":ConstructionPacketDrawing.materialKeyPageSize.x,"height_mm":ConstructionPacketDrawing.materialKeyPageSize.y,"annotation_only":true,
            "entries":entries.map{["key":$0.key,"piece_id":$0.pieceID,"copy":$0.copy] as [String:Any]}])
        }
      }
    }}
    return result
  }
  static func assembly(_ model:ConstructionPacketModel)throws->Data {
    try make(model.name+" / assembly and section reference") {context in
      let views=model.production.views.isEmpty ? ConstructionAssemblyDrawings.defaultViews():model.production.views
      for view in views {
        let drawing=try ConstructionAssemblyDrawings.resolve(source:model.source,view:view)
        let partIDs=Array(Set(drawing.shapes.map(\.pieceID))).sorted()
        let chunks:[Set<String>?]=model.production.labels && view.explosionPercent>0
          ? stride(from:0,to:partIDs.count,by:32).map{Set(partIDs[$0..<min(partIDs.count,$0+32)])}:[nil]
        for (chunkIndex,chunk) in chunks.enumerated() {
        let callouts=chunk.map{ConstructionAssemblyDrawings.calloutLayout(drawing,pieceIDs:$0)}
        try page(context,width:210,height:297) {context in
          text(view.title+(chunks.count>1 ? " / part key \(chunkIndex+1) of \(chunks.count)":""),x:15,y:12,width:180,height:10,size:5,bold:true)
          let size=drawing.assembledDimensionsMM
          text("Nominal assembly envelope at this pose: \(amount(size.x)) × \(amount(size.y)) × \(amount(size.z)) mm (X / Y / Z)",x:15,y:25,width:180,height:10,size:3)
          let area=CGRect(x:15,y:42,width:180,height:165),bounds=callouts?.bounds ?? drawing.bounds,factor=min(area.width/bounds.width,area.height/bounds.height)
          context.saveGState();context.translateBy(x:area.midX-bounds.width*factor/2-bounds.x*factor,y:area.midY-bounds.height*factor/2-bounds.y*factor);context.scaleBy(x:factor,y:factor)
          for shape in drawing.shapes {
            context.setStrokeColor(NSColor(calibratedWhite:0.2,alpha:0.85).cgColor);context.setLineWidth(max(0.1/factor,shape.lineWidthMM))
            line(shape.points,closed:shape.closed,context:context)
            for hole in shape.holes {line(hole,closed:true,context:context)}
            if shape.closed {context.setFillColor(NSColor(hex:shape.color).cgColor);context.drawPath(using:.eoFillStroke)}
            else{context.setStrokeColor(NSColor(hex:shape.color).cgColor);context.strokePath()}
          }
          if let callouts {
            for item in callouts.callouts {
              context.setStrokeColor(NSColor.darkGray.cgColor);context.setLineWidth(callouts.fontSize*0.07)
              line([item.anchor,item.position],closed:false,context:context);context.strokePath()
              let r=callouts.radius,box=CGRect(x:item.position.x-r,y:item.position.y-r,width:r*2,height:r*2)
              context.setFillColor(NSColor.white.cgColor);context.fillEllipse(in:box);context.strokeEllipse(in:box)
              text(String(item.number),x:box.minX,y:item.position.y-callouts.fontSize*0.6,width:box.width,height:callouts.fontSize*1.5,size:callouts.fontSize,bold:true,color:.black,alignment:.center)
            }
            for item in callouts.legend {
              for (index,value) in item.lines.enumerated() {
                text((index==0 ? "\(item.number)  ":"   ")+value,x:item.position.x,y:item.position.y+Double(index)*callouts.fontSize*1.45,
                  width:bounds.width/2,height:callouts.fontSize*1.6,size:callouts.fontSize,color:.black,monospaced:true)
              }
            }
          }
          context.restoreGState()
          if let axis=view.sectionAxis {text("Section plane \(axis.rawValue.uppercased()) = \(view.sectionOffsetMM?.expression ?? "0") mm. Independent material layers retain their declared calipers.",x:15,y:218,width:180,height:14,size:3)}
          text(drawing.representation,x:15,y:238,width:180,height:18,size:2.8)
          text("Reference diagram fitted to this page. Use Actual-size-pattern-proofs.pdf or nominal SVG files for physical cut scale.\nSource "+model.sourceDigest,x:15,y:265,width:180,height:20,size:2.5)
        }
        }
      }
      let report=NSMutableAttributedString(string:"")
      func paragraph(_ value:String,bold:Bool=false) {
        let style=NSMutableParagraphStyle();style.paragraphSpacing=7;style.lineSpacing=2
        report.append(NSAttributedString(string:value+"\n",attributes:[.font:NSFont.systemFont(ofSize:bold ? 12:9.5,weight:bold ? .semibold:.regular),.foregroundColor:NSColor.black,.paragraphStyle:style]))
      }
      paragraph(model.name+" / source-authored assembly order",bold:true)
      paragraph("Source "+model.sourceDigest)
      paragraph("Production quantity \(model.production.quantity). Nominal millimeters; no cutter compensation applied. Printing, score/groove tool paths, fold/turn-in/seam guides, and assembly marks remain distinct.")
      for (index,step) in model.steps.enumerated() {
        paragraph("\(index+1). "+step.title,bold:true)
        if !step.componentIDs.isEmpty {paragraph("Parts: "+step.componentIDs.joined(separator:", "))}
        if !step.jointIDs.isEmpty {paragraph("Joints: "+step.jointIDs.joined(separator:", "))}
        paragraph(step.instructions)
      }
      paragraph("Independent cutting and materials",bold:true)
      for piece in model.pieces {paragraph("\(piece.id) / \(piece.name) / group \(piece.groupID ?? "none") / \(piece.stock.name), \(amount(piece.stock.resolvedThicknessMM)) mm / \(amount(piece.bounds.width)) × \(amount(piece.bounds.height)) mm / cut \(piece.quantity*model.production.quantity) / grain \(piece.stock.grain.rawValue).")}
      for batch in model.layouts.batches {paragraph("\(batch.stock.name) / \(amount(batch.stock.resolvedThicknessMM)) mm: \(batch.sheetCount) \(batch.format.surface.rawValue) allocation(s), \(amount(batch.cutAreaMM2/1_000_000)) m² net pieces, \(amount(batch.stockAreaMM2/1_000_000)) m² stock. Nesting waste \(amount(batch.wasteFraction*100))%; explicit additional allowance \(amount(batch.format.wasteAllowanceFraction*100))%. Repacking never moves canonical artwork.")}
      if !model.attachments.tapes.isEmpty {paragraph("Tape cutting and placement",bold:true)}
      for tape in model.attachments.tapes {paragraph("\(tape.id) → joint \(tape.jointID), cut piece \(tape.componentID). \(tape.stock.name), \(amount(tape.stock.resolvedThicknessMM)) mm; \(amount(tape.widthMM)) × \(amount(tape.lengthMM)) mm; quantity \(tape.quantity*model.production.quantity). Side \(tape.side); end offsets \(amount(tape.endOffsetStartMM)) / \(amount(tape.endOffsetEndMM)) mm; overlap \(amount(tape.overlapMM)) mm; effective bond \(amount(tape.bondThicknessMM)) mm. Targets \(tape.firstTarget.panelID) / \(tape.secondTarget.panelID), with exact face/edge regions in Tape-schedule.json. Install \(tape.installation.order): \(tape.installation.stage). Present parts: \(tape.installation.presentComponentIDs.joined(separator:", ")). Later covered by: \((tape.installation.coveredByComponentIDs ?? []).joined(separator:", ")).")}
      if !model.attachments.staples.isEmpty {paragraph("Board-joint staple schedule",bold:true)}
      for staple in model.attachments.staples {
        paragraph("\(staple.id) → joint \(staple.jointID). Entry \(staple.entryPanelID); receiving \(staple.receivingPanelID). Crown \(amount(staple.crownWidthMM)) mm, wire \(amount(staple.wireWidthMM)) × \(amount(staple.wireDepthMM)) mm, legs \(amount(staple.legLengthMM)) mm; \(staple.termination.rawValue). Tool: \(staple.tool). Install \(staple.installation.order): \(staple.installation.stage). Source coordinate positions/orientation and actual leg/material intervals are in Staple-schedule.json. These are assembly marks, not drill/punch instructions.")
        paragraph("Entry side \(staple.entrySide.rawValue). Driver access \(amount(staple.toolAccessMM)) mm; clearance \(amount(staple.toolClearanceMM)) mm; minimum receiving depth \(amount(staple.minimumReceivingDepthMM)) mm, edge distance \(amount(staple.minimumEdgeDistanceMM)) mm, end margin \(amount(staple.endMarginMM)) mm; maximum joint gap \(amount(staple.maximumJointGapMM)) mm. Definition count \(staple.definitionCount), spacing \(amount(staple.spacingMM)) mm. Receiving entry boundaries: \(staple.receivingEntryBoundaries.map(\.surface.rawValue).joined(separator:", ")). Through-exit geometry is recorded independently of the declared buried/exposed/clinch termination.")
        if let access=staple.clincherAccessMM {paragraph("Required clincher access \(amount(access)) mm; declared clinch length \(amount(staple.clinchLengthMM ?? 0)) mm.")}
        for (index,leg) in staple.legMaterialIntervals.enumerated() {paragraph("Leg \(index+1): "+leg.map{"\($0.panelID) [\(amount($0.entryMM)), \(amount($0.exitMM))] mm"}.joined(separator:"; "))}
      }
      if !model.attachments.adhesives.isEmpty {paragraph("Adhesive declarations",bold:true)}
      for adhesive in model.attachments.adhesives {paragraph("\(adhesive.id): \(adhesive.identity), effective \(amount(adhesive.thicknessMM)) mm, coverage \(amount(adhesive.coverage*100))%. Bond regions and exclusions on \(adhesive.firstPanelID) / \(adhesive.secondPanelID) are retained in Adhesive-regions.json; no bond-strength simulation is claimed.")}
      paragraph("Recorded construction/process assumptions",bold:true)
      for assumption in model.production.assumptions {paragraph(assumption)}
      if let kerf=model.production.declaredKerfMM {paragraph("Declared kerf assumption: \(amount(kerf)) mm. It has not been applied to these nominal cut files; do not compensate twice.")}
      if !model.production.processNotes.isEmpty {paragraph(model.production.processNotes)}
      for issue in model.issues {paragraph(issue.severity.rawValue.uppercased()+": "+issue.message)}
      paragraph("Actual manufacturing samples, sliding feel, material compression, staple performance and bond strength remain physical evaluations. No printing, cutting, machine motion or heating command was sent.")
      let framesetter=CTFramesetterCreateWithAttributedString(report);var location=0,pages=0,box=CGRect(x:0,y:0,width:210*unit,height:297*unit)
      while location<report.length {
        guard pages<64 else{throw FormError.invalid("Assembly instructions exceed64 review pages; shorten or split their source-authored scope.")}
        context.beginPDFPage([kCGPDFContextMediaBox:Data(bytes:&box,count:MemoryLayout<CGRect>.size)] as CFDictionary);context.textMatrix = .identity
        let path=CGPath(rect:box.insetBy(dx:42,dy:45),transform:nil),frame=CTFramesetterCreateFrame(framesetter,CFRange(location:location,length:0),path,nil),range=CTFrameGetVisibleStringRange(frame)
        guard range.length>0 else{throw FormError.invalid("An assembly instruction cannot fit the proof page.")}
        CTFrameDraw(frame,context);context.endPDFPage();location+=range.length;pages+=1
      }
    }
  }
  private static func amount(_ value:Double)->String {String(format:"%.3f",value)}
}

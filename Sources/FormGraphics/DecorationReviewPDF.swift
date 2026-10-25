import AppKit
import CoreText
import FormCore

public struct DecorationReviewSpecification {
  public var name:String
  public var quantity:Int
  public var notes:String?
  public init(name:String,quantity:Int,notes:String?=nil) {self.name=name;self.quantity=quantity;self.notes=notes}
}

@MainActor enum DecorationReviewPDF {
  static func make(_ plan:DecorationGeometry,specification:DecorationReviewSpecification?)throws->Data {
    if let specification {
      guard !specification.name.isEmpty,specification.name.count<=160,(1...100000).contains(specification.quantity),(specification.notes?.count ?? 0)<=4000 else{throw FormError.invalid("Use a bounded preparation name, quantity and review notes.")}
    }
    let margin=12.0,header=24.0,factor=TypographyEngine.pointsPerMM
    var box=CGRect(x:0,y:0,width:(plan.pageWidth+margin*2)*factor,height:(plan.pageHeight+margin*2+header)*factor)
    let data=NSMutableData()
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&box,[kCGPDFContextTitle:"FORM decoration review",kCGPDFContextSubject:"Actual-size reference and explicit preparation specification; separate delivery files, no thermal recipe."] as CFDictionary) else{throw FormError.invalid("Could not compose decoration review.")}
    context.beginPDFPage(nil);context.saveGState();context.translateBy(x:0,y:box.height);context.scaleBy(x:factor,y:-factor)
    context.setFillColor(NSColor.white.cgColor);context.fill(.init(x:0,y:0,width:box.width/factor,height:box.height/factor))
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    ("FORM / "+plan.options.process.rawValue.uppercased()+" PREPARATION").draw(at:.init(x:margin,y:margin),withAttributes:[.font:NSFont.systemFont(ofSize:4,weight:.semibold),.foregroundColor:NSColor.black])
    let summary=String(format:"%.2f × %.2f mm artwork · mirror %@ · background %@",plan.width,plan.height,plan.options.mirror ? "on":"off",plan.options.includeBackground ? "included":"excluded")
    summary.draw(in:.init(x:margin,y:margin+7,width:plan.pageWidth,height:7),withAttributes:[.font:NSFont.systemFont(ofSize:3),.foregroundColor:NSColor.darkGray])
    "Actual-size reference. Delivery files are identified separately; see following specification.".draw(in:.init(x:margin,y:margin+14,width:plan.pageWidth,height:9),withAttributes:[.font:NSFont.systemFont(ofSize:2.7),.foregroundColor:NSColor.darkGray])
    NSGraphicsContext.restoreGraphicsState();context.translateBy(x:margin,y:margin+header)
    for region in plan.regions {context.addPath(plan.deliveryPath(region.path));context.setFillColor(FormColor.color(region.color).cgColor);context.fillPath()}
    context.setStrokeColor(NSColor.gray.cgColor);context.setLineWidth(0.1);context.stroke(.init(x:0,y:0,width:plan.pageWidth,height:plan.pageHeight));context.restoreGState();context.endPDFPage()
    let sourceName=plan.source.objects.first{$0.id==plan.source.objectID}?.name ?? "Physical artwork"
    var lines=["FORM / DECORATION SPECIFICATION",specification?.name ?? sourceName,"Quantity: \(specification.map{String($0.quantity)} ?? "not supplied")",
      String(format:"Artwork %.2f × %.2f mm; delivery page %.2f × %.2f mm.",plan.width,plan.height,plan.pageWidth,plan.pageHeight),
      "Process: \(plan.options.process.rawValue.uppercased()); delivery mirror: \(plan.options.mirror ? "on":"off"); source background: \(plan.options.includeBackground ? "included":"excluded").",
      "Opaque white artwork: \(plan.options.process == .htv ? "retained as a solid material region":plan.options.whitePolicy == .printOpaqueWhite ? "print white":"garment show-through"). Tint-zero paint clears earlier content."]
    if plan.options.process == .htv {
      lines += ["HTV / SOLID MATERIAL REGIONS",String(format:"Weed padding: %.2f mm. Artwork is never scaled to add the border.",plan.options.weedMargin),"Closed, outlined cut regions use normal knockout and painter order. No overlap, choke, tacking or blade/pressure setting is inferred."]
      for region in plan.regions {
        let m=region.material
        lines.append("• \(region.paintKey) / \(region.name) → \(m?.name ?? "material unknown"); supplier \(m?.supplier ?? "unknown"); SKU \(m?.sku ?? "unknown").\(m?.notes.map{" "+$0} ?? "")")
      }
    }else {
      lines += ["DTF / VENDOR-RIP HANDOFF",String(format:"Requested %.3f DPI. Encoded X/Y density and integer pixel dimensions are recorded in Revision/Report metadata.",plan.options.dpi),
        "Color delivery: \(plan.options.colorDelivery.rawValue). RGBA is an sRGB appearance handoff; a process PDF contains actual profile-pinned process colors.",
        "Named-spot process alternate conversion: \(plan.options.convertSpotAlternates ? "explicitly enabled":"disabled"). Original ink declarations stay in Source.json and original ICC assets.",
        "Underbase references: \(plan.options.includeUnderbaseReference ? "included":"omitted"). A silhouette reference is not a RIP white channel, ink density, choke or screening instruction."]
      if let profile=plan.source.artwork.outputColorProfile {lines.append("Output profile: \(profile.name); SHA-256 \(profile.sha256).")}
    }
    if let target=plan.source.target {
      lines += ["APPLICATION TARGET",target.garment.name+" / "+target.zoneName,
        String(format:"Placement offset %.2f, %.2f mm; rotation %.2f°. Surface: %@.",target.attachment.offset.x,target.attachment.offset.y,target.attachment.rotation,target.surface.rawValue),
        target.surface == .cylindricalBand ? "This curved concept zone records flat arc-length dimensions. Application compensation and contact remain unverified.":"Envelope validation does not establish application contact, compensation or material compatibility."]
    }
    lines += ["MATERIAL / EQUIPMENT DECLARATIONS",plan.options.materialNotes ?? "Material / film: unknown",plan.options.equipmentNotes ?? "Equipment / application settings: unknown"]
    if let notes=specification?.notes,!notes.isEmpty {lines += ["REVIEW NOTES",notes]}
    if !plan.issues.isEmpty {lines.append("PREFLIGHT FINDINGS");lines += plan.issues.map{"\($0.severity.uppercased()): \($0.message)"}}
    lines += ["SCOPE", "Delivery, reference and original source files are classified and hashed in Manifest.json. The source snapshot and original color declarations stay immutable; screen/RGBA previews do not encode named physical ink channels.",
      "No machine connection, stock reservation, automatic vendor compatibility, calibrated press result, cutting/printing or thermal recipe. Review material, film, adhesive, fabric and equipment requirements with the chosen provider."]
    let paragraph=NSMutableParagraphStyle();paragraph.paragraphSpacing=5
    let text=NSAttributedString(string:lines.joined(separator:"\n"),attributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.black,.paragraphStyle:paragraph])
    let framesetter=CTFramesetterCreateWithAttributedString(text),page=CGRect(x:0,y:0,width:210*factor,height:297*factor),path=CGPath(rect:page.insetBy(dx:36,dy:36),transform:nil)
    var location=0,pages=0
    while location<text.length {
      guard pages<64 else{throw FormError.invalid("Split this preparation specification above 64 pages.")}
      var pageBox=page
      context.beginPDFPage([kCGPDFContextMediaBox:Data(bytes:&pageBox,count:MemoryLayout<CGRect>.size)] as CFDictionary)
      let frame=CTFramesetterCreateFrame(framesetter,CFRange(location:location,length:0),path,nil),visible=CTFrameGetVisibleStringRange(frame)
      guard visible.length>0 else{throw FormError.invalid("The preparation specification could not fit a readable line.")}
      CTFrameDraw(frame,context);context.endPDFPage();location+=visible.length;pages+=1
    }
    context.closePDF();return data as Data
  }
}
